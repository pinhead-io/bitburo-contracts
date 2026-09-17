// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Read calls on a Uniswap v3 pool that the Rebalancer makes, and nothing more. Written from scratch for this
///         contract (review I-3): only the function names and the ABI types are fixed, because they determine the
///         selector and the decoding. Semantics: docs.uniswap.org/contracts/v3/reference/core/UniswapV3Pool.
interface IUniswapV3Pool {
    /// @dev Address of the token with the lower address of the pair.
    function token0() external view returns (address);

    /// @dev Address of the other token.
    function token1() external view returns (address);

    /// @dev Swap fee in millionths (500 = 0.05%).
    function fee() external view returns (uint24);

    /// @dev Distance between ticks that can carry liquidity (10 at fee 500).
    function tickSpacing() external view returns (int24);

    /// @dev Current state. `sqrtPriceX96` is √(token1 per token0, in base units) × 2^96; `observationIndex` points
    ///      to the most recently written oracle observation. The Rebalancer does not read the other fields.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 cardinality,
            uint16 cardinalityNext,
            uint8 protocolFee,
            bool unlocked
        );

    /// @dev Liquidity that is active at the current price.
    function liquidity() external view returns (uint128);

    /// @dev Data of one tick. The Rebalancer only uses `netLiquidity`: what is added when the price crosses the tick
    ///      from below to above (and removed in the other direction); 0 if the tick is not in use.
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 grossLiquidity,
            int128 netLiquidity,
            uint256 outsideFeeGrowth0,
            uint256 outsideFeeGrowth1,
            int56 outsideTickCumulative,
            uint160 outsideSecondsPerLiquidity,
            uint32 outsideSeconds,
            bool inUse
        );

    /// @dev Oracle observation at `index`. The Rebalancer only uses `timestamp`: the block in which the pool wrote
    ///      that observation (at most one per block).
    function observations(uint256 index)
        external
        view
        returns (uint32 timestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulative, bool filled);
}
