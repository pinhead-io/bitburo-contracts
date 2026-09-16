// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "../../src/libraries/TickMath.sol";

/// @notice Uniswap v3-pool met een instelbare sqrtPriceX96, fee-tier, liquiditeit en observations, en vaste
///         token0/token1. De tick volgt altijd uit sqrtPriceX96 (grootste t met P(t) <= sqrtPriceX96), zoals in de
///         echte pool.
/// @dev Twee manieren om de koers te zetten:
///      - `setPrice`/`setSqrtPriceX96`: de koers stond al zo vóór dit blok (er wordt geen observatie geschreven);
///      - `swapToPrice`/`swapToSqrtPriceX96`: een swap in dit blok. Verandert de tick, dan schrijft de mock net als
///        UniswapV3Pool.swap → Oracle.write een observatie met de oude tick, hooguit één per blok.
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
    /// @dev Standaard zo groot dat het blokvenster de run nooit begrenst; `setLiquidity` voor die tests.
    uint128 public liquidity = type(uint128).max;
    uint16 public observationIndex;
    uint16 public observationCardinality = 2;
    mapping(uint256 index => Observation) internal _observations;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
        // Eén geïnitialiseerde observatie ver in het verleden: de koers is dit blok niet veranderd.
        _observations[0] = Observation({blockTimestamp: 1, tickCumulative: 0, initialized: true});
    }

    /// @notice Zet de spot zodat `token1Amount` basiseenheden token1 gelijk staan aan `token0Amount` token0.
    function setPrice(uint256 token0Amount, uint256 token1Amount) external {
        _set(_sqrtOf(token0Amount, token1Amount));
    }

    /// @notice Zet sqrtPriceX96 rechtstreeks (voor randgevallen als MIN/MAX_SQRT_RATIO).
    function setSqrtPriceX96(uint160 value) external {
        _set(value);
    }

    /// @notice Als `setPrice`, maar als swap in het huidige blok (schrijft een observatie bij een tickwissel).
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

    /// @dev Oracle.write: hooguit één observatie per blok, met de tick die tot nu toe gold.
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

    /// @dev Grootste tick t met getSqrtPriceAtTick(t) <= value (binair zoeken).
    function _tickAt(uint160 value) internal pure returns (int24) {
        int256 lo = TickMath.MIN_TICK;
        int256 hi = TickMath.MAX_TICK;
        if (value < TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK)) return TickMath.MIN_TICK;
        while (lo < hi) {
            // In (lo, hi]: Solidity rondt naar nul af, dus bij een negatieve som naar boven; dat blijft <= hi.
            int256 mid = (lo + hi + 1) / 2;
            // forge-lint: disable-next-line(unsafe-typecast)
            if (TickMath.getSqrtPriceAtTick(int24(mid)) <= value) lo = mid;
            else hi = mid - 1;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(lo);
    }
}
