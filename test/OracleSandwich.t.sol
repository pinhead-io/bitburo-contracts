// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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

/// @dev Aanvaller: alles in één transactie (front-run, execute, back-run). Niets genest, dus nonReentrant helpt niet.
contract Sandwicher {
    IERC20 constant EURC = IERC20(0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42);
    IERC20 constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    ISwapRouter02 constant ROUTER = ISwapRouter02(0x2626664c2603336E57B271c5C0b26F421741e481);

    function attack(Rebalancer r, address victim, uint256 pushEurc) external {
        EURC.approve(address(ROUTER), type(uint256).max);
        USDC.approve(address(ROUTER), type(uint256).max);
        // 1. front-run: verkoop EURC voor USDC -> EURC goedkoper -> cbBTC duurder in EURC (spot omhoog)
        if (pushEurc > 0) {
            ROUTER.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams(address(EURC), address(USDC), 500, address(this), pushEurc, 0, 0)
            );
        }
        // 2. de run van het slachtoffer (koop: EURC -> USDC -> cbBTC) duwt EURC nog verder omlaag
        r.execute(victim, address(this));
        // 3. back-run: koop EURC terug met alle USDC
        if (pushEurc > 0) {
            ROUTER.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams(
                    address(USDC), address(EURC), 500, address(this), USDC.balanceOf(address(this)), 0, 0
                )
            );
        }
    }

    /// @dev Verkooprichting: koop EURC met USDC (EURC duurder -> cbBTC goedkoper in EURC, spot omlaag),
    ///      laat het slachtoffer cbBTC -> USDC -> EURC verkopen (duwt EURC verder omhoog), verkoop EURC terug.
    function attackSell(Rebalancer r, address victim, uint256 pushUsdc) external {
        EURC.approve(address(ROUTER), type(uint256).max);
        USDC.approve(address(ROUTER), type(uint256).max);
        if (pushUsdc > 0) {
            ROUTER.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams(address(USDC), address(EURC), 500, address(this), pushUsdc, 0, 0)
            );
        }
        r.execute(victim, address(this));
        if (pushUsdc > 0) {
            ROUTER.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams(
                    address(EURC), address(USDC), 500, address(this), EURC.balanceOf(address(this)), 0, 0
                )
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

contract OracleSandwichTest is Test {
    IERC20 internal constant EURC = IERC20(0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42);
    IERC20 internal constant CBBTC = IERC20(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address internal constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant FEED_CBBTC_USD = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
    address internal constant FEED_EURC_USD = 0x9867186e52d2F1C2c565CDA6E747101Fa56501e0;
    address internal constant SEQUENCER = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address internal constant POOL_EURC_USDC = 0x7279c08A36333e12c3Fc81747963264c100D66fB;
    address internal constant POOL_USDC_CBBTC = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;

    address internal treasury = makeAddr("treasury");
    address internal victim = makeAddr("victim");
    Rebalancer internal r;
    Sandwicher internal atk;

    function setUp() public {
        if (!vm.envOr("RUN_FORK", true)) {
            vm.skip(true);
        }
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));
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
    }

    function _fundVictim(uint256 eurcAmount, uint16 slippageBps) internal {
        deal(address(EURC), victim, eurcAmount);
        vm.startPrank(victim);
        EURC.approve(address(r), type(uint256).max);
        CBBTC.approve(address(r), type(uint256).max);
        // maxCorrection 100% -> run = drift * total = 80% van het EURC-saldo
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

    /// @dev Grootste push (EURC verkocht in de EURC/USDC-pool) waarbij quoteChecked nog slaagt.
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
        console.log("max push binnen 50 bps (EURC):", push);

        // baseline zonder manipulatie
        uint256 snap = vm.snapshotState();
        (,, uint256 fairBtc) = _run(12_500e6, 100, 0);
        vm.revertToState(snap);
        console.log("slachtoffer cbBTC zonder aanval:", fairBtc);

        (bool ok, int256 pnl, uint256 btc) = _run(12_500e6, 100, push);
        console.log("aanval geslaagd:", ok);
        console.log("aanvaller PnL (EURC 6 dec):");
        console.logInt(pnl);
        console.log("slachtoffer cbBTC met aanval:", btc);
        uint256 lossBtc = fairBtc - btc;
        console.log("verlies slachtoffer (cbBTC 8 dec):", lossBtc, " in EURC:", lossBtc * oracle / 1e8);
        console.log("beloning ontvangen door aanvaller (EURC):", uint256(50_000));

        // Omgekeerd ten opzichte van de oorspronkelijke PoC. Die bewees dat de aanval loonde
        // (audit M-1: +27 EURC bij een run van 10k). Sinds de verharding draait `_requireSpotNear`
        // ook ná de swap en komt `minOut` van de oracle, waardoor de router de aanval afkapt met
        // "Too little received". Wordt dit ooit weer winstgevend, dan faalt deze test.
        assertFalse(ok, "sandwich komt er weer doorheen");
        assertLe(pnl, 0, "sandwich is weer winstgevend");
        assertEq(btc, fairBtc, "slachtoffer krijgt minder dan zonder aanval");
    }

    /// @dev Was 30 bps in de oorspronkelijke PoC; `MIN_SLIPPAGE_BPS` is sinds de verharding 60 (audit L-2),
    ///      dus dit is de krapste stand die een gebruiker nog kan kiezen.
    function test_poc_selfSandwich_10k_slippage60() public {
        uint256 push = _maxPushWithinDeviation();
        (bool ok, int256 pnl,) = _run(12_500e6, 60, push);
        console.log("slippage 60 bps (krapst toegestaan): aanval geslaagd:", ok);
        console.logInt(pnl);
    }

    function test_poc_selfSandwich_1k_slippage100() public {
        uint256 push = _maxPushWithinDeviation();
        uint256 snap = vm.snapshotState();
        (,, uint256 fairBtc) = _run(1_250e6, 100, 0);
        vm.revertToState(snap);
        (bool ok, int256 pnl, uint256 btc) = _run(1_250e6, 100, push);
        console.log("run 1k: geslaagd:", ok);
        console.logInt(pnl);
        console.log("run 1k: verlies slachtoffer cbBTC:", fairBtc - btc);
    }

    /// @dev Testgat execute 4 (EX-03): op de echte route, met de EURC/USDC-pool vooraf voorgeschoven tot binnen de
    ///      spot-check, krijgt de owner voor elke run die slaagt minstens de oraclewaarde minus FEE_BPS +
    ///      maxSlippageBps. Runs die de post-swap-check niet halen tellen niet; minstens één geduwde run moet slagen.
    function test_fork_lossPerRunBoundedUnderSpotPush() public {
        uint256 oracle = r.quote();
        uint256 maxPush = _maxPushWithinDeviation();
        uint16[2] memory slippages = [uint16(60), uint16(100)];
        uint256 pushedRunsSucceeded;
        for (uint256 s = 0; s < slippages.length; s++) {
            for (uint256 f = 0; f <= 4; f++) {
                uint256 push = maxPush * f / 4;
                uint256 snap = vm.snapshotState();
                _fundVictim(1_250e6, slippages[s]); // koop van 1.000 EURC
                if (push > 0) {
                    deal(address(EURC), address(atk), push);
                    atk.pushOnly(push);
                }
                (bool ok,) = address(r).call(abi.encodeCall(r.execute, (victim, address(this))));
                if (ok) {
                    uint256 fairSats = Math.mulDiv(1_000e6, 1e8, oracle);
                    uint256 worstSats = Math.mulDiv(fairSats, 10_000 - r.FEE_BPS() - slippages[s], 10_000);
                    uint256 received = CBBTC.balanceOf(victim);
                    console.log("slippage:", slippages[s], " push:", push);
                    console.log("  ontvangen sats:", received, " ondergrens:", worstSats);
                    assertGe(received + 1, worstSats, "verlies boven fee + maxSlippage");
                    if (push > 0) pushedRunsSucceeded++;
                }
                vm.revertToState(snap);
            }
        }
        assertGt(pushedRunsSucceeded, 0, "geen enkele geduwde run geslaagd: de test bewijst dan niets");
    }

    /// @dev DoS: een push > 50 bps laat isDue/dueOwners leeg en execute reverten; wat kost dat de aanvaller?
    function test_poc_dosBySpotPush() public {
        _fundVictim(1_250e6, 100);
        (bool due,) = r.isDue(victim);
        assertTrue(due);
        uint256 push = _maxPushWithinDeviation() + 1_000e6;
        deal(address(EURC), address(atk), push);
        atk.pushOnly(push);
        (due,) = r.isDue(victim);
        assertFalse(due, "isDue nog true");
        assertEq(r.dueOwners(0, 10).length, 0);
        vm.expectRevert();
        r.execute(victim, address(this));
        console.log("DoS-push (EURC):", push, " USDC ontvangen:", USDC.balanceOf(address(atk)));
    }

    /// @dev Sweep: run-grootte x push-grootte, slippage 100 bps. Print PnL aanvaller en verlies slachtoffer.
    function test_poc_sweep() public {
        uint256 oracle = r.quote();
        uint256 maxPush = _maxPushWithinDeviation();
        console.log("oracle:", oracle, " spot:", r.spot());
        console.log("maxPush binnen 50 bps:", maxPush);
        uint256[4] memory runs = [uint256(1_250e6), 3_125e6, 6_250e6, 12_500e6];
        for (uint256 k = 0; k < runs.length; k++) {
            uint256 snap0 = vm.snapshotState();
            (bool okBase,, uint256 fairBtc) = _run(runs[k], 100, 0);
            vm.revertToState(snap0);
            console.log("---- run EURC:", runs[k] * 8 / 10, " baseline ok:", okBase);
            console.log(
                "     baseline cbBTC:", fairBtc, " fair@oracle:", (runs[k] * 8 / 10) * 9975 / 10000 * 1e8 / oracle
            );
            for (uint256 f = 1; f <= 5; f++) {
                uint256 push = maxPush * f / 5;
                uint256 snap = vm.snapshotState();
                (bool ok, int256 pnl, uint256 btc) = _run(runs[k], 100, push);
                if (ok) {
                    console.log("     push:", push, " victim cbBTC:", btc);
                    console.log(
                        "       verlies slachtoffer (cbBTC):",
                        fairBtc > btc ? fairBtc - btc : 0,
                        " in EURC:",
                        (fairBtc > btc ? fairBtc - btc : 0) * oracle / 1e8
                    );
                    console.log("       PnL aanvaller (EURC):");
                    console.logInt(pnl);
                } else {
                    console.log("     push:", push, " -> execute faalt");
                }
                vm.revertToState(snap);
            }
        }
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

    /// @dev Verkooprun: slachtoffer heeft alleen cbBTC, maxCorrection 100% -> verkoopt 20% van de waarde.
    function test_poc_sweepSell() public {
        uint256 oracle = r.quote();
        uint256 maxPush = _maxUsdcPushWithinDeviation();
        console.log("maxPush USDC binnen 50 bps:", maxPush);
        uint256[3] memory btcs = [uint256(7_500_000), 18_750_000, 37_500_000]; // ~5k, 12.5k, 25k EURC waarde -> run 1k, 2.5k, 5k
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
                "---- verkooprun, EURC-waarde positie:", btcs[k] * oracle / 1e8, " baseline EURC ontvangen:", fairEurc
            );
            for (uint256 f = 1; f <= 5; f++) {
                uint256 push = maxPush * f / 5;
                uint256 snap = vm.snapshotState();
                deal(address(USDC), address(atk), push);
                uint256 usdcBefore = USDC.balanceOf(address(atk));
                try atk.attackSell(r, victim, push) {
                    int256 pnl = int256(USDC.balanceOf(address(atk))) - int256(usdcBefore);
                    console.log(
                        "     push USDC:", push, " verlies slachtoffer EURC:", fairEurc - EURC.balanceOf(victim)
                    );
                    console.log("       PnL aanvaller (USDC):");
                    console.logInt(pnl);
                } catch {
                    console.log("     push USDC:", push, " -> execute faalt");
                }
                vm.revertToState(snap);
            }
            deal(address(CBBTC), victim, 0);
            vm.warp(block.timestamp); // geen effect, leesbaarheid
        }
    }
}
