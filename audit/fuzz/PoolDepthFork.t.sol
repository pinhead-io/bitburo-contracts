// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IV3SwapRouter} from "../../src/interfaces/IV3SwapRouter.sol";

/*
 * Whether the real USDC/cbBTC 0.05% pool on Base can fill a swap partially. SwapRouter02 passes no price limit, so a
 * partial fill needs a pool without liquidity up to the end of the price range. The contract refuses a partial fill
 * either way; this shows how far from it the pool is. Run from the repository root (a few minutes, many RPC calls):
 *
 *   FOUNDRY_TEST=audit/fuzz POOL_DEPTH_BLOCK=<block> ~/.foundry/bin/forge test --match-path 'audit/fuzz/*' -vv
 *
 * FOUNDRY_TEST makes forge compile this directory; the tests in test/ do not run.
 */
contract PoolDepthForkTest is Test {
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 internal constant CBBTC = IERC20(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
    address internal constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")), vm.envUint("POOL_DEPTH_BLOCK")
        );
    }

    /// @dev A buy of 1 billion USDC, about 250 times the pool's USDC, is taken in full.
    function test_poolTakesAllOfAHugeBuy() public {
        assertEq(_spent(USDC, CBBTC, 1_000_000_000e6), 1_000_000_000e6);
    }

    /// @dev A sell of 100,000 cbBTC, about 2,000 times the pool's cbBTC, is taken in full.
    function test_poolTakesAllOfAHugeSell() public {
        assertEq(_spent(CBBTC, USDC, 100_000e8), 100_000e8);
    }

    function _spent(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn) internal returns (uint256) {
        deal(address(tokenIn), address(this), amountIn);
        tokenIn.approve(ROUTER, amountIn);
        IV3SwapRouter(ROUTER)
            .exactInputSingle(
                IV3SwapRouter.ExactInputSingleParams({
                    tokenIn: address(tokenIn),
                    tokenOut: address(tokenOut),
                    fee: 500,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        return amountIn - tokenIn.balanceOf(address(this));
    }
}
