// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice De twee aanroepen op Uniswap SwapRouter02 die de Rebalancer doet. Zelf geschreven voor dit contract (review
///         I-3); alleen namen, veldvolgorde en ABI-typen liggen vast.
interface IV3SwapRouter {
    /// @dev Swap over een pad met een vaste input. SwapRouter02 kent hier geen `deadline`-veld, anders dan de eerste
    ///      SwapRouter. `path` is token, fee (3 bytes), token, fee, token, aaneengesloten.
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @return amountOut Wat `recipient` van het laatste token ontvangt.
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    /// @dev De Uniswap v3-factory waarvan de router de pools gebruikt.
    function factory() external view returns (address);
}
