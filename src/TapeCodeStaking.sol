// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title TapeCodeStaking
/// @notice Deployed on X Layer. Holds TapeCode NFTs while their owners stake them. Rewards are paid on BNB Chain by
///         TapeCodeRewards: when a list is prepared, every wallet here is read and shares in proportion to its points.
///
///  Points: NFTs staked x seconds, summed per wallet on chain. A payout only needs this contract's state at one block
///  (the public X Layer RPC serves event logs 100 blocks at a time), and staking just before a payout earns almost
///  nothing. Sum of all wallets' points == totalPoints() and sum of staked == totalStaked, at every block.
///
///  Safety of the NFTs: there is no owner, no pause and no upgrade. Only `unstake`, by the wallet that staked, ever
///  moves an NFT out. An NFT sent here with a plain `transferFrom` instead of `stake` cannot be recovered, because
///  nothing records who sent it; `safeTransferFrom` is refused.
contract TapeCodeStaking {
    struct Account {
        uint32 staked; // NFTs staked now
        uint64 updatedAt;
        uint160 points; // settled up to updatedAt
    }

    struct WalletView {
        address wallet;
        address rewardWallet; // receives this wallet's rewards on BNB Chain
        uint256 staked;
        uint256 points;
    }

    IERC721 public immutable nft;

    uint256 public totalStaked;
    uint64 private totalUpdatedAt;
    uint256 private totalSettled;

    mapping(address => Account) private accounts;
    mapping(uint256 => address) public stakerOf;
    mapping(address => uint256[]) private idsByWallet;
    mapping(uint256 => uint256) private indexInWallet;
    mapping(address => address) private chosenRewardWallet;
    address[] private wallets; // every wallet that ever staked
    mapping(address => bool) private known;

    event Staked(address indexed wallet, uint256 indexed id);
    event Unstaked(address indexed wallet, uint256 indexed id);
    event RewardWalletSet(address indexed wallet, address indexed rewardWallet);

    error ZeroAddress();
    error NothingToDo();
    error NotOwner();
    error NotStaker();
    error SetRewardWalletFirst();

    constructor(address nft_) {
        if (nft_ == address(0)) revert ZeroAddress();
        nft = IERC721(nft_);
    }

    // ------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------

    /// @notice Needs setApprovalForAll on the NFT first. A smart-contract wallet may not exist at the same address on
    ///         BNB Chain, so it must choose where its rewards go before staking (`setRewardWallet`).
    function stake(uint256[] calldata ids) external {
        if (ids.length == 0) revert NothingToDo();
        if (chosenRewardWallet[msg.sender] == address(0) && _isContract(msg.sender)) revert SetRewardWalletFirst();
        _settle(msg.sender);
        if (!known[msg.sender]) {
            known[msg.sender] = true;
            wallets.push(msg.sender);
        }
        uint256[] storage list = idsByWallet[msg.sender];
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (nft.ownerOf(id) != msg.sender) revert NotOwner();
            stakerOf[id] = msg.sender;
            indexInWallet[id] = list.length;
            list.push(id);
            emit Staked(msg.sender, id);
            nft.transferFrom(msg.sender, address(this), id);
        }
        accounts[msg.sender].staked += uint32(ids.length);
        totalStaked += ids.length;
    }

    /// @notice Back to the wallet that staked. Points already earned stay and are paid with the next list.
    function unstake(uint256[] calldata ids) external {
        if (ids.length == 0) revert NothingToDo();
        _settle(msg.sender);
        uint256[] storage list = idsByWallet[msg.sender];
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (stakerOf[id] != msg.sender) revert NotStaker();
            delete stakerOf[id];
            uint256 at = indexInWallet[id];
            uint256 last = list[list.length - 1];
            list[at] = last;
            indexInWallet[last] = at;
            list.pop();
            delete indexInWallet[id];
            emit Unstaked(msg.sender, id);
            nft.transferFrom(address(this), msg.sender, id);
        }
        accounts[msg.sender].staked -= uint32(ids.length);
        totalStaked -= ids.length;
    }

    /// @notice Where this wallet's rewards go on BNB Chain. address(0) means the wallet's own address.
    function setRewardWallet(address rewardWallet_) external {
        chosenRewardWallet[msg.sender] = rewardWallet_;
        emit RewardWalletSet(msg.sender, rewardWallet_);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function rewardWalletOf(address wallet) public view returns (address) {
        address chosen = chosenRewardWallet[wallet];
        return chosen == address(0) ? wallet : chosen;
    }

    function stakedOf(address wallet) external view returns (uint256) {
        return accounts[wallet].staked;
    }

    function idsOf(address wallet) external view returns (uint256[] memory) {
        return idsByWallet[wallet];
    }

    function pointsOf(address wallet) public view returns (uint256) {
        Account storage a = accounts[wallet];
        return a.points + uint256(a.staked) * (block.timestamp - a.updatedAt);
    }

    function totalPoints() public view returns (uint256) {
        return totalSettled + totalStaked * (block.timestamp - totalUpdatedAt);
    }

    function walletCount() external view returns (uint256) {
        return wallets.length;
    }

    /// @notice Wallets `start` to `start + count` (fewer at the end of the list), for building a payout list.
    function walletsPage(uint256 start, uint256 count) external view returns (WalletView[] memory out) {
        uint256 n = wallets.length;
        if (start >= n) return out;
        if (count > n - start) count = n - start;
        out = new WalletView[](count);
        for (uint256 i; i < count; ++i) {
            address w = wallets[start + i];
            out[i] = WalletView(w, rewardWalletOf(w), accounts[w].staked, pointsOf(w));
        }
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _settle(address wallet) private {
        Account storage a = accounts[wallet];
        a.points = uint160(pointsOf(wallet));
        a.updatedAt = uint64(block.timestamp);
        totalSettled = totalPoints();
        totalUpdatedAt = uint64(block.timestamp);
    }

    /// @dev An EIP-7702 delegated account (0xef0100 + address, 23 bytes) is still a key-held wallet: same address everywhere.
    function _isContract(address a) private view returns (bool) {
        bytes memory code = a.code;
        if (code.length == 0) return false;
        return !(code.length == 23 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00);
    }
}
