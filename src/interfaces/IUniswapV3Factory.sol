// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.37;

/// @notice Minimale Uniswap v3-factoryinterface (github.com/Uniswap/v3-core, IUniswapV3Factory).
interface IUniswapV3Factory {
    /// @dev Geeft voor beide tokenvolgordes hetzelfde pooladres; address(0) als de pool niet bestaat.
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}
