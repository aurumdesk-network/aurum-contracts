// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TapeCodeStaking} from "../src/TapeCodeStaking.sol";
import {TapeCodeRewards} from "../src/TapeCodeRewards.sol";
import {DeskPot} from "../src/DeskPot.sol";
import {PotDeploy} from "./utils/PotDeploy.sol";
import {AurumToken} from "../src/AurumToken.sol";
import {MockBEM, MockWBNB, MockV2Router, MockV3Router, MockV3Pool} from "./mocks/Mocks.sol";

/// @dev TapeCode-Test1 stand-in: a plain ERC-721 with ids given out by the test.
contract MockCollection is ERC721 {
    constructor() ERC721("TapeCode-Test1", "TCT1") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @dev A smart-contract wallet: it has code, and no onERC721Received.
contract ContractWallet {
    function call(address to, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory out) = to.call(data);
        require(ok, "call failed");
        return out;
    }
}

contract RefusesBnb {
    receive() external payable {
        revert("no");
    }
}

/// @dev Burns all the gas it is given when BNB arrives.
contract BurnsGas {
    receive() external payable {
        while (true) {}
    }
}

/// @dev A wallet whose receive needs more gas than a batch gives one wallet.
contract HungryWallet {
    uint256[] private log;

    receive() external payable {
        for (uint256 i; i < 10; ++i) log.push(i);
    }
}

/// @dev Refuses BNB until told otherwise.
contract ChangesItsMind {
    bool public open;

    function setOpen(bool open_) external {
        open = open_;
    }

    receive() external payable {
        require(open, "no");
    }
}

/// @dev Tries to be paid again from inside the payment.
contract ReentrantWallet {
    TapeCodeRewards public rewards;
    uint256 public period;
    uint256 public amount;
    bytes32[] public proof;
    bool public blocked;

    function load(TapeCodeRewards rewards_, uint256 period_, uint256 amount_, bytes32[] memory proof_) external {
        rewards = rewards_;
        period = period_;
        amount = amount_;
        proof = proof_;
    }

    receive() external payable {
        try rewards.pay(period, address(this), amount, proof) {} catch {
            blocked = true;
        }
    }
}

contract TapeCodeStakingTest is Test {
    MockCollection nft;
    TapeCodeStaking staking;
    address amara = makeAddr("amara");
    address bruno = makeAddr("bruno");
    address chloe = makeAddr("chloe");

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new MockCollection();
        staking = new TapeCodeStaking(address(nft));
        for (uint256 id = 1; id <= 5; ++id) nft.mint(amara, id);
        for (uint256 id = 6; id <= 8; ++id) nft.mint(bruno, id);
        vm.prank(amara);
        nft.setApprovalForAll(address(staking), true);
        vm.prank(bruno);
        nft.setApprovalForAll(address(staking), true);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory x) {
        x = new uint256[](2);
        x[0] = a;
        x[1] = b;
    }

    function test_stake_locksTheNftAndRecordsTheWallet() public {
        vm.prank(amara);
        staking.stake(_ids(1, 2));
        assertEq(nft.ownerOf(1), address(staking));
        assertEq(nft.ownerOf(2), address(staking));
        assertEq(staking.stakerOf(1), amara);
        assertEq(staking.stakedOf(amara), 2);
        assertEq(staking.totalStaked(), 2);
        assertEq(staking.walletCount(), 1);
        assertEq(staking.idsOf(amara).length, 2);
    }

    function test_stake_needsApproval() public {
        vm.prank(chloe);
        nft.setApprovalForAll(address(staking), false);
        nft.mint(chloe, 20);
        vm.prank(chloe);
        vm.expectRevert();
        staking.stake(_ids(20));
    }

    function test_stake_refusesSomeoneElsesNft_evenWhenTheyApprovedThisContract() public {
        // bruno owns 6 and has approved the contract; amara must not be able to stake it
        vm.prank(amara);
        vm.expectRevert(TapeCodeStaking.NotOwner.selector);
        staking.stake(_ids(6));
        assertEq(nft.ownerOf(6), bruno);
    }

    function test_stake_refusesAnNftAlreadyStaked() public {
        vm.startPrank(amara);
        staking.stake(_ids(1));
        vm.expectRevert(TapeCodeStaking.NotOwner.selector);
        staking.stake(_ids(1));
        vm.stopPrank();
    }

    function test_stake_sameIdTwiceInOneCallReverts() public {
        vm.prank(amara);
        vm.expectRevert(TapeCodeStaking.NotOwner.selector);
        staking.stake(_ids(1, 1));
    }

    function test_empty_calls_revert() public {
        vm.startPrank(amara);
        vm.expectRevert(TapeCodeStaking.NothingToDo.selector);
        staking.stake(new uint256[](0));
        vm.expectRevert(TapeCodeStaking.NothingToDo.selector);
        staking.unstake(new uint256[](0));
        vm.stopPrank();
    }

    function test_unstake_returnsTheNftOnlyToTheStaker() public {
        vm.prank(amara);
        staking.stake(_ids(1, 2));
        vm.prank(bruno);
        vm.expectRevert(TapeCodeStaking.NotStaker.selector);
        staking.unstake(_ids(1));

        vm.prank(amara);
        staking.unstake(_ids(1));
        assertEq(nft.ownerOf(1), amara);
        assertEq(staking.stakerOf(1), address(0));
        assertEq(staking.stakedOf(amara), 1);
        assertEq(staking.totalStaked(), 1);
        uint256[] memory left = staking.idsOf(amara);
        assertEq(left.length, 1);
        assertEq(left[0], 2);

        vm.prank(amara);
        vm.expectRevert(TapeCodeStaking.NotStaker.selector);
        staking.unstake(_ids(1)); // not twice
    }

    function test_unstake_keepsTheIdListCorrectWhateverTheOrder() public {
        uint256[] memory all = new uint256[](5);
        for (uint256 i; i < 5; ++i) all[i] = i + 1;
        vm.startPrank(amara);
        staking.stake(all);
        staking.unstake(_ids(1)); // first
        staking.unstake(_ids(3)); // middle
        staking.unstake(_ids(4)); // whichever is at the end now
        vm.stopPrank();
        uint256[] memory left = staking.idsOf(amara);
        assertEq(left.length, 2);
        assertEq(left[0] + left[1], 2 + 5);
        for (uint256 i; i < left.length; ++i) assertEq(staking.stakerOf(left[i]), amara);
        vm.startPrank(amara);
        staking.unstake(left);
        vm.stopPrank();
        assertEq(staking.idsOf(amara).length, 0);
        for (uint256 id = 1; id <= 5; ++id) assertEq(nft.ownerOf(id), amara);
    }

    function test_points_growWithNftsAndTime() public {
        vm.prank(amara);
        staking.stake(_ids(1, 2));
        skip(100);
        assertEq(staking.pointsOf(amara), 200);
        vm.prank(bruno);
        staking.stake(_ids(6));
        skip(50);
        assertEq(staking.pointsOf(amara), 300);
        assertEq(staking.pointsOf(bruno), 50);
        assertEq(staking.totalPoints(), 350);
    }

    function test_points_stopAfterUnstake_andAreKept() public {
        vm.prank(amara);
        staking.stake(_ids(1));
        skip(100);
        vm.prank(amara);
        staking.unstake(_ids(1));
        skip(1000);
        assertEq(staking.pointsOf(amara), 100);
        assertEq(staking.totalPoints(), 100);
    }

    function test_points_stakingMoreLaterCountsFromThen() public {
        vm.prank(amara);
        staking.stake(_ids(1));
        skip(10);
        vm.prank(amara);
        staking.stake(_ids(2));
        skip(10);
        assertEq(staking.pointsOf(amara), 10 + 20);
        assertEq(staking.totalPoints(), 30);
    }

    function test_walletsPage_pages() public {
        vm.prank(amara);
        staking.stake(_ids(1));
        vm.prank(bruno);
        staking.stake(_ids(6));
        skip(10);
        TapeCodeStaking.WalletView[] memory p = staking.walletsPage(0, 100);
        assertEq(p.length, 2);
        assertEq(p[0].wallet, amara);
        assertEq(p[0].rewardWallet, amara);
        assertEq(p[0].staked, 1);
        assertEq(p[0].points, 10);
        assertEq(staking.walletsPage(1, 1)[0].wallet, bruno);
        assertEq(staking.walletsPage(2, 1).length, 0);
        assertEq(staking.walletCount(), 2);
        vm.prank(amara);
        staking.stake(_ids(2)); // a known wallet is not listed twice
        assertEq(staking.walletCount(), 2);
    }

    function test_safeTransferIsRefused_soAnNftCannotArriveByAccident() public {
        vm.prank(amara);
        vm.expectRevert();
        nft.safeTransferFrom(amara, address(staking), 1);
        assertEq(nft.ownerOf(1), amara);
    }

    function test_rewardWallet_defaultsToTheWallet_andCanBeChosenAndCleared() public {
        assertEq(staking.rewardWalletOf(amara), amara);
        vm.prank(amara);
        staking.setRewardWallet(chloe);
        assertEq(staking.rewardWalletOf(amara), chloe);
        vm.prank(amara);
        staking.setRewardWallet(address(0));
        assertEq(staking.rewardWalletOf(amara), amara);
    }

    function test_contractWallet_mustChooseARewardWalletFirst_andCanStillUnstake() public {
        ContractWallet safe = new ContractWallet();
        nft.mint(address(safe), 30);
        safe.call(address(nft), abi.encodeCall(nft.setApprovalForAll, (address(staking), true)));
        vm.expectRevert("call failed");
        safe.call(address(staking), abi.encodeCall(staking.stake, (_ids(30))));

        safe.call(address(staking), abi.encodeCall(staking.setRewardWallet, (chloe)));
        safe.call(address(staking), abi.encodeCall(staking.stake, (_ids(30))));
        assertEq(staking.rewardWalletOf(address(safe)), chloe);
        safe.call(address(staking), abi.encodeCall(staking.unstake, (_ids(30)))); // no onERC721Received needed
        assertEq(nft.ownerOf(30), address(safe));
    }

    function test_eip7702Wallet_countsAsAKeyHeldWallet() public {
        vm.etch(chloe, abi.encodePacked(hex"ef0100", address(0x1234)));
        assertEq(chloe.code.length, 23);
        nft.mint(chloe, 31);
        vm.startPrank(chloe);
        nft.setApprovalForAll(address(staking), true);
        staking.stake(_ids(31));
        vm.stopPrank();
        assertEq(staking.stakedOf(chloe), 1);
    }

    function testFuzz_points_matchAReplayOfTheHistory(uint8[12] memory wallets, uint16[12] memory waits, bool[12] memory stakes) public {
        address[3] memory who = [amara, bruno, chloe];
        vm.prank(chloe);
        nft.setApprovalForAll(address(staking), true);
        for (uint256 id = 100; id < 112; ++id) nft.mint(chloe, id);
        uint256[3] memory expected;
        uint256[3] memory count;
        uint256 total;
        for (uint256 i; i < 12; ++i) {
            uint256 dt = waits[i];
            skip(dt);
            for (uint256 w; w < 3; ++w) {
                expected[w] += count[w] * dt;
                total += count[w] * dt;
            }
            uint256 w = wallets[i] % 3;
            uint256[] memory held = staking.idsOf(who[w]);
            if (stakes[i]) {
                uint256 id = _firstOwned(who[w]);
                if (id == 0) continue;
                vm.prank(who[w]);
                staking.stake(_ids(id));
                ++count[w];
            } else if (held.length != 0) {
                vm.prank(who[w]);
                staking.unstake(_ids(held[0]));
                --count[w];
            }
            uint256 sum;
            for (uint256 k; k < 3; ++k) {
                assertEq(staking.pointsOf(who[k]), expected[k]);
                assertEq(staking.stakedOf(who[k]), count[k]);
                sum += staking.pointsOf(who[k]);
            }
            assertEq(staking.totalPoints(), total);
            assertEq(sum, total);
        }
        assertEq(nft.balanceOf(address(staking)), staking.totalStaked());
    }

    function _firstOwned(address who) internal view returns (uint256) {
        for (uint256 id = 1; id <= 8; ++id) if (nft.ownerOf(id) == who) return id;
        if (who == chloe) for (uint256 id = 100; id < 112; ++id) if (nft.ownerOf(id) == who) return id;
        return 0;
    }
}

/// @dev Random stakes and unstakes for the invariant test.
contract StakingHandler is Test {
    MockCollection public immutable nft;
    TapeCodeStaking public immutable staking;
    address[] public people;

    constructor(MockCollection nft_, TapeCodeStaking staking_) {
        nft = nft_;
        staking = staking_;
        for (uint256 i; i < 4; ++i) {
            address p = makeAddr(string.concat("person-", vm.toString(i)));
            people.push(p);
            for (uint256 id = i * 10 + 1; id <= i * 10 + 6; ++id) nft.mint(p, id);
            vm.prank(p);
            nft.setApprovalForAll(address(staking), true);
        }
    }

    function stake(uint8 who, uint8 pick, uint16 wait) external {
        skip(wait);
        address p = people[who % 4];
        uint256 base = (who % 4) * 10 + 1;
        uint256 id = base + (pick % 6);
        if (nft.ownerOf(id) != p) return;
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(p);
        staking.stake(ids);
    }

    function unstake(uint8 who, uint8 pick, uint16 wait) external {
        skip(wait);
        address p = people[who % 4];
        uint256[] memory held = staking.idsOf(p);
        if (held.length == 0) return;
        uint256[] memory ids = new uint256[](1);
        ids[0] = held[pick % held.length];
        vm.prank(p);
        staking.unstake(ids);
    }
}

contract TapeCodeStakingInvariantTest is Test {
    MockCollection nft;
    TapeCodeStaking staking;
    StakingHandler handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new MockCollection();
        staking = new TapeCodeStaking(address(nft));
        handler = new StakingHandler(nft, staking);
        targetContract(address(handler));
    }

    function invariant_totalsMatchTheWallets() public view {
        uint256 points;
        uint256 count;
        for (uint256 i; i < 4; ++i) {
            address p = handler.people(i);
            points += staking.pointsOf(p);
            count += staking.stakedOf(p);
            uint256[] memory held = staking.idsOf(p);
            assertEq(held.length, staking.stakedOf(p));
            for (uint256 k; k < held.length; ++k) {
                assertEq(staking.stakerOf(held[k]), p);
                assertEq(nft.ownerOf(held[k]), address(staking));
            }
        }
        assertEq(points, staking.totalPoints());
        assertEq(count, staking.totalStaked());
        assertEq(nft.balanceOf(address(staking)), staking.totalStaked());
    }
}

contract TapeCodeRewardsTest is Test {
    TapeCodeRewards rewards;
    address owner = makeAddr("multisig");
    address amara = makeAddr("amara");
    address bruno = makeAddr("bruno");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_800_000_000);
        rewards = new TapeCodeRewards(owner);
        vm.deal(address(this), 1_000 ether);
    }

    function _fund(uint256 bnb) internal {
        (bool ok, ) = address(rewards).call{value: bnb}("");
        assertTrue(ok);
    }

    // ---- a two-wallet tree: the root is the sorted hash of the two leaves, each proof is the other leaf
    function _node(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proof(bytes32 other) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = other;
    }

    function _publishTo(address wa, uint256 a, address wb, uint256 b) internal returns (uint256 id, bytes32 la, bytes32 lb) {
        id = rewards.periodCount();
        la = rewards.leaf(id, wa, a);
        lb = rewards.leaf(id, wb, b);
        uint64 from = rewards.lastToTime();
        vm.prank(owner);
        rewards.publish(_node(la, lb), a + b, from, uint64(block.timestamp), "list");
    }

    /// Publishes a list for amara and bruno. Returns the period id and both leaves.
    function _publish(uint256 a, uint256 b) internal returns (uint256 id, bytes32 la, bytes32 lb) {
        return _publishTo(amara, a, bruno, b);
    }

    // ---- receiving

    function test_receive_onlyBooksTheBnb() public {
        (bool ok, ) = address(rewards).call{value: 1 ether, gas: 5_000}("");
        assertTrue(ok, "a payment needs almost no gas");
        assertEq(address(rewards).balance, 1 ether);
        assertEq(rewards.available(), 1 ether);
    }

    function test_noFunctionTakesBnbOut_butAList() public {
        _fund(1 ether);
        vm.startPrank(owner);
        for (uint256 i; i < 3; ++i) {
            bytes memory data = i == 0 ? abi.encodeWithSignature("rescueBnb(address)", owner) : i == 1 ? abi.encodeWithSignature("withdraw()") : abi.encodeWithSignature("buy()");
            (bool ok, ) = address(rewards).call(data);
            assertFalse(ok);
        }
        vm.stopPrank();
        assertEq(address(rewards).balance, 1 ether);
    }

    // ---- publishing

    function test_publish_onlyOwner() public {
        _fund(100);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        rewards.publish(bytes32(uint256(1)), 100, 0, 1, "list");
    }

    function test_ownership_takesTwoSteps() public {
        vm.prank(owner);
        rewards.transferOwnership(amara);
        assertEq(rewards.owner(), owner);
        vm.prank(amara);
        rewards.acceptOwnership();
        assertEq(rewards.owner(), amara);
    }

    function test_publish_refusesEmptyLists() public {
        _fund(100);
        vm.startPrank(owner);
        vm.expectRevert(TapeCodeRewards.BadList.selector);
        rewards.publish(bytes32(0), 100, 0, 1, "list");
        vm.expectRevert(TapeCodeRewards.BadList.selector);
        rewards.publish(bytes32(uint256(1)), 0, 0, 1, "list");
        vm.stopPrank();
    }

    function test_publish_periodsMustFollowEachOther_soNoTimeIsPaidTwice() public {
        _fund(1_000);
        uint64 t1 = uint64(block.timestamp - 100);
        uint64 t2 = uint64(block.timestamp);
        vm.startPrank(owner);
        vm.expectRevert(TapeCodeRewards.BadPeriod.selector);
        rewards.publish(bytes32(uint256(1)), 100, 5, t1, "list"); // first list must start at 0
        rewards.publish(bytes32(uint256(1)), 100, 0, t1, "list");
        assertEq(rewards.lastToTime(), t1);
        vm.expectRevert(TapeCodeRewards.BadPeriod.selector);
        rewards.publish(bytes32(uint256(2)), 100, 0, t2, "list"); // starts over: same time again
        vm.expectRevert(TapeCodeRewards.BadPeriod.selector);
        rewards.publish(bytes32(uint256(2)), 100, t1 - 1, t2, "list"); // overlaps
        vm.expectRevert(TapeCodeRewards.BadPeriod.selector);
        rewards.publish(bytes32(uint256(2)), 100, t1 + 1, t2, "list"); // leaves a gap
        vm.expectRevert(TapeCodeRewards.BadPeriod.selector);
        rewards.publish(bytes32(uint256(2)), 100, t1, t1, "list"); // empty span
        vm.expectRevert(TapeCodeRewards.BadPeriod.selector);
        rewards.publish(bytes32(uint256(2)), 100, t1, t2 + 1, "list"); // from the future: it would block later lists
        rewards.publish(bytes32(uint256(2)), 100, t1, t2, "list");
        vm.stopPrank();
        assertEq(rewards.periodCount(), 2);
    }

    function test_publish_cannotPromiseBnbTwice() public {
        _fund(100);
        vm.startPrank(owner);
        vm.expectRevert(TapeCodeRewards.NotEnoughBnb.selector);
        rewards.publish(bytes32(uint256(1)), 101, 0, uint64(block.timestamp - 1), "list");
        rewards.publish(bytes32(uint256(1)), 100, 0, uint64(block.timestamp - 1), "list");
        assertEq(rewards.available(), 0);
        vm.expectRevert(TapeCodeRewards.NotEnoughBnb.selector);
        rewards.publish(bytes32(uint256(2)), 1, uint64(block.timestamp - 1), uint64(block.timestamp), "list");
        vm.stopPrank();
    }

    // ---- paying

    function test_pay_anyoneCanSend_theBnbGoesToTheListedWallet() public {
        _fund(300);
        (uint256 id, bytes32 la, bytes32 lb) = _publish(100, 200);
        vm.prank(stranger);
        rewards.pay(id, amara, 100, _proof(lb));
        assertEq(amara.balance, 100);
        assertEq(stranger.balance, 0);
        assertTrue(rewards.isPaid(id, amara));
        assertFalse(rewards.isPaid(id, bruno));
        rewards.pay(id, bruno, 200, _proof(la));
        assertEq(bruno.balance, 200);
        assertEq(rewards.promised(), 0);
        assertEq(rewards.totalPaid(), 300);
        assertEq(address(rewards).balance, 0);
    }

    function test_pay_refusesAWrongWalletAmountOrPeriod() public {
        _fund(300);
        (uint256 id, , bytes32 lb) = _publish(100, 200);
        vm.expectRevert(TapeCodeRewards.BadProof.selector);
        rewards.pay(id, stranger, 100, _proof(lb)); // another wallet
        vm.expectRevert(TapeCodeRewards.BadProof.selector);
        rewards.pay(id, amara, 101, _proof(lb)); // more BNB
        vm.expectRevert(TapeCodeRewards.BadPeriod.selector);
        rewards.pay(id + 1, amara, 100, _proof(lb)); // a list that does not exist
    }

    function test_pay_notTwice() public {
        _fund(300);
        (uint256 id, , bytes32 lb) = _publish(100, 200);
        rewards.pay(id, amara, 100, _proof(lb));
        vm.expectRevert(TapeCodeRewards.AlreadyPaid.selector);
        rewards.pay(id, amara, 100, _proof(lb));
        assertEq(amara.balance, 100);
    }

    function test_pay_aProofFromOneListDoesNotWorkOnAnother() public {
        _fund(600);
        (uint256 first, bytes32 la, bytes32 lb) = _publish(100, 200);
        skip(1);
        (uint256 second, , ) = _publish(100, 200);
        vm.expectRevert(TapeCodeRewards.BadProof.selector);
        rewards.pay(second, amara, 100, _proof(lb)); // proof built for the first list
        rewards.pay(first, amara, 100, _proof(lb));
        assertEq(amara.balance, 100);
        assertTrue(la != rewards.leaf(second, amara, 100));
    }

    function test_pay_aListCannotPayMoreThanItsTotal() public {
        _fund(1_000);
        bytes32 la = rewards.leaf(0, amara, 100);
        bytes32 lb = rewards.leaf(0, bruno, 900); // the tree holds 1,000 but the list says 300
        vm.prank(owner);
        rewards.publish(_node(la, lb), 300, 0, uint64(block.timestamp), "list");
        rewards.pay(0, amara, 100, _proof(lb));
        vm.expectRevert(TapeCodeRewards.OverPaid.selector);
        rewards.pay(0, bruno, 900, _proof(la));
        assertEq(bruno.balance, 0);
        assertEq(address(rewards).balance, 900);
    }

    function test_payMany_paysEveryone_skippingWhoIsAlreadyPaid() public {
        _fund(300);
        (uint256 id, bytes32 la, bytes32 lb) = _publish(100, 200);
        rewards.pay(id, amara, 100, _proof(lb)); // amara got hers just before the batch
        TapeCodeRewards.Payment[] memory list = new TapeCodeRewards.Payment[](2);
        list[0] = TapeCodeRewards.Payment(id, amara, 100, _proof(lb));
        list[1] = TapeCodeRewards.Payment(id, bruno, 200, _proof(la));
        vm.prank(stranger);
        rewards.payMany(list);
        assertEq(amara.balance, 100);
        assertEq(bruno.balance, 200);
        assertEq(rewards.promised(), 0);
    }

    function test_payMany_aWrongProofFailsTheBatch() public {
        _fund(300);
        (uint256 id, , bytes32 lb) = _publish(100, 200);
        TapeCodeRewards.Payment[] memory list = new TapeCodeRewards.Payment[](2);
        list[0] = TapeCodeRewards.Payment(id, amara, 100, _proof(lb));
        list[1] = TapeCodeRewards.Payment(id, bruno, 999, _proof(lb));
        vm.expectRevert(TapeCodeRewards.BadProof.selector);
        rewards.payMany(list);
        assertEq(amara.balance, 0);
    }

    function test_promisedBnb_staysAsMoreArrives() public {
        _fund(300);
        (uint256 id, , bytes32 lb) = _publish(100, 200);
        assertEq(rewards.available(), 0);
        _fund(1 ether); // more BNB arrives: only the new BNB is free
        assertEq(rewards.available(), 1 ether);
        rewards.pay(id, amara, 100, _proof(lb));
        assertEq(rewards.available(), 1 ether);
        assertEq(rewards.promised(), 200);
    }

    // ---- wallets that do not simply take BNB

    function test_pay_aWalletRefusingBnb_revertsAndStaysPayable() public {
        ChangesItsMind wallet = new ChangesItsMind();
        _fund(300);
        (uint256 id, bytes32 la, ) = _publishTo(address(wallet), 100, bruno, 200);
        bytes32 lb = rewards.leaf(id, bruno, 200);
        vm.expectRevert(TapeCodeRewards.WalletRefusedBnb.selector);
        rewards.pay(id, address(wallet), 100, _proof(lb));
        assertFalse(rewards.isPaid(id, address(wallet)));
        assertEq(rewards.promised(), 300);

        wallet.setOpen(true);
        rewards.pay(id, address(wallet), 100, _proof(lb));
        assertEq(address(wallet).balance, 100);
        assertTrue(la != bytes32(0));
    }

    function test_payMany_aWalletRefusingBnb_doesNotStopTheOthers_andStaysPayable() public {
        ChangesItsMind wallet = new ChangesItsMind();
        _fund(300);
        (uint256 id, bytes32 la, bytes32 lb) = _publishTo(address(wallet), 100, bruno, 200);
        TapeCodeRewards.Payment[] memory list = new TapeCodeRewards.Payment[](2);
        list[0] = TapeCodeRewards.Payment(id, address(wallet), 100, _proof(lb));
        list[1] = TapeCodeRewards.Payment(id, bruno, 200, _proof(la));
        vm.expectEmit(true, true, false, true, address(rewards));
        emit TapeCodeRewards.PaymentRefused(id, address(wallet), 100);
        rewards.payMany(list);
        assertEq(bruno.balance, 200);
        assertFalse(rewards.isPaid(id, address(wallet)));
        assertEq(rewards.promised(), 100, "its BNB stays promised");
        assertEq(rewards.available(), 0);
        assertEq(rewards.totalPaid(), 200);
        (, , uint256 paid, , ) = rewards.periods(id);
        assertEq(paid, 200);

        wallet.setOpen(true);
        rewards.payMany(list); // the same batch again: bruno is skipped, the wallet is paid
        assertEq(address(wallet).balance, 100);
        assertEq(bruno.balance, 200);
        assertEq(rewards.promised(), 0);
    }

    function test_payMany_aWalletBurningGas_doesNotStopTheOthers() public {
        BurnsGas wallet = new BurnsGas();
        _fund(300);
        (uint256 id, bytes32 la, bytes32 lb) = _publishTo(address(wallet), 100, bruno, 200);
        TapeCodeRewards.Payment[] memory list = new TapeCodeRewards.Payment[](2);
        list[0] = TapeCodeRewards.Payment(id, address(wallet), 100, _proof(lb));
        list[1] = TapeCodeRewards.Payment(id, bruno, 200, _proof(la));
        uint256 before = gasleft();
        rewards.payMany(list);
        assertLt(before - gasleft(), 300_000, "the wallet cost the batch at most its gas limit");
        assertEq(bruno.balance, 200);
        assertEq(rewards.promised(), 100);
    }

    function test_aWalletNeedingMoreGas_isSkippedInABatch_butPayWorks() public {
        HungryWallet wallet = new HungryWallet();
        _fund(300);
        (uint256 id, bytes32 la, bytes32 lb) = _publishTo(address(wallet), 100, bruno, 200);
        TapeCodeRewards.Payment[] memory list = new TapeCodeRewards.Payment[](2);
        list[0] = TapeCodeRewards.Payment(id, address(wallet), 100, _proof(lb));
        list[1] = TapeCodeRewards.Payment(id, bruno, 200, _proof(la));
        rewards.payMany(list);
        assertEq(address(wallet).balance, 0);
        rewards.pay(id, address(wallet), 100, _proof(lb));
        assertEq(address(wallet).balance, 100);
        assertEq(rewards.promised(), 0);
    }

    function test_aWalletCallingBackIn_cannotBePaidTwice() public {
        ReentrantWallet wallet = new ReentrantWallet();
        _fund(300);
        (uint256 id, , bytes32 lb) = _publishTo(address(wallet), 100, bruno, 200);
        bytes32 otherLeaf = rewards.leaf(id, bruno, 200);
        wallet.load(rewards, id, 100, _proof(otherLeaf));
        rewards.pay(id, address(wallet), 100, _proof(lb));
        assertTrue(wallet.blocked(), "the second payment was refused");
        assertEq(address(wallet).balance, 100);
        assertEq(address(rewards).balance, 200);
        assertEq(rewards.promised(), 200);
    }

    function testFuzz_pay_splitsExactlyAndKeepsTheBooks(uint64 a, uint64 b, uint64 extra, bool amaraFirst) public {
        vm.assume(a > 0 && b > 0);
        uint256 total = uint256(a) + b;
        _fund(total + extra);
        (uint256 id, bytes32 la, bytes32 lb) = _publish(a, b);
        if (amaraFirst) rewards.pay(id, amara, a, _proof(lb));
        rewards.pay(id, bruno, b, _proof(la));
        if (!amaraFirst) rewards.pay(id, amara, a, _proof(lb));
        assertEq(amara.balance, a);
        assertEq(bruno.balance, b);
        assertEq(rewards.promised(), 0);
        assertEq(rewards.available(), extra);
        assertEq(address(rewards).balance, extra);
    }
}

/// @notice How the Desk Pot shares out the tax once TapeCodeRewards is set, through real sells of AURUM.
contract TapeCodeTaxTest is Test {
    uint256 constant BEM_PER_BNB = 36.8e8;
    uint256 constant DESK_PRICE = 2e12; // BNB per 1e18 AURUM in the mock market

    MockWBNB wbnb;
    MockBEM bem;
    MockV2Router v2;
    MockV3Router v3;
    MockV3Pool v3pool;
    DeskPot pot;
    AurumToken desk;
    TapeCodeRewards rewards;
    address team = makeAddr("team-liquidity");
    address protocol = makeAddr("protocol-treasury");
    address pair = makeAddr("pancake-pair");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_800_000_000);
        wbnb = new MockWBNB();
        bem = new MockBEM();
        v2 = new MockV2Router(address(wbnb));
        v3 = new MockV3Router(address(wbnb), address(bem));
        v3.setRate(BEM_PER_BNB);
        v3pool = new MockV3Pool(address(bem), address(wbnb));
        v3pool.setPrice(address(bem) < address(wbnb) ? uint160(Math.sqrt(Math.mulDiv(1 ether, 1 << 192, BEM_PER_BNB))) : uint160(Math.sqrt(Math.mulDiv(BEM_PER_BNB, 1 << 192, 1 ether))));
        deal(address(wbnb), address(v3pool), 1_000 ether);
        pot = PotDeploy.deploy(address(bem), address(v2), address(v3), address(v3pool), address(this), protocol);
        desk = new AurumToken("AURUM", "AURUM", 1_000_000_000 ether, team, address(pot), address(v2), address(this));
        // the chip and desk contracts play no part in the tax split
        pot.wire(address(desk), makeAddr("nft"), makeAddr("minter"), makeAddr("chipswap"));
        desk.setPair(pair);
        desk.setTaxExempt(team, true);
        desk.setSwapThreshold(1);
        v2.setSellRate(address(desk), DESK_PRICE);
        vm.deal(address(v2), 1_000 ether);
        rewards = new TapeCodeRewards(address(this));
    }

    function _deposit(uint256 bnb) internal {
        vm.deal(address(desk), bnb);
        vm.prank(address(desk));
        pot.depositTax{value: bnb}(0);
    }

    function test_share_isOneTwoTwo_ofTheFivePercent() public {
        pot.setTapeCodeRewards(address(rewards));
        _deposit(5 ether); // the 5% tax on a sale worth 100 BNB
        assertEq(pot.totalTaxBnb(), 5 ether);
        assertEq(address(rewards).balance, 1 ether, "1% to the NFT Staking Pool, as BNB");
        assertEq(pot.totalTapeCodeBnb(), 1 ether);
        assertEq(protocol.balance, 2 ether, "2% to the protocol, as BNB");
        assertEq(pot.totalProtocolBnb(), 2 ether);
        assertEq(pot.directBnb(), 1 ether, "half of the Desk Pot's 2% stays BNB");
        assertEq(pot.buybackBnb(), 1 ether, "the other half buys BEM");
        assertEq(pot.taxBnb(), 0);
        assertEq(address(pot).balance, 2 ether);
    }

    function test_share_waitsForThePointZeroThreeBnb() public {
        pot.setTapeCodeRewards(address(rewards));
        _deposit(0.029 ether);
        assertEq(pot.taxBnb(), 0.029 ether, "under the threshold everything waits");
        assertEq(address(rewards).balance, 0);
        assertEq(pot.directBnb() + pot.buybackBnb(), 0);
        _deposit(0.001 ether);
        assertEq(pot.taxBnb(), 0);
        assertEq(address(rewards).balance, 0.006 ether);
        assertEq(protocol.balance, 0.012 ether);
        assertEq(pot.directBnb(), 0.006 ether);
        assertEq(pot.buybackBnb(), 0.006 ether);
    }

    function test_share_atMostOncePerHour() public {
        pot.setTapeCodeRewards(address(rewards));
        _deposit(5 ether);
        _deposit(5 ether);
        assertEq(pot.taxBnb(), 5 ether, "the second part waits for the next round");
        assertEq(address(rewards).balance, 1 ether);
        skip(1 hours);
        pot.poke();
        assertEq(pot.taxBnb(), 0);
        assertEq(address(rewards).balance, 2 ether);
        assertEq(pot.totalTapeCodeBnb(), 2 ether);
    }

    function test_share_oddAmountsLoseNothing() public {
        pot.setTapeCodeRewards(address(rewards));
        _deposit(0.030000000000000007 ether);
        assertEq(address(rewards).balance + protocol.balance + pot.directBnb() + pot.buybackBnb(), 0.030000000000000007 ether);
        assertEq(address(pot).balance, pot.directBnb() + pot.buybackBnb());
    }

    function test_share_withoutRewards_staysInTheDeskPot() public {
        _deposit(5 ether);
        assertEq(protocol.balance, 2 ether);
        assertEq(pot.directBnb(), 1.5 ether);
        assertEq(pot.buybackBnb(), 1.5 ether);
        assertEq(pot.totalTapeCodeBnb(), 0);
    }

    function test_share_stopsWhenRewardsIsCleared() public {
        pot.setTapeCodeRewards(address(rewards));
        pot.setTapeCodeRewards(address(0));
        _deposit(5 ether);
        assertEq(pot.totalTapeCodeBnb(), 0);
        assertEq(pot.directBnb() + pot.buybackBnb(), 3 ether);
    }

    function test_share_aReceiverThatFailsNeverBlocksASale() public {
        pot.setTapeCodeRewards(address(new RefusesBnb()));
        _deposit(5 ether);
        assertEq(pot.totalTapeCodeBnb(), 0);
        assertEq(pot.directBnb() + pot.buybackBnb(), 3 ether, "its share stays in the Desk Pot");
    }

    function test_share_aReceiverBurningGasNeverBlocksASale() public {
        pot.setTapeCodeRewards(address(new BurnsGas()));
        vm.deal(address(desk), 5 ether);
        vm.prank(address(desk));
        pot.depositTax{value: 5 ether, gas: 1_000_000}(0);
        assertEq(pot.totalTapeCodeBnb(), 0);
        assertEq(pot.directBnb() + pot.buybackBnb(), 3 ether);
    }

    function test_share_aBrokenBemMarketNeverBlocksASale() public {
        pot.setTapeCodeRewards(address(rewards));
        v3.setBroken(true);
        _deposit(5 ether);
        assertEq(address(rewards).balance, 1 ether, "the share does not depend on the BEM market");
        assertEq(pot.directBnb() + pot.buybackBnb(), 2 ether);
    }

    function test_setter_onlyAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        pot.setTapeCodeRewards(stranger);
    }

    function test_realSell_paysTheShare() public {
        pot.setTapeCodeRewards(address(rewards));
        vm.startPrank(team);
        desk.transfer(pair, 300_000_000 ether); // liquidity for the pair
        desk.transfer(stranger, 1_000_000 ether);
        vm.stopPrank();
        vm.startPrank(stranger);
        desk.transfer(pair, 500_000 ether); // first sell: 5% tax collects in the token
        desk.transfer(pair, 500_000 ether); // next sell: the collected tax is sold for BNB first, the round runs
        vm.stopPrank();
        uint256 tax = pot.totalTaxBnb();
        assertGe(tax, 0.03 ether);
        assertEq(pot.totalTapeCodeBnb(), (tax * 2_000) / 10_000);
        assertEq(address(rewards).balance, pot.totalTapeCodeBnb());
    }
}
