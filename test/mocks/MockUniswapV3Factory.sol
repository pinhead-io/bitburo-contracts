// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IUniswapV3Factory} from "../../src/interfaces/IUniswapV3Factory.sol";

/// @notice Uniswap v3 factory imitation: a configurable registry of pools per token pair and fee tier.
contract MockUniswapV3Factory is IUniswapV3Factory {
    mapping(address tokenA => mapping(address tokenB => mapping(uint24 fee => address pool))) public getPool;

    /// @notice Registers `pool` for {tokenA, tokenB} and `fee`, in both orders (like the real factory).
    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        getPool[tokenA][tokenB][fee] = pool;
        getPool[tokenB][tokenA][fee] = pool;
    }
}
