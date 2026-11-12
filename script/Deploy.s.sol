// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {AurumToken} from "../src/AurumToken.sol";
import {DeskPot} from "../src/DeskPot.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeskMinter, ITapeoutCPU} from "../src/DeskMinter.sol";
import {ChipSwap} from "../src/ChipSwap.sol";
import {TapeCodeRewards} from "../src/TapeCodeRewards.sol";

interface IFactory {
    function createPair(address a, address b) external returns (address);
    function getPair(address a, address b) external view returns (address);
}

interface IRouterV2 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256 amountTokenMin, uint256 amountETHMin, address to, uint256 deadline)
        external
        payable
        returns (uint256, uint256, uint256);
}

/// @notice TapeOut's processor factory on BSC (read on a mainnet fork; the source is not verified).
interface ITapeoutFactory {
    function createCPU(string calldata name, string calldata symbol, string calldata story, uint256 supplyCap, uint256 mintPrice)
        external
        payable;
    function deployFee() external view returns (uint256);
    function cpuCount() external view returns (uint256);
    function cpuAt(uint256 i) external view returns (address);
}

/// @notice A CPU's transistors contract: NAND = id 0, LATCH = id 1, one id per mint call.
interface ITapeoutChips {
    function mint(uint256 id, uint256 amount) external payable;
    function mintPrice() external view returns (uint256);
    function protocolFee() external view returns (uint256);
}

/// @notice Deploys and wires AURUM, creates the AURUM/WBNB PancakeSwap V2 pool and seeds it from the
///         (tax-exempt) deployer. Desks are circuits of the AURUM processor on TapeOut.
/// Flow: ChipSwap takes 100,000 AURUM (burned) + 1 BEM for 4 NAND + 2 LATCH; DeskMinter tapes out the desk circuit with them.
/// Env:
///   PRIVATE_KEY (fork); on mainnet leave it unset and pass --account/--ledger with --sender.
///   PROTOCOL (gets 0.2 BEM per chip set, default deployer)
///   BEM (default: BSC mainnet BEM), V2_ROUTER, V3_ROUTER, BEM_POOL (PancakeSwap V3 BEM/WBNB pool the buyback trades on)
///   CPU: the AURUM processor, created by the project on TapeOut. Required on BSC mainnet.
///     If unset (fork only), the script creates one through TAPEOUT_FACTORY with a 30,000 chip cap, mints every
///     chip and stocks ChipSwap with them. On mainnet the project mints its chips and transfers them to ChipSwap.
///   MULTISIG: the project's Safe. Required on BSC mainnet. Every right ends there: the deploying wallet keeps none
///     (checked at the end). It only has to accept the AURUM ownership once (acceptOwnership). Default on a fork: the deployer.
///   CHIPS_OWNER (ChipSwap owner, default MULTISIG)
///   SEED_DESK, SEED_BNB: first liquidity, from the deployer. Fork default 400M AURUM + 20 BNB. On mainnet both must be
///     set; SEED_BNB=0 only creates the pool, for the team to add liquidity later from a tax-exempt wallet.
///   TAPECODE_OWNER (publishes the TapeCode payout lists, default MULTISIG)
///   UPGRADE_ADMIN (proposes and executes Desk Pot upgrades through the timelock, default MULTISIG)
///   UPGRADE_DELAY (seconds every upgrade waits in the timelock, default 172800 = 48 hours)
contract Deploy is Script {
    uint256 internal constant NAND_ID = 0;
    uint256 internal constant LATCH_ID = 1;
    uint256 internal constant NAND_PER = 4;
    uint256 internal constant LATCH_PER = 2;
    uint256 internal constant DESKS = 5_000;
    uint256 internal constant SITE_SETS = 1; // one set kept by the project for its DeWEB site circuit
    // 2 inputs, 1 output, 4 NAND + 2 LATCH; taped out successfully on the real TapeOut CPU on a fork.
    // Gates in order, signals 0-1 constants, 2-3 inputs, then one signal per gate:
    //   s4 = NAND(s2,s3)  s5 = LATCH(s4)  s6 = NAND(s5,s3)  s7 = LATCH(s6)  s8 = NAND(s7,s2)  s9 = NAND(s8,s8) -> output
    bytes internal constant DESK_NETLIST = hex"000000020000030100000400000005000003010000060000000700000200000008000008";

    struct Cfg {
        address bem;
        address v2;
        address v3;
        address bemPool;
        address protocol;
        address cpu;
        address factory;
        address multisig;
        address chipsOwner;
        address tapeCodeOwner;
        address upgradeAdmin;
        uint256 upgradeDelay;
        uint256 seedDesk;
        uint256 seedBnb;
    }

    function _cfg(address deployer) internal view returns (Cfg memory c) {
        c.bem = vm.envOr("BEM", address(0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a));
        c.v2 = vm.envOr("V2_ROUTER", address(0x10ED43C718714eb63d5aA57B78B54704E256024E));
        c.v3 = vm.envOr("V3_ROUTER", address(0x1b81D678ffb9C0263b24A97847620C99d213eB14));
        c.bemPool = vm.envOr("BEM_POOL", address(0x28B12792F9D81Bd529Bc5572434E861C9EDbBBC2));
        c.protocol = vm.envOr("PROTOCOL", deployer);
        c.cpu = vm.envOr("CPU", address(0));
        c.factory = vm.envOr("TAPEOUT_FACTORY", address(0x68224F668083c29e9800Be2a646d42d18cedF7e2));
        c.multisig = vm.envOr("MULTISIG", deployer);
        c.chipsOwner = vm.envOr("CHIPS_OWNER", c.multisig);
        c.tapeCodeOwner = vm.envOr("TAPECODE_OWNER", c.multisig);
        c.upgradeAdmin = vm.envOr("UPGRADE_ADMIN", c.multisig);
        c.upgradeDelay = vm.envOr("UPGRADE_DELAY", uint256(48 hours));
        c.seedDesk = vm.envOr("SEED_DESK", uint256(400_000_000 ether));
        c.seedBnb = vm.envOr("SEED_BNB", uint256(20 ether));
    }

    struct Out {
        DeskPot pot;
        address potImpl;
        TimelockController timelock;
        AurumToken desk;
        address cpu;
        DeskMinter minter;
        ChipSwap chips;
        TapeCodeRewards tapeCode;
        address pair;
    }

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address me = pk != 0 ? vm.addr(pk) : msg.sender; // msg.sender = --sender when signing with --account/--ledger
        Cfg memory c = _cfg(me);
        bool createCpu = c.cpu == address(0);
        if (createCpu && block.chainid == 56) revert("CPU (the AURUM processor) required on BSC mainnet");
        if (block.chainid == 56) {
            if (!vm.envExists("MULTISIG") || c.multisig == me) revert("MULTISIG (the project's Safe, not the deploying wallet) required on BSC mainnet");
            if (!vm.envExists("SEED_DESK") || !vm.envExists("SEED_BNB")) revert("SEED_DESK and SEED_BNB required on BSC mainnet (SEED_BNB=0: create the pool only)");
            if (c.multisig.code.length == 0) revert("MULTISIG has no contract code on BSC mainnet: is it the Safe address?");
        }

        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();
        if (createCpu) c.cpu = _createCpu(c.factory);
        Out memory o = _deploy(c, me);
        if (createCpu) _stockChips(o, me);
        o.pair = _seedPool(c, o.desk, me);
        _handOver(c, o, me);
        vm.stopBroadcast();

        console2.log("DeskPot:     ", address(o.pot));
        console2.log("AurumToken:  ", address(o.desk));
        console2.log("AurumCPU: ", o.cpu);
        console2.log("DeskMinter:  ", address(o.minter));
        console2.log("ChipSwap:    ", address(o.chips));
        console2.log("Chips:       ", ITapeoutCPU(o.cpu).transistors());
        console2.log("ChipStock:   ", o.chips.setsLeft());
        console2.log("DeskPair:    ", o.pair);
        console2.log("TapeCodeRewards:", address(o.tapeCode));
        console2.log("DeskPotImpl: ", o.potImpl);
        console2.log("UpgradeTimelock:", address(o.timelock));
        console2.log("Multisig:    ", c.multisig);
        if (c.multisig != me) {
            console2.log("NEXT: the multisig calls AurumToken.acceptOwnership() once. Until then the token owner is still pending.");
        }
    }

    function _deploy(Cfg memory c, address me) internal returns (Out memory o) {
        o.cpu = c.cpu;
        o.pot = _deployPot(c, me, o);
        o.desk = new AurumToken("AURUM", "AURUM", 1_000_000_000 ether, me, address(o.pot), c.v2, me);
        o.minter = new DeskMinter(
            DeskMinter.Config(c.cpu, NAND_ID, LATCH_ID, NAND_PER, LATCH_PER, DESK_NETLIST, 2, 1), c.multisig
        );
        address chips = ITapeoutCPU(c.cpu).transistors();
        ChipSwap.Element[] memory set = new ChipSwap.Element[](2);
        set[0] = ChipSwap.Element(chips, NAND_ID, NAND_PER);
        set[1] = ChipSwap.Element(chips, LATCH_ID, LATCH_PER);
        o.chips = new ChipSwap(address(o.desk), c.bem, address(o.pot), c.protocol, set, c.chipsOwner);
        o.pot.wire(address(o.desk), c.cpu, address(o.minter), address(o.chips));
        o.tapeCode = new TapeCodeRewards(c.tapeCodeOwner);
        o.pot.setTapeCodeRewards(address(o.tapeCode));
    }

    /// The Desk Pot behind its proxy. Only the timelock may upgrade it; UPGRADE_ADMIN proposes and executes there.
    function _deployPot(Cfg memory c, address me, Out memory o) internal returns (DeskPot) {
        address[] memory admins = new address[](1);
        admins[0] = c.upgradeAdmin;
        o.timelock = new TimelockController(c.upgradeDelay, admins, admins, address(0));
        o.potImpl = address(new DeskPot(c.bem, c.v2, c.v3, c.bemPool));
        bytes memory init = abi.encodeCall(DeskPot.initialize, (me, address(o.timelock), c.protocol));
        return DeskPot(payable(address(new ERC1967Proxy(o.potImpl, init))));
    }

    /// The AURUM processor: chip cap = 5,000 sets for ChipSwap + 1 for the project's site circuit, all minted by the
    /// project, so nobody can mint chips beyond that.
    function _createCpu(address factory) internal returns (address) {
        ITapeoutFactory f = ITapeoutFactory(factory);
        f.createCPU{value: f.deployFee()}("Aurum Desk", "Aurum Core", "Desks of the AURUM revenue pool", (DESKS + SITE_SETS) * (NAND_PER + LATCH_PER), 1);
        return f.cpuAt(f.cpuCount() - 1);
    }

    /// Mints the whole chip supply (the price comes back to the creator) and stocks ChipSwap with 5,000 sets.
    function _stockChips(Out memory o, address me) internal {
        ITapeoutChips t = ITapeoutChips(ITapeoutCPU(o.cpu).transistors());
        uint256 price = t.mintPrice();
        uint256 fee = t.protocolFee();
        uint256 sets = DESKS + SITE_SETS;
        t.mint{value: price * sets * NAND_PER + fee}(NAND_ID, sets * NAND_PER);
        t.mint{value: price * sets * LATCH_PER + fee}(LATCH_ID, sets * LATCH_PER);
        IERC1155(address(t)).safeTransferFrom(me, address(o.chips), NAND_ID, DESKS * NAND_PER, "");
        IERC1155(address(t)).safeTransferFrom(me, address(o.chips), LATCH_ID, DESKS * LATCH_PER, "");
    }

    /// Every right goes to the multisig; the deploying wallet keeps none. Its AURUM and LP stay in it until moved by hand.
    function _handOver(Cfg memory c, Out memory o, address me) internal {
        if (c.multisig == me) return; // a fork run with no MULTISIG
        bytes32 admin = o.pot.DEFAULT_ADMIN_ROLE();
        bytes32 pauser = o.pot.PAUSER_ROLE();
        o.pot.grantRole(admin, c.multisig);
        o.pot.grantRole(pauser, c.multisig);
        o.pot.renounceRole(pauser, me);
        o.pot.renounceRole(admin, me); // last: the multisig already holds it
        o.desk.setTaxExempt(c.multisig, true); // the multisig may add liquidity later without paying the 5%
        o.desk.transferOwnership(c.multisig); // two steps: the multisig accepts it

        // nothing is left with the deploying wallet
        require(!o.pot.hasRole(admin, me) && !o.pot.hasRole(pauser, me), "deployer still holds a Desk Pot role");
        require(o.pot.hasRole(admin, c.multisig) && o.pot.hasRole(pauser, c.multisig), "multisig lacks a Desk Pot role");
        require(!o.pot.hasRole(o.pot.UPGRADER_ROLE(), me), "deployer can upgrade");
        require(o.desk.pendingOwner() == c.multisig, "AURUM hand-over not started");
        require(o.minter.owner() == c.multisig, "DeskMinter owner");
        require(o.chips.owner() == c.chipsOwner && o.tapeCode.owner() == c.tapeCodeOwner, "ChipSwap or TapeCodeRewards owner");
        require(!o.timelock.hasRole(o.timelock.PROPOSER_ROLE(), me) || c.upgradeAdmin == me, "deployer can propose upgrades");
    }

    /// AURUM/WBNB pool, seeded tax-free by the deployer.
    function _seedPool(Cfg memory c, AurumToken desk, address me) internal returns (address pair) {
        IRouterV2 router = IRouterV2(c.v2);
        IFactory factory = IFactory(router.factory());
        pair = factory.getPair(address(desk), router.WETH());
        if (pair == address(0)) pair = factory.createPair(address(desk), router.WETH());
        desk.setTaxExempt(me, true);
        desk.setPair(pair);
        if (c.seedBnb != 0) {
            desk.approve(c.v2, c.seedDesk);
            router.addLiquidityETH{value: c.seedBnb}(address(desk), c.seedDesk, 0, 0, me, block.timestamp + 600);
        }
    }
}
