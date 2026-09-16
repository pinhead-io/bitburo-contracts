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

/// @dev Pool-stand-in zonder geïnitialiseerde ticks: `_maxInput` rekent daarmee alleen met de in-range liquiditeit.
contract NoTicks {
    function ticks(int24) external pure returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool) {}
}

/// @dev Rekent de runomvang zoals `_maxRunEurc`, maar zonder de tickgrens: alleen de in-range liquiditeit aan het begin
///      van het blok. Dat is de bovengrens die liquiditeit buiten de range nooit mag verhogen. Alleen voor Base, waar
///      EURC token0 van EURC/USDC is en USDC token0 van USDC/cbBTC.
contract RebalancerInRangeSizing is Rebalancer {
    IUniswapV3Pool private immutable _noTicks;

    constructor(Deployment memory d) Rebalancer(d) {
        _noTicks = IUniswapV3Pool(address(new NoTicks()));
    }

    function maxRunInRangeOnly(bool isBuy, uint256 price) external view returns (uint256) {
        (address touched, Window memory w1, Window memory w2) = _windows();
        if (touched != address(0)) return 0; // geen run; het venster is dan leeg
        uint256 in1 = _maxInput(_noTicks, w1, isBuy);
        uint256 eurc1 = isBuy ? in1 : _convert(w1.sqrtPriceX96, false, in1);
        uint256 in2 = _maxInput(_noTicks, w2, isBuy);
        uint256 eurc2 = isBuy ? _convert(w1.sqrtPriceX96, false, in2) : Math.mulDiv(in2, price, 1e8);
        return Math.min(eurc1, eurc2);
    }
}

/// @notice Review PR #18 als asserts op een Base-fork: push-then-JIT (M-1), de liquiditeitsklif (L-1) en de
///         scenario's uit de meting van de varianten (LP uit een eerder blok, duwen zonder LP, JIT buiten de range,
///         twee owners in één blok), elk voor correcties van 2.000, 5.000 en 10.000 EURC, koop en verkoop, bij de
///         huidige protocolfee en bij protocolfee 0.
///
///         Extra winst = PnL van de aanvaller met push − PnL van precies dezelfde opzet zonder push (zelfde LP of
///         JIT, beide pools terug naar hun blokbeginkoers, LP opgeheven en fees geïnd), gewaardeerd tegen de
///         blokbeginkoers van EURC/USDC en de Chainlink-koers voor cbBTC, zonder keeperbeloning. Alleen vergeleken als
///         evenveel owners slagen als zonder push. Pushes: tot de ongunstige tickrand (en 0,1 tot 0,49 bp erover) en
///         0,25 tot 5,5 bp vanaf de huidige koers, vanaf de gepinde koers én vanaf de voor de aanvaller gunstigste plek
///         in de tick (in een vorig blok gezet). Pushes over de tickgrens moeten geweigerd worden met
///         PoolTouchedThisBlock.
///
///         Eisen: bij de huidige protocolfee geen winst; bij protocolfee 0 minder dan 1 bp van de run.
///         Snelste herhalen: `FORK_BLOCK=51390800` (dan uit de RPC-cache).
contract BlockWindowReviewForkTest is BlockWindowForkTest {
    uint8 internal constant PUSH_JIT = 1; // push, dan JIT in de range (zelfde blok)
    uint8 internal constant LP_PRIOR = 2; // LP in een eerder blok, push, execute
    uint8 internal constant PUSH_ONLY = 3; // alleen push
    uint8 internal constant OOR_JIT = 4; // push, JIT net buiten de range in de swaprichting (zelfde blok)

    // Lopende configuratie (storage, tegen stack-too-deep).
    uint8 internal kind;
    bool internal lpBoth; // LP/JIT in beide pools (anders alleen EURC/USDC)
    bool internal pushBoth; // push in beide pools (anders alleen EURC/USDC)
    uint256 internal phiPm; // aandeel van de aanvaller in de actieve liquiditeit, promille
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
        bool crossed; // een push veranderde de tick
        bytes4 revertSel;
        uint256 inRangeBound; // run bij alleen de in-range liquiditeit, vlak vóór execute (alleen OOR_JIT)
    }

    /// @dev Samenvatting over rasters. In memory: `vm.revertToState` zet ook de storage van de test terug.
    struct Summary {
        uint256 comparisons;
        int256 maxBpX100;
        uint256 refused; // pushes over de tickgrens of JIT, geweigerd met PoolTouchedThisBlock
        uint256 oorRunGrew; // JIT buiten de range: run groter dan dezelfde push zonder JIT
        uint256 oorMaxGrowth; // grootste groei in EURC-basiseenheden
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

    // ─── Hulpfuncties ───────────────────────────────────────────────────────────────────────────────────────

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

    /// @dev Push-limiet in de richting van de run (kopen: beide pools omlaag). mode 0: k honderdste bp vanaf de
    ///      huidige koers; mode 1: tot de ongunstige tickrand, plus k honderdste bp erover. 0 = geen ruimte.
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

    /// @dev Vorig blok: zet de koers op de voor de aanvaller gunstigste plek in de tick (maximale ruimte tot de
    ///      ongunstige rand), in de pools waar hij duwt.
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

    /// @dev Eén poging: (push) → (JIT) → execute voor alle owners → JIT weg, pools terug, LP opheffen.
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

    /// @dev Raster voor de huidige configuratie, beide richtingen, correcties 2.000 / 5.000 / 10.000 EURC. Asserteert
    ///      per correctie de eis op de beste extra winst, de weigering van elke push over de tickgrens en (bij JIT
    ///      buiten de range) dat de run niet groter is dan zonder die JIT.
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
                if (feeOff) assertLt(b.bp, 100, "extra winst 1 bp of meer bij protocolfee 0");
                else assertLe(b.extra, 0, "extra winst bij de huidige protocolfee");
            }
        }
        vm.revertToState(snap0);
    }

    /// @dev Alle pushes voor één richting en correctie, vergeleken met dezelfde opzet zonder push.
    function _pushes(Summary memory sum, bool isBuy, uint256 corr, uint256 snap) internal returns (Best memory b) {
        vm.revertToState(snap);
        Res memory base = _one(isBuy, corr, false, 0, 0);
        if (kind == PUSH_JIT) {
            assertEq(base.okCount, 0, "JIT in de range in hetzelfde blok kwam door");
            assertEq(base.revertSel, Rebalancer.PoolTouchedThisBlock.selector, "JIT: verkeerde weigering");
        }
        b.bp = type(int256).min;
        uint8[16] memory modes = _modes();
        uint256[16] memory ks = _ks();
        for (uint256 j; j < ks.length; j++) {
            vm.revertToState(snap);
            Res memory a = _one(isBuy, corr, true, modes[j], ks[j]);
            if (a.crossed || kind == PUSH_JIT) {
                assertEq(a.okCount, 0, "push over de tickgrens of JIT kwam door");
                assertEq(a.revertSel, Rebalancer.PoolTouchedThisBlock.selector, "verkeerde weigering");
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

    /// @dev JIT buiten de range schrijft geen observatie. Die liquiditeit mag de run nooit groter maken dan wat de
    ///      in-range liquiditeit toelaat (de fout van variant A+L). Ze kán wel een bestaande klif opheffen: dan groeit de
    ///      run ten opzichte van dezelfde push zonder JIT tot hooguit die grens. Dat wordt geteld en gelogd.
    function _checkOorJit(Summary memory sum, bool isBuy, uint256 corr, uint256 snap, uint256 j, Res memory a)
        internal
    {
        // Verkoop: de run is sats × koers en de sats zijn naar boven afgerond, dus hooguit 1 sat boven de grens.
        assertLe(a.run, a.inRangeBound + r.quote() / 1e8 + 1, "JIT buiten de range: run boven de in-range grens");
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
                    isBuy ? "koop" : "verkoop",
                    ",corr=",
                    vm.toString(corr / 1e6),
                    ",zonderJit=",
                    vm.toString(noJit.run),
                    ",metJit=",
                    vm.toString(a.run),
                    ",inRangeGrens=",
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
                    isBuy ? "koop" : "verkoop",
                    ",corr=",
                    vm.toString(corr / 1e6),
                    ",vergeleken=",
                    vm.toString(okN),
                    ",run=",
                    vm.toString(bestRun),
                    ",extra=",
                    vm.toString(bestExtra),
                    ",bpx100=",
                    okN == 0 ? "n.v.t." : vm.toString(bestBp)
                )
            )
        );
    }

    function _summary(string memory label, Summary memory sum) internal pure {
        console.log(label, "vergelijkingen:", sum.comparisons);
        console.log("  pushes over de tickgrens of JIT geweigerd:", sum.refused);
        console.log("  hoogste extra winst (bp x100 van de run):");
        console.logInt(sum.maxBpX100);
        if (sum.oorRunGrew > 0) {
            console.log("  JIT buiten de range: run groter dan zonder JIT (binnen de in-range grens):", sum.oorRunGrew);
            console.log("  grootste groei (EURC 6 dec):", sum.oorMaxGrowth);
        }
    }

    // ─── Review M-1: push-then-JIT ──────────────────────────────────────────────────────────────────────────

    /// @notice De PoC uit de review (duwen door de dunne pool, dan JIT-liquiditeit 99× in de range, dan execute) wordt
    ///         geweigerd: de mint schrijft een observatie, dus execute revert met PoolTouchedThisBlock en het slachtoffer
    ///         handelt niet. Ook zonder push, en bij 99,9% JIT in beide pools.
    function test_review_pushThenJit_refused() public {
        Summary memory sum = _newSummary();
        _cfg(PUSH_JIT, false, false, 990, 1);
        _grid(sum, false, false);
        _cfg(PUSH_JIT, true, true, 999, 1);
        _grid(sum, false, true);
        _summary("push-then-JIT", sum);
        assertGt(sum.refused, 0, "niets geweigerd: de test bewijst niets");
        assertEq(sum.comparisons, 0, "een run met JIT in de range slaagde");
    }

    /// @notice Vijf owners van 10.000 EURC in één blok na één push van 4,5 bp en JIT: geen enkele run slaagt, en isDue
    ///         meldt na de mint geen van de vijf. (Review: vroeger slaagden alle vijf, +3,2 bp voor de aanvaller.)
    function test_review_pushThenJit_fiveOwnersRefused() public {
        _freshFeeds(0);
        address[] memory vs = new address[](5);
        for (uint256 i; i < 5; i++) {
            vs[i] = makeAddr(string.concat("multi", vm.toString(i)));
            _fund(vs[i], true, 10_000e6);
            (bool dueBefore,) = r.isDue(vs[i]);
            assertTrue(dueBefore, "opzet: owner due");
        }
        WindowAttacker.Push memory p = _push(P1, true, 45);
        atk.swapTo(P1, p.zeroForOne, p.limit);
        int24 tl = _floor10(_tick(P1)) - 20;
        atk.mint(P1, tl, tl + 50, IUniswapV3Pool(P1).liquidity() * 199);
        for (uint256 i; i < 5; i++) {
            (bool due,) = r.isDue(vs[i]);
            assertFalse(due, "isDue na push en JIT");
        }
        assertEq(r.dueOwners(0, 100).length, 0, "dueOwners na push en JIT");
        atk.attack(r, vs, new WindowAttacker.Push[](0));
        assertEq(atk.succeeded(), 0, "een run slaagde na push en JIT");
        assertEq(bytes4(atk.lastRevert()), Rebalancer.PoolTouchedThisBlock.selector);
        for (uint256 i; i < 5; i++) {
            assertEq(EURC.balanceOf(vs[i]), 12_500e6, "slachtoffer handelde");
        }
    }

    // ─── Welke acties schrijven een observatie ──────────────────────────────────────────────────────────────

    function _observationThisBlock(address pool) internal view returns (bool) {
        (,, uint16 index,,,,) = IUniswapV3Pool(pool).slot0();
        (uint32 ts,,,) = IUniswapV3Pool(pool).observations(index);
        return ts == uint32(vm.getBlockTimestamp());
    }

    /// @dev Na `action` in een vers blok: schreef EURC/USDC een observatie, en is de owner nog due?
    function _expectTouched(bool touched, string memory what) internal {
        _freshFeeds(0);
        (bool due,) = r.isDue(victim);
        console.log(what, touched ? "observatie" : "geen observatie");
        assertEq(_observationThisBlock(P1), touched, what);
        assertEq(due, !touched, what);
    }

    /// @notice De blokcheck op de echte pool, per actie (Uniswap v3-core d8b1c635): een swap binnen de tick, een mint
    ///         of burn buiten de range, een burn van 0 en collect schrijven niets; een mint of burn in de range en een
    ///         swap over de tickgrens wel, en dan is de owner niet due.
    function test_observationSemantics_perAction() public {
        _fund(victim, true, 2000e6);
        uint256 snap = vm.snapshotState();
        int24 b = _floor10(_tick(P1));
        uint128 l = IUniswapV3Pool(P1).liquidity();

        _expectTouched(false, "vers blok");
        (bool ok, WindowAttacker.Push memory p) = _pushInTick(P1, true, 900_000);
        assertTrue(ok, "opzet: ruimte in de tick");
        atk.swapTo(P1, p.zeroForOne, p.limit);
        _expectTouched(false, "swap binnen de tick");

        vm.revertToState(snap);
        atk.mint(P1, b - 60, b - 10, l);
        _expectTouched(false, "mint buiten de range (onder)");
        atk.mint(P1, b + 20, b + 70, l);
        _expectTouched(false, "mint buiten de range (boven)");
        vm.prank(address(atk));
        IUniswapV3PoolActions(P1).collect(address(atk), b - 60, b - 10, 1, 1);
        _expectTouched(false, "collect");

        vm.revertToState(snap);
        atk.mint(P1, b - 20, b + 30, l);
        _expectTouched(true, "mint in de range");

        vm.revertToState(snap);
        atk.mint(P1, b - 20, b + 30, l);
        atk.mint(P1, b - 60, b - 10, l);
        _nextBlock();
        _expectTouched(false, "volgend blok na de mints");
        vm.prank(address(atk));
        IUniswapV3PoolActions(P1).burn(b - 60, b - 10, l);
        _expectTouched(false, "burn buiten de range");
        vm.prank(address(atk));
        IUniswapV3PoolActions(P1).burn(b - 20, b + 30, 0);
        _expectTouched(false, "burn van 0 in de range");
        vm.prank(address(atk));
        IUniswapV3PoolActions(P1).burn(b - 20, b + 30, l);
        _expectTouched(true, "burn in de range");

        vm.revertToState(snap);
        int24 tickBefore = _tick(P1);
        p = _push(P1, true, 20);
        atk.swapTo(P1, p.zeroForOne, p.limit);
        assertTrue(_tick(P1) != tickBefore, "opzet: tick niet veranderd");
        _expectTouched(true, "swap over de tickgrens");
    }

    // ─── Review L-1: liquiditeitsklif ───────────────────────────────────────────────────────────────────────

    /// @notice De PoC uit de review: koers vlak onder een tickgrens, daarboven 99× minder liquiditeit (positie tot die
    ///         grens, in een eerder blok gemint), verkoop van 3.000 EURC. Vroeger isDue true en execute in elk blok een
    ///         revert. Nu zijn isDue en execute het in elk blok eens, en de run wordt kleiner in plaats van dat hij
    ///         vastloopt.
    function test_review_liquidityCliff_isDueAgreesWithExecute() public {
        int24 upperB = _floor10(_tick(P1)) + 10;
        uint160 edge = TickMath.getSqrtPriceAtTick(upperB);
        atk.swapTo(P1, false, edge - edge / 400_000); // ~0,05 bp onder de grens
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
            console.log("blok", block.number, due ? "isDue=true" : "isDue=false", ok ? "execute ok" : "execute revert");
            console.logInt(delta);
            if (!ok) console.logBytes(reason);
            assertEq(ok, due, "isDue en execute zijn het oneens");
            if (ok) {
                executed++;
                assertGt(EURC.balanceOf(victim), eurcBefore, "run leverde niets op");
            }
            // Volgend deel: CHUNK_INTERVAL later, de koers en de klif blijven staan.
            _nextBlock();
            vm.warp(vm.getBlockTimestamp() + r.CHUNK_INTERVAL());
            _freshFeeds(0);
        }
        assertGt(executed, 0, "geen enkele run door de klif: de owner zit vast");
    }

    // ─── Scenario's uit de meting ───────────────────────────────────────────────────────────────────────────

    /// @notice LP uit een eerder blok (99% van EURC/USDC, of 99,9% van beide pools), huidige protocolfee: geen winst.
    function test_scenario_lpPriorBlock_currentProtocolFee_noProfit() public {
        Summary memory sum = _newSummary();
        _cfg(LP_PRIOR, false, false, 990, 1);
        _grid(sum, false, false);
        _grid(sum, false, true);
        _cfg(LP_PRIOR, true, false, 999, 1);
        _grid(sum, false, true);
        _cfg(LP_PRIOR, true, true, 999, 1);
        _grid(sum, false, true);
        _summary("LP eerder blok, huidige protocolfee", sum);
        assertGt(sum.comparisons, 0, "niets vergeleken");
        assertLe(sum.maxBpX100, 0);
    }

    /// @notice LP uit een eerder blok alleen in EURC/USDC (99%, of 99,9% met LP in beide pools), protocolfee 0 (zoals
    ///         `test_review_jitPushProfit_protocolFeeOff` uit de review): extra winst onder 1 bp van de run.
    function test_scenario_lpPriorBlock_protocolFeeOff_belowOneBp_pushEurcPool() public {
        Summary memory sum = _newSummary();
        _cfg(LP_PRIOR, false, false, 990, 1);
        _grid(sum, true, false);
        _grid(sum, true, true);
        _cfg(LP_PRIOR, true, false, 999, 1);
        _grid(sum, true, false);
        _grid(sum, true, true);
        _summary("LP eerder blok, protocolfee 0, push EURC/USDC", sum);
        assertGt(sum.comparisons, 0, "niets vergeleken");
        assertLt(sum.maxBpX100, 100);
    }

    /// @notice Idem met LP en push in beide pools.
    function test_scenario_lpPriorBlock_protocolFeeOff_belowOneBp_pushBothPools() public {
        Summary memory sum = _newSummary();
        _cfg(LP_PRIOR, true, true, 999, 1);
        _grid(sum, true, false);
        _grid(sum, true, true);
        _summary("LP eerder blok, protocolfee 0, push beide pools", sum);
        assertGt(sum.comparisons, 0, "niets vergeleken");
        assertLt(sum.maxBpX100, 100);
    }

    /// @notice Duwen zonder LP, in één of beide pools: geen winst.
    function test_scenario_pushWithoutLp_noProfit() public {
        Summary memory sum = _newSummary();
        _cfg(PUSH_ONLY, false, false, 0, 1);
        _grid(sum, false, false);
        _grid(sum, false, true);
        _cfg(PUSH_ONLY, false, true, 0, 1);
        _grid(sum, false, true);
        _summary("duwen zonder LP", sum);
        assertGt(sum.comparisons, 0, "niets vergeleken");
        assertGt(sum.refused, 0, "geen push over de tickgrens getoetst");
        assertLe(sum.maxBpX100, 0);
    }

    /// @notice JIT net buiten de range in de swaprichting (schrijft geen observatie) plus push, alleen EURC/USDC (99%)
    ///         en in beide pools (99,9%), huidige protocolfee: de run blijft binnen wat de in-range liquiditeit
    ///         toelaat, en geen winst.
    function test_scenario_jitOutOfRange_currentProtocolFee() public {
        Summary memory sum = _newSummary();
        _cfg(OOR_JIT, false, false, 990, 1);
        _grid(sum, false, true);
        _cfg(OOR_JIT, true, true, 999, 1);
        _grid(sum, false, true);
        _summary("JIT buiten de range, huidige protocolfee", sum);
        assertGt(sum.comparisons, 0, "niets vergeleken");
        assertLe(sum.maxBpX100, 0);
    }

    /// @notice Idem bij protocolfee 0: < 1 bp.
    function test_scenario_jitOutOfRange_protocolFeeOff() public {
        Summary memory sum = _newSummary();
        _cfg(OOR_JIT, true, true, 999, 1);
        _grid(sum, true, true);
        _summary("JIT buiten de range, protocolfee 0", sum);
        assertGt(sum.comparisons, 0, "niets vergeleken");
        assertLt(sum.maxBpX100, 100);
    }

    /// @notice Twee owners in één blok na één push in beide pools, zonder LP: geen winst.
    function test_scenario_twoOwnersOneBlock_pushOnly() public {
        Summary memory sum = _newSummary();
        _cfg(PUSH_ONLY, false, true, 0, 2);
        _grid(sum, false, true);
        _summary("twee owners, zonder LP", sum);
        assertGt(sum.comparisons, 0, "niets vergeleken");
        assertLe(sum.maxBpX100, 0);
    }

    /// @notice Twee owners in één blok met LP uit een eerder blok (99,9% van beide pools), push in EURC/USDC: geen
    ///         winst bij de huidige protocolfee, < 1 bp bij protocolfee 0.
    function test_scenario_twoOwnersOneBlock_lpPriorBlock() public {
        Summary memory cur = _newSummary();
        _cfg(LP_PRIOR, true, false, 999, 2);
        _grid(cur, false, true);
        _summary("twee owners, LP eerder blok, huidige protocolfee", cur);
        assertGt(cur.comparisons, 0, "niets vergeleken");
        Summary memory off = _newSummary();
        _grid(off, true, true);
        _summary("twee owners, LP eerder blok, protocolfee 0", off);
        assertGt(off.comparisons, 0, "niets vergeleken");
    }

    /// @notice Twee owners, LP en push in beide pools, protocolfee 0: < 1 bp.
    function test_scenario_twoOwnersOneBlock_lpPriorBlock_pushBothPools_protocolFeeOff() public {
        Summary memory sum = _newSummary();
        _cfg(LP_PRIOR, true, true, 999, 2);
        _grid(sum, true, true);
        _summary("twee owners, LP en push beide pools, protocolfee 0", sum);
        assertGt(sum.comparisons, 0, "niets vergeleken");
    }

    /// @notice Twee owners in één blok met JIT in de range: beide geweigerd.
    function test_scenario_twoOwnersOneBlock_jitRefused() public {
        Summary memory sum = _newSummary();
        _cfg(PUSH_JIT, true, false, 999, 2);
        _grid(sum, false, true);
        _summary("twee owners, JIT", sum);
        assertGt(sum.refused, 0, "niets geweigerd");
        assertEq(sum.comparisons, 0, "een run met JIT in de range slaagde");
    }
}
