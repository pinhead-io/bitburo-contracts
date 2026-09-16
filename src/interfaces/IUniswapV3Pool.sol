// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.37;

/// @notice Minimale Uniswap v3-poolinterface (github.com/Uniswap/v3-core, IUniswapV3PoolState/Immutables).
interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
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
}
