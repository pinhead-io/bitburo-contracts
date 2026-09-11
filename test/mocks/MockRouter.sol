// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IV3SwapRouter} from "../../src/interfaces/IV3SwapRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Uniswap SwapRouter02-nabootsing: accepteert alleen het 2-hop-pad via USDC met 0,05% per hop,
///         rekent output op een instelbare koers (EURC-basiseenheden per cbBTC) minus instelbare slippage.
contract MockRouter is IV3SwapRouter {
    uint24 public constant POOL_FEE = 500;

    address public immutable EURC;
    address public immutable USDC;
    address public immutable CBBTC;

    uint256 public price;
    uint256 public slippageBps;
    uint256 public gasBurn;
    uint256 public calls;
    bytes public lastPath;
    address public lastRecipient;
    uint256 public lastAmountIn;
    uint256 public lastAmountOutMinimum;

    constructor(address eurc, address usdc, address cbbtc, uint256 price_) {
        EURC = eurc;
        USDC = usdc;
        CBBTC = cbbtc;
        price = price_;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function setSlippageBps(uint256 bps) external {
        slippageBps = bps;
    }

    /// @notice Laat elke swap minstens `gas` gas verbruiken (om gasbudgetten te testen).
    function setGasBurn(uint256 gas) external {
        gasBurn = gas;
    }

    function exactInput(ExactInputParams calldata p) external payable override returns (uint256 amountOut) {
        uint256 stopAt = gasleft() > gasBurn ? gasleft() - gasBurn : 0;
        while (gasleft() > stopAt) {}
        require(p.path.length == 66, "MockRouter: path length");
        address tokenIn = address(bytes20(p.path[0:20]));
        uint24 fee1 = uint24(bytes3(p.path[20:23]));
        address mid = address(bytes20(p.path[23:43]));
        uint24 fee2 = uint24(bytes3(p.path[43:46]));
        address tokenOut = address(bytes20(p.path[46:66]));
        require(fee1 == POOL_FEE && fee2 == POOL_FEE && mid == USDC, "MockRouter: path hops");

        if (tokenIn == EURC && tokenOut == CBBTC) {
            amountOut = Math.mulDiv(p.amountIn, 1e8, price);
        } else if (tokenIn == CBBTC && tokenOut == EURC) {
            amountOut = Math.mulDiv(p.amountIn, price, 1e8);
        } else {
            revert("MockRouter: path tokens");
        }
        amountOut = Math.mulDiv(amountOut, 10_000 - slippageBps, 10_000);
        require(amountOut >= p.amountOutMinimum, "Too little received");

        MockERC20(tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        MockERC20(tokenOut).mint(p.recipient, amountOut);

        calls++;
        lastPath = p.path;
        lastRecipient = p.recipient;
        lastAmountIn = p.amountIn;
        lastAmountOutMinimum = p.amountOutMinimum;
    }
}
