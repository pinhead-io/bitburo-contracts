// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Rebalancer} from "../src/Rebalancer.sol";
import {RebalancerTestBase} from "./Rebalancer.t.sol";

/// @notice Audit PoCs and fuzz tests for the arithmetic of _plan/_buy/_sell/_takeFee (scratchpad, not in the repo).
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

    // ─── (a) corridor-or-cap, (b) fee exactly 25 bps, (c) no residue ─────────────────────────────────────────

    /// @dev After one execute: either |drift| <= band, or the run was bounded (cap, allowance or minTrade floor),
    ///      or the remaining drift is only the fee+slippage loss (< 1.25% of the run amount / total).
    ///      Also: fee == exactly 25 bps of the EURC leg, and the contract keeps nothing (except what was already
    ///      in it by accident before the run).
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
            bandBps: uint16(bound(band, 1, 9999)),
            maxCorrectionBps: uint16(bound(cap, 1, 10_000)),
            minTradeEurc: uint64(bound(minTrade, 1e5, 1e9)), // >= 0.1 EURC; microruns: see test_poc_microBuyYieldsZeroOutput
            interval: 1 hours,
            maxSlippageBps: uint16(bound(slip, 30, 100))
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
        // Balance left behind by accident: execute must not touch it, and must not add anything to it.
        if (donation > 0) eurc.mint(address(r), donation);

        (bool due, int256 delta) = r.isDue(alice);
        if (!due) return;
        bool isBuy = delta > 0;
        uint256 absDelta = isBuy ? uint256(delta) : uint256(-delta);
        (, uint256 totalBefore) = _fraction(alice, price);
        uint256 capEurc = Math.max(Math.mulDiv(totalBefore, p.maxCorrectionBps, BPS), p.minTradeEurc);

        uint256 treasuryBefore = eurc.balanceOf(treasury);
        uint256 keeperBefore = eurc.balanceOf(keeper);
        uint256 routerEurcBefore = eurc.balanceOf(address(router));
        uint256 aliceEurcBefore = eurc.balanceOf(alice);
        uint256 aliceBtcBefore = cbbtc.balanceOf(alice);

        r.execute(alice, keeper);

        // (c) residue
        assertEq(eurc.balanceOf(address(r)), donation, "EURC residue != donation");
        assertEq(cbbtc.balanceOf(address(r)), 0, "cbBTC residue");
        assertEq(eurc.allowance(address(r), address(router)), 0, "router allowance EURC remains");
        assertEq(cbbtc.allowance(address(r), address(router)), 0, "router allowance cbBTC remains");

        // (b) fee exactly 25 bps of the EURC leg
        uint256 feePaid = (eurc.balanceOf(treasury) - treasuryBefore) + (eurc.balanceOf(keeper) - keeperBefore);
        uint256 feeBase;
        uint256 amountInEurcValue;
        if (isBuy) {
            uint256 amountIn = aliceEurcBefore - eurc.balanceOf(alice);
            feeBase = amountIn;
            amountInEurcValue = amountIn;
            assertEq(eurc.balanceOf(address(router)) - routerEurcBefore, amountIn - feePaid, "swapIn != amountIn - fee");
        } else {
            uint256 btcIn = aliceBtcBefore - cbbtc.balanceOf(alice);
            uint256 received = Math.mulDiv(Math.mulDiv(btcIn, price, 1e8), BPS - routerSlip, BPS);
            feeBase = received;
            amountInEurcValue = Math.mulDiv(btcIn, price, 1e8);
            assertEq(eurc.balanceOf(alice) - aliceEurcBefore, received - feePaid, "owner did not get received - fee");
        }
        assertEq(feePaid, Math.mulDiv(feeBase, 25, BPS), "fee != 25 bps");
        assertLe(feePaid, feeBase * 25 / BPS, "fee rounded up");
        assertEq(eurc.balanceOf(keeper) - keeperBefore, Math.min(50_000, feePaid), "reward != min(0.05, fee)");

        // (a) corridor or cap
        (uint256 fracAfter, uint256 totalAfter) = _fraction(alice, price);
        uint256 driftAfter = _absDrift(fracAfter, p.targetBps);
        uint256 bandWad = uint256(p.bandBps) * 1e18 / BPS;
        bool capped = absDelta == capEurc; // correction was capped at the cap (or minTrade floor)
        bool clamped = amountInEurcValue + 2 < absDelta; // allowance/rounding limited the run
        if (!capped && !clamped) {
            // Full correction: the only residual drift is the loss (fee + slippage) on the run amount.
            // |drift'| <= (fee+slip) * amountIn / total' , well below 1.25% * 1.
            uint256 lossBound = Math.mulDiv(amountInEurcValue, 25 + p.maxSlippageBps, BPS);
            uint256 maxDriftWad = Math.mulDiv(lossBound + 2, 1e18, totalAfter) + 1e12;
            assertLe(driftAfter, maxDriftWad, "residual drift larger than fee+slippage loss");
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
            bandBps: uint16(bound(band, 1, 500)),
            maxCorrectionBps: uint16(bound(cap, 5000, 10_000)), // >= 50% per run: main correction in <= 2 runs, rest is tail
            minTradeEurc: 1e5, // >= 0.1 EURC: below ~0.0008 EURC a buy yields 0 sats and the series never ends
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

    // ─── PoCs ──────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev Overshoot on a sell: after a full sell the fraction is slightly ABOVE target (same direction),
    ///      and with band 1 bps and minTrade 1 a second, smaller sell follows. No ping-pong, but a tail.
    function test_poc_sellOvershootTailRuns() public {
        Rebalancer.Params memory p = _defaultParams();
        p.bandBps = 1;
        p.maxCorrectionBps = 10_000;
        p.minTradeEurc = 1;
        p.interval = 1 hours;
        router.setSlippageBps(100);
        _setUser(alice, 0, 1_250_000, p); // 1000 EURC in cbBTC, target 80/20
        r.execute(alice, address(0)); // sell 200 EURC
        (uint256 frac,) = _fraction(alice, PRICE);
        emit log_named_uint("fraction after run 1 (wad)", frac); // > 0.80e18
        assertGt(frac, 0.8e18);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _setPrice(PRICE);
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertLt(delta, 0, "second run is also a sell");
        emit log_named_int("run 2 delta", delta); // ~ -2 EURC
        r.execute(alice, address(0));
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _setPrice(PRICE);
        (due, delta) = r.isDue(alice);
        emit log_named_int("run 3 delta", delta);
    }

    /// @dev Cadence: allowance < correction -> partial run, yet lastExecutedAt moves a full interval forward.
    function test_poc_partialRunAdvancesCadence() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        vm.prank(alice);
        eurc.approve(address(r), 5e6); // exactly minTrade
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, 100e6);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 995e6, "only 5 EURC traded");
        assertEq(r.lastExecutedAt(alice), uint64(START));
        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(alice, keeper); // rest of the 100 EURC has to wait a full interval
    }

    /// @dev Liveness: spot 0.5% below oracle (allowed) + 0.1% pool fees > maxSlippage 0.3% -> every run reverts.
    function test_poc_minSlippageBelowSpotDeviationPlusPoolFees() public {
        Rebalancer.Params memory p = _defaultParams();
        p.maxSlippageBps = 30;
        _setUser(alice, 1000e6, 0, p);
        _setSpot(PRICE * (BPS + 50) / BPS); // spot within the 0.5% limit
        (bool due,) = r.isDue(alice);
        assertTrue(due, "spot check lets the run through");
        router.setSlippageBps(60); // 0.5% spot + 0.1% pool fees relative to oracle
        vm.expectRevert("Too little received");
        r.execute(alice, keeper);
    }

    /// @dev DoS: TREASURY on the EURC blacklist -> every run with a fee remainder to treasury reverts; no admin to
    ///      switch it. sweep(EURC) fails too.
    function test_poc_blacklistedTreasuryBricksExecute() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        eurc.setBlacklisted(treasury, true);
        vm.expectRevert("Blacklistable: account is blacklisted");
        r.execute(alice, keeper); // fee 0.25 > reward 0.05 -> transfer to treasury
        vm.expectRevert("Blacklistable: account is blacklisted");
        r.execute(alice, address(0));
        // Only mini runs (fee <= 0.05 EURC, amountIn <= 200 EURC) with rewardTo != 0 still succeed.
        _setUser(bob, 100e6, 0, _defaultParams());
        r.execute(bob, keeper);
        assertEq(eurc.balanceOf(keeper), 25_000);
    }

    /// @dev Fee 0 and amountOutMinimum 0 on microruns: minTrade=1 and allowance=1 -> run "succeeds", keeper gets 0.
    function test_poc_microRunZeroFeeZeroMinOut() public {
        Rebalancer.Params memory p = _defaultParams();
        p.minTradeEurc = 1;
        _setUser(alice, 1000e6, 0, p);
        vm.prank(alice);
        eurc.approve(address(r), 399); // fee = 399*25/10000 = 0
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, 100e6);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(keeper), 0, "keeper gets nothing");
        assertEq(eurc.balanceOf(treasury), 0);
        assertEq(router.lastAmountOutMinimum(), 0, "amountOutMinimum 0");
        assertEq(r.lastExecutedAt(alice), uint64(START), "cadence moved forward anyway");
    }

    /// @dev Structural: if total*maxCorrection < minTrade, then cap = minTrade and correction == minTrade.
    ///      On a sell wantBtc is rounded down, so the value is < minTrade and amountIn = 0,
    ///      unless minTrade*1e8 is exactly divisible by the price. Small wallets therefore cannot sell.
    function test_poc_smallWalletCannotSell() public {
        uint256 price = 80_123_456_789; // realistic feed price: 80,123.456789 EURC per cbBTC
        _setPrice(price);
        router.setPrice(price);
        Rebalancer.Params memory p = _defaultParams(); // minTrade 5 EURC, cap 10%
        uint256 btc = 50_000; // ~40 EURC in cbBTC, 0 EURC: drift 20%, total 40 -> cap 4 < 5 -> cap = 5
        _setUser(alice, 0, btc, p);
        (bool due, int256 delta) = r.isDue(alice);
        assertFalse(due, "sell of 5 EURC is blocked by rounding");
        assertEq(delta, 0);
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        r.execute(alice, keeper);

        // Mirror image: buying with the same total/cap does work (amountIn = exactly minTrade).
        _setUser(bob, 40e6, 0, p);
        (due, delta) = r.isDue(bob);
        assertTrue(due);
        assertEq(delta, 5e6);
        r.execute(bob, keeper);

        // At a price that divides exactly (80,000.000000) the sell does succeed: purely a rounding artefact.
        _setPrice(80_000e6);
        router.setPrice(80_000e6);
        (due,) = r.isDue(alice);
        assertTrue(due, "due with an exactly dividing price");
    }

    /// @dev Same artefact for larger wallets when cap - minTrade < 1 sat of value (up to ~800 EURC units).
    function testFuzz_poc_sellBlockedWhenCapEqualsMinTrade(uint256 price, uint64 minTrade, uint256 btc) public {
        price = bound(price, 20_000e6, 200_000e6);
        minTrade = uint64(bound(minTrade, 1e6, 100e6));
        btc = bound(btc, 1, 1e13);
        Rebalancer.Params memory p = _defaultParams();
        p.minTradeEurc = minTrade;
        p.maxCorrectionBps = 1;
        p.targetBps = 500;
        _setPrice(price);
        router.setPrice(price);
        _setUser(alice, 0, btc, p);
        uint256 total = Math.mulDiv(btc, price, 1e8);
        vm.assume(Math.mulDiv(total, 1, BPS) < minTrade); // cap = minTrade
        vm.assume(Math.mulDiv(total, 9500, BPS) >= minTrade); // drift*total >= minTrade: correction == minTrade
        (bool due,) = r.isDue(alice);
        bool exact = (uint256(minTrade) * 1e8) % price == 0;
        assertEq(due, exact, "sell is only due if minTrade fits exactly in sats");
    }

    /// @dev Micro buy: swapIn < 1 sat of value -> expectedOut 0 -> amountOutMinimum 0 -> owner pays EURC
    ///      and receives 0 cbBTC (fuzz counterexample: cash 5866, target 10%, minTrade 6).
    function test_poc_microBuyYieldsZeroOutput() public {
        Rebalancer.Params memory p = _defaultParams();
        p.targetBps = 1000;
        p.minTradeEurc = 6;
        p.maxCorrectionBps = 10_000;
        _setUser(alice, 5866, 0, p);
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, 586);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 5866 - 586, "EURC paid");
        assertEq(cbbtc.balanceOf(alice), 0, "0 cbBTC received");
        assertEq(router.lastAmountOutMinimum(), 0);
    }

    /// @dev Drain loop: minTrade=1 and dust cash: every run takes cap% EURC, returns 0 sats, fraction stays 0,
    ///      so the next run is due again. Fuzz counterexample from testFuzz_audit_noPingPongConstantPrice.
    function test_poc_dustBuyLoopNeverConverges() public {
        Rebalancer.Params memory p = _defaultParams();
        p.minTradeEurc = 1;
        p.targetBps = 600; // 6%: every buy < 1 sat -> 0 output; at 80% the first run happens to yield 1 sat
        p.maxCorrectionBps = 5000;
        p.interval = 1 hours;
        _setUser(alice, 2067, 0, p);
        uint256 runs;
        (bool due,) = r.isDue(alice);
        while (due && runs < 20) {
            r.execute(alice, address(0));
            runs++;
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            _setPrice(PRICE);
            (due,) = r.isDue(alice);
        }
        assertEq(runs, 20, "stays due");
        assertEq(cbbtc.balanceOf(alice), 0, "never received anything");
        assertLt(eurc.balanceOf(alice), 2067, "but lost EURC");
        emit log_named_uint("EURC left after 20 runs", eurc.balanceOf(alice));
    }

    /// @dev The cap is per run, not per day: interval 1 hour + cap 10% = up to 24 x 10% per day.
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
}
