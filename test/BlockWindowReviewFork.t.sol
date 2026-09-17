// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Rebalancer} from "../src/Rebalancer.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {BlockWindowForkTest, IUniswapV3PoolActions, WindowAttacker} from "./BlockWindowFork.t.sol";

interface IUniswapV3FactoryOwner {
    function owner() external view returns (address);
}

interface IUniswapV3PoolOwnerActions {
    function setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1) external;
}

/// @dev Pool stand-in without initialized ticks: `_maxInput` then computes with only the in-range liquidity.
contract NoTicks {
    function ticks(int24) external pure returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool) {}
}

/// @dev Computes the run size like `_maxRunEurc`, but without the tick boundary: only the in-range liquidity at the
///      start of the block. That is the upper bound that liquidity outside the range may never raise. Only for Base,
///      where EURC is token0 of EURC/USDC and USDC is token0 of USDC/cbBTC.
contract RebalancerInRangeSizing is Rebalancer {
    IUniswapV3Pool private immutable _noTicks;

    constructor(Deployment memory d) Rebalancer(d) {
        _noTicks = IUniswapV3Pool(address(new NoTicks()));
    }

    function maxRunInRangeOnly(bool isBuy, uint256 price) external view returns (uint256) {
        (address touched, Window memory w1, Window memory w2) = _windows();
        if (touched != address(0)) return 0; // no run; the window is then empty
        uint256 in1 = _maxInput(_noTicks, w1, isBuy);
        uint256 eurc1 = isBuy ? in1 : _convert(w1.sqrtPriceX96, false, in1);
        uint256 in2 = _maxInput(_noTicks, w2, isBuy);
        uint256 eurc2 = isBuy ? _convert(w1.sqrtPriceX96, false, in2) : Math.mulDiv(in2, price, 1e8);
        return Math.min(eurc1, eurc2);
    }
}

/// @notice Review PR #18 as asserts on a Base fork: push-then-JIT (M-1), the liquidity cliff (L-1) and the scenarios
///         from the measurement of the variants (LP from an earlier block, pushing without LP, JIT out of range,
///         two owners in one block), each for corrections of 2,000, 5,000 and 10,000 EURC, buy and sell, at the
///         current protocol fee and at protocol fee 0.
///
///         Extra profit = attacker PnL with push − PnL of exactly the same setup without push (same LP or
///         JIT, both pools back to their block-start price, LP removed and fees collected), valued at the
///         block-start price of EURC/USDC and the Chainlink price for cbBTC, without keeper reward. Only compared
///         if as many owners succeed as without push. Pushes: to the unfavourable tick edge (and 0.1 to 0.49 bp
///         beyond) and 0.25 to 5.5 bp from the current price, from the pinned price and from the spot in the tick
///         most favourable to the attacker (set in a previous block). Pushes across the tick boundary must be
///         rejected with PoolTouchedThisBlock.
///
///         Requirements: without LP share no profit; with a large LP share (earlier block, or JIT out of range)
///         < 0.5 bp of the run at the current protocol fee; at protocol fee 0 less than 2 bp of the run (review F-4:
///         a push within the tick is invisible without an observation, so at most ~1 tick per pushed pool). Around the
///         capacity of the window the requirements at `_capacityGrid` apply.
///         Fastest rerun: `FORK_BLOCK=51390800` (then from the RPC cache).
contract BlockWindowReviewForkTest is BlockWindowForkTest {
    uint8 internal constant PUSH_JIT = 1; // push, then JIT in range (same block)
    uint8 internal constant LP_PRIOR = 2; // LP in an earlier block, push, execute
    uint8 internal constant PUSH_ONLY = 3; // push only
    uint8 internal constant OOR_JIT = 4; // push, JIT just out of range in the swap direction (same block)

    // Current configuration (storage, against stack-too-deep).
    uint8 internal kind;
    bool internal lpBoth; // LP/JIT in both pools (else only EURC/USDC)
    bool internal pushBoth; // push in both pools (else only EURC/USDC)
    uint256 internal phiPm; // attacker's share of the active liquidity, per mille
    uint256 internal nOwners;

    address[2] internal pools;
    int24[2] internal lpTl;
    int24[2] internal lpTu;
    uint128[2] internal lpLiq;
    int24[2] internal jl;
    int24[2] internal ju;
    uint128[2] internal jliq;
    uint160[2] internal startSqrt;
    uint256[3] internal e0;
    uint256[3] internal b0;

    RebalancerInRangeSizing internal sizing;

    struct Res {
        uint256 okCount;
        int256 pnl;
        uint256 run;
        bool crossed; // a push changed the tick
        bytes4 revertSel;
        uint256 inRangeBound; // run with only the in-range liquidity, just before execute (OOR_JIT only)
    }

    /// @dev Summary over grids. In memory: `vm.revertToState` also resets the test's storage.
    struct Summary {
        uint256 comparisons;
        int256 maxBpX100;
        uint256 refused; // pushes across the tick boundary or JIT, rejected with PoolTouchedThisBlock
        uint256 oorRunGrew; // JIT out of range: run larger than the same push without JIT
        uint256 oorMaxGrowth; // largest growth in EURC base units
    }

    function setUp() public override {
        super.setUp();
        if (!vm.envOr("RUN_FORK", true)) return;
        pools = [P1, P2];
        deal(address(EURC), address(atk), 5_000_000_000e6);
        deal(address(USDC), address(atk), 5_000_000_000e6);
        deal(address(CBBTC), address(atk), 50_000e8);
        Rebalancer.Deployment memory d = Rebalancer.Deployment({
            eurc: address(EURC),
            cbbtc: address(CBBTC),
            usdc: address(USDC),
            router: ROUTER,
            feedCbbtcUsd: FEED_CBBTC_USD,
            feedEurcUsd: FEED_EURC_USD,
            sequencerFeed: SEQUENCER,
            poolEurcUsdc: P1,
            poolUsdcCbbtc: P2,
            treasury: treasury
        });
        sizing = new RebalancerInRangeSizing(d);
    }

    function _newSummary() internal pure returns (Summary memory sum) {
        sum.maxBpX100 = type(int256).min;
    }

    // ─── Helpers ────────────────────────────────────────────────────────────────────────────────────────────

    function _tick(address pool) internal view returns (int24 t) {
        (, t,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    function _floor10(int24 t) internal pure returns (int24 b) {
        b = t / 10;
        if (t < 0 && t % 10 != 0) b--;
        b *= 10;
    }

    function _nLp() internal view returns (uint256) {
        return lpBoth ? 2 : 1;
    }

    function _nPush() internal view returns (uint256) {
        return pushBoth ? 2 : 1;
    }

    /// @dev Push limit in the direction of the run (buying: both pools down). mode 0: k hundredths of a bp from the
    ///      current price; mode 1: to the unfavourable tick edge, plus k hundredths of a bp beyond. 0 = no room.
    function _pushLimit(address pool, bool isBuy, uint8 mode, uint256 k) internal view returns (uint160 limit) {
        uint160 s = _sqrt(pool);
        int24 t = _tick(pool);
        if (mode == 0) {
            limit = uint160(isBuy ? Math.mulDiv(s, 2e6 - k, 2e6) : Math.mulDiv(s, 2e6 + k, 2e6));
        } else if (isBuy) {
            uint160 e = TickMath.getSqrtPriceAtTick(t);
            limit = k == 0 ? e + 1 : uint160(Math.mulDiv(e, 2e6 - k, 2e6));
        } else {
            uint160 e = TickMath.getSqrtPriceAtTick(t + 1);
            limit = k == 0 ? e - 1 : uint160(Math.mulDiv(e, 2e6 + k, 2e6));
        }
        if (isBuy ? limit >= s : limit <= s) limit = 0;
    }

    /// @dev Previous block: set the price at the spot in the tick most favourable to the attacker (maximum room to the
    ///      unfavourable edge), in the pools it pushes.
    function _edgeStart(bool isBuy) internal {
        for (uint256 i; i < _nPush(); i++) {
            address pool = pools[i];
            int24 t = _tick(pool);
            uint160 s = _sqrt(pool);
            if (isBuy) {
                uint160 e = TickMath.getSqrtPriceAtTick(t + 1) - 1;
                if (e > s) atk.swapTo(pool, false, e);
            } else {
                uint160 e = TickMath.getSqrtPriceAtTick(t) + 1;
                if (e < s) atk.swapTo(pool, true, e);
            }
        }
        _nextBlock();
    }

    function _setProtocolFeeOff() internal {
        address owner = IUniswapV3FactoryOwner(0x33128a8fC17869897dcE68Ed026d694621f6FDfD).owner();
        vm.startPrank(owner);
        IUniswapV3PoolOwnerActions(P1).setFeeProtocol(0, 0);
        IUniswapV3PoolOwnerActions(P2).setFeeProtocol(0, 0);
        vm.stopPrank();
        (,,,,, uint8 fp1,) = IUniswapV3Pool(P1).slot0();
        (,,,,, uint8 fp2,) = IUniswapV3Pool(P2).slot0();
        assertEq(fp1, 0);
        assertEq(fp2, 0);
    }

    function _liq(address pool) internal view returns (uint128) {
        return uint128(uint256(IUniswapV3Pool(pool).liquidity()) * phiPm / (1000 - phiPm));
    }

    function _mintPrior() internal {
        for (uint256 i; i < _nLp(); i++) {
            int24 t = _tick(pools[i]);
            lpTl[i] = _floor10(t) - 20;
            lpTu[i] = lpTl[i] + 50;
            lpLiq[i] = _liq(pools[i]);
            atk.mint(pools[i], lpTl[i], lpTu[i], lpLiq[i]);
        }
        _nextBlock();
    }

    function _jit(bool isBuy) internal {
        jliq = [uint128(0), 0];
        if (kind != PUSH_JIT && kind != OOR_JIT) return;
        for (uint256 i; i < _nLp(); i++) {
            int24 t = _tick(pools[i]);
            jliq[i] = _liq(pools[i]);
            if (kind == PUSH_JIT) {
                jl[i] = _floor10(t) - 20;
                ju[i] = jl[i] + 50;
            } else if (isBuy) {
                ju[i] = _floor10(t);
                jl[i] = ju[i] - 50;
            } else {
                jl[i] = _floor10(t) + 10;
                ju[i] = jl[i] + 50;
            }
            atk.mint(pools[i], jl[i], ju[i], jliq[i]);
        }
    }

    function _victims(bool isBuy, uint256 corr) internal returns (address[] memory vs) {
        vs = new address[](nOwners);
        for (uint256 i; i < nOwners; i++) {
            vs[i] = i == 0 ? victim : i == 1 ? victim2 : makeAddr("victim3");
            _fund(vs[i], isBuy, corr);
            e0[i] = EURC.balanceOf(vs[i]);
            b0[i] = CBBTC.balanceOf(vs[i]);
        }
    }

    function _runOf(address[] memory vs, uint256 price) internal view returns (uint256 run) {
        for (uint256 i; i < vs.length; i++) {
            uint256 e = EURC.balanceOf(vs[i]);
            uint256 b = CBBTC.balanceOf(vs[i]);
            run += e < e0[i] ? e0[i] - e : Math.mulDiv(b0[i] - b, price, 1e8);
        }
    }

    /// @dev One attempt: (push) → (JIT) → execute for all owners → JIT removed, pools back, LP removed.
    function _one(bool isBuy, uint256 corr, bool push, uint8 mode, uint256 k) internal returns (Res memory res) {
        _freshFeeds(0);
        uint256 price = r.quote();
        startSqrt = [_sqrt(P1), _sqrt(P2)];
        address[] memory vs = _victims(isBuy, corr);
        int256 v0 = _value(address(atk), startSqrt[0], price);
        if (push) {
            for (uint256 i; i < _nPush(); i++) {
                uint160 limit = _pushLimit(pools[i], isBuy, mode, k);
                if (limit == 0) return res;
                res.crossed = res.crossed || _crossesTick(WindowAttacker.Push(pools[i], isBuy, limit));
                atk.swapTo(pools[i], isBuy, limit);
            }
        }
        _jit(isBuy);
        if (kind == OOR_JIT) res.inRangeBound = sizing.maxRunInRangeOnly(isBuy, price);
        atk.attack(r, vs, new WindowAttacker.Push[](0));
        res.okCount = atk.succeeded();
        if (res.okCount < nOwners) res.revertSel = bytes4(atk.lastRevert());
        uint256 touched = Math.max(_nPush(), kind == PUSH_ONLY ? 1 : _nLp());
        for (uint256 i; i < touched; i++) {
            if (jliq[i] > 0) atk.exitLp(pools[i], jl[i], ju[i], jliq[i]);
            uint160 cur = _sqrt(pools[i]);
            if (cur != startSqrt[i]) atk.swapTo(pools[i], cur > startSqrt[i], startSqrt[i]);
            if (kind == LP_PRIOR && lpLiq[i] > 0) atk.exitLp(pools[i], lpTl[i], lpTu[i], lpLiq[i]);
        }
        res.pnl = _value(address(atk), startSqrt[0], price) - v0 - int256(res.okCount * REWARD);
        res.run = _runOf(vs, price);
    }

    function _cfg(uint8 kind_, bool lpBoth_, bool pushBoth_, uint256 phiPm_, uint256 nOwners_) internal {
        kind = kind_;
        lpBoth = lpBoth_;
        pushBoth = pushBoth_;
        phiPm = phiPm_;
        nOwners = nOwners_;
        lpLiq = [uint128(0), 0];
    }

    /// @dev Grid for the current configuration, both directions, corrections 2,000 / 5,000 / 10,000 EURC. Asserts
    ///      per correction the requirement on the best extra profit, the rejection of every push across the tick
    ///      boundary and (for JIT out of range) that the run is not larger than without that JIT.
    struct Best {
        uint256 okN;
        int256 bp;
        int256 extra;
        uint256 run;
    }

    function _modes() internal pure returns (uint8[16] memory) {
        return [uint8(1), 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    }

    function _ks() internal pure returns (uint256[16] memory) {
        return [uint256(0), 10, 20, 30, 40, 45, 49, 25, 50, 100, 200, 300, 400, 450, 500, 550];
    }

    function _grid(Summary memory sum, bool feeOff, bool edge) internal {
        uint256[3] memory corrs = [uint256(2000e6), 5000e6, 10_000e6];
        uint256 snap0 = vm.snapshotState();
        for (uint256 d; d < 2; d++) {
            bool isBuy = d == 0;
            vm.revertToState(snap0);
            if (feeOff) _setProtocolFeeOff();
            if (edge) _edgeStart(isBuy);
            if (kind == LP_PRIOR) _mintPrior();
            uint256 snap = vm.snapshotState();
            for (uint256 c; c < corrs.length; c++) {
                Best memory b = _pushes(sum, isBuy, corrs[c], snap);
                _logBest(feeOff, edge, isBuy, corrs[c], b.okN, b.run, b.extra, b.bp);
                if (b.okN == 0) continue;
                sum.comparisons += b.okN;
                if (b.bp > sum.maxBpX100) sum.maxBpX100 = b.bp;
                if (feeOff) assertLt(b.bp, 200, "extra profit 2 bp or more at protocol fee 0");
                // An attacker with a large LP share may take at most < 0.5 bp of the run (accepted
                // by Arjan; the outcome shifts per block with the pool state). Without LP share: no profit.
                else if (kind == LP_PRIOR || kind == OOR_JIT) assertLt(b.bp, 50, "LP: extra profit 0.5 bp or more");
                else assertLe(b.extra, 0, "extra profit at the current protocol fee");
            }
        }
        vm.revertToState(snap0);
    }

    /// @dev All pushes for one direction and correction, compared with the same setup without push.
    function _pushes(Summary memory sum, bool isBuy, uint256 corr, uint256 snap) internal returns (Best memory b) {
        vm.revertToState(snap);
        Res memory base = _one(isBuy, corr, false, 0, 0);
        if (kind == PUSH_JIT) {
            assertEq(base.okCount, 0, "JIT in range in the same block got through");
            assertEq(base.revertSel, Rebalancer.PoolTouchedThisBlock.selector, "JIT: wrong rejection");
        }
        b.bp = type(int256).min;
        uint8[16] memory modes = _modes();
        uint256[16] memory ks = _ks();
        for (uint256 j; j < ks.length; j++) {
            vm.revertToState(snap);
            Res memory a = _one(isBuy, corr, true, modes[j], ks[j]);
            if (a.crossed || kind == PUSH_JIT) {
                assertEq(a.okCount, 0, "push across the tick boundary or JIT got through");
                assertEq(a.revertSel, Rebalancer.PoolTouchedThisBlock.selector, "wrong rejection");
                sum.refused++;
            }
            if (kind == OOR_JIT && a.okCount > 0) _checkOorJit(sum, isBuy, corr, snap, j, a);
            if (a.okCount == 0 || a.okCount != base.okCount || a.run == 0) continue;
            b.okN++;
            int256 extra = a.pnl - base.pnl;
            int256 bp = extra * 1_000_000 / int256(a.run);
            if (bp > b.bp) {
                b.bp = bp;
                b.extra = extra;
                b.run = a.run;
            }
        }
    }

    /// @dev JIT out of range writes no observation. That liquidity may never make the run larger than what the
    ///      in-range liquidity allows (the bug of variant A+L). It can, however, remove an existing cliff: then the run
    ///      grows relative to the same push without JIT up to at most that bound. That is counted and logged.
    function _checkOorJit(Summary memory sum, bool isBuy, uint256 corr, uint256 snap, uint256 j, Res memory a)
        internal
    {
        // Sell: the run is sats × price and the sats are rounded up, so at most 1 sat above the bound.
        assertLe(a.run, a.inRangeBound + r.quote() / 1e8 + 1, "JIT out of range: run above the in-range bound");
        uint256 after_ = vm.snapshotState();
        vm.revertToState(snap);
        kind = PUSH_ONLY;
        Res memory noJit = _one(isBuy, corr, true, _modes()[j], _ks()[j]);
        kind = OOR_JIT;
        vm.revertToState(after_);
        if (noJit.okCount > 0 && a.run > noJit.run) {
            sum.oorRunGrew++;
            if (a.run - noJit.run > sum.oorMaxGrowth) sum.oorMaxGrowth = a.run - noJit.run;
            console.log(
                string.concat(
                    "OOR_GROEI,dir=",
                    isBuy ? "buy" : "sell",
                    ",corr=",
                    vm.toString(corr / 1e6),
                    ",withoutJit=",
                    vm.toString(noJit.run),
                    ",withJit=",
                    vm.toString(a.run),
                    ",inRangeBound=",
                    vm.toString(a.inRangeBound)
                )
            );
        }
    }

    function _logBest(
        bool feeOff,
        bool edge,
        bool isBuy,
        uint256 corr,
        uint256 okN,
        uint256 bestRun,
        int256 bestExtra,
        int256 bestBp
    ) internal view {
        console.log(
            string.concat(
                string.concat(
                    "BEST,kind=",
                    vm.toString(kind),
                    ",lpBoth=",
                    lpBoth ? "1" : "0",
                    ",pushBoth=",
                    pushBoth ? "1" : "0",
                    ",owners=",
                    vm.toString(nOwners),
                    ",phiPm=",
                    vm.toString(phiPm),
                    ",feeOff=",
                    feeOff ? "1" : "0",
                    ",edge=",
                    edge ? "1" : "0"
                ),
                string.concat(
                    ",dir=",
                    isBuy ? "buy" : "sell",
                    ",corr=",
                    vm.toString(corr / 1e6),
                    ",compared=",
                    vm.toString(okN),
                    ",run=",
                    vm.toString(bestRun),
                    ",extra=",
                    vm.toString(bestExtra),
                    ",bpx100=",
                    okN == 0 ? "n/a" : vm.toString(bestBp)
                )
            )
        );
    }

    function _summary(string memory label, Summary memory sum) internal pure {
        console.log(label, "comparisons:", sum.comparisons);
        console.log("  pushes across the tick boundary or JIT rejected:", sum.refused);
        console.log("  highest extra profit (bp x100 of the run):");
        console.logInt(sum.maxBpX100);
        if (sum.oorRunGrew > 0) {
            console.log("  JIT out of range: run larger than without JIT (within the in-range bound):", sum.oorRunGrew);
            console.log("  largest growth (EURC 6 dec):", sum.oorMaxGrowth);
        }
    }

    // ─── Review M-1: push-then-JIT ──────────────────────────────────────────────────────────────────────────

    /// @notice The PoC from the review (push through the thin pool, then JIT liquidity 99× in range, then execute) is
    ///         rejected: the mint writes an observation, so execute reverts with PoolTouchedThisBlock and the victim
    ///         does not trade. Also without push, and with 99.9% JIT in both pools.
    function test_review_pushThenJit_refused() public {
        Summary memory sum = _newSummary();
        _cfg(PUSH_JIT, false, false, 990, 1);
        _grid(sum, false, false);
        _cfg(PUSH_JIT, true, true, 999, 1);
        _grid(sum, false, true);
        _summary("push-then-JIT", sum);
        assertGt(sum.refused, 0, "nothing rejected: the test proves nothing");
        assertEq(sum.comparisons, 0, "a run with JIT in range succeeded");
    }

    /// @notice Five owners of 10,000 EURC in one block after one push of 4.5 bp and JIT: no run succeeds, and isDue
    ///         reports none of the five after the mint. (Review: previously all five succeeded, +3.2 bp for attacker.)
    function test_review_pushThenJit_fiveOwnersRefused() public {
        _freshFeeds(0);
        address[] memory vs = new address[](5);
        for (uint256 i; i < 5; i++) {
            vs[i] = makeAddr(string.concat("multi", vm.toString(i)));
            _fund(vs[i], true, 10_000e6);
            (bool dueBefore,) = r.isDue(vs[i]);
            assertTrue(dueBefore, "setup: owner due");
        }
        WindowAttacker.Push memory p = _push(P1, true, 45);
        atk.swapTo(P1, p.zeroForOne, p.limit);
        int24 tl = _floor10(_tick(P1)) - 20;
        atk.mint(P1, tl, tl + 50, IUniswapV3Pool(P1).liquidity() * 199);
        for (uint256 i; i < 5; i++) {
            (bool due,) = r.isDue(vs[i]);
            assertFalse(due, "isDue after push and JIT");
        }
        assertEq(r.dueOwners(0, 100).length, 0, "dueOwners after push and JIT");
        atk.attack(r, vs, new WindowAttacker.Push[](0));
        assertEq(atk.succeeded(), 0, "a run succeeded after push and JIT");
        assertEq(bytes4(atk.lastRevert()), Rebalancer.PoolTouchedThisBlock.selector);
        for (uint256 i; i < 5; i++) {
            assertEq(EURC.balanceOf(vs[i]), 12_500e6, "victim traded");
        }
    }

    // ─── Which actions write an observation ─────────────────────────────────────────────────────────────────

    function _observationThisBlock(address pool) internal view returns (bool) {
        (,, uint16 index,,,,) = IUniswapV3Pool(pool).slot0();
        (uint32 ts,,,) = IUniswapV3Pool(pool).observations(index);
        return ts == uint32(vm.getBlockTimestamp());
    }

    /// @dev After `action` in a fresh block: did EURC/USDC write an observation, and is the owner still due?
    function _expectTouched(bool touched, string memory what) internal {
        _freshFeeds(0);
        (bool due,) = r.isDue(victim);
        console.log(what, touched ? "observation" : "no observation");
        assertEq(_observationThisBlock(P1), touched, what);
        assertEq(due, !touched, what);
    }

    /// @notice The block check on the real pool, per action (Uniswap v3-core d8b1c635): a swap within the tick, a mint
    ///         or burn out of range, a burn of 0 and collect write nothing; a mint or burn in range and a
    ///         swap across the tick boundary do, and then the owner is not due.
    function test_observationSemantics_perAction() public {
        _fund(victim, true, 2000e6);
        uint256 snap = vm.snapshotState();
        int24 b = _floor10(_tick(P1));
        uint128 l = IUniswapV3Pool(P1).liquidity();

        _expectTouched(false, "fresh block");
        (bool ok, WindowAttacker.Push memory p) = _pushInTick(P1, true, 900_000);
        assertTrue(ok, "setup: room in the tick");
        atk.swapTo(P1, p.zeroForOne, p.limit);
        _expectTouched(false, "swap within the tick");

        vm.revertToState(snap);
        atk.mint(P1, b - 60, b - 10, l);
        _expectTouched(false, "mint out of range (below)");
        atk.mint(P1, b + 20, b + 70, l);
        _expectTouched(false, "mint out of range (above)");
        vm.prank(address(atk));
        IUniswapV3PoolActions(P1).collect(address(atk), b - 60, b - 10, 1, 1);
        _expectTouched(false, "collect");

        vm.revertToState(snap);
        atk.mint(P1, b - 20, b + 30, l);
        _expectTouched(true, "mint in range");

        vm.revertToState(snap);
        atk.mint(P1, b - 20, b + 30, l);
        atk.mint(P1, b - 60, b - 10, l);
        _nextBlock();
        _expectTouched(false, "next block after the mints");
        vm.prank(address(atk));
        IUniswapV3PoolActions(P1).burn(b - 60, b - 10, l);
        _expectTouched(false, "burn out of range");
        vm.prank(address(atk));
        IUniswapV3PoolActions(P1).burn(b - 20, b + 30, 0);
        _expectTouched(false, "burn of 0 in range");
        vm.prank(address(atk));
        IUniswapV3PoolActions(P1).burn(b - 20, b + 30, l);
        _expectTouched(true, "burn in range");

        vm.revertToState(snap);
        int24 tickBefore = _tick(P1);
        p = _push(P1, true, 20);
        atk.swapTo(P1, p.zeroForOne, p.limit);
        assertTrue(_tick(P1) != tickBefore, "setup: tick not changed");
        _expectTouched(true, "swap across the tick boundary");
    }

    // ─── Review L-1: liquidity cliff ────────────────────────────────────────────────────────────────────────

    /// @notice The PoC from the review: price just below a tick boundary, above it 99× less liquidity (position up to
    ///         that boundary, minted in an earlier block), sell of 3,000 EURC. Previously isDue true and execute
    ///         a revert in every block. Now isDue and execute agree in every block, and the run gets smaller instead of
    ///         getting stuck.
    function test_review_liquidityCliff_isDueAgreesWithExecute() public {
        int24 upperB = _floor10(_tick(P1)) + 10;
        uint160 edge = TickMath.getSqrtPriceAtTick(upperB);
        atk.swapTo(P1, false, edge - edge / 400_000); // ~0.05 bp below the boundary
        _nextBlock();
        uint128 liq = uint128(uint256(IUniswapV3Pool(P1).liquidity()) * 99);
        atk.mint(P1, upperB - 10, upperB, liq);
        _nextBlock();
        _freshFeeds(0);
        _fund(victim, false, 3000e6);
        uint256 executed;
        for (uint256 i; i < 6; i++) {
            (bool due, int256 delta) = r.isDue(victim);
            uint256 eurcBefore = EURC.balanceOf(victim);
            (bool ok, bytes memory reason) = address(r).call(abi.encodeCall(r.execute, (victim, address(this))));
            console.log("blk", block.number, due ? "isDue=true" : "isDue=false", ok ? "execute ok" : "execute revert");
            console.logInt(delta);
            if (!ok) console.logBytes(reason);
            assertEq(ok, due, "isDue and execute disagree");
            if (ok) {
                executed++;
                assertGt(EURC.balanceOf(victim), eurcBefore, "run yielded nothing");
            }
            // Next chunk: CHUNK_INTERVAL later, the price and the cliff stay in place.
            _nextBlock();
            vm.warp(vm.getBlockTimestamp() + r.CHUNK_INTERVAL());
            _freshFeeds(0);
        }
        assertGt(executed, 0, "not a single run through the cliff: the owner is stuck");
    }

    // ─── Scenarios from the measurement ───────────────────────────────────────────────────────────────────────

    /// @notice LP from an earlier block (99% of EURC/USDC, or 99.9% of both pools), current protocol fee: extra profit
    ///         below 0.5 bp of the run.
    function test_scenario_lpPriorBlock_currentProtocolFee_belowHalfBp() public {
        Summary memory sum = _newSummary();
        _cfg(LP_PRIOR, false, false, 990, 1);
        _grid(sum, false, false);
        _grid(sum, false, true);
        _cfg(LP_PRIOR, true, false, 999, 1);
        _grid(sum, false, true);
        _cfg(LP_PRIOR, true, true, 999, 1);
        _grid(sum, false, true);
        _summary("LP earlier block, current protocol fee", sum);
        assertGt(sum.comparisons, 0, "nothing compared");
        assertLt(sum.maxBpX100, 50);
    }

    /// @notice LP from an earlier block only in EURC/USDC (99%, or 99.9% with LP in both pools), protocol fee 0 (like
    ///         `test_review_jitPushProfit_protocolFeeOff` from the review): extra profit < 2 bp of the run (review F-4).
    function test_scenario_lpPriorBlock_protocolFeeOff_belowTwoBp_pushEurcPool() public {
        Summary memory sum = _newSummary();
        _cfg(LP_PRIOR, false, false, 990, 1);
        _grid(sum, true, false);
        _grid(sum, true, true);
        _cfg(LP_PRIOR, true, false, 999, 1);
        _grid(sum, true, false);
        _grid(sum, true, true);
        _summary("LP earlier block, protocol fee 0, push EURC/USDC", sum);
        assertGt(sum.comparisons, 0, "nothing compared");
        assertLt(sum.maxBpX100, 200);
    }

    /// @notice Same with LP and push in both pools.
    function test_scenario_lpPriorBlock_protocolFeeOff_belowTwoBp_pushBothPools() public {
        Summary memory sum = _newSummary();
        _cfg(LP_PRIOR, true, true, 999, 1);
        _grid(sum, true, false);
        _grid(sum, true, true);
        _summary("LP earlier block, protocol fee 0, push both pools", sum);
        assertGt(sum.comparisons, 0, "nothing compared");
        assertLt(sum.maxBpX100, 200);
    }

    /// @notice Pushing without LP, in one or both pools: no profit.
    function test_scenario_pushWithoutLp_noProfit() public {
        Summary memory sum = _newSummary();
        _cfg(PUSH_ONLY, false, false, 0, 1);
        _grid(sum, false, false);
        _grid(sum, false, true);
        _cfg(PUSH_ONLY, false, true, 0, 1);
        _grid(sum, false, true);
        _summary("pushing without LP", sum);
        assertGt(sum.comparisons, 0, "nothing compared");
        assertGt(sum.refused, 0, "no push across the tick boundary tested");
        assertLe(sum.maxBpX100, 0);
    }

    /// @notice JIT just out of range in the swap direction (writes no observation) plus push, only EURC/USDC (99%)
    ///         and in both pools (99.9%), current protocol fee: the run stays within what the in-range liquidity
    ///         allows, and the extra profit stays below 0.5 bp of the run.
    function test_scenario_jitOutOfRange_currentProtocolFee() public {
        Summary memory sum = _newSummary();
        _cfg(OOR_JIT, false, false, 990, 1);
        _grid(sum, false, true);
        _cfg(OOR_JIT, true, true, 999, 1);
        _grid(sum, false, true);
        _summary("JIT out of range, current protocol fee", sum);
        assertGt(sum.comparisons, 0, "nothing compared");
        assertLt(sum.maxBpX100, 50);
    }

    /// @notice Same at protocol fee 0: < 2 bp.
    function test_scenario_jitOutOfRange_protocolFeeOff() public {
        Summary memory sum = _newSummary();
        _cfg(OOR_JIT, true, true, 999, 1);
        _grid(sum, true, true);
        _summary("JIT out of range, protocol fee 0", sum);
        assertGt(sum.comparisons, 0, "nothing compared");
        assertLt(sum.maxBpX100, 200);
    }

    /// @notice Two owners in one block after one push in both pools, without LP: no profit.
    function test_scenario_twoOwnersOneBlock_pushOnly() public {
        Summary memory sum = _newSummary();
        _cfg(PUSH_ONLY, false, true, 0, 2);
        _grid(sum, false, true);
        _summary("two owners, without LP", sum);
        assertGt(sum.comparisons, 0, "nothing compared");
        assertLe(sum.maxBpX100, 0);
    }

    /// @notice Two owners in one block with LP from an earlier block (99.9% of both pools), push in EURC/USDC: < 0.5 bp
    ///         at the current protocol fee, < 2 bp at protocol fee 0.
    function test_scenario_twoOwnersOneBlock_lpPriorBlock() public {
        Summary memory cur = _newSummary();
        _cfg(LP_PRIOR, true, false, 999, 2);
        _grid(cur, false, true);
        _summary("two owners, LP earlier block, current protocol fee", cur);
        assertGt(cur.comparisons, 0, "nothing compared");
        Summary memory off = _newSummary();
        _grid(off, true, true);
        _summary("two owners, LP earlier block, protocol fee 0", off);
        assertGt(off.comparisons, 0, "nothing compared");
    }

    /// @notice Two owners, LP and push in both pools, protocol fee 0: < 2 bp.
    function test_scenario_twoOwnersOneBlock_lpPriorBlock_pushBothPools_protocolFeeOff() public {
        Summary memory sum = _newSummary();
        _cfg(LP_PRIOR, true, true, 999, 2);
        _grid(sum, true, true);
        _summary("two owners, LP and push both pools, protocol fee 0", sum);
        assertGt(sum.comparisons, 0, "nothing compared");
    }

    // ─── Review F-4: runs around the capacity of the window ──────────────────────────────────────────────────

    /// @dev Largest run (EURC) the window now allows after a push to the unfavourable tick edge in the pools being
    ///      pushed: `isDue` of an owner with a correction well above any capacity. Returns the
    ///      capacity without push if there is no room for a push.
    function _capacity(bool isBuy, uint256 snap) internal returns (uint256 capPushed, uint256 capPlain) {
        vm.revertToState(snap);
        _freshFeeds(0);
        _fund(victim, isBuy, 5_000_000e6);
        (, int256 plain) = r.isDue(victim);
        capPlain = uint256(plain < 0 ? -plain : plain);
        for (uint256 i; i < _nPush(); i++) {
            uint160 limit = _pushLimit(pools[i], isBuy, 1, 0);
            if (limit != 0) atk.swapTo(pools[i], isBuy, limit);
        }
        (, int256 pushed) = r.isDue(victim);
        capPushed = uint256(pushed < 0 ? -pushed : pushed);
        vm.revertToState(snap);
    }

    /// @dev Highest values over a grid around the capacity, in bp x100 of the run with push.
    struct CapacityWorst {
        int256 victimBpX100; // extra loss of the victim from the push, at equal run
        int256 attackerBpX100; // extra profit of the attacker from the push, at the same correction
        uint256 compared;
    }

    /// @dev Value the victim (owner 0) has lost since `_victims`, in EURC at the feed price.
    function _victimLoss() internal view returns (int256) {
        uint256 price = r.quote();
        uint256 before = e0[0] + Math.mulDiv(b0[0], price, 1e8);
        uint256 afterRun = EURC.balanceOf(victim) + Math.mulDiv(CBBTC.balanceOf(victim), price, 1e8);
        return int256(before) - int256(afterRun);
    }

    /// @dev Grid around the capacity: LP from an earlier block (share `phi` per mille) and push in both pools, price in
    ///      the previous block at the spot in the tick most favourable to the attacker, corrections from 50% to 102% of
    ///      the capacity after the push plus the capacity without push, pushes to the tick edge and price moves of
    ///      0.25 / 0.5 / 1 bp from the price (`limit = s·(2e6−k)/2e6`, k = 25 / 50 / 100). Two measures per case
    ///      (verificatie 579f763):
    ///      - victim: loss with push − loss without push at the same run (same setup, correction = the run
    ///        with push). That is what the push costs the victim: ~1 tick per pushed pool;
    ///      - attacker: PnL with push − PnL of the same setup without push at the same correction, each at its own
    ///        run. That is the attacker's decision: if the push makes the run smaller, it also avoids what it would lose
    ///        as LP on the extra volume, and that too is profit from the push.
    function _capacityGrid(bool feeOff, uint256 phi) internal returns (CapacityWorst memory w) {
        w.victimBpX100 = type(int256).min;
        w.attackerBpX100 = type(int256).min;
        uint256 snap0 = vm.snapshotState();
        for (uint256 d; d < 2; d++) {
            bool isBuy = d == 0;
            vm.revertToState(snap0);
            _cfg(LP_PRIOR, true, true, phi, 1);
            if (feeOff) _setProtocolFeeOff();
            _edgeStart(isBuy);
            _mintPrior();
            uint256 snap = vm.snapshotState();
            (uint256 capPushed, uint256 capPlain) = _capacity(isBuy, snap);
            uint256[9] memory corrs = [
                capPushed * 500 / 1000,
                capPushed * 800 / 1000,
                capPushed * 900 / 1000,
                capPushed * 950 / 1000,
                capPushed * 980 / 1000,
                capPushed * 995 / 1000,
                capPushed,
                capPushed * 1020 / 1000,
                capPlain
            ];
            uint8[4] memory modes = [uint8(1), 0, 0, 0];
            uint256[4] memory ks = [uint256(0), 25, 50, 100];
            for (uint256 c; c < corrs.length; c++) {
                if (corrs[c] < 20e6) continue;
                vm.revertToState(snap);
                Res memory base = _one(isBuy, corrs[c], false, 0, 0);
                for (uint256 j; j < modes.length; j++) {
                    vm.revertToState(snap);
                    Res memory a = _one(isBuy, corrs[c], true, modes[j], ks[j]);
                    if (a.crossed) {
                        assertEq(a.okCount, 0, "push across the tick boundary got through");
                        continue;
                    }
                    if (a.okCount == 0 || base.okCount == 0 || a.run == 0) continue;
                    int256 lossPushed = _victimLoss();
                    vm.revertToState(snap);
                    Res memory same = _one(isBuy, a.run, false, 0, 0);
                    assertEq(same.okCount, 1, "comparison run without push failed");
                    assertApproxEqRel(same.run, a.run, 0.0001e18, "comparison run not the same size");
                    int256 victimBp = (lossPushed - _victimLoss()) * 1_000_000 / int256(a.run);
                    int256 attackerBp = (a.pnl - base.pnl) * 1_000_000 / int256(a.run);
                    w.compared++;
                    if (victimBp > w.victimBpX100) w.victimBpX100 = victimBp;
                    if (attackerBp > w.attackerBpX100) w.attackerBpX100 = attackerBp;
                    _logCapacity(feeOff, isBuy, corrs[c], j, a.run, base.run, victimBp, attackerBp);
                }
            }
        }
        vm.revertToState(snap0);
        assertGt(w.compared, 0, "nothing compared: the test proves nothing");
    }

    function _logCapacity(
        bool feeOff,
        bool isBuy,
        uint256 corr,
        uint256 push,
        uint256 run,
        uint256 runWithoutPush,
        int256 victimBp,
        int256 attackerBp
    ) internal view {
        console.log(
            string.concat(
                string.concat(
                    "CAP,feeOff=",
                    feeOff ? "1" : "0",
                    ",phiPm=",
                    vm.toString(phiPm),
                    isBuy ? ",buy" : ",sell",
                    ",corr=",
                    vm.toString(corr),
                    ",push=",
                    vm.toString(push)
                ),
                string.concat(
                    ",run=",
                    vm.toString(run),
                    ",runWithoutPush=",
                    vm.toString(runWithoutPush),
                    ",victimBpx100=",
                    vm.toString(victimBp),
                    ",attackerBpx100=",
                    vm.toString(attackerBp)
                )
            )
        );
    }

    function _reportCapacity(string memory label, CapacityWorst memory w) internal pure {
        console.log(
            string.concat(
                "F-4 MAX,",
                label,
                ",comparisons=",
                vm.toString(w.compared),
                ",victimBpx100=",
                vm.toString(w.victimBpX100),
                ",attackerBpx100=",
                vm.toString(w.attackerBpX100)
            )
        );
    }

    /// @notice Review F-4, protocol fee 0: an LP with 99% or 99.9% of both pools and runs around the capacity of the
    ///         window. A push within the tick is invisible without an observation. Requirement: the victim loses through
    ///         the push < 2.05 bp of the run (at most ~1 tick per pushed pool). The attacker's extra profit at the same
    ///         correction is only logged, not tested against a fixed bound: it depends on the block (measured
    ///         +1.39 to +4.07 bp over five blocks, verification 579f763). The surplus above the loss of the
    ///         victim comes from the volume that drops out through the smaller run. Protocol fee 0 is hypothetical
    ///         (`feeProtocol` is set to 68).
    function test_scenario_lpNearCapacity_protocolFeeOff_victimBelowTwoBp() public {
        CapacityWorst memory w990 = _capacityGrid(true, 990);
        CapacityWorst memory w999 = _capacityGrid(true, 999);
        _reportCapacity("protocol fee 0,share 99%", w990);
        _reportCapacity("protocol fee 0,share 99.9%", w999);
        assertLt(w990.victimBpX100, 205, "protocol fee 0, share 99%: victim loses 2.05 bp or more");
        assertLt(w999.victimBpX100, 205, "protocol fee 0, share 99.9%: victim loses 2.05 bp or more");
    }

    /// @notice Review F-4, current protocol fee (`feeProtocol` 68 = 1/4 on both pools, read on the fork): the same
    ///         grids around the capacity. Requirements: victim < 2.05 bp (the push shifts its price regardless of the
    ///         protocol fee), attacker < 0.5 bp of the run.
    function test_scenario_lpNearCapacity_currentProtocolFee_belowHalfBp() public {
        (,,,,, uint8 fp1,) = IUniswapV3Pool(P1).slot0();
        (,,,,, uint8 fp2,) = IUniswapV3Pool(P2).slot0();
        console.log("feeProtocol EURC/USDC and USDC/cbBTC:", fp1, fp2);
        assertGt(fp1, 0, "setup: protocol fee is already 0");
        assertGt(fp2, 0, "setup: protocol fee is already 0");
        CapacityWorst memory w990 = _capacityGrid(false, 990);
        CapacityWorst memory w999 = _capacityGrid(false, 999);
        _reportCapacity("current protocol fee,share 99%", w990);
        _reportCapacity("current protocol fee,share 99.9%", w999);
        assertLt(w990.victimBpX100, 205, "current protocol fee, share 99%: victim loses 2.05 bp or more");
        assertLt(w999.victimBpX100, 205, "current protocol fee, share 99.9%: victim loses 2.05 bp or more");
        assertLt(w990.attackerBpX100, 50, "current protocol fee, share 99%: attacker gains 0.5 bp or more");
        assertLt(w999.attackerBpX100, 50, "current protocol fee, share 99.9%: attacker gains 0.5 bp or more");
    }

    /// @notice Two owners in one block with JIT in range: both rejected.
    function test_scenario_twoOwnersOneBlock_jitRefused() public {
        Summary memory sum = _newSummary();
        _cfg(PUSH_JIT, true, false, 999, 2);
        _grid(sum, false, true);
        _summary("two owners, JIT", sum);
        assertGt(sum.refused, 0, "nothing rejected");
        assertEq(sum.comparisons, 0, "a run with JIT in range succeeded");
    }
}
