// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Rebalancer} from "../src/Rebalancer.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {RebalancerTestBase} from "./Rebalancer.t.sol";

/// @dev Makes the block window readable for the edge tests.
contract RebalancerWindowHarness is Rebalancer {
    constructor(Deployment memory d) Rebalancer(d) {}

    function window(IUniswapV3Pool pool) external view returns (bool touched, Window memory w) {
        return _window(pool);
    }

    function windowFitsTickSpacing(uint16 moveBps, int24 spacing) external pure returns (bool) {
        return _windowFitsTickSpacing(moveBps, spacing);
    }

    function maxRunEurc(bool isBuy, uint256 price) external view returns (uint256 eurc, address binding) {
        (, Window memory w1, Window memory w2) = _windows();
        return _maxRunEurc(isBuy, price, w1, w2);
    }
}

/// @notice Unit tests for audit M-1: block window, run size from the liquidity, and rounds in chunks.
contract BlockWindowTest is RebalancerTestBase {
    RebalancerWindowHarness internal h;

    function setUp() public override {
        super.setUp();
        h = new RebalancerWindowHarness(_deployment());
    }

    // ─── Helpers ────────────────────────────────────────────────────────────────────────────────────────────

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

    /// @dev Largest EURC input into the EURC/USDC pool (buy, token0 in) per the formula from the specification,
    ///      computed independently of the contract: L × 2^96 × (√P − √lower) / (√P × √lower) × 75%.
    function _expectedMaxBuy(uint128 liquidity) internal view returns (uint256) {
        (, Rebalancer.Window memory w) = h.window(poolEurcUsdc);
        uint256 s = poolEurcUsdc.sqrtPriceX96();
        uint256 amount = Math.mulDiv(uint256(liquidity) << 96, s - w.lower, s) / w.lower;
        return amount * 7500 / 10_000;
    }

    /// @dev Same for sells: USDC (token1) in up to `upper`, equal to EURC at a 1:1 price.
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

    // ─── Window ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice The window lies conservatively within MAX_BLOCK_MOVE_BPS of both edges of the starting tick, and is, up
    ///         to rounding, equally wide: lower² ≥ P(t+1)² × (1 − 6 bp) and upper² ≤ P(t)² × (1 + 6 bp).
    function testFuzz_window_conservativeAndTight(int24 tick, uint256 frac) public {
        tick = int24(bound(tick, -200_000, 200_000));
        frac = bound(frac, 0, 1e18);
        uint256 p0 = TickMath.getSqrtPriceAtTick(tick);
        uint256 p1 = TickMath.getSqrtPriceAtTick(tick + 1);
        poolEurcUsdc.setSqrtPriceX96(uint160(p0 + Math.mulDiv(p1 - p0 - 1, frac, 1e18)));
        assertEq(poolEurcUsdc.tick(), tick, "setup: tick");

        (bool touched, Rebalancer.Window memory w) = h.window(poolEurcUsdc);
        assertFalse(touched);
        // P(t) from TickMath is rounded up; the real P(t) is above p0 - 1.
        assertGe(uint256(w.lower) * w.lower * 10_000, p1 * p1 * 9994, "lower bound too loose");
        assertLe(uint256(w.upper) * w.upper * 10_000, (p0 - 1) * (p0 - 1) * 10_006, "upper bound too loose");
        uint256 tol = p1 / (1 << 96) + 3;
        assertLe(w.lower, Math.sqrt(p1 * p1 * 9994 / 10_000) + tol, "lower bound needlessly tight");
        assertGe(w.upper + tol, Math.sqrt((p0 - 1) * (p0 - 1) * 10_006 / 10_000), "upper bound needlessly tight");
        assertEq(w.sqrtPriceX96, poolEurcUsdc.sqrtPriceX96());
    }

    /// @notice At the edges of the tick range the upper bound is not clipped (no uint160 overflow) and nothing reverts.
    function test_window_extremeTicksDoNotOverflow() public {
        poolEurcUsdc.setSqrtPriceX96(TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK - 1));
        (bool touched, Rebalancer.Window memory w) = h.window(poolEurcUsdc);
        assertFalse(touched);
        assertEq(w.upper, type(uint160).max, "upper bound clipped");
        assertLe(w.lower, poolEurcUsdc.sqrtPriceX96());

        poolEurcUsdc.setSqrtPriceX96(TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK));
        (touched, w) = h.window(poolEurcUsdc);
        assertFalse(touched);
        assertGe(w.upper, poolEurcUsdc.sqrtPriceX96());

        // A real pool cannot have tick MAX_TICK; then an empty window instead of a revert in TickMath.
        poolEurcUsdc.setSqrtPriceX96(TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK));
        assertEq(poolEurcUsdc.tick(), TickMath.MAX_TICK, "setup");
        (touched, w) = h.window(poolEurcUsdc);
        assertFalse(touched);
        assertGt(w.lower, w.upper, "window not empty");
    }

    /// @notice Block check: an observation of this block at `observationIndex` (at any index and cardinality, also 1)
    ///         marks the pool as touched; an older observation does not, and then the window follows from slot0.tick.
    ///         Replaces the fuzz test on deriving the starting tick from two observations: that derivation is gone,
    ///         because without an observation in this block slot0.tick is the start tick, and with one there is no run.
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
        assertFalse(touched, "old observation counts as touched");
        assertEq(w.lower, ref.lower, "lower does not follow slot0.tick");
        assertEq(w.upper, ref.upper, "upper does not follow slot0.tick");
        assertLt(w.lower, TickMath.getSqrtPriceAtTick(tick), "window not around slot0.tick");
        assertGt(w.upper, TickMath.getSqrtPriceAtTick(tick + 1), "window not around slot0.tick");

        poolEurcUsdc.setObservation(index, uint32(block.timestamp), 0, true);
        (touched,) = h.window(poolEurcUsdc);
        assertTrue(touched, "observation of this block not seen");
    }

    /// @notice A swap within the tick writes no observation and leaves the window as is; a swap that changes the
    ///         tick (mock writes like Uniswap) touches the pool. A next block starts at the new price.
    function test_window_swapWithinTickKeepsWindow_tickChangeTouches() public {
        (, Rebalancer.Window memory before) = h.window(poolEurcUsdc);
        poolEurcUsdc.swapToPrice(1e6, 1.00005e6); // 0.5 bp up, within tick 0
        assertEq(poolEurcUsdc.tick(), 0, "setup: tick");
        (bool touched, Rebalancer.Window memory within) = h.window(poolEurcUsdc);
        assertFalse(touched, "swap within the tick counts as touched");
        assertEq(within.lower, before.lower);
        assertEq(within.upper, before.upper);

        poolEurcUsdc.swapToPrice(1e6, 1.002e6); // 20 bp: tick change
        (touched,) = h.window(poolEurcUsdc);
        assertTrue(touched, "tick change not seen");

        _nextBlock();
        Rebalancer.Window memory next;
        (touched, next) = h.window(poolEurcUsdc);
        assertFalse(touched, "next block still touched");
        assertGt(next.upper, before.upper);
    }

    /// @notice The constructor no longer needs a minimum count of observations: the block check reads the last one.
    ///         (Replaces `test_constructor_rejectsPoolWithCardinalityBelowTwo`; that check was only needed for
    ///         deriving the starting tick from the previous observation.)
    function test_constructor_acceptsCardinalityOne() public {
        poolEurcUsdc.setObservationCardinality(1);
        poolUsdcCbbtc.setObservationCardinality(1);
        Rebalancer fresh = new Rebalancer(_deployment());
        assertEq(address(fresh.POOL_EURC_USDC()), address(poolEurcUsdc));
    }

    /// @notice An observation of this block in either pool: execute reverts before the swap with
    ///         PoolTouchedThisBlock, isDue and dueOwners report nothing. A next block does. Also at cardinality 1.
    ///         (Replaces `test_blockStartUnknown_revertsAndNotDue`: an unknown starting tick no longer exists.)
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
            assertEq(router.calls(), 0, "swap done");
            assertEq(r.lastExecutedAt(alice), 0);
            pools[i].setObservation(0, 1, 0, true); // an old observation again
        }
        _nextBlock();
        (bool dueNext,) = r.isDue(alice);
        assertTrue(dueNext);
        r.execute(alice, keeper);
    }

    /// @notice The selector that keepers recognise as a temporary revert.
    function test_poolTouchedThisBlock_selector() public pure {
        assertEq(Rebalancer.PoolTouchedThisBlock.selector, bytes4(keccak256("PoolTouchedThisBlock(address)")));
        assertEq(Rebalancer.PoolTouchedThisBlock.selector, bytes4(0x817a53db));
    }

    // ─── Before: pool already moved in this block ──────────────────────────────────────────────────────────

    /// @notice A push of 7 bp in this block changes the tick and so hits the block check. Before the block check this
    ///         stranded on the window (BlockMoveExceeded); the upfront rejection is now stricter and has its own error.
    function test_execute_revertsPoolTouchedBeforeSwap() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        // 7 bp in this block (against the buy, so up).
        poolEurcUsdc.swapToPrice(1e6, 1.0007e6);
        (bool due,) = r.isDue(alice);
        assertFalse(due, "isDue");
        assertEq(r.dueOwners(0, 10).length, 0, "dueOwners");
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.PoolTouchedThisBlock.selector, poolEurcUsdc));
        r.execute(alice, keeper);
        assertEq(router.calls(), 0, "swap done");
        assertEq(r.lastExecutedAt(alice), 0);

        // Next block: the new price is the starting price.
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

    /// @notice A push within the starting tick writes no observation and is allowed; a push across the tick boundary
    ///         is not, even if it stays within the 6 bp window. A push of 4 bp used to be allowed
    ///         (`test_execute_pushWithinWindowAllowed`): that is exactly the room push-then-JIT used
    ///         (review PR #18, M-1).
    function test_execute_pushWithinTickAllowed_pushOverTickRefused() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        // Previous block: price in the middle of tick 0.
        poolEurcUsdc.setPrice(1e6, 1.00005e6);
        uint256 snap = vm.snapshotState();

        poolEurcUsdc.swapToPrice(1e6, 1.000001e6); // ~0.5 bp in the direction of the buy, within tick 0
        assertEq(poolEurcUsdc.tick(), 0, "setup: tick");
        (bool due,) = r.isDue(alice);
        assertTrue(due, "push within the tick");
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 900e6);

        vm.revertToState(snap);
        poolEurcUsdc.swapToPrice(1.0004e6, 1e6); // 4 bp in the direction of the buy: tick change
        (due,) = r.isDue(alice);
        assertFalse(due, "push across the tick");
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.PoolTouchedThisBlock.selector, poolEurcUsdc));
        r.execute(alice, keeper);
    }

    // ─── After: push plus own swap ──────────────────────────────────────────────────────────────────────────

    function test_execute_revertsBlockMoveExceededAfterSwap() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        _setUser(bob, 0, 1_250_000, _defaultParams());

        // Buy pushes EURC/USDC 7 bp down: outside the window, within the spot check.
        router.setPoolShift(poolEurcUsdc, 1.0007e6, 1e6);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockMoveExceeded.selector, poolEurcUsdc));
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 1000e6, "nothing booked");
        assertEq(r.lastExecutedAt(alice), 0);

        // Sell via USDC/cbBTC: same.
        router.setPoolShift(poolUsdcCbbtc, PRICE, 1.0007e8);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockMoveExceeded.selector, poolUsdcCbbtc));
        r.execute(bob, keeper);
        assertEq(cbbtc.balanceOf(bob), 1_250_000);

        // A prior push can only stay within the starting tick (else PoolTouchedThisBlock), and the window is still
        // computed from that tick's edges. Previous block: price mid tick 0. Push within the tick to just above P(0),
        // then own impact to 6 bp below P(0): outside the window, which counts down from P(1), ending 5 bp below P(0).
        // Up to 5 bp below P(0) does fit. (The push here used to be 3 bp across the tick boundary; that now hits the
        // block check.)
        poolEurcUsdc.setPrice(1e6, 1.00005e6);
        poolEurcUsdc.swapToPrice(1e6, 1.000001e6);
        assertEq(poolEurcUsdc.tick(), 0, "setup: tick");
        router.setPoolShift(poolEurcUsdc, 1.0006e6, 1e6);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockMoveExceeded.selector, poolEurcUsdc));
        r.execute(alice, keeper);
        router.setPoolShift(poolEurcUsdc, 1.0005e6, 1e6);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 900e6);
    }

    // ─── Run size from the liquidity ────────────────────────────────────────────────────────────────────────

    function test_plan_buyBoundedByLiquidityOpensRound() public {
        uint128 liq = 1e12;
        poolEurcUsdc.setLiquidity(liq);
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6)); // correction 8,000, budget 10,000
        uint256 expected = _expectedMaxBuy(liq);
        assertGt(expected, 180e6, "setup");
        assertLt(expected, 200e6, "setup");

        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, int256(expected), "isDue reports the chunk");
        r.execute(alice, keeper);
        assertEq(10_000e6 - eurc.balanceOf(alice), expected, "run follows from the liquidity");
        (bool isBuy, uint256 remaining) = _round(alice);
        assertTrue(isBuy);
        assertEq(remaining, 10_000e6 - expected, "remaining budget");
    }

    function test_plan_sellBoundedByLiquidityOpensRound() public {
        uint128 liq = 1e12;
        poolEurcUsdc.setLiquidity(liq);
        _setUser(bob, 0, 12_500_000, _params(10_000, 20e6)); // 10,000 EURC in cbBTC, correction 2,000
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

    /// @notice Lead 2: two runs in the same block. Alice's run changes the tick (5 bp); bob therefore reverts
    ///         upfront on the block check (previously on the window, BlockMoveExceeded), one block later he does not.
    function test_execute_twoOwnersSameBlockShareWindow() public {
        poolEurcUsdc.setLiquidity(1e12);
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        _setUser(bob, 10_000e6, 0, _params(10_000, 20e6));
        // Alice's run pushes EURC/USDC 5 bp down (like a real swap: observation in this block).
        router.setPoolShift(poolEurcUsdc, 1.0005e6, 1e6);
        r.execute(alice, keeper);
        router.setPoolShift(MockUniswapV3Pool(address(0)), 0, 0);

        (bool due,) = r.isDue(bob);
        assertFalse(due, "bob due in the same block");
        address[] memory list = r.dueOwners(0, 10);
        assertEq(list.length, 0);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.PoolTouchedThisBlock.selector, poolEurcUsdc));
        r.execute(bob, keeper);

        _nextBlock();
        (due,) = r.isDue(bob);
        assertTrue(due, "bob one block later");
        r.execute(bob, keeper);
    }

    /// @notice Two runs in the same block that do not change the tick share the window of the starting tick: the second
    ///         is allowed, and is sized on the room the first one left.
    function test_execute_twoOwnersSameBlockWithinTickShareWindow() public {
        poolEurcUsdc.setLiquidity(1e12);
        poolEurcUsdc.setPrice(1e6, 1.00009e6); // previous block: top of tick 0
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        _setUser(bob, 10_000e6, 0, _params(10_000, 20e6));
        (, int256 deltaAliceAlone) = r.isDue(alice);
        router.setPoolShift(poolEurcUsdc, 1e6, 1.00001e6); // alice's run stays within tick 0
        r.execute(alice, keeper);
        router.setPoolShift(MockUniswapV3Pool(address(0)), 0, 0);
        assertEq(poolEurcUsdc.tick(), 0, "setup: tick");
        (bool due, int256 deltaBob) = r.isDue(bob);
        assertTrue(due, "bob allowed in the same block as long as the tick holds");
        assertLt(deltaBob, deltaAliceAlone, "bob gets the remaining room, not the whole window");
        r.execute(bob, keeper);
    }

    // ─── Liquidity cliff (review L-1) ───────────────────────────────────────────────────────────────────────

    /// @dev Sets EURC/USDC (previous block) to tick `t`, slightly above the lower edge.
    function _p1AtTick(int24 t) internal {
        poolEurcUsdc.setSqrtPriceX96(TickMath.getSqrtPriceAtTick(t) + 1_000);
        assertEq(poolEurcUsdc.tick(), t, "setup: tick");
    }

    /// @dev Largest run at liquidity `liq` in EURC/USDC and `liquidityNet` = `net` at `boundary`, in a snapshot.
    function _runWith(bool isBuy, uint128 liq, int24 boundary, int128 net) internal returns (uint256 run) {
        uint256 snap = vm.snapshotState();
        poolEurcUsdc.setLiquidity(liq);
        poolEurcUsdc.setLiquidityNet(boundary, net);
        (run,) = h.maxRunEurc(isBuy, PRICE);
        vm.revertToState(snap);
    }

    /// @notice Buy (EURC/USDC down) with the price at tick 0: boundary 0 is in the window and is crossed at once.
    ///         If the liquidity ends there (1e12 → 5e11), the run uses 5e11. If it grows (1e12 → 1.5e12),
    ///         the run stays that of 1e12. isDue and execute follow the same size.
    function test_cliff_buy_boundaryInWindowUsesThinnerSide() public {
        uint256 thin = _runWith(true, 5e11, 0, 0);
        uint256 full = _runWith(true, 1e12, 0, 0);
        assertGt(thin, 20e6, "setup");
        assertEq(_runWith(true, 1e12, 0, 5e11), thin, "cliff not counted");
        assertEq(_runWith(true, 1e12, 0, -5e11), full, "liquidity beyond the boundary made the run larger");

        poolEurcUsdc.setLiquidity(1e12);
        poolEurcUsdc.setLiquidityNet(0, 5e11);
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(uint256(delta), thin, "isDue");
        r.execute(alice, keeper);
        assertEq(10_000e6 - eurc.balanceOf(alice), thin, "execute");
    }

    /// @notice Sell (EURC/USDC up) with the price at tick 5: boundary 10 is in the window. Same rule, other
    ///         direction and sign: crossing upward adds `liquidityNet`.
    function test_cliff_sell_boundaryInWindowUsesThinnerSide() public {
        _p1AtTick(5);
        uint256 thin = _runWith(false, 5e11, 10, 0);
        uint256 full = _runWith(false, 1e12, 10, 0);
        assertGt(thin, 20e6, "setup");
        assertEq(_runWith(false, 1e12, 10, -5e11), thin, "cliff not counted");
        assertEq(_runWith(false, 1e12, 10, 5e11), full, "liquidity beyond the boundary made the run larger");
        // Tick 5 down: boundary 0 is also in the window (t - 5).
        assertEq(_runWith(true, 1e12, 0, 5e11), _runWith(true, 5e11, 0, 0), "boundary t - 5 not counted");
    }

    /// @notice No initializable boundary in the window in the swap direction: `liquidityNet` of the boundary outside it
    ///         does nothing. Buy at tick 6 (boundary 0 is just below the window), sell at tick 4 (boundary 10 just
    ///         above it).
    function test_cliff_noBoundaryInWindowIgnoresNet() public {
        _p1AtTick(6);
        assertEq(_runWith(true, 1e12, 0, 1e12), _runWith(true, 1e12, 0, 0), "buy: boundary outside the window counted");
        _p1AtTick(4);
        assertEq(_runWith(false, 1e12, 10, -1e12), _runWith(false, 1e12, 10, 0), "sell: boundary outside the window");
    }

    /// @notice No liquidity beyond the boundary: no run. isDue and dueOwners report nothing and execute reverts upfront
    ///         with BlockMoveExceeded, in both directions. So isDue and execute agree (review L-1: previously
    ///         isDue true and execute a revert after the swap every time).
    function test_cliff_zeroLiquidityBeyondBoundary_notDue() public {
        poolEurcUsdc.setLiquidity(1e12);
        poolEurcUsdc.setLiquidityNet(0, 1e12);
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        (bool due,) = r.isDue(alice);
        assertFalse(due, "buy due");
        assertEq(r.dueOwners(0, 10).length, 0);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockMoveExceeded.selector, poolEurcUsdc));
        r.execute(alice, keeper);

        _p1AtTick(5);
        poolEurcUsdc.setLiquidityNet(10, -1e12);
        _setUser(bob, 0, 12_500_000, _params(10_000, 20e6));
        (due,) = r.isDue(bob);
        assertFalse(due, "sell due");
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockMoveExceeded.selector, poolEurcUsdc));
        r.execute(bob, keeper);
    }

    /// @notice USDC/cbBTC has negative ticks: the boundary downward is floor(tick / 10) × 10, not rounded toward zero.
    function test_cliff_negativeTickInCbbtcPool() public {
        poolEurcUsdc.setLiquidity(type(uint128).max);
        int24 t = poolUsdcCbbtc.tick();
        assertLt(t, 0, "setup: negative tick");
        int24 b = t / 10 * 10;
        if (t % 10 != 0) b -= 10;
        poolUsdcCbbtc.setSqrtPriceX96(TickMath.getSqrtPriceAtTick(b + 2) + 1_000); // buy down: boundary b in window
        poolUsdcCbbtc.setLiquidity(1e13);
        (uint256 full, address binding) = h.maxRunEurc(true, PRICE);
        assertEq(binding, address(poolUsdcCbbtc), "setup: cbBTC pool limits");
        poolUsdcCbbtc.setLiquidityNet(b + 10, 1e13); // boundary rounded to zero: outside swap direction, not counted
        (uint256 run,) = h.maxRunEurc(true, PRICE);
        assertEq(run, full, "wrong boundary at negative tick");
        poolUsdcCbbtc.setLiquidityNet(b, 5e12);
        (run,) = h.maxRunEurc(true, PRICE);
        assertLt(run, full * 51 / 100, "boundary at negative tick not counted");
        assertGt(run, full * 49 / 100);
    }

    /// @notice For every `liquidityNet` at the boundary and every tick around a multiple of 10: the run is never larger
    ///         than without a boundary, and equal to the run at min(liquidity now, liquidity beyond the boundary) if
    ///         the boundary lies in the window.
    function testFuzz_cliff_neverLargerAndMinLiquidity(int128 net, uint8 offset, bool isBuy) public {
        int24 t = int24(uint24(bound(offset, 0, 9)));
        _p1AtTick(t);
        uint128 liq = 1e12;
        net = int128(bound(net, -2e12, 2e12));
        int24 boundary = isBuy ? int24(0) : int24(10);
        uint256 without = _runWith(isBuy, liq, boundary, 0);
        uint256 with = _runWith(isBuy, liq, boundary, net);
        assertLe(with, without, "run larger because of liquidity beyond the boundary");
        // Boundary in the window: down for t <= 5, up for t >= 5 (see _maxInput).
        bool inWindow = isBuy ? t <= 5 : t >= 5;
        int256 beyond = isBuy ? int256(uint256(liq)) - net : int256(uint256(liq)) + net;
        if (!inWindow) {
            assertEq(with, without, "boundary outside the window counted");
        } else if (beyond <= 0) {
            assertEq(with, 0, "no liquidity beyond the boundary, still a run");
        } else {
            uint128 minLiq = uint128(Math.min(liq, uint256(beyond)));
            assertEq(with, _runWith(isBuy, minLiq, boundary, 0), "not the smallest liquidity");
        }
    }

    // ─── Review I-2: dueOwners shares the run size across the page ───────────────────────────────────────────

    /// @notice `dueOwners` computes the run size per direction once per page (review I-2). For every state of the
    ///         liquidity, the tick boundary and a mix of owners (buy and sell, within the band, inactive, without
    ///         allowance, with or without an open round, large and small) each page returns exactly the owners where
    ///         `isDue` returns true, in registry order.
    function testFuzz_dueOwners_matchesIsDuePerOwner(uint256 seed, uint128 liq, int128 net, uint8 offset) public {
        _p1AtTick(int24(uint24(bound(offset, 0, 9))));
        liq = uint128(bound(liq, 1e9, 1e14));
        poolEurcUsdc.setLiquidity(liq);
        net = int128(bound(net, -2e14, 2e14));
        poolEurcUsdc.setLiquidityNet(0, net);
        poolEurcUsdc.setLiquidityNet(10, -net / 2);

        uint256 n = 10;
        address[] memory users = new address[](n);
        for (uint256 i; i < n; i++) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            users[i] = makeAddr(string.concat("iso", vm.toString(i)));
            Rebalancer.Params memory p = _params(uint16(bound(x >> 8, 10, 10_000)), uint64(bound(x >> 24, 20e6, 500e6)));
            p.targetBps = uint16(bound(x >> 40, 5, 95) * 100);
            p.bandBps = uint16(bound(x >> 48, 125, 2000));
            p.active = (x >> 64) % 8 != 0;
            _setUser(users[i], bound(x >> 72, 0, 200_000e6), bound(x >> 128, 0, 3e8), p);
            if ((x >> 192) % 7 == 0) {
                vm.prank(users[i]);
                eurc.approve(address(r), (x >> 200) % 2 == 0 ? 0 : 30e6);
            }
            // Some already run now: that sometimes opens a round (chunk after CHUNK_INTERVAL) or sets the clock.
            if ((x >> 208) % 3 == 0) {
                try r.execute(users[i], keeper) {} catch {}
                _nextBlock();
            }
        }
        _warp(r.CHUNK_INTERVAL());

        address[] memory expected = new address[](n);
        uint256 m;
        for (uint256 i; i < n; i++) {
            (bool isDueNow,) = r.isDue(users[i]);
            if (isDueNow) expected[m++] = users[i];
        }
        address[] memory due = r.dueOwners(0, n);
        assertEq(due.length, m, "number of due owners differs from isDue");
        for (uint256 i; i < m; i++) {
            assertEq(due[i], expected[i], "dueOwners differs from isDue");
        }
        // Pages of 3 together give the same list.
        uint256 k;
        for (uint256 off; off < n; off += 3) {
            address[] memory page = r.dueOwners(off, 3);
            for (uint256 j; j < page.length; j++) {
                assertEq(page[j], expected[k++], "page differs from isDue");
            }
        }
        assertEq(k, m, "pages miss owners");
    }

    // ─── Rounds in chunks ───────────────────────────────────────────────────────────────────────────────────

    function test_chunk_nextOnlyAfterChunkInterval() public {
        poolEurcUsdc.setLiquidity(1e12);
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        r.execute(alice, keeper);
        uint256 t0 = vm.getBlockTimestamp();

        _warp(10 minutes - 1);
        (bool due,) = r.isDue(alice);
        assertFalse(due, "due before CHUNK_INTERVAL");
        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(alice, keeper);

        _warp(1);
        (, uint256 remBefore) = _round(alice);
        int256 delta;
        (due, delta) = r.isDue(alice);
        assertTrue(due, "chunk not due after CHUNK_INTERVAL");
        assertEq(r.dueOwners(0, 10).length, 1);
        assertEq(r.dueOwners(0, 10)[0], alice);
        uint256 before = eurc.balanceOf(alice);
        r.execute(alice, keeper);
        assertEq(before - eurc.balanceOf(alice), uint256(delta));
        assertEq(r.lastExecutedAt(alice), uint64(t0 + 10 minutes), "lastExecutedAt follows the chunk");
        (, uint256 remAfter) = _round(alice);
        assertEq(remAfter, remBefore - uint256(delta), "remaining budget drops by the chunk");
    }

    /// @notice A correction runs in chunks until within the band; then no more chunks, only again after `interval`.
    function test_chunk_runsUntilWithinBand() public {
        poolEurcUsdc.setLiquidity(1e13); // ~1,875 EURC per chunk
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
        assertGt(chunks, 3, "not in chunks");
        // The round ends as soon as the estimate without fee lands within the band; with 0.25% fee the owner can stay
        // just (at most the fee of the last chunk) outside the band. That rest waits for the normal interval.
        (uint256 fraction,) = _fractionOf(alice);
        assertGe(fraction, 0.749e18, "not (almost) within the band");
        (, uint256 remaining) = _round(alice);
        assertEq(remaining, 0, "round not closed");
        assertLe(traded, 10_000e6, "budget exceeded");
        // Only after `interval` after the last chunk a new round again (if there is something to do then).
        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(alice, keeper);
    }

    /// @notice The budget of the round (maxCorrectionBps of the value at the first run) cannot be exceeded via
    ///         chunks; after that `interval` applies again, even though the owner is still outside the band.
    function test_chunk_budgetCapsRound() public {
        poolEurcUsdc.setLiquidity(2e12); // ~375 EURC per chunk
        _setUser(alice, 10_000e6, 0, _params(1000, 20e6)); // budget 1,000 EURC, correction 8,000
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
        assertEq(traded, 1000e6, "budget not used up exactly");
        assertEq(chunks, 3, "375 + 375 + 250");
        (, uint256 remaining) = _round(alice);
        assertEq(remaining, 0);
        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(alice, keeper);
        _warp(1 hours);
        (bool dueAgain, int256 d) = r.isDue(alice);
        assertTrue(dueAgain, "new round after interval");
        assertGt(d, 0);
    }

    /// @notice A remaining budget below minTradeEurc opens no round.
    function test_chunk_tailBelowMinTradeEndsRound() public {
        poolEurcUsdc.setLiquidity(1e12); // ~187.5 EURC per chunk
        _setUser(alice, 10_000e6, 0, _params(200, 20e6)); // budget 200 EURC -> rest 12.5 < 20
        r.execute(alice, keeper);
        (, uint256 remaining) = _round(alice);
        assertEq(remaining, 0);
    }

    /// @notice A run limited by the allowance (not the liquidity) opens no round.
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

    /// @notice Direction change: a chunk never happens in the other direction than the round (no ping-pong).
    function test_chunk_directionChangeNeverStartsChunk() public {
        poolEurcUsdc.setLiquidity(1e12);
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        r.execute(alice, keeper);
        (bool isBuy, uint256 remaining) = _round(alice);
        assertTrue(isBuy);
        assertGt(remaining, 0);

        // cbBTC 1,000× more expensive: the small position is now well above 80%, so sell.
        _warp(10 minutes);
        _setPrice(PRICE * 1000);
        router.setPrice(PRICE * 1000);
        (bool due,) = r.isDue(alice);
        assertFalse(due, "chunk in the other direction");
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        r.execute(alice, keeper);

        _warp(1 hours);
        _setPrice(PRICE * 1000);
        int256 delta;
        (due, delta) = r.isDue(alice);
        assertTrue(due, "after interval it is");
        assertLt(delta, 0, "now sell");
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
        assertEq(remaining, 0, "round not aborted");
        _warp(10 minutes);
        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(alice, keeper);
    }

    /// @notice A chunk that would now fall below MIN_TRADE_FLOOR (room in this block used up) waits: not due, reverts
    ///         upfront, and the round stays open until there is room again.
    function test_chunk_belowFloorWaitsAndKeepsRound() public {
        poolEurcUsdc.setLiquidity(1e12);
        _setUser(alice, 10_000e6, 0, _params(10_000, 20e6));
        r.execute(alice, keeper);
        (, uint256 remaining) = _round(alice);
        _warp(10 minutes);
        // Someone else pushes the pool across the tick in this block. Previously the chunk then fell below the floor
        // (BlockMoveExceeded); now the block check rejects it earlier. The round stays open in both cases.
        poolEurcUsdc.swapToPrice(1.0005e6, 1e6);
        (bool due,) = r.isDue(alice);
        assertFalse(due);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.PoolTouchedThisBlock.selector, poolEurcUsdc));
        r.execute(alice, keeper);
        (, uint256 stillRemaining) = _round(alice);
        assertEq(stillRemaining, remaining, "round disappeared");
        _nextBlock();
        (due,) = r.isDue(alice);
        assertTrue(due);
    }

    /// @notice A chunk may be smaller than the user's minTradeEurc (which applies to the correction), but
    ///         never smaller than MIN_TRADE_FLOOR.
    function test_chunk_smallerThanUserMinTradeButAboveFloor() public {
        poolEurcUsdc.setLiquidity(1e12); // ~187.5 EURC per chunk
        _setUser(alice, 10_000e6, 0, _params(10_000, 500e6));
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertLt(uint256(delta), 500e6);
        assertGe(uint256(delta), r.MIN_TRADE_FLOOR());
        r.execute(alice, keeper);
        // Fee of the chunk covers the reward.
        assertEq(eurc.balanceOf(keeper), r.KEEPER_REWARD_EURC());

        // Liquidity so small that a chunk falls below the floor: wait.
        poolEurcUsdc.setLiquidity(1e11); // ~18.75 EURC
        _warp(10 minutes);
        (due,) = r.isDue(alice);
        assertFalse(due);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BlockMoveExceeded.selector, poolEurcUsdc));
        r.execute(alice, keeper);
    }

    /// @notice Self-audit 2026-09-17, lead 13: the constructor rejects a window that does not fit well within the tick
    ///         spacing. With this contract's constants (6 bp, spacing 10) it holds; 10 or more at spacing 10 does not.
    function test_constructor_windowFitsTickSpacing() public view {
        assertTrue(h.windowFitsTickSpacing(r.MAX_BLOCK_MOVE_BPS(), r.TICK_SPACING()), "constants of this contract");
        assertTrue(h.windowFitsTickSpacing(9, 10));
        assertFalse(h.windowFitsTickSpacing(10, 10), "window as wide as the tick spacing");
        assertFalse(h.windowFitsTickSpacing(60, 10));
        assertFalse(h.windowFitsTickSpacing(6, 0), "spacing 0");
    }

    /// @notice Self-audit 2026-09-17, lead 11: if the wallet shrinks during a round (withdrawal or a price drop), then
    ///         a chunk is never larger than `maxCorrectionBps` of the value at that moment. Previously the budget of
    ///         the first run applied, so a chunk here could be 375 EURC on a wallet of 3,000 EURC.
    function test_chunk_budgetShrinksWithWallet() public {
        poolEurcUsdc.setLiquidity(2e12);
        _setUser(alice, 20_000e6, 0, _params(1000, 20e6)); // budget 2,000
        r.execute(alice, keeper);
        (, uint256 remaining) = _round(alice);
        assertGt(remaining, 0, "setup: the liquidity limited the first run, round open");
        uint256 cap = _expectedMaxBuy(2e12);
        assertGt(cap, 300e6, "setup: the liquidity allows more than 10% of the shrunken wallet");

        // The owner withdraws down to a wallet of ~3,000 EURC; it is still far below its 80% cbBTC target.
        uint256 btcValue = Math.mulDiv(cbbtc.balanceOf(alice), PRICE, 1e8);
        uint256 withdraw = eurc.balanceOf(alice) - (3_000e6 - btcValue);
        vm.prank(alice);
        eurc.transfer(bob, withdraw);
        _warp(10 minutes);

        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due, "chunk is due");
        uint256 total = eurc.balanceOf(alice) + Math.mulDiv(cbbtc.balanceOf(alice), PRICE, 1e8);
        assertLe(uint256(delta), total * 1000 / BPS, "chunk larger than maxCorrectionBps of the current value");
        r.execute(alice, keeper);
        (, remaining) = _round(alice);
        assertLe(remaining, total * 1000 / BPS, "remaining budget above the budget of the current value");
    }

    /// @notice Lead 3: a donation during a round does not increase the budget.
    function test_chunk_donationDoesNotGrowRoundBudget() public {
        poolEurcUsdc.setLiquidity(2e12);
        _setUser(alice, 10_000e6, 0, _params(1000, 20e6)); // budget 1,000
        r.execute(alice, keeper);
        eurc.mint(alice, 100_000e6); // donation: value ×11, correction much larger
        uint256 traded = 10_000e6 - (eurc.balanceOf(alice) - 100_000e6);
        for (uint256 i; i < 10; i++) {
            _warp(10 minutes);
            (bool due, int256 delta) = r.isDue(alice);
            if (!due) break;
            r.execute(alice, keeper);
            traded += uint256(delta);
        }
        assertEq(traded, 1000e6, "budget of the round grew with the donation");
    }

    /// @notice After `interval` since the last run a new round starts with a fresh budget, even if an (expired)
    ///         round was still open.
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
        assertGt(fresh, remaining - uint256(delta), "budget not renewed");
        assertEq(fresh + uint256(delta), total, "fresh budget = 100% of the value at this run");
    }

    /// @notice If the round runs to near the band, the estimate (without fee) closes the round as soon as the chunk
    ///         brings the owner within the band; no round stays open.
    function test_chunk_roundEndsWhenRunReachesBand() public {
        poolEurcUsdc.setLiquidity(1e13); // ~1,875 EURC per chunk
        // 7,400 EURC + cbBTC worth 2,600: share 26%, deviation 54% × 10,000 = 5,400.
        _setUser(alice, 7_400e6, 3_250_000, _params(10_000, 20e6));
        for (uint256 i; i < 10; i++) {
            (bool due,) = r.isDue(alice);
            if (!due) break;
            r.execute(alice, keeper);
            (, uint256 remaining) = _round(alice);
            (uint256 fraction,) = _fractionOf(alice);
            if (fraction + 0.05e18 >= 0.8e18) assertEq(remaining, 0, "round stays open within the band");
            _warp(10 minutes);
        }
    }

    function _fractionOf(address user) internal view returns (uint256 fractionWad, uint256 total) {
        uint256 position = Math.mulDiv(cbbtc.balanceOf(user), PRICE, 1e8);
        total = eurc.balanceOf(user) + position;
        fractionWad = total == 0 ? 0 : Math.mulDiv(position, 1e18, total);
    }
}
