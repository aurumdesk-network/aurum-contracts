// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AurumToken} from "../src/AurumToken.sol";
import {DeskPot} from "../src/DeskPot.sol";
import {PotDeploy} from "./utils/PotDeploy.sol";
import {DeskMinter} from "../src/DeskMinter.sol";
import {ChipSwap} from "../src/ChipSwap.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockBEM, MockToken, MockWBNB, MockChips, MockTapeoutCPU, MockV2Router, MockV3Router, MockV3Pool} from "./mocks/Mocks.sol";

/// @notice Covers the test checklist of the AURUM spec (section 10) plus the staking decisions.
contract AurumTest is Test {
    using stdStorage for StdStorage;

    uint256 constant ONE_BEM = 1e8;
    uint256 constant BEM_PER_BNB = 36.8e8; // ~0.0272 BNB per BEM, close to the real market
    uint256 constant DESK_PRICE = 2e12; // BNB per 1e18 AURUM in the mock market (1 AURUM = 0.000002 BNB)
    uint256 constant NAND = 0; // ids on a real TapeOut transistors contract
    uint256 constant LATCH = 1;
    uint256 constant FEE = 0.0002 ether; // tape-out fee
    // the desk circuit: 2 inputs, 1 output, 4 NAND + 2 LATCH (same bytes the fork test tapes out on the real CPU)
    bytes constant DESK_NETLIST = hex"000000020000030100000400000005000003010000060000000700000200000008000008";
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    MockWBNB wbnb;
    MockBEM bem;
    MockV2Router v2;
    MockV3Router v3;
    MockV3Pool v3pool; // the BEM/WBNB pool whose price and 30-minute average guard the buyback
    MockChips elements; // the AURUM CPU's NAND/LATCH
    DeskPot pot;
    AurumToken desk;
    MockTapeoutCPU nft; // the AURUM CPU: desks are its circuits
    DeskMinter minter;
    ChipSwap chips;

    address admin = address(this);
    address team = makeAddr("team-liquidity");
    address protocol = makeAddr("protocol-treasury");
    address pair = makeAddr("pancake-pair");
    address emily = makeAddr("emily");
    address marcus = makeAddr("marcus");
    address priya = makeAddr("priya");
    address jake = makeAddr("jake");

    function setUp() public {
        wbnb = new MockWBNB();
        bem = new MockBEM();
        v2 = new MockV2Router(address(wbnb));
        v3 = new MockV3Router(address(wbnb), address(bem));
        v3.setRate(BEM_PER_BNB);
        v3pool = new MockV3Pool(address(bem), address(wbnb));
        v3pool.setPrice(_sqrtPriceFor(BEM_PER_BNB));
        deal(address(wbnb), address(v3pool), 1_000 ether); // deep pool: the 1% buy cap does not bind
        nft = new MockTapeoutCPU();
        elements = nft.transistors();

        pot = PotDeploy.deploy(address(bem), address(v2), address(v3), address(v3pool), admin, protocol);
        desk = new AurumToken("AURUM", "AURUM", 1_000_000_000 ether, team, address(pot), address(v2), admin);
        minter = new DeskMinter(DeskMinter.Config(address(nft), NAND, LATCH, 4, 2, DESK_NETLIST, 2, 1), admin);
        ChipSwap.Element[] memory set = new ChipSwap.Element[](2);
        set[0] = ChipSwap.Element(address(elements), NAND, 4);
        set[1] = ChipSwap.Element(address(elements), LATCH, 2);
        chips = new ChipSwap(address(desk), address(bem), address(pot), protocol, set, admin);
        elements.mint(address(chips), NAND, 4 * 100); // project stock for 100 desks
        elements.mint(address(chips), LATCH, 2 * 100);
        pot.wire(address(desk), address(nft), address(minter), address(chips));

        desk.setPair(pair);
        desk.setTaxExempt(team, true);
        desk.setSwapThreshold(1); // sell any collected tax at the next sell, so small test amounts are exact
        vm.prank(team);
        desk.transfer(pair, 300_000_000 ether); // pool liquidity, seeded tax-free by the exempt team wallet
        v2.setSellRate(address(desk), DESK_PRICE);
        vm.deal(address(v2), 1_000 ether);
        vm.deal(emily, 100 ether);
        vm.deal(marcus, 100 ether);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _fund(address who) internal {
        vm.prank(team);
        desk.transfer(who, 100_000 ether); // wallet to wallet: untaxed
        bem.mint(who, ONE_BEM);
    }

    /// Step 1: 100,000 AURUM + 1 BEM -> 4 NAND + 2 LATCH.
    function _swap(address who) internal {
        vm.startPrank(who);
        desk.approve(address(chips), type(uint256).max);
        bem.approve(address(chips), type(uint256).max);
        chips.swap(1);
        vm.stopPrank();
    }

    /// Step 2: the chip set + tape-out fee -> desk circuit.
    function _mint(address who) internal returns (uint256 id) {
        _fund(who);
        _swap(who);
        vm.deal(who, who.balance + FEE);
        vm.startPrank(who);
        elements.setApprovalForAll(address(minter), true);
        id = minter.mint{value: FEE}();
        vm.stopPrank();
    }

    function _stake(address who, uint256 id) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.startPrank(who);
        nft.setApprovalForAll(address(pot), true); // the wallet's one-time approval before staking
        pot.stake(ids);
        vm.stopPrank();
    }

    function _unstake(address who, uint256 id) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(who);
        pot.unstake(ids);
    }

    function _mintAndStake(address who) internal returns (uint256 id) {
        id = _mint(who);
        _stake(who, id);
    }

    /// Simulates trading tax worth `bnb` reaching the Desk Pot: AURUM tax collects in the token, which sells it for BNB.
    function _tax(uint256 bnb) internal {
        uint256 deskAmount = (bnb * 1 ether) / DESK_PRICE;
        vm.prank(team);
        desk.transfer(address(desk), deskAmount);
        desk.swapTaxes(); // one sale sells all of it
    }

    /// An hour later, anyone runs the round.
    function _round() internal {
        vm.warp(block.timestamp + 1 hours);
        pot.poke();
    }

    /// The pool's sqrt price (Q64.96, token1 per token0) for `bemPerBnb` BEM units per 1e18 wei.
    function _sqrtPriceFor(uint256 bemPerBnb) internal view returns (uint160) {
        if (address(bem) < address(wbnb)) return uint160(Math.sqrt(Math.mulDiv(1 ether, 1 << 192, bemPerBnb)));
        return uint160(Math.sqrt(Math.mulDiv(bemPerBnb, 1 << 192, 1 ether)));
    }

    function _assertSolvent() internal view {
        assertGe(address(pot).balance, pot.reserved(0) + pot.carry(0) + pot.taxBnb() + pot.buybackBnb() + pot.directBnb(), "BNB solvency");
        assertGe(bem.balanceOf(address(pot)), pot.reserved(1) + pot.carry(1) + pot.mintBemPending(), "BEM solvency");
    }

    // ------------------------------------------------------------------
    // AURUM token
    // ------------------------------------------------------------------

    function test_desk_supplyIsFixed() public view {
        assertEq(desk.totalSupply(), 1_000_000_000 ether);
    }

    function test_desk_buyFree_sellTax5pct_walletFree() public {
        vm.prank(pair); // a PancakeSwap buy: the pair sends AURUM out, no tax
        desk.transfer(emily, 1_000 ether);
        assertEq(desk.balanceOf(emily), 1_000 ether);
        assertEq(desk.balanceOf(address(desk)), 0);

        vm.prank(emily); // a sell: 5% of it waits in the token
        desk.transfer(pair, 500 ether);
        assertEq(desk.balanceOf(address(desk)), 25 ether, "5% sell tax waits for the next sale");
        assertEq(pot.totalTaxBnb(), 0);

        vm.prank(emily); // the next sell first turns the waiting 25 AURUM into BNB for the Desk Pot
        desk.transfer(pair, 100 ether);
        assertEq(pot.totalTaxBnb(), 25 ether * DESK_PRICE / 1 ether, "the Desk Pot received BNB, never AURUM");
        assertEq(desk.balanceOf(address(desk)), 5 ether, "this sell's 5% waits");
        assertEq(desk.balanceOf(address(pot)), 0);

        vm.prank(emily); // wallet to wallet
        desk.transfer(marcus, 100 ether);
        assertEq(desk.balanceOf(marcus), 100 ether);
        assertEq(desk.balanceOf(address(desk)), 5 ether);
    }

    function testFuzz_desk_taxConservesTokens(uint256 amount, bool isBuy) public {
        uint256 supply = desk.totalSupply();
        if (isBuy) {
            amount = bound(amount, 0, desk.balanceOf(pair));
            vm.prank(pair);
            desk.transfer(emily, amount);
            assertEq(desk.balanceOf(emily), amount, "buys are untaxed");
            assertEq(desk.balanceOf(address(desk)), 0);
        } else {
            vm.prank(team);
            desk.transfer(emily, 1_000_000 ether);
            amount = bound(amount, 0, 1_000_000 ether);
            uint256 before = desk.balanceOf(pair);
            vm.prank(emily);
            desk.transfer(pair, amount);
            assertEq(desk.balanceOf(pair) - before + desk.balanceOf(address(desk)), amount);
            assertEq(desk.balanceOf(address(desk)), amount * 500 / 10_000);
        }
        assertEq(desk.totalSupply(), supply);
    }

    function test_desk_extraTaxedPools_mainPairPermanent() public {
        address v3DeskPot = makeAddr("desk-v3-pool");
        vm.prank(team);
        desk.transfer(v3DeskPot, 1_000 ether); // untaxed: not a pool yet
        assertEq(desk.balanceOf(v3DeskPot), 1_000 ether);

        desk.setTaxedPool(v3DeskPot, true); // someone opened another pool: tax it too
        vm.prank(team);
        desk.transfer(emily, 1_000 ether);
        vm.prank(emily);
        desk.transfer(v3DeskPot, 1_000 ether); // a sell into the other pool pays 5%
        assertEq(desk.balanceOf(v3DeskPot), 1_000 ether + 950 ether);
        vm.prank(v3DeskPot);
        desk.transfer(marcus, 100 ether); // buys stay free
        assertEq(desk.balanceOf(marcus), 100 ether);

        vm.expectRevert(AurumToken.MainPair.selector);
        desk.setTaxedPool(pair, false);
        vm.prank(emily);
        vm.expectRevert();
        desk.setTaxedPool(makeAddr("x"), true);
    }

    function test_desk_poolsCannotBeExempt() public {
        vm.expectRevert(AurumToken.PoolCannotBeExempt.selector);
        desk.setTaxExempt(pair, true);
        address other = makeAddr("other-pool");
        desk.setTaxExempt(other, true);
        desk.setTaxedPool(other, true); // becoming a taxed pool drops the exemption
        assertFalse(desk.isTaxExempt(other));
        vm.expectRevert(AurumToken.PoolCannotBeExempt.selector);
        desk.setTaxExempt(other, true);
    }

    function test_desk_pairIsOneTime_andOnlyOwnerManagesExemptions() public {
        vm.expectRevert(AurumToken.PairAlreadySet.selector);
        desk.setPair(makeAddr("other"));
        vm.prank(emily);
        vm.expectRevert();
        desk.setTaxExempt(emily, true);
    }

    // ------------------------------------------------------------------
    // Mint
    // ------------------------------------------------------------------

    function test_mint_tapesOutCircuit_burnsChips() public {
        uint256 id = _mint(emily);
        assertEq(id, 1);
        assertEq(nft.ownerOf(1), emily, "the desk is a circuit of the AURUM CPU");
        assertTrue(minter.isDesk(1));
        assertEq(minter.desks(0), 1);
        assertEq(keccak256(nft.netlist(1)), keccak256(DESK_NETLIST));
        assertEq(elements.balanceOf(emily, NAND), 0);
        assertEq(elements.balanceOf(address(minter), NAND), 0, "the tape-out burned the chips");
        assertEq(elements.balanceOf(address(minter), LATCH), 0);
        assertEq(address(nft).balance, FEE, "tape-out fee paid to the CPU");
    }

    function test_mint_refundsExtraBnb_andNeedsTheFee() public {
        _fund(emily);
        _swap(emily);
        vm.startPrank(emily);
        elements.setApprovalForAll(address(minter), true);
        vm.expectRevert(DeskMinter.FeeTooLow.selector);
        minter.mint{value: FEE - 1}();
        uint256 before = emily.balance;
        minter.mint{value: 1 ether}();
        vm.stopPrank();
        assertEq(before - emily.balance, FEE);
    }

    function test_mint_failsWithoutChips() public {
        vm.deal(emily, 1 ether);
        vm.startPrank(emily);
        elements.setApprovalForAll(address(minter), true);
        vm.expectRevert(); // no chips yet
        minter.mint{value: FEE}();
        vm.stopPrank();
        _fund(emily);
        _swap(emily);
        vm.startPrank(emily);
        elements.safeTransferFrom(emily, marcus, LATCH, 1, ""); // one LATCH short
        vm.expectRevert();
        minter.mint{value: FEE}();
        vm.stopPrank();
        assertEq(minter.totalMinted(), 0);
    }

    /// Chips from the swap, taped out straight on the CPU, skipping the minter.
    function _tapeoutDirectly(address who, bytes memory net) internal returns (uint256 id) {
        vm.deal(who, 1 ether);
        vm.prank(who);
        nft.tapeout{value: FEE}(net, 2, 1);
        id = nft.nextId();
    }

    function _chips(address who, uint256 sets) internal {
        for (uint256 i; i < sets; ++i) {
            _fund(who);
            _swap(who);
        }
    }

    function _stakeExpectingNotADesk(address who, uint256 id) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.startPrank(who);
        nft.setApprovalForAll(address(pot), true);
        vm.expectRevert(DeskPot.NotADesk.selector);
        pot.stake(ids);
        vm.stopPrank();
        assertFalse(minter.isDesk(id));
    }

    function test_circuitTapedOutDirectly_stakesAndEarnsLikeAnyDesk() public {
        uint256 mine = _mintAndStake(emily);
        _chips(jake, 1);
        uint256 direct = _tapeoutDirectly(jake, DESK_NETLIST);
        assertTrue(minter.isDesk(direct));
        assertEq(elements.balanceOf(jake, NAND), 0, "it cost a whole set");
        assertEq(elements.balanceOf(jake, LATCH), 0);
        _stake(jake, direct);
        _round(); // both eligible now
        _tax(0.05 ether);
        _round();
        assertGt(pot.claimable(direct, 0), 0);
        assertEq(pot.claimable(direct, 0), pot.claimable(mine, 0), "the same share as a desk minted here");
        assertEq(pot.claimable(direct, 1), pot.claimable(mine, 1) , "BEM too");
        uint256 before = jake.balance;
        uint256 owed = pot.claimable(direct, 0);
        vm.prank(jake);
        pot.claim(direct, 0, owed);
        assertEq(jake.balance - before, owed);
    }

    function test_sameChips_otherWiring_isADesk() public {
        _chips(jake, 1);
        bytes memory other = DESK_NETLIST;
        other[other.length - 1] = 0x07; // the last NAND reads another signal
        uint256 id = _tapeoutDirectly(jake, other);
        assertTrue(minter.isDesk(id));
        _stake(jake, id);
        assertEq(pot.pendingDesks(), 1);
    }

    function test_oneChipSet_cannotBecomeManyDesks() public {
        _chips(jake, 1);
        for (uint256 i; i < 4; ++i) _stakeExpectingNotADesk(jake, _tapeoutDirectly(jake, hex"00000002000003")); // 1 NAND each
        _stakeExpectingNotADesk(jake, _tapeoutDirectly(jake, hex"01000002"));
        _stakeExpectingNotADesk(jake, _tapeoutDirectly(jake, hex"01000002"));
        assertEq(elements.balanceOf(jake, NAND), 0);
        assertEq(elements.balanceOf(jake, LATCH), 0);
        assertEq(pot.pendingDesks(), 0);
    }

    function test_otherChipCounts_areNotDesks() public {
        _chips(jake, 3);
        _stakeExpectingNotADesk(jake, _tapeoutDirectly(jake, hex"000000020000030100000400000005000003000000060000020000000700000300000008000002")); // 5 + 1: six gates too
        _stakeExpectingNotADesk(jake, _tapeoutDirectly(jake, bytes.concat(DESK_NETLIST, hex"00000002000003"))); // 5 + 2
        assertFalse(minter.isDesk(999_999), "a circuit that does not exist");
    }

    // ------------------------------------------------------------------
    // ChipSwap: 100,000 AURUM + 1 BEM -> 4 NAND + 2 LATCH
    // ------------------------------------------------------------------

    function test_chipSwap_burnsDesk_splitsBem_handsOutSet() public {
        _fund(emily);
        uint256 supply = desk.totalSupply();
        _swap(emily);
        assertEq(supply - desk.totalSupply(), 100_000 ether, "100,000 AURUM burned");
        assertEq(desk.balanceOf(emily), 0);
        assertEq(bem.balanceOf(emily), 0);
        assertEq(bem.balanceOf(address(pot)), 0.6e8, "0.6 BEM to the pot");
        assertEq(bem.balanceOf(DEAD), 0.2e8, "0.2 BEM burned");
        assertEq(bem.balanceOf(protocol), 0.2e8, "0.2 BEM to the protocol");
        assertEq(pot.mintBemPending(), 0.6e8);
        assertEq(chips.totalBemBurned(), 0.2e8);
        assertEq(elements.balanceOf(emily, NAND), 4);
        assertEq(elements.balanceOf(emily, LATCH), 2);
        assertEq(chips.setsLeft(), 99);
        assertEq(chips.totalSets(), 1);
    }

    function test_chipSwap_severalSets() public {
        vm.prank(team);
        desk.transfer(emily, 300_000 ether);
        bem.mint(emily, 3 * ONE_BEM);
        vm.startPrank(emily);
        desk.approve(address(chips), type(uint256).max);
        bem.approve(address(chips), type(uint256).max);
        chips.swap(3);
        vm.stopPrank();
        assertEq(elements.balanceOf(emily, NAND), 12);
        assertEq(elements.balanceOf(emily, LATCH), 6);
        assertEq(desk.balanceOf(emily), 0);
        assertEq(pot.mintBemPending(), 3 * 0.6e8);
    }

    function test_chipSwap_needsDeskBem_andStock() public {
        vm.prank(team);
        desk.transfer(emily, 99_999 ether);
        bem.mint(emily, ONE_BEM);
        vm.startPrank(emily);
        desk.approve(address(chips), type(uint256).max);
        bem.approve(address(chips), type(uint256).max);
        vm.expectRevert(); // one AURUM short
        chips.swap(1);
        vm.stopPrank();
        vm.prank(team);
        desk.transfer(emily, 1 ether);
        vm.prank(emily);
        bem.transfer(marcus, 1);
        vm.prank(emily);
        vm.expectRevert(); // enough AURUM, one BEM unit short
        chips.swap(1);
        vm.startPrank(emily);
        vm.expectRevert(ChipSwap.ZeroSets.selector);
        chips.swap(0);
        vm.expectRevert(ChipSwap.OutOfStock.selector);
        chips.swap(101);
        vm.stopPrank();
    }

    function test_chipSwap_stockLimitedByScarcestElement_andWithdrawOnlyOwner() public {
        chips.withdraw(address(elements), LATCH, 2 * 97, team); // LATCH left for 3 sets, NAND for 100
        assertEq(chips.setsLeft(), 3);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, emily));
        vm.prank(emily);
        chips.withdraw(address(elements), NAND, 4, emily);
    }

    function test_chipsAreTransferable_anyHolderCanMint() public {
        _fund(emily);
        _swap(emily);
        vm.startPrank(emily);
        elements.safeTransferFrom(emily, marcus, NAND, 4, "");
        elements.safeTransferFrom(emily, marcus, LATCH, 2, "");
        vm.stopPrank();
        vm.deal(marcus, 1 ether);
        vm.startPrank(marcus);
        elements.setApprovalForAll(address(minter), true);
        uint256 id = minter.mint{value: FEE}(); // marcus never held AURUM or BEM
        vm.stopPrank();
        assertEq(nft.ownerOf(id), marcus);
    }

    function test_mint_cannotExceed5000() public {
        stdstore.target(address(minter)).sig("totalMinted()").checked_write(uint256(4_999));
        _mint(emily); // #5000
        _fund(marcus);
        _swap(marcus);
        vm.startPrank(marcus);
        elements.setApprovalForAll(address(minter), true);
        vm.expectRevert(DeskMinter.SoldOut.selector);
        minter.mint{value: FEE}();
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Taxes -> BNB
    // ------------------------------------------------------------------

    function test_tax_soldInsideNextSell_waitsInTheDeskPot() public {
        vm.prank(team);
        desk.transfer(address(desk), 10_000 ether); // tax worth 0.02 BNB waiting in the token
        vm.prank(team);
        desk.transfer(emily, 1_000 ether);
        vm.prank(emily);
        desk.transfer(pair, 1_000 ether); // any sell triggers the tax sale
        assertEq(pot.totalTaxBnb(), 0.02 ether);
        assertEq(protocol.balance, 0, "nothing is shared before 0.03 BNB");
        assertEq(pot.taxBnb(), 0.02 ether, "under 0.03 BNB: it waits");
        assertEq(desk.balanceOf(address(desk)), 50 ether, "only the new 5% sell tax waits");
    }

    function test_tax_anyoneCanSwap_sellsAllOfIt() public {
        vm.prank(team);
        desk.transfer(address(desk), 3_000_000 ether); // 1% of the 300M AURUM pair
        vm.prank(jake);
        desk.swapTaxes();
        assertEq(desk.balanceOf(address(desk)), 0, "one sale sells all the collected tax");
        assertEq(pot.totalTaxBnb(), 3_000_000 ether * DESK_PRICE / 1 ether);
    }

    function test_tax_belowThreshold_waits() public {
        desk.setSwapThreshold(10_000 ether);
        vm.prank(team);
        desk.transfer(address(desk), 9_999 ether);
        desk.swapTaxes();
        assertEq(desk.balanceOf(address(desk)), 9_999 ether);
        assertEq(pot.totalTaxBnb(), 0);
        vm.expectRevert(AurumToken.ThresholdTooHigh.selector);
        desk.setSwapThreshold(10_000_001 ether);
    }

    function test_tax_failedSale_neverBlocksTheSell() public {
        vm.deal(address(v2), 0); // the router cannot pay out: the tax sale reverts inside the sell
        vm.prank(team);
        desk.transfer(address(desk), 10_000 ether);
        vm.prank(team);
        desk.transfer(emily, 1_000 ether);
        vm.prank(emily);
        desk.transfer(pair, 1_000 ether); // still goes through
        assertEq(desk.balanceOf(emily), 0);
    }

    function test_tax_pausedPot_keepsBnbInToken_thenForwardsIt() public {
        pot.pause();
        vm.prank(team);
        desk.transfer(address(desk), 10_000 ether);
        desk.swapTaxes(); // sold, but the paused Desk Pot refuses the deposit
        assertEq(address(desk).balance, 0.02 ether);
        assertEq(pot.totalTaxBnb(), 0);
        pot.unpause();
        vm.prank(team);
        desk.transfer(address(desk), 5_000 ether);
        desk.swapTaxes(); // forwards the waiting BNB together with the new sale
        assertEq(address(desk).balance, 0);
        assertEq(pot.totalTaxBnb(), 0.03 ether);
    }

    function test_tax_onlyDeskDeposits() public {
        vm.expectRevert(DeskPot.OnlyDesk.selector);
        pot.depositTax{value: 1 ether}(0);
    }

    // ------------------------------------------------------------------
    // Rounds
    // ------------------------------------------------------------------

    function test_round_belowThreshold_noBnbSplit() public {
        _mintAndStake(emily);
        _round(); // emily becomes eligible; distributes nothing yet (no eligible desk this round)
        _tax(0.029 ether); // under 0.03 BNB
        uint256 before = pot.taxBnb();
        _round(); // distributes nothing from BNB
        assertEq(pot.taxBnb(), before);
        assertEq(pot.buybackBnb(), 0);
        assertEq(pot.claimable(1, 0), 0);
    }

    function test_round_sharesTheTax_protocolTwoFifths_deskPotHalfBnbHalfBem() public {
        uint256 a = _mintAndStake(emily);
        uint256 b = _mintAndStake(marcus);
        _round(); // both eligible now; the 1.2 mint BEM waits for an eligible round? (paid now: 0 eligible -> held)
        _tax(0.05 ether); // no NFT Staking Pool set here: all of it stays in the Desk Pot
        _round();

        assertEq(protocol.balance, 0.02 ether, "2% of the 5% to the protocol");
        uint256 bought = (0.015 ether * BEM_PER_BNB) / 1 ether;
        assertEq(pot.totalBemBought(), bought, "BEM bought with 0.015 BNB");
        assertEq(pot.totalBuybackBnbSpent(), 0.015 ether);
        assertEq(pot.claimable(a, 0), 0.0075 ether, "half of 0.015 BNB each");
        assertEq(pot.claimable(b, 0), 0.0075 ether);
        // BEM: bought + 2 x 0.6 mint BEM, split between the 2 desks
        assertEq(pot.claimable(a, 1), (bought + 1.2e8) / 2);
        assertEq(pot.claimable(a, 1), pot.claimable(b, 1));
        _assertSolvent();
    }

    function test_round_failedBuyback_keepsBnb_paysDirectBnb_retriesLater() public {
        uint256 a = _mintAndStake(emily);
        _round();
        _tax(0.05 ether);
        v3.setBroken(true);
        _round();
        assertEq(pot.buybackBnb(), 0.015 ether, "buyback BNB kept for a retry");
        assertEq(pot.totalBemBought(), 0, "no BEM recorded when the swap failed");
        assertEq(pot.claimable(a, 0), 0.015 ether, "direct BNB still paid");
        _assertSolvent();

        v3.setBroken(false);
        _round();
        assertEq(pot.buybackBnb(), 0);
        assertEq(pot.totalBemBought(), (0.015 ether * BEM_PER_BNB) / 1 ether);
        _assertSolvent();
    }

    function test_round_belowMinimumOut_keepsBnb() public {
        _mintAndStake(emily);
        _round();
        _tax(0.05 ether);
        v3.setRate((BEM_PER_BNB * 90) / 100); // the swap would pay 10% under the pool price
        _round();
        assertEq(pot.buybackBnb(), 0.015 ether);
        assertEq(pot.totalBemBought(), 0);
    }

    function test_round_directBnbNeverSpentOnBuyback() public {
        _mintAndStake(emily);
        _round();
        _tax(0.05 ether);
        v3.setBroken(true);
        _round();
        uint256 directPaid = pot.totalDistributed(0);
        // retry with a working router: only the kept buyback BNB is swapped
        v3.setBroken(false);
        _round();
        assertEq(pot.totalBuybackBnbSpent(), 0.015 ether);
        assertEq(pot.totalDistributed(0), directPaid);
    }

    function test_round_priceOffItsAverage_defersBuy() public {
        uint256 a = _mintAndStake(emily);
        _round();
        _tax(0.05 ether);
        v3pool.setTicks(500, 0); // spot 5% away from the 30-minute average: someone is pushing the price
        _round();
        assertEq(pot.totalBemBought(), 0, "no buy at a manipulated price");
        assertEq(pot.buybackBnb(), 0.015 ether);
        assertEq(pot.claimable(a, 0), 0.015 ether, "direct BNB still paid");
        v3pool.setTicks(150, 0); // within 2%: fine
        _round();
        assertEq(pot.buybackBnb(), 0);
        assertGt(pot.totalBemBought(), 0);
    }

    function test_round_noPriceHistory_defersBuy() public {
        _mintAndStake(emily);
        _round();
        _tax(0.05 ether);
        v3pool.setNoHistory(true);
        _round();
        assertEq(pot.totalBemBought(), 0);
        assertEq(pot.buybackBnb(), 0.015 ether);
    }

    function test_round_buyCappedAtOnePercentOfBemPool() public {
        _mintAndStake(emily);
        _round();
        deal(address(wbnb), address(v3pool), 1 ether); // shallow pool: one buy may spend 0.01 BNB
        _tax(0.05 ether);
        _round();
        assertEq(pot.totalBuybackBnbSpent(), 0.01 ether);
        assertEq(pot.buybackBnb(), 0.005 ether, "the rest waits");
        _round();
        assertEq(pot.totalBuybackBnbSpent(), 0.015 ether);
        assertEq(pot.buybackBnb(), 0);
        _assertSolvent();
    }

    function test_round_buysFailingThreeDays_paidAsBnb() public {
        uint256 a = _mintAndStake(emily);
        _round();
        _tax(0.05 ether);
        v3.setBroken(true);
        _round(); // first failed buy
        assertEq(pot.claimable(a, 0), 0.015 ether);
        vm.warp(block.timestamp + 3 days);
        pot.poke();
        assertEq(pot.buybackBnb(), 0);
        assertEq(pot.claimable(a, 0), 0.03 ether, "the buyback half arrives as BNB");
        assertEq(pot.buybackFailingSince(), 0);
        _assertSolvent();
    }

    function test_round_atMostOncePerHour() public {
        _mintAndStake(emily);
        _round();
        _tax(0.05 ether); // money waiting, but the last round was just now
        vm.expectRevert(DeskPot.NothingToDo.selector);
        pot.poke();
        assertFalse(pot.roundDue());
        vm.warp(block.timestamp + 59 minutes);
        vm.expectRevert(DeskPot.NothingToDo.selector);
        pot.poke();
        vm.warp(block.timestamp + 1 minutes);
        assertTrue(pot.roundDue());
        vm.prank(jake); // anyone may run it
        pot.poke();
        assertEq(pot.taxBnb(), 0);
    }

    function test_round_nothingToDo() public {
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(DeskPot.NothingToDo.selector);
        pot.poke();
    }

    function test_round_runsInsideASell_noKeeper() public {
        uint256 a = _mintAndStake(emily);
        _round(); // a eligible
        vm.warp(block.timestamp + 1 hours);
        uint256 before = pot.rounds();
        vm.prank(team);
        desk.transfer(address(desk), 25_000 ether); // tax worth 0.05 BNB waiting in the token
        vm.prank(team);
        desk.transfer(marcus, 1_000 ether);
        vm.prank(marcus);
        desk.transfer(pair, 1_000 ether); // an ordinary sell: tax sold, deposited, and the due round runs inside it
        assertEq(pot.rounds(), before + 1, "the sell ran the round");
        assertEq(pot.claimable(a, 0), 0.015 ether);
        assertGt(pot.claimable(a, 1), 0, "BEM bought and paid");
    }

    function test_round_runsInsideChipPurchase_andStake() public {
        uint256 a = _mintAndStake(emily);
        _round(); // a eligible; its own 0.6 mint BEM was held (no eligible desk then)
        vm.warp(block.timestamp + 1 hours);
        _fund(marcus);
        _swap(marcus); // the chip purchase brings 0.6 BEM and runs the due round
        assertEq(pot.claimable(a, 1), 1.2e8, "both chip purchases' BEM paid without anyone pressing a button");

        uint256 b = _mint(marcus); // within the hour: no round yet
        _tax(0.05 ether);
        vm.warp(block.timestamp + 1 hours);
        uint256 before = pot.rounds();
        _stake(marcus, b); // the stake runs the due round first; b waits for the next one
        assertEq(pot.rounds(), before + 1);
        assertEq(pot.claimable(b, 0), 0);
        assertFalse(pot.isEligible(b));
    }

    function test_round_neverBlocksASell() public {
        _mintAndStake(emily);
        _round();
        vm.warp(block.timestamp + 1 hours);
        v3.setBroken(true);
        v3pool.setTicks(900, 0);
        vm.prank(team);
        desk.transfer(address(desk), 25_000 ether);
        vm.prank(team);
        desk.transfer(marcus, 1_000 ether);
        vm.prank(marcus);
        desk.transfer(pair, 1_000 ether); // the round inside cannot buy BEM; the sell still goes through
        assertEq(desk.balanceOf(marcus), 0);
        assertEq(pot.buybackBnb(), 0.015 ether);
    }

    // ------------------------------------------------------------------
    // Staking rules    // ------------------------------------------------------------------
    // Staking rules
    // ------------------------------------------------------------------

    function test_mintBem_onlyToStakedDesks_notToItself() public {
        uint256 a = _mintAndStake(emily);
        _round(); // a eligible; 0.6 BEM from a's own mint stays pending (no eligible desk when it arrived? it was paid to 0 desks -> held)
        assertEq(pot.claimable(a, 1), 0, "a did not get its own mint BEM in the round it became eligible");
        uint256 b = _mint(marcus); // not staked
        _round();
        // a gets both pending mint shares (its own held 0.6 + marcus's 0.6); marcus's unstaked desk gets nothing
        assertEq(pot.claimable(a, 1), 1.2e8);
        assertEq(pot.claimable(b, 1), 0);
    }

    function test_antiSniping_stakeJustBeforeRound_earnsNothingFromIt() public {
        uint256 a = _mintAndStake(emily);
        _round(); // a eligible
        _tax(0.05 ether);
        uint256 sniper = _mintAndStake(jake); // stakes right before the round
        _round();
        assertGt(pot.claimable(a, 0), 0);
        assertEq(pot.claimable(sniper, 0), 0, "a desk staked during the epoch earns nothing from that round");
        _unstake(jake, sniper);
        assertEq(pot.claimable(sniper, 0), 0);
        assertEq(pot.pendingDesks() + pot.eligibleDesks(), 1);
    }

    function test_noEligibleDesks_holdsEverything() public {
        _mint(emily); // minted, never staked
        _tax(0.05 ether);
        _round();
        assertEq(pot.totalDistributed(0), 0);
        assertEq(pot.totalDistributed(1), 0);
        assertEq(pot.directBnb() + pot.buybackBnb(), 0.03 ether, "BNB held for later");
        assertEq(pot.mintBemPending(), 0.6e8, "mint BEM held for later");
        _assertSolvent();
    }

    function test_stake_onlyOwner_notApprovedOperator() public {
        uint256 id = _mint(emily);
        vm.prank(emily);
        nft.setApprovalForAll(jake, true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(jake);
        vm.expectRevert(DeskPot.NotOwner.selector);
        pot.stake(ids);
    }

    function test_unstake_onlyStaker_andDirectDepositRejected() public {
        uint256 id = _mintAndStake(emily);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(jake);
        vm.expectRevert(DeskPot.NotStaker.selector);
        pot.unstake(ids);

        uint256 other = _mint(marcus);
        vm.prank(marcus);
        vm.expectRevert(); // safeTransfer straight into the Desk Pot would leave a desk without a staker
        nft.safeTransferFrom(marcus, address(pot), other);
    }

    function test_stakedDesk_cannotBeTransferredBySeller() public {
        uint256 id = _mintAndStake(emily);
        vm.prank(emily);
        vm.expectRevert(); // the Desk Pot holds it
        nft.transferFrom(emily, marcus, id);
    }

    // ------------------------------------------------------------------
    // Vault and claims
    // ------------------------------------------------------------------

    function _paidDesk() internal returns (uint256 id) {
        id = _mintAndStake(emily);
        _round();
        _tax(0.05 ether);
        _round();
    }

    function test_claim_single_partial_repeated_noDoubleSpend() public {
        uint256 id = _paidDesk();
        uint256 bnbOwed = pot.claimable(id, 0);
        uint256 before = emily.balance;

        vm.startPrank(emily);
        pot.claim(id, 0, bnbOwed / 4); // partial
        assertEq(pot.claimable(id, 0), bnbOwed - bnbOwed / 4);
        pot.claim(id, 0, type(uint256).max); // the rest
        assertEq(pot.claimable(id, 0), 0);
        vm.expectRevert(DeskPot.BadAmount.selector);
        pot.claim(id, 0, 1); // nothing left
        vm.stopPrank();
        assertEq(emily.balance - before, bnbOwed);
        assertEq(pot.claimedOf(id, 0), bnbOwed);
        _assertSolvent();
    }

    function test_claim_bemAndBnbIndependent_claimAll() public {
        uint256 id = _paidDesk();
        uint256 bemOwed = pot.claimable(id, 1);
        uint256 bnbOwed = pot.claimable(id, 0);
        vm.prank(emily);
        pot.claim(id, 1, bemOwed);
        assertEq(pot.claimable(id, 0), bnbOwed, "claiming BEM leaves BNB untouched");
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(emily);
        pot.claimAll(ids);
        assertEq(pot.claimable(id, 0), 0);
        assertEq(bem.balanceOf(emily), bemOwed);
    }

    function test_claim_overAmountReverts_andOnlyRightsHolder() public {
        uint256 id = _paidDesk();
        uint256 owed = pot.claimable(id, 0);
        vm.prank(emily);
        vm.expectRevert(DeskPot.BadAmount.selector);
        pot.claim(id, 0, owed + 1);
        vm.prank(jake);
        vm.expectRevert(DeskPot.NotRightsHolder.selector);
        pot.claim(id, 0, 1);
    }

    function test_rewardsFollowNft_afterUnstakeAndSale() public {
        uint256 id = _paidDesk();
        uint256 owed = pot.claimable(id, 0);
        _unstake(emily, id);
        assertEq(pot.claimable(id, 0), owed, "unclaimed rewards stay with the NFT");

        vm.prank(emily);
        nft.transferFrom(emily, marcus, id); // sold
        vm.prank(emily);
        vm.expectRevert(DeskPot.NotRightsHolder.selector);
        pot.claim(id, 0, owed);

        uint256 before = marcus.balance;
        vm.prank(marcus);
        pot.claim(id, 0, owed);
        assertEq(marcus.balance - before, owed, "the new owner claims what came with the NFT");
    }

    function test_unstakedDesk_stopsEarning_butKeepsWhatItHad() public {
        uint256 a = _paidDesk();
        uint256 b = _mintAndStake(marcus);
        _unstake(emily, a);
        uint256 kept = pot.claimable(a, 0);
        _round(); // b becomes eligible
        _tax(0.05 ether);
        _round();
        assertEq(pot.claimable(a, 0), kept, "no new rewards while unstaked");
        assertGt(pot.claimable(b, 0), 0);
    }

    function test_failedClaim_keepsRights() public {
        RejectsBnb wallet = new RejectsBnb();
        uint256 id = _mint(emily);
        vm.prank(emily);
        nft.transferFrom(emily, address(wallet), id);
        wallet.stake(pot, nft, id);
        _round();
        _tax(0.05 ether);
        _round();
        uint256 owed = pot.claimable(id, 0);
        assertGt(owed, 0);
        vm.expectRevert();
        wallet.claim(pot, id, owed); // the contract wallet rejects BNB
        assertEq(pot.claimable(id, 0), owed, "the failed claim did not lose anything");
    }

    function test_reentrantClaimant_cannotDoubleClaim() public {
        Reenterer r = new Reenterer();
        uint256 id = _mint(emily);
        vm.prank(emily);
        nft.transferFrom(emily, address(r), id);
        r.stake(pot, nft, id);
        _round();
        _tax(0.05 ether);
        _round();
        uint256 owed = pot.claimable(id, 0);
        vm.expectRevert(); // re-entry hits the guard, so the whole claim reverts
        r.attack(pot, id, owed);
        assertEq(pot.claimable(id, 0), owed);
    }

    // ------------------------------------------------------------------
    // Rounding, decimals and many desks
    // ------------------------------------------------------------------

    function test_remainders_carryAndNeverOverpay() public {
        address[3] memory people = [emily, marcus, priya];
        uint256[3] memory ids;
        for (uint256 i; i < 3; ++i) ids[i] = _mintAndStake(people[i]);
        _round();
        _tax(0.030000000000000001 ether); // odd wei amounts: 3 desks never divide evenly
        _round();
        uint256 bnbEach = pot.claimable(ids[0], 0);
        assertEq(pot.claimable(ids[1], 0), bnbEach);
        assertEq(bnbEach * 3 + pot.carry(0), pot.totalDistributed(0) + pot.carry(0));
        assertLe(bnbEach * 3, 0.015 ether + 1);
        _assertSolvent();
    }

    function testFuzz_solvency_randomActivity(uint8 desks, uint64 taxWei, uint8 unstakeEvery, bool breakRouter) public {
        desks = uint8(bound(desks, 1, 25));
        taxWei = uint64(bound(taxWei, 0.03 ether, 3 ether));
        uint256[] memory ids = new uint256[](desks);
        address[] memory who = new address[](desks);
        for (uint256 i; i < desks; ++i) {
            who[i] = address(uint160(0x1000 + i));
            ids[i] = _mintAndStake(who[i]);
        }
        _round();
        v3.setBroken(breakRouter);
        _tax(taxWei);
        _round();
        uint256 step = bound(unstakeEvery, 1, 5);
        for (uint256 i; i < desks; i += step) _unstake(who[i], ids[i]);
        v3.setBroken(false);
        _tax(0.05 ether);
        _round();
        _assertSolvent();
        for (uint256 i; i < desks; ++i) {
            uint256 owed = pot.claimable(ids[i], 0);
            if (owed > 0) {
                vm.prank(pot.rightsHolder(ids[i]));
                pot.claim(ids[i], 0, owed);
            }
        }
        _assertSolvent();
    }

    // ------------------------------------------------------------------
    // Admin, pause, registry
    // ------------------------------------------------------------------

    function test_pause_stopsRoundsTaxesStake_butNotUnstakeOrClaim() public {
        uint256 id = _paidDesk();
        uint256 other = _mint(marcus);
        pot.pause();

        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pot.poke();
        vm.prank(team);
        desk.transfer(address(desk), 1_000 ether);
        desk.swapTaxes(); // the tax sale itself is not blocked; the paused Desk Pot just refuses the BNB for now
        assertGt(address(desk).balance, 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = other;
        vm.prank(marcus);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pot.stake(ids);

        vm.prank(emily);
        pot.claim(id, 0, type(uint256).max);
        _unstake(emily, id);
        assertEq(nft.ownerOf(id), emily);
    }

    function test_unpause_onlyAdmin() public {
        address guardian = makeAddr("guardian");
        pot.grantRole(pot.PAUSER_ROLE(), guardian);
        vm.prank(guardian);
        pot.pause();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, bytes32(0)));
        pot.unpause();
    }

    function test_noKeeperRole() public {
        (bool ok,) = address(pot).staticcall(abi.encodeWithSignature("KEEPER_ROLE()"));
        assertFalse(ok, "rounds need no keeper");
    }

    function test_onlyChipSwapNotifiesMintBem() public {
        vm.expectRevert(DeskPot.OnlyChipSwap.selector);
        pot.notifyMintBem(1e8);
    }

    function test_initializeOnce() public {
        vm.expectRevert(DeskPot.AlreadyInitialized.selector);
        pot.wire(address(desk), address(nft), address(minter), address(chips));
    }

    function test_assetRegistry_addAndDistributeNewAsset() public {
        MockToken usdt = new MockToken("Tether USD", "USDT", 18);
        pot.addAsset(address(usdt));
        assertEq(pot.assetsLength(), 3);
        vm.expectRevert(DeskPot.BadAsset.selector);
        pot.addAsset(address(usdt)); // no duplicates

        uint256 a = _mintAndStake(emily);
        uint256 b = _mintAndStake(marcus);
        _round();
        usdt.mint(admin, 100 ether);
        usdt.approve(address(pot), 100 ether);
        pot.depositAndDistribute(2, 100 ether);
        assertEq(pot.claimable(a, 2), 50 ether);
        vm.prank(marcus);
        pot.claim(b, 2, 50 ether);
        assertEq(usdt.balanceOf(marcus), 50 ether);
        vm.expectRevert(DeskPot.BadAsset.selector);
        pot.depositAndDistribute(1, 1); // core assets only via rounds
        vm.prank(emily);
        vm.expectRevert();
        pot.depositAndDistribute(2, 1); // the multisig only
    }

    function test_donationsJoinTheTax() public {
        vm.deal(jake, 1 ether);
        vm.prank(jake);
        (bool ok,) = address(pot).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(pot.taxBnb(), 0.5 ether);
    }
}

/// @dev A desk owner that is a contract refusing BNB.
contract RejectsBnb {
    function stake(DeskPot pot, IERC721 nft, uint256 id) external {
        nft.approve(address(pot), id);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        pot.stake(ids);
    }

    function claim(DeskPot pot, uint256 id, uint256 amount) external {
        pot.claim(id, 0, amount);
    }

    receive() external payable {
        revert("no BNB");
    }
}

/// @dev Tries to claim again from inside the BNB transfer.
contract Reenterer {
    DeskPot internal target;
    uint256 internal tid;
    uint256 internal amt;

    function stake(DeskPot pot, IERC721 nft, uint256 id) external {
        nft.approve(address(pot), id);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        pot.stake(ids);
    }

    function attack(DeskPot pot, uint256 id, uint256 amount) external {
        target = pot;
        tid = id;
        amt = amount;
        pot.claim(id, 0, amount / 2);
    }

    receive() external payable {
        target.claim(tid, 0, amt / 2);
    }
}

contract AurumBigTaxTest is AurumTest {
    /// A big tax pile goes in one sale, inside the next sell.
    function test_tax_bigPile_soldInOneSell() public {
        vm.prank(team);
        desk.transfer(address(desk), 4_000_000 ether);
        vm.prank(team);
        desk.transfer(emily, 3_000 ether);
        for (uint256 i; i < 3; ++i) {
            vm.prank(emily);
            desk.transfer(pair, 1_000 ether);
        }
        assertEq(desk.balanceOf(address(desk)), 50 ether, "only the last sell's 5% waits");
        // the pile plus the tax of the first two sells; the third sell's tax waits
        assertEq(pot.totalTaxBnb(), 4_000_100 ether * DESK_PRICE / 1 ether);
        assertEq(protocol.balance, pot.totalProtocolBnb(), "the protocol got its share of what was shared out");
    }
}
