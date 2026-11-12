// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {DeskPot} from "../src/DeskPot.sol";

interface ITimelock {
    function getMinDelay() external view returns (uint256);
    function hashOperation(address target, uint256 value, bytes calldata data, bytes32 predecessor, bytes32 salt)
        external
        pure
        returns (bytes32);
}

/// @notice Step 1 of a Desk Pot upgrade: deploys the new implementation (anyone may) and prints what the multisig sends
///         to the timelock. It schedules, waits the delay, then executes; nothing changes before that.
/// Env: POT (the Desk Pot proxy), TIMELOCK (the upgrade timelock), SALT (optional, any bytes32, to tell two
///      operations with the same call apart). BEM, V2_ROUTER, V3_ROUTER, BEM_POOL as in Deploy.s.sol.
///      PRIVATE_KEY on a fork; on mainnet pass --account/--ledger with --sender.
/// Before running: the new DeskPot must keep every state variable in place and only append new ones.
contract UpgradePot is Script {
    function run() external {
        address pot = vm.envAddress("POT");
        address timelock = vm.envAddress("TIMELOCK");
        bytes32 salt = vm.envOr("SALT", bytes32(0));
        address bem = vm.envOr("BEM", address(0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a));
        address v2 = vm.envOr("V2_ROUTER", address(0x10ED43C718714eb63d5aA57B78B54704E256024E));
        address v3 = vm.envOr("V3_ROUTER", address(0x1b81D678ffb9C0263b24A97847620C99d213eB14));
        address bemPool = vm.envOr("BEM_POOL", address(0x28B12792F9D81Bd529Bc5572434E861C9EDbBBC2));

        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();
        address impl = address(new DeskPot(bem, v2, v3, bemPool));
        vm.stopBroadcast();

        bytes memory call = abi.encodeCall(DeskPot(payable(pot)).upgradeToAndCall, (impl, ""));
        uint256 delay = ITimelock(timelock).getMinDelay();
        console2.log("New implementation:", impl);
        console2.log("Timelock delay (seconds):", delay);
        console2.log("1) Multisig calls the timelock: schedule(target, value, data, predecessor, salt, delay)");
        console2.log("   target ", pot);
        console2.log("   value   0");
        console2.log("   data");
        console2.logBytes(call);
        console2.log("   predecessor 0x0000000000000000000000000000000000000000000000000000000000000000");
        console2.log("   salt");
        console2.logBytes32(salt);
        console2.log("2) After the delay: execute(target, value, data, predecessor, salt) with the same values");
        console2.log("   operation id (to watch or cancel):");
        console2.logBytes32(ITimelock(timelock).hashOperation(pot, 0, call, bytes32(0), salt));
    }
}
