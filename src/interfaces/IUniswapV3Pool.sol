// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.37;

/// @notice Minimale Uniswap v3-poolinterface (github.com/Uniswap/v3-core, IUniswapV3PoolState/Immutables).
interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    /// @dev Fee-tier in hondersten van een bp (500 = 0,05%).
    function fee() external view returns (uint24);
    /// @dev Alleen ticks die een veelvoud hiervan zijn, kunnen geïnitialiseerd zijn (UniswapV3Factory: 10 bij fee 500).
    function tickSpacing() external view returns (int24);
    /// @dev sqrtPriceX96 = sqrt(token1 per token0, in basiseenheden) * 2^96.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    /// @dev In-range liquiditeit op dit moment.
    function liquidity() external view returns (uint128);
    /// @dev Staat per tick (Tick.Info). `liquidityNet` wordt opgeteld bij het kruisen van links naar rechts en
    ///      afgetrokken van rechts naar links; 0 voor een niet-geïnitialiseerde tick.
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );
    /// @dev Ringbuffer van oracle-observaties; de pool schrijft er hooguit één per blok (Oracle.write).
    function observations(uint256 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        );
}
