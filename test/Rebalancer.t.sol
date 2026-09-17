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

// ─── Shared setup ──────────────────────────────────────────────────────────────────────────────────────────

abstract contract RebalancerTestBase is Test {
    uint256 internal constant START = 1_800_000_000;
    uint256 internal constant PRICE = 80_000e6; // EURC base units per cbBTC
    uint256 internal constant BPS = 10_000;

    MockERC20 internal eurc;
    MockERC20 internal cbbtc;
    MockERC20 internal usdc;
    MockAggregator internal feedBtc;
    MockAggregator internal feedEurc;
    MockAggregator internal sequencer;
    MockRouter internal router;
    MockUniswapV3Pool internal poolEurcUsdc; // token0 = EURC, token1 = USDC, as on Base
    MockUniswapV3Pool internal poolUsdcCbbtc; // token0 = USDC, token1 = cbBTC, as on Base
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

    /// @dev Sets feeds and pools so that `quote()` and `spot()` (up to rounding) give `price` EURC per cbBTC,
    ///      with EURC/USD = 1.
    function _setPrice(uint256 price) internal {
        feedBtc.set(int256(price * 1e8 / 1e6), block.timestamp, block.timestamp);
        feedEurc.set(1e8, block.timestamp, block.timestamp);
        _setSpot(price);
    }

    /// @dev Only the pools: EURC/USDC at 1:1, USDC/cbBTC at `price` USDC base units per cbBTC.
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
        // Since MIN_BAND_BPS the lower bound is 125 (was 1): a band below the maximum loss per run is not allowed.
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

    /// @notice MIN_BAND_BPS = FEE_BPS + MAX_SLIPPAGE_BPS: 124 reverts, 125 is allowed.
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
        p.maxCorrectionBps = 9; // below MIN_CORRECTION_BPS
        _expectInvalid(p);
        p.maxCorrectionBps = 10_001;
        _expectInvalid(p);
    }

    /// @dev H-2 / L-1: the dust configuration from the audit (minTrade 1, cap 1 bps) can no longer be set.
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
        // The fee of the smallest allowed run is 0.05 EURC; the reward is at most half of that (self-audit L-D).
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
        p.maxSlippageBps = 30; // old lower bound, now below MIN_SLIPPAGE_BPS (60)
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

    /// @dev L-A: `offset + limit` overflowed with `offset >= 1` and `limit = type(uint256).max` (Panic 0x11).
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
        // 1,000 EURC, 0 cbBTC: drift 80%, cap 10% -> 100 EURC.
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
        // 0 EURC, 0.0125 cbBTC (= 1,000 EURC): drift 20%, cap 10% -> 100 EURC = 125_000 sats.
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
        // Previously sell slippage could push the fee below the reward: 150 EURC in cbBTC, cap 10% = 15 < floor 20
        // -> sell 25_000 sats (20 EURC); router delivers 1% less (19.8 EURC), fee was 49_500. Since L-B the fee is
        // taken over max(received, expected) = 20 EURC -> 50_000. Since self-audit L-D the reward is at most half
        // of the fee: 25_000 to the keeper, 25_000 to the treasury. The cap itself is covered in
        // test_takeFee_cappedAtMaxFee.
        _setUser(alice, 0, 187_500, _defaultParams());
        router.setSlippageBps(100);
        r.execute(alice, keeper);
        assertEq(cbbtc.balanceOf(alice), 187_500 - 25_000);
        assertEq(eurc.balanceOf(keeper), 25_000);
        assertEq(eurc.balanceOf(treasury), 25_000);
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
        assertEq(delta, 40e6); // L-C: what execute actually trades, not the correction of 100 EURC
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
        // The correction is mathematically never larger than the balance; check that the balance is the upper bound.
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
        // Second run: total = 900 + 124_687 sats * 80_000 = 900e6 + 99_749_600 -> cap 10% = 99_974_960.
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
        // 200 EURC + 0.01 cbBTC (800 EURC): fraction exactly 80%.
        _setUser(alice, 200e6, 1_000_000, _defaultParams());
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        r.execute(alice, keeper);

        // 240 EURC + 760 EURC in cbBTC: drift 4% < band 5%.
        _setUser(bob, 240e6, 950_000, _defaultParams());
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        r.execute(bob, keeper);
    }

    function test_execute_revertsNothingToDoAtBandEdge() public {
        // drift exactly 5% = band -> nothing (<=).
        _setUser(alice, 250e6, 937_500, _defaultParams());
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        r.execute(alice, keeper);
    }

    function test_execute_revertsNothingToDoBelowMinTrade() public {
        // 30 EURC + 70 EURC cbBTC: correction 10 EURC < min 20.
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

    /// @notice Self-audit 2026-09-17, Info-G: a `startedAt` in the future gives `SequencerDown`, not a Panic.
    function test_execute_revertsSequencerDownWhenStartedAtInFuture() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        sequencer.set(0, vm.getBlockTimestamp() + 1, vm.getBlockTimestamp() + 1);
        vm.expectRevert(Rebalancer.SequencerDown.selector);
        r.execute(alice, keeper);
        vm.expectRevert(Rebalancer.SequencerDown.selector);
        r.quote();
        (bool due,) = r.isDue(alice);
        assertFalse(due);
    }

    /// @dev L-9: an uninitialized round (startedAt == 0) of the uptime feed does not count as "up".
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
        // M-2: hourly feed (0x9867…01e0) with a 15-minute margin.
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
        // cbBTC/USD = 1e-8 and EURC/USD = 1: 1 * 1e6 / 1e8 = 0. Both answers are > 0, so only the
        // product check catches this.
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
        // Same price, different route: EURC/USD 1.16 and USDC/cbBTC 92,800 USDC -> 80,000 EURC per cbBTC.
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
        // Pools with reversed token0/token1 give the same spot.
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

        // Exactly at the limit (0.5%) is allowed; the sqrt rounding makes the spot at most 1 unit lower.
        _setSpot(PRICE * (BPS + 50) / BPS);
        (due,) = r.isDue(alice);
        assertTrue(due);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 900e6);
    }

    function test_execute_spotCheckIgnoresPoolFeesOnly() public {
        // Only the EURC/USDC pool shifted by 0.4%: below the limit, the run goes ahead.
        _setUser(alice, 1000e6, 0, _defaultParams());
        poolEurcUsdc.setPrice(1e6, 1.004e6);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 900e6);
    }

    /// @dev Test gap oracle 4: only the EURC/USDC pool shifted by more than 0.5% (the thin pool, the real
    ///      attack route) also blocks the run.
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

    /// @dev Test gap oracle 5 (ORC-3): feed and spot move independently. Feed +0.3% and spot -0.3% is 0.6%
    ///      combined and blocks; feed +0.3% with spot +0.1% (new EURC feed, deviation 0.1%) does not.
    function test_execute_feedAndSpotDivergeIndependently() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        feedBtc.set(int256(PRICE * 1e8 / 1e6) * 1003 / 1000, START, START);
        _setSpot(PRICE * 997 / 1000);
        (bool due,) = r.isDue(alice);
        assertFalse(due, "0.6% apart: blocked");
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.SpotDeviatesFromOracle.selector, r.spot(), r.quote()));
        r.execute(alice, keeper);

        _setSpot(PRICE * 1001 / 1000);
        (due,) = r.isDue(alice);
        assertTrue(due, "0.2% apart: allowed");
        r.execute(alice, keeper);
    }

    /// @dev M-1: the spot is also checked after the swap. A run whose own price impact (or a
    ///      front-run shift plus impact) moves the spot outside 0.5% of the oracle still reverts and books nothing.
    function test_execute_revertsWhenSpotDeviatesAfterSwap() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        // Beforehand +0.4% (allowed); the swap itself moves the pool to +0.6%.
        poolEurcUsdc.setPrice(1e6, 1.004e6);
        router.setPoolShift(poolEurcUsdc, 1e6, 1.006e6);
        (bool due,) = r.isDue(alice);
        assertTrue(due, "within the limit beforehand");
        vm.expectPartialRevert(Rebalancer.SpotDeviatesFromOracle.selector);
        r.execute(alice, keeper);
        assertEq(r.lastExecutedAt(alice), 0);
        assertEq(eurc.balanceOf(alice), 1000e6, "nothing booked");

        // Sell side: same rule.
        _setUser(bob, 0, 1_250_000, _defaultParams());
        router.setPoolShift(poolEurcUsdc, 1.006e6, 1e6);
        vm.expectPartialRevert(Rebalancer.SpotDeviatesFromOracle.selector);
        r.execute(bob, keeper);
        assertEq(cbbtc.balanceOf(bob), 1_250_000);

        // Impact that stays within both limits is allowed: 0.40% -> 0.44% is within 0.5% of the oracle and within
        // MAX_BLOCK_MOVE_BPS of the price at the start of the block. (0.4% -> 0.5% would now fail on the block window.)
        router.setPoolShift(poolEurcUsdc, 1e6, 1.0044e6);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 900e6);
    }

    /// @dev Test gap oracle 9: extreme sqrtPriceX96 (Uniswap's MIN/MAX_SQRT_RATIO) causes no Panic towards
    ///      the outside via isDue/dueOwners; execute reverts cleanly.
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

    /// @dev Lead 10: with sqrtPriceX96 < 2^48, ratioX96 = sqrtPriceX96² / 2^96 was equal to 0 and `_spotOut` divided
    ///      by 0 (Panic 0x12). With ratioX128 the spot stays computable; the run reverts cleanly on the spot check.
    function test_spot_smallSqrtPriceDoesNotDivideByZero() public {
        uint160 small = uint160(1 << 40);
        assertEq(Math.mulDiv(small, small, 1 << 96), 0, "setup: the old ratioX96 is 0");
        _setUser(alice, 1000e6, 0, _defaultParams());

        // USDC/cbBTC pool: cbBTC is token1, so usdcPerBtc = 1e8 * 2^128 / 2^16; EURC/USDC is at 1:1.
        poolUsdcCbbtc.setSqrtPriceX96(small);
        assertEq(r.spot(), 1e8 << 112);
        // EURC/USDC pool: USDC is token1, so EURC = usdcPerBtc * 2^128 / 2^16.
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

    /// @dev Test gap oracle 8 (ORC-7): on an EURC depeg (feed 0.90 USD, pool follows) the price in EURC rises,
    ///      the cbBTC share rises and the next run sells cbBTC for the depegged EURC. Design choice
    ///      (EURC as numeraire); pinned here so that it does not change unnoticed.
    function test_isDue_eurcDepegTurnsHoldIntoSell() public {
        // 2,000 EURC + 0.1 cbBTC: exactly 80/20 at EURC/USD = 1, band 1.25% (MIN_BAND_BPS; was 1%, no longer allowed).
        // The depeg pushes the share to ~81.6%, so also outside this band.
        Rebalancer.Params memory p = _defaultParams();
        p.bandBps = 125;
        _setUser(alice, 2000e6, 10_000_000, p);
        (bool due,) = r.isDue(alice);
        assertFalse(due);

        feedEurc.set(0.9e8, START, START);
        poolEurcUsdc.setPrice(1e6, 0.9e6);
        uint256 price = r.quote();
        assertEq(price, Math.mulDiv(80_000e8, 1e6, 0.9e8), "price in EURC rises ~11%");
        assertEq(r.quoteChecked(), price);
        int256 delta;
        (due, delta) = r.isDue(alice);
        assertTrue(due);
        assertLt(delta, 0, "sells cbBTC for depegged EURC");
    }

    // sweep and rewardTo ────────────────────────────────────────────────────────────────────────────────

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
        // Empty balance: no transfer, no revert.
        r.sweep(eurc);
        assertEq(eurc.balanceOf(treasury), 123e6);
    }

    /// @dev M-6: a blacklisted TREASURY lets the rebalance go ahead; the treasury share of the fee stays in the
    ///      contract (FeeRetained) and `sweep` collects it once the blacklist is lifted.
    function test_execute_continuesWhenTreasuryBlacklistedAndSweepRecoversFee() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        eurc.setBlacklisted(treasury, true);

        uint256 amountOut = Math.mulDiv(99_750_000, 1e8, PRICE);
        vm.expectEmit(false, false, false, true, address(r));
        emit Rebalancer.FeeRetained(200_000);
        vm.expectEmit(true, false, false, true, address(r));
        emit Rebalancer.Executed(alice, true, 100e6, 250_000, 50_000, keeper, amountOut, PRICE, 1000e6, 0);
        r.execute(alice, keeper);

        assertEq(eurc.balanceOf(alice), 900e6, "run went ahead");
        assertEq(cbbtc.balanceOf(alice), amountOut);
        assertEq(eurc.balanceOf(keeper), 50_000, "reward paid as usual");
        assertEq(eurc.balanceOf(treasury), 0);
        assertEq(eurc.balanceOf(address(r)), 200_000, "treasury share stays in the contract");
        assertEq(r.lastExecutedAt(alice), uint64(START));

        // While the treasury is blacklisted, sweep cannot move it out; afterwards it can.
        vm.expectRevert("Blacklistable: account is blacklisted");
        r.sweep(eurc);
        eurc.setBlacklisted(treasury, false);
        r.sweep(eurc);
        assertEq(eurc.balanceOf(address(r)), 0);
        assertEq(eurc.balanceOf(treasury), 200_000);
    }

    /// @dev M-6, sell side and rewardTo == address(0): the full fee stays behind, the owner gets exactly
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

        // A later run does not count the leftover balance as "received".
        vm.warp(START + 1 days);
        _setPrice(PRICE);
        eurc.setBlacklisted(treasury, false);
        _setUser(bob, 0, 1_250_000, _defaultParams());
        r.execute(bob, address(0));
        assertEq(eurc.balanceOf(bob), 99_750_000);
        assertEq(eurc.balanceOf(address(r)), 250_000, "alice's remainder is still there");
        assertEq(eurc.balanceOf(treasury), 250_000, "bob's fee did arrive");
    }

    /// @dev M-6: a blacklisted rewardTo costs the caller its reward, not the owner its run; the whole fee
    ///      then goes to the treasury and the event reports reward 0.
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

    /// @dev M-6: with TREASURY as rewardTo, both the reward and the treasury transfer fail once the treasury
    ///      is blacklisted, and the whole fee stays in the contract. The run is still booked; `sweep` gets it later.
    function test_execute_continuesWhenTreasuryBlacklisted() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        eurc.setBlacklisted(treasury, true);
        vm.expectEmit(false, false, false, true, address(r));
        emit Rebalancer.FeeRetained(250_000);
        r.execute(alice, treasury);
        assertEq(r.lastExecutedAt(alice), uint64(START));
        assertEq(eurc.balanceOf(address(r)), 250_000);
    }

    /// @dev Test gap execute 7: `sweep` calls arbitrary code with msg.sender = Rebalancer. `balanceOf` goes
    ///      via STATICCALL (view in IERC20), so a fake token cannot even register an owner: the attempt reverts
    ///      and nothing changes.
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

    /// @dev Test gap execute 7 (EX-09), the writing side: `transfer` of a fake token does run with
    ///      write access. Re-entering a due owner's run via `execute` hits the reentrancy guard; the only thing
    ///      that works is registering the fake token itself as owner (polluting `_owners`), without balance or effect.
    function test_sweep_maliciousTokenReentryCanOnlyRegisterItself() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        ReentrantSweepToken evil = new ReentrantSweepToken(r, alice);

        r.sweep(IERC20(address(evil)));

        assertEq(
            bytes4(evil.executeRevertData()),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            "execute was entered"
        );
        assertEq(eurc.balanceOf(alice), 1000e6);
        assertEq(r.lastExecutedAt(alice), 0);
        assertEq(r.ownerCount(), 2);
        assertEq(r.owners(1, 1)[0], address(evil), "fake token is registered as owner");
        (bool due,) = r.isDue(address(evil));
        assertFalse(due, "never due without balance");
        assertEq(eurc.balanceOf(address(r)), 0);

        // The real owner then runs as usual.
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 900e6);
    }

    /// @notice Self-audit 2026-09-17, L-D: an owner who calls `execute` for itself with `rewardTo` = itself
    ///         and only does runs at the floor (`maxCorrectionBps` 10, `minTradeEurc` 20 EURC, wallet 20,000 EURC),
    ///         still pays half of the fee to the treasury. Previously the whole fee went back to the owner.
    function test_execute_selfRewardAtFloorStillPaysTreasuryHalf() public {
        Rebalancer.Params memory p = _defaultParams();
        p.maxCorrectionBps = 10;
        p.interval = 1 hours;
        _setUser(alice, 20_000e6, 0, p);
        uint256 runs = 24;
        for (uint256 i; i < runs; i++) {
            if (i > 0) {
                vm.warp(vm.getBlockTimestamp() + 1 hours);
                vm.roll(block.number + 1);
                _setPrice(PRICE);
            }
            (, int256 delta) = r.isDue(alice);
            assertEq(delta, int256(20e6), "run at the floor");
            vm.prank(alice);
            r.execute(alice, alice);
        }
        assertEq(eurc.balanceOf(treasury), runs * 25_000, "treasury gets half of 0.05 EURC per run");
        assertEq(20_000e6 - eurc.balanceOf(alice), runs * (20e6 - 25_000), "owner pays half of the fee net");
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

    /// @dev L-2: spot at +0.5% (allowed) plus 0.1% pool fees is 0.6% combined versus the oracle; with the new
    ///      lower bound of 60 bps such a run is still just executable. With 30 bps it would revert structurally.
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

    /// @dev L-1: if the router delivers 0 cbBTC (only possible if amountOutMinimum is 0 due to rounding), the
    ///      buy reverts instead of giving EURC away. Forced here with an absurd price.
    function test_execute_revertsNoOutputWhenBuyYieldsZero() public {
        uint256 hugePrice = 1e16; // 10 billion EURC per cbBTC: 99.75 EURC buys 0 sats
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
        // L-B: fee over max(received 99 EURC, expected 100 EURC), so over the oracle value.
        assertEq(eurc.balanceOf(keeper) + eurc.balanceOf(treasury), 100e6 * 25 / BPS);
        assertEq(eurc.balanceOf(alice), 99e6 - 100e6 * 25 / BPS);
    }

    /// @dev L-B, worked example from the audit: sale worth 20.000160 EURC, received 19.980159 EURC
    ///      (10 bps router slippage). Previously the fee was 25 bps over `received` = 49,950, below the reward, and
    ///      the caller got everything. Now the fee is 25 bps over the oracle value = 50,000: exactly the reward, as
    ///      MIN_TRADE_FLOOR promises. Just above the floor (20.01 EURC) the treasury now gets a share too.
    function test_execute_sellFeeFloorUsesExpectedOut() public {
        _sellAtValue(alice, 80_000_640_000, keeper); // 25,000 sats × 80,000.64 = 20.000160 EURC
        assertEq(eurc.balanceOf(keeper), 25_000, "reward is half of the fee (L-D)");
        assertEq(eurc.balanceOf(treasury), 25_000, "treasury gets the other half");
        assertEq(eurc.balanceOf(alice), 19_980_159 - 50_000);
        assertGt(19_980_159 * 25 / BPS, 0);
        assertLt(19_980_159 * 25 / BPS, 50_000, "setup: old fee was below the reward");

        address keeper2 = makeAddr("keeper2");
        _sellAtValue(bob, 80_040_000_000, keeper2); // 25,000 sats × 80,040 = 20.010000 EURC, received 19.989990
        assertEq(eurc.balanceOf(keeper2), 25_012, "reward = fee / 2 (fee 50,025)");
        assertEq(eurc.balanceOf(treasury), 25_000 + 25_013);
        assertLe(19_989_990 * 25 / BPS, 50_000, "setup: old fee gave the treasury 0");
    }

    /// @dev Sale of exactly 25,000 sats (allowance) at `price`, with 10 bps router slippage.
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

    /// @dev L-B: the fee is capped at the received amount. Unreachable via the router (minOut is at most
    ///      MAX_SLIPPAGE_BPS below expectedOut), so here via a harness that calls `_takeFee` directly.
    function test_takeFee_cappedAtMaxFee() public {
        RebalancerFeeHarness h = new RebalancerFeeHarness(_deployment());
        eurc.mint(address(h), 1_000e6);
        (uint256 fee, uint256 reward) = h.takeFee(1_000e6, 1_000, keeper);
        assertEq(fee, 1_000, "capped at maxFee");
        assertEq(reward, 500, "reward capped at half of the fee");
        assertEq(eurc.balanceOf(keeper), 500);
        (fee, reward) = h.takeFee(1_000e6, type(uint256).max, address(0));
        assertEq(fee, 2_500_000);
        assertEq(reward, 0);
        assertEq(eurc.balanceOf(treasury), 500 + 2_500_000, "half of the first fee plus the whole second");
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
        // A revert keeps the owner due: the contract does not remember failed attempts. The keepers therefore
        // simulate first and track a cool-down per owner themselves.
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

        // updatedAt in the future -> StaleFeed in _readFeed, also caught.
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

    /// @dev L-C: the delta is what `execute` actually sells (capped at the allowance), not the correction of
    ///      100 EURC. Previously this test pinned the old behaviour (delta -100 EURC).
    function test_isDue_deltaIsAllowanceBoundedAmount() public {
        _setUser(alice, 0, 1_250_000, _defaultParams());
        vm.prank(alice);
        cbbtc.approve(address(r), 30_000); // 24 EURC: above the floor, far below the correction
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, -24e6);
        vm.expectEmit(true, false, false, false, address(r));
        emit Rebalancer.Executed(alice, false, 30_000, 0, 0, keeper, 0, 0, 0, 0);
        r.execute(alice, keeper);
        assertEq(cbbtc.balanceOf(alice), 1_250_000 - 30_000);
    }

    /// @dev L-C, example from the audit: wallet 10,000 EURC, correction 1,000 EURC, allowance 20 EURC. `isDue`
    ///      reported 1,000 EURC while `execute` trades 20 EURC; now it reports 20 EURC.
    function test_isDue_deltaMatchesExecutedAmountWhenAllowanceBinds() public {
        _setUser(alice, 10_000e6, 0, _defaultParams());
        (, int256 unbounded) = r.isDue(alice);
        assertEq(unbounded, 1_000e6, "setup: correction 1,000 EURC");
        vm.prank(alice);
        eurc.approve(address(r), 20e6);
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, 20e6);
        r.execute(alice, keeper);
        assertEq(eurc.balanceOf(alice), 10_000e6 - uint256(delta), "execute trades exactly the reported delta");
    }

    // dueOwners ─────────────────────────────────────────────────────────────────────────────────────────

    function test_dueOwners_filtersAndPaginatesLikeIsDue() public {
        address[6] memory users;
        for (uint256 i = 0; i < 6; i++) {
            users[i] = makeAddr(string(abi.encodePacked("due", i)));
        }
        _setUser(users[0], 1000e6, 0, _defaultParams()); // due: buy
        _setUser(users[1], 200e6, 1_000_000, _defaultParams()); // within band
        _setUser(users[2], 0, 1_250_000, _defaultParams()); // due: sell
        Rebalancer.Params memory inactive = _defaultParams();
        inactive.active = false;
        _setUser(users[3], 1000e6, 0, inactive); // inactive
        _setUser(users[4], 1000e6, 0, _defaultParams()); // just executed -> not due
        r.execute(users[4], keeper);
        _setUser(users[5], 1000e6, 0, _defaultParams()); // due, but allowance 0
        vm.prank(users[5]);
        eurc.approve(address(r), 0);

        address[] memory due = r.dueOwners(0, 100);
        assertEq(due.length, 2);
        assertEq(due[0], users[0]);
        assertEq(due[1], users[2]);
        for (uint256 i = 0; i < 6; i++) {
            (bool isDueNow,) = r.isDue(users[i]);
            assertEq(isDueNow, i == 0 || i == 2, "dueOwners differs from isDue");
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

    /// @dev Test gap execute 2 and mandate 1: a keeper that walks through `dueOwners` page by page (like
    ///      keeper.ts, here with pages of 5) reaches every due owner, including number 6 and beyond. Small wallets
    ///      with allowed params (10 EURC, below the floor) sit in between, are never due and crowd out no one.
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

        assertEq(executed, count / 2, "not every due owner reached");
        for (uint256 i = 0; i < count; i++) {
            bool isSmallWallet = i % 2 == 0;
            assertEq(r.lastExecutedAt(users[i]), isSmallWallet ? 0 : uint64(START));
        }
        assertEq(eurc.balanceOf(users[count - 1]), 900e6, "the last owner was executed too");
        assertEq(r.dueOwners(0, count).length, 0, "after the round nobody is due anymore");
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
        assertEq(eurc.balanceOf(alice), 1000e6, "no funds moved");
        assertEq(r.lastExecutedAt(alice), 0);
        // The allowance is still set by the user; there is just nothing left that can use it.
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
        // The registration itself stays readable.
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

        // Revoking works, even for someone who never had settings.
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

        // Setting an active mandate (new or again) reverts.
        p.active = true;
        vm.expectRevert(Rebalancer.ContractRetired.selector);
        vm.prank(alice);
        r.setParams(p);
        vm.expectRevert(Rebalancer.ContractRetired.selector);
        vm.prank(keeper);
        r.setParams(p);

        // Inactive settings are still validated.
        p.active = false;
        p.bandBps = 0;
        vm.expectRevert(Rebalancer.InvalidParams.selector);
        vm.prank(alice);
        r.setParams(p);
    }

    function test_retire_sweepStillWorks() public {
        _setUser(alice, 1000e6, 0, _defaultParams());
        eurc.setBlacklisted(treasury, true);
        r.execute(alice, keeper); // 0.20 EURC treasury share stays behind (FeeRetained)
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
        // The treasury may be an EOA.
        d = _deployment();
        d.treasury = eoa;
        new Rebalancer(d);
    }

    /// @dev L-4: both feeds must have 8 decimals; the conversion divides them by each other.
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

        // Both at 18 is also wrong: the constant is 8, not "equal to each other".
        MockAggregator btc18 = new MockAggregator(18, "cbBTC / USD");
        d = _deployment();
        d.feedCbbtcUsd = address(btc18);
        d.feedEurcUsd = address(feed18);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedFeedDecimals.selector, address(btc18)));
        new Rebalancer(d);
    }

    /// @dev Review I-4: EURC 6, cbBTC 8 and USDC 6 decimals; the units and lower bounds are fixed on that basis.
    function test_constructor_rejectsTokenWithWrongDecimals() public {
        address[3] memory tokens = [address(eurc), address(cbbtc), address(usdc)];
        uint8[3] memory wrong = [uint8(18), 6, 8];
        for (uint256 i; i < 3; i++) {
            vm.mockCall(tokens[i], abi.encodeWithSignature("decimals()"), abi.encode(wrong[i]));
            vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedTokenDecimals.selector, tokens[i]));
            new Rebalancer(_deployment());
            vm.clearMockedCalls();
        }
        // With the correct decimals it goes through.
        new Rebalancer(_deployment());
    }

    /// @dev Review I-4: a token without `decimals()` is not a valid token for this contract; the deploy reverts.
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

    /// @dev Lead 1: a pool with the correct tokens but a fee tier other than POOL_FEE is rejected, even if the
    ///      factory would register it under 500.
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

    /// @dev Review L-1: the run size assumes at most one tick boundary in the window, and that only holds for
    ///      tickSpacing 10. A pool with a different tickSpacing is rejected.
    function test_constructor_rejectsPoolWithWrongTickSpacing() public {
        poolEurcUsdc.setTickSpacing(1);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedTickSpacing.selector, address(poolEurcUsdc)));
        new Rebalancer(_deployment());
        poolEurcUsdc.setTickSpacing(10);
        poolUsdcCbbtc.setTickSpacing(60);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedTickSpacing.selector, address(poolUsdcCbbtc)));
        new Rebalancer(_deployment());
    }

    /// @dev Lead 1: a pool with the correct tokens and fee that is not the pool of the router's factory (a
    ///      replica pool, or a pool from another factory) is rejected.
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

        // The real pools, but the router points to another factory in which they are not registered.
        MockUniswapV3Factory otherFactory = new MockUniswapV3Factory();
        router.setFactory(address(otherFactory));
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.PoolNotFromRouterFactory.selector, address(poolEurcUsdc)));
        new Rebalancer(_deployment());

        // Router without factory.
        router.setFactory(address(0));
        vm.expectRevert(Rebalancer.ZeroAddress.selector);
        new Rebalancer(_deployment());

        // Back to the correct factory: the deploy succeeds.
        router.setFactory(address(factory));
        new Rebalancer(_deployment());
    }

    // Reference vectors (PHP AutoTradeStrategy::rebalanceAmount) ───────────────────────────────────────

    struct Vector {
        uint256 cash; // EURC base units
        uint256 position; // EURC base units
        uint16 targetBps;
        uint16 bandBps;
        uint16 capBps;
        uint64 minTrade;
        int256 amount; // signed, EURC base units; + buy, - sell
    }

    /// @dev Price 100 EURC per cbBTC, so that 1 sat == 1 EURC base unit and the position converts exactly.
    uint256 internal constant VECTOR_PRICE = 100e6;

    /// @dev Vectors from the PHP reference, with `minTrade` at the contract floor of 20 EURC. As a result v[4],
    ///      v[6] and v[12] differ from the original PHP set (minTrade 5): v[4] is scaled ×10, and for v[6] and
    ///      v[12] the cap floor is now 20 instead of 10 (cap = max(total × 10%, minTrade)).
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
            assertEq(Math.mulDiv(btc, VECTOR_PRICE, 1e8), v[i].position, "position not exactly convertible");
            _setUser(user, v[i].cash, btc, p);

            (bool due, int256 delta) = r.isDue(user);
            if (v[i].amount == 0) {
                assertFalse(due, string(abi.encodePacked("vector ", vm.toString(i), ": due")));
                assertEq(delta, 0, string(abi.encodePacked("vector ", vm.toString(i), ": delta")));
                continue;
            }
            assertTrue(due, string(abi.encodePacked("vector ", vm.toString(i), ": not due")));
            assertEq(delta > 0, v[i].amount > 0, string(abi.encodePacked("vector ", vm.toString(i), ": direction")));
            assertApproxEqAbs(delta, v[i].amount, 2, string(abi.encodePacked("vector ", vm.toString(i), ": amount")));
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
        cash = bound(cash, 0, 1e15); // <= 1 billion EURC
        btc = bound(btc, 0, 1e13); // <= 100,000 cbBTC
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
        // When selling, the delta is the rounded-up sats amount at the price: up to 1 sat above the cap.
        assertLe(absDelta, capEurc + PRICE / 1e8, "correction above cap");
        assertGe(absDelta, p.minTradeEurc, "correction below minTrade");

        uint256 treasuryBefore = eurc.balanceOf(treasury);
        uint256 keeperBefore = eurc.balanceOf(keeper);
        r.execute(alice, rewardTo);

        assertEq(eurc.balanceOf(address(r)), 0, "EURC residual balance");
        assertEq(cbbtc.balanceOf(address(r)), 0, "cbBTC residual balance");
        assertEq(r.lastExecutedAt(alice), uint64(block.timestamp));

        uint256 feePaid = (eurc.balanceOf(treasury) - treasuryBefore) + (eurc.balanceOf(keeper) - keeperBefore);
        if (delta > 0) {
            uint256 amountIn = cash - eurc.balanceOf(alice);
            assertLe(amountIn, capEurc, "amountIn above cap");
            assertLe(amountIn, absDelta, "amountIn above correction");
            assertLe(amountIn, Math.min(cash, allowanceEurc), "amountIn above balance/allowance");
            assertGe(amountIn, p.minTradeEurc, "amountIn below minTrade");
            uint256 fee = Math.mulDiv(amountIn, 25, BPS);
            assertEq(feePaid, fee, "fee != reward + treasury");
            assertEq(eurc.balanceOf(address(router)), amountIn - fee, "swapIn + fee != amountIn");
            assertEq(cbbtc.balanceOf(alice) - btc, Math.mulDiv(amountIn - fee, 1e8, PRICE), "output to owner");
            if (withReward) assertEq(eurc.balanceOf(keeper) - keeperBefore, Math.min(50_000, fee / 2));
            else assertEq(eurc.balanceOf(keeper), keeperBefore);
        } else {
            uint256 btcIn = btc - cbbtc.balanceOf(alice);
            uint256 valueIn = Math.mulDiv(btcIn, PRICE, 1e8);
            // wantBtc is rounded up (M-5): at most 1 sat of value above cap/correction.
            uint256 oneSat = PRICE / 1e8;
            assertLe(valueIn, capEurc + oneSat, "sale value above cap");
            assertLe(valueIn, absDelta + oneSat, "sale value above correction");
            assertLe(btcIn, Math.min(btc, allowanceBtc), "btcIn above balance/allowance");
            assertGe(valueIn, p.minTradeEurc, "sale value below minTrade");
            uint256 fee = Math.mulDiv(valueIn, 25, BPS);
            assertEq(feePaid, fee, "fee != reward + treasury");
            assertEq(eurc.balanceOf(alice) - cash, valueIn - fee, "output to owner");
            assertEq(cbbtc.balanceOf(address(router)), btcIn);
            if (withReward) assertEq(eurc.balanceOf(keeper) - keeperBefore, Math.min(50_000, fee / 2));
            else assertEq(eurc.balanceOf(keeper), keeperBefore);
        }
    }

    /// @dev Test gap math 1 (M-01): with an arbitrary, non-round price and full allowance an owner is due
    ///      exactly when the capped correction reaches minTrade, with that correction as delta; if it is due,
    ///      `execute` also succeeds (no NothingToDo from rounding in the conversion to sats).
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
        assertEq(due, expectDue, "due differs from correction >= minTrade");
        if (!expectDue) {
            assertEq(delta, 0);
            vm.expectRevert(Rebalancer.NothingToDo.selector);
            r.execute(alice, keeper);
            return;
        }
        // L-C: the delta is the actual input amount. When selling, that is the rounded-up sats amount
        // (at most the balance) at the price, so up to 1 sat of value above the correction.
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
    /// @dev Ghost counters per revert reason (test gap math 7): NothingToDo is expected, "Too little received" or a
    ///      spot deviation points to a liveness failure.
    uint256 public revertsNothingToDo;
    uint256 public revertsInactive;
    uint256 public revertsNotDue;
    uint256 public revertsSpot;
    uint256 public revertsSlippage;
    uint256 public revertsRetired;
    uint256 public revertsBlockMove;
    uint256 public revertsPoolTouched;
    uint256 public revertsOther;
    /// @dev Round ghosts (audit M-1): budget and direction of the current round per owner, and what has already been
    ///      traded in that round. A run is a new round if `interval` has passed since the last run, otherwise a chunk.
    mapping(address actor => uint256) public ghostRoundBudget;
    mapping(address actor => uint256) public ghostRoundSpent;
    mapping(address actor => uint256) public ghostRoundRuns;
    mapping(address actor => bool) public ghostRoundIsBuy;
    bool public roundBudgetExceeded;
    bool public roundDirectionFlipped;
    bool public chunkWithoutRound;
    uint256 public chunksSucceeded;
    /// @dev Retire ghosts: has an `Executed` event still been seen after `retire` (in any handler action)?
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
            bandBps: uint16(bound(band, 125, 9999)), // MIN_BAND_BPS; setParams now rejects lower bands
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

    /// @dev Small steps: a next block (2 s) or exactly CHUNK_INTERVAL, so that chunks of rounds are hit.
    function warpShort(bool chunkInterval) external afterCall {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + (chunkInterval ? 10 minutes : 2));
        _refreshFeeds();
    }

    /// @dev Finite liquidity in one of the two pools, so that runs go in chunks (or 0 = unlimited again).
    function setLiquidity(bool eurcPool, uint128 liquidity) external afterCall {
        uint128 value = liquidity % 4 == 0 ? type(uint128).max : uint128(bound(liquidity, 1e11, 1e14));
        if (eurcPool) poolEurcUsdc.setLiquidity(value);
        else poolUsdcCbbtc.setLiquidity(uint128(Math.min(uint256(value) * 1e3, type(uint128).max)));
    }

    /// @dev A swap by someone else in this block (up to ±10 bp). If it changes the tick, it hits the block check
    ///      (PoolTouchedThisBlock); within the tick, the block window.
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

    /// @dev Test gap oracle 10: shift only the pools (feed stays put), up to ±1%, so that the spot check is also hit
    ///      in the invariant suite.
    function shiftSpot(uint16 bps, bool up) external afterCall {
        bps = uint16(bound(bps, 0, 100));
        (, int256 a,,,) = feedBtc.latestRoundData();
        uint256 price = uint256(a) * 1e6 / 1e8;
        uint256 shifted = up ? price * (10_000 + bps) / 10_000 : price * (10_000 - bps) / 10_000;
        poolUsdcCbbtc.setPrice(shifted, 1e8);
    }

    /// @dev Anyone may sweep; therefore the contract must never keep a balance and the treasury never decreases.
    function sweep(bool eurcToken) external afterCall {
        r.sweep(eurcToken ? eurc : cbbtc);
    }

    /// @dev The treasury halts the contract. Once per run; after that no execute may succeed. Gated on
    ///      the seed (1 in 8), so that most runs keep hitting the normal paths and a third end retired.
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
            // Sells round up by at most 1 sat per run (M-5).
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
        // Only execute may change actor balances: record the new balance.
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

    /// @dev Tokens leave (or reach) an owner wallet only via execute or a handler deposit.
    function invariant_ownerBalancesOnlyMoveThroughExecute() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            assertEq(eurc.balanceOf(a), handler.ghostEurc(a), "EURC moved outside execute");
            assertEq(cbbtc.balanceOf(a), handler.ghostBtc(a), "cbBTC moved outside execute");
        }
    }

    function invariant_contractNeverHoldsBalance() public view {
        assertFalse(handler.contractHeldBalance(), "contract kept a balance after a call");
        assertEq(eurc.balanceOf(address(r)), 0);
        assertEq(cbbtc.balanceOf(address(r)), 0);
    }

    function invariant_treasuryMonotonic() public view {
        assertFalse(handler.treasuryDecreased(), "treasury balance decreased");
        assertGe(eurc.balanceOf(treasury), handler.lastTreasury());
    }

    /// @dev Without router slippage and with the spot within ±1%, an execute may only fail on NothingToDo, Inactive,
    ///      NotDue, spot check, block check, block window or ContractRetired; "Too little received" or anything
    ///      else would be a liveness failure.
    function invariant_executeFailsOnlyForKnownReasons() public view {
        assertEq(handler.revertsSlippage(), 0, "router slippage without cause");
        assertEq(handler.revertsOther(), 0, "unknown revert reason");
        assertEq(
            handler.executes(),
            handler.executesSucceeded() + handler.revertsNothingToDo() + handler.revertsInactive()
                + handler.revertsNotDue() + handler.revertsSpot() + handler.revertsRetired()
                + handler.revertsBlockMove() + handler.revertsPoolTouched()
        );
    }

    /// @dev Shows per run which paths were hit (with -vv), so that a green suite does not rest on empty paths.
    function afterInvariant() public view virtual {
        console.log("execute succeeded:", handler.executesSucceeded(), " of which chunks:", handler.chunksSucceeded());
        console.log("revert BlockMoveExceeded:", handler.revertsBlockMove(), " NotDue:", handler.revertsNotDue());
        console.log("execute total:", handler.executes(), " NothingToDo:", handler.revertsNothingToDo());
        console.log("revert spot:", handler.revertsSpot(), " retired:", handler.revertsRetired());
        console.log(
            "revert inactive:", handler.revertsInactive(), " PoolTouchedThisBlock:", handler.revertsPoolTouched()
        );
    }

    /// @dev Audit M-1: the runs of one round (first run plus chunks) together stay within that round's budget
    ///      (maxCorrectionBps of the value at the first run, at least minTradeEurc).
    function invariant_roundBudgetNeverExceeded() public view {
        assertFalse(handler.roundBudgetExceeded(), "round traded more than its budget");
    }

    /// @dev Audit M-1: a chunk always goes in the direction of the round, and only while a round is running.
    function invariant_chunkKeepsRoundDirection() public view {
        assertFalse(handler.roundDirectionFlipped(), "chunk in the opposite direction of the round");
        assertFalse(handler.chunkWithoutRound(), "chunk without a running round");
    }

    /// @dev After retire no Executed event occurs anymore, and the flag never goes back.
    function invariant_noExecutedAfterRetire() public view {
        assertFalse(handler.executedAfterRetire(), "Executed after retire");
        assertLe(handler.retires(), 1, "retire succeeded more than once");
        assertEq(r.retired(), handler.retires() == 1, "retired flag differs from the handler");
        if (r.retired()) {
            assertEq(r.dueOwners(0, handler.actorCount()).length, 0, "dueOwners not empty after retire");
        }
    }
}

/// @dev The same invariants without `retire` in the handler. In deep runs `retire` (1 in 8 per call) almost always
///      halts the contract early, so that rounds and chunks are barely hit. Falls under
///      `--match-contract RebalancerInvariantTest`.
contract RebalancerInvariantTestNoRetire is RebalancerInvariantTest {
    function setUp() public override {
        super.setUp();
        // Initial state: every actor active, with balance and full allowance, and an EURC/USDC pool with finite
        // liquidity (~375 EURC per run), so that larger corrections go in chunks.
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

/// @dev Makes `_takeFee` callable for the cap test.
contract RebalancerFeeHarness is Rebalancer {
    constructor(Deployment memory d) Rebalancer(d) {}

    function takeFee(uint256 feeBase, uint256 maxFee, address rewardTo) external returns (uint256, uint256) {
        return _takeFee(feeBase, maxFee, rewardTo);
    }
}

/// @dev Fake token for `sweep`: `balanceOf` calls Rebalancer's `setParams` with msg.sender = Rebalancer.
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

/// @dev Fake token for `sweep` with a writing `transfer`: tries to get into the run of `victim` and
///      then registers itself as owner.
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
