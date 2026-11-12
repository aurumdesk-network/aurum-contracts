// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeskPot} from "../src/DeskPot.sol";
import {AurumTest} from "./Aurum.t.sol";
import {PotDeploy} from "./utils/PotDeploy.sol";

/// @dev A later version: same storage, one new function.
contract DeskPotV2 is DeskPot {
    constructor(address bem_, address v2Router_, address v3Router_, address bemPool_) DeskPot(bem_, v2Router_, v3Router_, bemPool_) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice The Desk Pot behind its proxy: who may upgrade, and that an upgrade keeps every desk and vault.
contract UpgradeTest is AurumTest {
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _impl(DeskPot p) internal view returns (address) {
        return address(uint160(uint256(vm.load(address(p), IMPL_SLOT))));
    }

    function _v2() internal returns (address) {
        return address(new DeskPotV2(address(bem), address(v2), address(v3), address(v3pool)));
    }

    function test_upgrade_cannotSetUpTwice_norUseTheImplementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        pot.initialize(admin, admin, protocol);
        DeskPot impl = DeskPot(payable(_impl(pot)));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(jake, jake, jake);
        assertEq(pot.epoch() >= 1, true, "the proxy is set up");
        assertEq(impl.epoch(), 0, "the implementation holds nothing");
    }

    function test_upgrade_onlyTheUpgrader() public {
        DeskPot p = PotDeploy.deploy(address(bem), address(v2), address(v3), address(v3pool), admin, makeAddr("timelock"), protocol);
        address next = _v2();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, p.UPGRADER_ROLE()));
        p.upgradeToAndCall(next, "");
        // the admin cannot hand itself the right either: the upgrader role administers itself
        bytes32 role = p.UPGRADER_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        p.grantRole(role, admin);
        vm.prank(jake);
        vm.expectRevert();
        p.upgradeToAndCall(next, "");
    }

    function test_upgrade_keepsEveryDeskAndVault() public {
        uint256 a = _mintAndStake(emily);
        uint256 b = _mintAndStake(marcus);
        _round();
        _tax(0.03 ether);
        _round();
        uint256 bnbA = pot.claimable(a, 0);
        uint256 bemA = pot.claimable(a, 1);
        uint256 balance = address(pot).balance;
        uint256 epochBefore = pot.epoch();
        assertGt(bnbA, 0);

        pot.upgradeToAndCall(_v2(), ""); // the admin is the upgrader in these tests
        assertEq(DeskPotV2(payable(address(pot))).version(), 2);
        assertEq(pot.claimable(a, 0), bnbA);
        assertEq(pot.claimable(a, 1), bemA);
        assertEq(address(pot).balance, balance);
        assertEq(pot.epoch(), epochBefore);
        assertEq(nft.ownerOf(b), address(pot), "staked desks stay in the same contract");
        assertTrue(pot.isEligible(b));

        uint256 before = emily.balance;
        vm.prank(emily);
        pot.claim(a, 0, bnbA);
        assertEq(emily.balance - before, bnbA);
        _tax(0.03 ether); // rounds and the tax keep working on the new code
        _round();
        assertGt(pot.claimable(b, 0), 0);
        _assertSolvent();
    }

    function test_upgrade_rejectsAContractThatIsNotADeskPot() public {
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, address(bem)));
        pot.upgradeToAndCall(address(bem), "");
    }

    function test_upgrade_throughTheTimelock_waitsTheDelay() public {
        address multisig = makeAddr("multisig");
        address[] memory who = new address[](1);
        who[0] = multisig;
        TimelockController lock = new TimelockController(48 hours, who, who, address(0));
        DeskPot p = PotDeploy.deploy(address(bem), address(v2), address(v3), address(v3pool), admin, address(lock), protocol);
        address next = _v2();
        bytes memory call = abi.encodeCall(p.upgradeToAndCall, (next, ""));

        vm.prank(jake);
        vm.expectRevert(); // only the multisig proposes
        lock.schedule(address(p), 0, call, bytes32(0), bytes32(0), 48 hours);

        vm.prank(multisig);
        vm.expectRevert(); // shorter than the minimum delay
        lock.schedule(address(p), 0, call, bytes32(0), bytes32(0), 1 hours);

        vm.prank(multisig);
        lock.schedule(address(p), 0, call, bytes32(0), bytes32(0), 48 hours);
        vm.prank(multisig);
        vm.expectRevert(); // not yet
        lock.execute(address(p), 0, call, bytes32(0), bytes32(0));

        skip(48 hours);
        vm.prank(jake);
        vm.expectRevert(); // only the multisig executes
        lock.execute(address(p), 0, call, bytes32(0), bytes32(0));
        vm.prank(multisig);
        lock.execute(address(p), 0, call, bytes32(0), bytes32(0));
        assertEq(_impl(p), next);
        assertEq(DeskPotV2(payable(address(p))).version(), 2);
    }

    function test_upgrade_aScheduledUpgradeCanBeCancelled() public {
        address multisig = makeAddr("multisig");
        address[] memory who = new address[](1);
        who[0] = multisig;
        TimelockController lock = new TimelockController(48 hours, who, who, address(0));
        DeskPot p = PotDeploy.deploy(address(bem), address(v2), address(v3), address(v3pool), admin, address(lock), protocol);
        address before = _impl(p);
        bytes memory call = abi.encodeCall(p.upgradeToAndCall, (_v2(), ""));
        vm.startPrank(multisig);
        lock.schedule(address(p), 0, call, bytes32(0), bytes32(0), 48 hours);
        lock.cancel(lock.hashOperation(address(p), 0, call, bytes32(0), bytes32(0)));
        skip(48 hours);
        vm.expectRevert();
        lock.execute(address(p), 0, call, bytes32(0), bytes32(0));
        vm.stopPrank();
        assertEq(_impl(p), before);
    }
}
