// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {BlockWindowForkTest, WindowAttacker} from "./BlockWindowFork.t.sol";

interface ILagFactoryOwner {
    function owner() external view returns (address);
}

interface ILagPoolOwner {
    function setFeeProtocol(uint8, uint8) external;
}

contract LagAttacker is WindowAttacker {
    /// @dev Swap to exactly `limit`; the amount is large enough that the limit always binds (or the transfer reverts).
    function pushTo(address pool, bool zeroForOne, uint160 limit)
        external
        returns (uint256 amountIn, uint256 amountOut)
    {
        return _swap(pool, zeroForOne, 1 << 200, limit);
    }

    function swapExact(address pool, bool zeroForOne, uint256 amount) external returns (uint256, uint256) {
        return _swap(pool, zeroForOne, amount, 0);
    }
}

/// @notice Self-audit 2026-09-17, leads 17 and 18 (extension of L-F, `PrevBlockLagFork.t.sol`).
///
///         Lead 17: push in block N-1 in USDC/cbBTC only, or split over both pools, with and without
///         Chainlink lag in the attacker's favour (cbBTC/USD 30 bp, EURC/USD 10 bp), without LP and with an
///         LP of 99% in both pools, at the current protocol fee and at protocol fee 0. No arbitrage between the blocks.
///
///         Lead 18: in block N, before the run, a push within the starting tick in both pools (no observation), by
///         an LP of 99% in both pools, with and without lag, on its own and on top of the largest accepted push in
///         block N-1.
///
///         Measures, per configuration (buy and sell, correction 10,000 EURC):
///         - extra attacker profit = attacker value with push minus the same setup without push (same LP, same
///           lag), excluding keeper reward, in bp x100 of the run;
///         - extra victim loss = worse effective price than without push, in bp x100;
///         - victim against the real price (without lag), including the 25 bp fee.
///         Extra: `test_lead17_p1only_protocolFeeOff` is the control (push only in EURC/USDC, as in L-F), and
///         `test_lead17_run{25k,50k,100k}_protocolFeeOff` measure larger runs: a push in USDC/cbBTC costs a fixed sum
///         of pool fee to the existing LPs, while the profit grows with the run.
///         Logs only; the conclusions are in `audit/2026-09-17/FINDINGS-STATUS.md` (09-17-self/lead 17 and 18).
///
///         Run: copy this file to `test/` (it imports `./BlockWindowFork.t.sol`) and run
///         `FORK_BLOCK=51425248 ~/.foundry/bin/forge test --match-contract Leads17And18ForkTest -vv`.
contract Leads17And18ForkTest is BlockWindowForkTest {
    LagAttacker internal latk;

    uint256 internal corr = 10_000e6; // the victim's correction

    struct Setup {
        bool isBuy;
        uint256 phiPm; // LP share in both pools in per mille, 0 = no LP
        uint256 cbLag;
        uint256 euLag;
        int256 prevP1; // push in block N-1, bp x10, in the direction of the run
        int256 prevP2;
        uint256 inTickPpm; // push within the starting tick in block N, both pools; 0 = none
    }

    struct Res {
        bool ok;
        bytes4 err;
        uint256 victimIn;
        uint256 victimOut;
        int256 atkValue;
    }

    function setUp() public override {
        super.setUp();
        latk = new LagAttacker();
        atk = latk;
        deal(address(EURC), address(latk), 1e15 * 1e6);
        deal(address(USDC), address(latk), 1e15 * 1e6);
        deal(address(CBBTC), address(latk), 1e10 * 1e8);
    }

    /// @dev Fresh feeds; `cbbtcBps`/`eurcBps` > 0 shift the oracle price EURC/cbBTC in the attacker's favour.
    function _feeds(bool isBuy, uint256 cbbtcBps, uint256 eurcBps) internal {
        vm.clearMockedCalls();
        address[2] memory feeds = [FEED_CBBTC_USD, FEED_EURC_USD];
        for (uint256 i; i < 2; i++) {
            (uint80 id, int256 answer, uint256 startedAt,, uint80 answeredIn) =
                IAggregatorV3(feeds[i]).latestRoundData();
            int256 lag = int256(i == 0 ? cbbtcBps : eurcBps);
            int256 sign = (i == 0) == isBuy ? int256(1) : int256(-1);
            answer = answer * (10_000 + sign * lag) / 10_000;
            vm.mockCall(
                feeds[i],
                abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
                abi.encode(id, answer, startedAt, vm.getBlockTimestamp(), answeredIn)
            );
        }
    }

    function _setProtocolFeeOff() internal {
        address o = ILagFactoryOwner(0x33128a8fC17869897dcE68Ed026d694621f6FDfD).owner();
        vm.startPrank(o);
        ILagPoolOwner(P1).setFeeProtocol(0, 0);
        ILagPoolOwner(P2).setFeeProtocol(0, 0);
        vm.stopPrank();
    }

    function _range(address pool) internal view returns (int24 tl, int24 tu) {
        (, int24 t,,,,,) = IUniswapV3Pool(pool).slot0();
        tl = ((t / 10) * 10) - 200;
        tu = ((t / 10) * 10) + 200;
    }

    function _run(Setup memory c) internal returns (Res memory res) {
        _feeds(c.isBuy, 0, 0);
        uint256 truePrice = r.quote();
        uint160 s1 = _sqrt(P1);
        int256 v0 = _value(address(latk), s1, truePrice);
        address[2] memory pools = [P1, P2];
        int24[2] memory tl;
        int24[2] memory tu;
        uint128[2] memory liq;
        if (c.phiPm > 0) {
            for (uint256 i; i < 2; i++) {
                (tl[i], tu[i]) = _range(pools[i]);
                liq[i] = uint128(uint256(IUniswapV3Pool(pools[i]).liquidity()) * c.phiPm / (1000 - c.phiPm));
                latk.mint(pools[i], tl[i], tu[i], liq[i]);
            }
            _nextBlock();
        }
        // Block N-1: push in the direction of the run.
        int256[2] memory prev = [c.prevP1, c.prevP2];
        uint256[2] memory prevOut;
        bool[2] memory prevDir;
        for (uint256 i; i < 2; i++) {
            if (prev[i] == 0) continue;
            WindowAttacker.Push memory p = _push(pools[i], c.isBuy, prev[i]);
            prevDir[i] = p.zeroForOne;
            (, prevOut[i]) = latk.pushTo(pools[i], p.zeroForOne, p.limit);
            require(_sqrt(pools[i]) == p.limit, "push did not reach the target price");
        }
        // Block N: lag, then optionally a push within the starting tick, then execute.
        _nextBlock();
        _feeds(c.isBuy, 0, 0);
        _fund(victim, c.isBuy, corr);
        _feeds(c.isBuy, c.cbLag, c.euLag);
        uint256[2] memory tickOut;
        bool[2] memory tickDir;
        if (c.inTickPpm > 0) {
            for (uint256 i; i < 2; i++) {
                (bool ok, WindowAttacker.Push memory p) = _pushInTick(pools[i], c.isBuy, c.inTickPpm);
                if (!ok) continue;
                tickDir[i] = p.zeroForOne;
                (, tickOut[i]) = latk.pushTo(pools[i], p.zeroForOne, p.limit);
                require(_sqrt(pools[i]) == p.limit, "in-tick push did not reach the target price");
            }
        }
        uint256 e0 = EURC.balanceOf(victim);
        uint256 b0 = CBBTC.balanceOf(victim);
        vm.prank(address(latk));
        try r.execute(victim, address(latk)) {
            res.ok = true;
        } catch (bytes memory reason) {
            res.err = bytes4(reason);
        }
        if (c.isBuy) {
            res.victimIn = e0 - EURC.balanceOf(victim);
            res.victimOut = CBBTC.balanceOf(victim) - b0;
        } else {
            res.victimIn = b0 - CBBTC.balanceOf(victim);
            res.victimOut = EURC.balanceOf(victim) - e0;
        }
        // Everything back in the same block, remove the LP.
        for (uint256 i; i < 2; i++) {
            if (tickOut[i] > 0) latk.swapExact(pools[i], !tickDir[i], tickOut[i]);
        }
        for (uint256 i; i < 2; i++) {
            if (prevOut[i] > 0) latk.swapExact(pools[i], !prevDir[i], prevOut[i]);
        }
        for (uint256 i; i < 2; i++) {
            if (liq[i] > 0) latk.exitLp(pools[i], tl[i], tu[i], liq[i]);
        }
        res.atkValue = _value(address(latk), s1, truePrice) - v0 - (res.ok ? int256(REWARD) : int256(0));
    }

    function _eff(bool isBuy, Res memory x) internal pure returns (uint256) {
        return isBuy ? Math.mulDiv(x.victimIn, 1e8, x.victimOut) : Math.mulDiv(x.victimOut, 1e8, x.victimIn);
    }

    struct Best {
        int256 maxPushX10; // largest accepted push
        int256 atkBpX100; // highest extra attacker profit, bp x100 of the run
        int256 victimBpX100; // extra victim loss at that push
        int256 victimTrueBpX100; // victim against the real price at that push
        uint256 tried;
        uint256 accepted;
        int256 worstVictimBpX100; // largest extra victim loss over all accepted pushes
        int256 atkAtWorstVictim; // extra attacker profit at that push
        int256 victimTrueAtWorst;
    }

    function _compare(Setup memory c, Res memory base, Res memory x, uint256 truePrice, Best memory b, int256 pushX10)
        internal
        pure
    {
        b.tried++;
        if (!x.ok) return;
        b.accepted++;
        uint256 eff = _eff(c.isBuy, x);
        uint256 effBase = _eff(c.isBuy, base);
        int256 victimExtra = c.isBuy
            ? (int256(eff) - int256(effBase)) * 1e6 / int256(effBase)
            : (int256(effBase) - int256(eff)) * 1e6 / int256(effBase);
        int256 victimTrue = c.isBuy
            ? (int256(eff) - int256(truePrice)) * 1e6 / int256(truePrice)
            : (int256(truePrice) - int256(eff)) * 1e6 / int256(truePrice);
        uint256 runEurc = c.isBuy ? x.victimIn : Math.mulDiv(x.victimIn, truePrice, 1e8);
        int256 atk = (x.atkValue - base.atkValue) * 1e6 / int256(runEurc);
        if (pushX10 > b.maxPushX10) b.maxPushX10 = pushX10;
        if (b.accepted == 1 || victimExtra > b.worstVictimBpX100) {
            b.worstVictimBpX100 = victimExtra;
            b.atkAtWorstVictim = atk;
            b.victimTrueAtWorst = victimTrue;
        }
        if (b.accepted == 1 || atk > b.atkBpX100) {
            b.atkBpX100 = atk;
            b.victimBpX100 = victimExtra;
            b.victimTrueBpX100 = victimTrue;
        }
    }

    function _log(string memory label, Setup memory c, bool feeOff, Best memory b) internal view {
        console.log(
            string.concat(
                "L1718,",
                label,
                c.isBuy ? ",buy" : ",sell",
                ",corr=",
                vm.toString(corr / 1e6),
                ",phiPm=",
                vm.toString(c.phiPm),
                ",feeOff=",
                feeOff ? "1" : "0",
                ",lag=",
                vm.toString(c.cbLag),
                "/",
                vm.toString(c.euLag),
                string.concat(
                    ",accepted=",
                    vm.toString(b.accepted),
                    "/",
                    vm.toString(b.tried),
                    ",maxPush_bpx10=",
                    vm.toString(b.maxPushX10),
                    ",bestAtk_bpx100=",
                    vm.toString(b.atkBpX100),
                    ",victimExtra_bpx100=",
                    vm.toString(b.victimBpX100),
                    ",victimVsTrue_bpx100=",
                    vm.toString(b.victimTrueBpX100),
                    ",worstVictim_bpx100=",
                    vm.toString(b.worstVictimBpX100),
                    ",atkAtWorst_bpx100=",
                    vm.toString(b.atkAtWorstVictim),
                    ",victimVsTrueAtWorst_bpx100=",
                    vm.toString(b.victimTrueAtWorst)
                )
            )
        );
    }

    /// @dev Lead 17: grid of pushes in block N-1. mode 1 = USDC/cbBTC only, mode 2 = split evenly over both.
    function _lead17(bool isBuy, uint256 phiPm, bool feeOff, uint8 mode) internal {
        if (feeOff) _setProtocolFeeOff();
        uint256[2][2] memory lags = [[uint256(0), 0], [uint256(30), 10]];
        uint256 snap = vm.snapshotState();
        for (uint256 l; l < 2; l++) {
            Setup memory c = Setup(isBuy, phiPm, lags[l][0], lags[l][1], 0, 0, 0);
            vm.revertToState(snap);
            _feeds(isBuy, 0, 0);
            uint256 truePrice = r.quote();
            Res memory base = _run(c);
            require(base.ok, "baseline failed");
            Best memory b;
            for (int256 push = 50; push <= 1200; push += 50) {
                vm.revertToState(snap);
                // mode 0 = EURC/USDC only (control, as in L-F), 1 = USDC/cbBTC only, 2 = split evenly.
                c.prevP1 = mode == 2 ? push / 2 : mode == 0 ? push : int256(0);
                c.prevP2 = mode == 2 ? push / 2 : mode == 0 ? int256(0) : push;
                Res memory x = _run(c);
                _compare(c, base, x, truePrice, b, push);
            }
            _log(mode == 0 ? "lead17-p1only" : mode == 1 ? "lead17-p2only" : "lead17-both", c, feeOff, b);
        }
        vm.revertToState(snap);
    }

    /// @dev Lead 18: LP 99% in both pools, push within the starting tick in both pools in block N; `prevPush` on top in
    ///      block N-1 (EURC/USDC, bp x10; 0 = none).
    function _lead18(bool isBuy, bool feeOff, int256 prevPush, uint256 phiPm) internal {
        if (feeOff) _setProtocolFeeOff();
        uint256[2][2] memory lags = [[uint256(0), 0], [uint256(30), 10]];
        uint256[4] memory ppms = [uint256(250_000), 500_000, 900_000, 999_000];
        uint256 snap = vm.snapshotState();
        for (uint256 l; l < 2; l++) {
            Setup memory c = Setup(isBuy, phiPm, lags[l][0], lags[l][1], prevPush, 0, 0);
            vm.revertToState(snap);
            _feeds(isBuy, 0, 0);
            uint256 truePrice = r.quote();
            Res memory base = _run(c);
            if (!base.ok) {
                console.log("L1718,lead18: base without in-tick push reverts, prevPush bpx10", uint256(prevPush));
                continue;
            }
            Best memory b;
            for (uint256 k; k < ppms.length; k++) {
                vm.revertToState(snap);
                c.inTickPpm = ppms[k];
                Res memory x = _run(c);
                _compare(c, base, x, truePrice, b, int256(ppms[k] / 1000));
            }
            _log(prevPush == 0 ? "lead18-inTick" : "lead18-inTick+prev", c, feeOff, b);
        }
        vm.revertToState(snap);
    }

    /// @dev Control: push only in EURC/USDC, same setup as L-F (`PrevBlockLagFork.t.sol`).
    function test_lead17_p1only_protocolFeeOff() public {
        for (uint256 i; i < 2; i++) {
            uint256 phi = i == 0 ? 990 : 999;
            _lead17(true, phi, true, 0);
            _lead17(false, phi, true, 0);
        }
    }

    // ─── Lead 17 ────────────────────────────────────────────────────────────────────────────────────────────

    function test_lead17_noLp_currentFee() public {
        for (uint8 m = 1; m <= 2; m++) {
            _lead17(true, 0, false, m);
            _lead17(false, 0, false, m);
        }
    }

    function test_lead17_lp_currentFee() public {
        for (uint8 m = 1; m <= 2; m++) {
            _lead17(true, 990, false, m);
            _lead17(false, 990, false, m);
        }
    }

    function test_lead17_lp_protocolFeeOff() public {
        for (uint256 i; i < 2; i++) {
            uint256 phi = i == 0 ? 990 : 999;
            for (uint8 m = 1; m <= 2; m++) {
                _lead17(true, phi, true, m);
                _lead17(false, phi, true, m);
            }
        }
    }

    /// @dev Cost of a push in USDC/cbBTC is fixed (pool fee to the existing LPs), the profit grows with the run:
    ///      larger corrections, per pool split, LP 99% at protocol fee 0, with and without lag.
    function _largerRuns(uint256 c) internal {
        corr = c;
        for (uint8 m; m <= 2; m++) {
            _lead17(true, 990, true, m);
            _lead17(false, 990, true, m);
        }
    }

    function test_lead17_run25k_protocolFeeOff() public {
        _largerRuns(25_000e6);
    }

    function test_lead17_run50k_protocolFeeOff() public {
        _largerRuns(50_000e6);
    }

    function test_lead17_run100k_protocolFeeOff() public {
        _largerRuns(100_000e6);
    }

    // ─── Lead 18 ────────────────────────────────────────────────────────────────────────────────────────────

    function test_lead18_inTick_currentFee() public {
        _lead18(true, false, 0, 990);
        _lead18(false, false, 0, 990);
    }

    function test_lead18_inTick_protocolFeeOff() public {
        for (uint256 i; i < 2; i++) {
            uint256 phi = i == 0 ? 990 : 999;
            _lead18(true, true, 0, phi);
            _lead18(false, true, 0, phi);
        }
    }

    /// @dev On top of the largest push in EURC/USDC in block N-1 that was still accepted with full lag (L-F:
    ///      buy 90 bp, sell 80 bp).
    function test_lead18_inTickOnTopOfPrevPush_protocolFeeOff() public {
        for (uint256 i; i < 2; i++) {
            uint256 phi = i == 0 ? 990 : 999;
            _lead18(true, true, 900, phi);
            _lead18(false, true, 800, phi);
        }
    }
}
