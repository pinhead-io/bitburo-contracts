// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Rebalancer} from "src/Rebalancer.sol";
import {IUniswapV3Pool} from "src/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "src/libraries/TickMath.sol";

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}

/// @dev Attacker: all in one transaction (front-run, execute, back-run). Nothing nested, so nonReentrant does not help.
contract Sandwicher {
    IERC20 constant EURC = IERC20(0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42);
    IERC20 constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    ISwapRouter02 constant ROUTER = ISwapRouter02(0x2626664c2603336E57B271c5C0b26F421741e481);

    function attack(Rebalancer r, address victim, uint256 pushEurc) external {
        EURC.approve(address(ROUTER), type(uint256).max);
        USDC.approve(address(ROUTER), type(uint256).max);
        // 1. front-run: sell EURC for USDC -> EURC cheaper -> cbBTC more expensive in EURC (spot up)
        if (pushEurc > 0) {
            ROUTER.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams(address(EURC), address(USDC), 500, address(this), pushEurc, 0, 0)
            );
        }
        // 2. the victim's run (buy: EURC -> USDC -> cbBTC) pushes EURC down even further
        r.execute(victim, address(this));
        // 3. back-run: buy EURC back with all USDC
        if (pushEurc > 0) {
            ROUTER.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams(
                    address(USDC), address(EURC), 500, address(this), USDC.balanceOf(address(this)), 0, 0
                )
            );
        }
    }

    /// @dev Sell direction: buy EURC with USDC (EURC more expensive -> cbBTC cheaper in EURC, spot down),
    ///      let the victim sell cbBTC -> USDC -> EURC (pushes EURC further up), sell EURC back.
    ///      Only the EURC from the push goes back to USDC; the reward stays as EURC.
    function attackSell(Rebalancer r, address victim, uint256 pushUsdc) external {
        EURC.approve(address(ROUTER), type(uint256).max);
        USDC.approve(address(ROUTER), type(uint256).max);
        uint256 pushed;
        if (pushUsdc > 0) {
            pushed = ROUTER.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams(address(USDC), address(EURC), 500, address(this), pushUsdc, 0, 0)
            );
        }
        r.execute(victim, address(this));
        if (pushed > 0) {
            ROUTER.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams(address(EURC), address(USDC), 500, address(this), pushed, 0, 0)
            );
        }
    }

    function pushUsdcOnly(uint256 pushUsdc) external {
        USDC.approve(address(ROUTER), type(uint256).max);
        ROUTER.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams(address(USDC), address(EURC), 500, address(this), pushUsdc, 0, 0)
        );
    }

    function pushOnly(uint256 pushEurc) external {
        EURC.approve(address(ROUTER), type(uint256).max);
        ROUTER.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams(address(EURC), address(USDC), 500, address(this), pushEurc, 0, 0)
        );
    }
}

/// @notice Shared fork setup for the sandwich tests: addresses, a fresh Rebalancer contract, the attacker and the
///         helpers for pushes and runs. Abstract and without tests, so that `OracleSandwichTest` and
///         `OracleLagSandwichTest` each add only their own tests and nothing runs twice.
abstract contract OracleSandwichBase is Test {
    IERC20 internal constant EURC = IERC20(0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42);
    IERC20 internal constant CBBTC = IERC20(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address internal constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant FEED_CBBTC_USD = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
    address internal constant FEED_EURC_USD = 0x9867186e52d2F1C2c565CDA6E747101Fa56501e0;
    address internal constant SEQUENCER = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address internal constant POOL_EURC_USDC = 0x7279c08A36333e12c3Fc81747963264c100D66fB;
    address internal constant POOL_USDC_CBBTC = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;
    uint256 internal constant REWARD = 50_000;

    address internal treasury = makeAddr("treasury");
    address internal victim = makeAddr("victim");
    Rebalancer internal r;
    Sandwicher internal atk;

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
                feedCbbtcUsd: FEED_CBBTC_USD,
                feedEurcUsd: FEED_EURC_USD,
                sequencerFeed: SEQUENCER,
                poolEurcUsdc: POOL_EURC_USDC,
                poolUsdcCbbtc: POOL_USDC_CBBTC,
                treasury: treasury
            })
        );
        atk = new Sandwicher();
        // A fresh block: the fork block itself may already have contained a swap in the pools.
        _nextBlock();
    }

    function _nextBlock() internal {
        vm.roll(block.number + 1);
        vm.warp(vm.getBlockTimestamp() + 2);
    }

    /// @dev Small pushes (EURC sold in EURC/USDC): the pool moves ~1 bp per 200 EURC (measured). Since the block check
    ///      a run only succeeds after a push that stays within the current tick (else PoolTouchedThisBlock). How much
    ///      EURC that is depends on where the price is in the tick; so the last push is computed: half the room
    ///      to the lower edge of the tick. (Was 900 EURC, ~4.5 bp: that now always crosses the tick boundary.) Without
    ///      such a push every attack would revert and a test would prove nothing.
    function _smallPushes() internal view returns (uint256[5] memory) {
        return [uint256(25e6), 100e6, 250e6, 500e6, _pushWithinTick(500_000)];
    }

    /// @dev EURC input that pushes EURC/USDC down by `ppm` millionths of the room to P(tick), at the in-range liquidity
    ///      (constant within the tick): amount0 = L × 2^96 × (√P − √target) / (√P × √target), plus 0.05% pool fee.
    function _pushWithinTick(uint256 ppm) internal view returns (uint256) {
        (uint160 s, int24 t,,,,,) = IUniswapV3Pool(POOL_EURC_USDC).slot0();
        uint160 edge = TickMath.getSqrtPriceAtTick(t);
        if (s <= edge + 1) return 1;
        uint160 target = s - uint160(Math.mulDiv(s - edge - 1, ppm, 1e6));
        uint256 liquidity = IUniswapV3Pool(POOL_EURC_USDC).liquidity();
        uint256 net = Math.mulDiv(liquidity << 96, s - target, s) / target;
        return Math.max(net * 1e6 / (1e6 - 500), 1);
    }

    /// @dev Same for the sell direction: USDC input that pushes EURC/USDC up by `ppm` of the room to P(tick + 1).
    ///      amount1 = L × (√target − √P) / 2^96, plus 0.05% pool fee. The last of the small USDC pushes.
    function _smallUsdcPushes() internal view returns (uint256[5] memory pushes) {
        pushes = [uint256(25e6), 100e6, 250e6, 500e6, 0];
        (uint160 s, int24 t,,,,,) = IUniswapV3Pool(POOL_EURC_USDC).slot0();
        uint160 edge = TickMath.getSqrtPriceAtTick(t + 1);
        if (s + 1 >= edge) {
            pushes[4] = 1;
            return pushes;
        }
        uint160 target = s + uint160(Math.mulDiv(edge - 1 - s, 500_000, 1e6));
        uint256 net = Math.mulDiv(IUniswapV3Pool(POOL_EURC_USDC).liquidity(), target - s, 1 << 96);
        pushes[4] = Math.max(net * 1e6 / (1e6 - 500), 1);
    }

    function _fundVictim(uint256 eurcAmount, uint16 slippageBps) internal {
        deal(address(EURC), victim, eurcAmount);
        vm.startPrank(victim);
        EURC.approve(address(r), type(uint256).max);
        CBBTC.approve(address(r), type(uint256).max);
        // maxCorrection 100% -> correction = drift * total = 80% of the EURC balance (the run can be smaller)
        r.setParams(
            Rebalancer.Params({
                active: true,
                targetBps: 8000,
                bandBps: 500,
                maxCorrectionBps: 10000,
                minTradeEurc: 20e6,
                interval: 1 days,
                maxSlippageBps: slippageBps
            })
        );
        vm.stopPrank();
    }

    /// @dev Largest push (EURC sold in the EURC/USDC pool) at which quoteChecked still succeeds.
    function _maxPushWithinDeviation() internal returns (uint256 push) {
        uint256 lo = 0;
        uint256 hi = 200_000e6;
        deal(address(EURC), address(this), hi);
        for (uint256 i = 0; i < 40; i++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            EURC.transfer(address(atk), mid);
            atk.pushOnly(mid);
            (bool ok,) = address(r).staticcall(abi.encodeWithSelector(r.quoteChecked.selector));
            vm.revertToState(snap);
            if (ok) lo = mid;
            else hi = mid;
        }
        push = lo;
    }

    /// @return ok          Whether the attack (push, execute, swap back) succeeded.
    /// @return attackerPnl EURC result of the attacker, including the reward.
    /// @return victimBtc   cbBTC of the victim afterwards.
    function _run(uint256 victimEurc, uint16 slippageBps, uint256 push)
        internal
        returns (bool ok, int256 attackerPnl, uint256 victimBtc)
    {
        _fundVictim(victimEurc, slippageBps);
        deal(address(EURC), address(atk), push);
        uint256 before = EURC.balanceOf(address(atk));
        try atk.attack(r, victim, push) {
            ok = true;
        } catch (bytes memory reason) {
            ok = false;
            console.log("attack reverted:");
            console.logBytes(reason);
        }
        attackerPnl = int256(EURC.balanceOf(address(atk))) - int256(before);
        victimBtc = CBBTC.balanceOf(victim);
    }

    /// @dev Pushes within the block window: at least one attack must succeed, and none yields the attacker more
    ///      than the reward that an honest caller also gets.
    function _assertSmallPushesUnprofitable(uint256 victimEurc, uint16 slippageBps) internal {
        uint256[5] memory pushes = _smallPushes();
        uint256 okCount;
        for (uint256 i = 0; i < pushes.length; i++) {
            uint256 snap = vm.snapshotState();
            (bool ok, int256 pnl,) = _run(victimEurc, slippageBps, pushes[i]);
            vm.revertToState(snap);
            console.log("push within window (EURC):", pushes[i], " succeeded:", ok);
            console.logInt(pnl);
            if (!ok) continue;
            okCount++;
            assertLe(pnl, int256(REWARD), "attacker earns more than the reward");
        }
        assertGt(okCount, 0, "no push within the window succeeded: the test then proves nothing");
    }
}

/// @notice Fork regressions for audit M-1 (self-sandwich) and L-3 (DoS by pushing the spot). Since the block window
///         (MAX_BLOCK_MOVE_BPS) pushes up to the spot check revert before the swap; pushes within the window succeed,
///         but yield the attacker no more than the reward that an honest caller also gets. Skip with
///         RUN_FORK=false.
contract OracleSandwichTest is OracleSandwichBase {
    function test_poc_selfSandwich_10k_slippage100() public {
        uint256 oracle = r.quote();
        uint256 spot0 = r.spot();
        console.log("oracle EURC/cbBTC:", oracle, " spot:", spot0);
        uint256 push = _maxPushWithinDeviation();
        console.log("max push within 50 bps (EURC):", push);

        // baseline without manipulation
        uint256 snap = vm.snapshotState();
        (,, uint256 fairBtc) = _run(12_500e6, 100, 0);
        vm.revertToState(snap);
        console.log("victim cbBTC without attack:", fairBtc);

        (bool ok, int256 pnl, uint256 btc) = _run(12_500e6, 100, push);
        console.log("attack succeeded:", ok);
        console.log("attacker PnL (EURC 6 dec):");
        console.logInt(pnl);
        console.log("victim cbBTC with attack:", btc);

        // Reversed relative to the original PoC. That proved the attack paid off (audit M-1: +27 EURC on
        // a run of 10k). The push up to the spot check (~50 bp) is far outside the block window, so the run reverts
        // before the swap already. Without push the same owner does succeed, with a run limited by the liquidity.
        assertGt(fairBtc, 0, "baseline without push does not succeed: the test then proves nothing");
        assertFalse(ok, "sandwich gets through again");
        assertLe(pnl, 0, "sandwich is profitable again");
        assertEq(btc, 0, "victim still traded at the pushed price");
        vm.revertToState(snap);
        _assertSmallPushesUnprofitable(12_500e6, 100);
    }

    /// @dev Was 30 bps in the original PoC; `MIN_SLIPPAGE_BPS` has been 60 since the hardening (audit L-2),
    ///      so this is the tightest setting a user can still choose.
    function test_poc_selfSandwich_10k_slippage60() public {
        uint256 push = _maxPushWithinDeviation();
        uint256 snap = vm.snapshotState();
        (bool ok, int256 pnl, uint256 btc) = _run(12_500e6, 60, push);
        console.log("slippage 60 bps (tightest allowed): attack succeeded:", ok);
        console.logInt(pnl);
        assertFalse(ok, "sandwich with maximum push gets through");
        assertLe(pnl, 0, "sandwich profitable");
        assertEq(btc, 0);
        vm.revertToState(snap);
        _assertSmallPushesUnprofitable(12_500e6, 60);
    }

    function test_poc_selfSandwich_1k_slippage100() public {
        uint256 push = _maxPushWithinDeviation();
        uint256 snap = vm.snapshotState();
        (bool ok, int256 pnl,) = _run(1_250e6, 100, push);
        console.log("run 1k: succeeded:", ok);
        console.logInt(pnl);
        assertFalse(ok, "sandwich with maximum push gets through");
        assertLe(pnl, 0, "sandwich profitable");
        vm.revertToState(snap);
        _assertSmallPushesUnprofitable(1_250e6, 100);
    }

    /// @dev Test gap execute 4 (EX-03): on the real route, with the EURC/USDC pool pushed beforehand, the owner gets,
    ///      for every run that succeeds, at least the oracle value minus FEE_BPS + maxSlippageBps. The push happens in
    ///      the previous block, up to the spot check (there the block window sees nothing and only the spot check
    ///      protects), or small in the same block. Runs that fail a check do not count; at least one pushed run must
    ///      succeed. The run can be smaller than the 1,000 EURC correction due to the liquidity; the bound applies to
    ///      what is actually traded.
    function test_fork_lossPerRunBoundedUnderSpotPush() public {
        uint256 oracle = r.quote();
        uint256 maxPush = _maxPushWithinDeviation();
        uint256[5] memory smallPushes = _smallPushes();
        uint16[2] memory slippages = [uint16(60), uint16(100)];
        uint256 pushedRunsSucceeded;
        for (uint256 s = 0; s < slippages.length; s++) {
            for (uint256 f = 0; f <= 9; f++) {
                bool sameBlock = f >= 5;
                uint256 push = sameBlock ? smallPushes[f - 5] : maxPush * f / 4;
                uint256 snap = vm.snapshotState();
                _fundVictim(1_250e6, slippages[s]);
                if (push > 0) {
                    deal(address(EURC), address(atk), push);
                    atk.pushOnly(push);
                    if (!sameBlock) _nextBlock();
                }
                (bool ok,) = address(r).call(abi.encodeCall(r.execute, (victim, address(this))));
                if (ok) {
                    uint256 spent = 1_250e6 - EURC.balanceOf(victim);
                    uint256 fairSats = Math.mulDiv(spent, 1e8, oracle);
                    uint256 worstSats = Math.mulDiv(fairSats, 10_000 - r.FEE_BPS() - slippages[s], 10_000);
                    uint256 received = CBBTC.balanceOf(victim);
                    console.log("slippage:", slippages[s], " push:", push);
                    console.log("  same block:", sameBlock, " traded EURC:", spent);
                    console.log("  received sats:", received, " lower bound:", worstSats);
                    assertGe(received + 1, worstSats, "loss above fee + maxSlippage");
                    if (push > 0) pushedRunsSucceeded++;
                }
                vm.revertToState(snap);
            }
        }
        assertGt(pushedRunsSucceeded, 0, "not a single pushed run succeeded: the test proves nothing");
    }

    /// @dev L-3: a push > 50 bps leaves isDue/dueOwners empty and makes execute revert while the pool stays pushed. If
    ///      arbitrage (here the attacker itself) resets the pool, the owner is due again one block later.
    function test_poc_dosBySpotPush() public {
        _fundVictim(1_250e6, 100);
        (bool due,) = r.isDue(victim);
        assertTrue(due);
        uint256 push = _maxPushWithinDeviation() + 1_000e6;
        deal(address(EURC), address(atk), push);
        atk.pushOnly(push);
        (due,) = r.isDue(victim);
        assertFalse(due, "isDue still true");
        assertEq(r.dueOwners(0, 10).length, 0);
        vm.expectRevert();
        r.execute(victim, address(this));
        uint256 usdcOut = USDC.balanceOf(address(atk));
        console.log("DoS push (EURC):", push, " USDC received:", usdcOut);

        // Still blocked one block later: the spot check still sees the push.
        _nextBlock();
        (due,) = r.isDue(victim);
        assertFalse(due, "push across blocks no longer blocks");

        atk.pushUsdcOnly(usdcOut);
        console.log("DoS cost for the attacker (EURC 6 dec):", push - EURC.balanceOf(address(atk)));
        _nextBlock();
        (due,) = r.isDue(victim);
        assertTrue(due, "not due again after the pool recovered");
        r.execute(victim, address(this));
    }

    /// @dev Sweep: run size x push size, slippage 100 bps. No successful attack yields the attacker more
    ///      than the reward, and at least one push within the window succeeds.
    function test_poc_sweep() public {
        uint256 oracle = r.quote();
        uint256 maxPush = _maxPushWithinDeviation();
        uint256[5] memory smallPushes = _smallPushes();
        console.log("oracle:", oracle, " spot:", r.spot());
        console.log("maxPush within 50 bps:", maxPush);
        uint256[4] memory runs = [uint256(1_250e6), 3_125e6, 6_250e6, 12_500e6];
        uint256 okCount;
        for (uint256 k = 0; k < runs.length; k++) {
            uint256 snap0 = vm.snapshotState();
            (bool okBase,, uint256 fairBtc) = _run(runs[k], 100, 0);
            vm.revertToState(snap0);
            console.log("---- correction EURC:", runs[k] * 8 / 10, " baseline ok:", okBase);
            console.log("     baseline cbBTC:", fairBtc);
            for (uint256 f = 0; f < 10; f++) {
                uint256 push = f < 5 ? smallPushes[f] : maxPush * (f - 4) / 5;
                uint256 snap = vm.snapshotState();
                (bool ok, int256 pnl, uint256 btc) = _run(runs[k], 100, push);
                if (ok) {
                    okCount++;
                    console.log("     push:", push, " victim cbBTC:", btc);
                    console.log("       attacker PnL incl. reward (EURC):");
                    console.logInt(pnl);
                    assertLe(pnl, int256(REWARD), "attacker earns more than the reward");
                } else {
                    console.log("     push:", push, " -> execute fails");
                    assertEq(btc, 0, "failed attack still left a run");
                }
                vm.revertToState(snap);
            }
        }
        assertGt(okCount, 0, "not a single attack succeeded: the test then proves nothing");
    }

    function _maxUsdcPushWithinDeviation() internal returns (uint256 push) {
        uint256 lo = 0;
        uint256 hi = 200_000e6;
        for (uint256 i = 0; i < 40; i++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            deal(address(USDC), address(atk), mid);
            atk.pushUsdcOnly(mid);
            (bool ok,) = address(r).staticcall(abi.encodeWithSelector(r.quoteChecked.selector));
            vm.revertToState(snap);
            if (ok) lo = mid;
            else hi = mid;
        }
        push = lo;
    }

    /// @dev Sell run: victim holds only cbBTC, maxCorrection 100% -> correction 20% of the value. The
    ///      attacker earns no USDC with any push (within the window or up to the spot check); it keeps the reward
    ///      separately as EURC. At least one pushed attack succeeds.
    function test_poc_sweepSell() public {
        uint256 oracle = r.quote();
        uint256 maxPush = _maxUsdcPushWithinDeviation();
        console.log("maxPush USDC within 50 bps:", maxPush);
        uint256[5] memory smallPushes = _smallUsdcPushes(); // ~1 USDC per EURC: same order; the last one within the tick
        uint256[3] memory btcs = [uint256(7_500_000), 18_750_000, 37_500_000]; // ~5k, 12.5k, 25k EURC value
        uint256 okCount;
        for (uint256 k = 0; k < btcs.length; k++) {
            deal(address(CBBTC), victim, btcs[k]);
            vm.startPrank(victim);
            CBBTC.approve(address(r), type(uint256).max);
            r.setParams(
                Rebalancer.Params({
                    active: true,
                    targetBps: 8000,
                    bandBps: 500,
                    maxCorrectionBps: 10000,
                    minTradeEurc: 20e6,
                    interval: 1 days,
                    maxSlippageBps: 100
                })
            );
            vm.stopPrank();
            uint256 snap0 = vm.snapshotState();
            vm.prank(address(atk));
            r.execute(victim, address(atk));
            uint256 fairEurc = EURC.balanceOf(victim);
            vm.revertToState(snap0);
            console.log(
                "---- sell, EURC value of position:", btcs[k] * oracle / 1e8, " baseline EURC received:", fairEurc
            );
            for (uint256 f = 0; f < 10; f++) {
                uint256 push = f < 5 ? smallPushes[f] : maxPush * (f - 4) / 5;
                uint256 snap = vm.snapshotState();
                deal(address(USDC), address(atk), push);
                uint256 usdcBefore = USDC.balanceOf(address(atk));
                try atk.attackSell(r, victim, push) {
                    okCount++;
                    int256 pnl = int256(USDC.balanceOf(address(atk))) - int256(usdcBefore);
                    console.log("     push USDC:", push, " EURC victim:", EURC.balanceOf(victim));
                    console.log("       attacker PnL excl. reward (USDC):");
                    console.logInt(pnl);
                    assertLe(pnl, 0, "attacker earns USDC from the sandwich");
                    assertLe(EURC.balanceOf(address(atk)), REWARD, "attacker kept more EURC than the reward");
                } catch {
                    console.log("     push USDC:", push, " -> execute fails");
                }
                vm.revertToState(snap);
            }
            deal(address(CBBTC), victim, 0);
        }
        assertGt(okCount, 0, "not a single attack succeeded: the test then proves nothing");
    }
}
