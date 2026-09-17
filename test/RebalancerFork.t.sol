// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Rebalancer} from "../src/Rebalancer.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/// @dev Only for the cadence test: `getRoundData` is not in the contract's minimal interface.
interface IChainlinkRounds {
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Integration against Base mainnet (fork). Skip with RUN_FORK=false.
contract RebalancerForkTest is Test {
    IERC20 internal constant EURC = IERC20(0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42);
    IERC20 internal constant CBBTC = IERC20(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant FEED_CBBTC_USD = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
    /// @dev EURC/USD with heartbeat 1 hour and deviation 0.1% (Chainlink reference directory for Base); the old
    ///      24-hour feed 0xDAe3…8250 is no longer listed there (audit M-2).
    address internal constant FEED_EURC_USD = 0x9867186e52d2F1C2c565CDA6E747101Fa56501e0;
    address internal constant SEQUENCER = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address internal constant POOL_EURC_USDC = 0x7279c08A36333e12c3Fc81747963264c100D66fB;
    address internal constant POOL_USDC_CBBTC = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;

    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");

    Rebalancer internal r;

    function setUp() public {
        if (!vm.envOr("RUN_FORK", true)) {
            vm.skip(true);
            return;
        }
        // `FORK_BLOCK` pins a block (review I-7), so the suite is reproducible; defaults to the latest.
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        // A fork is at the state after the latest block, with its timestamp. If that block had a tick change in one of
        // the pools, the block check sees it as "touched in this block". So start in a fresh block.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 2);

        r = new Rebalancer(
            Rebalancer.Deployment({
                eurc: address(EURC),
                cbbtc: address(CBBTC),
                usdc: USDC,
                router: ROUTER,
                feedCbbtcUsd: FEED_CBBTC_USD,
                feedEurcUsd: FEED_EURC_USD,
                sequencerFeed: SEQUENCER,
                poolEurcUsdc: POOL_EURC_USDC,
                poolUsdcCbbtc: POOL_USDC_CBBTC,
                treasury: treasury
            })
        );
    }

    /// @notice Measures the deviation between pool spot and feed price; should normally be well below 1%.
    function test_fork_spotMatchesOracle() public view {
        uint256 oracle = r.quote();
        uint256 spotPrice = r.spot();
        uint256 diff = spotPrice > oracle ? spotPrice - oracle : oracle - spotPrice;
        console.log("oracle EURC/cbBTC (6 dec):", oracle);
        console.log("spot   EURC/cbBTC (6 dec):", spotPrice);
        console.log("deviation in bps:", diff * 10_000 / oracle);
        assertApproxEqRel(spotPrice, oracle, 0.01e18, "spot deviates more than 1% from the feeds");
        assertEq(r.quoteChecked(), oracle);
    }

    /// @notice Shifts the cbBTC/USD feed by 1%: the spot then deviates too far, execute reverts and isDue is false.
    function test_fork_spotDeviationBlocksRun() public {
        _fund(buyer, 1000e6, 0);
        (bool due,) = r.isDue(buyer);
        assertTrue(due);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(FEED_CBBTC_USD).latestRoundData();
        vm.mockCall(
            FEED_CBBTC_USD,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(roundId, answer * 101 / 100, startedAt, updatedAt, answeredInRound)
        );
        uint256 oracle = r.quote();
        uint256 spotPrice = r.spot();
        assertLt(spotPrice * 10_000, oracle * (10_000 - 50), "setup: spot must be more than 0.5% below the feed");

        (due,) = r.isDue(buyer);
        assertFalse(due);
        assertEq(r.dueOwners(0, 10).length, 0);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.SpotDeviatesFromOracle.selector, spotPrice, oracle));
        r.execute(buyer, keeper);
        vm.clearMockedCalls();

        (due,) = r.isDue(buyer);
        assertTrue(due);
        address[] memory list = r.dueOwners(0, 10);
        assertEq(list.length, 1);
        assertEq(list[0], buyer);
    }

    /// @notice Review I-4: the real tokens have the decimals the constructor checks for (EURC 6, cbBTC 8,
    ///         USDC 6), so the deploy in `setUp` with the deploy script's addresses succeeds, and a token with other
    ///         decimals at those addresses is rejected.
    function test_fork_constructorChecksTokenDecimals() public {
        assertEq(IERC20Metadata(address(EURC)).decimals(), 6, "EURC");
        assertEq(IERC20Metadata(address(CBBTC)).decimals(), 8, "cbBTC");
        assertEq(IERC20Metadata(USDC).decimals(), 6, "USDC");
        assertEq(address(r.EURC()), address(EURC));

        Rebalancer.Deployment memory d = Rebalancer.Deployment({
            eurc: address(EURC),
            cbbtc: address(CBBTC),
            usdc: USDC,
            router: ROUTER,
            feedCbbtcUsd: FEED_CBBTC_USD,
            feedEurcUsd: FEED_EURC_USD,
            sequencerFeed: SEQUENCER,
            poolEurcUsdc: POOL_EURC_USDC,
            poolUsdcCbbtc: POOL_USDC_CBBTC,
            treasury: treasury
        });
        vm.mockCall(address(CBBTC), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.UnexpectedTokenDecimals.selector, address(CBBTC)));
        new Rebalancer(d);
        vm.clearMockedCalls();
        new Rebalancer(d);
    }

    /// @notice Test gap oracle 3: both feeds have 8 decimals on-chain, carry the expected description and are
    ///         fresher than MAX_AGE_*; the sequencer feed has an initialized round.
    function test_fork_feedsAreFreshAndMatchConstants() public view {
        IAggregatorV3 eurcFeed = IAggregatorV3(FEED_EURC_USD);
        IAggregatorV3 btcFeed = IAggregatorV3(FEED_CBBTC_USD);
        assertEq(eurcFeed.decimals(), 8);
        assertEq(btcFeed.decimals(), 8);
        assertEq(keccak256(bytes(eurcFeed.description())), keccak256("EURC / USD"));
        assertEq(keccak256(bytes(btcFeed.description())), keccak256("cbBTC / USD"));

        (, int256 eurcAnswer,, uint256 eurcUpdatedAt,) = eurcFeed.latestRoundData();
        (, int256 btcAnswer,, uint256 btcUpdatedAt,) = btcFeed.latestRoundData();
        assertGt(eurcAnswer, 0);
        assertGt(btcAnswer, 0);
        // Test against the contract's tolerance, not the nominal heartbeat: a late round (measured 3,632 s)
        // is above 1 hour but well below MAX_AGE_EURC.
        assertLe(block.timestamp - eurcUpdatedAt, r.MAX_AGE_EURC(), "EURC feed older than MAX_AGE_EURC");
        assertLe(block.timestamp - btcUpdatedAt, r.MAX_AGE_CBBTC());
        // EURC/USD should be around 1.0–1.3 (8 decimals).
        assertGt(eurcAnswer, 0.9e8);
        assertLt(eurcAnswer, 1.5e8);

        (, int256 seqAnswer, uint256 seqStartedAt,,) = IAggregatorV3(SEQUENCER).latestRoundData();
        assertEq(seqAnswer, 0);
        assertGt(seqStartedAt, 0);
    }

    /// @notice Test gap oracle 3, the cadence: over the latest rounds of both feeds there is never more than MAX_AGE_*
    ///         between two consecutive updates. This tests the constants against the actual heartbeat and not
    ///         only against the age of the latest round.
    function test_fork_feedCadenceWithinMaxAge() public view {
        _assertCadence(FEED_CBBTC_USD, r.MAX_AGE_CBBTC());
        _assertCadence(FEED_EURC_USD, r.MAX_AGE_EURC());
    }

    function _assertCadence(address feed, uint256 maxAge) internal view {
        uint256 rounds = 24;
        (uint80 roundId,,, uint256 newerUpdatedAt,) = IAggregatorV3(feed).latestRoundData();
        uint256 checked;
        uint256 largestGap;
        // Round id = (phaseId << 64) | round within the phase; walk back within one phase.
        while (checked < rounds && uint64(roundId) > 1) {
            roundId--;
            (,,, uint256 updatedAt,) = IChainlinkRounds(feed).getRoundData(roundId);
            uint256 gap = newerUpdatedAt - updatedAt;
            if (gap > largestGap) largestGap = gap;
            assertLe(gap, maxAge, "gap between two rounds larger than MAX_AGE");
            newerUpdatedAt = updatedAt;
            checked++;
        }
        console.log(IAggregatorV3(feed).description(), "largest gap (s):", largestGap);
        assertEq(checked, rounds, "too few rounds in the current phase to test the cadence");
    }

    /// @notice M-1: the spot after the swap is within the tolerance; a run of 100 EURC/0.002 cbBTC passes the
    ///         post-swap check comfortably and books nothing extra.
    function test_fork_postSwapSpotWithinTolerance() public {
        _fund(buyer, 1000e6, 0);
        r.execute(buyer, keeper);
        uint256 oracle = r.quote();
        uint256 spotAfter = r.spot();
        uint256 diff = spotAfter > oracle ? spotAfter - oracle : oracle - spotAfter;
        assertLe(diff * 10_000, oracle * 50, "spot after the swap outside 0.5%");
        assertEq(r.quoteChecked(), oracle);
    }

    /// @notice Measures the gas of a real buy and sell, so a keeper knows what to budget.
    function test_fork_buyAndSellGasCost() public {
        _fund(buyer, 1000e6, 0);
        _fund(seller, 0, 2_000_000);

        vm.expectEmit(true, false, false, false, address(r));
        emit Rebalancer.Executed(buyer, true, 0, 0, 0, treasury, 0, 0, 0, 0);
        uint256 g = gasleft();
        r.execute(buyer, keeper);
        uint256 buyGas = g - gasleft();
        uint64 buyTime = uint64(vm.getBlockTimestamp());

        // The buy can change the tick of a pool; then the block check rejects a second run in the same block
        // (PoolTouchedThisBlock). So the sell goes in the next block, as a keeper would do too.
        vm.roll(block.number + 1);
        vm.warp(vm.getBlockTimestamp() + 2);
        vm.expectEmit(true, false, false, false, address(r));
        emit Rebalancer.Executed(seller, false, 0, 0, 0, treasury, 0, 0, 0, 0);
        g = gasleft();
        r.execute(seller, keeper);
        uint256 sellGas = g - gasleft();

        console.log("gas buy:", buyGas, "gas sell:", sellGas);
        assertEq(r.lastExecutedAt(buyer), buyTime);
        assertEq(r.lastExecutedAt(seller), uint64(vm.getBlockTimestamp()));
        assertLt(buyGas, 1_000_000, "buy no longer fits in the budgeted gas");
        assertLt(sellGas, 1_000_000, "sell no longer fits in the budgeted gas");
    }

    function _params() internal pure returns (Rebalancer.Params memory) {
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

    function _fund(address user, uint256 eurcAmount, uint256 btcAmount) internal {
        if (eurcAmount > 0) {
            vm.prank(POOL_EURC_USDC);
            EURC.transfer(user, eurcAmount);
        }
        if (btcAmount > 0) {
            vm.prank(POOL_USDC_CBBTC);
            CBBTC.transfer(user, btcAmount);
        }
        vm.startPrank(user);
        EURC.approve(address(r), type(uint256).max);
        CBBTC.approve(address(r), type(uint256).max);
        r.setParams(_params());
        vm.stopPrank();
    }

    function test_fork_quoteWithinSaneRange() public view {
        uint256 price = r.quote();
        assertGt(price, 30_000e6);
        assertLt(price, 300_000e6);
    }

    function test_fork_buyRun() public {
        _fund(buyer, 1000e6, 0);

        (bool due, int256 delta) = r.isDue(buyer);
        assertTrue(due);
        assertEq(delta, 100e6);

        vm.expectEmit(true, false, false, false, address(r));
        emit Rebalancer.Executed(buyer, true, 100e6, 250_000, 50_000, keeper, 0, 0, 1000e6, 0);
        r.execute(buyer, keeper);

        assertEq(EURC.balanceOf(buyer), 900e6, "100 EURC moved");
        assertGt(CBBTC.balanceOf(buyer), 0, "owner receives cbBTC");
        assertEq(EURC.balanceOf(keeper), 50_000, "reward");
        assertEq(EURC.balanceOf(treasury), 200_000, "treasury fee");
        assertEq(EURC.balanceOf(address(r)), 0);
        assertEq(CBBTC.balanceOf(address(r)), 0);
        assertEq(r.lastExecutedAt(buyer), uint64(block.timestamp));

        // Received cbBTC is within 1% of the feed price (99.75 EURC after fee).
        uint256 expected = 99_750_000 * 1e8 / r.quote();
        assertApproxEqRel(CBBTC.balanceOf(buyer), expected, 0.01e18);

        (due, delta) = r.isDue(buyer);
        assertFalse(due);
        assertEq(delta, 0);

        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(buyer, keeper);
    }

    function test_fork_sellRun() public {
        _fund(seller, 0, 2_000_000); // 0.02 cbBTC

        uint256 price = r.quote();
        uint256 total = 2_000_000 * price / 1e8;
        (bool due, int256 delta) = r.isDue(seller);
        assertTrue(due);
        // L-C: the delta is the value of the rounded-up sats, so at most 1 sat above the 10% cap.
        uint256 sats = (total / 10 * 1e8 + price - 1) / price;
        assertEq(delta, -int256(sats * price / 1e8), "cap 10% of the total value, as sold sats");

        vm.expectEmit(true, false, false, false, address(r));
        emit Rebalancer.Executed(seller, false, 0, 0, 0, keeper, 0, 0, 0, 0);
        r.execute(seller, keeper);

        uint256 btcSold = 2_000_000 - CBBTC.balanceOf(seller);
        assertApproxEqAbs(btcSold, 200_000, 1, "10% of the position sold");
        uint256 received = EURC.balanceOf(seller);
        assertGt(received, 0, "owner receives EURC");
        assertApproxEqRel(received, btcSold * price / 1e8 * 9975 / 10_000, 0.01e18);
        assertEq(EURC.balanceOf(keeper), 50_000, "reward");
        assertGt(EURC.balanceOf(treasury), 0, "treasury fee");
        // fee = 25 bps over max(received, expected proceeds at the oracle price) = reward + treasury (audit L-B).
        uint256 fee = EURC.balanceOf(keeper) + EURC.balanceOf(treasury);
        uint256 feeBase = received + fee;
        uint256 expectedOut = btcSold * price / 1e8;
        if (expectedOut > feeBase) feeBase = expectedOut;
        assertEq(fee, feeBase * 25 / 10_000);
        assertEq(EURC.balanceOf(address(r)), 0);
        assertEq(CBBTC.balanceOf(address(r)), 0);

        (due, delta) = r.isDue(seller);
        assertFalse(due);
        assertEq(delta, 0);

        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(seller, keeper);
    }
}
