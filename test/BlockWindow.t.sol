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

    function window(IUniswapV3Pool pool) external view returns (bool touched, Window memory w) {
        return _window(pool);
    }

    function maxRunEurc(bool isBuy, uint256 price) external view returns (uint256 eurc, address binding) {
        (, Window memory w1, Window memory w2) = _windows();
        return _maxRunEurc(isBuy, price, w1, w2);
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

        (bool touched, Rebalancer.Window memory w) = h.window(poolEurcUsdc);
        assertFalse(touched);
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
        (bool touched, Rebalancer.Window memory w) = h.window(poolEurcUsdc);
        assertFalse(touched);
        assertEq(w.upper, type(uint160).max, "bovengrens afgekapt");
        assertLe(w.lower, poolEurcUsdc.sqrtPriceX96());

        poolEurcUsdc.setSqrtPriceX96(TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK));
        (touched, w) = h.window(poolEurcUsdc);
        assertFalse(touched);
        assertGe(w.upper, poolEurcUsdc.sqrtPriceX96());

        // Tick MAX_TICK kan een echte pool niet hebben; dan een leeg venster in plaats van een revert in TickMath.
        poolEurcUsdc.setSqrtPriceX96(TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK));
        assertEq(poolEurcUsdc.tick(), TickMath.MAX_TICK, "opzet");
        (touched, w) = h.window(poolEurcUsdc);
        assertFalse(touched);
        assertGt(w.lower, w.upper, "venster niet leeg");
    }

    /// @notice Blokcheck: een observatie van dit blok op `observationIndex` (bij elke index en cardinality, ook 1)
    ///         markeert de pool als aangeraakt; een oudere observatie niet, en dan volgt het venster uit slot0.tick.
    ///         Vervangt de fuzz-test op de afleiding van de begintick uit twee observaties: die afleiding is weg,
    ///         want zonder observatie in dit blok is slot0.tick de begintick, en met een observatie is er geen run.
    function testFuzz_window_observationThisBlockMeansTouched(int24 tick, uint16 index, uint16 cardinality, uint32 age)
        public
    {
        tick = int24(bound(tick, -200_000, 200_000));
        cardinality = uint16(bound(cardinality, 1, type(uint16).max));
        index = uint16(bound(index, 0, cardinality - 1));
        age = uint32(bound(age, 1, block.timestamp - 1));
        poolEurcUsdc.setSqrtPriceX96(TickMath.getSqrtPriceAtTick(tick));
        (, Rebalancer.Window memory ref) = h.window(poolEurcUsdc);
        poolEurcUsdc.setObservationCardinality(cardinality);
        poolEurcUsdc.setObservationIndex(index);

        poolEurcUsdc.setObservation(index, uint32(block.timestamp) - age, 0, true);
        (bool touched, Rebalancer.Window memory w) = h.window(poolEurcUsdc);
        assertFalse(touched, "oude observatie telt als aangeraakt");
        assertEq(w.lower, ref.lower, "lower volgt niet slot0.tick");
        assertEq(w.upper, ref.upper, "upper volgt niet slot0.tick");
        assertLt(w.lower, TickMath.getSqrtPriceAtTick(tick), "venster niet rond slot0.tick");
        assertGt(w.upper, TickMath.getSqrtPriceAtTick(tick + 1), "venster niet rond slot0.tick");

        poolEurcUsdc.setObservation(index, uint32(block.timestamp), 0, true);
        (touched,) = h.window(poolEurcUsdc);
        assertTrue(touched, "observatie van dit blok niet gezien");
    }

    /// @notice Een swap binnen de tick schrijft geen observatie en laat het venster staan; een swap die de tick
    ///         verandert (mock schrijft zoals Uniswap) raakt de pool aan. Een volgend blok begint op de nieuwe koers.
    function test_window_swapWithinTickKeepsWindow_tickChangeTouches() public {
        (, Rebalancer.Window memory before) = h.window(poolEurcUsdc);
        poolEurcUsdc.swapToPrice(1e6, 1.00005e6); // 0,5 bp omhoog, binnen tick 0
        assertEq(poolEurcUsdc.tick(), 0, "opzet: tick");
        (bool touched, Rebalancer.Window memory within) = h.window(poolEurcUsdc);
        assertFalse(touched, "swap binnen de tick telt als aangeraakt");
        assertEq(within.lower, before.lower);
        assertEq(within.upper, before.upper);

        poolEurcUsdc.swapToPrice(1e6, 1.002e6); // 20 bp: tickwissel
        (touched,) = h.window(poolEurcUsdc);
        assertTrue(touched, "tickwissel niet gezien");

        _nextBlock();
        Rebalancer.Window memory next;
        (touched, next) = h.window(poolEurcUsdc);
        assertFalse(touched, "volgend blok nog aangeraakt");
        assertGt(next.upper, before.upper);
    }

    /// @notice De constructor eist geen minimum aantal observaties meer: de blokcheck leest alleen de laatste.
    ///         (Vervangt `test_constructor_rejectsPoolWithCardinalityBelowTwo`; die check was alleen nodig voor de
    ///         afleiding van de begintick uit de vorige observatie.)
    function test_constructor_acceptsCardinalityOne() public {
        poolEurcUsdc.setObservationCardinality(1);
        poolUsdcCbbtc.setObservationCardinality(1);
        Rebalancer fresh = new Rebalancer(_deployment());
        assertEq(address(fresh.POOL_EURC_USDC()), address(poolEurcUsdc));
    }

    /// @notice Een observatie van dit blok in een van beide pools: execute revert vóór de swap met
    ///         PoolTouchedThisBlock, isDue en dueOwners melden niets. Een volgend blok wel. Ook bij cardinality 1.
    ///         (Vervangt `test_blockStartUnknown_revertsAndNotDue`: een onbekende begintick bestaat niet meer.)
    function test_poolTouchedThisBlock_revertsAndNotDue() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        MockUniswapV3Pool[2] memory pools = [poolEurcUsdc, poolUsdcCbbtc];
        for (uint256 i; i < 2; i++) {
            pools[i].setObservationCardinality(1);
            pools[i].setObservation(0, uint32(vm.getBlockTimestamp()), 0, true);
            (bool due, int256 delta) = r.isDue(alice);
            assertFalse(due, "isDue");
            assertEq(delta, 0);
            assertEq(r.dueOwners(0, 10).length, 0, "dueOwners");
            vm.expectRevert(abi.encodeWithSelector(Rebalancer.PoolTouchedThisBlock.selector, pools[i]));
            r.execute(alice, keeper);
            assertEq(router.calls(), 0, "swap gedaan");
            assertEq(r.lastExecutedAt(alice), 0);
            pools[i].setObservation(0, 1, 0, true); // weer een oude observatie
        }
        _nextBlock();
        (bool dueNext,) = r.isDue(alice);
        assertTrue(dueNext);
        r.execute(alice, keeper);
    }

    /// @notice De selector die wekkers als tijdelijke revert herkennen.
    function test_poolTouchedThisBlock_selector() public pure {
        assertEq(Rebalancer.PoolTouchedThisBlock.selector, bytes4(keccak256("PoolTouchedThisBlock(address)")));
        assertEq(Rebalancer.PoolTouchedThisBlock.selector, bytes4(0x817a53db));
    }

    // ─── Vooraf: pool in dit blok al bewogen ────────────────────────────────────────────────────────────────

    /// @notice Een push van 7 bp in dit blok verandert de tick en raakt dus de blokcheck. Vóór de blokcheck strandde
    ///         dit op het venster (BlockMoveExceeded); de weigering vooraf is nu strenger en heeft een eigen error.
    function test_execute_revertsPoolTouchedBeforeSwap() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        // 7 bp in dit blok (tegen de koop in, dus omhoog).
        poolEurcUsdc.swapToPrice(1e6, 1.0007e6);
        (bool due,) = r.isDue(alice);
        assertFalse(due, "isDue");
        assertEq(r.dueOwners(0, 10).length, 0, "dueOwners");
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.PoolTouchedThisBlock.selector, poolEurcUsdc));
        r.execute(alice, keeper);
        assertEq(router.calls(), 0, "swap gedaan");
        assertEq(r.lastExecutedAt(alice), 0);

        // Volgend blok: de nieuwe koers is de beginkoers.
        _nextBlock();
        (due,) = r.isDue(alice);
        assertTrue(due);
        r.execute(alice, keeper);
    }

    function test_execute_revertsPoolTouchedBeforeSwapInCbbtcPool() public {
        _setUser(bob, 0, 1_250_000, _defaultParams());
        poolUsdcCbbtc.swapToPrice(PRICE, 0.9993e8); // ~7 bp
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.PoolTouchedThisBlock.selector, poolUsdcCbbtc));
        r.execute(bob, keeper);
    }

    /// @notice Een push binnen de begintick schrijft geen observatie en mag; een push over de tickgrens niet, ook
    ///         niet als hij binnen het venster van 6 bp blijft. Vroeger mocht een push van 4 bp
    ///         (`test_execute_pushWithinWindowAllowed`): dat is precies de ruimte die push-then-JIT gebruikte
    ///         (review PR #18, M-1).
    function test_execute_pushWithinTickAllowed_pushOverTickRefused() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        // Vorig blok: koers midden in tick 0.
        poolEurcUsdc.setPrice(1e6, 1.00005e6);
        uint256 snap = vm.snapshotState();

        poolEurcUsdc.swapToPrice(1e6, 1.000001e6); // ~0,5 bp in de richting van de koop, binnen tick 0
        assertEq(poolEurcUsdc.tick(), 0, "opzet: tick");
        (bool due,) = r.isDue(alice);
        assertTrue(due, "push binnen de tick");
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 900e6);

        vm.revertToState(snap);
        poolEurcUsdc.swapToPrice(1.0004e6, 1e6); // 4 bp in de richting van de koop: tickwissel
        (due,) = r.isDue(alice);
        assertFalse(due, "push over de tick");
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.PoolTouchedThisBlock.selector, poolEurcUsdc));
        r.execute(alice, keeper);
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

        // Een push vooraf kan alleen nog binnen de begintick (anders PoolTouchedThisBlock), en het venster blijft vanaf
        // de randen van die tick gerekend. Vorig blok: koers midden in tick 0. Push binnen de tick naar net boven P(0),
        // dan eigen impact tot 6 bp onder P(0): buiten het venster, dat omlaag vanaf P(1) rekent en dus 5 bp onder P(0)
        // eindigt. Tot 5 bp onder P(0) past wel. (Vroeger was de push hier 3 bp over de tickgrens; die raakt nu de
        // blokcheck.)
        poolEurcUsdc.setPrice(1e6, 1.00005e6);
        poolEurcUsdc.swapToPrice(1e6, 1.000001e6);
        assertEq(poolEurcUsdc.tick(), 0, "opzet: tick");
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

    /// @notice Lead 2: twee runs in hetzelfde blok. De run van alice verandert de tick (5 bp); bob revert daarom
    ///         vooraf op de blokcheck (vroeger op het venster, BlockMoveExceeded), een blok later niet.
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
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.PoolTouchedThisBlock.selector, poolEurcUsdc));
        r.execute(bob, keeper);

        _nextBlock();
        (due,) = r.isDue(bob);
        assertTrue(due, "bob een blok later");
        r.execute(bob, keeper);
    }

    /// @notice Twee runs in hetzelfde blok die de tick niet veranderen, delen het venster van de begintick: de tweede
    ///         mag, en wordt gesized op de ruimte die de eerste overliet.
    function test_execute_twoOwnersSameBlockWithinTickShareWindow() public {
        poolEurcUsdc.setLiquidity(1e12);
        poolEurcUsdc.setPrice(1e6, 1.00009e6); // vorig blok: bovenin tick 0
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        _setUser(bob, 10_000e6, 0, _params(10_000, 20e6));
        (, int256 deltaAliceAlone) = r.isDue(alice);
        router.setPoolShift(poolEurcUsdc, 1e6, 1.00001e6); // run van alice blijft binnen tick 0
        r.execute(alice, keeper);
        router.setPoolShift(MockUniswapV3Pool(address(0)), 0, 0);
        assertEq(poolEurcUsdc.tick(), 0, "opzet: tick");
        (bool due, int256 deltaBob) = r.isDue(bob);
        assertTrue(due, "bob mag in hetzelfde blok zolang de tick staat");
        assertLt(deltaBob, deltaAliceAlone, "bob krijgt de resterende ruimte, niet het hele venster");
        r.execute(bob, keeper);
    }

    // ─── Liquiditeitsklif (review L-1) ──────────────────────────────────────────────────────────────────────

    /// @dev Zet EURC/USDC (vorig blok) op tick `t`, iets boven de onderrand.
    function _p1AtTick(int24 t) internal {
        poolEurcUsdc.setSqrtPriceX96(TickMath.getSqrtPriceAtTick(t) + 1_000);
        assertEq(poolEurcUsdc.tick(), t, "opzet: tick");
    }

    /// @dev Grootste run bij liquiditeit `liq` in EURC/USDC en `liquidityNet` = `net` op `boundary`, in een snapshot.
    function _runWith(bool isBuy, uint128 liq, int24 boundary, int128 net) internal returns (uint256 run) {
        uint256 snap = vm.snapshotState();
        poolEurcUsdc.setLiquidity(liq);
        poolEurcUsdc.setLiquidityNet(boundary, net);
        (run,) = h.maxRunEurc(isBuy, PRICE);
        vm.revertToState(snap);
    }

    /// @notice Koop (EURC/USDC omlaag) met de koers op tick 0: grens 0 ligt in het venster en wordt meteen gekruist.
    ///         Houdt de liquiditeit daar op (1e12 → 5e11), dan rekent de run met 5e11. Groeit ze (1e12 → 1,5e12),
    ///         dan blijft de run die van 1e12. isDue en execute volgen dezelfde omvang.
    function test_cliff_buy_boundaryInWindowUsesThinnerSide() public {
        uint256 thin = _runWith(true, 5e11, 0, 0);
        uint256 full = _runWith(true, 1e12, 0, 0);
        assertGt(thin, 20e6, "opzet");
        assertEq(_runWith(true, 1e12, 0, 5e11), thin, "klif niet meegerekend");
        assertEq(_runWith(true, 1e12, 0, -5e11), full, "liquiditeit voorbij de grens maakte de run groter");

        poolEurcUsdc.setLiquidity(1e12);
        poolEurcUsdc.setLiquidityNet(0, 5e11);
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(uint256(delta), thin, "isDue");
        r.execute(alice, keeper);
        assertEq(10_000e6 - eurc.balanceOf(alice), thin, "execute");
    }

    /// @notice Verkoop (EURC/USDC omhoog) met de koers op tick 5: grens 10 ligt in het venster. Zelfde regel, andere
    ///         richting en teken: omhoog kruisen telt `liquidityNet` op.
    function test_cliff_sell_boundaryInWindowUsesThinnerSide() public {
        _p1AtTick(5);
        uint256 thin = _runWith(false, 5e11, 10, 0);
        uint256 full = _runWith(false, 1e12, 10, 0);
        assertGt(thin, 20e6, "opzet");
        assertEq(_runWith(false, 1e12, 10, -5e11), thin, "klif niet meegerekend");
        assertEq(_runWith(false, 1e12, 10, 5e11), full, "liquiditeit voorbij de grens maakte de run groter");
        // Tick 5 omlaag: grens 0 ligt ook in het venster (t - 5).
        assertEq(_runWith(true, 1e12, 0, 5e11), _runWith(true, 5e11, 0, 0), "grens t - 5 niet meegerekend");
    }

    /// @notice Geen initialiseerbare grens in het venster in de swaprichting: `liquidityNet` van de grens erbuiten
    ///         doet niets. Koop op tick 6 (grens 0 ligt net onder het venster), verkoop op tick 4 (grens 10 net
    ///         erboven).
    function test_cliff_noBoundaryInWindowIgnoresNet() public {
        _p1AtTick(6);
        assertEq(_runWith(true, 1e12, 0, 1e12), _runWith(true, 1e12, 0, 0), "koop: grens buiten het venster telde");
        _p1AtTick(4);
        assertEq(_runWith(false, 1e12, 10, -1e12), _runWith(false, 1e12, 10, 0), "verkoop: grens buiten het venster");
    }

    /// @notice Voorbij de grens geen liquiditeit: geen run. isDue en dueOwners melden niets en execute revert vooraf
    ///         met BlockMoveExceeded, in beide richtingen. Zo zijn isDue en execute het eens (review L-1: vroeger
    ///         isDue true en execute elke keer een revert na de swap).
    function test_cliff_zeroLiquidityBeyondBoundary_notDue() public {
        poolEurcUsdc.setLiquidity(1e12);
        poolEurcUsdc.setLiquidityNet(0, 1e12);
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        (bool due,) = r.isDue(alice);
        assertFalse(due, "koop due");
        assertEq(r.dueOwners(0, 10).length, 0);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockMoveExceeded.selector, poolEurcUsdc));
        r.execute(alice, keeper);

        _p1AtTick(5);
        poolEurcUsdc.setLiquidityNet(10, -1e12);
        _setUser(bob, 0, 12_500_000, _params(10_000, 20e6));
        (due,) = r.isDue(bob);
        assertFalse(due, "verkoop due");
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockMoveExceeded.selector, poolEurcUsdc));
        r.execute(bob, keeper);
    }

    /// @notice USDC/cbBTC heeft negatieve ticks: de grens omlaag is floor(tick / 10) × 10, niet naar nul afgerond.
    function test_cliff_negativeTickInCbbtcPool() public {
        poolEurcUsdc.setLiquidity(type(uint128).max);
        int24 t = poolUsdcCbbtc.tick();
        assertLt(t, 0, "opzet: negatieve tick");
        int24 b = t / 10 * 10;
        if (t % 10 != 0) b -= 10;
        poolUsdcCbbtc.setSqrtPriceX96(TickMath.getSqrtPriceAtTick(b + 2) + 1_000); // koop omlaag: grens b in venster
        poolUsdcCbbtc.setLiquidity(1e13);
        (uint256 full, address binding) = h.maxRunEurc(true, PRICE);
        assertEq(binding, address(poolUsdcCbbtc), "opzet: cbBTC-pool begrenst");
        poolUsdcCbbtc.setLiquidityNet(b + 10, 1e13); // naar nul afgeronde grens: buiten de swaprichting, telt niet
        (uint256 run,) = h.maxRunEurc(true, PRICE);
        assertEq(run, full, "verkeerde grens bij negatieve tick");
        poolUsdcCbbtc.setLiquidityNet(b, 5e12);
        (run,) = h.maxRunEurc(true, PRICE);
        assertLt(run, full * 51 / 100, "grens bij negatieve tick niet meegerekend");
        assertGt(run, full * 49 / 100);
    }

    /// @notice Voor elke `liquidityNet` op de grens en elke tick rond een veelvoud van 10: de run is nooit groter dan
    ///         zonder grens, en gelijk aan de run bij min(liquiditeit nu, liquiditeit voorbij de grens) als de grens in
    ///         het venster ligt.
    function testFuzz_cliff_neverLargerAndMinLiquidity(int128 net, uint8 offset, bool isBuy) public {
        int24 t = int24(uint24(bound(offset, 0, 9)));
        _p1AtTick(t);
        uint128 liq = 1e12;
        net = int128(bound(net, -2e12, 2e12));
        int24 boundary = isBuy ? int24(0) : int24(10);
        uint256 without = _runWith(isBuy, liq, boundary, 0);
        uint256 with = _runWith(isBuy, liq, boundary, net);
        assertLe(with, without, "run groter door liquiditeit voorbij de grens");
        // Grens in het venster: omlaag voor t <= 5, omhoog voor t >= 5 (zie _maxInput).
        bool inWindow = isBuy ? t <= 5 : t >= 5;
        int256 beyond = isBuy ? int256(uint256(liq)) - net : int256(uint256(liq)) + net;
        if (!inWindow) {
            assertEq(with, without, "grens buiten het venster telde mee");
        } else if (beyond <= 0) {
            assertEq(with, 0, "geen liquiditeit voorbij de grens, toch een run");
        } else {
            uint128 minLiq = uint128(Math.min(liq, uint256(beyond)));
            assertEq(with, _runWith(isBuy, minLiq, boundary, 0), "niet de kleinste liquiditeit");
        }
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
        // Iemand anders duwt de pool in dit blok over de tick. Vroeger viel het deel dan onder de vloer
        // (BlockMoveExceeded); nu weigert de blokcheck het eerder. De ronde blijft in beide gevallen staan.
        poolEurcUsdc.swapToPrice(1.0005e6, 1e6);
        (bool due,) = r.isDue(alice);
        assertFalse(due);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.PoolTouchedThisBlock.selector, poolEurcUsdc));
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
