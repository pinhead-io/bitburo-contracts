// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console} from "forge-std/Test.sol";

import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {WindowAttacker} from "./BlockWindowFork.t.sol";
import {BlockWindowReviewForkTest} from "./BlockWindowReviewFork.t.sol";

/// @notice Zelf-audit 2026-09-17, lead L-E: JIT-liquiditeit op de tickgrens zonder observatie.
///
///         Staat de koers van EURC/USDC precies op P(b) (b een veelvoud van 10), dan geldt voor Uniswap v3 een positie
///         met ondergrens b (bij tick b − 1) of bovengrens b (bij tick b) als buiten de range: een mint schrijft geen
///         observatie, dus de blokcheck ziet hem niet. Een run in de richting van die positie kruist b meteen en handelt
///         tegen die liquiditeit. Deze test zet die stand in het vorige blok, mint in het blok van de run 99× de
///         actieve liquiditeit en meet: observatie ja/nee, runomvang (`isDue`) met en zonder JIT, wat het slachtoffer
///         ontvangt met en zonder JIT, en wat de JIT-positie aan fees int.
///
///         Draaien: kopieer dit bestand naar `test/` (het importeert de fork-suites daar) en run
///         `FORK_BLOCK=51425248 ~/.foundry/bin/forge test --match-contract BoundaryJitForkTest --match-test boundaryJit -vv`
///         (zonder `--match-test` draaien ook alle geërfde tests uit `BlockWindowReviewForkTest`).
contract BoundaryJitForkTest is BlockWindowReviewForkTest {
    struct Out {
        uint256 run; // isDue-delta in EURC
        uint256 victimEurc;
        uint256 victimBtc;
        uint256 fee0; // geïnde fees JIT-positie, token0 (EURC)
        uint256 fee1; // token1 (USDC)
        uint256 inRangeBound; // run bij alleen de in-range liquiditeit (RebalancerInRangeSizing)
        int256 atkPnl; // waarde aanvaller na exit min vóór mint, tegen blokbeginkoers pool 1 en Chainlink, zonder beloning
    }

    /// @dev Vorig blok: maak `b` geïnitialiseerd (kleine positie) en zet de koers precies op P(b). Bij `isBuy` (run duwt
    ///      EURC/USDC omlaag) vanaf onder, zodat tick == b; anders vanaf boven, zodat tick == b − 1.
    function _toBoundary(bool isBuy) internal returns (int24 b) {
        int24 t = _tick(P1);
        b = isBuy ? _floor10(t) + 10 : _floor10(t);
        // b wordt een geïnitialiseerde tick (kleine positie met b als grens, in de range: observatie in dit vorige blok)
        if (isBuy) atk.mint(P1, b - 20, b, 1e9);
        else atk.mint(P1, b, b + 20, 1e9);
        atk.swapTo(P1, !isBuy, TickMath.getSqrtPriceAtTick(b));
        _nextBlock();
        assertEq(_sqrt(P1), TickMath.getSqrtPriceAtTick(b), "koers precies op P(b)");
        assertEq(_tick(P1), isBuy ? b : b - 1, "tick na de swap");
        assertFalse(_observationThisBlock(P1), "vers blok");
    }

    function _run(bool isBuy, bool jit, int24 b, uint128 liq) internal returns (Out memory o) {
        _freshFeeds(0);
        (int24 tl, int24 tu) = isBuy ? (b - 50, b) : (b, b + 50);
        uint256 price = r.quote();
        uint160 s1 = _sqrt(P1);
        int256 v0 = _value(address(atk), s1, price);
        o.inRangeBound = sizing.maxRunInRangeOnly(isBuy, price);
        (bool due, int256 delta) = r.isDue(victim);
        assertTrue(due, "due voor JIT");
        if (jit) {
            atk.mint(P1, tl, tu, liq);
            assertFalse(_observationThisBlock(P1), "JIT op de grens schrijft geen observatie");
            (bool due2, int256 delta2) = r.isDue(victim);
            assertTrue(due2, "nog due na JIT");
            delta = delta2;
        }
        o.run = uint256(delta > 0 ? delta : -delta);
        uint256 e0 = EURC.balanceOf(victim);
        uint256 c0 = CBBTC.balanceOf(victim);
        address[] memory vs = new address[](1);
        vs[0] = victim;
        atk.attack(r, vs, new WindowAttacker.Push[](0));
        assertEq(atk.succeeded(), 1, "run geslaagd");
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

        console.log(isBuy ? "koop" : "verkoop", "correctie EURC", corr / 1e6);
        console.log("  blok", block.number, "grens b");
        console.logInt(b);
        console.log("  run EURC (6 dec) zonder / met JIT", plain.run, withJit.run);
        console.log("  slachtoffer EURC ontvangen zonder / met JIT", plain.victimEurc, withJit.victimEurc);
        console.log("  slachtoffer sats ontvangen zonder / met JIT", plain.victimBtc, withJit.victimBtc);
        console.log("  JIT tokensOwed na burn (hoofdsom + fees) EURC / USDC", withJit.fee0, withJit.fee1);
        console.log("  in-range bovengrens run EURC", plain.inRangeBound);
        console.log("  PnL aanvaller zonder / met JIT (EURC 6 dec, zonder beloning):");
        console.logInt(plain.atkPnl);
        console.logInt(withJit.atkPnl);
        // Bij verkoop is `isDue` amountIn × koers met amountIn naar boven afgerond: tot 1 sat (koers / 1e8) boven de cap.
        assertLe(withJit.run, plain.inRangeBound + r.quote() / 1e8, "run nooit boven de in-range bovengrens");
        console.log("  PnL aanvaller met JIT in bp x100 van de run");
        console.logInt(withJit.atkPnl * 1e6 / int256(withJit.run));
        // Het slachtoffer krijgt met extra liquiditeit nooit minder.
        if (isBuy) assertGe(withJit.victimBtc, plain.victimBtc, "koper niet slechter");
        else assertGe(withJit.victimEurc, plain.victimEurc, "verkoper niet slechter");
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
