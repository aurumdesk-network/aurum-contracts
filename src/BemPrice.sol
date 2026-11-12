// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IPancakeV3SwapRouter {
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

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice The parts of the PancakeSwap V3 BEM/WBNB pool a BEM buy reads. PancakeSwap's slot0 packs feeProtocol
///         as uint32 (Uniswap: uint8), so it is declared as uint32 here.
interface IPancakeV3PoolLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint32, bool);
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tickCumulatives, uint160[] memory);
}

/// @notice The on-chain price guard of the Desk Pot's BEM buys.
library BemPrice {
    uint32 internal constant TWAP_WINDOW = 30 minutes;
    int24 internal constant MAX_TICK_DEVIATION = 200; // ~2%: a spot price further from the 30-minute average means manipulation
    uint256 internal constant BUY_SLIPPAGE_BPS = 200; // minimum out = spot price - pool fee - 2%
    uint256 private constant BPS = 10_000;

    /// @dev Minimum BEM for `bnbIn` at the pool's spot price, after its fee and BUY_SLIPPAGE_BPS. Zero (= do not
    ///      buy) when the pool cannot be read, has no 30-minute history, or its spot tick is off that average.
    function minOut(IPancakeV3PoolLike pool, uint24 poolFee, bool bemIsToken0, uint256 bnbIn) internal view returns (uint256) {
        uint160 sqrtP;
        int24 tick;
        try pool.slot0() returns (uint160 s0, int24 t0, uint16, uint16, uint16, uint32, bool) {
            (sqrtP, tick) = (s0, t0);
        } catch {
            return 0;
        }
        if (sqrtP == 0) return 0;

        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW; // ago[1] = 0: now
        int24 avg;
        try pool.observe(ago) returns (int56[] memory cum, uint160[] memory) {
            int56 delta = cum[1] - cum[0];
            int56 window = int56(uint56(TWAP_WINDOW));
            avg = int24(delta / window);
            if (delta < 0 && delta % window != 0) --avg; // round toward negative infinity
        } catch {
            return 0;
        }
        int24 dev = tick > avg ? tick - avg : avg - tick;
        if (dev > MAX_TICK_DEVIATION) return 0;

        // spot price = token1 per token0 = (sqrtP / 2^96)^2
        uint256 q = 1 << 96;
        uint256 spotOut = bemIsToken0
            ? Math.mulDiv(Math.mulDiv(bnbIn, q, sqrtP), q, sqrtP) // BEM = BNB / price
            : Math.mulDiv(Math.mulDiv(bnbIn, sqrtP, q), sqrtP, q); // BEM = BNB * price
        return (((spotOut * (1e6 - poolFee)) / 1e6) * (BPS - BUY_SLIPPAGE_BPS)) / BPS;
    }
}
