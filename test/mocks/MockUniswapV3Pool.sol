// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3Pool.sol";

/// @notice Uniswap v3-pool met alleen een instelbare sqrtPriceX96 en fee-tier, en vaste token0/token1.
contract MockUniswapV3Pool is IUniswapV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint160 public sqrtPriceX96;
    uint24 public fee = 500;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    /// @notice Zet de spot zodat `token1Amount` basiseenheden token1 gelijk staan aan `token0Amount` token0.
    function setPrice(uint256 token0Amount, uint256 token1Amount) external {
        sqrtPriceX96 = uint160(Math.sqrt(Math.mulDiv(token1Amount, 1 << 192, token0Amount)));
    }

    function setFee(uint24 value) external {
        fee = value;
    }

    /// @notice Zet sqrtPriceX96 rechtstreeks (voor randgevallen als MIN/MAX_SQRT_RATIO).
    function setSqrtPriceX96(uint160 value) external {
        sqrtPriceX96 = value;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }
}
