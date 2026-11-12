// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AurumToken} from "../src/AurumToken.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {DeskPot} from "../src/DeskPot.sol";
import {PotDeploy} from "./utils/PotDeploy.sol";
import {DeskMinter, ITapeoutCPU} from "../src/DeskMinter.sol";
import {ChipSwap} from "../src/ChipSwap.sol";
import {TapeCodeRewards} from "../src/TapeCodeRewards.sol";

interface ITapeoutFactory {
    function createCPU(string calldata, string calldata, string calldata, uint256 supplyCap, uint256 mintPrice) external payable;
    function deployFee() external view returns (uint256);
    function cpuCount() external view returns (uint256);
    function cpuAt(uint256) external view returns (address);
}

interface ITapeoutChips {
    function mint(uint256 id, uint256 amount) external payable;
    function protocolFee() external view returns (uint256);
}

interface ITapeoutCircuits {
    function circuitInfo(uint256) external view returns (uint256 inputs, uint256 outputs, uint256 latches, uint256 gates);
}

interface IRouterV2 {
    function factory() external view returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
    function addLiquidityETH(address, uint256, uint256, uint256, address, uint256) external payable returns (uint256, uint256, uint256);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256, address[] calldata, address, uint256) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256, uint256, address[] calldata, address, uint256) external;
    function swapExactTokensForETH(uint256, uint256, address[] calldata, address, uint256) external returns (uint256[] memory);
}

interface IFactoryV2 {
    function createPair(address, address) external returns (address);
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory) external returns (uint256, uint160, uint32, uint256);
}

interface IRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

/// @notice AURUM against real PancakeSwap V2 (AURUM pool), real PancakeSwap V3 (BEM/WBNB 1% pool) and the
///         real BEM token, on a BSC mainnet fork. The AURUM processor is created through TapeOut's real
///         factory, so desks are real TapeOut circuits.
///   FORK_URL=http://127.0.0.1:8545 forge test --match-contract ForkAurum -vv
contract ForkAurumTest is Test {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    address constant V2 = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant V3 = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BEM = 0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a;
    uint24 constant FEE = 10_000;
    address constant BEM_POOL = 0x28B12792F9D81Bd529Bc5572434E861C9EDbBBC2; // PancakeSwap V3 BEM/WBNB 1%
    address constant TAPEOUT_FACTORY = 0x68224F668083c29e9800Be2a646d42d18cedF7e2;
    bytes constant DESK_NETLIST = hex"000000020000030100000400000005000003010000060000000700000200000008000008";

    IRouterV2 router = IRouterV2(V2);
    DeskPot pot;
    AurumToken desk;
    IERC721 nft; // the AURUM CPU
    DeskMinter minter;
    ChipSwap chips;
    IERC1155 elements; // its NAND (0) / LATCH (1)
    address pair;
    address protocol = makeAddr("fork-protocol");
    address olivia = makeAddr("fork-olivia");
    address daniel = makeAddr("fork-daniel");
    address trader = makeAddr("fork-trader");
    bool forked;

    function setUp() public {
        string memory url = vm.envOr("FORK_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;

        vm.deal(address(this), 100 ether);
        ITapeoutFactory f = ITapeoutFactory(TAPEOUT_FACTORY);
        f.createCPU{value: f.deployFee()}("Aurum Desk", "Aurum Core", "fork test", 600, 1); // 100 sets
        nft = IERC721(f.cpuAt(f.cpuCount() - 1));
        elements = IERC1155(ITapeoutCPU(address(nft)).transistors());
        uint256 fee = ITapeoutChips(address(elements)).protocolFee();
        ITapeoutChips(address(elements)).mint{value: 400 + fee}(0, 400);
        ITapeoutChips(address(elements)).mint{value: 200 + fee}(1, 200);

        pot = PotDeploy.deploy(BEM, V2, V3, BEM_POOL, address(this), protocol);
        desk = new AurumToken("AURUM", "AURUM", 1_000_000_000 ether, address(this), address(pot), V2, address(this));
        minter = new DeskMinter(DeskMinter.Config(address(nft), 0, 1, 4, 2, DESK_NETLIST, 2, 1), address(this));
        ChipSwap.Element[] memory set = new ChipSwap.Element[](2);
        set[0] = ChipSwap.Element(address(elements), 0, 4);
        set[1] = ChipSwap.Element(address(elements), 1, 2);
        chips = new ChipSwap(address(desk), BEM, address(pot), protocol, set, address(this));
        elements.safeTransferFrom(address(this), address(chips), 0, 400, "");
        elements.safeTransferFrom(address(this), address(chips), 1, 200, "");
        pot.wire(address(desk), address(nft), address(minter), address(chips));

        pair = IFactoryV2(router.factory()).createPair(address(desk), WBNB);
        desk.setTaxExempt(address(this), true);
        desk.setPair(pair);
        desk.approve(V2, type(uint256).max);
        router.addLiquidityETH{value: 20 ether}(address(desk), 400_000_000 ether, 0, 0, address(this), block.timestamp);

        vm.deal(olivia, 20 ether);
        vm.deal(daniel, 20 ether);
        vm.deal(trader, 50 ether);
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _buyDesk(address who, uint256 bnb) internal {
        vm.prank(who);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: bnb}(0, _path(WBNB, address(desk)), who, block.timestamp);
    }

    function _buyBem(address who, uint256 bnb) internal returns (uint256) {
        IRouterV3.ExactInputSingleParams memory p = IRouterV3.ExactInputSingleParams(WBNB, BEM, FEE, who, block.timestamp, bnb, 0, 0);
        vm.prank(who);
        return IRouterV3(V3).exactInputSingle{value: bnb}(p);
    }

    function _mintAndStake(address who) internal returns (uint256 id) {
        _buyDesk(who, 0.3 ether); // ~ enough AURUM (buys are untaxed)
        _buyBem(who, 0.05 ether); // ~1.8 BEM
        vm.startPrank(who);
        desk.approve(address(chips), type(uint256).max);
        IERC20(BEM).approve(address(chips), type(uint256).max);
        chips.swap(1); // 100,000 AURUM + 1 BEM -> 4 NAND + 2 LATCH
        elements.setApprovalForAll(address(minter), true);
        id = minter.mint{value: minter.tapeoutFee()}();
        nft.setApprovalForAll(address(pot), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        pot.stake(ids);
        vm.stopPrank();
    }

    function _quoteBem(uint256 bnb) internal returns (uint256 out) {
        (out,,,) = IQuoterV2(QUOTER).quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams(WBNB, BEM, bnb, FEE, 0));
    }

    function test_fork_buyFree_sellTax5pct_onRealPancake() public {
        if (!forked) return;
        uint256 quoted = router.getAmountsOut(1 ether, _path(WBNB, address(desk)))[1];
        _buyDesk(trader, 1 ether);
        assertEq(desk.balanceOf(trader), quoted, "buys are untaxed");
        assertEq(desk.balanceOf(address(desk)), 0);

        uint256 sellAmt = desk.balanceOf(trader) / 2;
        vm.startPrank(trader);
        desk.approve(V2, type(uint256).max);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(sellAmt, 0, _path(address(desk), WBNB), trader, block.timestamp);
        assertEq(desk.balanceOf(address(desk)), sellAmt * 500 / 10_000, "5% of the sell waits in the token");
        assertEq(pot.totalTaxBnb(), 0);
        uint256 second = desk.balanceOf(trader) / 4;
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(second, 0, _path(address(desk), WBNB), trader, block.timestamp);
        vm.stopPrank();
        assertEq(desk.balanceOf(address(desk)), second * 500 / 10_000, "the waiting tax was sold inside the next sell");
        assertGt(pot.totalTaxBnb(), 0, "tax arrived in the pot as BNB");
        assertEq(desk.balanceOf(address(pot)), 0, "the pot never holds AURUM");
    }

    function test_fork_plainSellFails_feeOnTransferSellWorks() public {
        if (!forked) return;
        _buyDesk(trader, 1 ether);
        uint256 amt = desk.balanceOf(trader) / 2;
        address[] memory p = _path(address(desk), WBNB);
        vm.startPrank(trader);
        desk.approve(V2, type(uint256).max);
        vm.expectRevert(bytes("Pancake: K"));
        router.swapExactTokensForETH(amt, 0, p, trader, block.timestamp);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(amt, 0, p, trader, block.timestamp);
        vm.stopPrank();
    }

    /// Full loop on real markets: trading tax -> BNB -> 0.03 threshold -> real BEM bought on V3 -> desks claim.
    function test_fork_fullLoop_realBemBuyback_andClaims() public {
        if (!forked) return;
        uint256 a = _mintAndStake(olivia);
        uint256 b = _mintAndStake(daniel);
        // daniel's chip purchase already ran a round by itself (olivia's desk was waiting); an hour later anyone
        // runs the next one, which activates daniel's desk too
        vm.warp(block.timestamp + 1 hours);
        pot.poke();

        // trading volume: buys and sells by a trader
        for (uint256 i; i < 4; ++i) _buyDesk(trader, 2 ether);
        vm.startPrank(trader);
        desk.approve(V2, type(uint256).max);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(desk.balanceOf(trader) / 2, 0, _path(address(desk), WBNB), trader, block.timestamp);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(desk.balanceOf(trader) / 10, 0, _path(address(desk), WBNB), trader, block.timestamp);
        vm.stopPrank();

        uint256 out = pot.totalTaxBnb(); // the first sell's tax was sold for BNB inside the second sell
        assertGt(out, 0);
        assertEq(protocol.balance, 0, "nothing is shared before the round");
        assertEq(pot.taxBnb(), out, "the whole tax waits for the round");
        assertGe(pot.taxBnb(), pot.ROUND_THRESHOLD(), "enough tax for a round");

        uint256 toBuy = (pot.taxBnb() * 3) / 10; // no NFT Staking Pool here: 2/5 to the protocol, half of the rest buys BEM
        uint256 bemQuote = _quoteBem(toBuy);
        uint256 aBem0 = pot.claimable(a, 1); // olivia was eligible one round earlier: she alone got the 1.2 chip-set BEM
        uint256 bBem0 = pot.claimable(b, 1);
        vm.warp(block.timestamp + 1 hours); // rounds run at most hourly; the contract prices the buy itself
        pot.poke();
        assertGe(pot.totalBemBought(), bemQuote * 97 / 100, "real BEM bought on PancakeSwap V3 at a fair price");
        assertEq(pot.buybackBnb(), 0);

        uint256 bemEach = pot.claimable(a, 1);
        assertEq(bemEach - aBem0, pot.claimable(b, 1) - bBem0, "equal share of the bought BEM per desk");
        assertGt(pot.claimable(a, 0), 0);

        uint256 before = IERC20(BEM).balanceOf(olivia);
        vm.prank(olivia);
        pot.claim(a, 1, type(uint256).max);
        assertEq(IERC20(BEM).balanceOf(olivia) - before, bemEach, "real BEM arrives in the wallet");
        uint256 bnbBefore = daniel.balance;
        uint256 bnbOwed = pot.claimable(b, 0);
        vm.prank(daniel);
        pot.claim(b, 0, bnbOwed);
        assertEq(daniel.balance - bnbBefore, bnbOwed);

        assertGe(address(pot).balance, pot.reserved(0) + pot.carry(0) + pot.taxBnb() + pot.buybackBnb() + pot.directBnb());
        assertGe(IERC20(BEM).balanceOf(address(pot)), pot.reserved(1) + pot.carry(1) + pot.mintBemPending());
    }

    function test_fork_deskIsARealTapeoutCircuit() public {
        if (!forked) return;
        uint256 id = _mintAndStake(olivia);
        (uint256 inputs, uint256 outputs, uint256 latches, uint256 gates) = ITapeoutCircuits(address(nft)).circuitInfo(id);
        assertEq(inputs, 2);
        assertEq(outputs, 1);
        assertEq(latches, 2, "2 LATCH");
        assertEq(gates, 6, "4 NAND + 2 LATCH");
        assertTrue(minter.isDesk(id));
        assertEq(nft.ownerOf(id), address(pot), "staked");
        assertEq(elements.balanceOf(address(minter), 0) + elements.balanceOf(address(minter), 1), 0, "tape-out burned the set");
    }

    /// On the real TapeOut contract: chips from ChipSwap, taped out straight on the processor. One set makes one desk.
    function test_fork_circuitTapedOutDirectly_isADesk_smallerOnesAreNot() public {
        if (!forked) return;
        vm.deal(olivia, 20 ether);
        _buyDesk(olivia, 2 ether);
        _buyBem(olivia, 0.2 ether);
        vm.startPrank(olivia);
        desk.approve(address(chips), type(uint256).max);
        IERC20(BEM).approve(address(chips), type(uint256).max);
        chips.swap(4);
        ITapeoutCPU cpu = ITapeoutCPU(address(nft));
        uint256 fee = cpu.TAPEOUT_FEE();
        nft.setApprovalForAll(address(pot), true);
        uint256[] memory ids = new uint256[](1);

        cpu.tapeout{value: fee}(DESK_NETLIST, 2, 1); // the same circuit as the minter's
        uint256 same = cpu.nextId();
        assertEq(nft.ownerOf(same), olivia);
        assertTrue(minter.isDesk(same));
        ids[0] = same;
        pot.stake(ids);
        assertEq(nft.ownerOf(same), address(pot));

        bytes memory other = DESK_NETLIST;
        other[other.length - 1] = 0x07;
        cpu.tapeout{value: fee}(other, 2, 1); // same chips, other wiring
        ids[0] = cpu.nextId();
        assertTrue(minter.isDesk(ids[0]));
        pot.stake(ids);

        cpu.tapeout{value: fee}(hex"00000002000003", 2, 1); // 1 NAND
        ids[0] = cpu.nextId();
        assertFalse(minter.isDesk(ids[0]));
        vm.expectRevert(DeskPot.NotADesk.selector);
        pot.stake(ids);
        cpu.tapeout{value: fee}(hex"000000020000030100000400000005000003000000060000020000000700000300000008000002", 2, 1); // 5 NAND + 1 LATCH: six gates too
        ids[0] = cpu.nextId();
        assertFalse(minter.isDesk(ids[0]));
        vm.stopPrank();
        assertFalse(minter.isDesk(type(uint128).max), "a circuit that does not exist");
    }

    /// The smallest distribution: 0.03 BNB of tax -> 0.006 BNB to the NFT Staking Pool, 0.012 BNB to the protocol, 0.006 BNB to the desks, 0.006 BNB
    /// of real BEM on the real pool.
    function test_fork_minimumRound_sharesTheTax() public {
        if (!forked) return;
        TapeCodeRewards rewards = new TapeCodeRewards(address(this));
        pot.setTapeCodeRewards(address(rewards));
        uint256 id = _mintAndStake(olivia);
        pot.poke();
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(pot).call{value: 0.03 ether}(""); // exactly the threshold
        assertTrue(ok);
        uint256 q = _quoteBem(0.006 ether);
        assertGt(q, 0, "0.006 BNB buys some BEM on the real pool");
        vm.warp(block.timestamp + 1 hours);
        pot.poke();
        assertEq(address(rewards).balance, 0.006 ether, "1% of the 5%");
        assertEq(protocol.balance, 0.012 ether, "2% of the 5% to the protocol");
        assertEq(pot.claimable(id, 0), 0.006 ether, "1% of the 5% as BNB");
        assertEq(pot.totalBuybackBnbSpent(), 0.006 ether, "1% of the 5% buys BEM");
        assertGe(pot.totalBemBought(), q * 97 / 100);
    }

    /// The TapeCode share on real markets: real sells of AURUM -> 20% of the tax in BNB -> a list pays it as BNB.
    function test_fork_tapeCodeShare_isBnb_andAListPaysIt() public {
        if (!forked) return;
        TapeCodeRewards rewards = new TapeCodeRewards(address(this));
        pot.setTapeCodeRewards(address(rewards));

        _buyDesk(trader, 5 ether);
        uint256 sellAmt = desk.balanceOf(trader) / 4;
        vm.startPrank(trader);
        desk.approve(V2, type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            router.swapExactTokensForETHSupportingFeeOnTransferTokens(sellAmt, 0, _path(address(desk), WBNB), trader, block.timestamp);
        }
        vm.stopPrank();

        uint256 tax = pot.totalTaxBnb();
        assertGt(tax, 0.03 ether, "enough tax for a round");
        assertGt(pot.totalTapeCodeBnb(), 0, "the first round ran inside a sell");
        assertLt(pot.taxBnb(), tax, "what came after it waits for the next round");
        vm.warp(block.timestamp + 1 hours);
        pot.poke();
        assertEq(pot.taxBnb(), 0);
        assertEq(pot.totalTapeCodeBnb(), (tax * 2_000) / 10_000, "20% of the tax");
        assertEq(address(rewards).balance, pot.totalTapeCodeBnb(), "it stays BNB");
        assertEq(protocol.balance, pot.totalProtocolBnb(), "the protocol got its share");
        assertApproxEqAbs(pot.totalProtocolBnb(), 2 * pot.totalTapeCodeBnb(), 2, "2% against 1%, to the wei");
        assertEq(IERC20(BEM).balanceOf(address(rewards)), 0, "no BEM in the NFT Staking Pool");

        uint256 total = rewards.available();
        uint256 toOlivia = total / 3;
        uint256 toDaniel = total - toOlivia;
        bytes32 la = rewards.leaf(0, olivia, toOlivia);
        bytes32 lb = rewards.leaf(0, daniel, toDaniel);
        bytes32 root = la < lb ? keccak256(abi.encodePacked(la, lb)) : keccak256(abi.encodePacked(lb, la));
        rewards.publish(root, total, 0, uint64(block.timestamp), "list");
        bytes32[] memory proof = new bytes32[](1);
        uint256 oliviaBefore = olivia.balance;
        uint256 danielBefore = daniel.balance;
        proof[0] = lb;
        vm.prank(trader);
        rewards.pay(0, olivia, toOlivia, proof);
        proof[0] = la;
        rewards.pay(0, daniel, toDaniel, proof);
        assertEq(olivia.balance - oliviaBefore, toOlivia);
        assertEq(daniel.balance - danielBefore, toDaniel);
        assertEq(rewards.promised(), 0);
    }
}
