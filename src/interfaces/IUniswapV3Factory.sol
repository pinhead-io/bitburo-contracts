// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice The single call on the Uniswap v3 factory that the Rebalancer makes. Written from scratch for this contract
///         (review I-3); only the name and ABI types are fixed.
interface IUniswapV3Factory {
    /// @dev Pool address for the pair and the fee; the order of the tokens does not matter. address(0) if that pool
    ///      does not exist.
    function getPool(address tokenX, address tokenY, uint24 poolFee) external view returns (address);
}
