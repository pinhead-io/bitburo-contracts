// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice The one call on Uniswap SwapRouter02 that the Rebalancer makes. Written from scratch for this contract;
///         only the name, the field order and the ABI types are fixed (selector 0x04e45aaf).
interface IV3SwapRouter {
    /// @dev Swap through the single pool of `tokenIn`, `tokenOut` and `fee`, with a fixed input. Unlike the first
    ///      SwapRouter, SwapRouter02 has no `deadline` field here. `sqrtPriceLimitX96` 0 = no price limit.
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @return amountOut What `recipient` receives of `tokenOut`.
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
