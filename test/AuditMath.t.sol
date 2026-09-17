// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Rebalancer} from "../src/Rebalancer.sol";
import {RebalancerTestBase} from "./Rebalancer.t.sol";

/// @notice Fuzz, invariant and PoC tests from the internal audit of 15 September 2026 for the arithmetic of
///         _plan/_buy/_sell/_takeFee, adapted to the rules introduced afterwards (MIN_TRADE_FLOOR 20 EURC,
///         MIN_CORRECTION_BPS 10, MIN_SLIPPAGE_BPS 60, Ceil on wantBtc, post-swap spot check, fee in try).
///         Note: under via_ir Solidity caches `block.timestamp` within a test; so after `vm.warp` always
///         use `vm.getBlockTimestamp()`.
contract AuditMathTest is RebalancerTestBase {
    // ─── helpers ───────────────────────────────────────────────────────────────────────────────────────────

    function _fraction(address user, uint256 price) internal view returns (uint256 fracWad, uint256 total) {
        uint256 cash = eurc.balanceOf(user);
        uint256 position = Math.mulDiv(cbbtc.balanceOf(user), price, 1e8);
        total = cash + position;
        fracWad = total == 0 ? 0 : Math.mulDiv(position, 1e18, total);
    }

    function _absDrift(uint256 fracWad, uint16 targetBps) internal pure returns (uint256) {
        uint256 t = uint256(targetBps) * 1e18 / BPS;
        return fracWad > t ? fracWad - t : t - fracWad;
    }

    // ─── (a) corridor-or-cap, (b) fee exactly 25 bps, (c) no leftovers ─────────────────────────────────────

    /// @dev After one execute: either |drift| <= band, or the run was limited (cap, allowance or minTrade floor),
    ///      or the remaining drift is solely the fee+slippage loss (< 1.25% of the run amount / total).
    ///      Also: fee == exactly 25 bps of the EURC leg, fee covers the reward, every buy yields cbBTC, and
    ///      the contract keeps nothing (except what was already in it by accident before the run).
    function testFuzz_audit_corridorFeeResidue(
        uint256 cash,
        uint256 btc,
        uint16 targetSteps,
        uint16 band,
        uint16 cap,
        uint64 minTrade,
        uint16 slip,
        uint16 routerSlip,
        uint256 price,
        uint256 allowanceEurc,
        uint256 allowanceBtc,
        uint256 donation
    ) public {
        cash = bound(cash, 0, 1e15);
        btc = bound(btc, 0, 1e13);
        price = bound(price, 20_000e6, 200_000e6);
        Rebalancer.Params memory p = Rebalancer.Params({
            active: true,
            targetBps: uint16(bound(targetSteps, 5, 95)) * 100,
            bandBps: uint16(bound(band, 125, 9999)), // MIN_BAND_BPS
            maxCorrectionBps: uint16(bound(cap, 10, 10_000)),
            minTradeEurc: uint64(bound(minTrade, 20e6, 1e9)),
            interval: 1 hours,
            maxSlippageBps: uint16(bound(slip, 60, 100))
        });
        routerSlip = uint16(bound(routerSlip, 0, p.maxSlippageBps));
        donation = bound(donation, 0, 1e9);

        _setPrice(price);
        router.setPrice(price);
        router.setSlippageBps(routerSlip);
        _setUser(alice, cash, btc, p);
        vm.startPrank(alice);
        eurc.approve(address(r), allowanceEurc);
        cbbtc.approve(address(r), allowanceBtc);
        vm.stopPrank();
        // Accidentally left-behind balance: execute must not touch it, and must not add anything to it.
        if (donation > 0) eurc.mint(address(r), donation);

        (bool due, int256 delta) = r.isDue(alice);
        if (!due) return;
        bool isBuy = delta > 0;
        uint256 absDelta = isBuy ? uint256(delta) : uint256(-delta);
        (uint256 fracBefore, uint256 totalBefore) = _fraction(alice, price);
        uint256 capEurc = Math.max(Math.mulDiv(totalBefore, p.maxCorrectionBps, BPS), p.minTradeEurc);
        // Since L-C `delta` is the limited input amount; I recompute the correction itself here.
        uint256 correction = Math.min(Math.mulDiv(_absDrift(fracBefore, p.targetBps), totalBefore, 1e18), capEurc);

        uint256 treasuryBefore = eurc.balanceOf(treasury);
        uint256 keeperBefore = eurc.balanceOf(keeper);
        uint256 routerEurcBefore = eurc.balanceOf(address(router));
        uint256 aliceEurcBefore = eurc.balanceOf(alice);
        uint256 aliceBtcBefore = cbbtc.balanceOf(alice);

        r.execute(alice, keeper);

        // (c) leftovers
        assertEq(eurc.balanceOf(address(r)), donation, "EURC leftover != donation");
        assertEq(cbbtc.balanceOf(address(r)), 0, "cbBTC leftover");
        assertEq(eurc.allowance(address(r), address(router)), 0, "router allowance EURC remains");
        assertEq(cbbtc.allowance(address(r), address(router)), 0, "router allowance cbBTC remains");

        // (b) fee exactly 25 bps of the EURC leg, and never below the reward (apart from sell slippage)
        uint256 feePaid = (eurc.balanceOf(treasury) - treasuryBefore) + (eurc.balanceOf(keeper) - keeperBefore);
        uint256 feeBase;
        uint256 amountInEurcValue;
        if (isBuy) {
            uint256 amountIn = aliceEurcBefore - eurc.balanceOf(alice);
            feeBase = amountIn;
            amountInEurcValue = amountIn;
            assertEq(eurc.balanceOf(address(router)) - routerEurcBefore, amountIn - feePaid, "swapIn != amountIn - fee");
            assertGt(cbbtc.balanceOf(alice) - aliceBtcBefore, 0, "buy yielded 0 cbBTC");
            assertGt(router.lastAmountOutMinimum(), 0, "amountOutMinimum 0");
            assertGe(feePaid, r.KEEPER_REWARD_EURC(), "buy fee below the reward");
        } else {
            uint256 btcIn = aliceBtcBefore - cbbtc.balanceOf(alice);
            uint256 received = Math.mulDiv(Math.mulDiv(btcIn, price, 1e8), BPS - routerSlip, BPS);
            amountInEurcValue = Math.mulDiv(btcIn, price, 1e8);
            // L-B: base is max(received, expected proceeds at the oracle price).
            feeBase = Math.max(received, amountInEurcValue);
            assertEq(eurc.balanceOf(alice) - aliceEurcBefore, received - feePaid, "owner did not get received - fee");
            assertGt(router.lastAmountOutMinimum(), 0, "amountOutMinimum 0");
            assertGe(feePaid, r.KEEPER_REWARD_EURC(), "sell fee below the reward");
            // Ceil on wantBtc: the sold value is at most 1 sat above the correction.
            assertLe(amountInEurcValue, correction + price / 1e8, "sold more than 1 sat above the correction");
        }
        assertEq(absDelta, amountInEurcValue, "isDue delta != actually traded amount (L-C)");
        assertEq(feePaid, Math.mulDiv(feeBase, 25, BPS), "fee != 25 bps");
        assertLe(feePaid, feeBase * 25 / BPS, "fee rounded up");
        assertEq(eurc.balanceOf(keeper) - keeperBefore, Math.min(50_000, feePaid / 2), "reward != min(0.05, fee / 2)");

        // (a) corridor or cap
        (uint256 fracAfter, uint256 totalAfter) = _fraction(alice, price);
        uint256 driftAfter = _absDrift(fracAfter, p.targetBps);
        uint256 bandWad = uint256(p.bandBps) * 1e18 / BPS;
        bool capped = correction == capEurc; // correction is clipped at the cap (or minTrade floor)
        bool clamped = amountInEurcValue + 2 < correction; // allowance/rounding limited the run
        if (!capped && !clamped) {
            // Full correction: the only remaining drift is the loss (fee + slippage) on the run amount.
            // |drift'| <= (fee+slip) * amountIn / total' , well below 1.25% * 1.
            uint256 lossBound = Math.mulDiv(amountInEurcValue, 25 + p.maxSlippageBps, BPS);
            uint256 maxDriftWad = Math.mulDiv(lossBound + 2 + price / 1e8, 1e18, totalAfter) + 1e12;
            assertLe(driftAfter, maxDriftWad, "remaining drift larger than fee+slippage loss");
            if (bandWad >= maxDriftWad) assertLe(driftAfter, bandWad, "full correction ends outside band");
        }

        // Direction: any next run goes the same way (no ping-pong through overshoot).
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _setPrice(price);
        (bool due2, int256 delta2) = r.isDue(alice);
        if (due2) {
            assertEq(delta2 > 0, isBuy, "direction reverses: ping-pong");
        }
    }

    /// @dev Repeated runs at a constant price: the direction never reverses and the series converges (finite).
    function testFuzz_audit_noPingPongConstantPrice(
        uint256 cash,
        uint256 btc,
        uint16 targetSteps,
        uint16 band,
        uint16 cap,
        uint16 routerSlip
    ) public {
        cash = bound(cash, 0, 1e12);
        btc = bound(btc, 0, 1e10);
        Rebalancer.Params memory p = Rebalancer.Params({
            active: true,
            targetBps: uint16(bound(targetSteps, 5, 95)) * 100,
            bandBps: uint16(bound(band, 125, 500)), // MIN_BAND_BPS
            maxCorrectionBps: uint16(bound(cap, 5000, 10_000)), // >= 50% per run: main correction in <= 2 runs, rest is tail
            minTradeEurc: 20e6,
            interval: 1 hours,
            maxSlippageBps: 100
        });
        router.setSlippageBps(bound(routerSlip, 0, 100));
        _setUser(alice, cash, btc, p);

        (bool due, int256 delta) = r.isDue(alice);
        if (!due) return;
        bool dir = delta > 0;
        uint256 runs;
        while (due && runs < 60) {
            assertEq(delta > 0, dir, "direction reversed");
            r.execute(alice, address(0));
            runs++;
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            _setPrice(PRICE);
            (due, delta) = r.isDue(alice);
        }
        assertLt(runs, 60, "does not converge");
    }

    // ─── PoC's ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev Overshoot on sell (I-01): after a full sell the fraction is slightly ABOVE target (same direction).
    ///      With band 1 bps a second, smaller sell used to follow (a tail with fee). Since MIN_BAND_BPS (125 =
    ///      FEE_BPS + MAX_SLIPPAGE_BPS) setParams rejects such a band, and the residual deviation from fee and
    ///      slippage (≤ 1.25% of the run amount, here ≤ 0.25 pt) falls within the smallest allowed band: the
    ///      correction is done in one run. Rewritten from proof-of-tail to proof-of-fix.
    function test_poc_sellOvershootTailRuns() public {
        Rebalancer.Params memory p = _defaultParams();
        p.bandBps = 1;
        vm.prank(alice);
        vm.expectRevert(Rebalancer.InvalidParams.selector);
        r.setParams(p);

        p.bandBps = r.MIN_BAND_BPS();
        p.maxCorrectionBps = 10_000;
        p.interval = 1 hours;
        router.setSlippageBps(100);
        _setUser(alice, 0, 25_000_000, p); // 20,000 EURC in cbBTC, target 80/20
        r.execute(alice, address(0)); // sell 4,000 EURC
        (uint256 frac,) = _fraction(alice, PRICE);
        assertGt(frac, 0.8e18, "overshoot in the same direction");
        assertLt(frac, 0.8e18 + 0.0125e18, "overshoot outside the smallest band");
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _setPrice(PRICE);
        (bool due, int256 delta) = r.isDue(alice);
        assertFalse(due, "tail run despite MIN_BAND_BPS");
        assertEq(delta, 0);
    }

    /// @dev Cadence: allowance < correction -> partial run, lastExecutedAt still moves a full interval ahead.
    function test_poc_partialRunAdvancesCadence() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        vm.prank(alice);
        eurc.approve(address(r), 20e6); // exactly minTrade
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, 20e6, "L-C: delta is the limited run, not the correction of 100 EURC");
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 980e6, "only 20 EURC traded");
        assertEq(r.lastExecutedAt(alice), uint64(START));
        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(alice, keeper); // rest of the 100 EURC must wait a full interval
    }

    /// @dev Liveness (L-2): spot 0.5% above oracle (allowed) + 0.1% pool fees = 0.6%. The old lower bound of
    ///      30 bps can no longer be set; with the new lower bound of 60 bps exactly this run succeeds.
    function test_poc_minSlippageBelowSpotDeviationPlusPoolFees() public {
        Rebalancer.Params memory p = _defaultParams();
        p.maxSlippageBps = 30;
        vm.expectRevert(Rebalancer.InvalidParams.selector);
        vm.prank(alice);
        r.setParams(p);

        p.maxSlippageBps = 60;
        _setUser(alice, 1000e6, 0, p);
        _setSpot(PRICE * (BPS + 50) / BPS); // spot within the 0.5% limit
        (bool due,) = r.isDue(alice);
        assertTrue(due, "spot check lets the run through");
        router.setSlippageBps(60); // 0.5% spot + 0.1% pool fees relative to oracle
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 900e6);
    }

    /// @dev M-6: TREASURY on the EURC blacklist no longer locks the contract. Every run goes through, the
    ///      reward is paid, the treasury share stays in the contract, and sweep collects it later.
    function test_poc_blacklistedTreasuryNoLongerBricksExecute() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        _setUser(bob, 1000e6, 0, _defaultParams());
        eurc.setBlacklisted(treasury, true);
        r.execute(alice, keeper); // fee 0.25 > reward 0.05 -> 0.20 to treasury fails, stays behind
        r.execute(bob, address(0)); // whole fee 0.25 stays behind
        assertEq(eurc.balanceOf(alice), 900e6);
        assertEq(eurc.balanceOf(bob), 900e6);
        assertEq(eurc.balanceOf(keeper), 50_000);
        assertEq(eurc.balanceOf(address(r)), 200_000 + 250_000);
        assertEq(eurc.balanceOf(treasury), 0);

        eurc.setBlacklisted(treasury, false);
        r.sweep(eurc);
        assertEq(eurc.balanceOf(treasury), 450_000);
        assertEq(eurc.balanceOf(address(r)), 0);
    }

    /// @dev L-1: micro-runs with fee 0 and amountOutMinimum 0 can no longer be configured: minTrade < 20 EURC is
    ///      rejected, and an allowance below the floor is NothingToDo instead of a dust run.
    function test_poc_microRunNoLongerPossible() public {
        Rebalancer.Params memory p = _defaultParams();
        p.minTradeEurc = 1;
        vm.expectRevert(Rebalancer.InvalidParams.selector);
        vm.prank(alice);
        r.setParams(p);

        _setUser(alice, 1000e6, 0, _defaultParams());
        vm.prank(alice);
        eurc.approve(address(r), 399);
        (bool due, int256 delta) = r.isDue(alice);
        assertFalse(due);
        assertEq(delta, 0);
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        r.execute(alice, keeper);
        assertEq(r.lastExecutedAt(alice), 0, "cadence not moved");
    }

    /// @dev M-5: if total*maxCorrection < minTrade, then cap = minTrade and correction == minTrade. With a
    ///      non-round price wantBtc is now rounded up, so that the value computed back is >= minTrade
    ///      and small wallets can sell after all. The sold value is at most 1 sat above the correction.
    function test_poc_smallWalletCanSellWithNonRoundPrice() public {
        uint256 price = 80_123_456_789; // realistic feed price: 80,123.456789 EURC per cbBTC
        _setPrice(price);
        router.setPrice(price);
        Rebalancer.Params memory p = _defaultParams(); // minTrade 20 EURC, cap 10%
        uint256 btc = 200_000; // ~160 EURC in cbBTC, 0 EURC: drift 20% -> 32 > cap; cap = max(16, 20) = 20
        _setUser(alice, 0, btc, p);
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due, "sell of 20 EURC is due despite the rounding");
        r.execute(alice, keeper);

        uint256 sold = btc - cbbtc.balanceOf(alice);
        uint256 wantFloor = Math.mulDiv(20e6, 1e8, price); // 24,961: value 19.9996 < 20 -> previously blocked
        assertEq(sold, wantFloor + 1, "rounded up");
        uint256 soldValue = Math.mulDiv(sold, price, 1e8);
        assertEq(delta, -int256(soldValue), "L-C: delta is the value of the sold sats");
        assertGe(soldValue, 20e6);
        assertLe(soldValue, 20e6 + price / 1e8, "at most 1 sat above the correction");

        // Mirror image: buying with the same total/cap works too (amountIn = exactly minTrade).
        _setUser(bob, 160e6, 0, p);
        (due, delta) = r.isDue(bob);
        assertTrue(due);
        assertEq(delta, 20e6);
        r.execute(bob, keeper);
    }

    /// @dev M-5, fuzzed: a sell at the minTrade floor is due whether or not minTrade*1e8 is divisible by the price.
    function testFuzz_poc_sellOnMinTradeFloorAlwaysDue(uint256 price, uint64 minTrade, uint256 btc) public {
        price = bound(price, 20_000e6, 200_000e6);
        minTrade = uint64(bound(minTrade, 20e6, 100e6));
        btc = bound(btc, 1, 1e13);
        Rebalancer.Params memory p = _defaultParams();
        p.minTradeEurc = minTrade;
        p.maxCorrectionBps = 10;
        p.targetBps = 500;
        _setPrice(price);
        router.setPrice(price);
        _setUser(alice, 0, btc, p);
        uint256 total = Math.mulDiv(btc, price, 1e8);
        vm.assume(Math.mulDiv(total, 10, BPS) < minTrade); // cap = minTrade
        vm.assume(Math.mulDiv(total, 9500, BPS) >= minTrade); // drift*total >= minTrade: correction == minTrade
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due, "sell at the floor is always due");
        r.execute(alice, keeper);
        uint256 sold = btc - cbbtc.balanceOf(alice);
        assertEq(sold, Math.mulDiv(minTrade, 1e8, price, Math.Rounding.Ceil));
        assertEq(delta, -int256(Math.mulDiv(sold, price, 1e8)), "L-C: delta is the value of the sold sats");
        assertGe(Math.mulDiv(sold, price, 1e8), minTrade, "sold value below minTrade");
    }

    /// @dev I-02: the cap is per run, not per day: interval 1 hour + cap 10% = up to 24 x 10% per day.
    function test_poc_capIsPerRunNotPerDay() public {
        Rebalancer.Params memory p = _defaultParams();
        p.interval = 1 hours;
        _setUser(alice, 1000e6, 0, p);
        for (uint256 i = 0; i < 5; i++) {
            r.execute(alice, address(0));
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            _setPrice(PRICE);
        }
        assertLt(eurc.balanceOf(alice), 600e6, "> 40% moved within 5 hours");
    }

    /// @dev EX-03: the maximum loss per run relative to the oracle is FEE_BPS + maxSlippageBps. With the spot at the
    ///      edge of the tolerance and the router at the edge of the slippage, the owner still receives exactly that.
    function testFuzz_poc_lossPerRunBoundedByFeePlusSlippage(uint16 slip, uint16 routerSlip, bool up) public {
        Rebalancer.Params memory p = _defaultParams();
        p.maxSlippageBps = uint16(bound(slip, 60, 100));
        routerSlip = uint16(bound(routerSlip, 0, p.maxSlippageBps));
        _setUser(alice, 1000e6, 0, p);
        _setSpot(up ? PRICE * (BPS + 50) / BPS : PRICE * (BPS - 50) / BPS);
        router.setSlippageBps(routerSlip);
        r.execute(alice, keeper);
        uint256 fairSats = Math.mulDiv(100e6, 1e8, PRICE);
        uint256 worstSats = Math.mulDiv(fairSats, BPS - 25 - p.maxSlippageBps, BPS);
        assertGe(cbbtc.balanceOf(alice) + 1, worstSats, "loss above fee + maxSlippage");
    }
}
