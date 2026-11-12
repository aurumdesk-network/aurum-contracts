// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @dev BEM stand-in: 8 decimals, plain transfers, no burn (like the real BEM).
contract MockBEM is ERC20 {
    constructor() ERC20("BEM", "BEM") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract MockToken is ERC20 {
    uint8 internal immutable dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        dec = d;
    }

    function decimals() public view override returns (uint8) {
        return dec;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract MockWBNB is ERC20 {
    constructor() ERC20("Wrapped BNB", "WBNB") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// @dev TapeOut circuit elements stand-in (NAND = id 1, LATCH = id 2).
contract MockElements is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

/// @dev PancakeSwap V2 router stand-in: sells a token for BNB at a fixed rate (BNB per 1e18 tokens).
contract MockV2Router {
    address public immutable WETH;
    mapping(address => uint256) public sellRate;

    constructor(address weth) {
        WETH = weth;
    }

    receive() external payable {}

    function setSellRate(address token, uint256 r) external {
        sellRate[token] = r;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory a) {
        a = new uint256[](2);
        a[0] = amountIn;
        a[1] = (amountIn * sellRate[path[0]]) / 1 ether;
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, "EXPIRED");
        require(path[path.length - 1] == WETH, "path");
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * sellRate[path[0]]) / 1 ether;
        require(out >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");
        (bool ok,) = to.call{value: out}("");
        require(ok, "ETH");
    }
}

/// @dev PancakeSwap V3 SwapRouter stand-in: buys BEM with BNB at a fixed rate (BEM units per 1 BNB).
contract MockV3Router {
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

    address public immutable WETH9;
    MockBEM public immutable bem;
    uint256 public rate; // BEM units per 1e18 wei
    bool public broken; // simulate no liquidity / router failure
    uint24 public lastFee;

    constructor(address weth, address bem_) {
        WETH9 = weth;
        bem = MockBEM(bem_);
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        require(!broken, "no liquidity");
        require(block.timestamp <= p.deadline, "Transaction too old");
        require(p.tokenIn == WETH9 && p.tokenOut == address(bem) && msg.value == p.amountIn, "params");
        lastFee = p.fee;
        out = (p.amountIn * rate) / 1 ether;
        require(out >= p.amountOutMinimum, "Too little received");
        bem.mint(p.recipient, out);
    }
}

/// @dev TapeOut processor stand-in, matching what the real BSC contracts do (read on a mainnet fork):
///      the CPU is the ERC-721 of its circuits, NAND = id 0 and LATCH = id 1 on its transistors contract,
///      netlist gates are 0x00 + two 3-byte inputs (NAND) or 0x01 + one 3-byte input (LATCH),
///      tapeout() takes a fixed fee, burns the gates' chips from the caller and mints the circuit to the caller.
contract MockTapeoutCPU is ERC721 {
    uint256 public constant TAPEOUT_FEE = 0.0002 ether;
    MockChips public immutable transistors;
    uint256 public nextId; // most recent circuit id, like the real CPU
    mapping(uint256 => bytes) public netlist;
    mapping(uint256 => uint256[2]) private counts; // gates, latches

    constructor() ERC721("Aurum Desk", "Aurum Core") {
        transistors = new MockChips(address(this));
    }

    function tapeout(bytes calldata nl, uint32, uint32) external payable {
        require(msg.value == TAPEOUT_FEE, "fee");
        uint256 nand;
        uint256 latch;
        for (uint256 i; i < nl.length;) {
            if (nl[i] == 0x00) {
                ++nand;
                i += 7;
            } else {
                ++latch;
                i += 4;
            }
        }
        if (nand != 0) transistors.burnFrom(msg.sender, 0, nand);
        if (latch != 0) transistors.burnFrom(msg.sender, 1, latch);
        netlist[++nextId] = nl;
        counts[nextId] = [nand + latch, latch];
        _safeMint(msg.sender, nextId);
    }

    /// @dev Same shape as the real CPU: `gates` counts every gate, LATCH included. Reverts for a missing circuit.
    function circuitInfo(uint256 id) external view returns (uint256 inputs, uint256 outputs, uint256 latches, uint256 gates) {
        _requireOwned(id);
        return (2, 1, counts[id][1], counts[id][0]);
    }
}

/// @dev The CPU's NAND (0) / LATCH (1). Anyone may mint here; only the CPU burns.
contract MockChips is ERC1155 {
    address public immutable cpu;

    constructor(address cpu_) ERC1155("") {
        cpu = cpu_;
    }

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    function burnFrom(address from, uint256 id, uint256 amount) external {
        require(msg.sender == cpu, "only cpu");
        _burn(from, id, amount);
    }
}

/// @dev PancakeSwap V3 BEM/WBNB pool stand-in for the on-chain buyback checks: slot0 (spot price and tick) and a
///      30-minute average tick through observe(). The swap itself happens in MockV3Router at its own rate.
contract MockV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public constant fee = 10_000;
    uint160 public sqrtPriceX96;
    int24 public tick;
    int24 public twapTick;
    bool public noHistory;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setPrice(uint160 s) external {
        sqrtPriceX96 = s;
    }

    function setTicks(int24 spot, int24 average) external {
        tick = spot;
        twapTick = average;
    }

    function setNoHistory(bool v) external {
        noHistory = v;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (sqrtPriceX96, tick, 0, 1, 1, 0, true);
    }

    function observe(uint32[] calldata ago) external view returns (int56[] memory c, uint160[] memory s) {
        require(!noHistory, "OLD");
        c = new int56[](ago.length);
        s = new uint160[](ago.length);
        // cumulative ticks whose average over any window is twapTick
        for (uint256 i; i < ago.length; ++i) c[i] = int56(twapTick) * int56(uint56(1_000_000 - ago[i]));
    }
}
