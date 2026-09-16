// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Rebalancer} from "../src/Rebalancer.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "../src/libraries/TickMath.sol";

interface IUniswapV3PoolActions {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata)
        external
        returns (int256 amount0, int256 amount1);
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata)
        external
        returns (uint256, uint256);
    function burn(int24 tickLower, int24 tickUpper, uint128 amount) external returns (uint256, uint256);
    function collect(address recipient, int24 tickLower, int24 tickUpper, uint128 amount0, uint128 amount1)
        external
        returns (uint128, uint128);
}

/// @dev Aanvaller die alles in één transactie doet: pools duwen, `execute` voor één of meer owners, terugruilen, en
///      optioneel zijn eigen LP-positie opheffen.
contract WindowAttacker {
    struct Push {
        address pool;
        bool zeroForOne;
        uint160 limit;
    }

    uint160 internal constant MIN_LIMIT = 4295128740;
    uint160 internal constant MAX_LIMIT = 1461446703485210103287273052203988822378723970341;

    address private _pool;
    /// @dev Aantal geslaagde `execute`'s in de laatste `attack`.
    uint256 public succeeded;
    bytes public lastRevert;

    function attack(Rebalancer r, address[] calldata victims, Push[] calldata pushes) external {
        uint256[] memory outs = new uint256[](pushes.length);
        for (uint256 i; i < pushes.length; i++) {
            (, outs[i]) = _swap(pushes[i].pool, pushes[i].zeroForOne, 10_000_000e6, pushes[i].limit);
        }
        succeeded = 0;
        for (uint256 i; i < victims.length; i++) {
            try r.execute(victims[i], address(this)) {
                succeeded++;
            } catch (bytes memory reason) {
                lastRevert = reason;
            }
        }
        for (uint256 i = pushes.length; i > 0; i--) {
            if (outs[i - 1] > 0) _swap(pushes[i - 1].pool, !pushes[i - 1].zeroForOne, outs[i - 1], 0);
        }
    }

    function swapTo(address pool, bool zeroForOne, uint160 limit) external {
        _swap(pool, zeroForOne, 10_000_000e6, limit);
    }

    function mint(address pool, int24 tl, int24 tu, uint128 liq) external {
        _pool = pool;
        IUniswapV3PoolActions(pool).mint(address(this), tl, tu, liq, "");
        _pool = address(0);
    }

    function exitLp(address pool, int24 tl, int24 tu, uint128 liq) external {
        IUniswapV3PoolActions(pool).burn(tl, tu, liq);
        IUniswapV3PoolActions(pool).collect(address(this), tl, tu, type(uint128).max, type(uint128).max);
    }

    function _swap(address pool, bool zeroForOne, uint256 amount, uint160 limit)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        _pool = pool;
        if (limit == 0) limit = zeroForOne ? MIN_LIMIT : MAX_LIMIT;
        (int256 a0, int256 a1) = IUniswapV3PoolActions(pool).swap(address(this), zeroForOne, int256(amount), limit, "");
        _pool = address(0);
        (amountIn, amountOut) = zeroForOne ? (uint256(a0), uint256(-a1)) : (uint256(a1), uint256(-a0));
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        require(msg.sender == _pool, "cb");
        if (a0 > 0) IERC20(IUniswapV3Pool(msg.sender).token0()).transfer(msg.sender, uint256(a0));
        if (a1 > 0) IERC20(IUniswapV3Pool(msg.sender).token1()).transfer(msg.sender, uint256(a1));
    }

    function uniswapV3MintCallback(uint256 a0, uint256 a1, bytes calldata) external {
        require(msg.sender == _pool, "mcb");
        if (a0 > 0) IERC20(IUniswapV3Pool(msg.sender).token0()).transfer(msg.sender, a0);
        if (a1 > 0) IERC20(IUniswapV3Pool(msg.sender).token1()).transfer(msg.sender, a1);
    }
}

/// @notice Fork-tests (Base) voor het blokvenster van audit M-1: winst van een atomaire zelf-sandwich, twee owners in
///         één blok, een eerlijke correctie in delen, en de aanvaller met een groot LP-aandeel. Overslaan met
///         RUN_FORK=false. `FORK_BLOCK` pint een blok (sneller herhalen dankzij de RPC-cache); standaard het laatste.
contract BlockWindowForkTest is Test {
    IERC20 internal constant EURC = IERC20(0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42);
    IERC20 internal constant CBBTC = IERC20(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address internal constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant FEED_CBBTC_USD = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
    address internal constant FEED_EURC_USD = 0x9867186e52d2F1C2c565CDA6E747101Fa56501e0;
    address internal constant SEQUENCER = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address internal constant P1 = 0x7279c08A36333e12c3Fc81747963264c100D66fB; // EURC (token0) / USDC (token1)
    address internal constant P2 = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef; // USDC (token0) / cbBTC (token1)
    uint256 internal constant REWARD = 50_000;

    Rebalancer internal r;
    WindowAttacker internal atk;
    address internal treasury = makeAddr("treasury");
    address internal victim = makeAddr("victim");
    address internal victim2 = makeAddr("victim2");

    function setUp() public virtual {
        if (!vm.envOr("RUN_FORK", true)) {
            vm.skip(true);
            return;
        }
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        r = new Rebalancer(
            Rebalancer.Deployment({
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
            })
        );
        atk = new WindowAttacker();
        deal(address(EURC), address(atk), 50_000_000e6);
        deal(address(USDC), address(atk), 50_000_000e6);
        deal(address(CBBTC), address(atk), 500e8);
        // Begin in een vers blok: de laatste observatie van de pools is dan ouder dan dit blok.
        _nextBlock();
    }

    // ─── Hulpfuncties ───────────────────────────────────────────────────────────────────────────────────────

    function _nextBlock() internal {
        vm.roll(block.number + 1);
        vm.warp(vm.getBlockTimestamp() + 2);
    }

    /// @dev Houdt beide feeds vers na een `vm.warp` (zelfde antwoord, `updatedAt` = nu), optioneel cbBTC/USD
    ///      `lagBps` te hoog (een feed die binnen zijn deviation-drempel van 0,3% achterloopt).
    function _freshFeeds(uint256 lagBps) internal {
        vm.clearMockedCalls();
        address[2] memory feeds = [FEED_CBBTC_USD, FEED_EURC_USD];
        for (uint256 i; i < 2; i++) {
            (uint80 id, int256 answer, uint256 startedAt,, uint80 answeredIn) =
                IAggregatorV3(feeds[i]).latestRoundData();
            if (i == 0 && lagBps > 0) answer = answer * int256(10_000 + lagBps) / 10_000;
            vm.mockCall(
                feeds[i],
                abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
                abi.encode(id, answer, startedAt, vm.getBlockTimestamp(), answeredIn)
            );
        }
    }

    function _sqrt(address pool) internal view returns (uint160 s) {
        (s,,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    /// @dev Owner met een correctie van `correctionEurc` in de richting `isBuy` (doel 80% cbBTC, band 5%,
    ///      maxCorrection 100%).
    function _fund(address owner, bool isBuy, uint256 correctionEurc) internal {
        deal(address(EURC), owner, 0);
        deal(address(CBBTC), owner, 0);
        if (isBuy) deal(address(EURC), owner, correctionEurc * 10 / 8);
        else deal(address(CBBTC), owner, Math.mulDiv(correctionEurc * 5, 1e8, r.quote()));
        vm.startPrank(owner);
        EURC.approve(address(r), type(uint256).max);
        CBBTC.approve(address(r), type(uint256).max);
        r.setParams(
            Rebalancer.Params({
                active: true,
                targetBps: 8000,
                bandBps: 500,
                maxCorrectionBps: 10_000,
                minTradeEurc: 20e6,
                interval: 1 days,
                maxSlippageBps: 100
            })
        );
        vm.stopPrank();
    }

    /// @dev Waarde van de aanvaller in EURC-basiseenheden: USDC via de vaste pool-1-koers `s1`, cbBTC via `price`.
    function _value(address who, uint160 s1, uint256 price) internal view returns (int256) {
        uint256 usdcAsEurc = Math.mulDiv(Math.mulDiv(USDC.balanceOf(who), 1 << 96, s1), 1 << 96, s1);
        return int256(EURC.balanceOf(who) + usdcAsEurc + Math.mulDiv(CBBTC.balanceOf(who), price, 1e8));
    }

    function _ownerValue(address owner, uint256 price) internal view returns (uint256) {
        return EURC.balanceOf(owner) + Math.mulDiv(CBBTC.balanceOf(owner), price, 1e8);
    }

    /// @dev Push in `pool` in de richting van de run (`isBuy`: beide pools omlaag) over `bpsTimes10` / 10 bp
    ///      prijsbeweging vanaf de huidige koers; negatief = tegen de run in.
    function _push(address pool, bool isBuy, int256 bpsTimes10) internal view returns (WindowAttacker.Push memory p) {
        uint160 s = _sqrt(pool);
        bool down = isBuy == (bpsTimes10 > 0);
        uint256 abs = uint256(bpsTimes10 > 0 ? bpsTimes10 : -bpsTimes10);
        // sqrt(1 ± x) ≈ 1 ± x/2; bij een paar bp is de fout verwaarloosbaar (x²/8).
        p.pool = pool;
        p.zeroForOne = down;
        p.limit = uint160(down ? Math.mulDiv(s, 200_000 - abs, 200_000) : Math.mulDiv(s, 200_000 + abs, 200_000));
    }

    /// @dev Push binnen de huidige tick in de richting van de run: `ppm` miljoenste van de ruimte tot de ongunstige
    ///      tickrand (bij kopen P(tick), bij verkopen P(tick + 1)). Zo'n swap schrijft geen observatie. `ok = false`
    ///      als er geen ruimte is.
    function _pushInTick(address pool, bool isBuy, uint256 ppm)
        internal
        view
        returns (bool ok, WindowAttacker.Push memory p)
    {
        (uint160 s, int24 t,,,,,) = IUniswapV3Pool(pool).slot0();
        p.pool = pool;
        p.zeroForOne = isBuy;
        if (isBuy) {
            uint160 edge = TickMath.getSqrtPriceAtTick(t);
            if (s <= edge + 1) return (false, p);
            p.limit = s - uint160(Math.mulDiv(s - edge - 1, ppm, 1e6));
        } else {
            uint160 edge = TickMath.getSqrtPriceAtTick(t + 1);
            if (s + 1 >= edge) return (false, p);
            p.limit = s + uint160(Math.mulDiv(edge - 1 - s, ppm, 1e6));
        }
        ok = p.limit != s;
    }

    /// @dev Verandert deze push de tick (en schrijft hij dus een observatie)? Op de rand zelf: onbepaald, dan false.
    function _crossesTick(WindowAttacker.Push memory p) internal view returns (bool) {
        (, int24 t,,,,,) = IUniswapV3Pool(p.pool).slot0();
        return p.zeroForOne ? p.limit < TickMath.getSqrtPriceAtTick(t) : p.limit >= TickMath.getSqrtPriceAtTick(t + 1);
    }

    struct Outcome {
        bool ok;
        int256 extra; // winst aanvaller min de beloningen die ook een eerlijke aanroeper had gekregen
        uint256 runEurc; // omvang van de run(s) van het slachtoffer, in EURC
    }

    function _attack(address[] memory victims, WindowAttacker.Push[] memory pushes, uint256 price, uint160 s1)
        internal
        returns (Outcome memory o)
    {
        uint256[] memory eurcBefore = new uint256[](victims.length);
        uint256[] memory btcBefore = new uint256[](victims.length);
        for (uint256 i; i < victims.length; i++) {
            eurcBefore[i] = EURC.balanceOf(victims[i]);
            btcBefore[i] = CBBTC.balanceOf(victims[i]);
        }
        int256 v0 = _value(address(atk), s1, price);
        atk.attack(r, victims, pushes);
        uint256 n = atk.succeeded();
        o.ok = n > 0;
        o.extra = _value(address(atk), s1, price) - v0 - int256(n * REWARD);
        for (uint256 i; i < victims.length; i++) {
            uint256 e = EURC.balanceOf(victims[i]);
            uint256 b = CBBTC.balanceOf(victims[i]);
            o.runEurc += e < eurcBefore[i] ? eurcBefore[i] - e : Math.mulDiv(btcBefore[i] - b, price, 1e8);
        }
    }
}

/// @notice (a) en (b): winst van de aanvaller over een raster van pushes.
contract BlockWindowAttackForkTest is BlockWindowForkTest {
    /// @dev Pushes in tiende bp: binnen de tick (0,5 bp), over een paar ticks, tot de vensterrand en erover.
    function _grid() internal pure returns (int256[11] memory g) {
        g = [int256(5), 10, 20, 30, 40, 50, 55, 60, 70, 100, 300];
    }

    struct Stats {
        uint256 attempts;
        uint256 succeeded;
        uint256 succeededBeyondWindow;
        uint256 refusedTouched; // push over de tickgrens, geweigerd met PoolTouchedThisBlock
        int256 worstExtra;
        uint256 worstRun;
    }

    /// @dev Raster voor één richting en feedstand. `poolSel`: 1 = alleen EURC/USDC, 2 = alleen USDC/cbBTC,
    ///      3 = beide. Runs: 100 EURC, 500 EURC en een correctie van 8.000 EURC (de run loopt dan tegen de
    ///      liquiditeitsgrens aan). Naast het raster in bp twee pushes binnen de tick (50% en 99% van de ruimte tot
    ///      de rand): alleen die kunnen sinds de blokcheck nog slagen. Elke push over de tickgrens moet geweigerd
    ///      worden met PoolTouchedThisBlock.
    function _sweep(bool isBuy, uint256 lagBps, Stats memory st) internal {
        _freshFeeds(lagBps);
        uint256 price = r.quote();
        uint160 s1 = _sqrt(P1);
        uint256[3] memory runs = [uint256(100e6), 500e6, 8000e6];
        int256[11] memory g = _grid();
        uint256 snap = vm.snapshotState();
        for (uint256 k; k < runs.length; k++) {
            for (uint256 poolSel = 1; poolSel <= 3; poolSel++) {
                for (uint256 j; j < g.length + 3; j++) {
                    vm.revertToState(snap);
                    _fund(victim, isBuy, runs[k]);
                    // Na het raster: een push tegen de run in (3 bp), dan twee pushes binnen de tick.
                    int256 bps = j < g.length ? g[j] : j == g.length ? int256(-30) : int256(0);
                    WindowAttacker.Push[] memory ps = new WindowAttacker.Push[](poolSel == 3 ? 2 : 1);
                    bool pushOk = true;
                    bool crosses;
                    for (uint256 i; i < ps.length; i++) {
                        address pool = poolSel == 2 || i == 1 ? P2 : P1;
                        if (j <= g.length) ps[i] = _push(pool, isBuy, bps);
                        else (pushOk, ps[i]) = _pushInTick(pool, isBuy, j == g.length + 1 ? 500_000 : 990_000);
                        if (!pushOk) break;
                        crosses = crosses || _crossesTick(ps[i]);
                    }
                    if (!pushOk) continue;
                    address[] memory vs = new address[](1);
                    vs[0] = victim;
                    Outcome memory o = _attack(vs, ps, price, s1);
                    st.attempts++;
                    if (crosses) {
                        assertFalse(o.ok, "push over de tickgrens kwam door");
                        assertEq(
                            bytes4(atk.lastRevert()), Rebalancer.PoolTouchedThisBlock.selector, "verkeerde weigering"
                        );
                        st.refusedTouched++;
                    }
                    if (!o.ok) continue;
                    st.succeeded++;
                    if (bps > 60) st.succeededBeyondWindow++;
                    if (o.extra > st.worstExtra || st.succeeded == 1) {
                        st.worstExtra = o.extra;
                        st.worstRun = o.runEurc;
                    }
                    console.log(
                        string.concat(
                            "GRID,",
                            isBuy ? "koop" : "verkoop",
                            ",lagBps=",
                            vm.toString(lagBps),
                            ",correctie=",
                            vm.toString(runs[k] / 1e6),
                            ",pool=",
                            vm.toString(poolSel),
                            ",push_bp_x10=",
                            vm.toString(bps),
                            ",run=",
                            vm.toString(o.runEurc),
                            ",extra=",
                            vm.toString(o.extra)
                        )
                    );
                    assertLe(o.extra, 0, "aanvaller maakt winst met een atomaire zelf-sandwich");
                }
            }
        }
        vm.revertToState(snap);
    }

    function _report(string memory label, Stats memory st) internal pure {
        console.log(label);
        console.log("  pogingen:", st.attempts, " geslaagd:", st.succeeded);
        console.log("  over de tickgrens geweigerd (PoolTouchedThisBlock):", st.refusedTouched);
        console.log("  geslaagd met push > 6 bp:", st.succeededBeyondWindow, " run bij hoogste winst:", st.worstRun);
        console.log("  hoogste extra winst (EURC 6 dec):");
        console.logInt(st.worstExtra);
    }

    /// @notice (a) Koop: winst ≤ 0 bij elke geslaagde push, bij kleine runs en runs op de liquiditeitsgrens, met
    ///         actuele feeds en met cbBTC/USD 0,3% te hoog. Pushes over de tickgrens worden geweigerd. (Vroeger eiste
    ///         deze test meer dan 20 geslaagde pushes; sinds de blokcheck slagen alleen nog pushes binnen de tick.)
    function test_fork_attackGrid_buy() public {
        Stats memory st;
        _sweep(true, 0, st);
        _sweep(true, 30, st);
        _report("koop", st);
        assertGt(st.succeeded, 0, "geen enkele push slaagde: de test bewijst dan weinig");
        assertGt(st.refusedTouched, 0, "geen push over de tickgrens getoetst");
        assertEq(st.succeededBeyondWindow, 0, "push buiten het venster kwam door");
    }

    /// @notice (a) Verkoop, zelfde raster.
    function test_fork_attackGrid_sell() public {
        Stats memory st;
        _sweep(false, 0, st);
        _sweep(false, 30, st);
        _report("verkoop", st);
        assertGt(st.succeeded, 0, "geen enkele push slaagde: de test bewijst dan weinig");
        assertGt(st.refusedTouched, 0, "geen push over de tickgrens getoetst");
        assertEq(st.succeededBeyondWindow, 0, "push buiten het venster kwam door");
    }

    /// @notice (b) Twee owners in hetzelfde blok na één push (lead 2): de runs delen het venster, en de aanvaller
    ///         maakt geen winst, ook niet als beide runs slagen.
    function test_fork_twoOwnersSameBlockAfterOnePush() public {
        for (uint256 d; d < 2; d++) {
            bool isBuy = d == 0;
            _freshFeeds(0);
            uint256 price = r.quote();
            uint160 s1 = _sqrt(P1);
            uint256 snap = vm.snapshotState();
            uint256 bothOk;
            uint256 oneOk;
            int256[5] memory pushes = [int256(0), 10, 20, 30, 50];
            uint256[3] memory sizes = [uint256(60e6), 300e6, 8000e6];
            for (uint256 k; k < sizes.length; k++) {
                for (uint256 j; j < pushes.length; j++) {
                    vm.revertToState(snap);
                    _fund(victim, isBuy, sizes[k]);
                    _fund(victim2, isBuy, sizes[k]);
                    WindowAttacker.Push[] memory ps = new WindowAttacker.Push[](pushes[j] == 0 ? 0 : 2);
                    if (pushes[j] != 0) {
                        ps[0] = _push(P1, isBuy, pushes[j]);
                        ps[1] = _push(P2, isBuy, pushes[j]);
                    }
                    address[] memory vs = new address[](2);
                    vs[0] = victim;
                    vs[1] = victim2;
                    Outcome memory o = _attack(vs, ps, price, s1);
                    uint256 n = atk.succeeded();
                    if (n == 2) bothOk++;
                    if (n == 1) oneOk++;
                    console.log(
                        string.concat(
                            "TWO,",
                            isBuy ? "koop" : "verkoop",
                            ",correctie=",
                            vm.toString(sizes[k] / 1e6),
                            ",push_bp_x10=",
                            vm.toString(pushes[j]),
                            ",geslaagd=",
                            vm.toString(n),
                            ",run=",
                            vm.toString(o.runEurc),
                            ",extra=",
                            vm.toString(o.extra)
                        )
                    );
                    if (n > 0) assertLe(o.extra, 0, "aanvaller maakt winst met twee owners in een blok");
                }
            }
            console.log(isBuy ? "koop" : "verkoop", "beide geslaagd:", bothOk);
            console.log("  een van beide geslaagd:", oneOk);
            assertGt(bothOk + oneOk, 0, "geen enkele run geslaagd: de test bewijst niets");
            vm.revertToState(snap);
        }
    }
}

/// @notice (c) Een eerlijke correctie van ~8.000 EURC loopt in delen van 10 minuten volledig af.
contract BlockWindowChunksForkTest is BlockWindowForkTest {
    struct Flow {
        uint256 chunks;
        uint256 gasFirst;
        uint256 gasMax;
        uint256 startTime;
        uint256 endTime;
        uint256 traded;
    }

    function _flow(bool isBuy) internal returns (Flow memory f) {
        _freshFeeds(0);
        _fund(victim, isBuy, 8000e6);
        uint256 price = r.quote();
        f.startTime = vm.getBlockTimestamp();
        uint256 valueBefore = _ownerValue(victim, price);
        for (uint256 i; i < 30; i++) {
            (bool due, int256 delta) = r.isDue(victim);
            if (!due) break;
            uint160 s1 = _sqrt(P1);
            uint160 s2 = _sqrt(P2);
            uint256 g = gasleft();
            (bool ok, bytes memory reason) = address(r).call(abi.encodeCall(r.execute, (victim, address(this))));
            uint256 used = g - gasleft();
            if (!ok) {
                console.log("deel reverte, selector:");
                console.logBytes(reason);
            }
            assertTrue(ok, "eerlijk deel reverte");
            f.chunks++;
            f.traded += uint256(delta > 0 ? delta : -delta);
            if (f.chunks == 1) f.gasFirst = used;
            if (used > f.gasMax) f.gasMax = used;
            (bool rb, uint128 left) = r.rounds(victim);
            console.log(
                string.concat(
                    "CHUNK,",
                    isBuy ? "koop" : "verkoop",
                    ",n=",
                    vm.toString(f.chunks),
                    ",delta=",
                    vm.toString(delta),
                    ",gas=",
                    vm.toString(used),
                    ",rest=",
                    vm.toString(uint256(left)),
                    ",rondeKoop=",
                    rb ? "1" : "0"
                )
            );
            f.endTime = vm.getBlockTimestamp();
            // Arbitrage in een volgend blok zet beide pools terug op de stand van vóór het deel.
            _nextBlock();
            _restore(P1, s1);
            _restore(P2, s2);
            vm.warp(vm.getBlockTimestamp() + r.CHUNK_INTERVAL());
            vm.roll(block.number + 1);
            _freshFeeds(0);
        }
        (bool stillDue,) = r.isDue(victim);
        assertFalse(stillDue, "na 30 delen nog steeds due");
        (, uint128 rest) = r.rounds(victim);
        assertEq(rest, 0, "ronde niet afgesloten");
        // Klaar: binnen de band (80% ± 5%).
        uint256 total = _ownerValue(victim, price);
        uint256 fractionBps = Math.mulDiv(Math.mulDiv(CBBTC.balanceOf(victim), price, 1e8), 10_000, total);
        console.log(isBuy ? "koop" : "verkoop", "delen:", f.chunks);
        console.log("  doorlooptijd (s):", f.endTime - f.startTime, " verhandeld (EURC 6 dec):", f.traded);
        console.log("  cbBTC-aandeel na afloop (bps):", fractionBps);
        console.log("  gas eerste deel:", f.gasFirst, " hoogste gas per deel:", f.gasMax);
        console.log("  kosten gebruiker (EURC 6 dec, incl. fee):", valueBefore - total);
        assertGe(fractionBps, 7500, "correctie niet afgerond: onder de band");
        assertLe(fractionBps, 8500, "correctie niet afgerond: boven de band");
        assertGt(f.chunks, 1, "correctie ging in een keer: de test bewijst de delen niet");
    }

    function _restore(address pool, uint160 target) internal {
        uint160 cur = _sqrt(pool);
        if (cur == target) return;
        atk.swapTo(pool, cur > target, target);
    }

    function test_fork_honestCorrectionInChunks_buy() public {
        _flow(true);
    }

    function test_fork_honestCorrectionInChunks_sell() public {
        _flow(false);
    }
}

/// @notice (d) De LP-uitzondering: een aanvaller met een groot deel van de actieve liquiditeit in de EURC/USDC-pool
///         krijgt een deel van zijn eigen poolfee terug. Sinds de blokcheck kan hij in het blok van de run alleen nog
///         binnen de begintick duwen.
contract BlockWindowLpForkTest is BlockWindowForkTest {
    function _lpCase(bool isBuy, uint256 phiPct, uint256 size) internal returns (int256 bestExtra, uint256 bestRun) {
        _freshFeeds(0);
        uint256 price = r.quote();
        uint160 s1 = _sqrt(P1);
        (, int24 t,,,,,) = IUniswapV3Pool(P1).slot0();
        int24 tl = (t / 10) * 10 - 20;
        int24 tu = tl + 50;
        uint128 liq = uint128(uint256(IUniswapV3Pool(P1).liquidity()) * phiPct / (100 - phiPct));
        int256 value0 = _value(address(atk), s1, price);
        atk.mint(P1, tl, tu, liq);
        _nextBlock();
        _freshFeeds(0);
        uint256 snap = vm.snapshotState();
        bestExtra = type(int256).min;
        // Push binnen de tick, in miljoenste van de ruimte tot de ongunstige rand (0 = geen push).
        uint256[5] memory pushes = [uint256(0), 250_000, 500_000, 900_000, 999_000];
        {
            int256 base;
            for (uint256 j; j < pushes.length; j++) {
                vm.revertToState(snap);
                _fund(victim, isBuy, size);
                WindowAttacker.Push[] memory ps = new WindowAttacker.Push[](pushes[j] == 0 ? 0 : 1);
                if (pushes[j] != 0) {
                    bool pushOk;
                    (pushOk, ps[0]) = _pushInTick(P1, isBuy, pushes[j]);
                    if (!pushOk) continue;
                }
                address[] memory vs = new address[](1);
                vs[0] = victim;
                Outcome memory o = _attack(vs, ps, price, s1);
                if (!o.ok) {
                    require(j > 0, "basisrun zonder push faalt");
                    continue;
                }
                atk.exitLp(P1, tl, tu, liq);
                int256 v = _value(address(atk), s1, price) - value0 - int256(REWARD);
                if (j == 0) {
                    base = v;
                    continue;
                }
                int256 extra = v - base;
                console.log(
                    string.concat(
                        "LP,",
                        isBuy ? "koop" : "verkoop",
                        ",phiPct=",
                        vm.toString(phiPct),
                        ",correctie=",
                        vm.toString(size / 1e6),
                        ",push_bp_x10=",
                        vm.toString(pushes[j]),
                        ",run=",
                        vm.toString(o.runEurc),
                        ",extra=",
                        vm.toString(extra)
                    )
                );
                // Relatief tot de run: extra × 10.000 / run in tienden van een bp vergelijken.
                if (
                    bestExtra == type(int256).min || extra * 1e6 / int256(o.runEurc) > bestExtra * 1e6 / int256(bestRun)
                ) {
                    bestExtra = extra;
                    bestRun = o.runEurc;
                }
            }
        }
        vm.revertToState(snap);
    }

    /// @notice Meet de beste extra winst van een LP-aanvaller (aandeel 50%, 80%, 95% van de actieve liquiditeit, gemint
    ///         in een eerder blok) bij de huidige protocolfee, met pushes binnen de begintick. Correcties van 500 en
    ///         10.000 EURC: geen winst. Correctie van 20.000 EURC (run tot ~12.300 EURC dankzij de diepe LP): gemeten
    ///         op blok 51.390.800 +0,066 EURC (0,05 bp) bij 95%; daar geldt de grens van 1 bp uit de protocolfee-0-meting.
    ///         Vroeger: < 0,5 bp met pushes tot 5 bp; die pushes veranderen de tick en worden nu geweigerd.
    function test_fork_lpAttackerProfitAtCurrentProtocolFee() public {
        uint256 snap0 = vm.snapshotState();
        uint256[3] memory phis = [uint256(50), 80, 95];
        uint256[3] memory sizes = [uint256(500e6), 10_000e6, 20_000e6];
        for (uint256 i; i < phis.length; i++) {
            for (uint256 d; d < 2; d++) {
                for (uint256 k; k < sizes.length; k++) {
                    vm.revertToState(snap0);
                    (int256 extra, uint256 run) = _lpCase(d == 0, phis[i], sizes[k]);
                    console.log(d == 0 ? "koop" : "verkoop", "phi %", phis[i]);
                    console.log("  correctie (EURC):", sizes[k] / 1e6, " run (EURC 6 dec):", run);
                    console.log("  beste extra winst (EURC 6 dec):");
                    console.logInt(extra);
                    assertGt(run, 0, "geen enkele push slaagde: de test bewijst niets");
                    if (sizes[k] <= 10_000e6) {
                        assertLe(extra, 0, "LP-aanvaller maakt winst bij de huidige protocolfee");
                    } else {
                        assertLt(extra * 10_000, int256(run), "LP-aanvaller haalt 1 bp of meer van de run");
                    }
                }
            }
        }
    }
}
