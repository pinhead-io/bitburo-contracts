// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Rebalancer} from "../src/Rebalancer.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/// @notice Integratie tegen Base mainnet (fork). Overslaan met RUN_FORK=false.
contract RebalancerForkTest is Test {
    IERC20 internal constant EURC = IERC20(0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42);
    IERC20 internal constant CBBTC = IERC20(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant FEED_CBBTC_USD = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
    /// @dev EURC/USD met heartbeat 1 uur en deviatie 0,1% (Chainlink-referentiedirectory voor Base); de oude
    ///      24-uursfeed 0xDAe3…8250 staat daar niet meer in (audit M-2).
    address internal constant FEED_EURC_USD = 0x9867186e52d2F1C2c565CDA6E747101Fa56501e0;
    address internal constant SEQUENCER = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address internal constant POOL_EURC_USDC = 0x7279c08A36333e12c3Fc81747963264c100D66fB;
    address internal constant POOL_USDC_CBBTC = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;

    address internal treasury = makeAddr("treasury");
    address internal forwarder = makeAddr("forwarder");
    address internal workflowOwner = makeAddr("workflowOwner");
    address internal keeper = makeAddr("keeper");
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");

    Rebalancer internal r;

    function setUp() public {
        if (!vm.envOr("RUN_FORK", true)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));
        vm.etch(forwarder, hex"5f");

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
                treasury: treasury,
                forwarder: forwarder,
                workflowOwner: workflowOwner
            })
        );
    }

    /// @notice Meet de afwijking tussen pool-spot en feedkoers; hoort normaal ruim onder 1% te liggen.
    function test_fork_spotMatchesOracle() public view {
        uint256 oracle = r.quote();
        uint256 spotPrice = r.spot();
        uint256 diff = spotPrice > oracle ? spotPrice - oracle : oracle - spotPrice;
        console.log("oracle EURC/cbBTC (6 dec):", oracle);
        console.log("spot   EURC/cbBTC (6 dec):", spotPrice);
        console.log("afwijking in bps:", diff * 10_000 / oracle);
        assertApproxEqRel(spotPrice, oracle, 0.01e18, "spot wijkt meer dan 1% af van de feeds");
        assertEq(r.quoteChecked(), oracle);
    }

    /// @notice Schuift de cbBTC/USD-feed 1% op: de spot wijkt dan te ver af, execute revert en isDue is false.
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
        assertLt(spotPrice * 10_000, oracle * (10_000 - 50), "opzet: spot moet meer dan 0,5% onder de feed liggen");

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

    /// @notice Testgat oracle 3: beide feeds zijn on-chain 8 decimalen, dragen de verwachte beschrijving en zijn
    ///         verser dan MAX_AGE_*; de sequencer-feed heeft een geïnitialiseerde ronde.
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
        assertLe(block.timestamp - eurcUpdatedAt, 3600, "EURC-feed ouder dan zijn heartbeat van 1 uur");
        assertLe(block.timestamp - eurcUpdatedAt, r.MAX_AGE_EURC());
        assertLe(block.timestamp - btcUpdatedAt, r.MAX_AGE_CBBTC());
        // EURC/USD hoort rond 1,0–1,3 te liggen (8 decimalen).
        assertGt(eurcAnswer, 0.9e8);
        assertLt(eurcAnswer, 1.5e8);

        (, int256 seqAnswer, uint256 seqStartedAt,,) = IAggregatorV3(SEQUENCER).latestRoundData();
        assertEq(seqAnswer, 0);
        assertGt(seqStartedAt, 0);
    }

    /// @notice M-1: de spot na de swap ligt binnen de tolerantie; een run van 100 EURC/0,002 cbBTC haalt de
    ///         post-swap-check ruim en boekt niets extra's.
    function test_fork_postSwapSpotWithinTolerance() public {
        _fund(buyer, 1000e6, 0);
        r.execute(buyer, keeper);
        uint256 oracle = r.quote();
        uint256 spotAfter = r.spot();
        uint256 diff = spotAfter > oracle ? spotAfter - oracle : oracle - spotAfter;
        assertLe(diff * 10_000, oracle * 50, "spot na de swap buiten 0,5%");
        assertEq(r.quoteChecked(), oracle);
    }

    /// @notice Bevestigt dat de gasconstanten van `onReport` ruim genoeg zijn voor een echte koop en verkoop.
    function test_fork_onReportRunsBuyAndSellWithinGasBudget() public {
        _fund(buyer, 1000e6, 0);
        _fund(seller, 0, 2_000_000);
        address[] memory list = new address[](2);
        list[0] = buyer;
        list[1] = seller;

        vm.expectEmit(true, false, false, false, address(r));
        emit Rebalancer.Executed(buyer, true, 0, 0, 0, treasury, 0, 0, 0, 0);
        vm.expectEmit(true, false, false, false, address(r));
        emit Rebalancer.Executed(seller, false, 0, 0, 0, treasury, 0, 0, 0, 0);
        vm.prank(forwarder);
        r.onReport(
            abi.encodePacked(bytes32(uint256(1)), bytes10("bitburo"), workflowOwner, bytes2(0x0001)), abi.encode(list)
        );
        assertEq(r.lastExecutedAt(buyer), uint64(block.timestamp));
        assertEq(r.lastExecutedAt(seller), uint64(block.timestamp));
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

        assertEq(EURC.balanceOf(buyer), 900e6, "100 EURC verplaatst");
        assertGt(CBBTC.balanceOf(buyer), 0, "owner ontvangt cbBTC");
        assertEq(EURC.balanceOf(keeper), 50_000, "beloning");
        assertEq(EURC.balanceOf(treasury), 200_000, "treasury-fee");
        assertEq(EURC.balanceOf(address(r)), 0);
        assertEq(CBBTC.balanceOf(address(r)), 0);
        assertEq(r.lastExecutedAt(buyer), uint64(block.timestamp));

        // Ontvangen cbBTC ligt binnen 1% van de feedkoers (99,75 EURC na fee).
        uint256 expected = 99_750_000 * 1e8 / r.quote();
        assertApproxEqRel(CBBTC.balanceOf(buyer), expected, 0.01e18);

        (due, delta) = r.isDue(buyer);
        assertFalse(due);
        assertEq(delta, 0);

        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(buyer, keeper);
    }

    function test_fork_sellRun() public {
        _fund(seller, 0, 2_000_000); // 0,02 cbBTC

        uint256 price = r.quote();
        uint256 total = 2_000_000 * price / 1e8;
        (bool due, int256 delta) = r.isDue(seller);
        assertTrue(due);
        assertEq(delta, -int256(total / 10), "cap 10% van de totale waarde");

        vm.expectEmit(true, false, false, false, address(r));
        emit Rebalancer.Executed(seller, false, 0, 0, 0, keeper, 0, 0, 0, 0);
        r.execute(seller, keeper);

        uint256 btcSold = 2_000_000 - CBBTC.balanceOf(seller);
        assertApproxEqAbs(btcSold, 200_000, 1, "10% van de positie verkocht");
        uint256 received = EURC.balanceOf(seller);
        assertGt(received, 0, "owner ontvangt EURC");
        assertApproxEqRel(received, btcSold * price / 1e8 * 9975 / 10_000, 0.01e18);
        assertEq(EURC.balanceOf(keeper), 50_000, "beloning");
        assertGt(EURC.balanceOf(treasury), 0, "treasury-fee");
        // fee = 25 bps over het ontvangen bedrag = reward + treasury.
        uint256 fee = EURC.balanceOf(keeper) + EURC.balanceOf(treasury);
        assertEq(fee, (received + fee) * 25 / 10_000);
        assertEq(EURC.balanceOf(address(r)), 0);
        assertEq(CBBTC.balanceOf(address(r)), 0);

        (due, delta) = r.isDue(seller);
        assertFalse(due);
        assertEq(delta, 0);

        vm.expectRevert(Rebalancer.NotDue.selector);
        r.execute(seller, keeper);
    }
}
