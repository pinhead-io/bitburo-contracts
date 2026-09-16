// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.37;

/// @notice Minimale Uniswap SwapRouter02-interface (github.com/Uniswap/swap-router-contracts, IV3SwapRouter).
/// @dev SwapRouter02 heeft geen `deadline` in ExactInputParams, anders dan de oude SwapRouter.
interface IV3SwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    /// @dev Uit IPeripheryImmutableState: de Uniswap v3-factory waarvan de router de pools gebruikt.
    function factory() external view returns (address);
}
