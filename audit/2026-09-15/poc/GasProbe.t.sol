// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {RebalancerTestBase} from "repo/test/Rebalancer.t.sol";
import {Rebalancer} from "repo/src/Rebalancer.sol";
contract GasProbe is RebalancerTestBase {
    function test_probe() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        uint256 g0 = gasleft();
        r.execute(alice, bob);
        emit log_named_uint("execute gas (mock, no burn)", g0 - gasleft());
        _setUser(bob, 1000e6, 0, _defaultParams());
        router.setGasBurn(300_000);
        address[] memory list = new address[](1);
        list[0] = bob;
        vm.prank(forwarder);
        vm.recordLogs();
        r.onReport{gas: 3_700_000}(abi.encodePacked(bytes32(uint256(1)), bytes10("x"), workflowOwner, bytes2(0x0001)), abi.encode(list));
        emit log_named_uint("bob lastExecutedAt", r.lastExecutedAt(bob));
    }
}
