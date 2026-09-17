// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Rebalancer} from "../src/Rebalancer.sol";
import {RebalancerTestBase} from "./Rebalancer.t.sol";

/// @notice Fuzz-, invariant- en PoC-tests uit de interne audit van 15 september 2026 voor de rekenkunde van
///         _plan/_buy/_sell/_takeFee, aangepast aan de daarna ingevoerde regels (MIN_TRADE_FLOOR 20 EURC,
///         MIN_CORRECTION_BPS 10, MIN_SLIPPAGE_BPS 60, Ceil op wantBtc, post-swap-spotcheck, fee in try).
///         Let op: onder via_ir cachet Solidity `block.timestamp` binnen een test; na `vm.warp` daarom altijd
///         `vm.getBlockTimestamp()` gebruiken.
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

    // ─── (a) corridor-of-cap, (b) fee exact 25 bps, (c) geen restanten ─────────────────────────────────────

    /// @dev Na één execute geldt: óf |drift| <= band, óf de run was begrensd (cap, allowance of minTrade-vloer),
    ///      óf de resterende drift is uitsluitend het fee+slippage-verlies (< 1,25% van het run-bedrag / total).
    ///      Verder: fee == exact 25 bps van het EURC-been, fee dekt de beloning, elke koop levert cbBTC op, en
    ///      het contract houdt niets over (behalve wat er vóór de run al per ongeluk in zat).
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
        // Per ongeluk achtergebleven saldo: execute mag dat niet aanraken, en mag er niets bij laten komen.
        if (donation > 0) eurc.mint(address(r), donation);

        (bool due, int256 delta) = r.isDue(alice);
        if (!due) return;
        bool isBuy = delta > 0;
        uint256 absDelta = isBuy ? uint256(delta) : uint256(-delta);
        (uint256 fracBefore, uint256 totalBefore) = _fraction(alice, price);
        uint256 capEurc = Math.max(Math.mulDiv(totalBefore, p.maxCorrectionBps, BPS), p.minTradeEurc);
        // Sinds L-C is `delta` het begrensde inputbedrag; de correctie zelf reken ik hier na.
        uint256 correction = Math.min(Math.mulDiv(_absDrift(fracBefore, p.targetBps), totalBefore, 1e18), capEurc);

        uint256 treasuryBefore = eurc.balanceOf(treasury);
        uint256 keeperBefore = eurc.balanceOf(keeper);
        uint256 routerEurcBefore = eurc.balanceOf(address(router));
        uint256 aliceEurcBefore = eurc.balanceOf(alice);
        uint256 aliceBtcBefore = cbbtc.balanceOf(alice);

        r.execute(alice, keeper);

        // (c) restanten
        assertEq(eurc.balanceOf(address(r)), donation, "EURC-restant != donatie");
        assertEq(cbbtc.balanceOf(address(r)), 0, "cbBTC-restant");
        assertEq(eurc.allowance(address(r), address(router)), 0, "router-allowance EURC blijft staan");
        assertEq(cbbtc.allowance(address(r), address(router)), 0, "router-allowance cbBTC blijft staan");

        // (b) fee exact 25 bps van het EURC-been, en nooit onder de beloning (op verkoop-slippage na)
        uint256 feePaid = (eurc.balanceOf(treasury) - treasuryBefore) + (eurc.balanceOf(keeper) - keeperBefore);
        uint256 feeBase;
        uint256 amountInEurcValue;
        if (isBuy) {
            uint256 amountIn = aliceEurcBefore - eurc.balanceOf(alice);
            feeBase = amountIn;
            amountInEurcValue = amountIn;
            assertEq(eurc.balanceOf(address(router)) - routerEurcBefore, amountIn - feePaid, "swapIn != amountIn - fee");
            assertGt(cbbtc.balanceOf(alice) - aliceBtcBefore, 0, "koop leverde 0 cbBTC op");
            assertGt(router.lastAmountOutMinimum(), 0, "amountOutMinimum 0");
            assertGe(feePaid, r.KEEPER_REWARD_EURC(), "koop-fee onder de beloning");
        } else {
            uint256 btcIn = aliceBtcBefore - cbbtc.balanceOf(alice);
            uint256 received = Math.mulDiv(Math.mulDiv(btcIn, price, 1e8), BPS - routerSlip, BPS);
            amountInEurcValue = Math.mulDiv(btcIn, price, 1e8);
            // L-B: grondslag is max(ontvangen, verwachte opbrengst tegen de oracle).
            feeBase = Math.max(received, amountInEurcValue);
            assertEq(eurc.balanceOf(alice) - aliceEurcBefore, received - feePaid, "owner kreeg niet received - fee");
            assertGt(router.lastAmountOutMinimum(), 0, "amountOutMinimum 0");
            assertGe(feePaid, r.KEEPER_REWARD_EURC(), "verkoop-fee onder de beloning");
            // Ceil op wantBtc: de verkochte waarde ligt hooguit 1 sat boven de correctie.
            assertLe(amountInEurcValue, correction + price / 1e8, "meer dan 1 sat boven de correctie verkocht");
        }
        assertEq(absDelta, amountInEurcValue, "isDue-delta != werkelijk verhandeld bedrag (L-C)");
        assertEq(feePaid, Math.mulDiv(feeBase, 25, BPS), "fee != 25 bps");
        assertLe(feePaid, feeBase * 25 / BPS, "fee naar boven afgerond");
        assertEq(eurc.balanceOf(keeper) - keeperBefore, Math.min(50_000, feePaid / 2), "reward != min(0,05, fee / 2)");

        // (a) corridor of cap
        (uint256 fracAfter, uint256 totalAfter) = _fraction(alice, price);
        uint256 driftAfter = _absDrift(fracAfter, p.targetBps);
        uint256 bandWad = uint256(p.bandBps) * 1e18 / BPS;
        bool capped = correction == capEurc; // correctie is afgekapt op de cap (of minTrade-vloer)
        bool clamped = amountInEurcValue + 2 < correction; // allowance/afronding beperkte de run
        if (!capped && !clamped) {
            // Volledige correctie: enige restdrift is het verlies (fee + slippage) op het run-bedrag.
            // |drift'| <= (fee+slip) * amountIn / total' , ruim onder 1,25% * 1.
            uint256 lossBound = Math.mulDiv(amountInEurcValue, 25 + p.maxSlippageBps, BPS);
            uint256 maxDriftWad = Math.mulDiv(lossBound + 2 + price / 1e8, 1e18, totalAfter) + 1e12;
            assertLe(driftAfter, maxDriftWad, "restdrift groter dan fee+slippage-verlies");
            if (bandWad >= maxDriftWad) assertLe(driftAfter, bandWad, "volledige correctie eindigt buiten band");
        }

        // Richting: een eventuele volgende run gaat dezelfde kant op (geen ping-pong door overshoot).
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _setPrice(price);
        (bool due2, int256 delta2) = r.isDue(alice);
        if (due2) {
            assertEq(delta2 > 0, isBuy, "richting keert om: ping-pong");
        }
    }

    /// @dev Herhaalde runs bij constante koers: de richting keert nooit om en de reeks convergeert (eindig).
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
            maxCorrectionBps: uint16(bound(cap, 5000, 10_000)), // >= 50% per run: hoofdcorrectie in <= 2 runs, rest is staart
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
            assertEq(delta > 0, dir, "richting keerde om");
            r.execute(alice, address(0));
            runs++;
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            _setPrice(PRICE);
            (due, delta) = r.isDue(alice);
        }
        assertLt(runs, 60, "convergeert niet");
    }

    // ─── PoC's ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev Overshoot bij verkoop (I-01): na een volledige sell ligt de fractie iets BOVEN target (zelfde richting).
    ///      Met band 1 bps volgde vroeger een tweede, kleinere sell (een staart met fee). Sinds MIN_BAND_BPS (125 =
    ///      FEE_BPS + MAX_SLIPPAGE_BPS) weigert setParams zo'n band, en valt de restafwijking door fee en slippage
    ///      (≤ 1,25% van het runbedrag, hier ≤ 0,25 pt) binnen de kleinste toegestane band: de correctie is in één run
    ///      klaar. Omgeschreven van bewijs-van-staart naar bewijs-van-fix.
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
        _setUser(alice, 0, 25_000_000, p); // 20.000 EURC in cbBTC, target 80/20
        r.execute(alice, address(0)); // verkoop 4.000 EURC
        (uint256 frac,) = _fraction(alice, PRICE);
        assertGt(frac, 0.8e18, "overshoot in dezelfde richting");
        assertLt(frac, 0.8e18 + 0.0125e18, "overshoot buiten de kleinste band");
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _setPrice(PRICE);
        (bool due, int256 delta) = r.isDue(alice);
        assertFalse(due, "staart-run ondanks MIN_BAND_BPS");
        assertEq(delta, 0);
    }

    /// @dev Cadans: allowance < correctie -> deel-run, lastExecutedAt schuift toch een volledig interval op.
    function test_poc_partialRunAdvancesCadence() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        vm.prank(alice);
        eurc.approve(address(r), 20e6); // precies minTrade
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, 20e6, "L-C: delta is de begrensde run, niet de correctie van 100 EURC");
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 980e6, "slechts 20 EURC verhandeld");
        assertEq(r.lastExecutedAt(alice), uint64(START));
        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(alice, keeper); // rest van de 100 EURC moet een vol interval wachten
    }

    /// @dev Liveness (L-2): spot 0,5% boven oracle (toegestaan) + 0,1% poolfees = 0,6%. De oude ondergrens van
    ///      30 bps is niet meer te zetten; met de nieuwe ondergrens van 60 bps slaagt precies deze run.
    function test_poc_minSlippageBelowSpotDeviationPlusPoolFees() public {
        Rebalancer.Params memory p = _defaultParams();
        p.maxSlippageBps = 30;
        vm.expectRevert(Rebalancer.InvalidParams.selector);
        vm.prank(alice);
        r.setParams(p);

        p.maxSlippageBps = 60;
        _setUser(alice, 1000e6, 0, p);
        _setSpot(PRICE * (BPS + 50) / BPS); // spot binnen de 0,5%-grens
        (bool due,) = r.isDue(alice);
        assertTrue(due, "spot-check laat de run door");
        router.setSlippageBps(60); // 0,5% spot + 0,1% poolfees t.o.v. oracle
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 900e6);
    }

    /// @dev M-6: TREASURY op de EURC-blacklist zet het contract niet meer op slot. Elke run gaat door, de
    ///      beloning wordt betaald, het treasury-deel blijft in het contract, en sweep haalt het later op.
    function test_poc_blacklistedTreasuryNoLongerBricksExecute() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        _setUser(bob, 1000e6, 0, _defaultParams());
        eurc.setBlacklisted(treasury, true);
        r.execute(alice, keeper); // fee 0,25 > reward 0,05 -> 0,20 naar treasury faalt, blijft achter
        r.execute(bob, address(0)); // hele fee 0,25 blijft achter
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

    /// @dev L-1: microruns met fee 0 en amountOutMinimum 0 zijn niet meer te configureren: minTrade < 20 EURC wordt
    ///      geweigerd, en een allowance onder de vloer is NothingToDo in plaats van een dust-run.
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
        assertEq(r.lastExecutedAt(alice), 0, "cadans niet opgeschoven");
    }

    /// @dev M-5: is total*maxCorrection < minTrade, dan is cap = minTrade en correction == minTrade. Met een
    ///      niet-rond koersgetal wordt wantBtc nu naar boven afgerond, zodat de teruggerekende waarde >= minTrade is
    ///      en kleine wallets wél kunnen verkopen. De verkochte waarde ligt hooguit 1 sat boven de correctie.
    function test_poc_smallWalletCanSellWithNonRoundPrice() public {
        uint256 price = 80_123_456_789; // realistische feedkoers: 80.123,456789 EURC per cbBTC
        _setPrice(price);
        router.setPrice(price);
        Rebalancer.Params memory p = _defaultParams(); // minTrade 20 EURC, cap 10%
        uint256 btc = 200_000; // ~160 EURC in cbBTC, 0 EURC: drift 20% -> 32 > cap; cap = max(16, 20) = 20
        _setUser(alice, 0, btc, p);
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due, "verkoop van 20 EURC is due ondanks de afronding");
        r.execute(alice, keeper);

        uint256 sold = btc - cbbtc.balanceOf(alice);
        uint256 wantFloor = Math.mulDiv(20e6, 1e8, price); // 24.961: waarde 19,9996 < 20 -> vroeger geblokkeerd
        assertEq(sold, wantFloor + 1, "naar boven afgerond");
        uint256 soldValue = Math.mulDiv(sold, price, 1e8);
        assertEq(delta, -int256(soldValue), "L-C: delta is de waarde van de verkochte sats");
        assertGe(soldValue, 20e6);
        assertLe(soldValue, 20e6 + price / 1e8, "hooguit 1 sat boven de correctie");

        // Spiegelbeeld: kopen met dezelfde total/cap werkt ook (amountIn = exact minTrade).
        _setUser(bob, 160e6, 0, p);
        (due, delta) = r.isDue(bob);
        assertTrue(due);
        assertEq(delta, 20e6);
        r.execute(bob, keeper);
    }

    /// @dev M-5, gefuzzt: verkoop op de minTrade-vloer is due ongeacht of minTrade*1e8 deelbaar is door de koers.
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
        assertTrue(due, "verkoop op de vloer is altijd due");
        r.execute(alice, keeper);
        uint256 sold = btc - cbbtc.balanceOf(alice);
        assertEq(sold, Math.mulDiv(minTrade, 1e8, price, Math.Rounding.Ceil));
        assertEq(delta, -int256(Math.mulDiv(sold, price, 1e8)), "L-C: delta is de waarde van de verkochte sats");
        assertGe(Math.mulDiv(sold, price, 1e8), minTrade, "verkochte waarde onder minTrade");
    }

    /// @dev I-02: de cap is per run, niet per dag: interval 1 uur + cap 10% = tot 24 x 10% per dag.
    function test_poc_capIsPerRunNotPerDay() public {
        Rebalancer.Params memory p = _defaultParams();
        p.interval = 1 hours;
        _setUser(alice, 1000e6, 0, p);
        for (uint256 i = 0; i < 5; i++) {
            r.execute(alice, address(0));
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            _setPrice(PRICE);
        }
        assertLt(eurc.balanceOf(alice), 600e6, "binnen 5 uur > 40% verplaatst");
    }

    /// @dev EX-03: het maximale verlies per run t.o.v. de oracle is FEE_BPS + maxSlippageBps. Met de spot op de
    ///      rand van de tolerantie en de router op de rand van de slippage ontvangt de owner nog precies dat.
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
        assertGe(cbbtc.balanceOf(alice) + 1, worstSats, "verlies boven fee + maxSlippage");
    }
}
