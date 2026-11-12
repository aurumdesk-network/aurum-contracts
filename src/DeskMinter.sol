// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice The parts of a TapeOut processor (CPU) this contract uses. The CPU is the ERC-721 of its circuits;
///         tapeout() burns the netlist's NAND/LATCH from the caller and mints the new circuit to the caller.
interface ITapeoutCPU {
    function tapeout(bytes calldata netlist, uint32 inputs, uint32 outputs) external payable;
    function TAPEOUT_FEE() external view returns (uint256);
    function nextId() external view returns (uint256); // id of the most recent circuit
    function transistors() external view returns (address);
    function circuitInfo(uint256 id) external view returns (uint256 inputs, uint256 outputs, uint256 latches, uint256 gates);
}

/// @title DeskMinter
/// @notice Mints desks as real TapeOut circuits on the AURUM processor, so they trade wherever TapeOut circuits do.
///         Mint = one chip set (4 NAND + 2 LATCH, burned by the tape-out) + the processor's tape-out fee in BNB.
///         Every desk is the same fixed circuit. Max 5,000.
///         A desk is any circuit on the processor built from exactly one chip set, minted here or taped out straight on
///         TapeOut, whatever its wiring: every chip came from ChipSwap, so its AURUM and BEM are paid, and 5,000 sets can
///         only ever make 5,000 such circuits. TapeOut also accepts smaller circuits; they are not desks, or one set
///         could become six of them. The project's site circuit must not use this chip count (see the guide).
///         AURUM and BEM are paid one step earlier: ChipSwap takes 100,000 AURUM + 1 BEM per chip set.
contract DeskMinter is ERC1155Holder, IERC721Receiver, Ownable2Step, ReentrancyGuard {
    uint256 public constant MAX_SUPPLY = 5_000;

    ITapeoutCPU public immutable cpu;
    IERC721 public immutable circuits; // the CPU itself
    IERC1155 public immutable chips; // the CPU's NAND/LATCH
    uint256 public immutable nandId;
    uint256 public immutable latchId;
    uint256 public immutable nandPer;
    uint256 public immutable latchPer;
    uint32 public immutable inputs;
    uint32 public immutable outputs;

    bytes public netlist; // the desk circuit; must use exactly nandPer NAND and latchPer LATCH
    uint256 public totalMinted;
    uint256[] public desks; // circuit ids, in mint order

    event DeskMinted(address indexed to, uint256 indexed tokenId);

    error SoldOut();
    error ZeroAddress();
    error FeeTooLow();
    error TapeoutFailed();
    error RefundFailed();

    struct Config {
        address cpu;
        uint256 nandId;
        uint256 latchId;
        uint256 nandPer;
        uint256 latchPer;
        bytes netlist;
        uint32 inputs;
        uint32 outputs;
    }

    constructor(Config memory c, address owner_) Ownable(owner_) {
        if (c.cpu == address(0)) revert ZeroAddress();
        cpu = ITapeoutCPU(c.cpu);
        circuits = IERC721(c.cpu);
        chips = IERC1155(ITapeoutCPU(c.cpu).transistors());
        nandId = c.nandId;
        latchId = c.latchId;
        nandPer = c.nandPer;
        latchPer = c.latchPer;
        netlist = c.netlist;
        inputs = c.inputs;
        outputs = c.outputs;
    }

    /// @notice Caller must approve this contract for its chips (setApprovalForAll) and send at least
    ///         tapeoutFee() in BNB (any excess is refunded). The new circuit goes to the caller.
    function mint() external payable nonReentrant returns (uint256 tokenId) {
        if (totalMinted >= MAX_SUPPLY) revert SoldOut();
        uint256 fee = cpu.TAPEOUT_FEE();
        if (msg.value < fee) revert FeeTooLow();

        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        (ids[0], ids[1], amounts[0], amounts[1]) = (nandId, latchId, nandPer, latchPer);
        chips.safeBatchTransferFrom(msg.sender, address(this), ids, amounts, "");

        // the tape-out burns this contract's chips and mints the circuit here
        cpu.tapeout{value: fee}(netlist, inputs, outputs);
        tokenId = cpu.nextId();
        if (circuits.ownerOf(tokenId) != address(this)) revert TapeoutFailed();

        desks.push(tokenId);
        ++totalMinted;
        circuits.transferFrom(address(this), msg.sender, tokenId);
        emit DeskMinted(msg.sender, tokenId);

        if (msg.value > fee) {
            (bool ok,) = msg.sender.call{value: msg.value - fee}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @notice Whether a circuit counts as a desk: built from exactly nandPer NAND + latchPer LATCH. TapeOut counts every
    ///         gate, LATCH included, and burns one chip per gate, so this is what it really cost. False for a missing id.
    function isDesk(uint256 id) external view returns (bool) {
        try cpu.circuitInfo(id) returns (uint256, uint256, uint256 latches, uint256 gates) {
            return latches == latchPer && gates == nandPer + latchPer;
        } catch {
            return false;
        }
    }

    function tapeoutFee() external view returns (uint256) {
        return cpu.TAPEOUT_FEE();
    }

    /// @dev The CPU may mint with _safeMint.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
