// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Leads17And18ForkTest} from "./Leads17And18Fork.t.sol";

/// @notice Measurement for finding A-2 of `audit/2026-09-17-simplify/REPORT.md`: the previous-block push (L-F, I-4,
///         lead 17) at the CURRENT Uniswap protocol fee, for corrections larger than the 10,000 EURC that was
///         measured before. `Leads17And18Fork.t.sol::_largerRuns` only measured larger runs with the protocol fee
///         switched off.
/// @dev Written against `development` at `b3ca31a`. To run it, check out that commit, copy this file and
///      `audit/2026-09-17-self/poc/Leads17And18Fork.t.sol` into `test/` and run:
///      `FORK_BLOCK=51425248 ~/.foundry/bin/forge test --match-contract LargeRunsCurrentFeeForkPoC --match-test test_poc_a2 -vv`.
///      Log lines start with `L1718`; `bestAtk_bpx100` is the attacker's extra profit in bp x100 of the run.
contract LargeRunsCurrentFeeForkPoC is Leads17And18ForkTest {
    /// @param mode 0 = push in EURC/USDC only, 1 = push in USDC/cbBTC only.
    function _at(uint256 correction, uint256 lpShareInPerMille, uint8 mode) internal {
        corr = correction;
        _lead17(true, lpShareInPerMille, false, mode);
    }

    // Push in EURC/USDC, LP share 99%: the sign flips between 40,000 and 45,000 EURC.
    function test_poc_a2_eurcPool_10k() public { _at(10_000e6, 990, 0); }
    function test_poc_a2_eurcPool_20k() public { _at(20_000e6, 990, 0); }
    function test_poc_a2_eurcPool_30k() public { _at(30_000e6, 990, 0); }
    function test_poc_a2_eurcPool_40k() public { _at(40_000e6, 990, 0); }
    function test_poc_a2_eurcPool_45k() public { _at(45_000e6, 990, 0); }
    function test_poc_a2_eurcPool_50k() public { _at(50_000e6, 990, 0); }
    function test_poc_a2_eurcPool_75k() public { _at(75_000e6, 990, 0); }

    // Same run of 75,000 EURC at smaller LP shares.
    function test_poc_a2_eurcPool_75k_share90() public { _at(75_000e6, 900, 0); }
    function test_poc_a2_eurcPool_75k_share75() public { _at(75_000e6, 750, 0); }
    function test_poc_a2_eurcPool_75k_share50() public { _at(75_000e6, 500, 0); }

    // Push in the much deeper USDC/cbBTC pool: the attacker loses at every size and share.
    function test_poc_a2_cbbtcPool_50k() public { _at(50_000e6, 990, 1); }
    function test_poc_a2_cbbtcPool_200k() public { _at(200_000e6, 990, 1); }
    function test_poc_a2_cbbtcPool_200k_noLp() public { _at(200_000e6, 0, 1); }
}
