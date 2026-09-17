// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {IV3SwapRouter} from "../src/interfaces/IV3SwapRouter.sol";

/// @notice Fork regressions from the internal audit of 15 September 2026 (`audit/2026-09-15/poc/PocFork.t.sol`).
///         Skip with RUN_FORK=false.
contract PocFork is Test {
    IERC20 constant EURC = IERC20(0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42);
    IERC20 constant CBBTC = IERC20(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
    IERC20 constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant POOL_EURC_USDC = 0x7279c08A36333e12c3Fc81747963264c100D66fB;
    address constant POOL_USDC_CBBTC = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;
    address treasury = makeAddr("treasury");
    address keeper = makeAddr("keeper");
    Rebalancer r;

    function setUp() public {
        if (!vm.envOr("RUN_FORK", true)) {
            vm.skip(true);
        }
        // `FORK_BLOCK` pins a block (review I-7), so the suite is reproducible; defaults to the latest.
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        r = new Rebalancer(
            Rebalancer.Deployment({
                eurc: address(EURC),
                cbbtc: address(CBBTC),
                usdc: address(USDC),
                router: ROUTER,
                feedCbbtcUsd: 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D,
                feedEurcUsd: 0x9867186e52d2F1C2c565CDA6E747101Fa56501e0,
                sequencerFeed: 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433,
                poolEurcUsdc: POOL_EURC_USDC,
                poolUsdcCbbtc: POOL_USDC_CBBTC,
                treasury: treasury
            })
        );
    }

    function _fund(address u, uint256 e, uint256 b) internal {
        if (e > 0) vm.prank(POOL_EURC_USDC);
        EURC.transfer(u, e);
        if (b > 0) vm.prank(POOL_USDC_CBBTC);
        CBBTC.transfer(u, b);
        vm.startPrank(u);
        EURC.approve(address(r), type(uint256).max);
        CBBTC.approve(address(r), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Was PoC B and B2: a dust owner with `minTradeEurc = 1` and `maxCorrectionBps = 1` was due every run,
    ///      reverted on Uniswap or succeeded with fee 0, and so cost the keeper gas every hour. The hardening
    ///      put economic lower bounds under that (audit L-1 and M-2), so that setup can no longer be
    ///      registered. If that bound is ever dropped, this test fails.
    function test_dustOwnerCannotRegisterAnymore() public {
        address dust = makeAddr("dust");
        _fund(dust, 10, 0); // 0.00001 EURC

        // minTradeEurc below MIN_TRADE_FLOOR (20 EURC).
        vm.prank(dust);
        vm.expectRevert(Rebalancer.InvalidParams.selector);
        r.setParams(
            Rebalancer.Params({
                active: true,
                targetBps: 8000,
                bandBps: 500, // valid band: the revert must come from the bound under test
                maxCorrectionBps: 1000,
                minTradeEurc: 1,
                interval: 1 hours,
                maxSlippageBps: 100
            })
        );

        // maxCorrectionBps below MIN_CORRECTION_BPS (10).
        vm.prank(dust);
        vm.expectRevert(Rebalancer.InvalidParams.selector);
        r.setParams(
            Rebalancer.Params({
                active: true,
                targetBps: 8000,
                bandBps: 500, // valid band: the revert must come from the bound under test
                maxCorrectionBps: 1,
                minTradeEurc: 20e6,
                interval: 1 hours,
                maxSlippageBps: 100
            })
        );

        // maxSlippageBps below MIN_SLIPPAGE_BPS (60), the bound from audit L-2.
        vm.prank(dust);
        vm.expectRevert(Rebalancer.InvalidParams.selector);
        r.setParams(
            Rebalancer.Params({
                active: true,
                targetBps: 8000,
                bandBps: 500, // valid band: the revert must come from the bound under test
                maxCorrectionBps: 1000,
                minTradeEurc: 20e6,
                interval: 1 hours,
                maxSlippageBps: 30
            })
        );

        // So nobody is in the registry and no keeper finds work.
        assertEq(r.ownerCount(), 0, "dust owner is registered after all");
        assertEq(r.dueOwners(0, 10).length, 0);
    }

    /// C: the caller sandwiches its own execute within the 0.5% spot check.
    ///    Buyer: 20,000 EURC, cap 10% -> run of 2,000 EURC. Attacker first sells EURC in the thin
    ///    EURC/USDC pool (EURC gets cheaper, spot cbBTC-in-EURC rises), lets the run go (which buys
    ///    at a worse price), and buys the EURC back afterwards.
    function test_poc_executorSandwich() public {
        address buyer = makeAddr("buyer");
        deal(address(EURC), buyer, 20_000e6);
        _fund(buyer, 0, 0);
        vm.prank(buyer);
        r.setParams(
            Rebalancer.Params({
                active: true,
                targetBps: 8000,
                bandBps: 500,
                maxCorrectionBps: 1000,
                minTradeEurc: 20e6,
                interval: 1 days,
                maxSlippageBps: 100
            })
        );

        address atk = makeAddr("atk");
        uint256 oracle = r.quote();
        console.log("oracle:", oracle, "spot:", r.spot());
        console.log(
            "EURC in pool:", EURC.balanceOf(POOL_EURC_USDC) / 1e6, "USDC in pool:", USDC.balanceOf(POOL_EURC_USDC) / 1e6
        );

        // Find the largest EURC amount at which the spot still stays within 0.5% (bisection on a snapshot).
        uint256 lo = 0;
        uint256 hi = 30_000e6;
        for (uint256 i = 0; i < 20; i++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            _sellEurc(atk, mid);
            bool ok;
            try r.quoteChecked() {
                ok = true;
            } catch {}
            vm.revertToState(snap);
            if (ok) lo = mid;
            else hi = mid;
        }
        console.log("max EURC sell within 0.5%:", lo / 1e6);

        // 1) Attacker sells `lo` EURC -> USDC, to just within the upfront spot check.
        _sellEurc(atk, lo);
        console.log("spot after push:", r.spot(), "deviation bps:", (r.spot() - oracle) * 10_000 / oracle);

        // 2) The push is in the same block and changes the tick of EURC/USDC (Uniswap then writes an observation),
        //    so the run already reverts before the swap on the block check (audit M-1). Before the block check it
        //    stranded on the block window, before that on the spot check after the swap; the original PoC did get
        //    through here and logged the attacker's profit.
        uint256 btcBefore = CBBTC.balanceOf(buyer);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.PoolTouchedThisBlock.selector, POOL_EURC_USDC));
        r.execute(buyer, atk);

        assertEq(CBBTC.balanceOf(buyer), btcBefore, "buyer still bought at a pushed price");
        assertEq(EURC.balanceOf(atk), 0, "attacker still collected a reward");
    }

    function _sellEurc(address who, uint256 amt) internal returns (uint256 out) {
        deal(address(EURC), who, EURC.balanceOf(who) + amt);
        vm.startPrank(who);
        EURC.approve(ROUTER, amt);
        out = IV3SwapRouter(ROUTER)
            .exactInput(
                IV3SwapRouter.ExactInputParams({
                    path: abi.encodePacked(address(EURC), uint24(500), address(USDC)),
                    recipient: who,
                    amountIn: amt,
                    amountOutMinimum: 0
                })
            );
        vm.stopPrank();
    }

    function _buyEurc(address who, uint256 usdcAmt) internal returns (uint256 out) {
        vm.startPrank(who);
        USDC.approve(ROUTER, usdcAmt);
        out = IV3SwapRouter(ROUTER)
            .exactInput(
                IV3SwapRouter.ExactInputParams({
                    path: abi.encodePacked(address(USDC), uint24(500), address(EURC)),
                    recipient: who,
                    amountIn: usdcAmt,
                    amountOutMinimum: 0
                })
            );
        vm.stopPrank();
    }
}
