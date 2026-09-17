// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console} from "forge-std/Test.sol";
import {OracleSandwichBase} from "./OracleSandwich.t.sol";
import {IAggregatorV3} from "src/interfaces/IAggregatorV3.sol";

/// @notice M-1: sandwich profit per run size, with and without the cbBTC/USD feed 0.3% too high (within the deviation
///         threshold). Was `audit/2026-09-16/poc/OracleLagSandwich.t.sol`, a measurement without asserts; there the
///         best push gave up to +18.71 EURC. Now with asserts: no successful attack yields the attacker more than the
///         reward an honest caller also gets, and at least one pushed attack succeeds (else the test proves nothing).
/// @dev `_grid(walletEurc, …)` receives the wallet's EURC size; the correction is 80% of that (the run can be smaller
///      due to the liquidity). Skip with RUN_FORK=false.
contract OracleLagSandwichTest is OracleSandwichBase {
    function _grid(uint256 victimEurc, int256 lagBpsTimes10) internal {
        if (lagBpsTimes10 != 0) {
            (uint80 a, int256 ans, uint256 s, uint256 u, uint80 b) = IAggregatorV3(FEED_CBBTC_USD).latestRoundData();
            vm.mockCall(
                FEED_CBBTC_USD,
                abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
                abi.encode(a, ans * (100000 + lagBpsTimes10) / 100000, s, u, b)
            );
        }
        console.log("oracle", r.quote(), "spot", r.spot());
        uint256 snap0 = vm.snapshotState();
        (bool okB,,) = _run(victimEurc, 100, 0);
        vm.revertToState(snap0);
        console.log("correction (EURC 6 dec)", victimEurc * 8 / 10, "baseline ok", okB);

        uint256[5] memory small = _smallPushes();
        int256 best = type(int256).min;
        uint256 bestPush;
        uint256 pushedOk;
        for (uint256 i = 0; i < small.length + 80; i++) {
            uint256 push = i < small.length ? small[i] : (i - small.length + 1) * 250e6;
            uint256 snap = vm.snapshotState();
            (bool ok, int256 pnl,) = _run(victimEurc, 100, push);
            vm.revertToState(snap);
            if (!ok) continue;
            pushedOk++;
            if (pnl > best) {
                best = pnl;
                bestPush = push;
            }
            assertLe(pnl, int256(REWARD), "attacker earns more than the reward");
        }
        console.log("successful pushes", pushedOk, "best push", bestPush);
        console.log("best attacker PnL incl. reward (EURC 6 dec):");
        console.logInt(best);
        assertGt(pushedOk, 0, "not a single pushed attack succeeded: the test then proves nothing");
    }

    function test_poc_noLag_2500() public {
        _grid(3_125e6, 0);
    }

    function test_poc_noLag_4000() public {
        _grid(5_000e6, 0);
    }

    function test_poc_noLag_5000() public {
        _grid(6_250e6, 0);
    }

    function test_poc_lag30_2500() public {
        _grid(3_125e6, 300);
    }

    function test_poc_lag30_5000() public {
        _grid(6_250e6, 300);
    }

    function test_poc_lag30_8000() public {
        _grid(10_000e6, 300);
    }
}
