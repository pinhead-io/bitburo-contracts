// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RebalancerTestBase} from "./Rebalancer.t.sol";
import {Rebalancer} from "../src/Rebalancer.sol";

/// @notice Regressietests op het CRE-ontvangstoppervlak (`onReport`), afkomstig uit de interne audit van
///         15 september 2026 (`audit/2026-09-15/poc/CrePoC.t.sol`). De CRE-workflow zelf is verwijderd, maar
///         `onReport`, `FORWARDER` en `WORKFLOW_OWNER` zitten onveranderbaar in het uitgerolde contract.
contract CrePoC is RebalancerTestBase {
    function _meta(bytes32 wfId, address wfOwner) internal pure returns (bytes memory) {
        // 64 bytes, zoals KeystoneForwarder rawReport[45:109] aanlevert
        return abi.encodePacked(wfId, bytes10("whatever"), wfOwner, bytes2(0x0001));
    }

    /// @dev Was PoC-1: vijf sybils met stof-params (band 1 bps, cap 1 bps, minTrade 1) registreerden eerst,
    ///      bezetten elk uur alle vijf rapportplekken en lieten de zesde owner voorgoed wachten, voor een fee
    ///      die de gaskosten niet dekte. De verharding legde economische ondergrenzen onder `setParams`
    ///      (audit L-1 en M-2), waarmee die opzet niet meer te registreren valt: elke run moet minstens
    ///      `MIN_TRADE_FLOOR` verplaatsen en betaalt daar 25 bps fee over.
    function test_dustSybilCannotOccupyTheReport() public {
        Rebalancer.Params memory dust = Rebalancer.Params({
            active: true,
            targetBps: 8000,
            bandBps: 1,
            maxCorrectionBps: 1,
            minTradeEurc: 1,
            interval: 1 hours,
            maxSlippageBps: 100
        });

        address sybil = makeAddr("sybil");
        vm.prank(sybil);
        vm.expectRevert(Rebalancer.InvalidParams.selector);
        r.setParams(dust);

        // De goedkoopste opzet die wél mag, kost per run een echte fee over minstens 20 EURC.
        Rebalancer.Params memory cheapest = Rebalancer.Params({
            active: true,
            targetBps: 8000,
            bandBps: 1,
            maxCorrectionBps: 10,
            minTradeEurc: 20e6,
            interval: 1 hours,
            maxSlippageBps: 60
        });
        _setUser(sybil, 1000e6, 0, cheapest);
        _setUser(alice, 1000e6, 0, _defaultParams());

        vm.warp(START + 1);
        _setPrice(PRICE);
        address[] memory due = r.dueOwners(0, 50);
        assertEq(due.length, 2, "beide owners horen due te zijn");

        uint256 feeBefore = eurc.balanceOf(treasury);
        r.execute(sybil, address(0));
        uint256 paid = eurc.balanceOf(treasury) - feeBefore;
        emit log_named_uint("fee van de goedkoopst toegestane run (EURC-basiseenheden)", paid);

        // 25 bps over minstens 20 EURC is 0,05 EURC, precies de keeperbeloning. Gratis bezetten kan niet meer.
        assertGe(paid, 50_000, "een toegestane run kost de aanvaller geen fee");

        // En het contract heeft nooit iemand overgeslagen: `dueOwners` gaf altijd alle due owners terug.
        // De vijf plekken waren een keuze van de CRE-workflow, die inmiddels is verwijderd.
        assertEq(r.lastExecutedAt(alice), 0);
        (bool aliceDue,) = r.isDue(alice);
        assertTrue(aliceDue, "alice blijft due en vindbaar voor elke wekker");
    }

    /// PoC-2: 5 owners die elk (bijna) het volledige EXECUTE_GAS verbruiken passen in ~3,7M gas.
    function test_poc_fiveFullBudgetOwnersFit() public {
        uint256[6] memory burns = [uint256(0), 100_000, 150_000, 200_000, 225_000, 250_000];
        for (uint256 b = 0; b < burns.length; b++) {
            uint256 snap = vm.snapshotState();
            router.setGasBurn(burns[b]);
            address[] memory list = new address[](5);
            for (uint256 i = 0; i < 5; i++) {
                list[i] = makeAddr(string(abi.encodePacked("g", i)));
                _setUser(list[i], 1000e6, 0, _defaultParams());
            }
            uint256 g0 = gasleft();
            vm.prank(forwarder);
            r.onReport{gas: 3_700_000}(_meta(bytes32(uint256(1)), workflowOwner), abi.encode(list));
            uint256 used = g0 - gasleft();
            uint256 executed;
            for (uint256 i = 0; i < 5; i++) {
                if (r.lastExecutedAt(list[i]) != 0) executed++;
            }
            emit log_named_uint("burn", burns[b]);
            emit log_named_uint("  executed of 5 (3.7M gas)", executed);
            emit log_named_uint("  onReport gas used", used);
            vm.revertToState(snap);
        }
    }

    /// PoC-3: metadata korter dan 62 bytes laat de hele call reverten (geen try/catch daar); 64 bytes van de
    /// forwarder wordt gewoon geaccepteerd; workflowId en -naam worden niet gecontroleerd.
    function test_poc_metadataHandling() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.prank(forwarder);
        vm.expectRevert();
        r.onReport(hex"00", abi.encode(list));
        vm.prank(forwarder);
        r.onReport(_meta(keccak256("andere-workflow-zelfde-owner"), workflowOwner), abi.encode(list));
        assertEq(r.lastExecutedAt(alice), uint64(START));
    }

    /// PoC-4: replay van hetzelfde rapport is op contractniveau onschadelijk (NotDue).
    function test_poc_replayIsIdempotent() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        address[] memory list = new address[](1);
        list[0] = alice;
        bytes memory report = abi.encode(list);
        vm.prank(forwarder);
        r.onReport(_meta(bytes32(uint256(1)), workflowOwner), report);
        uint256 bal = eurc.balanceOf(alice);
        vm.expectEmit(true, false, false, true, address(r));
        emit Rebalancer.ReportSkipped(alice, abi.encodeWithSelector(Rebalancer.NotDue.selector));
        vm.prank(forwarder);
        r.onReport(_meta(bytes32(uint256(1)), workflowOwner), report);
        assertEq(eurc.balanceOf(alice), bal);
    }

    /// PoC-5: een owner die vlak voor het rapport zelf execute aanroept (of via een derde) steelt het slot;
    /// het rapport slaat hem over met NotDue. Onschadelijk voor fondsen, wel verspilling van een van de 5 slots.
    function test_poc_frontrunSlot() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        r.execute(alice, bob);
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.expectEmit(true, false, false, true, address(r));
        emit Rebalancer.ReportSkipped(alice, abi.encodeWithSelector(Rebalancer.NotDue.selector));
        vm.prank(forwarder);
        r.onReport(_meta(bytes32(uint256(1)), workflowOwner), abi.encode(list));
        assertEq(eurc.balanceOf(bob), 50_000);
    }
}
