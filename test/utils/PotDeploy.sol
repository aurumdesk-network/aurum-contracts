// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DeskPot} from "../../src/DeskPot.sol";

/// @dev The Desk Pot as deployed: an implementation behind an ERC-1967 proxy. In tests `upgrader` defaults to the admin.
library PotDeploy {
    function deploy(address bem, address v2, address v3, address bemPool, address admin, address protocol) internal returns (DeskPot) {
        return deploy(bem, v2, v3, bemPool, admin, admin, protocol);
    }

    function deploy(address bem, address v2, address v3, address bemPool, address admin, address upgrader, address protocol)
        internal
        returns (DeskPot)
    {
        DeskPot impl = new DeskPot(bem, v2, v3, bemPool);
        bytes memory init = abi.encodeCall(DeskPot.initialize, (admin, upgrader, protocol));
        return DeskPot(payable(address(new ERC1967Proxy(address(impl), init))));
    }
}
