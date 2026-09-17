// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IV3SwapRouter} from "../../src/interfaces/IV3SwapRouter.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockUniswapV3Pool} from "./MockUniswapV3Pool.sol";

/// @notice Uniswap SwapRouter02 imitation: accepts only the 2-hop path via USDC at 0.05% per hop,
///         computes output at a configurable rate (EURC base units per cbBTC) minus configurable slippage.
contract MockRouter is IV3SwapRouter {
    uint24 public constant POOL_FEE = 500;

    address public immutable EURC;
    address public immutable USDC;
    address public immutable CBBTC;
    /// @notice Like SwapRouter02.factory(); configurable, so the constructor check on the pools can be tested.
    address public factory;

    uint256 public price;
    uint256 public slippageBps;
    uint256 public gasBurn;
    /// @dev > 0: burn all gas except `gasKeep` in every swap (to test "run at full budget").
    uint256 public gasKeep;
    /// @dev Optional: pool that is set to a new price after every swap (imitates price impact / sandwich).
    MockUniswapV3Pool public shiftPool;
    uint256 public shiftToken0Amount;
    uint256 public shiftToken1Amount;
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

    function setFactory(address factory_) external {
        factory = factory_;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function setSlippageBps(uint256 bps) external {
        slippageBps = bps;
    }

    /// @notice Makes every swap burn at least `gas` gas (to test gas budgets).
    function setGasBurn(uint256 gas) external {
        gasBurn = gas;
    }

    /// @notice Makes every swap then set `pool` to `token0Amount : token1Amount`. Pool address(0) = off.
    /// @notice Makes every swap burn gas until only `keep` is left in the router frame; 0 = off.
    function setGasKeep(uint256 keep) external {
        gasKeep = keep;
    }

    function setPoolShift(MockUniswapV3Pool pool, uint256 token0Amount, uint256 token1Amount) external {
        shiftPool = pool;
        shiftToken0Amount = token0Amount;
        shiftToken1Amount = token1Amount;
    }

    function exactInput(ExactInputParams calldata p) external payable override returns (uint256 amountOut) {
        uint256 stopAt = gasleft() > gasBurn ? gasleft() - gasBurn : 0;
        if (gasKeep > 0) stopAt = gasKeep;
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
        if (address(shiftPool) != address(0)) shiftPool.swapToPrice(shiftToken0Amount, shiftToken1Amount);
    }
}
