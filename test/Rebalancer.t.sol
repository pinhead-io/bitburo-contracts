// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, Vm, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Rebalancer} from "../src/Rebalancer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {MockUniswapV3Factory} from "./mocks/MockUniswapV3Factory.sol";

// ─── Gedeelde opzet ────────────────────────────────────────────────────────────────────────────────────────

abstract contract RebalancerTestBase is Test {
    uint256 internal constant START = 1_800_000_000;
    uint256 internal constant PRICE = 80_000e6; // EURC-basiseenheden per cbBTC
    uint256 internal constant BPS = 10_000;

    MockERC20 internal eurc;
    MockERC20 internal cbbtc;
    MockERC20 internal usdc;
    MockAggregator internal feedBtc;
    MockAggregator internal feedEurc;
    MockAggregator internal sequencer;
    MockRouter internal router;
    MockUniswapV3Pool internal poolEurcUsdc; // token0 = EURC, token1 = USDC, zoals op Base
    MockUniswapV3Pool internal poolUsdcCbbtc; // token0 = USDC, token1 = cbBTC, zoals op Base
    MockUniswapV3Factory internal factory;
    Rebalancer internal r;

    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    function setUp() public virtual {
        vm.warp(START);

        eurc = new MockERC20("Euro Coin", "EURC", 6);
        cbbtc = new MockERC20("Coinbase Wrapped BTC", "cbBTC", 8);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        feedBtc = new MockAggregator(8, "cbBTC / USD");
        feedEurc = new MockAggregator(8, "EURC / USD");
        sequencer = new MockAggregator(0, "L2 Sequencer Uptime");
        poolEurcUsdc = new MockUniswapV3Pool(address(eurc), address(usdc));
        poolUsdcCbbtc = new MockUniswapV3Pool(address(usdc), address(cbbtc));
        _setPrice(PRICE);
        sequencer.set(0, START - 1 days, START - 1 days);

        router = new MockRouter(address(eurc), address(usdc), address(cbbtc), PRICE);
        factory = new MockUniswapV3Factory();
        factory.setPool(address(eurc), address(usdc), 500, address(poolEurcUsdc));
        factory.setPool(address(usdc), address(cbbtc), 500, address(poolUsdcCbbtc));
        router.setFactory(address(factory));

        r = new Rebalancer(_deployment());
    }

    function _deployment() internal view returns (Rebalancer.Deployment memory) {
        return Rebalancer.Deployment({
            eurc: address(eurc),
            cbbtc: address(cbbtc),
            usdc: address(usdc),
            router: address(router),
            feedCbbtcUsd: address(feedBtc),
            feedEurcUsd: address(feedEurc),
            sequencerFeed: address(sequencer),
            poolEurcUsdc: address(poolEurcUsdc),
            poolUsdcCbbtc: address(poolUsdcCbbtc),
            treasury: treasury
        });
    }

    /// @dev Zet feeds én pools zo dat `quote()` en `spot()` (op afronding na) `price` EURC per cbBTC geven,
    ///      met EURC/USD = 1.
    function _setPrice(uint256 price) internal {
        feedBtc.set(int256(price * 1e8 / 1e6), block.timestamp, block.timestamp);
        feedEurc.set(1e8, block.timestamp, block.timestamp);
        _setSpot(price);
    }

    /// @dev Alleen de pools: EURC/USDC op 1:1, USDC/cbBTC op `price` USDC-basiseenheden per cbBTC.
    function _setSpot(uint256 price) internal {
        poolEurcUsdc.setPrice(1e6, 1e6);
        poolUsdcCbbtc.setPrice(price, 1e8);
    }

    function _defaultParams() internal pure returns (Rebalancer.Params memory) {
        return Rebalancer.Params({
            active: true,
            targetBps: 8000,
            bandBps: 500,
            maxCorrectionBps: 1000,
            minTradeEurc: 20e6,
            interval: 1 days,
            maxSlippageBps: 100
        });
    }

    function _setUser(address user, uint256 cash, uint256 btc, Rebalancer.Params memory p) internal {
        if (cash > 0) eurc.mint(user, cash);
        if (btc > 0) cbbtc.mint(user, btc);
        vm.startPrank(user);
        eurc.approve(address(r), type(uint256).max);
        cbbtc.approve(address(r), type(uint256).max);
        r.setParams(p);
        vm.stopPrank();
    }
}

// ─── Unit ──────────────────────────────────────────────────────────────────────────────────────────────────

contract RebalancerTest is RebalancerTestBase {
    // setParams ──────────────────────────────────────────────────────────────────────────────────────────

    function test_setParams_storesAndRegisters() public {
        Rebalancer.Params memory p = _defaultParams();
        vm.expectEmit(true, false, false, true, address(r));
        emit Rebalancer.ParamsUpdated(alice, p);
        vm.prank(alice);
        r.setParams(p);

        (bool active, uint16 target, uint16 band, uint16 cap, uint64 minTrade, uint32 interval, uint16 slip) =
            r.params(alice);
        assertTrue(active);
        assertEq(target, 8000);
        assertEq(band, 500);
        assertEq(cap, 1000);
        assertEq(minTrade, 20e6);
        assertEq(interval, 1 days);
        assertEq(slip, 100);
        assertEq(r.ownerCount(), 1);
        assertEq(r.owners(0, 10)[0], alice);
    }

    function test_setParams_registersOnlyOnce() public {
        Rebalancer.Params memory p = _defaultParams();
        vm.startPrank(alice);
        r.setParams(p);
        p.active = false;
        r.setParams(p);
        p.targetBps = 5000;
        r.setParams(p);
        vm.stopPrank();
        assertEq(r.ownerCount(), 1);
        (bool active, uint16 target,,,,,) = r.params(alice);
        assertFalse(active);
        assertEq(target, 5000);
    }

    function test_setParams_boundaryValuesAccepted() public {
        Rebalancer.Params memory p = _defaultParams();
        vm.startPrank(alice);
        p.targetBps = 500;
        r.setParams(p);
        p.targetBps = 9500;
        r.setParams(p);
        // Ondergrens is sinds MIN_BAND_BPS 125 (was 1): een band onder het maximale verlies per run mag niet meer.
        p.bandBps = 125;
        r.setParams(p);
        p.bandBps = 9999;
        r.setParams(p);
        p.maxCorrectionBps = 10;
        r.setParams(p);
        p.maxCorrectionBps = 10_000;
        r.setParams(p);
        p.minTradeEurc = 20e6;
        r.setParams(p);
        p.interval = 1 hours;
        r.setParams(p);
        p.maxSlippageBps = 60;
        r.setParams(p);
        p.maxSlippageBps = 100;
        r.setParams(p);
        vm.stopPrank();
    }

    function test_setParams_rejectsTargetOutOfRange() public {
        Rebalancer.Params memory p = _defaultParams();
        p.targetBps = 400;
        _expectInvalid(p);
        p.targetBps = 9600;
        _expectInvalid(p);
        p.targetBps = 0;
        _expectInvalid(p);
    }

    function test_setParams_rejectsTargetNotMultipleOf100() public {
        Rebalancer.Params memory p = _defaultParams();
        p.targetBps = 8050;
        _expectInvalid(p);
        p.targetBps = 8001;
        _expectInvalid(p);
    }

    function test_setParams_rejectsBand() public {
        Rebalancer.Params memory p = _defaultParams();
        p.bandBps = 0;
        _expectInvalid(p);
        p.bandBps = 1;
        _expectInvalid(p);
        p.bandBps = 10_000;
        _expectInvalid(p);
    }

    /// @notice MIN_BAND_BPS = FEE_BPS + MAX_SLIPPAGE_BPS: 124 revert, 125 mag.
    function test_setParams_minBandBps() public {
        assertEq(r.MIN_BAND_BPS(), r.FEE_BPS() + r.MAX_SLIPPAGE_BPS());
        Rebalancer.Params memory p = _defaultParams();
        p.bandBps = 124;
        _expectInvalid(p);
        p.bandBps = 125;
        vm.prank(alice);
        r.setParams(p);
        (,, uint16 band,,,,) = r.params(alice);
        assertEq(band, 125);
    }

    function test_setParams_rejectsMaxCorrection() public {
        Rebalancer.Params memory p = _defaultParams();
        p.maxCorrectionBps = 0;
        _expectInvalid(p);
        p.maxCorrectionBps = 9; // onder MIN_CORRECTION_BPS
        _expectInvalid(p);
        p.maxCorrectionBps = 10_001;
        _expectInvalid(p);
    }

    /// @dev H-2 / L-1: de dust-configuratie uit de audit (minTrade 1, cap 1 bps) is niet meer te zetten.
    function test_setParams_rejectsMinTradeBelowFloor() public {
        Rebalancer.Params memory p = _defaultParams();
        p.minTradeEurc = 0;
        _expectInvalid(p);
        p.minTradeEurc = 1;
        _expectInvalid(p);
        p.minTradeEurc = 20e6 - 1;
        _expectInvalid(p);
        assertEq(r.MIN_TRADE_FLOOR(), 20e6);
        assertEq(r.MIN_CORRECTION_BPS(), 10);
        // De kleinste toegestane run dekt precies de keeperbeloning.
        assertEq(uint256(r.MIN_TRADE_FLOOR()) * r.FEE_BPS() / BPS, r.KEEPER_REWARD_EURC());
    }

    function test_setParams_rejectsIntervalBelowOneHour() public {
        Rebalancer.Params memory p = _defaultParams();
        p.interval = 1 hours - 1;
        _expectInvalid(p);
        p.interval = 0;
        _expectInvalid(p);
    }

    function test_setParams_rejectsSlippage() public {
        Rebalancer.Params memory p = _defaultParams();
        p.maxSlippageBps = 0;
        _expectInvalid(p);
        p.maxSlippageBps = 30; // oude ondergrens, nu onder MIN_SLIPPAGE_BPS (60)
        _expectInvalid(p);
        p.maxSlippageBps = 59;
        _expectInvalid(p);
        p.maxSlippageBps = 101;
        _expectInvalid(p);
    }

    function test_setParams_inactiveParamsStillValidated() public {
        Rebalancer.Params memory p = _defaultParams();
        p.active = false;
        p.bandBps = 0;
        _expectInvalid(p);
    }

    function _expectInvalid(Rebalancer.Params memory p) internal {
        vm.expectRevert(Rebalancer.InvalidParams.selector);
        vm.prank(alice);
        r.setParams(p);
    }

    // owners / ownerCount ────────────────────────────────────────────────────────────────────────────────

    function test_owners_pagination() public {
        address[5] memory users;
        for (uint256 i = 0; i < 5; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));
            vm.prank(users[i]);
            r.setParams(_defaultParams());
        }
        assertEq(r.ownerCount(), 5);

        address[] memory page = r.owners(0, 2);
        assertEq(page.length, 2);
        assertEq(page[0], users[0]);
        assertEq(page[1], users[1]);

        page = r.owners(2, 2);
        assertEq(page.length, 2);
        assertEq(page[0], users[2]);
        assertEq(page[1], users[3]);

        page = r.owners(4, 2);
        assertEq(page.length, 1);
        assertEq(page[0], users[4]);

        page = r.owners(0, 100);
        assertEq(page.length, 5);

        assertEq(r.owners(5, 2).length, 0);
        assertEq(r.owners(6, 2).length, 0);
        assertEq(r.owners(0, 0).length, 0);
    }

    /// @dev L-A: `offset + limit` overflowde bij `offset >= 1` en `limit = type(uint256).max` (Panic 0x11).
    function test_owners_andDueOwners_maxLimitNeverOverflows() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        _setUser(bob, 1000e6, 0, _defaultParams());
        address carol = makeAddr("carol");
        _setUser(carol, 1000e6, 0, _defaultParams());

        address[] memory page = r.owners(1, type(uint256).max);
        assertEq(page.length, 2);
        assertEq(page[0], bob);
        assertEq(page[1], carol);
        assertEq(r.owners(0, type(uint256).max).length, 3);
        assertEq(r.owners(3, type(uint256).max).length, 0);

        address[] memory due = r.dueOwners(1, type(uint256).max);
        assertEq(due.length, 2);
        assertEq(due[0], bob);
        assertEq(due[1], carol);
        assertEq(r.dueOwners(2, type(uint256).max - 1).length, 1);
        assertEq(r.dueOwners(3, type(uint256).max).length, 0);
    }

    function test_owners_emptyRegistry() public view {
        assertEq(r.ownerCount(), 0);
        assertEq(r.owners(0, 10).length, 0);
    }

    // execute: happy paths ───────────────────────────────────────────────────────────────────────────────

    function test_execute_buy_exactAmounts() public {
        // 1.000 EURC, 0 cbBTC: drift 80%, cap 10% -> 100 EURC.
        _setUser(alice, 1000e6, 0, _defaultParams());

        uint256 amountIn = 100e6;
        uint256 fee = amountIn * 25 / BPS; // 250_000
        uint256 reward = 50_000;
        uint256 swapIn = amountIn - fee;
        uint256 amountOut = Math.mulDiv(swapIn, 1e8, PRICE); // 124_687

        vm.expectEmit(true, false, false, true, address(r));
        emit Rebalancer.Executed(alice, true, amountIn, fee, reward, keeper, amountOut, PRICE, 1000e6, 0);
        r.execute(alice, keeper);

        assertEq(eurc.balanceOf(alice), 900e6);
        assertEq(cbbtc.balanceOf(alice), amountOut);
        assertEq(eurc.balanceOf(keeper), reward);
        assertEq(eurc.balanceOf(treasury), fee - reward);
        assertEq(eurc.balanceOf(address(router)), swapIn);
        assertEq(eurc.balanceOf(address(r)), 0);
        assertEq(cbbtc.balanceOf(address(r)), 0);
        assertEq(r.lastExecutedAt(alice), uint64(START));
        assertEq(router.lastRecipient(), alice);
        assertEq(router.lastAmountIn(), swapIn);
        assertEq(router.lastAmountOutMinimum(), amountOut * (BPS - 100) / BPS);
        assertEq(
            router.lastPath(), abi.encodePacked(address(eurc), uint24(500), address(usdc), uint24(500), address(cbbtc))
        );
    }

    function test_execute_sell_exactAmounts() public {
        // 0 EURC, 0,0125 cbBTC (= 1.000 EURC): drift 20%, cap 10% -> 100 EURC = 125_000 sats.
        _setUser(alice, 0, 1_250_000, _defaultParams());

        uint256 amountIn = 125_000;
        uint256 received = Math.mulDiv(amountIn, PRICE, 1e8); // 100e6
        uint256 fee = received * 25 / BPS; // 250_000
        uint256 reward = 50_000;
        uint256 amountOut = received - fee;

        vm.expectEmit(true, false, false, true, address(r));
        emit Rebalancer.Executed(alice, false, amountIn, fee, reward, keeper, amountOut, PRICE, 1000e6, 10_000);
        r.execute(alice, keeper);

        assertEq(cbbtc.balanceOf(alice), 1_250_000 - amountIn);
        assertEq(eurc.balanceOf(alice), amountOut);
        assertEq(eurc.balanceOf(keeper), reward);
        assertEq(eurc.balanceOf(treasury), fee - reward);
        assertEq(cbbtc.balanceOf(address(router)), amountIn);
        assertEq(eurc.balanceOf(address(r)), 0);
        assertEq(cbbtc.balanceOf(address(r)), 0);
        assertEq(r.lastExecutedAt(alice), uint64(START));
        assertEq(router.lastRecipient(), address(r));
        assertEq(router.lastAmountOutMinimum(), received * (BPS - 100) / BPS);
        assertEq(
            router.lastPath(), abi.encodePacked(address(cbbtc), uint24(500), address(usdc), uint24(500), address(eurc))
        );
    }

    function test_execute_rewardCappedByFee() public {
        // Vroeger kon verkoop-slippage de fee onder de beloning duwen: 150 EURC in cbBTC, cap 10% = 15 < vloer 20
        // -> verkoop 25_000 sats (20 EURC); router levert 1% minder (19,8 EURC), fee was 49_500. Sinds L-B telt
        // de fee over max(ontvangen, verwacht) = 20 EURC -> 50_000, precies de beloning. Een fee onder de beloning
        // is via `execute` dus niet meer te bereiken; de begrenzing zelf staat in test_takeFee_cappedAtMaxFee.
        _setUser(alice, 0, 187_500, _defaultParams());
        router.setSlippageBps(100);
        r.execute(alice, keeper);
        assertEq(cbbtc.balanceOf(alice), 187_500 - 25_000);
        assertEq(eurc.balanceOf(keeper), 50_000);
        assertEq(eurc.balanceOf(treasury), 0);
        assertEq(eurc.balanceOf(alice), 19_800_000 - 50_000);
    }

    function test_execute_rewardToZeroSendsWholeFeeToTreasury() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        vm.expectEmit(true, false, false, true, address(r));
        emit Rebalancer.Executed(
            alice, true, 100e6, 250_000, 0, address(0), Math.mulDiv(99_750_000, 1e8, PRICE), PRICE, 1000e6, 0
        );
        r.execute(alice, address(0));
        assertEq(eurc.balanceOf(treasury), 250_000);
    }

    function test_execute_sellWithRewardToZero() public {
        _setUser(alice, 0, 1_250_000, _defaultParams());
        r.execute(alice, address(0));
        assertEq(eurc.balanceOf(treasury), 250_000);
        assertEq(eurc.balanceOf(alice), 99_750_000);
    }

    function test_execute_anyoneMayCall() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        vm.prank(bob);
        r.execute(alice, bob);
        assertEq(eurc.balanceOf(bob), 50_000);
    }

    function test_execute_boundedByAllowance() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        vm.prank(alice);
        eurc.approve(address(r), 40e6);
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, 40e6); // L-C: wat execute werkelijk handelt, niet de correctie van 100 EURC
        vm.expectEmit(true, false, false, false, address(r));
        emit Rebalancer.Executed(alice, true, 40e6, 0, 0, address(0), 0, 0, 0, 0);
        r.execute(alice, address(0));
        assertEq(eurc.balanceOf(alice), 960e6);
    }

    function test_execute_sellBoundedByAllowance() public {
        _setUser(alice, 0, 1_250_000, _defaultParams());
        vm.prank(alice);
        cbbtc.approve(address(r), 100_000);
        r.execute(alice, address(0));
        assertEq(cbbtc.balanceOf(alice), 1_150_000);
    }

    function test_execute_boundedByBalance() public {
        // De correctie is wiskundig nooit groter dan het saldo; controleer dat het saldo de bovengrens is.
        Rebalancer.Params memory p = _defaultParams();
        p.targetBps = 9500;
        p.maxCorrectionBps = 10_000;
        _setUser(alice, 100e6, 0, p);
        r.execute(alice, address(0));
        assertEq(eurc.balanceOf(alice), 5e6);
        assertEq(eurc.balanceOf(address(r)), 0);

        p.targetBps = 500;
        _setUser(bob, 0, 125_000, p);
        r.execute(bob, address(0));
        assertEq(cbbtc.balanceOf(bob), 6_250);
        assertEq(cbbtc.balanceOf(address(r)), 0);
    }

    function test_execute_allowanceBelowMinTradeIsNothingToDo() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        vm.prank(alice);
        eurc.approve(address(r), 20e6 - 1);
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        r.execute(alice, address(0));
    }

    function test_execute_secondRunAfterIntervalUsesNewState() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        r.execute(alice, keeper);
        vm.warp(START + 1 days);
        _setPrice(PRICE);
        r.execute(alice, keeper);
        assertEq(r.lastExecutedAt(alice), uint64(START + 1 days));
        // Tweede run: total = 900 + 124_687 sats * 80_000 = 900e6 + 99_749_600 -> cap 10% = 99_974_960.
        assertEq(eurc.balanceOf(alice), 900e6 - 99_974_960);
    }

    // execute: reverts ───────────────────────────────────────────────────────────────────────────────────

    function test_execute_revertsInactiveWhenUnknown() public {
        vm.expectRevert(Rebalancer.Inactive.selector);
        r.execute(alice, keeper);
    }

    function test_execute_revertsInactiveWhenDeactivated() public {
        Rebalancer.Params memory p = _defaultParams();
        p.active = false;
        _setUser(alice, 1000e6, 0, p);
        vm.expectRevert(Rebalancer.Inactive.selector);
        r.execute(alice, keeper);
    }

    function test_execute_revertsNotDue() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        r.execute(alice, keeper);
        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(alice, keeper);

        vm.warp(START + 1 days - 1);
        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(alice, keeper);

        vm.warp(START + 1 days);
        _setPrice(PRICE);
        r.execute(alice, keeper);
    }

    function test_execute_revertsNothingToDoWithinBand() public {
        // 200 EURC + 0,01 cbBTC (800 EURC): fractie exact 80%.
        _setUser(alice, 200e6, 1_000_000, _defaultParams());
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        r.execute(alice, keeper);

        // 240 EURC + 760 EURC in cbBTC: drift 4% < band 5%.
        _setUser(bob, 240e6, 950_000, _defaultParams());
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        r.execute(bob, keeper);
    }

    function test_execute_revertsNothingToDoAtBandEdge() public {
        // drift precies 5% = band -> niets (<=).
        _setUser(alice, 250e6, 937_500, _defaultParams());
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        r.execute(alice, keeper);
    }

    function test_execute_revertsNothingToDoBelowMinTrade() public {
        // 30 EURC + 70 EURC cbBTC: correctie 10 EURC < min 20.
        _setUser(alice, 30e6, 87_500, _defaultParams());
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        r.execute(alice, keeper);
    }

    function test_execute_revertsNothingToDoZeroAllowance() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        vm.prank(alice);
        eurc.approve(address(r), 0);
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        r.execute(alice, keeper);
    }

    function test_execute_revertsNothingToDoZeroBalance() public {
        _setUser(alice, 0, 0, _defaultParams());
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        r.execute(alice, keeper);
    }

    function test_execute_revertsSequencerDownAnswerOne() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        sequencer.set(1, START - 1 days, START - 1 days);
        vm.expectRevert(Rebalancer.SequencerDown.selector);
        r.execute(alice, keeper);
    }

    /// @dev L-9: een niet-geïnitialiseerde ronde (startedAt == 0) van de uptime-feed telt niet als "up".
    function test_execute_revertsSequencerDownWhenStartedAtZero() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        sequencer.set(0, 0, 0);
        vm.expectRevert(Rebalancer.SequencerDown.selector);
        r.execute(alice, keeper);
        vm.expectRevert(Rebalancer.SequencerDown.selector);
        r.quote();
        (bool due,) = r.isDue(alice);
        assertFalse(due);
        assertEq(r.dueOwners(0, 10).length, 0);

        sequencer.set(0, START - 1 days, START - 1 days);
        r.execute(alice, keeper);
    }

    function test_execute_revertsSequencerDownWithinGrace() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        sequencer.set(0, START - 1 hours + 1, START - 1 hours + 1);
        vm.expectRevert(Rebalancer.SequencerDown.selector);
        r.execute(alice, keeper);

        sequencer.set(0, START - 1 hours, START - 1 hours);
        r.execute(alice, keeper);
    }

    function test_execute_revertsStaleFeedCbbtc() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        feedBtc.set(80_000e8, START, START - 1501);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.StaleFeed.selector, address(feedBtc)));
        r.execute(alice, keeper);

        feedBtc.set(80_000e8, START, START - 1500);
        r.execute(alice, keeper);
    }

    function test_execute_revertsStaleFeedWhenUpdatedAtInFuture() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        feedBtc.set(80_000e8, START, START + 1);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.StaleFeed.selector, address(feedBtc)));
        r.execute(alice, keeper);

        feedBtc.set(80_000e8, START, START);
        feedEurc.set(1e8, START, START + 1);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.StaleFeed.selector, address(feedEurc)));
        r.execute(alice, keeper);
    }

    function test_execute_revertsStaleFeedEurc() public {
        // M-2: uurfeed (0x9867…01e0) met 15 minuten marge.
        assertEq(r.MAX_AGE_EURC(), 4500);
        _setUser(alice, 1000e6, 0, _defaultParams());
        feedEurc.set(1e8, START, START - 4501);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.StaleFeed.selector, address(feedEurc)));
        r.execute(alice, keeper);

        feedEurc.set(1e8, START, START - 4500);
        r.execute(alice, keeper);
    }

    function test_execute_revertsInvalidFeedAnswer() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        feedBtc.set(0, START, START);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.InvalidFeedAnswer.selector, address(feedBtc)));
        r.execute(alice, keeper);

        feedBtc.set(80_000e8, START, START);
        feedEurc.set(-1, START, START);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.InvalidFeedAnswer.selector, address(feedEurc)));
        r.execute(alice, keeper);
    }

    function test_execute_revertsWhenQuoteRoundsToZero() public {
        // cbBTC/USD = 1e-8 en EURC/USD = 1: 1 * 1e6 / 1e8 = 0. Beide answers zijn > 0, dus alleen de
        // productcheck vangt dit.
        _setUser(alice, 1000e6, 0, _defaultParams());
        feedBtc.set(1, START, START);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.InvalidFeedAnswer.selector, address(feedBtc)));
        r.quote();
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.InvalidFeedAnswer.selector, address(feedBtc)));
        r.execute(alice, keeper);
        (bool due,) = r.isDue(alice);
        assertFalse(due);
    }

    // spot-vs-oracle ────────────────────────────────────────────────────────────────────────────────────

    function test_spot_matchesFeedsAcrossBothPools() public {
        // Zelfde koers, andere weg: EURC/USD 1,16 en USDC/cbBTC 92.800 USDC -> 80.000 EURC per cbBTC.
        assertApproxEqAbs(r.spot(), PRICE, 1);
        feedEurc.set(1.16e8, START, START);
        feedBtc.set(92_800e8, START, START);
        poolEurcUsdc.setPrice(1e6, 1.16e6);
        poolUsdcCbbtc.setPrice(92_800e6, 1e8);
        assertEq(r.quote(), PRICE);
        assertApproxEqAbs(r.spot(), PRICE, 1);
        assertEq(r.quoteChecked(), PRICE);
    }

    function test_spot_pairsWithReversedTokenOrder() public {
        // Pools met omgekeerde token0/token1 geven dezelfde spot.
        MockUniswapV3Pool reversedEurc = new MockUniswapV3Pool(address(usdc), address(eurc));
        MockUniswapV3Pool reversedBtc = new MockUniswapV3Pool(address(cbbtc), address(usdc));
        reversedEurc.setPrice(1e6, 1e6);
        reversedBtc.setPrice(1e8, PRICE);
        factory.setPool(address(usdc), address(eurc), 500, address(reversedEurc));
        factory.setPool(address(cbbtc), address(usdc), 500, address(reversedBtc));
        Rebalancer.Deployment memory d = _deployment();
        d.poolEurcUsdc = address(reversedEurc);
        d.poolUsdcCbbtc = address(reversedBtc);
        Rebalancer r2 = new Rebalancer(d);
        assertApproxEqAbs(r2.spot(), PRICE, 1);
        assertEq(r2.quoteChecked(), PRICE);
    }

    function test_execute_revertsWhenSpotDeviatesFromOracle() public {
        _setUser(alice, 1000e6, 0, _defaultParams());

        _setSpot(PRICE * (BPS + 51) / BPS);
        uint256 spotUp = r.spot();
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.SpotDeviatesFromOracle.selector, spotUp, PRICE));
        r.execute(alice, keeper);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.SpotDeviatesFromOracle.selector, spotUp, PRICE));
        r.quoteChecked();
        (bool due, int256 delta) = r.isDue(alice);
        assertFalse(due);
        assertEq(delta, 0);
        assertEq(r.dueOwners(0, 10).length, 0);
        assertEq(r.lastExecutedAt(alice), 0);

        _setSpot(PRICE * (BPS - 51) / BPS);
        uint256 spotDown = r.spot();
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.SpotDeviatesFromOracle.selector, spotDown, PRICE));
        r.execute(alice, keeper);
        (due,) = r.isDue(alice);
        assertFalse(due);

        // Precies op de grens (0,5%) mag wel; de sqrt-afronding maakt de spot hooguit 1 eenheid lager.
        _setSpot(PRICE * (BPS + 50) / BPS);
        (due,) = r.isDue(alice);
        assertTrue(due);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 900e6);
    }

    function test_execute_spotCheckIgnoresPoolFeesOnly() public {
        // Alleen de EURC/USDC-pool 0,4% verschoven: onder de grens, run gaat door.
        _setUser(alice, 1000e6, 0, _defaultParams());
        poolEurcUsdc.setPrice(1e6, 1.004e6);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 900e6);
    }

    /// @dev Testgat oracle 4: alleen de EURC/USDC-pool meer dan 0,5% verschoven (de dunne pool, de echte
    ///      aanvalsroute) blokkeert de run ook.
    function test_execute_revertsWhenOnlyEurcPoolDeviates() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        poolEurcUsdc.setPrice(1e6, 1.006e6);
        uint256 spotPrice = r.spot();
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.SpotDeviatesFromOracle.selector, spotPrice, PRICE));
        r.execute(alice, keeper);
        (bool due,) = r.isDue(alice);
        assertFalse(due);

        poolEurcUsdc.setPrice(1.006e6, 1e6);
        spotPrice = r.spot();
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.SpotDeviatesFromOracle.selector, spotPrice, PRICE));
        r.execute(alice, keeper);
    }

    /// @dev Testgat oracle 5 (ORC-3): feed en spot bewegen los van elkaar. Feed +0,3% en spot -0,3% is samen
    ///      0,6% en blokkeert; feed +0,3% met spot +0,1% (nieuwe EURC-feed, deviatie 0,1%) niet.
    function test_execute_feedAndSpotDivergeIndependently() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        feedBtc.set(int256(PRICE * 1e8 / 1e6) * 1003 / 1000, START, START);
        _setSpot(PRICE * 997 / 1000);
        (bool due,) = r.isDue(alice);
        assertFalse(due, "0,6% uit elkaar: geblokkeerd");
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.SpotDeviatesFromOracle.selector, r.spot(), r.quote()));
        r.execute(alice, keeper);

        _setSpot(PRICE * 1001 / 1000);
        (due,) = r.isDue(alice);
        assertTrue(due, "0,2% uit elkaar: toegestaan");
        r.execute(alice, keeper);
    }

    /// @dev M-1: de spot wordt ook ná de swap gecontroleerd. Een run waarvan de eigen prijsimpact (of een
    ///      voorschuiving plus impact) de spot buiten 0,5% van de oracle brengt, revert alsnog en boekt niets.
    function test_execute_revertsWhenSpotDeviatesAfterSwap() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        // Vooraf +0,4% (toegestaan); de swap zelf schuift de pool naar +0,6%.
        poolEurcUsdc.setPrice(1e6, 1.004e6);
        router.setPoolShift(poolEurcUsdc, 1e6, 1.006e6);
        (bool due,) = r.isDue(alice);
        assertTrue(due, "vooraf binnen de grens");
        vm.expectPartialRevert(Rebalancer.SpotDeviatesFromOracle.selector);
        r.execute(alice, keeper);
        assertEq(r.lastExecutedAt(alice), 0);
        assertEq(eurc.balanceOf(alice), 1000e6, "niets geboekt");

        // Verkoopkant: zelfde regel.
        _setUser(bob, 0, 1_250_000, _defaultParams());
        router.setPoolShift(poolEurcUsdc, 1.006e6, 1e6);
        vm.expectPartialRevert(Rebalancer.SpotDeviatesFromOracle.selector);
        r.execute(bob, keeper);
        assertEq(cbbtc.balanceOf(bob), 1_250_000);

        // Impact die binnen beide grenzen blijft mag wel: 0,40% -> 0,44% is binnen 0,5% van de oracle en binnen
        // MAX_BLOCK_MOVE_BPS van de koers aan het begin van het blok. (0,4% -> 0,5% zou nu op het blokvenster stranden.)
        router.setPoolShift(poolEurcUsdc, 1e6, 1.0044e6);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 900e6);
    }

    /// @dev Testgat oracle 9: extreme sqrtPriceX96 (MIN/MAX_SQRT_RATIO van Uniswap) geeft geen Panic naar
    ///      buiten via isDue/dueOwners; execute revert netjes.
    function test_spot_extremeSqrtPriceNeverPanicsInViews() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        uint160[2] memory extremes =
            [uint160(4_295_128_739), uint160(1461446703485210103287273052203988822378723970342)];
        for (uint256 i = 0; i < 2; i++) {
            poolUsdcCbbtc.setSqrtPriceX96(extremes[i]);
            (bool due, int256 delta) = r.isDue(alice);
            assertFalse(due);
            assertEq(delta, 0);
            assertEq(r.dueOwners(0, 10).length, 0);
            vm.expectRevert();
            r.execute(alice, keeper);
            poolEurcUsdc.setSqrtPriceX96(extremes[i]);
            (due,) = r.isDue(alice);
            assertFalse(due);
            assertEq(r.dueOwners(0, 10).length, 0);
            _setSpot(PRICE);
        }
        (bool dueAgain,) = r.isDue(alice);
        assertTrue(dueAgain);
    }

    /// @dev Lead 10: bij sqrtPriceX96 < 2^48 was ratioX96 = sqrtPriceX96² / 2^96 gelijk aan 0 en deelde `_spotOut`
    ///      door 0 (Panic 0x12). Met ratioX128 blijft de spot berekenbaar; de run revert netjes op de spotcheck.
    function test_spot_smallSqrtPriceDoesNotDivideByZero() public {
        uint160 small = uint160(1 << 40);
        assertEq(Math.mulDiv(small, small, 1 << 96), 0, "opzet: de oude ratioX96 is 0");
        _setUser(alice, 1000e6, 0, _defaultParams());

        // USDC/cbBTC-pool: cbBTC is token1, dus usdcPerBtc = 1e8 * 2^128 / 2^16; EURC/USDC staat op 1:1.
        poolUsdcCbbtc.setSqrtPriceX96(small);
        assertEq(r.spot(), 1e8 << 112);
        // EURC/USDC-pool: USDC is token1, dus EURC = usdcPerBtc * 2^128 / 2^16.
        _setSpot(PRICE);
        poolEurcUsdc.setSqrtPriceX96(small);
        assertEq(r.spot(), Math.mulDiv(PRICE, 1 << 128, 1 << 16));

        uint256 spotPrice = r.spot();
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.SpotDeviatesFromOracle.selector, spotPrice, PRICE));
        r.execute(alice, keeper);
        (bool due, int256 delta) = r.isDue(alice);
        assertFalse(due);
        assertEq(delta, 0);
    }

    /// @dev Testgat oracle 8 (ORC-7): bij een EURC-depeg (feed 0,90 USD, pool volgt) stijgt de koers in EURC,
    ///      stijgt het cbBTC-aandeel en verkoopt de volgende run cbBTC voor de gedepegde EURC. Ontwerpkeuze
    ///      (EURC als numeraire); hier vastgelegd zodat het niet ongemerkt verandert.
    function test_isDue_eurcDepegTurnsHoldIntoSell() public {
        // 2.000 EURC + 0,1 cbBTC: exact 80/20 bij EURC/USD = 1, band 1,25% (MIN_BAND_BPS; was 1%, dat mag niet meer).
        // De depeg duwt het aandeel naar ~81,6%, dus ook buiten deze band.
        Rebalancer.Params memory p = _defaultParams();
        p.bandBps = 125;
        _setUser(alice, 2000e6, 10_000_000, p);
        (bool due,) = r.isDue(alice);
        assertFalse(due);

        feedEurc.set(0.9e8, START, START);
        poolEurcUsdc.setPrice(1e6, 0.9e6);
        uint256 price = r.quote();
        assertEq(price, Math.mulDiv(80_000e8, 1e6, 0.9e8), "koers in EURC stijgt ~11%");
        assertEq(r.quoteChecked(), price);
        int256 delta;
        (due, delta) = r.isDue(alice);
        assertTrue(due);
        assertLt(delta, 0, "verkoopt cbBTC voor gedepegde EURC");
    }

    // sweep en rewardTo ────────────────────────────────────────────────────────────────────────────────

    function test_sweep_sendsFullBalanceToTreasury() public {
        eurc.mint(address(r), 123e6);
        cbbtc.mint(address(r), 4_567);
        vm.prank(bob);
        r.sweep(eurc);
        assertEq(eurc.balanceOf(address(r)), 0);
        assertEq(eurc.balanceOf(treasury), 123e6);
        assertEq(cbbtc.balanceOf(address(r)), 4_567);
        r.sweep(cbbtc);
        assertEq(cbbtc.balanceOf(address(r)), 0);
        assertEq(cbbtc.balanceOf(treasury), 4_567);
        // Leeg saldo: geen transfer, geen revert.
        r.sweep(eurc);
        assertEq(eurc.balanceOf(treasury), 123e6);
    }

    /// @dev M-6: een geblacklist TREASURY laat de rebalance doorgaan; het treasury-deel van de fee blijft in het
    ///      contract (FeeRetained) en `sweep` haalt het op zodra de blacklist is opgeheven.
    function test_execute_continuesWhenTreasuryBlacklistedAndSweepRecoversFee() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        eurc.setBlacklisted(treasury, true);

        uint256 amountOut = Math.mulDiv(99_750_000, 1e8, PRICE);
        vm.expectEmit(false, false, false, true, address(r));
        emit Rebalancer.FeeRetained(200_000);
        vm.expectEmit(true, false, false, true, address(r));
        emit Rebalancer.Executed(alice, true, 100e6, 250_000, 50_000, keeper, amountOut, PRICE, 1000e6, 0);
        r.execute(alice, keeper);

        assertEq(eurc.balanceOf(alice), 900e6, "run is doorgegaan");
        assertEq(cbbtc.balanceOf(alice), amountOut);
        assertEq(eurc.balanceOf(keeper), 50_000, "beloning gewoon betaald");
        assertEq(eurc.balanceOf(treasury), 0);
        assertEq(eurc.balanceOf(address(r)), 200_000, "treasury-deel blijft in het contract");
        assertEq(r.lastExecutedAt(alice), uint64(START));

        // Zolang de treasury geblacklist is, kan sweep het niet kwijt; daarna wel.
        vm.expectRevert("Blacklistable: account is blacklisted");
        r.sweep(eurc);
        eurc.setBlacklisted(treasury, false);
        r.sweep(eurc);
        assertEq(eurc.balanceOf(address(r)), 0);
        assertEq(eurc.balanceOf(treasury), 200_000);
    }

    /// @dev M-6, verkoopkant en rewardTo == address(0): de volledige fee blijft achter, de owner krijgt exact
    ///      received - fee.
    function test_execute_sellRetainsWholeFeeWhenTreasuryBlacklisted() public {
        _setUser(alice, 0, 1_250_000, _defaultParams());
        eurc.setBlacklisted(treasury, true);
        vm.expectEmit(false, false, false, true, address(r));
        emit Rebalancer.FeeRetained(250_000);
        r.execute(alice, address(0));
        assertEq(eurc.balanceOf(alice), 99_750_000);
        assertEq(eurc.balanceOf(address(r)), 250_000);
        assertEq(eurc.balanceOf(treasury), 0);

        // Een volgende run telt het achtergebleven saldo niet mee als "ontvangen".
        vm.warp(START + 1 days);
        _setPrice(PRICE);
        eurc.setBlacklisted(treasury, false);
        _setUser(bob, 0, 1_250_000, _defaultParams());
        r.execute(bob, address(0));
        assertEq(eurc.balanceOf(bob), 99_750_000);
        assertEq(eurc.balanceOf(address(r)), 250_000, "restant van alice staat er nog");
        assertEq(eurc.balanceOf(treasury), 250_000, "fee van bob is wel aangekomen");
    }

    /// @dev M-6: een geblacklist rewardTo kost de aanroeper zijn beloning, niet de owner zijn run; de hele fee
    ///      gaat dan naar de treasury en het event meldt reward 0.
    function test_execute_rewardFallsBackToTreasuryWhenRewardToBlacklisted() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        eurc.setBlacklisted(keeper, true);
        uint256 amountOut = Math.mulDiv(99_750_000, 1e8, PRICE);
        vm.expectEmit(true, false, false, true, address(r));
        emit Rebalancer.Executed(alice, true, 100e6, 250_000, 0, keeper, amountOut, PRICE, 1000e6, 0);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(keeper), 0);
        assertEq(eurc.balanceOf(treasury), 250_000);
        assertEq(eurc.balanceOf(address(r)), 0);
    }

    /// @dev M-6: met TREASURY als rewardTo falen beloning én treasury-transfer zodra de treasury geblacklist
    ///      is, en blijft de hele fee in het contract. De run wordt wél geboekt en `sweep` haalt de fee later op.
    function test_execute_continuesWhenTreasuryBlacklisted() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        eurc.setBlacklisted(treasury, true);
        vm.expectEmit(false, false, false, true, address(r));
        emit Rebalancer.FeeRetained(250_000);
        r.execute(alice, treasury);
        assertEq(r.lastExecutedAt(alice), uint64(START));
        assertEq(eurc.balanceOf(address(r)), 250_000);
    }

    /// @dev Testgat execute 7: `sweep` roept willekeurige code aan met msg.sender = Rebalancer. `balanceOf` gaat
    ///      via STATICCALL (view in IERC20), dus een nep-token kan zelfs geen owner registreren: de poging revert
    ///      en er verandert niets.
    function test_sweep_maliciousTokenCannotChangeState() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        MaliciousSweepToken evil = new MaliciousSweepToken(r);
        vm.expectRevert();
        r.sweep(IERC20(address(evil)));
        assertEq(r.ownerCount(), 1);
        assertEq(eurc.balanceOf(alice), 1000e6);
        assertEq(eurc.balanceOf(address(r)), 0);
        assertEq(eurc.balanceOf(treasury), 0);
    }

    /// @dev Testgat execute 7 (EX-09), de schrijvende kant: `transfer` van een nep-token draait wél met
    ///      schrijfrechten. Terug de run van een due owner in via `execute` stuit op de reentrancy-guard; het enige
    ///      dat lukt is het nep-token zelf als owner registreren (`_owners` vervuilen), zonder saldo of effect.
    function test_sweep_maliciousTokenReentryCanOnlyRegisterItself() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        ReentrantSweepToken evil = new ReentrantSweepToken(r, alice);

        r.sweep(IERC20(address(evil)));

        assertEq(
            bytes4(evil.executeRevertData()),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            "execute kwam binnen"
        );
        assertEq(eurc.balanceOf(alice), 1000e6);
        assertEq(r.lastExecutedAt(alice), 0);
        assertEq(r.ownerCount(), 2);
        assertEq(r.owners(1, 1)[0], address(evil), "nep-token staat als owner geregistreerd");
        (bool due,) = r.isDue(address(evil));
        assertFalse(due, "zonder saldo nooit due");
        assertEq(eurc.balanceOf(address(r)), 0);

        // De echte owner loopt daarna gewoon.
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 900e6);
    }

    function test_execute_rewardToSelfGoesToTreasury() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        vm.expectEmit(true, false, false, true, address(r));
        emit Rebalancer.Executed(
            alice, true, 100e6, 250_000, 0, address(0), Math.mulDiv(99_750_000, 1e8, PRICE), PRICE, 1000e6, 0
        );
        r.execute(alice, address(r));
        assertEq(eurc.balanceOf(address(r)), 0);
        assertEq(eurc.balanceOf(treasury), 250_000);
    }

    /// @dev L-2: spot op +0,5% (toegestaan) en 0,1% poolfees is samen 0,6% t.o.v. de oracle; met de nieuwe
    ///      ondergrens van 60 bps is zo'n run precies nog uitvoerbaar. Met 30 bps zou hij structureel reverten.
    function test_execute_minSlippageCoversSpotDeviationPlusPoolFees() public {
        Rebalancer.Params memory p = _defaultParams();
        p.maxSlippageBps = r.MIN_SLIPPAGE_BPS();
        assertEq(p.maxSlippageBps, 60);
        _setUser(alice, 1000e6, 0, p);
        _setSpot(PRICE * (BPS + 50) / BPS);
        router.setSlippageBps(60);
        (bool due,) = r.isDue(alice);
        assertTrue(due);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 900e6);

        router.setSlippageBps(61);
        _setUser(bob, 1000e6, 0, p);
        vm.expectRevert("Too little received");
        r.execute(bob, keeper);
    }

    /// @dev L-1: levert de router 0 cbBTC op (alleen mogelijk als amountOutMinimum door afronding 0 is), dan
    ///      revert de koop in plaats van EURC weg te geven. Hier geforceerd met een absurde koers.
    function test_execute_revertsNoOutputWhenBuyYieldsZero() public {
        uint256 hugePrice = 1e16; // 10 miljard EURC per cbBTC: 99,75 EURC koopt 0 sats
        _setPrice(hugePrice);
        router.setPrice(hugePrice);
        _setUser(alice, 1000e6, 0, _defaultParams());
        (bool due,) = r.isDue(alice);
        assertTrue(due);
        vm.expectRevert(Rebalancer.NoOutput.selector);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 1000e6);
        assertEq(r.lastExecutedAt(alice), 0);
    }

    function test_execute_revertsOnSlippageBuy() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        router.setSlippageBps(101);
        vm.expectRevert("Too little received");
        r.execute(alice, keeper);

        router.setSlippageBps(100);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(address(r)), 0);
    }

    function test_execute_revertsOnSlippageSell() public {
        _setUser(alice, 0, 1_250_000, _defaultParams());
        router.setSlippageBps(101);
        vm.expectRevert("Too little received");
        r.execute(alice, keeper);

        router.setSlippageBps(100);
        r.execute(alice, keeper);
        assertEq(cbbtc.balanceOf(address(r)), 0);
        // L-B: fee over max(ontvangen 99 EURC, verwacht 100 EURC), dus over de oraclewaarde.
        assertEq(eurc.balanceOf(keeper) + eurc.balanceOf(treasury), 100e6 * 25 / BPS);
        assertEq(eurc.balanceOf(alice), 99e6 - 100e6 * 25 / BPS);
    }

    /// @dev L-B, rekenvoorbeeld uit de audit: verkoop ter waarde van 20,000160 EURC, ontvangen 19,980159 EURC
    ///      (10 bps router-slippage). Vroeger was de fee 25 bps over `received` = 49.950, onder de beloning, en
    ///      kreeg de aanroeper alles. Nu is de fee 25 bps over de oraclewaarde = 50.000: precies de beloning, zoals
    ///      MIN_TRADE_FLOOR belooft. Iets boven de vloer (20,01 EURC) krijgt de treasury ook iets; vroeger niet.
    function test_execute_sellFeeFloorUsesExpectedOut() public {
        _sellAtValue(alice, 80_000_640_000, keeper); // 25.000 sats × 80.000,64 = 20,000160 EURC
        assertEq(eurc.balanceOf(keeper), 50_000, "beloning volledig");
        assertEq(eurc.balanceOf(treasury), 0, "fee is precies de beloning");
        assertEq(eurc.balanceOf(alice), 19_980_159 - 50_000);
        assertGt(19_980_159 * 25 / BPS, 0);
        assertLt(19_980_159 * 25 / BPS, 50_000, "opzet: oude fee lag onder de beloning");

        address keeper2 = makeAddr("keeper2");
        _sellAtValue(bob, 80_040_000_000, keeper2); // 25.000 sats × 80.040 = 20,010000 EURC, ontvangen 19,989990
        assertEq(eurc.balanceOf(keeper2), 50_000);
        assertEq(eurc.balanceOf(treasury), 25, "treasury krijgt > 0 (fee 50.025)");
        assertLe(19_989_990 * 25 / BPS, 50_000, "opzet: oude fee gaf de treasury 0");
    }

    /// @dev Verkoop van precies 25.000 sats (allowance) tegen `price`, met 10 bps router-slippage.
    function _sellAtValue(address user, uint256 price, address rewardTo) internal {
        _setPrice(price);
        router.setPrice(price);
        router.setSlippageBps(10);
        _setUser(user, 0, 1_250_000, _defaultParams());
        vm.prank(user);
        cbbtc.approve(address(r), 25_000);
        r.execute(user, rewardTo);
        assertEq(cbbtc.balanceOf(user), 1_250_000 - 25_000);
    }

    /// @dev L-B: de fee is begrensd op het ontvangen bedrag. Onbereikbaar via de router (minOut ligt hooguit
    ///      MAX_SLIPPAGE_BPS onder expectedOut), dus hier via een harness die `_takeFee` rechtstreeks aanroept.
    function test_takeFee_cappedAtMaxFee() public {
        RebalancerFeeHarness h = new RebalancerFeeHarness(_deployment());
        eurc.mint(address(h), 1_000e6);
        (uint256 fee, uint256 reward) = h.takeFee(1_000e6, 1_000, keeper);
        assertEq(fee, 1_000, "begrensd op maxFee");
        assertEq(reward, 1_000, "beloning begrensd op de fee");
        assertEq(eurc.balanceOf(keeper), 1_000);
        (fee, reward) = h.takeFee(1_000e6, type(uint256).max, address(0));
        assertEq(fee, 2_500_000);
        assertEq(reward, 0);
        assertEq(eurc.balanceOf(treasury), 2_500_000);
    }

    function test_execute_revertsWhenTokenPaused() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        eurc.setPaused(true);
        vm.expectRevert("Pausable: paused");
        r.execute(alice, keeper);
    }

    function test_execute_revertsWhenOwnerBlacklisted() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        eurc.setBlacklisted(alice, true);
        vm.expectRevert("Blacklistable: account is blacklisted");
        r.execute(alice, keeper);
        assertEq(r.lastExecutedAt(alice), 0);
        // Een revert houdt de owner due: het contract onthoudt mislukte pogingen niet. De wekkers simuleren
        // daarom eerst en houden zelf een cool-down per owner bij.
        (bool due,) = r.isDue(alice);
        assertTrue(due);
        assertEq(r.dueOwners(0, 10).length, 1);
    }

    function test_execute_lastExecutedAtNotSetOnRevert() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        router.setSlippageBps(200);
        vm.expectRevert("Too little received");
        r.execute(alice, keeper);
        assertEq(r.lastExecutedAt(alice), 0);
    }

    // isDue ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_isDue_falseWhenUnknownOrInactive() public {
        (bool due, int256 delta) = r.isDue(alice);
        assertFalse(due);
        assertEq(delta, 0);

        Rebalancer.Params memory p = _defaultParams();
        p.active = false;
        _setUser(alice, 1000e6, 0, p);
        (due, delta) = r.isDue(alice);
        assertFalse(due);
        assertEq(delta, 0);
    }

    function test_isDue_falseWhenNotDue() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        r.execute(alice, keeper);
        (bool due, int256 delta) = r.isDue(alice);
        assertFalse(due);
        assertEq(delta, 0);
        vm.warp(START + 1 days);
        _setPrice(PRICE);
        (due,) = r.isDue(alice);
        assertTrue(due);
    }

    function test_isDue_falseOnFeedFailureNeverReverts() public {
        _setUser(alice, 1000e6, 0, _defaultParams());

        sequencer.set(1, START - 1 days, START - 1 days);
        (bool due, int256 delta) = r.isDue(alice);
        assertFalse(due);
        assertEq(delta, 0);
        sequencer.set(0, START - 1 days, START - 1 days);

        feedBtc.set(80_000e8, START, START - 2000);
        (due, delta) = r.isDue(alice);
        assertFalse(due);
        assertEq(delta, 0);

        feedBtc.set(0, START, START);
        (due, delta) = r.isDue(alice);
        assertFalse(due);
        assertEq(delta, 0);

        // updatedAt in de toekomst -> StaleFeed in _readFeed, ook opgevangen.
        feedBtc.set(80_000e8, START, START + 1);
        (due, delta) = r.isDue(alice);
        assertFalse(due);
        assertEq(delta, 0);
    }

    function test_isDue_falseWithinBand() public {
        _setUser(alice, 200e6, 1_000_000, _defaultParams());
        (bool due, int256 delta) = r.isDue(alice);
        assertFalse(due);
        assertEq(delta, 0);
    }

    function test_isDue_falseBelowMinTradeAndZeroAllowance() public {
        _setUser(alice, 30e6, 87_500, _defaultParams());
        (bool due, int256 delta) = r.isDue(alice);
        assertFalse(due);
        assertEq(delta, 0);

        _setUser(bob, 1000e6, 0, _defaultParams());
        vm.prank(bob);
        eurc.approve(address(r), 0);
        (due, delta) = r.isDue(bob);
        assertFalse(due);
        assertEq(delta, 0);
    }

    function test_isDue_buyReturnsPositiveCorrection() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, 100e6);
    }

    function test_isDue_sellReturnsNegativeCorrection() public {
        _setUser(alice, 0, 1_250_000, _defaultParams());
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, -100e6);
    }

    /// @dev L-C: de delta is wat `execute` werkelijk verkoopt (begrensd op de allowance), niet de correctie van
    ///      100 EURC. Vroeger legde deze test het oude gedrag vast (delta -100 EURC).
    function test_isDue_deltaIsAllowanceBoundedAmount() public {
        _setUser(alice, 0, 1_250_000, _defaultParams());
        vm.prank(alice);
        cbbtc.approve(address(r), 30_000); // 24 EURC: boven de vloer, ver onder de correctie
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, -24e6);
        vm.expectEmit(true, false, false, false, address(r));
        emit Rebalancer.Executed(alice, false, 30_000, 0, 0, keeper, 0, 0, 0, 0);
        r.execute(alice, keeper);
        assertEq(cbbtc.balanceOf(alice), 1_250_000 - 30_000);
    }

    /// @dev L-C, voorbeeld uit de audit: wallet 10.000 EURC, correctie 1.000 EURC, allowance 20 EURC. `isDue`
    ///      meldde 1.000 EURC terwijl `execute` 20 EURC handelt; nu meldt het 20 EURC.
    function test_isDue_deltaMatchesExecutedAmountWhenAllowanceBinds() public {
        _setUser(alice, 10_000e6, 0, _defaultParams());
        (, int256 unbounded) = r.isDue(alice);
        assertEq(unbounded, 1_000e6, "opzet: correctie 1.000 EURC");
        vm.prank(alice);
        eurc.approve(address(r), 20e6);
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, 20e6);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 10_000e6 - uint256(delta), "execute handelt precies de gemelde delta");
    }

    // dueOwners ─────────────────────────────────────────────────────────────────────────────────────────

    function test_dueOwners_filtersAndPaginatesLikeIsDue() public {
        address[6] memory users;
        for (uint256 i = 0; i < 6; i++) {
            users[i] = makeAddr(string(abi.encodePacked("due", i)));
        }
        _setUser(users[0], 1000e6, 0, _defaultParams()); // due: kopen
        _setUser(users[1], 200e6, 1_000_000, _defaultParams()); // binnen band
        _setUser(users[2], 0, 1_250_000, _defaultParams()); // due: verkopen
        Rebalancer.Params memory inactive = _defaultParams();
        inactive.active = false;
        _setUser(users[3], 1000e6, 0, inactive); // inactief
        _setUser(users[4], 1000e6, 0, _defaultParams()); // net uitgevoerd -> niet due
        r.execute(users[4], keeper);
        _setUser(users[5], 1000e6, 0, _defaultParams()); // due, maar allowance 0
        vm.prank(users[5]);
        eurc.approve(address(r), 0);

        address[] memory due = r.dueOwners(0, 100);
        assertEq(due.length, 2);
        assertEq(due[0], users[0]);
        assertEq(due[1], users[2]);
        for (uint256 i = 0; i < 6; i++) {
            (bool isDueNow,) = r.isDue(users[i]);
            assertEq(isDueNow, i == 0 || i == 2, "dueOwners wijkt af van isDue");
        }

        due = r.dueOwners(0, 2);
        assertEq(due.length, 1);
        assertEq(due[0], users[0]);
        due = r.dueOwners(2, 2);
        assertEq(due.length, 1);
        assertEq(due[0], users[2]);
        assertEq(r.dueOwners(3, 3).length, 0);
        assertEq(r.dueOwners(6, 10).length, 0);
        assertEq(r.dueOwners(0, 0).length, 0);
    }

    function test_dueOwners_emptyOnFeedFailureNeverReverts() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        assertEq(r.dueOwners(0, 10).length, 1);
        sequencer.set(1, START - 1 days, START - 1 days);
        assertEq(r.dueOwners(0, 10).length, 0);
        sequencer.set(0, START - 1 days, START - 1 days);
        feedBtc.set(80_000e8, START, START - 2000);
        assertEq(r.dueOwners(0, 10).length, 0);
    }

    function test_dueOwners_emptyRegistry() public view {
        assertEq(r.dueOwners(0, 10).length, 0);
    }

    /// @dev Testgat execute 2 en mandaat 1: een wekker die pagina voor pagina door `dueOwners` loopt (zoals
    ///      keeper.ts, hier met pagina's van 5) bereikt elke due owner, ook nummer 6 en verder. Kleine wallets
    ///      met toegestane params (10 EURC, onder de vloer) staan ertussen, zijn nooit due en verdringen niemand.
    function test_dueOwners_pagingReachesEveryDueOwner() public {
        uint256 count = 12;
        uint256 pageSize = 5;
        address[] memory users = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            users[i] = makeAddr(string(abi.encodePacked("paged", i)));
            bool isSmallWallet = i % 2 == 0;
            _setUser(users[i], isSmallWallet ? 10e6 : 1000e6, 0, _defaultParams());
        }
        assertEq(r.dueOwners(0, count).length, count / 2);

        uint256 executed;
        for (uint256 offset = 0; offset < r.ownerCount(); offset += pageSize) {
            address[] memory page = r.dueOwners(offset, pageSize);
            for (uint256 j = 0; j < page.length; j++) {
                r.execute(page[j], keeper);
                executed++;
            }
        }

        assertEq(executed, count / 2, "niet elke due owner bereikt");
        for (uint256 i = 0; i < count; i++) {
            bool isSmallWallet = i % 2 == 0;
            assertEq(r.lastExecutedAt(users[i]), isSmallWallet ? 0 : uint64(START));
        }
        assertEq(eurc.balanceOf(users[count - 1]), 900e6, "de laatste owner is ook uitgevoerd");
        assertEq(r.dueOwners(0, count).length, 0, "na de ronde is niemand meer due");
    }

    // quote ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_quote_usesBothFeeds() public {
        assertEq(r.quote(), PRICE);
        feedEurc.set(1.1e8, START, START);
        assertEq(r.quote(), Math.mulDiv(80_000e8, 1e6, 1.1e8));
    }

    // retire ────────────────────────────────────────────────────────────────────────────────────────────

    function test_retire_revertsForNonTreasury() public {
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.NotTreasury.selector, alice));
        vm.prank(alice);
        r.retire();
        assertFalse(r.retired());
    }

    function test_retire_setsFlagAndEmits() public {
        assertFalse(r.retired());
        vm.expectEmit(false, false, false, true, address(r));
        emit Rebalancer.Retired();
        vm.prank(treasury);
        r.retire();
        assertTrue(r.retired());
    }

    function test_retire_secondCallReverts() public {
        vm.startPrank(treasury);
        r.retire();
        vm.expectRevert(Rebalancer.AlreadyRetired.selector);
        r.retire();
        vm.stopPrank();
        assertTrue(r.retired());
    }

    function test_retire_executeReverts() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        (bool due,) = r.isDue(alice);
        assertTrue(due);
        vm.prank(treasury);
        r.retire();
        vm.expectRevert(Rebalancer.ContractRetired.selector);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 1000e6, "geen fondsen bewogen");
        assertEq(r.lastExecutedAt(alice), 0);
        // De allowance staat nog bij de gebruiker; er is alleen niets meer dat hem kan gebruiken.
        assertEq(eurc.allowance(alice, address(r)), type(uint256).max);
    }

    function test_retire_isDueFalseAndDueOwnersEmpty() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        _setUser(bob, 1000e6, 0, _defaultParams());
        assertEq(r.dueOwners(0, 10).length, 2);
        vm.prank(treasury);
        r.retire();
        (bool due, int256 delta) = r.isDue(alice);
        assertFalse(due);
        assertEq(delta, 0);
        assertEq(r.dueOwners(0, 10).length, 0);
        // De registratie zelf blijft leesbaar.
        assertEq(r.ownerCount(), 2);
    }

    function test_retire_executeRevertsForEveryOwner() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        _setUser(bob, 1000e6, 0, _defaultParams());
        vm.prank(treasury);
        r.retire();

        vm.expectRevert(Rebalancer.ContractRetired.selector);
        r.execute(alice, keeper);
        vm.expectRevert(Rebalancer.ContractRetired.selector);
        r.execute(bob, keeper);

        assertEq(eurc.balanceOf(alice), 1000e6);
        assertEq(eurc.balanceOf(bob), 1000e6);
        assertEq(r.lastExecutedAt(alice), 0);
    }

    function test_retire_setParamsCanOnlyDeactivate() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        vm.prank(treasury);
        r.retire();

        // Intrekken werkt, ook voor iemand die nog nooit instellingen had.
        Rebalancer.Params memory p = _defaultParams();
        p.active = false;
        vm.expectEmit(true, false, false, true, address(r));
        emit Rebalancer.ParamsUpdated(alice, p);
        vm.prank(alice);
        r.setParams(p);
        (bool active,,,,,,) = r.params(alice);
        assertFalse(active);
        vm.prank(bob);
        r.setParams(p);
        assertEq(r.ownerCount(), 2);

        // Een actief mandaat zetten (nieuw of opnieuw) revert.
        p.active = true;
        vm.expectRevert(Rebalancer.ContractRetired.selector);
        vm.prank(alice);
        r.setParams(p);
        vm.expectRevert(Rebalancer.ContractRetired.selector);
        vm.prank(keeper);
        r.setParams(p);

        // Inactieve instellingen worden nog steeds gevalideerd.
        p.active = false;
        p.bandBps = 0;
        vm.expectRevert(Rebalancer.InvalidParams.selector);
        vm.prank(alice);
        r.setParams(p);
    }

    function test_retire_sweepStillWorks() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        eurc.setBlacklisted(treasury, true);
        r.execute(alice, keeper); // 0,20 EURC treasury-deel blijft achter (FeeRetained)
        assertEq(eurc.balanceOf(address(r)), 200_000);
        vm.prank(treasury);
        r.retire();
        eurc.setBlacklisted(treasury, false);
        cbbtc.mint(address(r), 4_567);
        vm.prank(bob);
        r.sweep(eurc);
        r.sweep(cbbtc);
        assertEq(eurc.balanceOf(address(r)), 0);
        assertEq(cbbtc.balanceOf(address(r)), 0);
        assertEq(eurc.balanceOf(treasury), 200_000);
        assertEq(cbbtc.balanceOf(treasury), 4_567);
    }

    // constructor ───────────────────────────────────────────────────────────────────────────────────────

    function test_constructor_rejectsZeroAddress() public {
        Rebalancer.Deployment memory d = _deployment();
        d.treasury = address(0);
        vm.expectRevert(Rebalancer.ZeroAddress.selector);
        new Rebalancer(d);
        d = _deployment();
        d.router = address(0);
        vm.expectRevert(Rebalancer.ZeroAddress.selector);
        new Rebalancer(d);
        d = _deployment();
        d.poolUsdcCbbtc = address(0);
        vm.expectRevert(Rebalancer.ZeroAddress.selector);
        new Rebalancer(d);
    }

    function test_constructor_rejectsNonContracts() public {
        address eoa = makeAddr("eoa");
        Rebalancer.Deployment memory d;
        for (uint256 i = 0; i < 9; i++) {
            d = _deployment();
            if (i == 0) d.eurc = eoa;
            if (i == 1) d.cbbtc = eoa;
            if (i == 2) d.usdc = eoa;
            if (i == 3) d.router = eoa;
            if (i == 4) d.feedCbbtcUsd = eoa;
            if (i == 5) d.feedEurcUsd = eoa;
            if (i == 6) d.sequencerFeed = eoa;
            if (i == 7) d.poolEurcUsdc = eoa;
            if (i == 8) d.poolUsdcCbbtc = eoa;
            vm.expectRevert(abi.encodeWithSelector(Rebalancer.NotAContract.selector, eoa));
            new Rebalancer(d);
        }
        // De treasury mag een EOA zijn.
        d = _deployment();
        d.treasury = eoa;
        new Rebalancer(d);
    }

    /// @dev L-4: beide feeds moeten 8 decimalen hebben; de omrekening deelt ze op elkaar.
    function test_constructor_rejectsFeedWithWrongDecimals() public {
        MockAggregator feed18 = new MockAggregator(18, "EURC / USD");
        Rebalancer.Deployment memory d = _deployment();
        d.feedEurcUsd = address(feed18);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedFeedDecimals.selector, address(feed18)));
        new Rebalancer(d);

        MockAggregator feed6 = new MockAggregator(6, "cbBTC / USD");
        d = _deployment();
        d.feedCbbtcUsd = address(feed6);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedFeedDecimals.selector, address(feed6)));
        new Rebalancer(d);

        // Allebei 18 is ook fout: de constante is 8, niet "gelijk aan elkaar".
        MockAggregator btc18 = new MockAggregator(18, "cbBTC / USD");
        d = _deployment();
        d.feedCbbtcUsd = address(btc18);
        d.feedEurcUsd = address(feed18);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedFeedDecimals.selector, address(btc18)));
        new Rebalancer(d);
    }

    /// @dev Review I-4: EURC 6, cbBTC 8 en USDC 6 decimalen; de eenheden en ondergrenzen zijn daarop vastgelegd.
    function test_constructor_rejectsTokenWithWrongDecimals() public {
        address[3] memory tokens = [address(eurc), address(cbbtc), address(usdc)];
        uint8[3] memory wrong = [uint8(18), 6, 8];
        for (uint256 i; i < 3; i++) {
            vm.mockCall(tokens[i], abi.encodeWithSignature("decimals()"), abi.encode(wrong[i]));
            vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedTokenDecimals.selector, tokens[i]));
            new Rebalancer(_deployment());
            vm.clearMockedCalls();
        }
        // Met de juiste decimalen gaat het door.
        new Rebalancer(_deployment());
    }

    /// @dev Review I-4: een token zonder `decimals()` is geen geldig token voor dit contract; de deploy revert.
    function test_constructor_rejectsTokenWithoutDecimals() public {
        vm.mockCallRevert(address(usdc), abi.encodeWithSignature("decimals()"), "");
        vm.expectRevert();
        new Rebalancer(_deployment());
    }

    function test_constructor_rejectsPoolWithWrongTokens() public {
        MockUniswapV3Pool wrong = new MockUniswapV3Pool(address(eurc), address(cbbtc));
        Rebalancer.Deployment memory d = _deployment();
        d.poolEurcUsdc = address(wrong);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedPoolTokens.selector, address(wrong)));
        new Rebalancer(d);
        d = _deployment();
        d.poolUsdcCbbtc = address(wrong);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedPoolTokens.selector, address(wrong)));
        new Rebalancer(d);
    }

    /// @dev Lead 1: een pool met de juiste tokens maar een andere fee-tier dan POOL_FEE wordt geweigerd, ook als de
    ///      factory hem onder 500 zou registreren.
    function test_constructor_rejectsPoolWithWrongFee() public {
        MockUniswapV3Pool wrongFee = new MockUniswapV3Pool(address(eurc), address(usdc));
        wrongFee.setFee(3000);
        factory.setPool(address(eurc), address(usdc), 500, address(wrongFee));
        Rebalancer.Deployment memory d = _deployment();
        d.poolEurcUsdc = address(wrongFee);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedPoolFee.selector, address(wrongFee)));
        new Rebalancer(d);
        factory.setPool(address(eurc), address(usdc), 500, address(poolEurcUsdc));

        MockUniswapV3Pool wrongFeeBtc = new MockUniswapV3Pool(address(usdc), address(cbbtc));
        wrongFeeBtc.setFee(100);
        d = _deployment();
        d.poolUsdcCbbtc = address(wrongFeeBtc);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedPoolFee.selector, address(wrongFeeBtc)));
        new Rebalancer(d);
    }

    /// @dev Review L-1: de runomvang rekent met hooguit één tickgrens in het venster, en dat klopt alleen bij
    ///      tickSpacing 10. Een pool met een andere tickSpacing wordt geweigerd.
    function test_constructor_rejectsPoolWithWrongTickSpacing() public {
        poolEurcUsdc.setTickSpacing(1);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedTickSpacing.selector, address(poolEurcUsdc)));
        new Rebalancer(_deployment());
        poolEurcUsdc.setTickSpacing(10);
        poolUsdcCbbtc.setTickSpacing(60);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedTickSpacing.selector, address(poolUsdcCbbtc)));
        new Rebalancer(_deployment());
    }

    /// @dev Lead 1: een pool met de juiste tokens en fee die niet de pool van de factory van de router is (een
    ///      nagebouwde pool, of een pool van een andere factory) wordt geweigerd.
    function test_constructor_rejectsPoolNotFromRouterFactory() public {
        MockUniswapV3Pool lookalike = new MockUniswapV3Pool(address(eurc), address(usdc));
        Rebalancer.Deployment memory d = _deployment();
        d.poolEurcUsdc = address(lookalike);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.PoolNotFromRouterFactory.selector, address(lookalike)));
        new Rebalancer(d);

        MockUniswapV3Pool lookalikeBtc = new MockUniswapV3Pool(address(usdc), address(cbbtc));
        d = _deployment();
        d.poolUsdcCbbtc = address(lookalikeBtc);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.PoolNotFromRouterFactory.selector, address(lookalikeBtc)));
        new Rebalancer(d);

        // De echte pools, maar de router wijst naar een andere factory waarin ze niet staan.
        MockUniswapV3Factory otherFactory = new MockUniswapV3Factory();
        router.setFactory(address(otherFactory));
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.PoolNotFromRouterFactory.selector, address(poolEurcUsdc)));
        new Rebalancer(_deployment());

        // Router zonder factory.
        router.setFactory(address(0));
        vm.expectRevert(Rebalancer.ZeroAddress.selector);
        new Rebalancer(_deployment());

        // Terug naar de juiste factory: de deploy slaagt.
        router.setFactory(address(factory));
        new Rebalancer(_deployment());
    }

    // Referentievectoren (PHP AutoTradeStrategy::rebalanceAmount) ──────────────────────────────────────

    struct Vector {
        uint256 cash; // EURC-basiseenheden
        uint256 position; // EURC-basiseenheden
        uint16 targetBps;
        uint16 bandBps;
        uint16 capBps;
        uint64 minTrade;
        int256 amount; // gesigneerd, EURC-basiseenheden; + kopen, - verkopen
    }

    /// @dev Koers 100 EURC per cbBTC, zodat 1 sat == 1 EURC-basiseenheid en de positie exact omgezet wordt.
    uint256 internal constant VECTOR_PRICE = 100e6;

    /// @dev Vectoren uit de PHP-referentie, met `minTrade` op de contractvloer van 20 EURC. Daardoor wijken v[4],
    ///      v[6] en v[12] af van de oorspronkelijke PHP-set (minTrade 5): v[4] is ×10 geschaald, en bij v[6] en
    ///      v[12] is de cap-vloer nu 20 in plaats van 10 (cap = max(total × 10%, minTrade)).
    function _vectors() internal pure returns (Vector[15] memory v) {
        v[0] = Vector(200e6, 800e6, 8000, 500, 1000, 20e6, 0);
        v[1] = Vector(500e6, 500e6, 8000, 500, 1000, 20e6, 100e6);
        v[2] = Vector(0, 1000e6, 8000, 500, 1000, 20e6, -100e6);
        v[3] = Vector(1000e6, 0, 8000, 500, 1000, 20e6, 100e6);
        v[4] = Vector(100e6, 900e6, 8000, 500, 1000, 20e6, -100e6);
        v[5] = Vector(3e6, 7e6, 8000, 500, 1000, 20e6, 0);
        v[6] = Vector(100e6, 0, 8000, 500, 1000, 20e6, 20e6);
        v[7] = Vector(50e6, 950e6, 8000, 200, 1000, 20e6, -100e6);
        v[8] = Vector(300e6, 700e6, 5000, 500, 1000, 20e6, -100e6);
        v[9] = Vector(123_456_789, 876_543_211, 8000, 500, 1000, 20e6, -76_543_211);
        v[10] = Vector(0, 0, 8000, 500, 1000, 20e6, 0);
        v[11] = Vector(1_000_000e6, 0, 8000, 500, 10_000, 20e6, 800_000e6);
        v[12] = Vector(40e6, 60e6, 9500, 500, 1000, 20e6, 20e6);
        v[13] = Vector(95e6, 5e6, 500, 500, 1000, 20e6, 0);
        v[14] = Vector(260e6, 740e6, 8000, 500, 1000, 100e6, 0);
    }

    function test_isDue_matchesPhpReferenceVectors() public {
        _setPrice(VECTOR_PRICE);
        assertEq(r.quote(), VECTOR_PRICE);
        Vector[15] memory v = _vectors();
        for (uint256 i = 0; i < v.length; i++) {
            address user = makeAddr(string(abi.encodePacked("vector", i)));
            Rebalancer.Params memory p = Rebalancer.Params({
                active: true,
                targetBps: v[i].targetBps,
                bandBps: v[i].bandBps,
                maxCorrectionBps: v[i].capBps,
                minTradeEurc: v[i].minTrade,
                interval: 1 days,
                maxSlippageBps: 100
            });
            uint256 btc = v[i].position * 1e8 / VECTOR_PRICE;
            assertEq(Math.mulDiv(btc, VECTOR_PRICE, 1e8), v[i].position, "positie niet exact omzetbaar");
            _setUser(user, v[i].cash, btc, p);

            (bool due, int256 delta) = r.isDue(user);
            if (v[i].amount == 0) {
                assertFalse(due, string(abi.encodePacked("vector ", vm.toString(i), ": due")));
                assertEq(delta, 0, string(abi.encodePacked("vector ", vm.toString(i), ": delta")));
                continue;
            }
            assertTrue(due, string(abi.encodePacked("vector ", vm.toString(i), ": not due")));
            assertEq(delta > 0, v[i].amount > 0, string(abi.encodePacked("vector ", vm.toString(i), ": richting")));
            assertApproxEqAbs(delta, v[i].amount, 2, string(abi.encodePacked("vector ", vm.toString(i), ": bedrag")));
        }
    }

    // Fuzz ──────────────────────────────────────────────────────────────────────────────────────────────

    function testFuzz_planBoundedAndAccountingClosed(
        uint256 cash,
        uint256 btc,
        uint16 targetSteps,
        uint16 band,
        uint16 cap,
        uint64 minTrade,
        uint256 allowanceEurc,
        uint256 allowanceBtc,
        bool withReward
    ) public {
        cash = bound(cash, 0, 1e15); // <= 1 miljard EURC
        btc = bound(btc, 0, 1e13); // <= 100.000 cbBTC
        Rebalancer.Params memory p = Rebalancer.Params({
            active: true,
            targetBps: uint16(bound(targetSteps, 5, 95)) * 100,
            bandBps: uint16(bound(band, 125, 9999)), // MIN_BAND_BPS
            maxCorrectionBps: uint16(bound(cap, 10, 10_000)),
            minTradeEurc: uint64(bound(minTrade, 20e6, 1e9)),
            interval: 1 days,
            maxSlippageBps: 100
        });
        allowanceEurc = bound(allowanceEurc, 0, type(uint256).max);
        allowanceBtc = bound(allowanceBtc, 0, type(uint256).max);
        address rewardTo = withReward ? keeper : address(0);

        _setUser(alice, cash, btc, p);
        vm.startPrank(alice);
        eurc.approve(address(r), allowanceEurc);
        cbbtc.approve(address(r), allowanceBtc);
        vm.stopPrank();

        uint256 total = cash + Math.mulDiv(btc, PRICE, 1e8);
        uint256 capEurc = Math.max(Math.mulDiv(total, p.maxCorrectionBps, BPS), p.minTradeEurc);

        (bool due, int256 delta) = r.isDue(alice);
        if (!due) {
            assertEq(delta, 0);
            vm.expectRevert(Rebalancer.NothingToDo.selector);
            r.execute(alice, rewardTo);
            return;
        }
        uint256 absDelta = delta > 0 ? uint256(delta) : uint256(-delta);
        // Bij verkopen is de delta de naar boven afgeronde sats-hoeveelheid tegen de koers: tot 1 sat boven de cap.
        assertLe(absDelta, capEurc + PRICE / 1e8, "correctie boven cap");
        assertGe(absDelta, p.minTradeEurc, "correctie onder minTrade");

        uint256 treasuryBefore = eurc.balanceOf(treasury);
        uint256 keeperBefore = eurc.balanceOf(keeper);
        r.execute(alice, rewardTo);

        assertEq(eurc.balanceOf(address(r)), 0, "EURC-restsaldo");
        assertEq(cbbtc.balanceOf(address(r)), 0, "cbBTC-restsaldo");
        assertEq(r.lastExecutedAt(alice), uint64(block.timestamp));

        uint256 feePaid = (eurc.balanceOf(treasury) - treasuryBefore) + (eurc.balanceOf(keeper) - keeperBefore);
        if (delta > 0) {
            uint256 amountIn = cash - eurc.balanceOf(alice);
            assertLe(amountIn, capEurc, "amountIn boven cap");
            assertLe(amountIn, absDelta, "amountIn boven correctie");
            assertLe(amountIn, Math.min(cash, allowanceEurc), "amountIn boven saldo/allowance");
            assertGe(amountIn, p.minTradeEurc, "amountIn onder minTrade");
            uint256 fee = Math.mulDiv(amountIn, 25, BPS);
            assertEq(feePaid, fee, "fee != reward + treasury");
            assertEq(eurc.balanceOf(address(router)), amountIn - fee, "swapIn + fee != amountIn");
            assertEq(cbbtc.balanceOf(alice) - btc, Math.mulDiv(amountIn - fee, 1e8, PRICE), "output naar owner");
            if (withReward) assertEq(eurc.balanceOf(keeper) - keeperBefore, Math.min(50_000, fee));
            else assertEq(eurc.balanceOf(keeper), keeperBefore);
        } else {
            uint256 btcIn = btc - cbbtc.balanceOf(alice);
            uint256 valueIn = Math.mulDiv(btcIn, PRICE, 1e8);
            // wantBtc wordt naar boven afgerond (M-5): hooguit 1 sat aan waarde boven cap/correctie.
            uint256 oneSat = PRICE / 1e8;
            assertLe(valueIn, capEurc + oneSat, "verkoopwaarde boven cap");
            assertLe(valueIn, absDelta + oneSat, "verkoopwaarde boven correctie");
            assertLe(btcIn, Math.min(btc, allowanceBtc), "btcIn boven saldo/allowance");
            assertGe(valueIn, p.minTradeEurc, "verkoopwaarde onder minTrade");
            uint256 fee = Math.mulDiv(valueIn, 25, BPS);
            assertEq(feePaid, fee, "fee != reward + treasury");
            assertEq(eurc.balanceOf(alice) - cash, valueIn - fee, "output naar owner");
            assertEq(cbbtc.balanceOf(address(router)), btcIn);
            if (withReward) assertEq(eurc.balanceOf(keeper) - keeperBefore, Math.min(50_000, fee));
            else assertEq(eurc.balanceOf(keeper), keeperBefore);
        }
    }

    /// @dev Testgat math 1 (M-01): bij een willekeurig, niet-rond koersgetal en volle allowance is een owner due
    ///      precies als de begrensde correctie de minTrade haalt, met die correctie als delta; is hij due, dan
    ///      slaagt `execute` ook (geen NothingToDo door afronding in de omrekening naar sats).
    function testFuzz_isDue_matchesCorrectionAtAnyPrice(
        uint256 price,
        uint256 cash,
        uint256 btc,
        uint16 targetSteps,
        uint16 band,
        uint16 cap,
        uint64 minTrade
    ) public {
        price = bound(price, 20_000e6, 200_000e6);
        cash = bound(cash, 0, 1e12);
        btc = bound(btc, 0, 1e10);
        Rebalancer.Params memory p = _defaultParams();
        p.targetBps = uint16(bound(targetSteps, 5, 95)) * 100;
        p.bandBps = uint16(bound(band, 125, 9999)); // MIN_BAND_BPS
        p.maxCorrectionBps = uint16(bound(cap, 10, 10_000));
        p.minTradeEurc = uint64(bound(minTrade, 20e6, 1e9));
        _setPrice(price);
        router.setPrice(price);
        _setUser(alice, cash, btc, p);

        uint256 position = Math.mulDiv(btc, price, 1e8);
        uint256 total = cash + position;
        uint256 correction;
        bool isBuy;
        if (total > 0) {
            uint256 fractionWad = Math.mulDiv(position, 1e18, total);
            uint256 targetWad = uint256(p.targetBps) * 1e18 / BPS;
            isBuy = fractionWad < targetWad;
            uint256 driftWad = isBuy ? targetWad - fractionWad : fractionWad - targetWad;
            if (driftWad > uint256(p.bandBps) * 1e18 / BPS) {
                uint256 capEurc = Math.max(Math.mulDiv(total, p.maxCorrectionBps, BPS), p.minTradeEurc);
                correction = Math.min(Math.mulDiv(driftWad, total, 1e18), capEurc);
            }
        }
        bool expectDue = correction >= p.minTradeEurc;

        (bool due, int256 delta) = r.isDue(alice);
        assertEq(due, expectDue, "due wijkt af van correctie >= minTrade");
        if (!expectDue) {
            assertEq(delta, 0);
            vm.expectRevert(Rebalancer.NothingToDo.selector);
            r.execute(alice, keeper);
            return;
        }
        // L-C: de delta is het werkelijke inputbedrag. Bij verkopen is dat de naar boven afgeronde sats-hoeveelheid
        // (hooguit het saldo) tegen de koers, dus tot 1 sat aan waarde boven de correctie.
        int256 expectedDelta;
        if (isBuy) {
            expectedDelta = int256(correction);
        } else {
            uint256 sats = Math.min(Math.mulDiv(correction, 1e8, price, Math.Rounding.Ceil), btc);
            expectedDelta = -int256(Math.mulDiv(sats, price, 1e8));
        }
        assertEq(delta, expectedDelta);
        r.execute(alice, keeper);
        assertEq(r.lastExecutedAt(alice), uint64(START));
    }

    function testFuzz_setParamsValidation(
        uint16 target,
        uint16 band,
        uint16 cap,
        uint64 minTrade,
        uint32 interval,
        uint16 slip
    ) public {
        Rebalancer.Params memory p = Rebalancer.Params({
            active: true,
            targetBps: target,
            bandBps: band,
            maxCorrectionBps: cap,
            minTradeEurc: minTrade,
            interval: interval,
            maxSlippageBps: slip
        });
        bool valid = target >= 500 && target <= 9500 && target % 100 == 0 && band >= 125 && band <= 9999 && cap >= 10
            && cap <= 10_000 && minTrade >= 20e6 && interval >= 1 hours && slip >= 60 && slip <= 100;
        if (!valid) vm.expectRevert(Rebalancer.InvalidParams.selector);
        vm.prank(alice);
        r.setParams(p);
        assertEq(r.ownerCount(), valid ? 1 : 0);
    }
}

// ─── Invariant ─────────────────────────────────────────────────────────────────────────────────────────────

contract RebalancerHandler is Test {
    Rebalancer public r;
    MockERC20 public eurc;
    MockERC20 public cbbtc;
    MockAggregator public feedBtc;
    MockAggregator public feedEurc;
    MockRouter public router;
    MockUniswapV3Pool public poolEurcUsdc;
    MockUniswapV3Pool public poolUsdcCbbtc;
    address public treasury;

    address[] public actors;
    mapping(address actor => uint256) public ghostEurc;
    mapping(address actor => uint256) public ghostBtc;
    uint256 public lastTreasury;
    bool public treasuryDecreased;
    bool public contractHeldBalance;
    uint256 public executes;
    uint256 public executesSucceeded;
    /// @dev Ghost-tellers per revert-reden (testgat math 7): NothingToDo is verwacht, "Too little received" of een
    ///      spot-afwijking wijst op liveness-uitval.
    uint256 public revertsNothingToDo;
    uint256 public revertsInactive;
    uint256 public revertsNotDue;
    uint256 public revertsSpot;
    uint256 public revertsSlippage;
    uint256 public revertsRetired;
    uint256 public revertsBlockMove;
    uint256 public revertsPoolTouched;
    uint256 public revertsOther;
    /// @dev Ronde-ghosts (audit M-1): budget en richting van de lopende ronde per owner, en wat er in die ronde al
    ///      verhandeld is. Een run is een nieuwe ronde als `interval` sinds de vorige run verstreken is, anders een deel.
    mapping(address actor => uint256) public ghostRoundBudget;
    mapping(address actor => uint256) public ghostRoundSpent;
    mapping(address actor => uint256) public ghostRoundRuns;
    mapping(address actor => bool) public ghostRoundIsBuy;
    bool public roundBudgetExceeded;
    bool public roundDirectionFlipped;
    bool public chunkWithoutRound;
    uint256 public chunksSucceeded;
    /// @dev Retire-ghosts: is er na `retire` nog een `Executed`-event gezien (in welke handler-actie dan ook)?
    uint256 public retires;
    bool public executedAfterRetire;

    constructor(
        Rebalancer r_,
        MockERC20 eurc_,
        MockERC20 cbbtc_,
        MockAggregator feedBtc_,
        MockAggregator feedEurc_,
        MockRouter router_,
        MockUniswapV3Pool poolEurcUsdc_,
        MockUniswapV3Pool poolUsdcCbbtc_,
        address treasury_
    ) {
        r = r_;
        eurc = eurc_;
        cbbtc = cbbtc_;
        feedBtc = feedBtc_;
        feedEurc = feedEurc_;
        router = router_;
        poolEurcUsdc = poolEurcUsdc_;
        poolUsdcCbbtc = poolUsdcCbbtc_;
        treasury = treasury_;
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    modifier afterCall() {
        bool wasRetired = r.retired();
        vm.recordLogs();
        _;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (wasRetired) {
            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].emitter == address(r) && logs[i].topics[0] == Rebalancer.Executed.selector) {
                    executedAfterRetire = true;
                }
            }
        }
        if (eurc.balanceOf(address(r)) != 0 || cbbtc.balanceOf(address(r)) != 0) contractHeldBalance = true;
        uint256 t = eurc.balanceOf(treasury);
        if (t < lastTreasury) treasuryDecreased = true;
        lastTreasury = t;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function setParams(uint256 seed, uint16 target, uint16 band, uint16 cap, uint64 minTrade, uint16 slip, bool active)
        external
        afterCall
    {
        Rebalancer.Params memory p = Rebalancer.Params({
            active: active,
            targetBps: uint16(bound(target, 5, 95)) * 100,
            bandBps: uint16(bound(band, 125, 9999)), // MIN_BAND_BPS; lagere banden weigert setParams nu
            maxCorrectionBps: uint16(bound(cap, 10, 10_000)),
            minTradeEurc: uint64(bound(minTrade, 20e6, 100e6)),
            interval: 1 hours,
            maxSlippageBps: uint16(bound(slip, 60, 100))
        });
        vm.prank(_actor(seed));
        r.setParams(p);
    }

    function approve(uint256 seed, uint256 eurcAllowance, uint256 btcAllowance) external afterCall {
        vm.startPrank(_actor(seed));
        eurc.approve(address(r), eurcAllowance);
        cbbtc.approve(address(r), btcAllowance);
        vm.stopPrank();
    }

    function deposit(uint256 seed, uint256 cash, uint256 btc) external afterCall {
        address a = _actor(seed);
        cash = bound(cash, 0, 1e12);
        btc = bound(btc, 0, 1e10);
        if (cash > 0) eurc.mint(a, cash);
        if (btc > 0) cbbtc.mint(a, btc);
        ghostEurc[a] += cash;
        ghostBtc[a] += btc;
    }

    function warp(uint32 dt) external afterCall {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + bound(dt, 0, 2 days));
        _refreshFeeds();
    }

    /// @dev Kleine stappen: een volgend blok (2 s) of precies CHUNK_INTERVAL, zodat delen van rondes geraakt worden.
    function warpShort(bool chunkInterval) external afterCall {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + (chunkInterval ? 10 minutes : 2));
        _refreshFeeds();
    }

    /// @dev Eindige liquiditeit in een van beide pools, zodat runs in delen gaan (of 0 = weer onbegrensd).
    function setLiquidity(bool eurcPool, uint128 liquidity) external afterCall {
        uint128 value = liquidity % 4 == 0 ? type(uint128).max : uint128(bound(liquidity, 1e11, 1e14));
        if (eurcPool) poolEurcUsdc.setLiquidity(value);
        else poolUsdcCbbtc.setLiquidity(uint128(Math.min(uint256(value) * 1e3, type(uint128).max)));
    }

    /// @dev Een swap van iemand anders in dit blok (tot ±10 bp). Verandert die de tick, dan raakt hij de blokcheck
    ///      (PoolTouchedThisBlock); binnen de tick het blokvenster.
    function pushInBlock(bool eurcPool, uint16 bps, bool up) external afterCall {
        bps = uint16(bound(bps, 0, 10));
        MockUniswapV3Pool pool = eurcPool ? poolEurcUsdc : poolUsdcCbbtc;
        uint256 s = pool.sqrtPriceX96();
        uint256 target = up ? s * (20_000 + bps) / 20_000 : s * (20_000 - bps) / 20_000;
        pool.swapToSqrtPriceX96(uint160(target));
    }

    function setPrice(uint256 price) external afterCall {
        price = bound(price, 20_000e6, 200_000e6);
        feedBtc.set(int256(price * 1e8 / 1e6), block.timestamp, block.timestamp);
        feedEurc.set(1e8, block.timestamp, block.timestamp);
        poolEurcUsdc.setPrice(1e6, 1e6);
        poolUsdcCbbtc.setPrice(price, 1e8);
        router.setPrice(price);
    }

    /// @dev Testgat oracle 10: alleen de pools verschuiven (feed blijft staan), tot ±1%, zodat de spot-check ook in
    ///      de invariant-suite geraakt wordt.
    function shiftSpot(uint16 bps, bool up) external afterCall {
        bps = uint16(bound(bps, 0, 100));
        (, int256 a,,,) = feedBtc.latestRoundData();
        uint256 price = uint256(a) * 1e6 / 1e8;
        uint256 shifted = up ? price * (10_000 + bps) / 10_000 : price * (10_000 - bps) / 10_000;
        poolUsdcCbbtc.setPrice(shifted, 1e8);
    }

    /// @dev Iedereen mag vegen; het contract mag daardoor nooit saldo overhouden en de treasury daalt nooit.
    function sweep(bool eurcToken) external afterCall {
        r.sweep(eurcToken ? eurc : cbbtc);
    }

    /// @dev De treasury zet het contract stil. Eén keer per run; daarna mag geen execute meer slagen. Gegate op
    ///      de seed (1 op 8), zodat de meeste runs de gewone paden blijven raken en een derde retired eindigt.
    function retire(uint256 seed) external afterCall {
        if (r.retired() || seed % 8 != 0) return;
        vm.prank(treasury);
        r.retire();
        retires++;
    }

    function execute(uint256 seed, uint256 rewardSeed) external afterCall {
        address owner = _actor(seed);
        address rewardTo = rewardSeed % 3 == 0 ? address(0) : (rewardSeed % 3 == 1 ? _actor(rewardSeed) : treasury);
        executes++;
        (,,,,, uint32 interval,) = r.params(owner);
        bool fresh = block.timestamp >= uint256(r.lastExecutedAt(owner)) + interval;
        (bool roundIsBuy, uint128 roundLeft) = r.rounds(owner);
        (, int256 answer,,,) = feedBtc.latestRoundData();
        uint256 price = uint256(answer) * 1e6 / 1e8;
        uint256 eurcBefore = eurc.balanceOf(owner);
        uint256 btcBefore = cbbtc.balanceOf(owner);
        uint256 totalBefore = eurcBefore + Math.mulDiv(btcBefore, price, 1e8);
        try r.execute(owner, rewardTo) {
            executesSucceeded++;
            bool isBuy = eurc.balanceOf(owner) < eurcBefore;
            uint256 spent = isBuy
                ? eurcBefore - eurc.balanceOf(owner)
                : Math.mulDiv(btcBefore - cbbtc.balanceOf(owner), price, 1e8, Math.Rounding.Ceil);
            if (fresh) {
                (,,, uint16 cap, uint64 minTrade,,) = r.params(owner);
                ghostRoundBudget[owner] = Math.max(Math.mulDiv(totalBefore, cap, 10_000), minTrade);
                ghostRoundSpent[owner] = spent;
                ghostRoundRuns[owner] = 1;
                ghostRoundIsBuy[owner] = isBuy;
            } else {
                chunksSucceeded++;
                if (roundLeft == 0) chunkWithoutRound = true;
                if (isBuy != ghostRoundIsBuy[owner] || isBuy != roundIsBuy) roundDirectionFlipped = true;
                ghostRoundSpent[owner] += spent;
                ghostRoundRuns[owner]++;
            }
            // Verkopen ronden hooguit 1 sat naar boven af per run (M-5).
            if (ghostRoundSpent[owner] > ghostRoundBudget[owner] + ghostRoundRuns[owner] * (price / 1e8 + 1)) {
                roundBudgetExceeded = true;
            }
        } catch (bytes memory reason) {
            bytes4 sel = reason.length >= 4 ? bytes4(reason) : bytes4(0);
            if (sel == Rebalancer.NothingToDo.selector) revertsNothingToDo++;
            else if (sel == Rebalancer.Inactive.selector) revertsInactive++;
            else if (sel == Rebalancer.NotDue.selector) revertsNotDue++;
            else if (sel == Rebalancer.SpotDeviatesFromOracle.selector) revertsSpot++;
            else if (sel == Rebalancer.ContractRetired.selector) revertsRetired++;
            else if (sel == Rebalancer.BlockMoveExceeded.selector) revertsBlockMove++;
            else if (sel == Rebalancer.PoolTouchedThisBlock.selector) revertsPoolTouched++;
            else if (sel == bytes4(keccak256("Error(string)"))) revertsSlippage++;
            else revertsOther++;
        }
        // Alleen execute mag saldi van actors veranderen: leg het nieuwe saldo vast.
        for (uint256 i = 0; i < actors.length; i++) {
            ghostEurc[actors[i]] = eurc.balanceOf(actors[i]);
            ghostBtc[actors[i]] = cbbtc.balanceOf(actors[i]);
        }
    }

    function _refreshFeeds() internal {
        (, int256 a,,,) = feedBtc.latestRoundData();
        feedBtc.set(a, block.timestamp, block.timestamp);
        feedEurc.set(1e8, block.timestamp, block.timestamp);
    }
}

contract RebalancerInvariantTest is StdInvariant, RebalancerTestBase {
    RebalancerHandler internal handler;

    function setUp() public virtual override {
        super.setUp();
        handler =
            new RebalancerHandler(r, eurc, cbbtc, feedBtc, feedEurc, router, poolEurcUsdc, poolUsdcCbbtc, treasury);
        targetContract(address(handler));
    }

    /// @dev Tokens verlaten (of bereiken) een owner-wallet alleen via execute of een handler-deposit.
    function invariant_ownerBalancesOnlyMoveThroughExecute() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            assertEq(eurc.balanceOf(a), handler.ghostEurc(a), "EURC bewoog buiten execute om");
            assertEq(cbbtc.balanceOf(a), handler.ghostBtc(a), "cbBTC bewoog buiten execute om");
        }
    }

    function invariant_contractNeverHoldsBalance() public view {
        assertFalse(handler.contractHeldBalance(), "contract hield saldo na een call");
        assertEq(eurc.balanceOf(address(r)), 0);
        assertEq(cbbtc.balanceOf(address(r)), 0);
    }

    function invariant_treasuryMonotonic() public view {
        assertFalse(handler.treasuryDecreased(), "treasury-saldo daalde");
        assertGe(eurc.balanceOf(treasury), handler.lastTreasury());
    }

    /// @dev Zonder router-slippage en met de spot binnen ±1% mag een execute alleen falen op NothingToDo, Inactive,
    ///      NotDue, de spot-check, de blokcheck, het blokvenster of ContractRetired; "Too little received" of iets anders zou
    ///      liveness-uitval zijn.
    function invariant_executeFailsOnlyForKnownReasons() public view {
        assertEq(handler.revertsSlippage(), 0, "router-slippage zonder oorzaak");
        assertEq(handler.revertsOther(), 0, "onbekende revert-reden");
        assertEq(
            handler.executes(),
            handler.executesSucceeded() + handler.revertsNothingToDo() + handler.revertsInactive()
                + handler.revertsNotDue() + handler.revertsSpot() + handler.revertsRetired()
                + handler.revertsBlockMove() + handler.revertsPoolTouched()
        );
    }

    /// @dev Laat per run zien welke paden geraakt zijn (met -vv), zodat een groene suite niet op lege paden rust.
    function afterInvariant() public view virtual {
        console.log("execute geslaagd:", handler.executesSucceeded(), " waarvan delen:", handler.chunksSucceeded());
        console.log("revert BlockMoveExceeded:", handler.revertsBlockMove(), " NotDue:", handler.revertsNotDue());
        console.log("execute totaal:", handler.executes(), " NothingToDo:", handler.revertsNothingToDo());
        console.log("revert spot:", handler.revertsSpot(), " retired:", handler.revertsRetired());
        console.log(
            "revert inactive:", handler.revertsInactive(), " PoolTouchedThisBlock:", handler.revertsPoolTouched()
        );
    }

    /// @dev Audit M-1: de runs van één ronde (eerste run plus delen) blijven samen binnen het budget van die ronde
    ///      (maxCorrectionBps van de waarde bij de eerste run, minstens minTradeEurc).
    function invariant_roundBudgetNeverExceeded() public view {
        assertFalse(handler.roundBudgetExceeded(), "ronde verhandelde meer dan haar budget");
    }

    /// @dev Audit M-1: een deel gaat altijd in de richting van de ronde en alleen als er een ronde loopt.
    function invariant_chunkKeepsRoundDirection() public view {
        assertFalse(handler.roundDirectionFlipped(), "deel in de andere richting dan de ronde");
        assertFalse(handler.chunkWithoutRound(), "deel zonder lopende ronde");
    }

    /// @dev Na retire vindt geen Executed-event meer plaats, en de vlag gaat nooit meer terug.
    function invariant_noExecutedAfterRetire() public view {
        assertFalse(handler.executedAfterRetire(), "Executed na retire");
        assertLe(handler.retires(), 1, "retire slaagde meer dan eens");
        assertEq(r.retired(), handler.retires() == 1, "retired-vlag wijkt af van de handler");
        if (r.retired()) {
            assertEq(r.dueOwners(0, handler.actorCount()).length, 0, "dueOwners niet leeg na retire");
        }
    }
}

/// @dev Dezelfde invariants zonder `retire` in de handler. In diepe runs zet `retire` (1 op 8 per aanroep) het contract
///      bijna altijd vroeg stil, waardoor rondes en delen nauwelijks geraakt worden. Valt onder
///      `--match-contract RebalancerInvariantTest`.
contract RebalancerInvariantTestNoRetire is RebalancerInvariantTest {
    function setUp() public override {
        super.setUp();
        // Startstand: elke actor actief, met saldo en volle allowance, en een EURC/USDC-pool met eindige liquiditeit
        // (~375 EURC per run), zodat grotere correcties in delen gaan.
        uint16[3] memory caps = [uint16(10_000), 1000, 300];
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            handler.deposit(i, 10_000e6 * (i + 1), 1_000_000 * i);
            vm.startPrank(a);
            eurc.approve(address(r), type(uint256).max);
            cbbtc.approve(address(r), type(uint256).max);
            Rebalancer.Params memory p = _defaultParams();
            p.maxCorrectionBps = caps[i];
            p.interval = 1 hours;
            r.setParams(p);
            vm.stopPrank();
        }
        poolEurcUsdc.setLiquidity(2e12);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = RebalancerHandler.retire.selector;
        selectors[1] = RebalancerHandler.setParams.selector;
        selectors[2] = RebalancerHandler.approve.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }
}

/// @dev Maakt `_takeFee` aanroepbaar voor de begrenzingstest.
contract RebalancerFeeHarness is Rebalancer {
    constructor(Deployment memory d) Rebalancer(d) {}

    function takeFee(uint256 feeBase, uint256 maxFee, address rewardTo) external returns (uint256, uint256) {
        return _takeFee(feeBase, maxFee, rewardTo);
    }
}

/// @dev Nep-token voor `sweep`: `balanceOf` roept met msg.sender = Rebalancer diens `setParams` aan.
contract MaliciousSweepToken {
    Rebalancer private immutable _r;

    constructor(Rebalancer r_) {
        _r = r_;
    }

    function balanceOf(address) external returns (uint256) {
        _r.setParams(
            Rebalancer.Params({
                active: true,
                targetBps: 8000,
                bandBps: 500,
                maxCorrectionBps: 1000,
                minTradeEurc: 20e6,
                interval: 1 hours,
                maxSlippageBps: 100
            })
        );
        return 0;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @dev Nep-token voor `sweep` met een schrijvende `transfer`: probeert de run van `victim` binnen te komen en
///      registreert zichzelf daarna als owner.
contract ReentrantSweepToken {
    Rebalancer private immutable _r;
    address private immutable _victim;
    bytes public executeRevertData;

    constructor(Rebalancer r_, address victim_) {
        _r = r_;
        _victim = victim_;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 1;
    }

    function transfer(address, uint256) external returns (bool) {
        try _r.execute(_victim, address(this)) {}
        catch (bytes memory reason) {
            executeRevertData = reason;
        }
        _r.setParams(
            Rebalancer.Params({
                active: true,
                targetBps: 8000,
                bandBps: 500,
                maxCorrectionBps: 1000,
                minTradeEurc: 20e6,
                interval: 1 hours,
                maxSlippageBps: 100
            })
        );
        return true;
    }
}
