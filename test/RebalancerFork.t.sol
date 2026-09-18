// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Rebalancer} from "../src/Rebalancer.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IV3SwapRouter} from "../src/interfaces/IV3SwapRouter.sol";
import {DeployRebalancer} from "../script/Deploy.s.sol";

interface IPoolSlot0 {
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool);
}

/// @notice Integration against Base mainnet (fork): the real USDC, cbBTC, SwapRouter02, USDC/cbBTC 0.05% pool and
///         Chainlink feeds. Skip with RUN_FORK=false. `FORK_BLOCK` pins a block (reproducible, and fast thanks to
///         the RPC cache); `BASE_RPC_URL` overrides the public RPC.
contract RebalancerForkTest is Test {
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 internal constant CBBTC = IERC20(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
    address internal constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant FEED_CBBTC_USD = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
    address internal constant SEQUENCER = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address internal constant POOL = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;
    uint256 internal constant BPS = 10_000;

    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal pusher = makeAddr("pusher");

    Rebalancer internal r;

    function setUp() public {
        if (!vm.envOr("RUN_FORK", true)) {
            vm.skip(true);
            return;
        }
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        r = new Rebalancer(address(USDC), address(CBBTC), ROUTER, FEED_CBBTC_USD, SEQUENCER, treasury);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────────────────────────────────────

    function _fund(address user, uint256 cash, uint256 btc, uint16 targetBps) internal {
        deal(address(USDC), user, cash);
        deal(address(CBBTC), user, btc);
        vm.startPrank(user);
        USDC.approve(address(r), type(uint256).max);
        CBBTC.approve(address(r), type(uint256).max);
        r.setMandate(targetBps, keeper);
        vm.stopPrank();
    }

    /// @return USDC base units per cbBTC at the pool's current price (token0 = USDC, token1 = cbBTC).
    function _spot() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IPoolSlot0(POOL).slot0();
        return Math.mulDiv(1e8 << 192, 1, uint256(sqrtPriceX96) * sqrtPriceX96);
    }

    /// @return How far the pool stands from Chainlink in bps; > 0 = cbBTC is dearer in the pool.
    function _poolAboveFeedBps() internal view returns (int256) {
        // Prices are far below 2^255.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (int256(_spot()) - int256(r.quote())) * int256(BPS) / int256(r.quote());
    }

    /// @dev The feed can lag the market by its 0.3% deviation threshold. A test that needs an honest run to pass
    ///      skips itself when the pool already stands further from the feed than leaves room for the run.
    function _skipUnlessPoolNearFeed() internal {
        int256 dev = _poolAboveFeedBps();
        console.log("pool above feed, bps:", dev);
        if (dev > 40 || dev < -40) vm.skip(true);
    }

    /// @dev A third party swaps in the pool: `usdcIn` > 0 buys cbBTC (price up), otherwise `btcIn` sells (price down).
    function _push(uint256 usdcIn, uint256 btcIn) internal {
        IERC20 tokenIn = usdcIn > 0 ? USDC : CBBTC;
        uint256 amount = usdcIn > 0 ? usdcIn : btcIn;
        deal(address(tokenIn), pusher, amount);
        vm.startPrank(pusher);
        tokenIn.approve(ROUTER, amount);
        IV3SwapRouter(ROUTER)
            .exactInputSingle(
                IV3SwapRouter.ExactInputSingleParams({
                    tokenIn: address(tokenIn),
                    tokenOut: address(usdcIn > 0 ? CBBTC : USDC),
                    fee: 500,
                    recipient: pusher,
                    amountIn: amount,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        vm.stopPrank();
    }

    // ─── Deployment ─────────────────────────────────────────────────────────────────────────────────────────

    function test_fork_deployScriptChecksAndDeploys() public {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("TREASURY", vm.toString(treasury));
        Rebalancer deployed = new DeployRebalancer().run();
        assertEq(address(deployed.USDC()), address(USDC));
        assertEq(address(deployed.CBBTC()), address(CBBTC));
        assertEq(address(deployed.ROUTER()), ROUTER);
        assertEq(deployed.TREASURY(), treasury);
        assertGt(deployed.quote(), 0);
    }

    function test_fork_feedIsFreshAndCloseToThePool() public view {
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(FEED_CBBTC_USD).latestRoundData();
        assertGt(answer, 0);
        assertLe(block.timestamp - updatedAt, r.MAX_FEED_AGE(), "feed older than MAX_FEED_AGE");
        assertEq(IAggregatorV3(FEED_CBBTC_USD).decimals(), 8);
        console.log("Chainlink USDC per cbBTC:", r.quote());
        console.log("pool      USDC per cbBTC:", _spot());
        assertApproxEqRel(_spot(), r.quote(), 0.01e18, "pool more than 1% from the feed");
    }

    // ─── Runs against the real pool ─────────────────────────────────────────────────────────────────────────

    function test_fork_buy() public {
        _skipUnlessPoolNearFeed();
        _fund(buyer, 10_000e6, 0, 8000); // run: 10% = 1,000 USDC
        uint256 price = r.quote();
        vm.prank(keeper);
        uint256 gasBefore = gasleft();
        r.execute(buyer, 0);
        console.log("gas of a buy:", gasBefore - gasleft());

        assertEq(USDC.balanceOf(buyer), 9_000e6);
        assertEq(USDC.balanceOf(address(r)), 2.5e6, "fee of 25 bps stays in the contract");
        assertEq(CBBTC.balanceOf(address(r)), 0);
        assertEq(USDC.allowance(address(r), ROUTER), 0);
        uint256 expected = 997.5e6 * 1e8 / price;
        assertGe(CBBTC.balanceOf(buyer), expected * (BPS - 55) / BPS);
        assertLe(CBBTC.balanceOf(buyer), expected * (BPS + 55) / BPS);

        r.sweep(USDC);
        assertEq(USDC.balanceOf(treasury), 2.5e6);
    }

    function test_fork_sell() public {
        _skipUnlessPoolNearFeed();
        _fund(seller, 0, 0.2e8, 5000); // run: 10% of the value
        uint256 price = r.quote();
        vm.prank(keeper);
        uint256 gasBefore = gasleft();
        r.execute(seller, 0);
        console.log("gas of a sell:", gasBefore - gasleft());

        uint256 sold = 0.2e8 - CBBTC.balanceOf(seller);
        assertApproxEqAbs(sold, 0.02e8, 1);
        uint256 expected = sold * price / 1e8;
        uint256 fee = USDC.balanceOf(address(r));
        uint256 received = USDC.balanceOf(seller) + fee;
        assertGe(received, expected * (BPS - 55) / BPS);
        assertLe(received, expected * (BPS + 55) / BPS);
        assertEq(fee, received * 25 / BPS);
        assertEq(CBBTC.balanceOf(address(r)), 0);
        assertEq(CBBTC.allowance(address(r), ROUTER), 0);
    }

    function test_fork_runOf100kFitsTheBound() public {
        // Needs room for ~15 bps of own price impact on top of the pool fee, so a tighter start than the other runs.
        int256 dev = _poolAboveFeedBps();
        console.log("pool above feed, bps:", dev);
        if (dev > 20 || dev < -20) vm.skip(true);
        _fund(buyer, 1_000_000e6, 0, 8000);
        uint256 expected = 99_750e6 * 1e8 / r.quote();
        vm.prank(keeper);
        uint256 got = r.execute(buyer, 0);
        console.log("100k buy, received below Chainlink in bps x100:", (expected - got) * 1_000_000 / expected);
        assertEq(CBBTC.balanceOf(buyer), got);
        assertGe(got, expected * (BPS - 55) / BPS);
    }

    function test_fork_strangerIsRefused() public {
        _fund(buyer, 10_000e6, 0, 8000);
        vm.expectRevert(Rebalancer.NotOwnerOrKeeper.selector);
        r.execute(buyer, 0);
        assertEq(USDC.balanceOf(buyer), 10_000e6);
    }

    // ─── Price bound against the real pool ──────────────────────────────────────────────────────────────────

    function test_fork_pushedPoolAgainstTheRunIsRefused() public {
        _fund(buyer, 10_000e6, 0, 8000);
        _push(1_500_000e6, 0); // cbBTC several percent dearer in the pool than at Chainlink
        console.log("pool above feed after the push, bps:", _poolAboveFeedBps());
        vm.prank(keeper);
        vm.expectRevert("Too little received");
        r.execute(buyer, 0);
    }

    function test_fork_poolFarBetterThanTheFeedIsRefused() public {
        _fund(buyer, 10_000e6, 0, 8000);
        _push(0, 20e8); // cbBTC several percent cheaper in the pool: what a stuck feed or a depeg looks like
        console.log("pool above feed after the push, bps:", _poolAboveFeedBps());
        vm.prank(keeper);
        vm.expectPartialRevert(Rebalancer.OutsidePriceBounds.selector);
        r.execute(buyer, 0);
    }

    function test_fork_keeperCanDemandTheQuotedOutput() public {
        _skipUnlessPoolNearFeed();
        _fund(buyer, 10_000e6, 0, 8000);

        // The keeper's quote: simulate the run, take what the swap yields, and undo it.
        uint256 snapshot = vm.snapshotState();
        vm.prank(keeper);
        uint256 quoted = r.execute(buyer, 0);
        vm.revertToState(snapshot);

        vm.prank(keeper);
        vm.expectRevert("Too little received");
        r.execute(buyer, quoted + 1);
        vm.prank(keeper);
        r.execute(buyer, quoted);
        assertEq(CBBTC.balanceOf(buyer), quoted);
    }

    /// @dev The contract reads the router's allowance after a swap to tell whether the pool took all of the input, so
    ///      USDC and cbBTC must lower an allowance by what `transferFrom` moves.
    function test_fork_tokensLowerTheAllowanceOnTransferFrom() public {
        IERC20[2] memory tokens = [USDC, CBBTC];
        for (uint256 i; i < 2; i++) {
            deal(address(tokens[i]), buyer, 100);
            vm.prank(buyer);
            assertTrue(tokens[i].approve(seller, 100));
            vm.prank(seller);
            assertTrue(tokens[i].transferFrom(buyer, seller, 40));
            assertEq(tokens[i].allowance(buyer, seller), 60);
        }
    }
}
