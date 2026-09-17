// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IV3SwapRouter} from "../../src/interfaces/IV3SwapRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Uniswap SwapRouter02 imitation for the single USDC/cbBTC 0.05% pool. Pays out at a configurable pool
///         price (USDC base units per cbBTC), made worse or better by `worseBps`.
contract MockRouter is IV3SwapRouter {
    uint24 public constant POOL_FEE = 500;

    address public immutable USDC;
    address public immutable CBBTC;

    uint256 public price;
    /// @dev Positive = the swapper receives that many bps less than at `price`; negative = more.
    int256 public worseBps;
    /// @dev A router that does not enforce `amountOutMinimum`, to test the contract's own bound.
    bool public ignoreMinimum;
    /// @dev Share of `amountIn` the pool can absorb; below 10,000 the rest stays with the caller, as in a real pool
    ///      that runs out of liquidity before the input is used up.
    uint256 public fillBps = 10_000;
    uint256 public calls;
    address public lastRecipient;
    uint256 public lastAmountIn;
    uint256 public lastAmountOutMinimum;

    constructor(address usdc, address cbbtc, uint256 price_) {
        USDC = usdc;
        CBBTC = cbbtc;
        price = price_;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function setWorseBps(int256 bps) external {
        worseBps = bps;
    }

    function setIgnoreMinimum(bool value) external {
        ignoreMinimum = value;
    }

    function setFillBps(uint256 bps) external {
        fillBps = bps;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable override returns (uint256 amountOut) {
        require(p.fee == POOL_FEE, "MockRouter: fee");
        require(p.sqrtPriceLimitX96 == 0, "MockRouter: price limit");
        uint256 used = p.amountIn * fillBps / 10_000;
        if (p.tokenIn == USDC && p.tokenOut == CBBTC) {
            amountOut = Math.mulDiv(used, 1e8, price);
        } else if (p.tokenIn == CBBTC && p.tokenOut == USDC) {
            amountOut = Math.mulDiv(used, price, 1e8);
        } else {
            revert("MockRouter: tokens");
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        amountOut = Math.mulDiv(amountOut, uint256(10_000 - worseBps), 10_000);
        if (!ignoreMinimum) require(amountOut >= p.amountOutMinimum, "Too little received");

        require(MockERC20(p.tokenIn).transferFrom(msg.sender, address(this), used), "MockRouter: transferFrom");
        MockERC20(p.tokenOut).mint(p.recipient, amountOut);

        calls++;
        lastRecipient = p.recipient;
        lastAmountIn = p.amountIn;
        lastAmountOutMinimum = p.amountOutMinimum;
    }
}
