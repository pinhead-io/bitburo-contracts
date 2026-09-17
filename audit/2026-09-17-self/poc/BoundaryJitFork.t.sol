// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console} from "forge-std/Test.sol";

import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {WindowAttacker} from "./BlockWindowFork.t.sol";
import {BlockWindowReviewForkTest} from "./BlockWindowReviewFork.t.sol";

/// @notice Self-audit 2026-09-17, lead L-E: JIT liquidity on the tick boundary without an observation.
///
///         If the EURC/USDC price sits exactly on P(b) (b a multiple of 10), Uniswap v3 counts a position
///         with lower bound b (at tick b − 1) or upper bound b (at tick b) as outside the range: a mint writes no
///         observation, so the block check does not see it. A run in the direction of that position crosses b at once
///         and trades against that liquidity. This test sets up that state in the previous block, mints 99× the active
///         liquidity in the block of the run and measures: observation yes/no, run size (`isDue`) with and without JIT,
///         what the victim receives with and without JIT, and what the JIT position collects in fees.
///
///         Run: copy this file to `test/` (it imports the fork suites there) and run
///         `FORK_BLOCK=51425248 ~/.foundry/bin/forge test --match-contract BoundaryJitForkTest --match-test boundaryJit -vv`
///         (without `--match-test` all tests inherited from `BlockWindowReviewForkTest` run as well).
contract BoundaryJitForkTest is BlockWindowReviewForkTest {
    struct Out {
        uint256 run; // isDue delta in EURC
        uint256 victimEurc;
        uint256 victimBtc;
        uint256 fee0; // fees collected by JIT position, token0 (EURC)
        uint256 fee1; // token1 (USDC)
        uint256 inRangeBound; // run with only the in-range liquidity (RebalancerInRangeSizing)
        int256 atkPnl; // attacker value after exit − before mint, at block-start price pool 1 + Chainlink, no reward
    }

    /// @dev Previous block: make `b` initialized (small position) and put the price exactly on P(b). With `isBuy` (run
    ///      pushes EURC/USDC down) from below, so tick == b; otherwise from above, so tick == b − 1.
    function _toBoundary(bool isBuy) internal returns (int24 b) {
        int24 t = _tick(P1);
        b = isBuy ? _floor10(t) + 10 : _floor10(t);
        // b becomes an initialized tick (small position bounded by b, in range: observation in this previous block)
        if (isBuy) atk.mint(P1, b - 20, b, 1e9);
        else atk.mint(P1, b, b + 20, 1e9);
        atk.swapTo(P1, !isBuy, TickMath.getSqrtPriceAtTick(b));
        _nextBlock();
        assertEq(_sqrt(P1), TickMath.getSqrtPriceAtTick(b), "price exactly on P(b)");
        assertEq(_tick(P1), isBuy ? b : b - 1, "tick after the swap");
        assertFalse(_observationThisBlock(P1), "fresh block");
    }

    function _run(bool isBuy, bool jit, int24 b, uint128 liq) internal returns (Out memory o) {
        _freshFeeds(0);
        (int24 tl, int24 tu) = isBuy ? (b - 50, b) : (b, b + 50);
        uint256 price = r.quote();
        uint160 s1 = _sqrt(P1);
        int256 v0 = _value(address(atk), s1, price);
        o.inRangeBound = sizing.maxRunInRangeOnly(isBuy, price);
        (bool due, int256 delta) = r.isDue(victim);
        assertTrue(due, "due before JIT");
        if (jit) {
            atk.mint(P1, tl, tu, liq);
            assertFalse(_observationThisBlock(P1), "JIT on the boundary writes no observation");
            (bool due2, int256 delta2) = r.isDue(victim);
            assertTrue(due2, "still due after JIT");
            delta = delta2;
        }
        o.run = uint256(delta > 0 ? delta : -delta);
        uint256 e0 = EURC.balanceOf(victim);
        uint256 c0 = CBBTC.balanceOf(victim);
        address[] memory vs = new address[](1);
        vs[0] = victim;
        atk.attack(r, vs, new WindowAttacker.Push[](0));
        assertEq(atk.succeeded(), 1, "run succeeded");
        o.victimEurc = EURC.balanceOf(victim) > e0 ? EURC.balanceOf(victim) - e0 : 0;
        o.victimBtc = CBBTC.balanceOf(victim) > c0 ? CBBTC.balanceOf(victim) - c0 : 0;
        if (jit) {
            vm.prank(address(atk));
            IUniswapV3PoolLike(P1).burn(tl, tu, liq);
            (,,,, uint128 owed0, uint128 owed1) = _position(tl, tu);
            o.fee0 = owed0;
            o.fee1 = owed1;
            vm.prank(address(atk));
            IUniswapV3PoolLike(P1).collect(address(atk), tl, tu, type(uint128).max, type(uint128).max);
        }
        o.atkPnl = _value(address(atk), s1, price) - v0 - int256(REWARD);
    }

    function _position(int24 tl, int24 tu)
        internal
        view
        returns (uint128 l, uint256 g0, uint256 g1, uint256 x, uint128 owed0, uint128 owed1)
    {
        bytes32 key = keccak256(abi.encodePacked(address(atk), tl, tu));
        (l, g0, g1, owed0, owed1) = IUniswapV3PoolLike(P1).positions(key);
        x = 0;
    }

    function _case(bool isBuy, uint256 corr) internal {
        int24 b = _toBoundary(isBuy);
        _fund(victim, isBuy, corr);
        uint128 liq = uint128(uint256(IUniswapV3Pool(P1).liquidity()) * 99);
        uint256 snap = vm.snapshotState();
        Out memory plain = _run(isBuy, false, b, liq);
        vm.revertToState(snap);
        Out memory withJit = _run(isBuy, true, b, liq);

        console.log(isBuy ? "buy" : "sell", "correction EURC", corr / 1e6);
        console.log("  block", block.number, "boundary b");
        console.logInt(b);
        console.log("  run EURC (6 dec) without / with JIT", plain.run, withJit.run);
        console.log("  victim EURC received without / with JIT", plain.victimEurc, withJit.victimEurc);
        console.log("  victim sats received without / with JIT", plain.victimBtc, withJit.victimBtc);
        console.log("  JIT tokensOwed after burn (principal + fees) EURC / USDC", withJit.fee0, withJit.fee1);
        console.log("  in-range upper bound run EURC", plain.inRangeBound);
        console.log("  attacker PnL without / with JIT (EURC 6 dec, excluding reward):");
        console.logInt(plain.atkPnl);
        console.logInt(withJit.atkPnl);
        // On a sell `isDue` is amountIn × price with amountIn rounded up: up to 1 sat (price / 1e8) above the cap.
        assertLe(withJit.run, plain.inRangeBound + r.quote() / 1e8, "run never above the in-range upper bound");
        console.log("  attacker PnL with JIT in bp x100 of the run");
        console.logInt(withJit.atkPnl * 1e6 / int256(withJit.run));
        // With extra liquidity the victim never gets less.
        if (isBuy) assertGe(withJit.victimBtc, plain.victimBtc, "buyer not worse off");
        else assertGe(withJit.victimEurc, plain.victimEurc, "seller not worse off");
    }

    function test_poc_boundaryJit_sell() public {
        _case(false, 2_000e6);
    }

    function test_poc_boundaryJit_buy() public {
        _case(true, 2_000e6);
    }
}

interface IUniswapV3PoolLike {
    function burn(int24 tickLower, int24 tickUpper, uint128 amount) external returns (uint256, uint256);
    function collect(address recipient, int24 tickLower, int24 tickUpper, uint128 amount0, uint128 amount1)
        external
        returns (uint128, uint128);
    function positions(bytes32 key) external view returns (uint128, uint256, uint256, uint128, uint128);
}
