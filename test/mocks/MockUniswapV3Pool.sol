// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "../../src/libraries/TickMath.sol";

/// @notice Uniswap v3 pool with a configurable sqrtPriceX96, fee tier, liquidity and observations, and fixed
///         token0/token1. The tick always follows from sqrtPriceX96 (largest t with P(t) <= sqrtPriceX96), as in the
///         real pool.
/// @dev Two ways to set the price:
///      - `setPrice`/`setSqrtPriceX96`: the price was already like this before this block (no observation is written);
///      - `swapToPrice`/`swapToSqrtPriceX96`: a swap in this block. If the tick changes, the mock, just like
///        UniswapV3Pool.swap → Oracle.write, writes an observation with the old tick, at most one per block.
contract MockUniswapV3Pool is IUniswapV3Pool {
    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        bool initialized;
    }

    address public immutable token0;
    address public immutable token1;
    uint160 public sqrtPriceX96;
    int24 public tick;
    uint24 public fee = 500;
    int24 public tickSpacing = 10;
    /// @dev `liquidityNet` per tick; default 0 (not initialized), so the run size is unaffected by boundaries.
    mapping(int24 tick => int128) public liquidityNetAt;
    /// @dev By default so large that the block window never limits the run; `setLiquidity` for those tests.
    uint128 public liquidity = type(uint128).max;
    uint16 public observationIndex;
    uint16 public observationCardinality = 2;
    mapping(uint256 index => Observation) internal _observations;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
        // One initialized observation far in the past: the price has not changed in this block.
        _observations[0] = Observation({blockTimestamp: 1, tickCumulative: 0, initialized: true});
    }

    /// @notice Sets the spot so that `token1Amount` base units of token1 equal `token0Amount` of token0.
    function setPrice(uint256 token0Amount, uint256 token1Amount) external {
        _set(_sqrtOf(token0Amount, token1Amount));
    }

    /// @notice Sets sqrtPriceX96 directly (for edge cases such as MIN/MAX_SQRT_RATIO).
    function setSqrtPriceX96(uint160 value) external {
        _set(value);
    }

    /// @notice Like `setPrice`, but as a swap in the current block (writes an observation on a tick change).
    function swapToPrice(uint256 token0Amount, uint256 token1Amount) external {
        swapToSqrtPriceX96(_sqrtOf(token0Amount, token1Amount));
    }

    function swapToSqrtPriceX96(uint160 value) public {
        int24 newTick = _tickAt(value);
        if (newTick != tick) _write(tick);
        sqrtPriceX96 = value;
        tick = newTick;
    }

    function setFee(uint24 value) external {
        fee = value;
    }

    function setTickSpacing(int24 value) external {
        tickSpacing = value;
    }

    /// @notice Sets `liquidityNet` of `tick_`, as a position with that tick as a boundary does in the real pool.
    function setLiquidityNet(int24 tick_, int128 net) external {
        liquidityNetAt[tick_] = net;
    }

    function ticks(int24 tick_)
        external
        view
        returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool)
    {
        int128 net = liquidityNetAt[tick_];
        uint128 gross = uint128(net < 0 ? -net : net);
        return (gross, net, 0, 0, 0, 0, 0, net != 0);
    }

    function setLiquidity(uint128 value) external {
        liquidity = value;
    }

    function setObservationCardinality(uint16 value) external {
        observationCardinality = value;
    }

    function setObservationIndex(uint16 value) external {
        observationIndex = value;
    }

    function setObservation(uint256 index, uint32 blockTimestamp, int56 tickCumulative, bool initialized) external {
        _observations[index] =
            Observation({blockTimestamp: blockTimestamp, tickCumulative: tickCumulative, initialized: initialized});
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, tick, observationIndex, observationCardinality, observationCardinality, 0, true);
    }

    function observations(uint256 index) external view returns (uint32, int56, uint160, bool) {
        Observation memory o = _observations[index];
        return (o.blockTimestamp, o.tickCumulative, 0, o.initialized);
    }

    function _set(uint160 value) internal {
        sqrtPriceX96 = value;
        tick = _tickAt(value);
    }

    /// @dev Oracle.write: at most one observation per block, with the tick that applied until now.
    function _write(int24 tickBefore) internal {
        Observation memory last = _observations[observationIndex];
        if (last.blockTimestamp == uint32(block.timestamp)) return;
        uint16 next = uint16((uint256(observationIndex) + 1) % observationCardinality);
        _observations[next] = Observation({
            blockTimestamp: uint32(block.timestamp),
            tickCumulative: last.tickCumulative + int56(tickBefore)
                * int56(uint56(uint32(block.timestamp) - last.blockTimestamp)),
            initialized: true
        });
        observationIndex = next;
    }

    function _sqrtOf(uint256 token0Amount, uint256 token1Amount) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(token1Amount, 1 << 192, token0Amount)));
    }

    /// @dev Largest tick t with getSqrtPriceAtTick(t) <= value (binary search).
    function _tickAt(uint160 value) internal pure returns (int24) {
        int256 lo = TickMath.MIN_TICK;
        int256 hi = TickMath.MAX_TICK;
        if (value < TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK)) return TickMath.MIN_TICK;
        while (lo < hi) {
            // In (lo, hi]: Solidity rounds toward zero, so upward for a negative sum; that stays <= hi.
            int256 mid = (lo + hi + 1) / 2;
            // forge-lint: disable-next-line(unsafe-typecast)
            if (TickMath.getSqrtPriceAtTick(int24(mid)) <= value) lo = mid;
            else hi = mid - 1;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(lo);
    }
}
