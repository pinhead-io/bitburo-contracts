// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice De ene aanroep op de Uniswap v3-factory die de Rebalancer doet. Zelf geschreven voor dit contract (review
///         I-3); alleen naam en ABI-typen liggen vast.
interface IUniswapV3Factory {
    /// @dev Pooladres voor het paar en de fee; de volgorde van de tokens maakt niet uit. address(0) als die pool niet
    ///      bestaat.
    function getPool(address tokenX, address tokenY, uint24 poolFee) external view returns (address);
}
