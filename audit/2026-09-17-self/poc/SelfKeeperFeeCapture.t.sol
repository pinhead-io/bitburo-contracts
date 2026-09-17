// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Rebalancer} from "../src/Rebalancer.sol";
import {RebalancerTestBase} from "./Rebalancer.t.sol";

/// @notice Zelf-audit 2026-09-17, bevinding L-D: runs op MIN_TRADE_FLOOR leveren de treasury niets op, en een owner die
///         zijn eigen `execute` aanroept met `rewardTo = zichzelf` handelt dan zonder fee.
///
///         Draaien: kopieer dit bestand naar `test/` en run
///         `~/.foundry/bin/forge test --match-contract SelfKeeperFeeCaptureTest -vv`. Geen fork nodig (mocks).
contract SelfKeeperFeeCaptureTest is RebalancerTestBase {
    /// @dev Wallet van 20.000 EURC, alles in EURC, doel 80% cbBTC, `maxCorrectionBps` 10 (0,1%), `interval` 1 uur. Het
    ///      budget per ronde is max(20.000 × 0,1%, minTradeEurc) = 20 EURC, dus elke run is precies 20 EURC en de fee
    ///      is precies de beloning van 0,05 EURC.
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
                _setPrice(PRICE); // feeds vers houden
            }
            (bool due, int256 delta) = r.isDue(alice);
            assertTrue(due, "owner is due");
            assertEq(delta, int256(20e6), "run = MIN_TRADE_FLOOR");
            vm.prank(alice);
            r.execute(alice, alice);
        }
        uint256 spent = 20_000e6 - eurc.balanceOf(alice);
        // Alice kocht 24 × 20 EURC = 480 EURC en kreeg per run haar eigen beloning terug.
        assertEq(spent, runs * 20e6 - runs * 50_000, "fee komt terug bij de owner");
        assertEq(eurc.balanceOf(treasury), 0, "treasury ontvangt niets");
        emit log_named_uint("volume EURC (6 dec)", runs * 20e6);
        emit log_named_uint("fee betaald door owner netto (6 dec)", 0);
        emit log_named_uint("treasury (6 dec)", eurc.balanceOf(treasury));
    }

    /// @dev Zelfde wallet met een externe keeper: ook dan krijgt de treasury niets, want de fee van een run op de vloer
    ///      gaat volledig naar de beloning.
    function test_poc_floorRunsYieldNothingForTreasuryWithAnyKeeper() public {
        _setUser(alice, 20_000e6, 0, _slowParams());
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(keeper), 50_000);
        assertEq(eurc.balanceOf(treasury), 0);
    }

    /// @dev Ter vergelijking: met de standaard `maxCorrectionBps` 1000 (10%) is de run 2.000 EURC, fee 5 EURC, en krijgt
    ///      de treasury 4,95 EURC; ook als de owner zichzelf beloont.
    function test_poc_normalRunStillPaysTreasury() public {
        Rebalancer.Params memory p = _slowParams();
        p.maxCorrectionBps = 1000;
        _setUser(alice, 20_000e6, 0, p);
        vm.prank(alice);
        r.execute(alice, alice);
        assertEq(eurc.balanceOf(treasury), 5e6 - 50_000);
    }
}
