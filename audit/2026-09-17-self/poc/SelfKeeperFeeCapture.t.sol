// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Rebalancer} from "../src/Rebalancer.sol";
import {RebalancerTestBase} from "./Rebalancer.t.sol";

/// @notice Self-audit 2026-09-17, finding L-D: runs at MIN_TRADE_FLOOR yield nothing for the treasury, and an owner who
///         calls his own `execute` with `rewardTo = himself` then trades without a fee.
///
///         Run: copy this file to `test/` and run
///         `~/.foundry/bin/forge test --match-contract SelfKeeperFeeCaptureTest -vv`. No fork needed (mocks).
contract SelfKeeperFeeCaptureTest is RebalancerTestBase {
    /// @dev Wallet of 20,000 EURC, all in EURC, target 80% cbBTC, `maxCorrectionBps` 10 (0.1%), `interval` 1 hour. The
    ///      budget per round is max(20,000 × 0.1%, minTradeEurc) = 20 EURC, so every run is exactly 20 EURC and the fee
    ///      is exactly the reward of 0.05 EURC.
    function _slowParams() internal pure returns (Rebalancer.Params memory p) {
        p = _defaultParams();
        p.maxCorrectionBps = 10;
        p.interval = 1 hours;
    }

    function test_poc_selfKeeperTradesFeeFreeAtFloor() public {
        _setUser(alice, 20_000e6, 0, _slowParams());
        uint256 runs = 24;
        for (uint256 i; i < runs; i++) {
            if (i > 0) {
                vm.warp(vm.getBlockTimestamp() + 1 hours);
                vm.roll(block.number + 1);
                _setPrice(PRICE); // keep feeds fresh
            }
            (bool due, int256 delta) = r.isDue(alice);
            assertTrue(due, "owner is due");
            assertEq(delta, int256(20e6), "run = MIN_TRADE_FLOOR");
            vm.prank(alice);
            r.execute(alice, alice);
        }
        uint256 spent = 20_000e6 - eurc.balanceOf(alice);
        // Alice bought 24 × 20 EURC = 480 EURC and got her own reward back on every run.
        assertEq(spent, runs * 20e6 - runs * 50_000, "fee returns to the owner");
        assertEq(eurc.balanceOf(treasury), 0, "treasury receives nothing");
        emit log_named_uint("volume EURC (6 dec)", runs * 20e6);
        emit log_named_uint("net fee paid by owner (6 dec)", 0);
        emit log_named_uint("treasury (6 dec)", eurc.balanceOf(treasury));
    }

    /// @dev Same wallet with an external keeper: the treasury still gets nothing, because the fee of a run at the floor
    ///      goes entirely to the reward.
    function test_poc_floorRunsYieldNothingForTreasuryWithAnyKeeper() public {
        _setUser(alice, 20_000e6, 0, _slowParams());
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(keeper), 50_000);
        assertEq(eurc.balanceOf(treasury), 0);
    }

    /// @dev For comparison: with the default `maxCorrectionBps` 1000 (10%) the run is 2,000 EURC, fee 5 EURC, and the
    ///      treasury gets 4.95 EURC; also when the owner rewards himself.
    function test_poc_normalRunStillPaysTreasury() public {
        Rebalancer.Params memory p = _slowParams();
        p.maxCorrectionBps = 1000;
        _setUser(alice, 20_000e6, 0, p);
        vm.prank(alice);
        r.execute(alice, alice);
        assertEq(eurc.balanceOf(treasury), 5e6 - 50_000);
    }
}
