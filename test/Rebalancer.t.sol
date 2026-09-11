// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Rebalancer} from "../src/Rebalancer.sol";
import {IReceiver} from "../src/interfaces/IReceiver.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";

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
    Rebalancer internal r;

    address internal treasury = makeAddr("treasury");
    address internal forwarder = makeAddr("forwarder");
    address internal workflowOwner = makeAddr("workflowOwner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    function setUp() public virtual {
        vm.warp(START);
        // De constructor eist dat de forwarder een contract is; de KeystoneForwarder is dat op Base ook.
        vm.etch(forwarder, hex"5f");

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
            treasury: treasury,
            forwarder: forwarder,
            workflowOwner: workflowOwner
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
            minTradeEurc: 5e6,
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
        assertEq(minTrade, 5e6);
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
        p.bandBps = 1;
        r.setParams(p);
        p.bandBps = 9999;
        r.setParams(p);
        p.maxCorrectionBps = 1;
        r.setParams(p);
        p.maxCorrectionBps = 10_000;
        r.setParams(p);
        p.minTradeEurc = 1;
        r.setParams(p);
        p.interval = 1 hours;
        r.setParams(p);
        p.maxSlippageBps = 30;
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
        p.bandBps = 10_000;
        _expectInvalid(p);
    }

    function test_setParams_rejectsMaxCorrection() public {
        Rebalancer.Params memory p = _defaultParams();
        p.maxCorrectionBps = 0;
        _expectInvalid(p);
        p.maxCorrectionBps = 10_001;
        _expectInvalid(p);
    }

    function test_setParams_rejectsMinTradeZero() public {
        Rebalancer.Params memory p = _defaultParams();
        p.minTradeEurc = 0;
        _expectInvalid(p);
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
        p.maxSlippageBps = 29;
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
        // 100 EURC -> amountIn 10 EURC, fee 25_000 < 50_000: hele fee naar rewardTo.
        _setUser(alice, 100e6, 0, _defaultParams());
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(keeper), 25_000);
        assertEq(eurc.balanceOf(treasury), 0);
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
        assertEq(delta, 100e6); // correctie vóór begrenzing
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
        eurc.approve(address(r), 4_999_999);
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
        // 3 EURC + 7 EURC cbBTC: correctie 1 EURC < min 5.
        _setUser(alice, 3e6, 8_750, _defaultParams());
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
        _setUser(alice, 1000e6, 0, _defaultParams());
        feedEurc.set(1e8, START, START - 90_001);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.StaleFeed.selector, address(feedEurc)));
        r.execute(alice, keeper);

        feedEurc.set(1e8, START, START - 90_000);
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
        // Fee over het werkelijk ontvangen bedrag (99 EURC), niet over de verwachting.
        assertEq(eurc.balanceOf(keeper) + eurc.balanceOf(treasury), 99e6 * 25 / BPS);
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
        _setUser(alice, 3e6, 8_750, _defaultParams());
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

    function test_isDue_deltaIsCorrectionBeforeAllowanceBound() public {
        _setUser(alice, 0, 1_250_000, _defaultParams());
        vm.prank(alice);
        cbbtc.approve(address(r), 10_000);
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, -100e6);
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

    // quote ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_quote_usesBothFeeds() public {
        assertEq(r.quote(), PRICE);
        feedEurc.set(1.1e8, START, START);
        assertEq(r.quote(), Math.mulDiv(80_000e8, 1e6, 1.1e8));
    }

    // onReport ──────────────────────────────────────────────────────────────────────────────────────────

    function _metadata(address wfOwner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(1)), bytes10("bitburo"), wfOwner, bytes2(0x0001));
    }

    function test_onReport_revertsUnauthorizedForwarder() public {
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnauthorizedForwarder.selector, bob));
        vm.prank(bob);
        r.onReport(_metadata(workflowOwner), abi.encode(list));
    }

    function test_onReport_revertsUnauthorizedWorkflowOwner() public {
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnauthorizedWorkflowOwner.selector, bob));
        vm.prank(forwarder);
        r.onReport(_metadata(bob), abi.encode(list));
    }

    function test_onReport_executesDueAndSkipsOthers() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        _setUser(bob, 200e6, 1_000_000, _defaultParams()); // binnen band
        address[] memory list = new address[](3);
        list[0] = alice;
        list[1] = bob;
        list[2] = keeper; // nooit geregistreerd

        uint256 amountOut = Math.mulDiv(99_750_000, 1e8, PRICE);
        vm.expectEmit(true, false, false, true, address(r));
        emit Rebalancer.Executed(alice, true, 100e6, 250_000, 50_000, treasury, amountOut, PRICE, 1000e6, 0);
        vm.expectEmit(true, false, false, true, address(r));
        emit Rebalancer.ReportSkipped(bob, abi.encodeWithSelector(Rebalancer.NothingToDo.selector));
        vm.expectEmit(true, false, false, true, address(r));
        emit Rebalancer.ReportSkipped(keeper, abi.encodeWithSelector(Rebalancer.Inactive.selector));

        vm.prank(forwarder);
        r.onReport(_metadata(workflowOwner), abi.encode(list));

        // Reward gaat naar de treasury: hele fee bij de treasury.
        assertEq(eurc.balanceOf(treasury), 250_000);
        assertEq(eurc.balanceOf(alice), 900e6);
        assertEq(eurc.balanceOf(bob), 200e6);
        assertEq(r.lastExecutedAt(alice), uint64(START));
        assertEq(r.lastExecutedAt(bob), 0);
    }

    function test_onReport_emptyReport() public {
        vm.prank(forwarder);
        r.onReport(_metadata(workflowOwner), abi.encode(new address[](0)));
    }

    function test_onReport_stopsCleanlyWhenGasRunsOut() public {
        address[5] memory users;
        address[] memory list = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            users[i] = makeAddr(string(abi.encodePacked("gas", i)));
            _setUser(users[i], 1000e6, 0, _defaultParams());
            list[i] = users[i];
        }

        // Genoeg voor de eerste owner en de reserve-check, te weinig voor een tweede: de lus breekt af,
        // de call slaagt en de rest blijft voor een volgend rapport.
        uint256 tightGas = r.EXECUTE_GAS_RESERVE() + 300_000;
        vm.prank(forwarder);
        r.onReport{gas: tightGas}(_metadata(workflowOwner), abi.encode(list));
        assertEq(r.lastExecutedAt(users[0]), uint64(START), "eerste owner uitgevoerd");
        assertEq(r.lastExecutedAt(users[1]), 0, "tweede owner overgeslagen door gasgebrek");
        assertEq(r.lastExecutedAt(users[4]), 0);

        // Met ruim gas gaan alle resterende owners in één rapport mee.
        vm.prank(forwarder);
        r.onReport{gas: 4_000_000}(_metadata(workflowOwner), abi.encode(list));
        for (uint256 i = 1; i < 5; i++) {
            assertEq(r.lastExecutedAt(users[i]), uint64(START));
        }
    }

    function test_onReport_executeGasBudgetIsPerOwner() public {
        // Een owner die meer dan EXECUTE_GAS zou vragen, wordt overgeslagen zonder de rest te raken.
        _setUser(alice, 1000e6, 0, _defaultParams());
        _setUser(bob, 1000e6, 0, _defaultParams());
        address[] memory list = new address[](2);
        list[0] = alice;
        list[1] = bob;
        router.setGasBurn(r.EXECUTE_GAS());

        vm.expectEmit(true, false, false, true, address(r));
        emit Rebalancer.ReportSkipped(alice, "");
        vm.expectEmit(true, false, false, true, address(r));
        emit Rebalancer.ReportSkipped(bob, "");
        vm.prank(forwarder);
        r.onReport{gas: 4_000_000}(_metadata(workflowOwner), abi.encode(list));
        assertEq(r.lastExecutedAt(alice), 0);
        assertEq(r.lastExecutedAt(bob), 0);
    }

    function test_onReport_skipsOnSwapFailure() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        router.setSlippageBps(200);
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.expectEmit(true, false, false, true, address(r));
        emit Rebalancer.ReportSkipped(alice, abi.encodeWithSignature("Error(string)", "Too little received"));
        vm.prank(forwarder);
        r.onReport(_metadata(workflowOwner), abi.encode(list));
        assertEq(r.lastExecutedAt(alice), 0);
    }

    function test_supportsInterface() public view {
        assertTrue(r.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(r.supportsInterface(type(IERC165).interfaceId));
        assertFalse(r.supportsInterface(0xffffffff));
        assertFalse(r.supportsInterface(0x12345678));
    }

    // constructor ───────────────────────────────────────────────────────────────────────────────────────

    function test_constructor_rejectsZeroAddress() public {
        Rebalancer.Deployment memory d = _deployment();
        d.treasury = address(0);
        vm.expectRevert(Rebalancer.ZeroAddress.selector);
        new Rebalancer(d);
        d = _deployment();
        d.workflowOwner = address(0);
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
        for (uint256 i = 0; i < 10; i++) {
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
            if (i == 9) d.forwarder = eoa;
            vm.expectRevert(abi.encodeWithSelector(Rebalancer.NotAContract.selector, eoa));
            new Rebalancer(d);
        }
        // Treasury en workflow-owner mogen EOA's zijn.
        d = _deployment();
        d.treasury = eoa;
        d.workflowOwner = eoa;
        new Rebalancer(d);
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

    function _vectors() internal pure returns (Vector[15] memory v) {
        v[0] = Vector(200e6, 800e6, 8000, 500, 1000, 5e6, 0);
        v[1] = Vector(500e6, 500e6, 8000, 500, 1000, 5e6, 100e6);
        v[2] = Vector(0, 1000e6, 8000, 500, 1000, 5e6, -100e6);
        v[3] = Vector(1000e6, 0, 8000, 500, 1000, 5e6, 100e6);
        v[4] = Vector(10e6, 90e6, 8000, 500, 1000, 5e6, -10e6);
        v[5] = Vector(3e6, 7e6, 8000, 500, 1000, 5e6, 0);
        v[6] = Vector(100e6, 0, 8000, 500, 1000, 5e6, 10e6);
        v[7] = Vector(50e6, 950e6, 8000, 200, 1000, 5e6, -100e6);
        v[8] = Vector(300e6, 700e6, 5000, 500, 1000, 5e6, -100e6);
        v[9] = Vector(123_456_789, 876_543_211, 8000, 500, 1000, 5e6, -76_543_211);
        v[10] = Vector(0, 0, 8000, 500, 1000, 5e6, 0);
        v[11] = Vector(1_000_000e6, 0, 8000, 500, 10_000, 5e6, 800_000e6);
        v[12] = Vector(40e6, 60e6, 9500, 500, 1000, 5e6, 10e6);
        v[13] = Vector(95e6, 5e6, 500, 500, 1000, 5e6, 0);
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
            bandBps: uint16(bound(band, 1, 9999)),
            maxCorrectionBps: uint16(bound(cap, 1, 10_000)),
            minTradeEurc: uint64(bound(minTrade, 1, 1e9)),
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
        assertLe(absDelta, capEurc, "correctie boven cap");
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
            assertLe(valueIn, capEurc, "verkoopwaarde boven cap");
            assertLe(valueIn, absDelta, "verkoopwaarde boven correctie");
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
        bool valid = target >= 500 && target <= 9500 && target % 100 == 0 && band >= 1 && band <= 9999 && cap >= 1
            && cap <= 10_000 && minTrade > 0 && interval >= 1 hours && slip >= 30 && slip <= 100;
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
        _;
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
            bandBps: uint16(bound(band, 1, 9999)),
            maxCorrectionBps: uint16(bound(cap, 1, 10_000)),
            minTradeEurc: uint64(bound(minTrade, 1, 100e6)),
            interval: 1 hours,
            maxSlippageBps: uint16(bound(slip, 30, 100))
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
        vm.warp(block.timestamp + bound(dt, 0, 2 days));
        _refreshFeeds();
    }

    function setPrice(uint256 price) external afterCall {
        price = bound(price, 20_000e6, 200_000e6);
        feedBtc.set(int256(price * 1e8 / 1e6), block.timestamp, block.timestamp);
        feedEurc.set(1e8, block.timestamp, block.timestamp);
        poolEurcUsdc.setPrice(1e6, 1e6);
        poolUsdcCbbtc.setPrice(price, 1e8);
        router.setPrice(price);
    }

    /// @dev Iedereen mag vegen; het contract mag daardoor nooit saldo overhouden en de treasury daalt nooit.
    function sweep(bool eurcToken) external afterCall {
        r.sweep(eurcToken ? eurc : cbbtc);
    }

    function execute(uint256 seed, uint256 rewardSeed) external afterCall {
        address owner = _actor(seed);
        address rewardTo = rewardSeed % 3 == 0 ? address(0) : (rewardSeed % 3 == 1 ? _actor(rewardSeed) : treasury);
        executes++;
        try r.execute(owner, rewardTo) {
            executesSucceeded++;
        } catch {}
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

    function setUp() public override {
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
}
