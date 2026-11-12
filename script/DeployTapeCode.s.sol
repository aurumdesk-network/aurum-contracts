// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TapeCodeStaking} from "../src/TapeCodeStaking.sol";

/// @notice Deploys TapeCodeStaking on X Layer. It has no owner: after this, nobody controls it.
/// Env: PRIVATE_KEY (fork); on mainnet leave it unset and pass --account/--ledger with --sender.
///      TAPECODE_NFT (default: TapeCode-Test1 on X Layer)
contract DeployTapeCode is Script {
    function run() external {
        address nft = vm.envOr("TAPECODE_NFT", address(0x0e91460D6823C711643e650A9a4C0cc21DE41614));
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();
        TapeCodeStaking staking = new TapeCodeStaking(nft);
        vm.stopBroadcast();
        console2.log("TapeCodeStaking:", address(staking));
    }
}
