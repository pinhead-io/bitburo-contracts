// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console} from "forge-std/Test.sol";
import {OracleSandwichTest} from "./OracleSandwich.t.sol";
import {IAggregatorV3} from "src/interfaces/IAggregatorV3.sol";

/// @notice M-1: sandwich-winst per rungrootte, met en zonder cbBTC/USD-feed 0,3% te hoog (binnen de deviation-drempel).
///         Was `audit/2026-09-16/poc/OracleLagSandwich.t.sol`, een meting zonder asserts; daar gaf de beste push tot
///         +18,71 EURC. Nu met asserts: geen enkele geslaagde aanval levert de aanvaller meer op dan de beloning die
///         een eerlijke aanroeper ook krijgt, en minstens één geduwde aanval slaagt (anders bewijst de test niets).
/// @dev `_grid(walletEurc, …)` krijgt de EURC-omvang van de wallet mee; de correctie is 80% daarvan (de run kan door
///      de liquiditeit kleiner zijn). Overslaan met RUN_FORK=false.
contract OracleLagSandwichTest is OracleSandwichTest {
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
        console.log("correctie (EURC 6 dec)", victimEurc * 8 / 10, "baseline ok", okB);

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
            assertLe(pnl, int256(REWARD), "aanvaller verdient meer dan de beloning");
        }
        console.log("geslaagde pushes", pushedOk, "beste push", bestPush);
        console.log("beste PnL aanvaller incl. beloning (EURC 6 dec):");
        console.logInt(best);
        assertGt(pushedOk, 0, "geen enkele geduwde aanval geslaagd: de test bewijst dan niets");
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
