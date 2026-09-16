// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {IV3SwapRouter} from "../src/interfaces/IV3SwapRouter.sol";

/// @notice Fork-regressies uit de interne audit van 15 september 2026 (`audit/2026-09-15/poc/PocFork.t.sol`).
///         Overslaan met RUN_FORK=false.
contract PocFork is Test {
    IERC20 constant EURC = IERC20(0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42);
    IERC20 constant CBBTC = IERC20(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
    IERC20 constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant POOL_EURC_USDC = 0x7279c08A36333e12c3Fc81747963264c100D66fB;
    address constant POOL_USDC_CBBTC = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;
    address treasury = makeAddr("treasury");
    address keeper = makeAddr("keeper");
    Rebalancer r;

    function setUp() public {
        if (!vm.envOr("RUN_FORK", true)) {
            vm.skip(true);
        }
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));
        r = new Rebalancer(
            Rebalancer.Deployment({
                eurc: address(EURC),
                cbbtc: address(CBBTC),
                usdc: address(USDC),
                router: ROUTER,
                feedCbbtcUsd: 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D,
                feedEurcUsd: 0x9867186e52d2F1C2c565CDA6E747101Fa56501e0,
                sequencerFeed: 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433,
                poolEurcUsdc: POOL_EURC_USDC,
                poolUsdcCbbtc: POOL_USDC_CBBTC,
                treasury: treasury
            })
        );
    }

    function _fund(address u, uint256 e, uint256 b) internal {
        if (e > 0) vm.prank(POOL_EURC_USDC);
        EURC.transfer(u, e);
        if (b > 0) vm.prank(POOL_USDC_CBBTC);
        CBBTC.transfer(u, b);
        vm.startPrank(u);
        EURC.approve(address(r), type(uint256).max);
        CBBTC.approve(address(r), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Was PoC B en B2: een stof-owner met `minTradeEurc = 1` en `maxCorrectionBps = 1` was elke run
    ///      due, reverte op Uniswap of slaagde met fee 0, en kostte de wekker zo elk uur gas. De verharding
    ///      legde daar economische ondergrenzen onder (audit L-1 en M-2), waardoor die opzet niet meer te
    ///      registreren valt. Vervalt die grens ooit, dan faalt deze test.
    function test_dustOwnerCannotRegisterAnymore() public {
        address dust = makeAddr("dust");
        _fund(dust, 10, 0); // 0,00001 EURC

        // minTradeEurc onder MIN_TRADE_FLOOR (20 EURC).
        vm.prank(dust);
        vm.expectRevert(Rebalancer.InvalidParams.selector);
        r.setParams(
            Rebalancer.Params({
                active: true,
                targetBps: 8000,
                bandBps: 1,
                maxCorrectionBps: 1000,
                minTradeEurc: 1,
                interval: 1 hours,
                maxSlippageBps: 100
            })
        );

        // maxCorrectionBps onder MIN_CORRECTION_BPS (10).
        vm.prank(dust);
        vm.expectRevert(Rebalancer.InvalidParams.selector);
        r.setParams(
            Rebalancer.Params({
                active: true,
                targetBps: 8000,
                bandBps: 1,
                maxCorrectionBps: 1,
                minTradeEurc: 20e6,
                interval: 1 hours,
                maxSlippageBps: 100
            })
        );

        // maxSlippageBps onder MIN_SLIPPAGE_BPS (60), de grens uit audit L-2.
        vm.prank(dust);
        vm.expectRevert(Rebalancer.InvalidParams.selector);
        r.setParams(
            Rebalancer.Params({
                active: true,
                targetBps: 8000,
                bandBps: 1,
                maxCorrectionBps: 1000,
                minTradeEurc: 20e6,
                interval: 1 hours,
                maxSlippageBps: 30
            })
        );

        // Er staat dus niemand in het register en geen enkele wekker vindt werk.
        assertEq(r.ownerCount(), 0, "stof-owner staat toch geregistreerd");
        assertEq(r.dueOwners(0, 10).length, 0);
    }

    /// C: de aanroeper sandwicht zijn eigen execute binnen de 0,5%-spotcheck.
    ///    Buyer: 20.000 EURC, cap 10% -> run van 2.000 EURC. Aanvaller verkoopt eerst EURC in de dunne
    ///    EURC/USDC-pool (EURC wordt goedkoper, spot cbBTC-in-EURC stijgt), laat de run lopen (die koopt
    ///    op een slechtere koers), en koopt de EURC daarna terug.
    function test_poc_executorSandwich() public {
        address buyer = makeAddr("buyer");
        deal(address(EURC), buyer, 20_000e6);
        _fund(buyer, 0, 0);
        vm.prank(buyer);
        r.setParams(
            Rebalancer.Params({
                active: true,
                targetBps: 8000,
                bandBps: 500,
                maxCorrectionBps: 1000,
                minTradeEurc: 20e6,
                interval: 1 days,
                maxSlippageBps: 100
            })
        );

        address atk = makeAddr("atk");
        uint256 oracle = r.quote();
        console.log("oracle:", oracle, "spot:", r.spot());
        console.log(
            "EURC in pool:", EURC.balanceOf(POOL_EURC_USDC) / 1e6, "USDC in pool:", USDC.balanceOf(POOL_EURC_USDC) / 1e6
        );

        // Zoek het grootste EURC-bedrag waarmee de spot nog binnen 0,5% blijft (bisectie op een snapshot).
        uint256 lo = 0;
        uint256 hi = 30_000e6;
        for (uint256 i = 0; i < 20; i++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            _sellEurc(atk, mid);
            bool ok;
            try r.quoteChecked() {
                ok = true;
            } catch {}
            vm.revertToState(snap);
            if (ok) lo = mid;
            else hi = mid;
        }
        console.log("max EURC-verkoop binnen 0,5%:", lo / 1e6);

        // 1) Aanvaller verkoopt `lo` EURC -> USDC, tot net binnen de spotcheck vooraf.
        _sellEurc(atk, lo);
        console.log("spot na push:", r.spot(), "afwijking bps:", (r.spot() - oracle) * 10_000 / oracle);

        // 2) De push ligt in hetzelfde blok en verandert de tick van EURC/USDC (Uniswap schrijft dan een observatie),
        //    dus de run revert al vóór de swap op de blokcheck (audit M-1). Vóór de blokcheck strandde hij op het
        //    blokvenster, daarvóór op de spotcheck ná de swap; de oorspronkelijke PoC kwam hier wél doorheen en logde
        //    de winst van de aanvaller.
        uint256 btcBefore = CBBTC.balanceOf(buyer);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.PoolTouchedThisBlock.selector, POOL_EURC_USDC));
        r.execute(buyer, atk);

        assertEq(CBBTC.balanceOf(buyer), btcBefore, "buyer heeft toch gekocht op een geduwde koers");
        assertEq(EURC.balanceOf(atk), 0, "aanvaller heeft toch een beloning geincasseerd");
    }

    function _sellEurc(address who, uint256 amt) internal returns (uint256 out) {
        deal(address(EURC), who, EURC.balanceOf(who) + amt);
        vm.startPrank(who);
        EURC.approve(ROUTER, amt);
        out = IV3SwapRouter(ROUTER)
            .exactInput(
                IV3SwapRouter.ExactInputParams({
                    path: abi.encodePacked(address(EURC), uint24(500), address(USDC)),
                    recipient: who,
                    amountIn: amt,
                    amountOutMinimum: 0
                })
            );
        vm.stopPrank();
    }

    function _buyEurc(address who, uint256 usdcAmt) internal returns (uint256 out) {
        vm.startPrank(who);
        USDC.approve(ROUTER, usdcAmt);
        out = IV3SwapRouter(ROUTER)
            .exactInput(
                IV3SwapRouter.ExactInputParams({
                    path: abi.encodePacked(address(USDC), uint24(500), address(EURC)),
                    recipient: who,
                    amountIn: usdcAmt,
                    amountOutMinimum: 0
                })
            );
        vm.stopPrank();
    }
}
