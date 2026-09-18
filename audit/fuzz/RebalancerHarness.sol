// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Rebalancer} from "../../src/Rebalancer.sol";
import {MockAggregator} from "../../test/mocks/MockAggregator.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";
import {MockRouter} from "../../test/mocks/MockRouter.sol";

/*
 * Medusa/Echidna harness for Rebalancer. It deploys the contract against the unit-test mocks and exposes only what
 * real accounts can do: owners set, change and stop their mandate, change allowances, receive and spend tokens;
 * callers (the owner, its keeper, another owner, a stranger, the treasury) try `execute`; anyone donates tokens to the
 * contract or sweeps it; the treasury retires it; the market moves the price and pushes the pool away from the feed;
 * time passes. The fuzzer never calls a mock directly. Every `property_` function must hold after every call.
 *
 * Contracts:
 *   RebalancerHarness     the properties; all must hold.
 *   RebalancerCanaries    the same, plus canaries that fail once a state worth reaching was reached (a buy, a sell,
 *                         a follow-up run inside the band, a follow-up run that reverses direction, retire).
 *   RebalancerPartialFill the same, plus a pool that can run dry and take only part of the input; the contract
 *                         must refuse such a run, so all properties must hold here too.
 *
 * Run from the repository root (solc 0.8.37 with the settings of foundry.toml, see medusa.json), with the corpus
 * outside the repository. Both tools leave a crytic-export/ directory behind; it does not belong in git.
 *
 *   medusa fuzz --config audit/fuzz/medusa.json --timeout 600 --corpus-dir <dir>
 *   medusa fuzz --config audit/fuzz/medusa.json --target-contracts RebalancerCanaries --timeout 120 --corpus-dir <dir>
 *   medusa fuzz --config audit/fuzz/medusa.json --target-contracts RebalancerPartialFill --timeout 120 --corpus-dir <dir>
 *   echidna audit/fuzz/RebalancerHarness.sol --contract RebalancerHarness --config audit/fuzz/echidna.yaml \
 *     --corpus-dir <dir>
 */

interface IHevm {
    function warp(uint256 timestamp) external;
}

/// @dev One account: an owner's wallet, the keeper, a stranger or the treasury. Only the harness can make it call.
contract Actor {
    address private immutable HARNESS = msg.sender;

    function exec(address target, bytes calldata data) external returns (bool ok, bytes memory ret) {
        require(msg.sender == HARNESS, "Actor: not the harness");
        (ok, ret) = target.call(data);
    }
}

contract RebalancerHarness {
    IHevm internal constant VM = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    uint256 internal constant BPS = 10_000;
    uint256 internal constant FEE_BPS = 25;
    uint256 internal constant BAND_BPS = 500;
    uint256 internal constant MIN_TRADE = 20e6;
    uint256 internal constant MIN_PRICE = 1_000e6; // USDC base units per cbBTC
    uint256 internal constant MAX_PRICE = 10_000_000e6;
    address internal constant SINK = address(0xdead);

    MockERC20 internal immutable USDC;
    MockERC20 internal immutable CBBTC;
    MockAggregator internal immutable FEED;
    MockAggregator internal immutable SEQUENCER;
    MockRouter internal immutable ROUTER;
    Rebalancer internal immutable R;
    Actor internal immutable KEEPER;
    Actor internal immutable STRANGER;
    Actor internal immutable TREASURY;
    Actor[3] internal owners;

    // Ghost state.
    uint256 internal feesCollected;
    uint256 internal donatedUsdc;
    uint256 internal donatedBtc;
    uint256 internal sweptUsdc;
    uint256 internal sweptBtc;
    bool internal retiredSeen;
    mapping(address owner => uint256) internal lastRunAt;

    // Violations, set by the actions and read by the properties. An action never reverts after setting one.
    bool internal unauthorizedRun;
    bool internal intervalBroken;
    bool internal runWhileRetiredOrInactive;
    bool internal isDueDisagrees;
    bool internal sizeBroken;
    bool internal lossBoundBroken;
    bool internal priceBoundBroken;
    bool internal directionBroken;
    bool internal insideBandRun;
    bool internal unfinishedFlagWrong;
    bool internal outputWrong;
    bool internal runLeftMoreThanTheFee;
    bool internal routerAllowanceLeft;
    bool internal otherAccountTouched;
    bool internal honestRunRefused;
    bool internal mandateRuleBroken;
    bool internal stopBroken;
    bool internal sweepBroken;
    bool internal retireBroken;

    /// @dev The owner's mandate, the market and the balances right before an `execute`.
    struct State {
        uint16 target;
        uint64 last;
        bool unfinished;
        address appointed;
        bool retired;
        uint256 price;
        uint256 cash;
        uint256 btc;
        bool due;
        int256 delta;
        uint256 heldUsdc;
        uint256 heldBtc;
    }

    constructor() {
        uint256 start = 1_790_000_000;
        VM.warp(start);
        USDC = new MockERC20("USD Coin", "USDC", 6);
        CBBTC = new MockERC20("Coinbase Wrapped BTC", "cbBTC", 8);
        FEED = new MockAggregator(8, "cbBTC / USD");
        SEQUENCER = new MockAggregator(0, "L2 Sequencer Uptime Status Feed");
        ROUTER = new MockRouter(address(USDC), address(CBBTC), 80_000e6);
        _refresh(start);
        KEEPER = new Actor();
        STRANGER = new Actor();
        TREASURY = new Actor();
        R = new Rebalancer(
            address(USDC), address(CBBTC), address(ROUTER), address(FEED), address(SEQUENCER), address(TREASURY)
        );
        // 50,000 USDC and 0.5 cbBTC each (44% cbBTC at the start price), targets 20%, 50% and 80%: all three are due.
        for (uint256 i; i < 3; i++) {
            Actor owner = new Actor();
            owners[i] = owner;
            USDC.mint(address(owner), 50_000e6);
            CBBTC.mint(address(owner), 0.5e8);
            owner.exec(address(USDC), abi.encodeCall(IERC20.approve, (address(R), type(uint256).max)));
            owner.exec(address(CBBTC), abi.encodeCall(IERC20.approve, (address(R), type(uint256).max)));
            owner.exec(address(R), abi.encodeCall(Rebalancer.setMandate, (uint16(2000 + 3000 * i), address(KEEPER))));
        }
    }

    // ─── Actions ────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev `callerSeed` picks the owner itself, the keeper, a stranger, another owner or the treasury.
    function execute(uint8 callerSeed, uint8 ownerSeed, uint256 minOutSeed) external {
        uint256 t = block.timestamp;
        _refresh(t);
        address owner = address(owners[ownerSeed % 3]);
        Actor caller = _actor(callerSeed, ownerSeed);
        State memory s = _state(owner);
        uint256[16] memory others = _others(owner);
        uint256 minOut = _minOut(s, minOutSeed);

        (bool ok, bytes memory ret) = caller.exec(address(R), abi.encodeCall(Rebalancer.execute, (owner, minOut)));
        bool authorized = address(caller) == owner || address(caller) == s.appointed;
        if (!ok) {
            // A run that `isDue` announced, started by the owner or its keeper, without an own minimum and with the
            // pool filling completely within 45 bps of the feed, must go through (at prices where one sat is small
            // next to the 20 USDC minimum).
            if (
                authorized && s.due && minOut == 0 && _abs(ROUTER.worseBps()) <= 45 && ROUTER.fillBps() == BPS
                    && s.price <= 1_000_000e6
            ) honestRunRefused = true;
            return;
        }
        if (!authorized) unauthorizedRun = true;
        if (s.retired || s.target == 0) runWhileRetiredOrInactive = true;
        if (t < uint256(s.last) + 1 days || (lastRunAt[owner] != 0 && t < lastRunAt[owner] + 1 days)) {
            intervalBroken = true;
        }
        lastRunAt[owner] = t;
        _checkRun(owner, s, t, minOut, abi.decode(ret, (uint256)));
        if (_changed(others, _others(owner))) otherAccountTouched = true;
    }

    /// @dev Mostly valid targets; the keeper is nobody, the keeper, the stranger or another owner.
    function setMandate(uint8 ownerSeed, uint16 target, uint8 keeperSeed) external {
        address owner = address(owners[ownerSeed % 3]);
        if (target % 16 != 0) target = uint16(500 + uint256(target) % 9001);
        address appointed = keeperSeed % 4 == 0 ? address(0) : address(_actor(keeperSeed % 4, ownerSeed));
        (, uint64 lastBefore,,) = R.mandates(owner);
        bool valid = target >= 500 && target <= 9500 && !R.retired();

        (bool ok,) = Actor(owner).exec(address(R), abi.encodeCall(Rebalancer.setMandate, (target, appointed)));
        (uint16 stored, uint64 last, bool unfinished, address k) = R.mandates(owner);
        if (ok != valid || (ok && (stored != target || k != appointed || unfinished)) || last != lastBefore) {
            mandateRuleBroken = true;
        }
    }

    function stop(uint8 ownerSeed) external {
        address owner = address(owners[ownerSeed % 3]);
        (, uint64 lastBefore,,) = R.mandates(owner);
        (bool ok,) = Actor(owner).exec(address(R), abi.encodeCall(Rebalancer.stop, ()));
        (uint16 target, uint64 last, bool unfinished, address k) = R.mandates(owner);
        if (!ok || target != 0 || last != lastBefore || unfinished || k != address(0)) stopBroken = true;
    }

    function approve(uint8 ownerSeed, bool ofUsdc, uint256 amount) external {
        amount = amount % 4 == 0 ? type(uint256).max : ofUsdc ? amount % 100_000e6 : amount % 1e8;
        owners[ownerSeed % 3].exec(address(ofUsdc ? USDC : CBBTC), abi.encodeCall(IERC20.approve, (address(R), amount)));
    }

    /// @dev The owner's wallet receives tokens from outside (a deposit, a purchase elsewhere).
    function receiveTokens(uint8 ownerSeed, uint256 cash, uint256 btc) external {
        address owner = address(owners[ownerSeed % 3]);
        USDC.mint(owner, cash % 20_000e6);
        CBBTC.mint(owner, btc % 0.2e8);
    }

    /// @dev The owner spends tokens elsewhere.
    function spend(uint8 ownerSeed, bool ofUsdc, uint256 amount) external {
        Actor owner = owners[ownerSeed % 3];
        MockERC20 token = ofUsdc ? USDC : CBBTC;
        uint256 balance = token.balanceOf(address(owner));
        owner.exec(address(token), abi.encodeCall(IERC20.transfer, (SINK, amount % (balance + 1))));
    }

    /// @dev Anyone can send tokens to the contract; they must end up with the treasury, never in a run.
    function donate(uint256 cash, uint256 btc) external {
        cash %= 1_000e6;
        btc %= 0.01e8;
        USDC.mint(address(R), cash);
        CBBTC.mint(address(R), btc);
        donatedUsdc += cash;
        donatedBtc += btc;
    }

    function sweep(bool ofUsdc, uint8 callerSeed) external {
        MockERC20 token = ofUsdc ? USDC : CBBTC;
        uint256 held = token.balanceOf(address(R));
        uint256 treasuryBefore = token.balanceOf(address(TREASURY));
        (bool ok,) =
            _actor(callerSeed, callerSeed).exec(address(R), abi.encodeCall(Rebalancer.sweep, (IERC20(address(token)))));
        if (!ok || token.balanceOf(address(R)) != 0 || token.balanceOf(address(TREASURY)) != treasuryBefore + held) {
            sweepBroken = true;
            return;
        }
        if (ofUsdc) sweptUsdc += held;
        else sweptBtc += held;
    }

    /// @dev The treasury retires rarely (7 of 256 seeds), so most sequences keep trading; anyone else must fail.
    function retire(uint8 callerSeed) external {
        Actor caller = _actor(callerSeed, callerSeed);
        bool isTreasury = address(caller) == address(TREASURY);
        if (isTreasury && callerSeed % 40 != 4) return;
        (bool ok,) = caller.exec(address(R), abi.encodeCall(Rebalancer.retire, ()));
        if (ok != isTreasury) retireBroken = true;
        if (ok) retiredSeen = true;
    }

    /// @dev The market moves up to 20% at a time; the feed follows at once.
    function movePrice(int256 bps) external {
        uint256 price = ROUTER.price() * uint256(int256(BPS) + bps % 2001) / BPS;
        ROUTER.setPrice(price < MIN_PRICE ? MIN_PRICE : price > MAX_PRICE ? MAX_PRICE : price);
        _refresh(block.timestamp);
    }

    /// @dev The pool away from the feed, up to 75 bps either way (beyond the 55 bps bound): a push or feed lag.
    function setPoolDeviation(int256 bps) external {
        ROUTER.setWorseBps(bps % 76);
    }

    function warp(uint256 dt) external {
        uint256 t = block.timestamp + 1 minutes + dt % 3 days;
        VM.warp(t);
        _refresh(t);
    }

    // ─── Properties ─────────────────────────────────────────────────────────────────────────────────────────

    function property_onlyOwnerOrKeeperRuns() external view returns (bool) {
        return !unauthorizedRun;
    }

    function property_atMostOneRunPerInterval() external view returns (bool) {
        return !intervalBroken;
    }

    function property_noRunWhenRetiredOrInactive() external view returns (bool) {
        return !runWhileRetiredOrInactive;
    }

    function property_isDueAnnouncesExactlyTheRun() external view returns (bool) {
        return !isDueDisagrees;
    }

    function property_runWithinMinimumAndCap() external view returns (bool) {
        return !sizeBroken;
    }

    function property_lossWithinFeePlusDeviation() external view returns (bool) {
        return !lossBoundBroken;
    }

    function property_swapWithinTheChainlinkBound() external view returns (bool) {
        return !priceBoundBroken;
    }

    function property_runTowardsTheTargetNotPastIt() external view returns (bool) {
        return !directionBroken;
    }

    function property_noRunInsideTheBandUnlessFinishing() external view returns (bool) {
        return !insideBandRun;
    }

    function property_unfinishedFlagFollowsTheRule() external view returns (bool) {
        return !unfinishedFlagWrong;
    }

    function property_outputGoesToTheOwnerAndMeetsMinAmountOut() external view returns (bool) {
        return !outputWrong;
    }

    function property_runLeavesOnlyTheFeeInTheContract() external view returns (bool) {
        return !runLeftMoreThanTheFee;
    }

    function property_noRouterAllowanceLeft() external view returns (bool) {
        return !routerAllowanceLeft && USDC.allowance(address(R), address(ROUTER)) == 0
            && CBBTC.allowance(address(R), address(ROUTER)) == 0;
    }

    function property_otherAccountsUntouched() external view returns (bool) {
        return !otherAccountTouched;
    }

    function property_honestRunsGoThrough() external view returns (bool) {
        return !honestRunRefused;
    }

    function property_mandateRules() external view returns (bool) {
        return !mandateRuleBroken;
    }

    function property_stopAlwaysWorks() external view returns (bool) {
        return !stopBroken;
    }

    function property_sweepSendsEverythingToTheTreasury() external view returns (bool) {
        return !sweepBroken;
    }

    function property_onlyTheTreasuryRetiresForGood() external view returns (bool) {
        return !retireBroken && (!retiredSeen || R.retired());
    }

    /// @dev Between calls the contract holds the fees and donations nobody swept yet, and nothing else; the treasury
    ///      holds exactly what was swept.
    function property_contractHoldsOnlyFeesAndDonations() external view returns (bool) {
        return USDC.balanceOf(address(R)) + sweptUsdc == feesCollected + donatedUsdc
            && CBBTC.balanceOf(address(R)) + sweptBtc == donatedBtc && USDC.balanceOf(address(TREASURY)) == sweptUsdc
            && CBBTC.balanceOf(address(TREASURY)) == sweptBtc;
    }

    // ─── Checks of one run ──────────────────────────────────────────────────────────────────────────────────

    function _checkRun(address owner, State memory s, uint256 t, uint256 minOut, uint256 swapOutput) internal {
        uint256 cash = USDC.balanceOf(owner);
        uint256 btc = CBBTC.balanceOf(owner);
        bool isBuy = cash < s.cash;
        // One leg out of the wallet, the other in.
        if (isBuy ? btc <= s.btc : (cash <= s.cash || btc >= s.btc)) {
            outputWrong = true;
            return;
        }
        uint256 sat = s.price / 1e8 + 1; // the value of one sat, rounded up
        uint256 position = s.btc * s.price / 1e8;
        uint256 total = s.cash + position;
        uint256 run = isBuy ? s.cash - cash : (s.btc - btc) * s.price / 1e8; // the contract's `value`

        // `isDue` announced exactly this run.
        if (!s.due || (s.delta > 0) != isBuy || _abs(s.delta) != run) isDueDisagrees = true;

        // At least the minimum, at most max(10% of the total, the minimum).
        uint256 cap = total / 10 > MIN_TRADE ? total / 10 : MIN_TRADE;
        if (run < MIN_TRADE || run > cap + sat) sizeBroken = true;

        // Loss against Chainlink: at most FEE_BPS + MAX_DEVIATION_BPS of the run, plus a few sats of rounding.
        uint256 positionAfter = btc * s.price / 1e8;
        uint256 totalAfter = cash + positionAfter;
        if (total > totalAfter && total - totalAfter > run * 80 / BPS + 3 * sat) lossBoundBroken = true;

        // What the swap delivered lies within MAX_DEVIATION_BPS of the Chainlink value of its input, in both directions.
        uint256 expected = isBuy ? (run - run * FEE_BPS / BPS) * 1e8 / s.price : run;
        if (swapOutput > expected * (BPS + 55) / BPS || swapOutput * BPS < expected * (BPS - 55)) {
            priceBoundBroken = true;
        }

        // Towards the target, and not past it by more than a pool 55 bps better than the feed can add (~0.3%).
        bool wantsBuy = position * BPS < total * s.target;
        uint256 over = run * 60 + 2 * sat * BPS; // 0.6% of the run, in the BPS-scaled units below
        if (
            wantsBuy != isBuy
                || (isBuy
                        ? positionAfter * BPS > totalAfter * s.target + over
                        : positionAfter * BPS + over < totalAfter * s.target)
        ) directionBroken = true;

        // Inside the band only as the follow-up of a correction the previous run left undone.
        uint256 drift = wantsBuy ? total * s.target - position * BPS : position * BPS - total * s.target;
        bool finishing = s.unfinished && t < uint256(s.last) + 2 days;
        if (!finishing && drift <= total * BAND_BPS) insideBandRun = true;
        _afterRun(owner, isBuy, finishing, drift <= total * BAND_BPS);

        // The mandate: this run's time, and `unfinished` exactly when at least the minimum of the drift is left.
        (, uint64 last, bool unfinished,) = R.mandates(owner);
        if (last != t || unfinished != (drift / BPS >= run + MIN_TRADE)) unfinishedFlagWrong = true;

        // The output goes to the owner and meets `minAmountOut`; the fee stays; nothing else moves in or out.
        uint256 fee = (isBuy ? run : swapOutput) * FEE_BPS / BPS;
        if (swapOutput < minOut || (isBuy ? btc - s.btc != swapOutput : cash - s.cash != swapOutput - fee)) {
            outputWrong = true;
        }
        if (USDC.balanceOf(address(R)) != s.heldUsdc + fee || CBBTC.balanceOf(address(R)) != s.heldBtc) {
            runLeftMoreThanTheFee = true;
        }
        if (USDC.allowance(address(R), address(ROUTER)) != 0 || CBBTC.allowance(address(R), address(ROUTER)) != 0) {
            routerAllowanceLeft = true;
        }
        feesCollected += fee;
    }

    /// @dev Hook for the canaries.
    function _afterRun(address owner, bool isBuy, bool finishing, bool insideBand) internal virtual {}

    // ─── Helpers ────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev The feeds are live: a fresh cbBTC/USD answer at the pool's mid price and a sequencer up for two hours.
    function _refresh(uint256 t) internal {
        FEED.set(int256(ROUTER.price() * 100), t, t);
        SEQUENCER.set(0, t - 2 hours, t);
    }

    /// @dev 0 = the owner, 1 = the keeper, 2 = the stranger, 3 = another owner, 4 = the treasury.
    function _actor(uint8 seed, uint8 ownerSeed) internal view returns (Actor) {
        uint256 kind = seed % 5;
        if (kind == 0) return owners[ownerSeed % 3];
        if (kind == 1) return KEEPER;
        if (kind == 2) return STRANGER;
        if (kind == 3) return owners[(uint256(ownerSeed) + 1) % 3];
        return TREASURY;
    }

    function _state(address owner) internal view returns (State memory s) {
        (s.target, s.last, s.unfinished, s.appointed) = R.mandates(owner);
        s.retired = R.retired();
        s.price = R.quote();
        s.cash = USDC.balanceOf(owner);
        s.btc = CBBTC.balanceOf(owner);
        (s.due, s.delta) = R.isDue(owner);
        s.heldUsdc = USDC.balanceOf(address(R));
        s.heldBtc = CBBTC.balanceOf(address(R));
    }

    /// @dev 0 (only the Chainlink bound), a demand around the Chainlink value of the announced run, or an impossible one.
    function _minOut(State memory s, uint256 seed) internal pure returns (uint256) {
        uint256 kind = seed % 4;
        if (kind == 0) return 0;
        if (kind == 3) return type(uint256).max;
        uint256 value = _abs(s.delta);
        uint256 expected = s.delta > 0 ? (value - value * FEE_BPS / BPS) * 1e8 / s.price : value;
        return expected * (kind == 1 ? 9950 : 9900 + (seed >> 8) % 200) / BPS;
    }

    /// @dev Balances of every account except `owner`, the allowances and mandates of the other owners.
    function _others(address owner) internal view returns (uint256[16] memory v) {
        uint256 k;
        for (uint256 i; i < 3; i++) {
            address other = address(owners[i]);
            if (other == owner) continue;
            (uint16 target, uint64 last, bool unfinished, address appointed) = R.mandates(other);
            v[k++] = USDC.balanceOf(other);
            v[k++] = CBBTC.balanceOf(other);
            v[k++] = USDC.allowance(other, address(R));
            v[k++] = CBBTC.allowance(other, address(R));
            v[k++] = uint256(keccak256(abi.encode(target, last, unfinished, appointed)));
        }
        address[3] memory rest = [address(KEEPER), address(STRANGER), address(TREASURY)];
        for (uint256 i; i < 3; i++) {
            v[k++] = USDC.balanceOf(rest[i]);
            v[k++] = CBBTC.balanceOf(rest[i]);
        }
    }

    function _changed(uint256[16] memory a, uint256[16] memory b) internal pure returns (bool) {
        for (uint256 i; i < 16; i++) {
            if (a[i] != b[i]) return true;
        }
        return false;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        // Safe: never called with type(int256).min.
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}

/// @dev Canaries: each fails as soon as the fuzzer reached the state it names. All are expected to fail; a canary that
///      holds means the run never got there.
contract RebalancerCanaries is RebalancerHarness {
    uint256 internal buys;
    uint256 internal sells;
    uint256 internal followUpsInsideTheBand;
    uint256 internal reversals;
    mapping(address owner => int8) internal lastDirection;

    function _afterRun(address owner, bool isBuy, bool finishing, bool insideBand) internal override {
        int8 direction = isBuy ? int8(1) : int8(-1);
        if (isBuy) buys++;
        else sells++;
        if (finishing && insideBand) followUpsInsideTheBand++;
        if (finishing && lastDirection[owner] == -direction) reversals++;
        lastDirection[owner] = direction;
    }

    function property_canary_noBuy() external view returns (bool) {
        return buys == 0;
    }

    function property_canary_noSell() external view returns (bool) {
        return sells == 0;
    }

    function property_canary_noFollowUpInsideTheBand() external view returns (bool) {
        return followUpsInsideTheBand == 0;
    }

    /// @dev A follow-up run (the band does not apply) in the opposite direction of the run before it.
    function property_canary_noReversingFollowUp() external view returns (bool) {
        return reversals == 0;
    }

    function property_canary_notRetired() external view returns (bool) {
        return !retiredSeen;
    }
}

/// @dev A pool that can run dry: it takes 98-100% of the input. A real v3 pool does this only when the swap exhausts
///      all liquidity in its direction (the router passes no price limit, so the price runs to the end of the range).
///      Without the contract's check on the router's allowance, `property_runLeavesOnlyTheFeeInTheContract`,
///      `property_noRouterAllowanceLeft` and `property_contractHoldsOnlyFeesAndDonations` fail here within two calls.
contract RebalancerPartialFill is RebalancerHarness {
    function setFill(uint256 bps) external {
        ROUTER.setFillBps(9_800 + bps % 201);
    }
}
