// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console} from "forge-std/console.sol";
import {BlockWindowTest} from "./BlockWindow.t.sol";

/// @notice PoC for finding A-1 of `audit/2026-09-17-simplify/REPORT.md`: a correction that runs in chunks stops at
///         the band edge, while the same correction in a single run reaches the target.
/// @dev Written against `development` at `b3ca31a` (the contract before the simplification). To run it, check out
///      that commit, copy this file into `test/` and run:
///      `RUN_FORK=false ~/.foundry/bin/forge test --match-test test_poc_a1 -vv`.
///      Same wallet in both tests: 100,000 EURC of value, 74% cbBTC, target 80%, band 5%, cap 10% (drift 6,000 EURC,
///      inside the budget of 10,000). PRICE = 80,000 EURC per cbBTC.
contract ChunkStopsAtBandEdgePoC is BlockWindowTest {
    function _correct(uint128 liquidity) internal returns (uint256 runs, uint256 shareBps) {
        poolEurcUsdc.setLiquidity(liquidity);
        _setUser(alice, 26_000e6, 0.925e8, _params(1000, 20e6));
        for (uint256 i; i < 400; i++) {
            (bool due,) = r.isDue(alice);
            if (!due) break;
            r.execute(alice, keeper);
            runs++;
            _warp(10 minutes);
        }
        (uint256 fraction,) = _fractionOf(alice);
        shareBps = fraction / 1e14;
    }

    function test_poc_a1_singleRunReachesTarget() public {
        (uint256 runs, uint256 shareBps) = _correct(1e15); // deep pool: the whole correction fits in one run
        console.log("deep pool: runs", runs, "cbBTC share after (bps)", shareBps);
        assertEq(runs, 1);
        assertApproxEqAbs(shareBps, 8000, 5);
    }

    function test_poc_a1_chunkedStopsAtBandEdge() public {
        (uint256 runs, uint256 shareBps) = _correct(2e12); // thin pool: ~375 EURC per chunk
        console.log("thin pool: runs", runs, "cbBTC share after (bps)", shareBps);
        assertGt(runs, 1);
        // The round closes as soon as the estimate lands inside the band: ~75%, not the 80% target.
        assertLt(shareBps, 7550);
    }
}
