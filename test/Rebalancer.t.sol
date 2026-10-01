// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Rebalancer} from "../src/Rebalancer.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

/// @dev Shared setup: mock tokens, feeds and router at PRICE, one Rebalancer, and helpers.
///      Under `via_ir` Solidity caches `block.timestamp` within a test function, so after a warp the helpers read the
///      time with `vm.getBlockTimestamp()`.
abstract contract RebalancerTestBase is Test {
    uint256 internal constant PRICE = 80_000e6; // USDC base units per cbBTC
    uint256 internal constant BPS = 10_000;

    MockERC20 internal usdc;
    MockERC20 internal cbbtc;
    MockAggregator internal feed;
    MockAggregator internal sequencer;
    MockRouter internal router;
    Rebalancer internal r;

    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
        vm.warp(1_790_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        cbbtc = new MockERC20("Coinbase Wrapped BTC", "cbBTC", 8);
        feed = new MockAggregator(8, "cbBTC / USD");
        sequencer = new MockAggregator(0, "L2 Sequencer Uptime Status Feed");
        router = new MockRouter(address(usdc), address(cbbtc), PRICE);
        _setPrice(PRICE);
        r = _deploy();
    }

    function _deploy() internal returns (Rebalancer) {
        return
            new Rebalancer(address(usdc), address(cbbtc), address(router), address(feed), address(sequencer), treasury);
    }

    /// @dev Sets feed and pool to `price` and makes both feeds fresh.
    function _setPrice(uint256 price) internal {
        uint256 nowTs = vm.getBlockTimestamp();
        // forge-lint: disable-next-line(unsafe-typecast)
        feed.set(int256(price * 100), nowTs, nowTs);
        sequencer.set(0, nowTs - 2 hours, nowTs);
        router.setPrice(price);
    }

    function _warp(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        _setPrice(router.price());
    }

    function _setUser(address user, uint256 cash, uint256 btc, uint16 targetBps) internal {
        if (cash > 0) usdc.mint(user, cash);
        if (btc > 0) cbbtc.mint(user, btc);
        vm.startPrank(user);
        usdc.approve(address(r), type(uint256).max);
        cbbtc.approve(address(r), type(uint256).max);
        r.setMandate(targetBps, keeper);
        vm.stopPrank();
    }

    function _execute(address owner) internal {
        vm.prank(keeper);
        r.execute(owner, 0);
    }

    function _valueOf(address user) internal view returns (uint256) {
        return usdc.balanceOf(user) + cbbtc.balanceOf(user) * router.price() / 1e8;
    }

    function _shareBps(address user) internal view returns (uint256) {
        return cbbtc.balanceOf(user) * router.price() / 1e8 * BPS / _valueOf(user);
    }
}

// ─── Unit ──────────────────────────────────────────────────────────────────────────────────────────────────

contract RebalancerTest is RebalancerTestBase {
    // ─── Constructor ────────────────────────────────────────────────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(address(r.USDC()), address(usdc));
        assertEq(address(r.CBBTC()), address(cbbtc));
        assertEq(address(r.ROUTER()), address(router));
        assertEq(address(r.FEED_CBBTC_USD()), address(feed));
        assertEq(address(r.SEQUENCER_FEED()), address(sequencer));
        assertEq(r.TREASURY(), treasury);
        assertFalse(r.retired());
    }

    function test_constructor_rejectsZeroTreasury() public {
        vm.expectRevert(Rebalancer.ZeroAddress.selector);
        new Rebalancer(address(usdc), address(cbbtc), address(router), address(feed), address(sequencer), address(0));
    }

    function test_constructor_rejectsRouterWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.NotAContract.selector, stranger));
        new Rebalancer(address(usdc), address(cbbtc), stranger, address(feed), address(sequencer), treasury);
    }

    function test_constructor_rejectsWrongDecimals() public {
        MockERC20 usdc18 = new MockERC20("Wrong", "W", 18);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedDecimals.selector, address(usdc18)));
        new Rebalancer(address(usdc18), address(cbbtc), address(router), address(feed), address(sequencer), treasury);

        // Swapped token addresses: USDC where cbBTC belongs.
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedDecimals.selector, address(cbbtc)));
        new Rebalancer(address(cbbtc), address(usdc), address(router), address(feed), address(sequencer), treasury);

        MockAggregator feed18 = new MockAggregator(18, "cbBTC / USD");
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedDecimals.selector, address(feed18)));
        new Rebalancer(address(usdc), address(cbbtc), address(router), address(feed18), address(sequencer), treasury);
    }

    function test_constructor_rejectsDeadFeeds() public {
        MockAggregator silent = new MockAggregator(8, "cbBTC / USD"); // answer 0, never updated
        vm.expectRevert(Rebalancer.InvalidFeedAnswer.selector);
        new Rebalancer(address(usdc), address(cbbtc), address(router), address(silent), address(sequencer), treasury);

        MockAggregator noSequencer = new MockAggregator(0, "uptime"); // startedAt 0
        vm.expectRevert(Rebalancer.SequencerDown.selector);
        new Rebalancer(address(usdc), address(cbbtc), address(router), address(feed), address(noSequencer), treasury);

        // An address without code where a feed belongs.
        vm.expectRevert();
        new Rebalancer(address(usdc), address(cbbtc), address(router), address(feed), stranger, treasury);
    }

    // ─── setMandate and stop ────────────────────────────────────────────────────────────────────────────────

    function test_setMandate_storesAndEmits() public {
        vm.expectEmit(address(r));
        emit Rebalancer.MandateSet(alice, 8000, keeper);
        vm.prank(alice);
        r.setMandate(8000, keeper);
        (uint16 target, uint64 last, bool unfinished, address k) = r.mandates(alice);
        assertEq(target, 8000);
        assertEq(last, 0);
        assertFalse(unfinished);
        assertEq(k, keeper);
    }

    function test_setMandate_boundsOfTheTarget() public {
        vm.startPrank(alice);
        r.setMandate(500, keeper);
        r.setMandate(9500, address(0)); // no keeper: only the owner may run
        for (uint16 i; i < 3; i++) {
            uint16 bad = i == 0 ? 0 : i == 1 ? 499 : 9501;
            vm.expectRevert(Rebalancer.InvalidTarget.selector);
            r.setMandate(bad, keeper);
        }
        vm.stopPrank();
    }

    function testFuzz_setMandate_validation(uint16 target, address anyKeeper) public {
        bool valid = target >= 500 && target <= 9500;
        vm.prank(alice);
        if (!valid) vm.expectRevert(Rebalancer.InvalidTarget.selector);
        r.setMandate(target, anyKeeper);
        (uint16 stored,,, address k) = r.mandates(alice);
        assertEq(stored, valid ? target : 0);
        assertEq(k, valid ? anyKeeper : address(0));
    }

    function test_setMandate_onlyChangesTheCaller() public {
        _setUser(alice, 1000e6, 0, 8000);
        vm.prank(bob);
        r.setMandate(2000, stranger);
        (uint16 target,,, address k) = r.mandates(alice);
        assertEq(target, 8000);
        assertEq(k, keeper);
    }

    function test_setMandate_doesNotShortenTheInterval() public {
        _setUser(alice, 1000e6, 0, 8000);
        _execute(alice);
        vm.prank(alice);
        r.setMandate(9000, keeper);
        vm.expectRevert(Rebalancer.NotDue.selector);
        _execute(alice);
    }

    function test_stop_thenSetMandateDoesNotShortenTheInterval() public {
        _setUser(alice, 1000e6, 0, 8000);
        _execute(alice);
        vm.startPrank(alice);
        r.stop();
        r.setMandate(8000, keeper);
        vm.stopPrank();
        (, uint64 last,,) = r.mandates(alice);
        assertEq(last, vm.getBlockTimestamp());
        vm.expectRevert(Rebalancer.NotDue.selector);
        _execute(alice);
    }

    function test_stop_revokesAndEmits() public {
        _setUser(alice, 1000e6, 0, 8000);
        vm.expectEmit(address(r));
        emit Rebalancer.MandateSet(alice, 0, address(0));
        vm.prank(alice);
        r.stop();
        vm.expectRevert(Rebalancer.Inactive.selector);
        _execute(alice);
        (bool due,) = r.isDue(alice);
        assertFalse(due);
    }

    // ─── Who may execute ────────────────────────────────────────────────────────────────────────────────────

    function test_execute_ownerMayRunOwnWallet() public {
        _setUser(alice, 1000e6, 0, 8000);
        vm.prank(alice);
        r.execute(alice, 0);
        assertGt(cbbtc.balanceOf(alice), 0);
    }

    function test_execute_ownerWithoutKeeper() public {
        _setUser(alice, 1000e6, 0, 8000);
        vm.prank(alice);
        r.setMandate(8000, address(0));
        vm.expectRevert(Rebalancer.NotOwnerOrKeeper.selector);
        _execute(alice);
        vm.prank(alice);
        r.execute(alice, 0);
    }

    function test_execute_revertsForStranger() public {
        _setUser(alice, 1000e6, 0, 8000);
        vm.prank(stranger);
        vm.expectRevert(Rebalancer.NotOwnerOrKeeper.selector);
        r.execute(alice, 0);
        // Another owner is a stranger too.
        _setUser(bob, 1000e6, 0, 8000);
        vm.prank(bob);
        vm.expectRevert(Rebalancer.NotOwnerOrKeeper.selector);
        r.execute(alice, 0);
    }

    function test_execute_replacedKeeperIsRefused() public {
        _setUser(alice, 1000e6, 0, 8000);
        vm.prank(alice);
        r.setMandate(8000, stranger);
        vm.expectRevert(Rebalancer.NotOwnerOrKeeper.selector);
        _execute(alice);
        vm.prank(stranger);
        r.execute(alice, 0);
    }

    function test_execute_treasuryHasNoSpecialRights() public {
        _setUser(alice, 1000e6, 0, 8000);
        vm.prank(treasury);
        vm.expectRevert(Rebalancer.NotOwnerOrKeeper.selector);
        r.execute(alice, 0);
    }

    // ─── The rule ───────────────────────────────────────────────────────────────────────────────────────────

    function test_execute_buy_exactAmounts() public {
        _setUser(alice, 1000e6, 0, 8000); // drift 800, capped at 10% = 100 USDC
        uint256 fee = 250_000; // 25 bps of 100 USDC
        uint256 out = (100e6 - fee) * 1e8 / PRICE; // 124,687 sats
        vm.expectEmit(address(r));
        emit Rebalancer.Executed(alice, true, 100e6, out, fee, PRICE, 1000e6);
        _execute(alice);
        assertEq(usdc.balanceOf(alice), 900e6);
        assertEq(cbbtc.balanceOf(alice), out);
        assertEq(usdc.balanceOf(address(r)), fee, "fee stays in the contract");
        assertEq(cbbtc.balanceOf(address(r)), 0);
        assertEq(usdc.balanceOf(treasury), 0);
        (, uint64 last,,) = r.mandates(alice);
        assertEq(last, vm.getBlockTimestamp());
    }

    function test_execute_returnsWhatTheSwapDelivered() public {
        _setUser(alice, 1000e6, 0, 8000);
        _setUser(bob, 0, 0.0125e8, 5000);
        router.setWorseBps(10);
        vm.startPrank(keeper);
        // The expectation rounds down twice, like the contract and the pool.
        // forge-lint: disable-next-line(divide-before-multiply)
        assertEq(r.execute(alice, 0), (99_750_000 * 1e8 / PRICE) * 9990 / BPS, "buy: cbBTC");
        assertEq(r.execute(bob, 0), 100e6 * 9990 / BPS, "sell: USDC before the fee");
        vm.stopPrank();
        assertEq(usdc.balanceOf(bob), 99_900_000 - 99_900_000 * 25 / BPS);
    }

    function test_execute_sell_exactAmounts() public {
        _setUser(alice, 0, 0.0125e8, 5000); // 1,000 USDC of cbBTC, drift 500, capped at 100 USDC
        uint256 amountIn = 125_000; // sats worth 100 USDC
        uint256 fee = 250_000;
        vm.expectEmit(address(r));
        emit Rebalancer.Executed(alice, false, amountIn, 100e6 - fee, fee, PRICE, 1000e6);
        _execute(alice);
        assertEq(cbbtc.balanceOf(alice), 0.0125e8 - amountIn);
        assertEq(usdc.balanceOf(alice), 100e6 - fee);
        assertEq(usdc.balanceOf(address(r)), fee);
        assertEq(cbbtc.balanceOf(address(r)), 0);
    }

    function test_execute_correctsTheWholeDriftWhenItFitsTheCap() public {
        // 10,000 USDC of value, 74% cbBTC, target 80%: drift 600 <= cap 1,000.
        _setUser(alice, 2600e6, 0.0925e8, 8000);
        _execute(alice);
        assertApproxEqAbs(_shareBps(alice), 8000, 3, "one run reaches the target");
    }

    function test_execute_buyTakesARemainderBelowTheMinimum() public {
        // 10,000 USDC of value, 69.99% cbBTC, target 80%: drift 1,001 against a cap of 1,000. The cap would leave
        // 1 USDC, too little for a run of its own, so this run takes the whole drift.
        _setUser(alice, 3001e6, 8_748_750, 8000);
        (, int256 delta) = r.isDue(alice);
        assertEq(delta, 1001e6);
        _execute(alice);
        assertEq(usdc.balanceOf(alice), 2000e6);
        (,, bool unfinished,) = r.mandates(alice);
        assertFalse(unfinished);
        assertApproxEqAbs(_shareBps(alice), 8000, 1, "only the fee short of the target");
        _warp(1 days);
        (bool due,) = r.isDue(alice);
        assertFalse(due, "nothing left to follow up");
    }

    function test_execute_sellTakesARemainderBelowTheMinimum() public {
        // 10,000 USDC of value, 60.01% cbBTC, target 50%: drift 1,001 against a cap of 1,000.
        _setUser(alice, 3999e6, 7_501_250, 5000);
        (, int256 delta) = r.isDue(alice);
        assertEq(delta, -1001e6);
        _execute(alice);
        assertEq(cbbtc.balanceOf(alice), 6_250_000, "a position of exactly 5,000 USDC");
        (,, bool unfinished,) = r.mandates(alice);
        assertFalse(unfinished);
        _warp(1 days);
        (bool due,) = r.isDue(alice);
        assertFalse(due, "nothing left to follow up");
    }

    function test_execute_remainderOfExactlyTheMinimumIsLeftToTheNextRun() public {
        // Drift 1,002 = cap + minimum: the 2 USDC left is a run of its own, so this run stays at the cap.
        _setUser(alice, 3002e6, 8_747_500, 8000);
        (, int256 delta) = r.isDue(alice);
        assertEq(delta, 1000e6);
        _execute(alice);
        (,, bool unfinished,) = r.mandates(alice);
        assertTrue(unfinished);
        _warp(1 days);
        (bool due,) = r.isDue(alice);
        assertTrue(due, "the next day finishes it");
    }

    function test_execute_sellRoundingCanLeaveJustUnderTheMinimum() public {
        // 10,000.0008 USDC of value, target 50%: drift 1,002.0004 = cap 1,000.00008 + 2.00032, so the run stays at
        // the cap. Rounded up to whole satoshi it sells 1,250,001 sats, worth 1,000.0008: 0.00072 more than the cap,
        // which leaves 1.9996 USDC of the drift. Less than the minimum, so it is not followed up.
        _setUser(alice, 3998e6, 7_502_501, 5000);
        (, int256 delta) = r.isDue(alice);
        assertEq(delta, -1_000_000_800);
        _execute(alice);
        assertEq(cbbtc.balanceOf(alice), 7_502_501 - 1_250_001);
        (,, bool unfinished,) = r.mandates(alice);
        assertFalse(unfinished, "1.9996 USDC left: just under the minimum");
        _warp(1 days);
        (bool due,) = r.isDue(alice);
        assertFalse(due, "nothing left to follow up");
    }

    function test_execute_takingTheRemainderIsStillBoundedByAllowance() public {
        // Drift 1,001: the run takes the whole drift, then the allowance cuts it.
        _setUser(alice, 3001e6, 8_748_750, 8000);
        vm.prank(alice);
        usdc.approve(address(r), 1000.5e6);
        (, int256 delta) = r.isDue(alice);
        assertEq(delta, 1000.5e6);
        _execute(alice);
        (,, bool unfinished,) = r.mandates(alice);
        assertFalse(unfinished, "0.50 USDC left: less than the minimum, not followed up");

        _setUser(bob, 3001e6, 8_748_750, 8000);
        vm.prank(bob);
        usdc.approve(address(r), 500e6);
        (, delta) = r.isDue(bob);
        assertEq(delta, 500e6);
        _execute(bob);
        (,, unfinished,) = r.mandates(bob);
        assertTrue(unfinished, "501 USDC left: followed up");
    }

    function test_execute_nothingToDoInsideAndOnTheBand() public {
        _setUser(alice, 2200e6, 0.0975e8, 8000); // exactly 78% cbBTC: drift == band
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        _execute(alice);
        (bool due,) = r.isDue(alice);
        assertFalse(due);
        // One sat less cbBTC puts the wallet just outside the band.
        vm.prank(alice);
        assertTrue(cbbtc.transfer(bob, 2));
        (due,) = r.isDue(alice);
        assertTrue(due);
    }

    function test_execute_bandEdgeDoesNotDependOnRounding() public {
        // At a price that is not round, a wallet exactly on the edge of the band is never due.
        _setPrice(79_999_123_457);
        // 4 cbBTC and the price in USDC: exactly 80% cbBTC, so 2 points from both a 78% and an 82% target.
        _setUser(alice, 79_999_123_457, 4e8, 7800);
        _setUser(bob, 79_999_123_457, 4e8, 8200);
        (bool due,) = r.isDue(alice);
        assertFalse(due);
        (due,) = r.isDue(bob);
        assertFalse(due);
    }

    function test_execute_correctionLargerThanTheCapIsFinishedOnTheNextDays() public {
        // All cash, target 71%: seven runs of 10% bring the wallet to ~70%, inside the band. The correction still
        // continues to the target, because the run before it left part of the correction undone.
        _setUser(alice, 10_000e6, 0, 7100);
        uint256 runs;
        for (; runs < 20; runs++) {
            (bool due,) = r.isDue(alice);
            if (!due) break;
            _execute(alice);
            _warp(1 days);
        }
        assertEq(runs, 8);
        assertApproxEqAbs(_shareBps(alice), 7100, 25, "fees leave the share a fraction short of the target");
        (,, bool unfinished,) = r.mandates(alice);
        assertFalse(unfinished);
    }

    function test_execute_unfinishedCorrectionExpiresAfterTwoIntervals() public {
        _setUser(alice, 10_000e6, 0, 7100);
        for (uint256 i; i < 7; i++) {
            _execute(alice);
            _warp(1 days);
        }
        (,, bool unfinished,) = r.mandates(alice);
        assertTrue(unfinished);
        assertLt(_shareBps(alice), 7100 - 50, "short of the target");
        assertGt(_shareBps(alice), 7100 - 200, "inside the band");
        (bool due,) = r.isDue(alice);
        assertTrue(due, "the day after: follow-up run");
        _warp(1 days); // two days after the last run: the band applies again
        (due,) = r.isDue(alice);
        assertFalse(due);
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        _execute(alice);
    }

    function test_setMandate_startsFromTheBandAgain() public {
        _setUser(alice, 10_000e6, 0, 7100);
        for (uint256 i; i < 7; i++) {
            _execute(alice);
            _warp(1 days);
        }
        vm.prank(alice);
        r.setMandate(7100, keeper);
        (,, bool unfinished,) = r.mandates(alice);
        assertFalse(unfinished);
        (bool due,) = r.isDue(alice);
        assertFalse(due);
    }

    function test_execute_followUpGoesToTheTargetFromEitherSide() public {
        // A follow-up ignores the band and trades towards the target at that day's price, so after a price move it can
        // trade back: day 1 buys 1,000 of the 1,030 USDC the wallet is short (the cap); cbBTC rises 3%; day 2 sells
        // 43.26 USDC of cbBTC although the wallet is only 0.43% from its target. Without a follow-up it is not due.
        _setUser(alice, 6030e6, 4_962_500, 5000); // 10,000 USDC of value, 39.7% cbBTC
        _execute(alice);
        (,, bool unfinished,) = r.mandates(alice);
        assertTrue(unfinished);

        _warp(1 days);
        _setPrice(PRICE * 103 / 100);
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, -43_263_296, "sells 43.26 USDC of cbBTC");
        _setUser(bob, usdc.balanceOf(alice), cbbtc.balanceOf(alice), 5000);
        (due,) = r.isDue(bob);
        assertFalse(due, "the same wallet without a follow-up");
        _execute(alice);
    }

    function test_execute_tinyWalletMayTradeMostOfItself() public {
        // Below 20 USDC the 2 USDC minimum is the budget, so a run can be a fifth of the wallet.
        _setUser(alice, 10e6, 0, 9500);
        _execute(alice);
        assertEq(usdc.balanceOf(alice), 8e6, "a run of 2 USDC out of 10");
    }

    function test_execute_emptyWalletIsNothingToDo() public {
        _setUser(alice, 0, 0, 8000);
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        _execute(alice);
    }

    function test_execute_smallWalletUsesTheMinimumAsBudget() public {
        _setUser(alice, 15e6, 0, 8000); // 10% would be 1.50 USDC, below the minimum of 2
        _execute(alice);
        assertEq(usdc.balanceOf(alice), 13e6);
    }

    function test_execute_driftBelowTheMinimumIsNothingToDo() public {
        _setUser(alice, 15e6, 0, 600); // drift 0.90 USDC: outside the band of 0.30, below the minimum of 2
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        _execute(alice);
        (bool due,) = r.isDue(alice);
        assertFalse(due);
    }

    function test_execute_boundedByAllowance() public {
        _setUser(alice, 1000e6, 0, 8000);
        vm.prank(alice);
        usdc.approve(address(r), 40e6);
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, 40e6);
        _execute(alice);
        assertEq(usdc.balanceOf(alice), 960e6);
    }

    function test_execute_allowanceBelowTheMinimumIsNothingToDo() public {
        _setUser(alice, 1000e6, 0, 8000);
        vm.prank(alice);
        usdc.approve(address(r), 500_000);
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        _execute(alice);
        vm.prank(alice);
        usdc.approve(address(r), 0);
        (bool due,) = r.isDue(alice);
        assertFalse(due);
    }

    function test_execute_sellBoundedByAllowance() public {
        _setUser(alice, 0, 0.0125e8, 5000);
        vm.prank(alice);
        cbbtc.approve(address(r), 50_000); // worth 40 USDC
        (, int256 delta) = r.isDue(alice);
        assertEq(delta, -40e6);
        _execute(alice);
        assertEq(cbbtc.balanceOf(alice), 0.0125e8 - 50_000);
    }

    function test_execute_sellAtANonRoundPrice() public {
        _setPrice(79_999_123_457); // the conversion back and forth must not drop the run below the minimum
        _setUser(alice, 0, 0.00025e8, 500); // ~20 USDC of cbBTC, target 5%: the run is exactly the minimum of 2
        (bool due,) = r.isDue(alice);
        assertTrue(due);
        _execute(alice);
    }

    function test_execute_revertsNotDueWithinTheInterval() public {
        _setUser(alice, 1000e6, 0, 8000);
        _execute(alice);
        _warp(1 days - 1);
        vm.expectRevert(Rebalancer.NotDue.selector);
        _execute(alice);
        (bool due,) = r.isDue(alice);
        assertFalse(due);
        _warp(1);
        _execute(alice);
        uint256 totalBeforeSecondRun = 900e6 + uint256(124_687) * PRICE / 1e8;
        assertEq(usdc.balanceOf(alice), 900e6 - totalBeforeSecondRun / 10, "second run: 10% of the new total");
    }

    function test_execute_failedRunDoesNotStartTheInterval() public {
        _setUser(alice, 1000e6, 0, 8000);
        router.setWorseBps(100);
        vm.prank(keeper);
        vm.expectRevert("Too little received");
        r.execute(alice, 0);
        (, uint64 last,,) = r.mandates(alice);
        assertEq(last, 0);
        router.setWorseBps(0);
        _execute(alice);
    }

    function test_execute_revertsInactive() public {
        vm.expectRevert(Rebalancer.Inactive.selector);
        _execute(alice);
    }

    function test_execute_revertsWhenOwnerIsBlacklistedOrTokenPaused() public {
        _setUser(alice, 1000e6, 0, 8000);
        usdc.setBlacklisted(alice, true);
        vm.prank(keeper);
        vm.expectRevert("Blacklistable: account is blacklisted");
        r.execute(alice, 0);
        usdc.setBlacklisted(alice, false);
        cbbtc.setPaused(true);
        vm.prank(keeper);
        vm.expectRevert("Pausable: paused");
        r.execute(alice, 0);
    }

    // ─── Price bound ────────────────────────────────────────────────────────────────────────────────────────

    function test_execute_lowerBound() public {
        _setUser(alice, 1000e6, 0, 8000);
        uint256 expected = 99_750_000 * 1e8 / PRICE; // 124,687 sats
        router.setWorseBps(54);
        _execute(alice);
        // 55 bps below the Chainlink value, rounded up so that rounding never loosens the bound.
        assertEq(router.lastAmountOutMinimum(), expected * 9945 / BPS + 1);

        _setUser(bob, 1000e6, 0, 8000);
        router.setWorseBps(56);
        vm.prank(keeper);
        vm.expectRevert("Too little received");
        r.execute(bob, 0);
    }

    function test_execute_partialFillIsRefused() public {
        // A pool that runs dry takes only part of the input; what it pays for that part is far below the bound.
        _setUser(alice, 1000e6, 0, 8000);
        router.setFillBps(5000);
        vm.prank(keeper);
        vm.expectRevert("Too little received");
        r.execute(alice, 0);
        router.setIgnoreMinimum(true);
        vm.prank(keeper);
        vm.expectPartialRevert(Rebalancer.OutsidePriceBounds.selector);
        r.execute(alice, 0);
        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(usdc.allowance(address(r), address(router)), 0, "a reverted run leaves no allowance behind");
    }

    function test_execute_partialFillWithinTheBoundIsRefused() public {
        // The pool takes 99.6% of the input and pays 0.2% better than Chainlink for it: what arrives lies within the
        // bound on the whole input, but the rest of the input would stay in the contract and be swept to the treasury.
        _setUser(alice, 1000e6, 0, 8000);
        _setUser(bob, 0, 0.0125e8, 5000);
        router.setFillBps(9960);
        router.setWorseBps(-20);
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.OutsidePriceBounds.selector, 124_436, 124_687));
        r.execute(alice, 0);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.OutsidePriceBounds.selector, 99_799_200, 100e6));
        r.execute(bob, 0);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 1000e6, "nothing moved");
        assertEq(cbbtc.balanceOf(bob), 0.0125e8, "nothing moved");
        assertEq(usdc.balanceOf(address(r)) + cbbtc.balanceOf(address(r)), 0);

        router.setFillBps(10_000);
        _execute(alice);
        _execute(bob);
    }

    function test_execute_zeroOutputIsRefused() public {
        _setUser(alice, 1000e6, 0, 8000);
        router.setIgnoreMinimum(true);
        router.setWorseBps(10_000);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.OutsidePriceBounds.selector, 0, 99_750_000 * 1e8 / PRICE));
        r.execute(alice, 0);
    }

    function test_execute_ownBoundHoldsWhenTheRouterDoesNotEnforceTheMinimum() public {
        _setUser(alice, 1000e6, 0, 8000);
        router.setIgnoreMinimum(true);
        router.setWorseBps(300);
        uint256 expected = 99_750_000 * 1e8 / PRICE;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.OutsidePriceBounds.selector, expected * 9700 / BPS, expected));
        r.execute(alice, 0);
        assertEq(usdc.balanceOf(alice), 1000e6, "nothing moved");
    }

    function test_execute_upperBoundStopsARunThatIsTooGood() public {
        // Pool 0.56% better than Chainlink: a stuck feed or a USDC depeg. Buy and sell both stop.
        _setUser(alice, 1000e6, 0, 8000);
        router.setWorseBps(-55);
        _execute(alice);

        _setUser(bob, 1000e6, 0, 8000);
        router.setWorseBps(-56);
        uint256 expected = 99_750_000 * 1e8 / PRICE;
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(Rebalancer.OutsidePriceBounds.selector, expected * 10_056 / BPS, expected)
        );
        r.execute(bob, 0);

        address carol = makeAddr("carol");
        _setUser(carol, 0, 0.0125e8, 5000);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.OutsidePriceBounds.selector, 100_560_000, 100e6));
        r.execute(carol, 0);
    }

    function test_execute_usdcDepegStopsBothDirections() public {
        // USDC at 0.98 USD: the pool asks 2% more USDC per cbBTC than the cbBTC/USD feed says.
        _setUser(alice, 1000e6, 0, 8000);
        _setUser(bob, 0, 0.0125e8, 5000);
        router.setPrice(PRICE * 100 / 98);
        vm.prank(keeper);
        vm.expectRevert("Too little received");
        r.execute(alice, 0); // a buy gets too little cbBTC
        vm.prank(keeper);
        vm.expectRevert(); // a sell gets "too much" USDC: OutsidePriceBounds
        r.execute(bob, 0);
    }

    function test_execute_minAmountOutCanOnlyTighten() public {
        _setUser(alice, 1000e6, 0, 8000);
        uint256 expected = 99_750_000 * 1e8 / PRICE;
        router.setWorseBps(10);

        // Stricter than the pool delivers: refused, although well inside the Chainlink bound.
        vm.prank(keeper);
        vm.expectRevert("Too little received");
        r.execute(alice, expected * 9995 / BPS);

        // Looser than the Chainlink bound: the Chainlink bound stays in force.
        router.setWorseBps(100);
        vm.prank(keeper);
        vm.expectRevert("Too little received");
        r.execute(alice, 1);

        router.setWorseBps(10);
        vm.prank(keeper);
        r.execute(alice, expected * 9990 / BPS);
        assertEq(router.lastAmountOutMinimum(), expected * 9990 / BPS);
    }

    function testFuzz_lossPerRunBoundedByFeePlusDeviation(
        uint256 cash,
        uint256 btc,
        uint16 target,
        int256 worseBps,
        uint256 price
    ) public {
        // Up to 100,000 USDC per cbBTC the smallest run is >= 2,000 sats, so one sat is at most 5 bps of it and a pool
        // 50 bps off the feed still lands inside MAX_DEVIATION_BPS. Above that price a run of the minimum can revert
        // on a pool that far off; it is retried the next hour and loses nothing.
        _setPrice(bound(price, 1_000e6, 100_000e6));
        cash = bound(cash, 0, 1e13);
        btc = bound(btc, 0, 1e11);
        target = uint16(bound(target, 500, 9500));
        worseBps = bound(worseBps, -50, 50);
        _setUser(alice, cash, btc, target);
        router.setWorseBps(worseBps);
        (bool due,) = r.isDue(alice);
        vm.assume(due);

        uint256 valueBefore = _valueOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 btcBefore = cbbtc.balanceOf(alice);
        _execute(alice);
        uint256 usdcMoved = usdcBefore > usdc.balanceOf(alice)
            ? usdcBefore - usdc.balanceOf(alice)
            : usdc.balanceOf(alice) - usdcBefore;
        uint256 btcMoved = btcBefore > cbbtc.balanceOf(alice)
            ? btcBefore - cbbtc.balanceOf(alice)
            : cbbtc.balanceOf(alice) - btcBefore;
        uint256 run = usdcBefore > usdc.balanceOf(alice) ? usdcMoved : btcMoved * router.price() / 1e8;
        uint256 valueAfter = _valueOf(alice);
        uint256 loss = valueBefore > valueAfter ? valueBefore - valueAfter : 0;
        // Fee 25 bps + at most 55 bps against Chainlink, plus the rounding of a few sats.
        assertLe(loss, run * 80 / BPS + 3 * router.price() / 1e8 + 3, "loss above fee + deviation");
    }

    // ─── The rule, fuzzed ───────────────────────────────────────────────────────────────────────────────────

    function testFuzz_runMovesTowardsTheTargetWithinTheCapOrFinishes(
        uint256 cash,
        uint256 btc,
        uint16 target,
        uint256 price
    ) public {
        price = bound(price, 1_000e6, 1_000_000e6);
        _setPrice(price);
        cash = bound(cash, 0, 1e13);
        btc = bound(btc, 0, 1e11);
        target = uint16(bound(target, 500, 9500));
        _setUser(alice, cash, btc, target);
        (bool due, int256 delta) = r.isDue(alice);
        vm.assume(due);

        uint256 total = _valueOf(alice);
        uint256 shareBefore = _shareBps(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 btcBefore = cbbtc.balanceOf(alice);
        _execute(alice);

        // `isDue` reports exactly what `execute` trades. The casts are safe: the sign is checked first.
        // forge-lint: disable-start(unsafe-typecast)
        if (delta > 0) assertEq(usdcBefore - usdc.balanceOf(alice), uint256(delta));
        else assertEq((btcBefore - cbbtc.balanceOf(alice)) * price / 1e8, uint256(-delta));

        uint256 run = delta > 0 ? uint256(delta) : uint256(-delta);
        // forge-lint: disable-end(unsafe-typecast)
        uint256 minTrade = r.MIN_TRADE_USDC();
        assertGe(run, minTrade, "below the minimum");
        uint256 cap = total / 10 > minTrade ? total / 10 : minTrade;
        // A run may exceed the cap by less than the minimum to take the rest of the drift; + 1 sat of rounding on a sell.
        assertLe(run, cap + minTrade + price / 1e8 + 1, "above the cap plus the minimum");

        // Towards the target and not past it (the fee leaves the run slightly short). The margin is one satoshi,
        // not one basis point: a sell rounds its amount up to whole satoshi, and on a small wallet at a high price
        // one satoshi is worth several basis points of it. It collapses back to one basis point on a large wallet.
        uint256 shareAfter = _shareBps(alice);
        uint256 satBps = (price / 1e8) * BPS / total + 1;
        if (delta > 0) {
            assertGt(shareAfter, shareBefore);
            assertLe(shareAfter, uint256(target) + satBps);
        } else {
            assertLt(shareAfter, shareBefore);
            assertGe(shareAfter + satBps, uint256(target));
        }

        // A run beyond the cap took the whole drift: it finishes the correction, and only the fee and one satoshi
        // stand between the wallet and its target.
        if (run > cap + price / 1e8 + 1) {
            (,, bool unfinished,) = r.mandates(alice);
            assertFalse(unfinished, "a run beyond the cap is unfinished");
            assertApproxEqAbs(shareAfter, target, satBps + run * r.FEE_BPS() / total + 1, "short of the target");
        }
    }

    // ─── isDue and quote ────────────────────────────────────────────────────────────────────────────────────

    function test_isDue_signAndAmount() public {
        _setUser(alice, 1000e6, 0, 8000);
        _setUser(bob, 0, 0.0125e8, 5000);
        (bool due, int256 delta) = r.isDue(alice);
        assertTrue(due);
        assertEq(delta, 100e6);
        (due, delta) = r.isDue(bob);
        assertTrue(due);
        assertEq(delta, -100e6);
        (due, delta) = r.isDue(stranger);
        assertFalse(due);
        assertEq(delta, 0);
    }

    function test_isDue_revertsLikeExecuteWhenTheFeedFails() public {
        _setUser(alice, 1000e6, 0, 8000);
        vm.warp(vm.getBlockTimestamp() + 1501);
        vm.expectRevert(Rebalancer.StaleFeed.selector);
        r.isDue(alice);
        // An owner without a mandate is answered without reading the feed.
        (bool due,) = r.isDue(stranger);
        assertFalse(due);
    }

    function test_quote_isTheFeedInUsdcUnits() public {
        feed.set(7_632_284_180_502, block.timestamp, block.timestamp); // 76,322.84180502 USD
        assertEq(r.quote(), 76_322_841_805);
    }

    // ─── Oracle ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_quote_revertsSequencerDown() public {
        uint256 nowTs = block.timestamp;
        sequencer.set(1, nowTs - 2 hours, nowTs); // down
        vm.expectRevert(Rebalancer.SequencerDown.selector);
        r.quote();
        sequencer.set(0, 0, nowTs); // uninitialized round
        vm.expectRevert(Rebalancer.SequencerDown.selector);
        r.quote();
        sequencer.set(0, nowTs + 1, nowTs); // in the future
        vm.expectRevert(Rebalancer.SequencerDown.selector);
        r.quote();
        sequencer.set(0, nowTs - 1 hours + 1, nowTs); // back up, still inside the grace period
        vm.expectRevert(Rebalancer.SequencerDown.selector);
        r.quote();
        sequencer.set(0, nowTs - 1 hours, nowTs);
        assertEq(r.quote(), PRICE);
    }

    function test_quote_revertsStaleSequencerFeed() public {
        uint256 nowTs = block.timestamp;
        sequencer.set(0, nowTs - 100 days, nowTs - 3 days - 1); // up, but the feed stopped reporting
        vm.expectRevert(Rebalancer.StaleFeed.selector);
        r.quote();
        sequencer.set(0, nowTs - 100 days, nowTs + 1); // in the future
        vm.expectRevert(Rebalancer.StaleFeed.selector);
        r.quote();
        sequencer.set(0, nowTs - 100 days, nowTs - 3 days);
        assertEq(r.quote(), PRICE);
    }

    function test_quote_revertsStaleFeed() public {
        uint256 nowTs = block.timestamp;
        // forge-lint: disable-start(unsafe-typecast)
        feed.set(int256(PRICE * 100), nowTs, nowTs - 1501);
        vm.expectRevert(Rebalancer.StaleFeed.selector);
        r.quote();
        feed.set(int256(PRICE * 100), nowTs, nowTs + 1);
        vm.expectRevert(Rebalancer.StaleFeed.selector);
        r.quote();
        feed.set(int256(PRICE * 100), nowTs, nowTs - 1500);
        // forge-lint: disable-end(unsafe-typecast)
        assertEq(r.quote(), PRICE);
    }

    function test_quote_revertsInvalidAnswer() public {
        uint256 nowTs = block.timestamp;
        int256[3] memory bad = [int256(0), -1, 99];
        for (uint256 i; i < 3; i++) {
            feed.set(bad[i], nowTs, nowTs);
            vm.expectRevert(Rebalancer.InvalidFeedAnswer.selector);
            r.quote();
        }
        feed.set(100, nowTs, nowTs);
        assertEq(r.quote(), 1);
    }

    function test_execute_revertsWhenTheOracleFails() public {
        _setUser(alice, 1000e6, 0, 8000);
        sequencer.set(1, block.timestamp - 2 hours, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(Rebalancer.SequencerDown.selector);
        r.execute(alice, 0);
    }

    // ─── Fees and sweep ─────────────────────────────────────────────────────────────────────────────────────

    function test_sweep_forwardsCollectedFeesToTheTreasury() public {
        _setUser(alice, 1000e6, 0, 8000);
        _setUser(bob, 0, 0.0125e8, 5000);
        _execute(alice);
        _execute(bob);
        assertEq(usdc.balanceOf(address(r)), 500_000);
        vm.prank(stranger); // anyone may call it
        r.sweep(IERC20(address(usdc)));
        assertEq(usdc.balanceOf(treasury), 500_000);
        assertEq(usdc.balanceOf(address(r)), 0);
    }

    function test_sell_isNotAffectedByCollectedFees() public {
        _setUser(alice, 1000e6, 0, 8000);
        _execute(alice); // leaves 0.25 USDC of fee in the contract
        _setUser(bob, 0, 0.0125e8, 5000);
        _execute(bob);
        assertEq(usdc.balanceOf(bob), 100e6 - 250_000, "the seller gets their own proceeds, not the fees");
        assertEq(usdc.balanceOf(address(r)), 500_000);
    }

    function test_sweep_strayTokens() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(r), 5e18);
        cbbtc.mint(address(r), 7);
        r.sweep(IERC20(address(other)));
        r.sweep(IERC20(address(cbbtc)));
        assertEq(other.balanceOf(treasury), 5e18);
        assertEq(cbbtc.balanceOf(treasury), 7);
    }

    function test_execute_continuesWhileTheTreasuryIsBlacklisted() public {
        usdc.setBlacklisted(treasury, true);
        _setUser(alice, 1000e6, 0, 8000);
        _execute(alice); // no transfer to the treasury inside a run
        vm.expectRevert("Blacklistable: account is blacklisted");
        r.sweep(IERC20(address(usdc)));
        usdc.setBlacklisted(treasury, false);
        r.sweep(IERC20(address(usdc)));
        assertEq(usdc.balanceOf(treasury), 250_000);
    }

    function test_sweep_maliciousTokenCannotReenter() public {
        // The token is alice's keeper, so without the guard its nested `execute` would go through.
        ReentrantToken evil = new ReentrantToken(r, alice);
        _setUser(alice, 1000e6, 0, 8000);
        vm.prank(alice);
        r.setMandate(8000, address(evil));
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        r.sweep(IERC20(address(evil)));
        assertEq(usdc.balanceOf(alice), 1000e6);
        // The same call outside `sweep` is an ordinary run.
        evil.run();
        assertEq(usdc.balanceOf(alice), 900e6);
    }

    // ─── retire ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_retire_onlyTheTreasury() public {
        vm.prank(keeper);
        vm.expectRevert(Rebalancer.NotTreasury.selector);
        r.retire();
        vm.expectEmit(address(r));
        emit Rebalancer.Retired();
        vm.prank(treasury);
        r.retire();
        assertTrue(r.retired());
        // There is no way back: a second call changes nothing.
        vm.prank(treasury);
        r.retire();
        assertTrue(r.retired());
    }

    function test_retire_stopsRunsAndNewMandatesButNotStopAndSweep() public {
        _setUser(alice, 1000e6, 0, 8000);
        _setUser(bob, 1000e6, 0, 8000);
        _execute(bob);
        vm.prank(treasury);
        r.retire();

        vm.prank(keeper);
        vm.expectRevert(Rebalancer.ContractRetired.selector);
        r.execute(alice, 0);
        vm.prank(alice);
        vm.expectRevert(Rebalancer.ContractRetired.selector);
        r.execute(alice, 0);
        (bool due,) = r.isDue(alice);
        assertFalse(due);

        vm.prank(alice);
        vm.expectRevert(Rebalancer.ContractRetired.selector);
        r.setMandate(8000, keeper);
        vm.prank(alice);
        r.stop();
        (uint16 target,,,) = r.mandates(alice);
        assertEq(target, 0);

        r.sweep(IERC20(address(usdc)));
        assertEq(usdc.balanceOf(treasury), 250_000);
    }
}

/// @dev A token that, as the victim's keeper, runs `execute` from inside its `transfer`, so while `sweep` is in progress.
contract ReentrantToken {
    Rebalancer private immutable R;
    address private immutable VICTIM;

    constructor(Rebalancer r, address victim) {
        R = r;
        VICTIM = victim;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 1;
    }

    function transfer(address, uint256) external returns (bool) {
        R.execute(VICTIM, 0);
        return true;
    }

    function run() external {
        R.execute(VICTIM, 0);
    }
}

// ─── Invariants ────────────────────────────────────────────────────────────────────────────────────────────

/// @dev Random owners, callers, prices, pool deviations, allowances, donations, sweeps and (optionally) `retire`.
contract RebalancerHandler is Test {
    uint256 internal constant BPS = 10_000;

    Rebalancer internal immutable R;
    MockERC20 internal immutable USDC;
    MockERC20 internal immutable CBBTC;
    MockAggregator internal immutable FEED;
    MockAggregator internal immutable SEQUENCER;
    MockRouter internal immutable ROUTER;
    address internal immutable TREASURY;
    address internal immutable KEEPER;
    bool internal immutable ALLOW_RETIRE;
    address[3] internal owners;
    address internal stranger = makeAddr("handlerStranger");

    uint256 public feesCollected; // as reported by the Executed events
    uint256 public donatedUsdc; // sent to the contract by mistake
    uint256 public donatedBtc;
    uint256 public sweptUsdc;
    uint256 public sweptBtc;
    uint256 public runs;
    mapping(address owner => uint256) internal lastRunAt;
    bool public strangerRan;
    bool public intervalBroken;
    bool public lossBoundBroken;
    bool public ranAfterRetire;
    bool public capBroken;

    constructor(
        Rebalancer r,
        MockERC20 usdc,
        MockERC20 cbbtc,
        MockAggregator feed,
        MockAggregator sequencer,
        MockRouter router,
        address treasury,
        address keeper,
        bool allowRetire
    ) {
        R = r;
        USDC = usdc;
        CBBTC = cbbtc;
        FEED = feed;
        SEQUENCER = sequencer;
        ROUTER = router;
        TREASURY = treasury;
        KEEPER = keeper;
        ALLOW_RETIRE = allowRetire;
        for (uint256 i; i < 3; i++) {
            owners[i] = makeAddr(string.concat("handlerOwner", vm.toString(i)));
            usdc.mint(owners[i], 50_000e6);
            cbbtc.mint(owners[i], 0.5e8);
            vm.startPrank(owners[i]);
            usdc.approve(address(r), type(uint256).max);
            cbbtc.approve(address(r), type(uint256).max);
            // forge-lint: disable-next-line(unsafe-typecast)
            r.setMandate(uint16(2000 + 3000 * i), keeper);
            vm.stopPrank();
        }
    }

    function _owner(uint256 seed) internal view returns (address) {
        return owners[seed % 3];
    }

    function _refreshFeeds(uint256 price) internal {
        uint256 nowTs = vm.getBlockTimestamp();
        // forge-lint: disable-next-line(unsafe-typecast)
        FEED.set(int256(price * 100), nowTs, nowTs);
        SEQUENCER.set(0, nowTs - 2 hours, nowTs);
    }

    /// @dev One in four mandates has no keeper, so that only the owner can run it.
    function setMandate(uint256 seed, uint16 target, uint8 keeperSeed) external {
        target = uint16(bound(target, 500, 9500));
        vm.prank(_owner(seed));
        try R.setMandate(target, keeperSeed % 4 == 0 ? address(0) : KEEPER) {} catch {}
    }

    /// @dev Rare, otherwise most sequences spend their time on owners without a mandate.
    function stop(uint256 seed, uint8 rarely) external {
        if (rarely % 4 != 0) return;
        vm.prank(_owner(seed));
        R.stop();
    }

    /// @dev Tries every owner with the same kind of caller: 0 = the owner, 1-3 = the keeper, 4 = a stranger.
    function execute(uint8 callerKind, uint256 minOutSeed) external {
        for (uint256 i; i < 3; i++) {
            _execute(owners[i], callerKind % 5, minOutSeed);
        }
    }

    /// @dev A day later, so that the interval is not what stops the run.
    function executeNextDay(uint8 callerKind, uint256 minOutSeed) external {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _refreshFeeds(ROUTER.price());
        for (uint256 i; i < 3; i++) {
            _execute(owners[i], callerKind % 5, minOutSeed);
        }
    }

    function _execute(address owner, uint8 callerKind, uint256 minOutSeed) internal {
        (,,, address appointed) = R.mandates(owner);
        address caller = callerKind == 0 ? owner : callerKind == 4 ? stranger : KEEPER;
        uint256 price = R.quote();
        uint256 usdcBefore = USDC.balanceOf(owner);
        uint256 btcBefore = CBBTC.balanceOf(owner);
        uint256 total = usdcBefore + btcBefore * price / 1e8;
        bool wasRetired = R.retired();

        vm.recordLogs();
        vm.prank(caller);
        try R.execute(owner, minOutSeed % 3 == 0 ? 0 : minOutSeed % 1000) {
            runs++;
            if (caller != owner && caller != appointed) strangerRan = true;
            if (wasRetired) ranAfterRetire = true;
            uint256 nowTs = vm.getBlockTimestamp();
            if (lastRunAt[owner] != 0 && nowTs < lastRunAt[owner] + 1 days) intervalBroken = true;
            lastRunAt[owner] = nowTs;
            feesCollected += _feeOf(vm.getRecordedLogs());

            bool isBuy = USDC.balanceOf(owner) < usdcBefore;
            uint256 run =
                isBuy ? usdcBefore - USDC.balanceOf(owner) : (btcBefore - CBBTC.balanceOf(owner)) * price / 1e8;
            uint256 totalAfter = USDC.balanceOf(owner) + CBBTC.balanceOf(owner) * price / 1e8;
            uint256 loss = total > totalAfter ? total - totalAfter : 0;
            if (loss > run * 80 / BPS + price / 1e8 * 3) lossBoundBroken = true;
            uint256 minTrade = R.MIN_TRADE_USDC();
            uint256 cap = total / 10 > minTrade ? total / 10 : minTrade;
            if (run > cap + minTrade + price / 1e8 || run + price / 1e8 < minTrade) capBroken = true;
            // Beyond the cap only to take the rest of the drift, so such a run leaves nothing to follow up.
            (,, bool unfinished,) = R.mandates(owner);
            if (run > cap + price / 1e8 && unfinished) capBroken = true;
        } catch {}
    }

    function _feeOf(Vm.Log[] memory logs) internal pure returns (uint256 fee) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == Rebalancer.Executed.selector) {
                (,,, fee,,) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256, uint256));
            }
        }
    }

    function movePrice(int256 bps) external {
        bps = bound(bps, -2000, 2000);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = ROUTER.price() * uint256(10_000 + bps) / BPS;
        price = bound(price, 1_000e6, 10_000_000e6);
        ROUTER.setPrice(price);
        _refreshFeeds(price);
    }

    /// @dev The pool away from the feed, in either direction, also beyond the bound.
    function setPoolDeviation(int256 bps) external {
        ROUTER.setWorseBps(bound(bps, -75, 75));
    }

    function warp(uint256 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 1 hours, 3 days));
        _refreshFeeds(ROUTER.price());
    }

    function donate(uint256 seed, uint256 cash, uint256 btc) external {
        USDC.mint(_owner(seed), bound(cash, 0, 20_000e6));
        CBBTC.mint(_owner(seed), bound(btc, 0, 0.2e8));
    }

    /// @dev Rebuilds one wallet so that its drift lies 0.5 to 1.5 USDC (plus less than one satoshi) past its cap, so the
    ///      next run takes the rest of the drift: the other actions practically never land there. The allowances go
    ///      back to the maximum, so that they do not cut that run short.
    function driftJustPastTheCap(uint256 seed, uint256 total, uint256 excess, bool isBuy) external {
        address owner = _owner(seed);
        (uint16 target,,,) = R.mandates(owner);
        if (target == 0) return;
        uint256 price = ROUTER.price();
        total = bound(total, 1_000e6, 200_000e6); // cap = total / 10, above the minimum
        excess = bound(excess, R.MIN_TRADE_USDC() / 4, R.MIN_TRADE_USDC() * 3 / 4);
        uint256 cap = total / 10;

        // The drift as `_plan` measures it, with the position rounded so that it only grows, by less than one satoshi.
        uint256 btc;
        if (isBuy) {
            uint256 targetValue = total * target / BPS;
            if (targetValue < cap + excess) return; // a target of about 10% or less has no buy past the cap
            btc = (targetValue - cap - excess) * 1e8 / price;
        } else {
            uint256 position = (total * target + BPS - 1) / BPS + cap + excess;
            btc = (position * 1e8 + price - 1) / price;
            if (btc * price / 1e8 > total) return; // a target of about 90% or more has no sell past the cap
        }

        deal(address(USDC), owner, total - btc * price / 1e8);
        deal(address(CBBTC), owner, btc);
        vm.startPrank(owner);
        USDC.approve(address(R), type(uint256).max);
        CBBTC.approve(address(R), type(uint256).max);
        vm.stopPrank();
    }

    function setAllowance(uint256 seed, bool ofUsdc, uint256 amount) external {
        vm.prank(_owner(seed));
        (ofUsdc ? USDC : CBBTC).approve(address(R), bound(amount, 0, 100_000e6));
    }

    /// @dev Tokens sent straight to the contract must end up with the treasury, never with an owner.
    function donateToContract(uint256 cash, uint256 btc) external {
        cash = bound(cash, 0, 1_000e6);
        btc = bound(btc, 0, 0.01e8);
        USDC.mint(address(R), cash);
        CBBTC.mint(address(R), btc);
        donatedUsdc += cash;
        donatedBtc += btc;
    }

    function sweep(bool ofUsdc) external {
        MockERC20 token = ofUsdc ? USDC : CBBTC;
        uint256 held = token.balanceOf(address(R));
        R.sweep(IERC20(address(token)));
        if (ofUsdc) sweptUsdc += held;
        else sweptBtc += held;
    }

    function retire() external {
        if (!ALLOW_RETIRE) return;
        vm.prank(TREASURY);
        R.retire();
    }
}

contract RebalancerInvariantTest is RebalancerTestBase {
    RebalancerHandler internal handler;

    function _allowRetire() internal pure virtual returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        handler = new RebalancerHandler(r, usdc, cbbtc, feed, sequencer, router, treasury, keeper, _allowRetire());
        targetContract(address(handler));
    }

    /// @dev The fees the events reported plus what was sent to the contract by mistake, minus what was swept: nothing
    ///      of an owner stays behind, and nothing of the contract's balance leaks into a run.
    function invariant_contractHoldsOnlyUnsweptFeesAndDonations() public view {
        assertEq(usdc.balanceOf(address(r)), handler.feesCollected() + handler.donatedUsdc() - handler.sweptUsdc());
        assertEq(cbbtc.balanceOf(address(r)), handler.donatedBtc() - handler.sweptBtc());
        assertEq(usdc.balanceOf(treasury), handler.sweptUsdc());
        assertEq(cbbtc.balanceOf(treasury), handler.sweptBtc());
    }

    function invariant_routerAllowanceIsZeroBetweenCalls() public view {
        assertEq(usdc.allowance(address(r), address(router)), 0);
        assertEq(cbbtc.allowance(address(r), address(router)), 0);
    }

    function invariant_onlyOwnerOrKeeperRuns() public view {
        assertFalse(handler.strangerRan());
    }

    function invariant_atMostOneRunPerInterval() public view {
        assertFalse(handler.intervalBroken());
    }

    function invariant_lossPerRunWithinFeePlusDeviation() public view {
        assertFalse(handler.lossBoundBroken());
    }

    function invariant_runWithinMinimumAndCap() public view {
        assertFalse(handler.capBroken());
    }

    function invariant_noRunAfterRetire() public view {
        assertFalse(handler.ranAfterRetire());
    }
}

/// @dev Same invariants without `retire`, so that long sequences keep trading.
contract RebalancerInvariantTestNoRetire is RebalancerInvariantTest {
    function _allowRetire() internal pure override returns (bool) {
        return false;
    }
}
