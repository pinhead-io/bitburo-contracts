// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

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
    ///      Alleen de EURC uit de push gaat terug naar USDC; de beloning blijft als EURC staan.
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

/// @notice Fork-regressies voor audit M-1 (zelf-sandwich) en L-3 (DoS door de spot te duwen). Sinds het blokvenster
///         (MAX_BLOCK_MOVE_BPS) reverten pushes tot de spotcheck vóór de swap; pushes binnen het venster slagen, maar
///         leveren de aanvaller niet meer op dan de beloning die een eerlijke aanroeper ook krijgt. Overslaan met
///         RUN_FORK=false.
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
    uint256 internal constant REWARD = 50_000;

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
        // Een vers blok: in het fork-blok zelf kan al een swap in de pools hebben gezeten.
        _nextBlock();
    }

    function _nextBlock() internal {
        vm.roll(block.number + 1);
        vm.warp(vm.getBlockTimestamp() + 2);
    }

    /// @dev Pushes (EURC verkocht in EURC/USDC) die binnen het blokvenster kunnen blijven: de pool beweegt gemeten
    ///      ~1 bp per 200 EURC. Zonder zulke pushes zou elke aanval reverten en bewijst een test niets.
    function _smallPushes() internal pure returns (uint256[5] memory) {
        return [uint256(25e6), 100e6, 250e6, 500e6, 900e6];
    }

    function _fundVictim(uint256 eurcAmount, uint16 slippageBps) internal {
        deal(address(EURC), victim, eurcAmount);
        vm.startPrank(victim);
        EURC.approve(address(r), type(uint256).max);
        CBBTC.approve(address(r), type(uint256).max);
        // maxCorrection 100% -> correctie = drift * total = 80% van het EURC-saldo (de run kan kleiner zijn)
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

    /// @return ok          Of de aanval (push, execute, terugruil) slaagde.
    /// @return attackerPnl EURC-resultaat van de aanvaller, inclusief de beloning.
    /// @return victimBtc   cbBTC van het slachtoffer na afloop.
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

    /// @dev Pushes binnen het blokvenster: minstens één aanval moet slagen, en geen enkele levert de aanvaller meer
    ///      op dan de beloning die een eerlijke aanroeper ook krijgt.
    function _assertSmallPushesUnprofitable(uint256 victimEurc, uint16 slippageBps) internal {
        uint256[5] memory pushes = _smallPushes();
        uint256 okCount;
        for (uint256 i = 0; i < pushes.length; i++) {
            uint256 snap = vm.snapshotState();
            (bool ok, int256 pnl,) = _run(victimEurc, slippageBps, pushes[i]);
            vm.revertToState(snap);
            console.log("push binnen venster (EURC):", pushes[i], " geslaagd:", ok);
            console.logInt(pnl);
            if (!ok) continue;
            okCount++;
            assertLe(pnl, int256(REWARD), "aanvaller verdient meer dan de beloning");
        }
        assertGt(okCount, 0, "geen push binnen het venster geslaagd: de test bewijst dan niets");
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

        // Omgekeerd ten opzichte van de oorspronkelijke PoC. Die bewees dat de aanval loonde (audit M-1: +27 EURC bij
        // een run van 10k). De push tot de spotcheck (~50 bp) ligt ver buiten het blokvenster, dus de run revert al
        // vóór de swap. Zonder push slaagt dezelfde owner wel, met een run die door de liquiditeit begrensd is.
        assertGt(fairBtc, 0, "baseline zonder push slaagt niet: de test bewijst dan niets");
        assertFalse(ok, "sandwich komt er weer doorheen");
        assertLe(pnl, 0, "sandwich is weer winstgevend");
        assertEq(btc, 0, "slachtoffer handelde toch op de geduwde koers");
        vm.revertToState(snap);
        _assertSmallPushesUnprofitable(12_500e6, 100);
    }

    /// @dev Was 30 bps in de oorspronkelijke PoC; `MIN_SLIPPAGE_BPS` is sinds de verharding 60 (audit L-2),
    ///      dus dit is de krapste stand die een gebruiker nog kan kiezen.
    function test_poc_selfSandwich_10k_slippage60() public {
        uint256 push = _maxPushWithinDeviation();
        uint256 snap = vm.snapshotState();
        (bool ok, int256 pnl, uint256 btc) = _run(12_500e6, 60, push);
        console.log("slippage 60 bps (krapst toegestaan): aanval geslaagd:", ok);
        console.logInt(pnl);
        assertFalse(ok, "sandwich met maximale push komt door");
        assertLe(pnl, 0, "sandwich winstgevend");
        assertEq(btc, 0);
        vm.revertToState(snap);
        _assertSmallPushesUnprofitable(12_500e6, 60);
    }

    function test_poc_selfSandwich_1k_slippage100() public {
        uint256 push = _maxPushWithinDeviation();
        uint256 snap = vm.snapshotState();
        (bool ok, int256 pnl,) = _run(1_250e6, 100, push);
        console.log("run 1k: geslaagd:", ok);
        console.logInt(pnl);
        assertFalse(ok, "sandwich met maximale push komt door");
        assertLe(pnl, 0, "sandwich winstgevend");
        vm.revertToState(snap);
        _assertSmallPushesUnprofitable(1_250e6, 100);
    }

    /// @dev Testgat execute 4 (EX-03): op de echte route, met de EURC/USDC-pool vooraf voorgeschoven, krijgt de owner
    ///      voor elke run die slaagt minstens de oraclewaarde minus FEE_BPS + maxSlippageBps. De push gebeurt in het
    ///      vorige blok, tot de spotcheck (daar ziet het blokvenster niets en beschermt alleen de spotcheck), of klein
    ///      in hetzelfde blok. Runs die een check niet halen tellen niet; minstens één geduwde run moet slagen. De run
    ///      kan door de liquiditeit kleiner zijn dan de correctie van 1.000 EURC; de grens geldt voor wat werkelijk
    ///      verhandeld is.
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
                    console.log("  zelfde blok:", sameBlock, " verhandeld EURC:", spent);
                    console.log("  ontvangen sats:", received, " ondergrens:", worstSats);
                    assertGe(received + 1, worstSats, "verlies boven fee + maxSlippage");
                    if (push > 0) pushedRunsSucceeded++;
                }
                vm.revertToState(snap);
            }
        }
        assertGt(pushedRunsSucceeded, 0, "geen enkele geduwde run geslaagd: de test bewijst niets");
    }

    /// @dev L-3: een push > 50 bps laat isDue/dueOwners leeg en execute reverten, zolang de pool geduwd blijft. Zet
    ///      arbitrage (hier de aanvaller zelf) de pool terug, dan is de owner een blok later weer due.
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
        uint256 usdcOut = USDC.balanceOf(address(atk));
        console.log("DoS-push (EURC):", push, " USDC ontvangen:", usdcOut);

        // Ook een blok later nog geblokkeerd: de spotcheck ziet de push nog.
        _nextBlock();
        (due,) = r.isDue(victim);
        assertFalse(due, "push over blokken heen blokkeert niet meer");

        atk.pushUsdcOnly(usdcOut);
        console.log("kosten DoS voor de aanvaller (EURC 6 dec):", push - EURC.balanceOf(address(atk)));
        _nextBlock();
        (due,) = r.isDue(victim);
        assertTrue(due, "na herstel van de pool niet weer due");
        r.execute(victim, address(this));
    }

    /// @dev Sweep: run-grootte x push-grootte, slippage 100 bps. Geen enkele geslaagde aanval levert de aanvaller meer
    ///      op dan de beloning, en minstens één push binnen het venster slaagt.
    function test_poc_sweep() public {
        uint256 oracle = r.quote();
        uint256 maxPush = _maxPushWithinDeviation();
        uint256[5] memory smallPushes = _smallPushes();
        console.log("oracle:", oracle, " spot:", r.spot());
        console.log("maxPush binnen 50 bps:", maxPush);
        uint256[4] memory runs = [uint256(1_250e6), 3_125e6, 6_250e6, 12_500e6];
        uint256 okCount;
        for (uint256 k = 0; k < runs.length; k++) {
            uint256 snap0 = vm.snapshotState();
            (bool okBase,, uint256 fairBtc) = _run(runs[k], 100, 0);
            vm.revertToState(snap0);
            console.log("---- correctie EURC:", runs[k] * 8 / 10, " baseline ok:", okBase);
            console.log("     baseline cbBTC:", fairBtc);
            for (uint256 f = 0; f < 10; f++) {
                uint256 push = f < 5 ? smallPushes[f] : maxPush * (f - 4) / 5;
                uint256 snap = vm.snapshotState();
                (bool ok, int256 pnl, uint256 btc) = _run(runs[k], 100, push);
                if (ok) {
                    okCount++;
                    console.log("     push:", push, " victim cbBTC:", btc);
                    console.log("       PnL aanvaller incl. beloning (EURC):");
                    console.logInt(pnl);
                    assertLe(pnl, int256(REWARD), "aanvaller verdient meer dan de beloning");
                } else {
                    console.log("     push:", push, " -> execute faalt");
                    assertEq(btc, 0, "mislukte aanval liet toch een run staan");
                }
                vm.revertToState(snap);
            }
        }
        assertGt(okCount, 0, "geen enkele aanval geslaagd: de test bewijst dan niets");
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

    /// @dev Verkooprun: slachtoffer heeft alleen cbBTC, maxCorrection 100% -> correctie 20% van de waarde. De
    ///      aanvaller verdient met geen enkele push (binnen het venster of tot de spotcheck) USDC; de beloning houdt
    ///      hij apart als EURC. Minstens één geduwde aanval slaagt.
    function test_poc_sweepSell() public {
        uint256 oracle = r.quote();
        uint256 maxPush = _maxUsdcPushWithinDeviation();
        console.log("maxPush USDC binnen 50 bps:", maxPush);
        uint256[5] memory smallPushes = _smallPushes(); // ~1 USDC per EURC: dezelfde orde
        uint256[3] memory btcs = [uint256(7_500_000), 18_750_000, 37_500_000]; // ~5k, 12.5k, 25k EURC waarde
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
                "---- verkoop, EURC-waarde positie:", btcs[k] * oracle / 1e8, " baseline EURC ontvangen:", fairEurc
            );
            for (uint256 f = 0; f < 10; f++) {
                uint256 push = f < 5 ? smallPushes[f] : maxPush * (f - 4) / 5;
                uint256 snap = vm.snapshotState();
                deal(address(USDC), address(atk), push);
                uint256 usdcBefore = USDC.balanceOf(address(atk));
                try atk.attackSell(r, victim, push) {
                    okCount++;
                    int256 pnl = int256(USDC.balanceOf(address(atk))) - int256(usdcBefore);
                    console.log("     push USDC:", push, " EURC slachtoffer:", EURC.balanceOf(victim));
                    console.log("       PnL aanvaller excl. beloning (USDC):");
                    console.logInt(pnl);
                    assertLe(pnl, 0, "aanvaller verdient USDC aan de sandwich");
                    assertLe(EURC.balanceOf(address(atk)), REWARD, "aanvaller hield meer EURC over dan de beloning");
                } catch {
                    console.log("     push USDC:", push, " -> execute faalt");
                }
                vm.revertToState(snap);
            }
            deal(address(CBBTC), victim, 0);
        }
        assertGt(okCount, 0, "geen enkele aanval geslaagd: de test bewijst dan niets");
    }
}
