// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice The two calls on Uniswap SwapRouter02 that the Rebalancer makes. Written from scratch for this contract
///         (review I-3); only names, field order and ABI types are fixed.
interface IV3SwapRouter {
    /// @dev Swap along a path with a fixed input. Unlike the first SwapRouter, SwapRouter02 has no `deadline` field
    ///      here. `path` is token, fee (3 bytes), token, fee, token, concatenated.
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @return amountOut What `recipient` receives of the last token.
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    /// @dev The Uniswap v3 factory whose pools the router uses.
    function factory() external view returns (address);
}
