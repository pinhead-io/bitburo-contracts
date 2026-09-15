// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Rebalancer} from "../src/Rebalancer.sol";
import {RebalancerTestBase} from "./Rebalancer.t.sol";

/// @notice Audit-PoC's en fuzz-tests voor de rekenkunde van _plan/_buy/_sell/_takeFee (scratchpad, niet in de repo).
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
    ///      Verder: fee == exact 25 bps van het EURC-been, en het contract houdt niets over (behalve wat er vóór
    ///      de run al per ongeluk in zat).
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
            minTradeEurc: uint64(bound(minTrade, 1e5, 1e9)), // >= 0,1 EURC; microruns apart in test_poc_microBuyYieldsZeroOutput
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
        // Per ongeluk achtergebleven saldo: execute mag dat niet aanraken, en mag er niets bij laten komen.
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

        // (c) restanten
        assertEq(eurc.balanceOf(address(r)), donation, "EURC-restant != donatie");
        assertEq(cbbtc.balanceOf(address(r)), 0, "cbBTC-restant");
        assertEq(eurc.allowance(address(r), address(router)), 0, "router-allowance EURC blijft staan");
        assertEq(cbbtc.allowance(address(r), address(router)), 0, "router-allowance cbBTC blijft staan");

        // (b) fee exact 25 bps van het EURC-been
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
            assertEq(eurc.balanceOf(alice) - aliceEurcBefore, received - feePaid, "owner kreeg niet received - fee");
        }
        assertEq(feePaid, Math.mulDiv(feeBase, 25, BPS), "fee != 25 bps");
        assertLe(feePaid, feeBase * 25 / BPS, "fee naar boven afgerond");
        assertEq(eurc.balanceOf(keeper) - keeperBefore, Math.min(50_000, feePaid), "reward != min(0,05, fee)");

        // (a) corridor of cap
        (uint256 fracAfter, uint256 totalAfter) = _fraction(alice, price);
        uint256 driftAfter = _absDrift(fracAfter, p.targetBps);
        uint256 bandWad = uint256(p.bandBps) * 1e18 / BPS;
        bool capped = absDelta == capEurc; // correctie is afgekapt op de cap (of minTrade-vloer)
        bool clamped = amountInEurcValue + 2 < absDelta; // allowance/afronding beperkte de run
        if (!capped && !clamped) {
            // Volledige correctie: enige restdrift is het verlies (fee + slippage) op het run-bedrag.
            // |drift'| <= (fee+slip) * amountIn / total' , ruim onder 1,25% * 1.
            uint256 lossBound = Math.mulDiv(amountInEurcValue, 25 + p.maxSlippageBps, BPS);
            uint256 maxDriftWad = Math.mulDiv(lossBound + 2, 1e18, totalAfter) + 1e12;
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
            bandBps: uint16(bound(band, 1, 500)),
            maxCorrectionBps: uint16(bound(cap, 5000, 10_000)), // >= 50% per run: hoofdcorrectie in <= 2 runs, rest is staart
            minTradeEurc: 1e5, // >= 0,1 EURC: onder ~0,0008 EURC levert een koop 0 sats op en de reeks eindigt nooit
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

    /// @dev Overshoot bij verkoop: na een volledige sell ligt de fractie iets BOVEN target (zelfde richting),
    ///      en met band 1 bps en minTrade 1 volgt een tweede, kleinere sell. Geen ping-pong, wel een staart.
    function test_poc_sellOvershootTailRuns() public {
        Rebalancer.Params memory p = _defaultParams();
        p.bandBps = 1;
        p.maxCorrectionBps = 10_000;
        p.minTradeEurc = 1;
        p.interval = 1 hours;
        router.setSlippageBps(100);
        _setUser(alice, 0, 1_250_000, p); // 1000 EURC in cbBTC, target 80/20
        r.execute(alice, address(0)); // verkoop 200 EURC
        (uint256 frac,) = _fraction(alice, PRICE);
        emit log_named_uint("fractie na run 1 (wad)", frac); // > 0.80e18
        assertGt(frac, 0.8e18);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _setPrice(PRICE);
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertLt(delta, 0, "tweede run is ook een verkoop");
        emit log_named_int("run 2 delta", delta); // ~ -2 EURC
        r.execute(alice, address(0));
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _setPrice(PRICE);
        (due, delta) = r.isDue(alice);
        emit log_named_int("run 3 delta", delta);
    }

    /// @dev Cadans: allowance < correctie -> deel-run, lastExecutedAt schuift toch een volledig interval op.
    function test_poc_partialRunAdvancesCadence() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        vm.prank(alice);
        eurc.approve(address(r), 5e6); // precies minTrade
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, 100e6);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 995e6, "slechts 5 EURC verhandeld");
        assertEq(r.lastExecutedAt(alice), uint64(START));
        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(alice, keeper); // rest van de 100 EURC moet een vol interval wachten
    }

    /// @dev Liveness: spot 0,5% onder oracle (toegestaan) + 0,1% poolfees > maxSlippage 0,3% -> elke run revert.
    function test_poc_minSlippageBelowSpotDeviationPlusPoolFees() public {
        Rebalancer.Params memory p = _defaultParams();
        p.maxSlippageBps = 30;
        _setUser(alice, 1000e6, 0, p);
        _setSpot(PRICE * (BPS + 50) / BPS); // spot binnen de 0,5%-grens
        (bool due,) = r.isDue(alice);
        assertTrue(due, "spot-check laat de run door");
        router.setSlippageBps(60); // 0,5% spot + 0,1% poolfees t.o.v. oracle
        vm.expectRevert("Too little received");
        r.execute(alice, keeper);
    }

    /// @dev DoS: TREASURY op de EURC-blacklist -> elke run met fee-restant naar treasury revert; geen admin om te
    ///      wisselen. Ook sweep(EURC) faalt.
    function test_poc_blacklistedTreasuryBricksExecute() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        eurc.setBlacklisted(treasury, true);
        vm.expectRevert("Blacklistable: account is blacklisted");
        r.execute(alice, keeper); // fee 0,25 > reward 0,05 -> transfer naar treasury
        vm.expectRevert("Blacklistable: account is blacklisted");
        r.execute(alice, address(0));
        // Alleen mini-runs (fee <= 0,05 EURC, amountIn <= 200 EURC) met rewardTo != 0 lukken nog.
        _setUser(bob, 100e6, 0, _defaultParams());
        r.execute(bob, keeper);
        assertEq(eurc.balanceOf(keeper), 25_000);
    }

    /// @dev Fee 0 en amountOutMinimum 0 bij microruns: minTrade=1 en allowance=1 -> run "slaagt", keeper krijgt 0.
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
        assertEq(eurc.balanceOf(keeper), 0, "keeper krijgt niets");
        assertEq(eurc.balanceOf(treasury), 0);
        assertEq(router.lastAmountOutMinimum(), 0, "amountOutMinimum 0");
        assertEq(r.lastExecutedAt(alice), uint64(START), "cadans toch opgeschoven");
    }

    /// @dev Structureel: is total*maxCorrection < minTrade, dan wordt cap = minTrade en correction == minTrade.
    ///      Bij verkoop wordt wantBtc naar beneden afgerond, waardoor de waarde < minTrade is en amountIn = 0,
    ///      tenzij minTrade*1e8 exact deelbaar is door de koers. Kleine wallets kunnen dus niet verkopen.
    function test_poc_smallWalletCannotSell() public {
        uint256 price = 80_123_456_789; // realistische feedkoers: 80.123,456789 EURC per cbBTC
        _setPrice(price);
        router.setPrice(price);
        Rebalancer.Params memory p = _defaultParams(); // minTrade 5 EURC, cap 10%
        uint256 btc = 50_000; // ~40 EURC in cbBTC, 0 EURC: drift 20%, total 40 -> cap 4 < 5 -> cap = 5
        _setUser(alice, 0, btc, p);
        (bool due, int256 delta) = r.isDue(alice);
        assertFalse(due, "verkoop van 5 EURC wordt door afronding geblokkeerd");
        assertEq(delta, 0);
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        r.execute(alice, keeper);

        // Spiegelbeeld: kopen met dezelfde total/cap werkt wel (amountIn = exact minTrade).
        _setUser(bob, 40e6, 0, p);
        (due, delta) = r.isDue(bob);
        assertTrue(due);
        assertEq(delta, 5e6);
        r.execute(bob, keeper);

        // Bij een koers die exact deelt (80.000,000000) lukt de verkoop wel: puur een afrondingsartefact.
        _setPrice(80_000e6);
        router.setPrice(80_000e6);
        (due,) = r.isDue(alice);
        assertTrue(due, "met exact delende koers wel due");
    }

    /// @dev Zelfde artefact bij grotere wallets als cap - minTrade < 1 sat aan waarde (tot ~800 EURC-units).
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
        assertEq(due, exact, "verkoop is alleen due als minTrade exact in sats past");
    }

    /// @dev Microkoop: swapIn < 1 sat aan waarde -> expectedOut 0 -> amountOutMinimum 0 -> owner betaalt EURC
    ///      en ontvangt 0 cbBTC (fuzz-tegenvoorbeeld: cash 5866, target 10%, minTrade 6).
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
        assertEq(eurc.balanceOf(alice), 5866 - 586, "EURC betaald");
        assertEq(cbbtc.balanceOf(alice), 0, "0 cbBTC ontvangen");
        assertEq(router.lastAmountOutMinimum(), 0);
    }

    /// @dev Drain-lus: minTrade=1 en dust-cash: elke run trekt cap% EURC af, geeft 0 sats terug, fractie blijft 0,
    ///      dus de volgende run is weer due. Fuzz-tegenvoorbeeld uit testFuzz_audit_noPingPongConstantPrice.
    function test_poc_dustBuyLoopNeverConverges() public {
        Rebalancer.Params memory p = _defaultParams();
        p.minTradeEurc = 1;
        p.targetBps = 600; // 6%: elke koop < 1 sat -> 0 output; bij 80% levert de eerste run toevallig 1 sat op
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
        assertEq(runs, 20, "blijft due");
        assertEq(cbbtc.balanceOf(alice), 0, "nooit iets ontvangen");
        assertLt(eurc.balanceOf(alice), 2067, "wel EURC kwijt");
        emit log_named_uint("EURC over na 20 runs", eurc.balanceOf(alice));
    }

    /// @dev De cap is per run, niet per dag: interval 1 uur + cap 10% = tot 24 x 10% per dag.
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
}
