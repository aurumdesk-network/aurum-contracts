// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {BemPrice, IPancakeV3PoolLike, IPancakeV3SwapRouter} from "./BemPrice.sol";

interface IPancakeV2Router {
    function WETH() external view returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IDeskRegistry {
    function isDesk(uint256 tokenId) external view returns (bool);
}

/// @title DeskPot
/// @notice Staking, per-NFT vaults and distribution for AURUM.
///
///  Inflows
///   - AURUM tax: AurumToken sells it for BNB inside the next sell on its pair and calls `depositTax`. The BNB builds up in
///     `taxBnb`. The Desk Pot never holds AURUM.
///   - 0.6 BEM per chip set -> `mintBemPending` (reported by ChipSwap).
///
///  Rounds (no keeper: they run by themselves inside sells, chip purchases and stakes, or through `poke()`)
///   - At most one round per ROUND_INTERVAL. A round is due when `taxBnb` >= 0.03 BNB, or new desks wait to be
///     activated, or BNB/BEM waits for eligible desks.
///   - `taxBnb` is shared out in the proportions of the 5% tax: 1% to TapeCodeRewards as BNB (the NFT Staking Pool,
///     when it is set), 2% to the Protocol as BNB, and 2% stays in the Desk Pot: half into `directBnb` (distributed as
///     BNB), half into `buybackBnb` (to buy BEM on PancakeSwap V3). The two buckets are accounted separately.
///   - The BEM buy protects itself on chain: it only runs while the pool's spot tick is within MAX_TICK_DEVIATION
///     of its 30-minute average, spends at most 1% of the BNB in the BEM pool, and asks for at least the spot
///     price minus the pool fee and BUY_SLIPPAGE_BPS. Unspent buyback BNB waits for a later round; after
///     BUYBACK_GIVE_UP of failed or skipped buys it is paid out as BNB instead. Direct BNB is always paid.
///   - Bought BEM + mint BEM are distributed as BEM, direct BNB as BNB, each equally to every eligible desk.
///   - Eligible = staked before the round's epoch started. A desk staked during an epoch starts earning
///     from the next round (no stake-just-before-the-round sniping). With no eligible desk, nothing is paid
///     and the buckets wait.
///
///  Vaults: accounting per NFT id (one contract holds the assets). Unclaimed rewards belong to the NFT and
///  follow it after unstaking/transfer. Claims can be partial. Unstake and claim are never paused.
///  Invariant: balance of each asset >= reserved (credited, unclaimed) + carry (rounding) + undistributed buckets.
///
///  Upgrades (decided 2026-11-08): this contract runs behind an ERC-1967 proxy (UUPS). The proxy's address, its BNB,
///  BEM, staked desks and every vault stay put; only the code can be replaced. Only UPGRADER_ROLE may do it, and that
///  role is held by a TimelockController, so every upgrade is public for the timelock's delay before it takes effect.
///  UPGRADER_ROLE administers itself: DEFAULT_ADMIN_ROLE cannot grant it.
///  Rules for a new version: keep every state variable in place and only append new ones; immutables (bem, routers,
///  BEM pool) live in the implementation and may be changed by deploying it with other values.
contract DeskPot is Initializable, AccessControl, ReentrancyGuard, Pausable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address payable;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE"); // the upgrade timelock

    uint256 public constant ROUND_THRESHOLD = 0.03 ether; // tax BNB that starts a distribution
    uint256 public constant ROUND_INTERVAL = 1 hours; // at most one round per hour
    uint32 public constant TWAP_WINDOW = BemPrice.TWAP_WINDOW;
    int24 public constant MAX_TICK_DEVIATION = BemPrice.MAX_TICK_DEVIATION;
    uint256 public constant MAX_BUY_BPS_OF_POOL = 100; // one BEM buy spends at most 1% of the BNB in the BEM pool
    uint256 public constant BUY_SLIPPAGE_BPS = BemPrice.BUY_SLIPPAGE_BPS;
    uint256 public constant BUYBACK_GIVE_UP = 3 days; // buys failing this long: pay the waiting BNB out as BNB
    uint256 public constant TAPECODE_TAX_BPS = 2_000; // of the tax: 1% of the 5%
    uint256 public constant PROTOCOL_TAX_BPS = 4_000; // of the tax: 2% of the 5%
    uint256 public constant SEND_GAS = 50_000; // a receiver must not be able to eat the gas of the sale it runs in
    uint256 public constant BUYBACK_BPS = 5_000; // of the Desk Pot's 2%: half buys BEM, half stays BNB
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_ASSETS = 16;

    // asset ids in the registry
    uint256 public constant BNB = 0; // native BNB, token = address(0)
    uint256 public constant BEM = 1;

    IERC20 public immutable bem;
    address public immutable wbnb;
    IPancakeV2Router public immutable v2Router; // only used to learn WBNB
    IPancakeV3SwapRouter public immutable v3Router; // buys BEM
    IPancakeV3PoolLike public immutable bemPool; // PancakeSwap V3 BEM/WBNB pool the buyback trades on
    uint24 public immutable bemPoolFee; // its fee tier
    bool internal immutable bemIsToken0;

    IERC20 public desk;
    IERC721 public nft; // the AURUM processor: every desk is one of its circuits
    IDeskRegistry public minter; // which circuits are desks
    address public chipSwap; // sells chip sets for AURUM + BEM; the only caller of notifyMintBem
    address public tapeCodeRewards; // the NFT Staking Pool: receives its share of the tax; address(0) = no such share
    address public protocol; // receives the Protocol's share of the tax
    uint256 public totalProtocolBnb;

    // ---- asset registry ----
    struct Asset {
        address token; // address(0) = native BNB
        uint8 decimals;
        bool active;
    }

    Asset[] public assets;
    mapping(address => bool) public isRegistered;

    // ---- distribution accounting, per asset id ----
    mapping(uint256 => uint256) public cumulativePerDesk; // credited to one eligible desk, ever
    mapping(uint256 => uint256) public reserved; // credited to desks, not yet claimed
    mapping(uint256 => uint256) public carry; // rounding remainder, joins the next credit
    mapping(uint256 => uint256) public totalDistributed;
    mapping(uint256 => uint256) public totalClaimed;
    mapping(uint256 => mapping(uint256 => uint256)) public epochEndCumulative; // epoch => asset => cumulative

    // ---- undistributed buckets ----
    uint256 public taxBnb; // tax waiting for the threshold
    uint256 public buybackBnb; // earmarked for buying BEM (kept after failed swaps)
    uint256 public directBnb; // earmarked for direct BNB distribution
    uint256 public mintBemPending; // 0.6 BEM per chip set, not yet distributed
    uint256 public lastRoundAt;
    uint256 public buybackFailingSince; // first round since the last successful BEM buy whose buy failed or was skipped

    // ---- running totals (dashboards) ----
    uint256 public totalTaxBnb;
    uint256 public totalTapeCodeBnb;
    uint256 public totalBuybackBnbSpent;
    uint256 public totalBemBought;
    uint256 public totalBemFromMint;
    uint256 public totalBemFromMintDistributed;
    uint256 public rounds;

    // ---- staking ----
    struct StakeInfo {
        address staker;
        uint64 joinEpoch;
        bool checkpointed;
    }

    uint256 public epoch; // 1 from initialize()
    uint256 public eligibleDesks; // staked before the current epoch: share in the next round
    uint256 public pendingDesks; // staked during the current epoch: eligible after the next round
    mapping(uint256 => StakeInfo) public stakes;
    mapping(uint256 => mapping(uint256 => uint256)) internal checkpointOf; // tokenId => asset
    mapping(uint256 => mapping(uint256 => uint256)) internal accruedOf; // tokenId => asset => settled, unclaimed
    mapping(uint256 => mapping(uint256 => uint256)) public claimedOf; // tokenId => asset


    event Wired(address desk, address nft, address minter, address chipSwap);
    event TapeCodeRewardsSet(address indexed rewards);
    event AssetAdded(uint256 indexed assetId, address indexed token, uint8 decimals);
    event MintBemReceived(uint256 amount);
    event Staked(uint256 indexed tokenId, address indexed staker, uint256 epoch);
    event Unstaked(uint256 indexed tokenId, address indexed staker);
    event TaxReceived(uint256 deskSold, uint256 bnb);
    event TaxShared(uint256 tax, uint256 toTapeCode, uint256 toProtocol, uint256 toBuyBem, uint256 toDirectBnb);
    event ProtocolSet(address indexed protocol);
    event BemBought(uint256 bnbIn, uint256 bemOut);
    event BuybackDeferred(uint256 bnbKept);
    event BuybackGivenUp(uint256 bnbPaidAsBnb);
    event Round(
        uint256 indexed round,
        uint256 indexed epoch,
        uint256 eligibleDesks,
        uint256 bemBought,
        uint256 bemFromMint,
        uint256 bnbDistributed,
        uint256 bemPerDesk,
        uint256 bnbPerDesk
    );
    event Credited(uint256 indexed assetId, uint256 amount, uint256 perDesk, uint256 desks);
    event Claimed(uint256 indexed tokenId, uint256 indexed assetId, address indexed to, uint256 amount);

    error AlreadyInitialized();
    error NotInitialized();
    error ZeroAddress();
    error OnlyChipSwap();
    error OnlyDesk();
    error NotADesk();
    error NotOwner();
    error NotStaker();
    error AlreadyStaked();
    error NotRightsHolder();
    error BadAmount();
    error BadAsset();
    error TooManyAssets();
    error NothingToDo();
    error NoDirectDeposit();
    error BadPool();

    /// @dev Deploys the implementation only. The values here are immutables in its code, shared by the proxy.
    constructor(address bem_, address v2Router_, address v3Router_, address bemPool_) {
        if (bem_ == address(0) || v2Router_ == address(0) || v3Router_ == address(0) || bemPool_ == address(0)) {
            revert ZeroAddress();
        }
        bem = IERC20(bem_);
        v2Router = IPancakeV2Router(v2Router_);
        v3Router = IPancakeV3SwapRouter(v3Router_);
        wbnb = v2Router.WETH();
        bemPool = IPancakeV3PoolLike(bemPool_);
        address t0 = bemPool.token0();
        address t1 = bemPool.token1();
        if (!((t0 == bem_ && t1 == wbnb) || (t0 == wbnb && t1 == bem_))) revert BadPool();
        bemIsToken0 = t0 == bem_;
        bemPoolFee = bemPool.fee();
        _disableInitializers(); // the implementation itself can never be set up or used
    }

    /// @notice Runs once, through the proxy, at deploy. `upgrader` should be the upgrade timelock.
    function initialize(address admin, address upgrader, address protocol_) external initializer {
        if (admin == address(0) || upgrader == address(0) || protocol_ == address(0)) revert ZeroAddress();
        epoch = 1;
        protocol = protocol_;
        assets.push(Asset(address(0), 18, true)); // BNB
        assets.push(Asset(address(bem), IERC20Metadata(address(bem)).decimals(), true)); // BEM
        isRegistered[address(0)] = true;
        isRegistered[address(bem)] = true;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _setRoleAdmin(UPGRADER_ROLE, UPGRADER_ROLE);
        _grantRole(UPGRADER_ROLE, upgrader);
    }

    /// @notice One-time wiring (AURUM and ChipSwap need this contract's address at their own deploy).
    function wire(address desk_, address nft_, address minter_, address chipSwap_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(nft) != address(0)) revert AlreadyInitialized();
        if (desk_ == address(0) || nft_ == address(0) || minter_ == address(0) || chipSwap_ == address(0)) revert ZeroAddress();
        desk = IERC20(desk_);
        nft = IERC721(nft_);
        minter = IDeskRegistry(minter_);
        chipSwap = chipSwap_;
        emit Wired(desk_, nft_, minter_, chipSwap_);
    }

    /// @dev Only the upgrade timelock may replace the code.
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ------------------------------------------------------------------
    // Inflows
    // ------------------------------------------------------------------

    /// @notice Unexpected BNB (donations) joins the tax waiting to be shared. Tax BNB arrives through depositTax.
    receive() external payable {
        taxBnb += msg.value;
    }

    /// @notice Called by ChipSwap right after it transferred 0.6 BEM per chip set here.
    function notifyMintBem(uint256 amount) external nonReentrant {
        if (msg.sender != chipSwap) revert OnlyChipSwap();
        mintBemPending += amount;
        totalBemFromMint += amount;
        emit MintBemReceived(amount);
        _tryRound();
    }

    // ------------------------------------------------------------------
    // Staking
    // ------------------------------------------------------------------

    function stake(uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        if (address(nft) == address(0)) revert NotInitialized();
        _tryRound(); // a due round runs first, so the new desks still wait for the next one
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            if (!minter.isDesk(id)) revert NotADesk(); // circuits of another chip count on the processor are not desks
            if (nft.ownerOf(id) != msg.sender) revert NotOwner();
            if (stakes[id].staker != address(0)) revert AlreadyStaked();
            nft.transferFrom(msg.sender, address(this), id);
            stakes[id] = StakeInfo({staker: msg.sender, joinEpoch: uint64(epoch), checkpointed: false});
            ++pendingDesks;
            emit Staked(id, msg.sender, epoch);
        }
    }

    /// @notice Never paused. Unclaimed rewards stay with the NFT.
    function unstake(uint256[] calldata tokenIds) external nonReentrant {
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            StakeInfo memory s = stakes[id];
            if (s.staker != msg.sender) revert NotStaker();
            _settle(id);
            if (s.joinEpoch == epoch) --pendingDesks;
            else --eligibleDesks;
            delete stakes[id];
            nft.transferFrom(address(this), msg.sender, id);
            emit Unstaked(id, msg.sender);
        }
    }

    /// @notice Desks must enter through stake(); a raw safeTransfer would leave an NFT without a staker.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert NoDirectDeposit();
    }

    // ------------------------------------------------------------------
    // Claims (never paused)
    // ------------------------------------------------------------------

    /// @notice Claim `amount` of an asset from a desk's vault (type(uint256).max = everything).
    ///         Paid to the staker while staked, otherwise to the NFT's current owner.
    function claim(uint256 tokenId, uint256 assetId, uint256 amount) public nonReentrant {
        _claim(tokenId, assetId, amount);
    }

    function claimAll(uint256[] calldata tokenIds) external nonReentrant {
        uint256 n = assets.length;
        for (uint256 i; i < tokenIds.length; ++i) {
            _settle(tokenIds[i]);
            for (uint256 a; a < n; ++a) {
                if (accruedOf[tokenIds[i]][a] != 0) _claim(tokenIds[i], a, type(uint256).max);
            }
        }
    }

    function _claim(uint256 tokenId, uint256 assetId, uint256 amount) internal {
        if (assetId >= assets.length) revert BadAsset();
        address to = rightsHolder(tokenId);
        if (msg.sender != to) revert NotRightsHolder();
        _settle(tokenId);
        uint256 available = accruedOf[tokenId][assetId];
        if (amount == type(uint256).max) amount = available;
        if (amount == 0 || amount > available) revert BadAmount();

        accruedOf[tokenId][assetId] = available - amount;
        reserved[assetId] -= amount;
        claimedOf[tokenId][assetId] += amount;
        totalClaimed[assetId] += amount;

        address token = assets[assetId].token;
        if (token == address(0)) payable(to).sendValue(amount);
        else IERC20(token).safeTransfer(to, amount);
        emit Claimed(tokenId, assetId, to, amount);
    }

    // ------------------------------------------------------------------
    // Taxes and rounds (no keeper)
    // ------------------------------------------------------------------

    /// @notice Called by AURUM with the BNB from selling its collected tax. It waits until ROUND_THRESHOLD; a due round
    ///         then runs inside the same transaction.
    function depositTax(uint256 deskSold) external payable nonReentrant whenNotPaused {
        if (msg.sender != address(desk)) revert OnlyDesk();
        if (msg.value == 0) revert NothingToDo();
        taxBnb += msg.value;
        totalTaxBnb += msg.value;
        emit TaxReceived(deskSold, msg.value);
        _tryRound();
    }

    /// @notice Run a round now if one is due. Anyone may call it (the caller pays the gas); rounds also run by
    ///         themselves inside sells, chip purchases and stakes.
    function poke() external nonReentrant whenNotPaused {
        if (!_tryRound()) revert NothingToDo();
    }

    /// @notice Whether a round would run now.
    function roundDue() public view returns (bool) {
        return !paused() && address(nft) != address(0) && block.timestamp >= lastRoundAt + ROUND_INTERVAL && _hasWork();
    }

    /// @notice Earliest time of the next round (it also needs something to do).
    function nextRoundAt() external view returns (uint256) {
        return lastRoundAt + ROUND_INTERVAL;
    }

    /// @notice Future multi-asset support: credit a registered non-core asset equally to eligible desks.
    function depositAndDistribute(uint256 assetId, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused {
        if (assetId <= BEM || assetId >= assets.length || !assets[assetId].active) revert BadAsset();
        if (amount == 0 || eligibleDesks == 0) revert NothingToDo();
        IERC20(assets[assetId].token).safeTransferFrom(msg.sender, address(this), amount);
        _credit(assetId, amount, eligibleDesks);
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    /// @notice address(0) stops the TapeCode share: the whole tax then stays in the Desk Pot, half BNB, half BEM.
    function setTapeCodeRewards(address rewards) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tapeCodeRewards = rewards;
        emit TapeCodeRewardsSet(rewards);
    }

    /// @notice Register another asset (architecture for later versions; v1 distributes BNB and BEM).
    function addAsset(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || isRegistered[token] || token == address(desk)) revert BadAsset();
        if (assets.length >= MAX_ASSETS) revert TooManyAssets();
        uint8 dec = IERC20Metadata(token).decimals();
        assets.push(Asset(token, dec, true));
        isRegistered[token] = true;
        emit AssetAdded(assets.length - 1, token, dec);
    }

    function setProtocol(address protocol_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (protocol_ == address(0)) revert ZeroAddress();
        protocol = protocol_;
        emit ProtocolSet(protocol_);
    }

    /// @notice Emergency stop for tax deposits, rounds and new stakes. Unstake and claims keep working.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function assetsLength() external view returns (uint256) {
        return assets.length;
    }

    /// @notice Who may claim a desk's vault: the staker while staked, otherwise the NFT's owner.
    function rightsHolder(uint256 tokenId) public view returns (address) {
        address s = stakes[tokenId].staker;
        return s != address(0) ? s : nft.ownerOf(tokenId);
    }

    /// @notice Unclaimed balance of an asset in a desk's vault.
    function claimable(uint256 tokenId, uint256 assetId) external view returns (uint256) {
        return accruedOf[tokenId][assetId] + _unsettled(tokenId, assetId);
    }

    /// @notice Everything ever credited to a desk in an asset (claimed + claimable).
    function allocated(uint256 tokenId, uint256 assetId) external view returns (uint256) {
        return claimedOf[tokenId][assetId] + accruedOf[tokenId][assetId] + _unsettled(tokenId, assetId);
    }

    function isEligible(uint256 tokenId) external view returns (bool) {
        StakeInfo memory s = stakes[tokenId];
        return s.staker != address(0) && s.joinEpoch < epoch;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _unsettled(uint256 tokenId, uint256 assetId) internal view returns (uint256) {
        StakeInfo memory s = stakes[tokenId];
        if (s.staker == address(0) || s.joinEpoch >= epoch) return 0;
        uint256 base = s.checkpointed ? checkpointOf[tokenId][assetId] : epochEndCumulative[s.joinEpoch][assetId];
        return cumulativePerDesk[assetId] - base;
    }

    function _settle(uint256 tokenId) internal {
        StakeInfo storage s = stakes[tokenId];
        if (s.staker == address(0) || s.joinEpoch >= epoch) return;
        uint256 n = assets.length;
        for (uint256 a; a < n; ++a) {
            uint256 c = cumulativePerDesk[a];
            uint256 base = s.checkpointed ? checkpointOf[tokenId][a] : epochEndCumulative[s.joinEpoch][a];
            if (c != base) accruedOf[tokenId][a] += c - base;
            checkpointOf[tokenId][a] = c;
        }
        s.checkpointed = true;
    }

    function _credit(uint256 assetId, uint256 amount, uint256 desks) internal returns (uint256 perDesk) {
        uint256 total = amount + carry[assetId];
        perDesk = total / desks;
        uint256 used = perDesk * desks;
        carry[assetId] = total - used;
        cumulativePerDesk[assetId] += perDesk;
        reserved[assetId] += used;
        totalDistributed[assetId] += used;
        if (amount != 0) emit Credited(assetId, used, perDesk, desks);
    }

    function _hasWork() internal view returns (bool) {
        return taxBnb >= ROUND_THRESHOLD || pendingDesks != 0
            || (eligibleDesks != 0 && (buybackBnb != 0 || directBnb != 0 || mintBemPending != 0));
    }

    /// @dev Runs inside other people's transactions (sells, chip purchases, stakes), so it never reverts on its own:
    ///      the BEM buy and every pool read are wrapped.
    function _tryRound() internal returns (bool) {
        if (!roundDue()) return false;
        _round();
        return true;
    }

    function _round() internal {
        if (taxBnb >= ROUND_THRESHOLD) _shareTax();

        uint256 desks = eligibleDesks;
        uint256 bought;
        uint256 fromMint;
        uint256 bnbPaid;
        uint256 bemPer;
        uint256 bnbPer;
        if (desks != 0) {
            if (buybackBnb != 0) bought = _buyBem(); // may hand buyback BNB over to directBnb after BUYBACK_GIVE_UP
            fromMint = mintBemPending;
            mintBemPending = 0;
            totalBemFromMintDistributed += fromMint;
            bnbPaid = directBnb;
            directBnb = 0;
            bnbPer = _credit(BNB, bnbPaid, desks);
            bemPer = _credit(BEM, bought + fromMint, desks);
            ++rounds;
        }

        // close the epoch: desks staked during it become eligible from the next round
        uint256 e = epoch;
        uint256 n = assets.length;
        for (uint256 a; a < n; ++a) {
            epochEndCumulative[e][a] = cumulativePerDesk[a];
        }
        eligibleDesks = desks + pendingDesks;
        pendingDesks = 0;
        epoch = e + 1;
        lastRoundAt = block.timestamp;
        emit Round(rounds, e, desks, bought, fromMint, bnbPaid, bemPer, bnbPer);
    }

    /// @dev The tax that built up: 1% of the 5% to the NFT Staking Pool, 2% to the Protocol, and the Desk Pot's 2%: half
    ///      stays BNB, half buys BEM.
    function _shareTax() private {
        uint256 tax = taxBnb;
        taxBnb = 0;
        uint256 toTapeCode = _send(tapeCodeRewards, (tax * TAPECODE_TAX_BPS) / BPS);
        uint256 toProtocol = _send(protocol, (tax * PROTOCOL_TAX_BPS) / BPS);
        totalTapeCodeBnb += toTapeCode;
        totalProtocolBnb += toProtocol;
        uint256 rest = tax - toTapeCode - toProtocol;
        uint256 toBuy = (rest * BUYBACK_BPS) / BPS;
        buybackBnb += toBuy;
        directBnb += rest - toBuy;
        emit TaxShared(tax, toTapeCode, toProtocol, toBuy, rest - toBuy);
    }

    /// @dev A failing receiver must never block a sale: its share then simply stays in the Desk Pot.
    function _send(address to, uint256 amount) private returns (uint256 sent) {
        if (to == address(0) || amount == 0) return 0;
        (bool ok, ) = to.call{value: amount, gas: SEND_GAS}("");
        return ok ? amount : 0;
    }

    /// @dev Buys BEM with (part of) `buybackBnb`. A skipped or failed buy keeps the BNB for a later round.
    function _buyBem() internal returns (uint256 bought) {
        uint256 amount = buybackBnb;
        uint256 cap = (IERC20(wbnb).balanceOf(address(bemPool)) * MAX_BUY_BPS_OF_POOL) / BPS;
        if (amount > cap) amount = cap;
        uint256 minOut = amount == 0 ? 0 : BemPrice.minOut(bemPool, bemPoolFee, bemIsToken0, amount);
        if (minOut != 0) {
            uint256 before = bem.balanceOf(address(this));
            IPancakeV3SwapRouter.ExactInputSingleParams memory p = IPancakeV3SwapRouter.ExactInputSingleParams({
                tokenIn: wbnb,
                tokenOut: address(bem),
                fee: bemPoolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            });
            try v3Router.exactInputSingle{value: amount}(p) {
                bought = bem.balanceOf(address(this)) - before;
            } catch {}
        }
        if (bought != 0) {
            buybackBnb -= amount;
            buybackFailingSince = 0;
            totalBuybackBnbSpent += amount;
            totalBemBought += bought;
            emit BemBought(amount, bought);
            return bought;
        }
        if (buybackFailingSince == 0) buybackFailingSince = block.timestamp;
        if (block.timestamp >= buybackFailingSince + BUYBACK_GIVE_UP) {
            uint256 give = buybackBnb;
            directBnb += give;
            buybackBnb = 0;
            buybackFailingSince = 0;
            emit BuybackGivenUp(give);
        } else {
            emit BuybackDeferred(buybackBnb);
        }
    }
}
