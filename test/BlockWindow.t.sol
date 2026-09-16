// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Rebalancer} from "../src/Rebalancer.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {RebalancerTestBase} from "./Rebalancer.t.sol";

/// @dev Maakt het blokvenster leesbaar voor de randtests.
contract RebalancerWindowHarness is Rebalancer {
    constructor(Deployment memory d) Rebalancer(d) {}

    function window(IUniswapV3Pool pool) external view returns (bool ok, Window memory w) {
        return _window(pool);
    }
}

/// @notice Unit-tests voor audit M-1: blokvenster, runomvang uit de liquiditeit en rondes in delen.
contract BlockWindowTest is RebalancerTestBase {
    RebalancerWindowHarness internal h;

    function setUp() public override {
        super.setUp();
        h = new RebalancerWindowHarness(_deployment());
    }

    // ─── Hulpfuncties ───────────────────────────────────────────────────────────────────────────────────────

    function _params(uint16 maxCorrectionBps, uint64 minTrade) internal pure returns (Rebalancer.Params memory p) {
        p = _defaultParams();
        p.maxCorrectionBps = maxCorrectionBps;
        p.minTradeEurc = minTrade;
        p.interval = 1 hours;
    }

    function _nextBlock() internal {
        vm.roll(block.number + 1);
        vm.warp(vm.getBlockTimestamp() + 2);
        _refreshFeeds();
    }

    function _warp(uint256 dt) internal {
        vm.roll(block.number + 1);
        vm.warp(vm.getBlockTimestamp() + dt);
        _refreshFeeds();
    }

    function _refreshFeeds() internal {
        (, int256 a,,,) = feedBtc.latestRoundData();
        feedBtc.set(a, vm.getBlockTimestamp(), vm.getBlockTimestamp());
        feedEurc.set(1e8, vm.getBlockTimestamp(), vm.getBlockTimestamp());
    }

    /// @dev Grootste EURC-input in de EURC/USDC-pool (koop, token0 erin) volgens de formule uit de specificatie,
    ///      onafhankelijk van het contract uitgerekend: L × 2^96 × (√P − √lower) / (√P × √lower) × 75%.
    function _expectedMaxBuy(uint128 liquidity) internal view returns (uint256) {
        (, Rebalancer.Window memory w) = h.window(poolEurcUsdc);
        uint256 s = poolEurcUsdc.sqrtPriceX96();
        uint256 amount = Math.mulDiv(uint256(liquidity) << 96, s - w.lower, s) / w.lower;
        return amount * 7500 / 10_000;
    }

    /// @dev Idem voor verkopen: USDC (token1) erin tot `upper`, bij koers 1:1 gelijk aan EURC.
    function _expectedMaxSell(uint128 liquidity) internal view returns (uint256) {
        (, Rebalancer.Window memory w) = h.window(poolEurcUsdc);
        uint256 s = poolEurcUsdc.sqrtPriceX96();
        return Math.mulDiv(liquidity, w.upper - s, 1 << 96) * 7500 / 10_000;
    }

    function _round(address owner) internal view returns (bool isBuy, uint256 remaining) {
        uint128 rem;
        (isBuy, rem) = r.rounds(owner);
        remaining = rem;
    }

    // ─── Venster ────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Het venster ligt conservatief binnen MAX_BLOCK_MOVE_BPS van beide randen van de begintick, en is op
    ///         afronding na even breed: lower² ≥ P(t+1)² × (1 − 6 bp) en upper² ≤ P(t)² × (1 + 6 bp).
    function testFuzz_window_conservativeAndTight(int24 tick, uint256 frac) public {
        tick = int24(bound(tick, -200_000, 200_000));
        frac = bound(frac, 0, 1e18);
        uint256 p0 = TickMath.getSqrtPriceAtTick(tick);
        uint256 p1 = TickMath.getSqrtPriceAtTick(tick + 1);
        poolEurcUsdc.setSqrtPriceX96(uint160(p0 + Math.mulDiv(p1 - p0 - 1, frac, 1e18)));
        assertEq(poolEurcUsdc.tick(), tick, "opzet: tick");

        (bool ok, Rebalancer.Window memory w) = h.window(poolEurcUsdc);
        assertTrue(ok);
        // P(t) uit TickMath is naar boven afgerond; de echte P(t) ligt boven p0 - 1.
        assertGe(uint256(w.lower) * w.lower * 10_000, p1 * p1 * 9994, "ondergrens te ruim");
        assertLe(uint256(w.upper) * w.upper * 10_000, (p0 - 1) * (p0 - 1) * 10_006, "bovengrens te ruim");
        uint256 tol = p1 / (1 << 96) + 3;
        assertLe(w.lower, Math.sqrt(p1 * p1 * 9994 / 10_000) + tol, "ondergrens onnodig krap");
        assertGe(w.upper + tol, Math.sqrt((p0 - 1) * (p0 - 1) * 10_006 / 10_000), "bovengrens onnodig krap");
        assertEq(w.sqrtPriceX96, poolEurcUsdc.sqrtPriceX96());
    }

    /// @notice Aan de randen van het tickbereik kapt de bovengrens niet af (geen uint160-overloop) en revert niets.
    function test_window_extremeTicksDoNotOverflow() public {
        poolEurcUsdc.setSqrtPriceX96(TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK - 1));
        (bool ok, Rebalancer.Window memory w) = h.window(poolEurcUsdc);
        assertTrue(ok);
        assertEq(w.upper, type(uint160).max, "bovengrens afgekapt");
        assertLe(w.lower, poolEurcUsdc.sqrtPriceX96());

        poolEurcUsdc.setSqrtPriceX96(TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK));
        (ok, w) = h.window(poolEurcUsdc);
        assertTrue(ok);
        assertGe(w.upper, poolEurcUsdc.sqrtPriceX96());
    }

    /// @notice Na een tickwissel in dit blok komt de begintick uit de observations, ook bij negatieve ticks.
    function testFuzz_window_startTickFromObservations(int24 startTick, uint32 delta, int24 moved) public {
        startTick = int24(bound(startTick, -200_000, 200_000));
        delta = uint32(bound(delta, 1, 30 days));
        moved = int24(bound(moved, -500, 500));
        poolEurcUsdc.setSqrtPriceX96(TickMath.getSqrtPriceAtTick(startTick));
        (, Rebalancer.Window memory before) = h.window(poolEurcUsdc);

        // Zoals Oracle.write na een swap in dit blok: vorige observatie `delta` geleden, nieuwe nu.
        int56 cum0 = -123_456_789;
        poolEurcUsdc.setObservation(0, uint32(block.timestamp) - delta, cum0, true);
        poolEurcUsdc.setObservation(1, uint32(block.timestamp), cum0 + int56(startTick) * int56(uint56(delta)), true);
        poolEurcUsdc.setObservationIndex(1);
        poolEurcUsdc.setSqrtPriceX96(TickMath.getSqrtPriceAtTick(startTick + moved));

        (bool ok, Rebalancer.Window memory w) = h.window(poolEurcUsdc);
        assertTrue(ok);
        assertEq(w.lower, before.lower, "lower volgt niet de begintick");
        assertEq(w.upper, before.upper, "upper volgt niet de begintick");
    }

    /// @notice Een swap in dit blok (mock schrijft zoals Uniswap) verschuift het venster niet.
    function test_window_swapInThisBlockKeepsWindow() public {
        (, Rebalancer.Window memory before) = h.window(poolEurcUsdc);
        poolEurcUsdc.swapToPrice(1e6, 1.002e6);
        (, Rebalancer.Window memory afterSwap) = h.window(poolEurcUsdc);
        assertEq(afterSwap.lower, before.lower);
        assertEq(afterSwap.upper, before.upper);
        // Een volgend blok begint op de nieuwe koers.
        _nextBlock();
        (, Rebalancer.Window memory next) = h.window(poolEurcUsdc);
        assertGt(next.upper, before.upper);
    }

    function test_constructor_rejectsPoolWithCardinalityBelowTwo() public {
        poolEurcUsdc.setObservationCardinality(1);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.ObservationCardinalityTooLow.selector, poolEurcUsdc));
        new Rebalancer(_deployment());
        poolEurcUsdc.setObservationCardinality(2);
        poolUsdcCbbtc.setObservationCardinality(1);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.ObservationCardinalityTooLow.selector, poolUsdcCbbtc));
        new Rebalancer(_deployment());
    }

    /// @notice Cardinality 1 na een write in dit blok, of een niet-geïnitialiseerde vorige observatie: de begintick
    ///         is onbekend. Veilig: execute revert, isDue en dueOwners melden niets.
    function test_blockStartUnknown_revertsAndNotDue() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        poolUsdcCbbtc.setObservation(0, uint32(block.timestamp), 0, true);
        poolUsdcCbbtc.setObservationCardinality(1);
        (bool due,) = r.isDue(alice);
        assertFalse(due);
        assertEq(r.dueOwners(0, 10).length, 0);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockStartUnknown.selector, poolUsdcCbbtc));
        r.execute(alice, keeper);

        poolUsdcCbbtc.setObservationCardinality(2); // vorige (index 1) is niet geïnitialiseerd
        (due,) = r.isDue(alice);
        assertFalse(due);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockStartUnknown.selector, poolUsdcCbbtc));
        r.execute(alice, keeper);

        poolUsdcCbbtc.setObservation(0, 1, 0, true); // weer een oude observatie
        (due,) = r.isDue(alice);
        assertTrue(due);
        r.execute(alice, keeper);
    }

    // ─── Vooraf: pool in dit blok al te ver ─────────────────────────────────────────────────────────────────

    function test_execute_revertsBlockMoveExceededBeforeSwap() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        // 7 bp in dit blok (tegen de koop in, dus omhoog): buiten het venster, ongeacht de richting.
        poolEurcUsdc.swapToPrice(1e6, 1.0007e6);
        (bool due,) = r.isDue(alice);
        assertFalse(due, "isDue");
        assertEq(r.dueOwners(0, 10).length, 0, "dueOwners");
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockMoveExceeded.selector, poolEurcUsdc));
        r.execute(alice, keeper);
        assertEq(router.calls(), 0, "swap gedaan");
        assertEq(r.lastExecutedAt(alice), 0);

        // Volgend blok: de nieuwe koers is de beginkoers.
        _nextBlock();
        (due,) = r.isDue(alice);
        assertTrue(due);
        r.execute(alice, keeper);
    }

    function test_execute_revertsBlockMoveExceededBeforeSwapInCbbtcPool() public {
        _setUser(bob, 0, 1_250_000, _defaultParams());
        poolUsdcCbbtc.swapToPrice(PRICE, 0.9993e8); // ~7 bp
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockMoveExceeded.selector, poolUsdcCbbtc));
        r.execute(bob, keeper);
    }

    function test_execute_pushWithinWindowAllowed() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        poolEurcUsdc.swapToPrice(1.0004e6, 1e6); // 4 bp in de richting van de koop
        (bool due,) = r.isDue(alice);
        assertTrue(due);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 900e6);
    }

    // ─── Achteraf: push plus eigen swap ─────────────────────────────────────────────────────────────────────

    function test_execute_revertsBlockMoveExceededAfterSwap() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        _setUser(bob, 0, 1_250_000, _defaultParams());

        // Koop duwt EURC/USDC 7 bp omlaag: buiten het venster, binnen de spotcheck.
        router.setPoolShift(poolEurcUsdc, 1.0007e6, 1e6);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockMoveExceeded.selector, poolEurcUsdc));
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 1000e6, "niets geboekt");
        assertEq(r.lastExecutedAt(alice), 0);

        // Verkoop via USDC/cbBTC: idem.
        router.setPoolShift(poolUsdcCbbtc, PRICE, 1.0007e8);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockMoveExceeded.selector, poolUsdcCbbtc));
        r.execute(bob, keeper);
        assertEq(cbbtc.balanceOf(bob), 1_250_000);

        // Push vooraf (3 bp) plus eigen impact (nog 3 bp) staat samen 6 bp van de beginkoers. De koers begon precies
        // op tick 0 en het venster rekent omlaag vanaf tick 1, dus hier is de ruimte omlaag 5 bp: revert. Een eigen
        // impact van nog 2 bp (samen 5 bp) past wel.
        poolEurcUsdc.swapToPrice(1.0003e6, 1e6);
        router.setPoolShift(poolEurcUsdc, 1.0006e6, 1e6);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockMoveExceeded.selector, poolEurcUsdc));
        r.execute(alice, keeper);
        router.setPoolShift(poolEurcUsdc, 1.0005e6, 1e6);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 900e6);
    }

    // ─── Runomvang uit de liquiditeit ───────────────────────────────────────────────────────────────────────

    function test_plan_buyBoundedByLiquidityOpensRound() public {
        uint128 liq = 1e12;
        poolEurcUsdc.setLiquidity(liq);
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6)); // correctie 8.000, budget 10.000
        uint256 expected = _expectedMaxBuy(liq);
        assertGt(expected, 180e6, "opzet");
        assertLt(expected, 200e6, "opzet");

        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, int256(expected), "isDue meldt het deel");
        r.execute(alice, keeper);
        assertEq(10_000e6 - eurc.balanceOf(alice), expected, "run volgt uit de liquiditeit");
        (bool isBuy, uint256 remaining) = _round(alice);
        assertTrue(isBuy);
        assertEq(remaining, 10_000e6 - expected, "restbudget");
    }

    function test_plan_sellBoundedByLiquidityOpensRound() public {
        uint128 liq = 1e12;
        poolEurcUsdc.setLiquidity(liq);
        _setUser(bob, 0, 12_500_000, _params(10_000, 20e6)); // 10.000 EURC in cbBTC, correctie 2.000
        uint256 expected = _expectedMaxSell(liq);
        uint256 sats = Math.mulDiv(expected, 1e8, PRICE, Math.Rounding.Ceil);
        (bool due, int256 delta) = r.isDue(bob);
        assertTrue(due);
        assertEq(delta, -int256(Math.mulDiv(sats, PRICE, 1e8)));
        r.execute(bob, keeper);
        assertEq(12_500_000 - cbbtc.balanceOf(bob), sats);
        (bool isBuy, uint256 remaining) = _round(bob);
        assertFalse(isBuy);
        assertEq(remaining, 10_000e6 - Math.mulDiv(sats, PRICE, 1e8, Math.Rounding.Ceil));
    }

    /// @notice Lead 2: twee runs in hetzelfde blok delen het venster. De eerste gebruikt de ruimte, de tweede past
    ///         niet meer (onder MIN_TRADE_FLOOR) en revert vooraf; een blok later wel.
    function test_execute_twoOwnersSameBlockShareWindow() public {
        poolEurcUsdc.setLiquidity(1e12);
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        _setUser(bob, 10_000e6, 0, _params(10_000, 20e6));
        // De run van alice duwt EURC/USDC 5 bp omlaag (zoals een echte swap: observatie in dit blok).
        router.setPoolShift(poolEurcUsdc, 1.0005e6, 1e6);
        r.execute(alice, keeper);
        router.setPoolShift(MockUniswapV3Pool(address(0)), 0, 0);

        (bool due,) = r.isDue(bob);
        assertFalse(due, "bob due in hetzelfde blok");
        address[] memory list = r.dueOwners(0, 10);
        assertEq(list.length, 0);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockMoveExceeded.selector, poolEurcUsdc));
        r.execute(bob, keeper);

        _nextBlock();
        (due,) = r.isDue(bob);
        assertTrue(due, "bob een blok later");
        r.execute(bob, keeper);
    }

    // ─── Rondes in delen ────────────────────────────────────────────────────────────────────────────────────

    function test_chunk_nextOnlyAfterChunkInterval() public {
        poolEurcUsdc.setLiquidity(1e12);
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        r.execute(alice, keeper);
        uint256 t0 = vm.getBlockTimestamp();

        _warp(10 minutes - 1);
        (bool due,) = r.isDue(alice);
        assertFalse(due, "due voor CHUNK_INTERVAL");
        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(alice, keeper);

        _warp(1);
        (, uint256 remBefore) = _round(alice);
        int256 delta;
        (due, delta) = r.isDue(alice);
        assertTrue(due, "deel niet due na CHUNK_INTERVAL");
        assertEq(r.dueOwners(0, 10).length, 1);
        assertEq(r.dueOwners(0, 10)[0], alice);
        uint256 before = eurc.balanceOf(alice);
        r.execute(alice, keeper);
        assertEq(before - eurc.balanceOf(alice), uint256(delta));
        assertEq(r.lastExecutedAt(alice), uint64(t0 + 10 minutes), "lastExecutedAt volgt het deel");
        (, uint256 remAfter) = _round(alice);
        assertEq(remAfter, remBefore - uint256(delta), "restbudget daalt met het deel");
    }

    /// @notice Een correctie loopt in delen af tot binnen de band; daarna geen deel meer, pas weer na `interval`.
    function test_chunk_runsUntilWithinBand() public {
        poolEurcUsdc.setLiquidity(1e13); // ~1.875 EURC per deel
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        uint256 chunks;
        uint256 traded;
        for (uint256 i; i < 20; i++) {
            (bool due, int256 delta) = r.isDue(alice);
            if (!due) break;
            r.execute(alice, keeper);
            traded += uint256(delta);
            chunks++;
            _warp(10 minutes);
        }
        assertGt(chunks, 3, "niet in delen");
        // De ronde eindigt zodra de schatting zonder fee binnen de band uitkomt; met 0,25% fee kan de owner net
        // (hooguit de fee van het laatste deel) buiten de band blijven. Die rest wacht op het gewone interval.
        (uint256 fraction,) = _fractionOf(alice);
        assertGe(fraction, 0.749e18, "niet (bijna) binnen de band");
        (, uint256 remaining) = _round(alice);
        assertEq(remaining, 0, "ronde niet afgesloten");
        assertLe(traded, 10_000e6, "budget overschreden");
        // Pas na `interval` na het laatste deel weer een nieuwe ronde (als er dan iets te doen is).
        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(alice, keeper);
    }

    /// @notice Het budget van de ronde (maxCorrectionBps van de waarde bij de eerste run) is niet via delen te
    ///         overschrijden; daarna geldt weer `interval`, ook al staat de owner nog buiten de band.
    function test_chunk_budgetCapsRound() public {
        poolEurcUsdc.setLiquidity(2e12); // ~375 EURC per deel
        _setUser(alice, 10_000e6, 0, _params(1000, 20e6)); // budget 1.000 EURC, correctie 8.000
        uint256 traded;
        uint256 chunks;
        for (uint256 i; i < 10; i++) {
            (bool due, int256 delta) = r.isDue(alice);
            if (!due) break;
            r.execute(alice, keeper);
            traded += uint256(delta);
            chunks++;
            _warp(10 minutes);
        }
        assertEq(traded, 1000e6, "budget niet precies opgebruikt");
        assertEq(chunks, 3, "375 + 375 + 250");
        (, uint256 remaining) = _round(alice);
        assertEq(remaining, 0);
        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(alice, keeper);
        _warp(1 hours);
        (bool dueAgain, int256 d) = r.isDue(alice);
        assertTrue(dueAgain, "nieuwe ronde na interval");
        assertGt(d, 0);
    }

    /// @notice Een restbudget onder minTradeEurc opent geen ronde.
    function test_chunk_tailBelowMinTradeEndsRound() public {
        poolEurcUsdc.setLiquidity(1e12); // ~187,5 EURC per deel
        _setUser(alice, 10_000e6, 0, _params(200, 20e6)); // budget 200 EURC -> rest 12,5 < 20
        r.execute(alice, keeper);
        (, uint256 remaining) = _round(alice);
        assertEq(remaining, 0);
    }

    /// @notice Een run die door de allowance (niet de liquiditeit) begrensd is, opent geen ronde.
    function test_chunk_allowanceBoundRunOpensNoRound() public {
        poolEurcUsdc.setLiquidity(1e12);
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        vm.prank(alice);
        eurc.approve(address(r), 100e6);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 9_900e6);
        (, uint256 remaining) = _round(alice);
        assertEq(remaining, 0);
    }

    /// @notice Richtingswissel: een deel gebeurt nooit in de andere richting dan de ronde (geen ping-pong).
    function test_chunk_directionChangeNeverStartsChunk() public {
        poolEurcUsdc.setLiquidity(1e12);
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        r.execute(alice, keeper);
        (bool isBuy, uint256 remaining) = _round(alice);
        assertTrue(isBuy);
        assertGt(remaining, 0);

        // cbBTC 1.000× duurder: de kleine positie is nu ruim boven 80%, dus verkopen.
        _warp(10 minutes);
        _setPrice(PRICE * 1000);
        router.setPrice(PRICE * 1000);
        (bool due,) = r.isDue(alice);
        assertFalse(due, "deel in de andere richting");
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        r.execute(alice, keeper);

        _warp(1 hours);
        _setPrice(PRICE * 1000);
        int256 delta;
        (due, delta) = r.isDue(alice);
        assertTrue(due, "na interval wel");
        assertLt(delta, 0, "nu verkopen");
        r.execute(alice, keeper);
    }

    function test_setParams_abortsRound() public {
        poolEurcUsdc.setLiquidity(1e12);
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        r.execute(alice, keeper);
        (, uint256 remaining) = _round(alice);
        assertGt(remaining, 0);
        vm.prank(alice);
        r.setParams(_params(10_000, 20e6));
        (, remaining) = _round(alice);
        assertEq(remaining, 0, "ronde niet afgebroken");
        _warp(10 minutes);
        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(alice, keeper);
    }

    /// @notice Een deel dat nu onder MIN_TRADE_FLOOR zou vallen (ruimte in dit blok op), wacht: niet due, revert
    ///         vooraf, en de ronde blijft staan tot er weer ruimte is.
    function test_chunk_belowFloorWaitsAndKeepsRound() public {
        poolEurcUsdc.setLiquidity(1e12);
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        r.execute(alice, keeper);
        (, uint256 remaining) = _round(alice);
        _warp(10 minutes);
        poolEurcUsdc.swapToPrice(1.0005e6, 1e6); // iemand anders gebruikt de ruimte in dit blok
        (bool due,) = r.isDue(alice);
        assertFalse(due);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockMoveExceeded.selector, poolEurcUsdc));
        r.execute(alice, keeper);
        (, uint256 stillRemaining) = _round(alice);
        assertEq(stillRemaining, remaining, "ronde verdwenen");
        _nextBlock();
        (due,) = r.isDue(alice);
        assertTrue(due);
    }

    /// @notice Een deel mag kleiner zijn dan minTradeEurc van de gebruiker (die geldt voor de correctie), maar
    ///         nooit kleiner dan MIN_TRADE_FLOOR.
    function test_chunk_smallerThanUserMinTradeButAboveFloor() public {
        poolEurcUsdc.setLiquidity(1e12); // ~187,5 EURC per deel
        _setUser(alice, 10_000e6, 0, _params(10_000, 500e6));
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertLt(uint256(delta), 500e6);
        assertGe(uint256(delta), r.MIN_TRADE_FLOOR());
        r.execute(alice, keeper);
        // Fee van het deel dekt de beloning.
        assertEq(eurc.balanceOf(keeper), r.KEEPER_REWARD_EURC());

        // Liquiditeit zo klein dat een deel onder de vloer valt: wachten.
        poolEurcUsdc.setLiquidity(1e11); // ~18,75 EURC
        _warp(10 minutes);
        (due,) = r.isDue(alice);
        assertFalse(due);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockMoveExceeded.selector, poolEurcUsdc));
        r.execute(alice, keeper);
    }

    /// @notice Lead 3: een donatie tijdens een ronde vergroot het budget niet.
    function test_chunk_donationDoesNotGrowRoundBudget() public {
        poolEurcUsdc.setLiquidity(2e12);
        _setUser(alice, 10_000e6, 0, _params(1000, 20e6)); // budget 1.000
        r.execute(alice, keeper);
        eurc.mint(alice, 100_000e6); // donatie: waarde ×11, correctie veel groter
        uint256 traded = 10_000e6 - (eurc.balanceOf(alice) - 100_000e6);
        for (uint256 i; i < 10; i++) {
            _warp(10 minutes);
            (bool due, int256 delta) = r.isDue(alice);
            if (!due) break;
            r.execute(alice, keeper);
            traded += uint256(delta);
        }
        assertEq(traded, 1000e6, "budget van de ronde groeide mee met de donatie");
    }

    /// @notice Na `interval` sinds de laatste run begint een nieuwe ronde met een vers budget, ook als er nog een
    ///         (verlopen) ronde stond.
    function test_chunk_freshRoundAfterIntervalReplacesStaleRound() public {
        poolEurcUsdc.setLiquidity(1e12);
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        r.execute(alice, keeper);
        (, uint256 remaining) = _round(alice);
        _warp(1 hours);
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        (, uint256 total) = _fractionOf(alice);
        r.execute(alice, keeper);
        (, uint256 fresh) = _round(alice);
        assertGt(fresh, remaining - uint256(delta), "budget niet vernieuwd");
        assertEq(fresh + uint256(delta), total, "vers budget = 100% van de waarde bij deze run");
    }

    /// @notice Loopt de ronde tot vlak bij de band, dan sluit de schatting (zonder fee) de ronde af zodra het deel
    ///         de owner binnen de band brengt; er blijft geen ronde staan.
    function test_chunk_roundEndsWhenRunReachesBand() public {
        poolEurcUsdc.setLiquidity(1e13); // ~1.875 EURC per deel
        // 7.400 EURC + cbBTC ter waarde van 2.600: aandeel 26%, afwijking 54% × 10.000 = 5.400.
        _setUser(alice, 7_400e6, 3_250_000, _params(10_000, 20e6));
        for (uint256 i; i < 10; i++) {
            (bool due,) = r.isDue(alice);
            if (!due) break;
            r.execute(alice, keeper);
            (, uint256 remaining) = _round(alice);
            (uint256 fraction,) = _fractionOf(alice);
            if (fraction + 0.05e18 >= 0.8e18) assertEq(remaining, 0, "ronde blijft staan binnen de band");
            _warp(10 minutes);
        }
    }

    function _fractionOf(address user) internal view returns (uint256 fractionWad, uint256 total) {
        uint256 position = Math.mulDiv(cbbtc.balanceOf(user), PRICE, 1e8);
        total = eurc.balanceOf(user) + position;
        fractionWad = total == 0 ? 0 : Math.mulDiv(position, 1e18, total);
    }
}
