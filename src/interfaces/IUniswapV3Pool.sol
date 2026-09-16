// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.37;

/// @notice Minimale Uniswap v3-poolinterface (github.com/Uniswap/v3-core, IUniswapV3PoolState/Immutables).
interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    /// @dev Fee-tier in hondersten van een bp (500 = 0,05%).
    function fee() external view returns (uint24);
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
