// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IV3SwapRouter} from "./interfaces/IV3SwapRouter.sol";

/**
 * @title Rebalancer
 * @notice Rebalances a user's wallet between USDC and cbBTC towards the cbBTC share the user chose, using an ERC-20
 *         allowance. The funds stay in the user's wallet; between transactions the contract only holds the fees it
 *         has collected and not yet forwarded to the treasury.
 *
 * @dev Immutable: no admin, no upgrade, no pause. The only switch is `retire`, which stops the contract for good and
 *      cannot touch funds or mandates.
 *
 *      Who may trade. Only the owner of a wallet, or the keeper that owner appointed in `setMandate`, may call
 *      `execute` for it. The caller chooses the moment and may demand a better price (`minAmountOut`); direction and
 *      amount follow from the rule below, and the price is bounded by Chainlink. The owner can replace the keeper or
 *      revoke the mandate at any time.
 *
 *      The rule. position = cbBTC balance at the Chainlink price, total = USDC balance + position,
 *      drift = |position − total × target|. A correction starts when drift > BAND_BPS of the total. One run corrects
 *      the drift, at most max(MAX_CORRECTION_BPS of the total, MIN_TRADE_USDC); when that would leave less than
 *      MIN_TRADE_USDC of the drift, the run takes the whole drift instead. Balance and allowance cap it, it is never
 *      less than MIN_TRADE_USDC, and it runs at most once per INTERVAL. A run that leaves at least MIN_TRADE_USDC of
 *      its correction undone is followed up on the next days until the target is reached, also inside the band.
 *
 *      Price bound. The output the contract actually receives must lie within MAX_DEVIATION_BPS of the Chainlink
 *      value of the input, pool fee included, in both directions. The lower bound caps what a run can lose to a
 *      pushed pool: FEE_BPS + MAX_DEVIATION_BPS against Chainlink. The upper bound stops the contract when pool and
 *      feed disagree the other way, which is what a stuck feed or a USDC depeg looks like (the feed is cbBTC/USD and
 *      USDC counts as one dollar).
 *
 *      Fees. FEE_BPS of the USDC leg of every run stays in the contract; anyone can forward it to the treasury with
 *      `sweep`. Decisions, measurements and the trust model are in README.md.
 */
contract Rebalancer is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC; // 6 decimals
    IERC20 public immutable CBBTC; // 8 decimals
    IV3SwapRouter public immutable ROUTER; // Uniswap SwapRouter02
    IAggregatorV3 public immutable FEED_CBBTC_USD; // 8 decimals
    IAggregatorV3 public immutable SEQUENCER_FEED; // L2 Sequencer Uptime, answer 0 = up
    address public immutable TREASURY;

    uint24 public constant POOL_FEE = 500; // the USDC/cbBTC 0.05% pool
    uint256 public constant FEE_BPS = 25;
    uint256 public constant MIN_TARGET_BPS = 500;
    uint256 public constant MAX_TARGET_BPS = 9500;
    uint256 public constant BAND_BPS = 200;
    /// @notice Per run, share of the total value. A run that this cap would leave less than MIN_TRADE_USDC short of
    ///         the target takes that remainder too, so it can exceed the cap by just under MIN_TRADE_USDC.
    uint256 public constant MAX_CORRECTION_BPS = 1000;
    /// @notice The smallest run that is worth making, the smallest remainder the cap leaves for a next run, and the
    ///         step that separates a finished correction from an unfinished one in `_plan`. It has to be strictly
    ///         positive: at 0 a run that finishes its correction would still mark itself unfinished, which drops the
    ///         band for the next day and never stops.
    /// @dev 2 USDC, which is set by the rounding rather than by the economics. A run is measured in whole satoshi,
    ///      so the single unit a swap can round away is worth `price / 1e8` — a share of the run that grows as the
    ///      run shrinks and as cbBTC gets dearer. It has to stay well inside MAX_DEVIATION_BPS, which the pool's own
    ///      distance to the feed and the pool fee already eat into, or a run reverts on a bound that rounding alone
    ///      pushed it past. At 2 USDC that unit is 4.25 bps of the run at 85,000 USDC per cbBTC and 5 bps at
    ///      100,000: up to there a pool 50 bps off the feed still executes a run of the minimum. Above 100,000 such
    ///      a run needs a pool closer to the feed or it reverts, harmlessly, until the next attempt. It serves
    ///      wallets from ~40 USDC, against ~100 at 5 USDC.
    uint256 public constant MIN_TRADE_USDC = 2e6;
    uint256 public constant INTERVAL = 1 days; // between two runs of one owner
    /// @notice How far the received output may lie from the Chainlink value of the input, pool fee (5 bps) included.
    uint256 public constant MAX_DEVIATION_BPS = 55;
    uint256 public constant GRACE_PERIOD = 1 hours; // after the sequencer comes back up
    uint256 public constant MAX_FEED_AGE = 1500; // cbBTC/USD heartbeat of 20 minutes + 25%
    uint256 private constant BPS = 10_000;
    uint256 private constant CBBTC_UNIT = 1e8;
    uint256 private constant FEED_UNITS_PER_USDC_UNIT = 100; // the feed has 8 decimals, USDC has 6

    /// @dev One storage slot per owner. `targetBps` 0 = no mandate.
    struct Mandate {
        uint16 targetBps; // cbBTC share of the total value
        uint64 lastExecutedAt;
        bool unfinished; // the last run left at least MIN_TRADE_USDC of its correction undone
        address keeper; // may call `execute` for this owner, next to the owner; address(0) = only the owner
    }

    mapping(address owner => Mandate) public mandates;
    /// @notice True once the treasury has called `retire`. Irreversible.
    bool public retired;

    event MandateSet(address indexed owner, uint16 targetBps, address indexed keeper);
    /// @param amountIn  What the owner paid: USDC for a buy (fee included), cbBTC for a sell.
    /// @param amountOut What the owner received: cbBTC for a buy, USDC for a sell (fee deducted).
    /// @param fee       In USDC.
    /// @param price     USDC base units per cbBTC according to Chainlink.
    /// @param total     Value of the wallet in USDC before the run.
    event Executed(
        address indexed owner,
        bool isBuy,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee,
        uint256 price,
        uint256 total
    );
    event Retired();

    error InvalidTarget();
    error Inactive();
    error NotOwnerOrKeeper();
    error NotDue();
    error NothingToDo();
    error SequencerDown();
    error StaleFeed();
    error InvalidFeedAnswer();
    /// @notice The swap delivered nothing, more than MAX_DEVIATION_BPS above `expected`, or less than the lower bound,
    ///         or the pool did not take all of the input. Too little normally shows up earlier, as the router's own
    ///         "Too little received".
    error OutsidePriceBounds(uint256 received, uint256 expected);
    error ContractRetired();
    error NotTreasury();
    error ZeroAddress();
    error NotAContract(address account);
    error UnexpectedDecimals(address target);

    constructor(
        address usdc,
        address cbbtc,
        address router,
        address feedCbbtcUsd,
        address sequencerFeed,
        address treasury
    ) {
        if (treasury == address(0)) revert ZeroAddress();
        if (router.code.length == 0) revert NotAContract(router);
        USDC = IERC20(usdc);
        CBBTC = IERC20(cbbtc);
        ROUTER = IV3SwapRouter(router);
        FEED_CBBTC_USD = IAggregatorV3(feedCbbtcUsd);
        SEQUENCER_FEED = IAggregatorV3(sequencerFeed);
        TREASURY = treasury;

        // The amounts and `_quote` are written for these decimals.
        if (IERC20Metadata(usdc).decimals() != 6) revert UnexpectedDecimals(usdc);
        if (IERC20Metadata(cbbtc).decimals() != 8) revert UnexpectedDecimals(cbbtc);
        if (FEED_CBBTC_USD.decimals() != 8) revert UnexpectedDecimals(feedCbbtcUsd);
        _quote(); // both feeds must answer at deployment
    }

    // ─── Owner ──────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Sets the caller's target cbBTC share and the keeper that may run it.
    /// @param keeper address(0) = only the caller may run their own wallet.
    function setMandate(uint16 targetBps, address keeper) external {
        if (retired) revert ContractRetired();
        if (targetBps < MIN_TARGET_BPS || targetBps > MAX_TARGET_BPS) revert InvalidTarget();
        _setMandate(targetBps, keeper);
    }

    /// @notice Revokes the caller's mandate. Also works after `retire`.
    function stop() external {
        _setMandate(0, address(0));
    }

    /// @dev Leaves `lastExecutedAt` alone: changing a mandate does not shorten INTERVAL. A new mandate starts from
    ///      the band again.
    function _setMandate(uint16 targetBps, address keeper) private {
        Mandate storage m = mandates[msg.sender];
        m.targetBps = targetBps;
        m.unfinished = false;
        m.keeper = keeper;
        emit MandateSet(msg.sender, targetBps, keeper);
    }

    // ─── Reading ────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice What `execute(owner, …)` would trade now. `usdcDelta` > 0 = buy cbBTC for that much USDC, < 0 = sell
    ///         cbBTC worth that much USDC at the Chainlink price.
    /// @dev Reverts, like `execute`, when the sequencer or the price feed fails. Does not look at the pool: whether
    ///      the price bound holds only shows when the swap runs, so simulate `execute` before sending it.
    function isDue(address owner) external view returns (bool due, int256 usdcDelta) {
        Mandate memory m = mandates[owner];
        if (retired || m.targetBps == 0 || block.timestamp < m.lastExecutedAt + INTERVAL) return (false, 0);
        uint256 price = _quote();
        (bool isBuy, uint256 amountIn,,) = _plan(owner, m.targetBps, _finishing(m), price);
        if (amountIn == 0) return (false, 0);
        uint256 value = isBuy ? amountIn : amountIn * price / CBBTC_UNIT;
        // The value of a wallet is far below 2^255, so the casts cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, isBuy ? int256(value) : -int256(value));
    }

    /// @notice Chainlink price in USDC base units per cbBTC, with USDC counted as one dollar.
    function quote() external view returns (uint256) {
        return _quote();
    }

    // ─── Execution ──────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Performs one rebalance run for `owner`. Only the owner or the keeper the owner appointed.
    /// @param minAmountOut Lower bound for the output of the swap (cbBTC for a buy, USDC before the fee for a sell).
    ///                     It can only make the price bound stricter; 0 = only the Chainlink bound applies.
    /// @return swapOutput  What the swap delivered, in the same terms as `minAmountOut`. A keeper simulates
    ///                     `execute(owner, 0)` and demands that amount, minus a small tolerance, in the transaction.
    function execute(address owner, uint256 minAmountOut) external nonReentrant returns (uint256 swapOutput) {
        if (retired) revert ContractRetired();
        Mandate storage m = mandates[owner];
        uint256 targetBps = m.targetBps;
        if (targetBps == 0) revert Inactive();
        if (msg.sender != owner && msg.sender != m.keeper) revert NotOwnerOrKeeper();
        if (block.timestamp < m.lastExecutedAt + INTERVAL) revert NotDue();

        uint256 price = _quote();
        (bool isBuy, uint256 amountIn, uint256 total, bool unfinished) = _plan(owner, targetBps, _finishing(m), price);
        if (amountIn == 0) revert NothingToDo();
        m.lastExecutedAt = uint64(block.timestamp);
        m.unfinished = unfinished;

        uint256 fee;
        uint256 amountOut;
        if (isBuy) {
            USDC.safeTransferFrom(owner, address(this), amountIn);
            fee = amountIn * FEE_BPS / BPS;
            uint256 swapIn = amountIn - fee;
            swapOutput = _swap(USDC, CBBTC, swapIn, swapIn * CBBTC_UNIT / price, minAmountOut);
            amountOut = swapOutput;
            CBBTC.safeTransfer(owner, amountOut);
        } else {
            CBBTC.safeTransferFrom(owner, address(this), amountIn);
            swapOutput = _swap(CBBTC, USDC, amountIn, amountIn * price / CBBTC_UNIT, minAmountOut);
            fee = swapOutput * FEE_BPS / BPS;
            amountOut = swapOutput - fee;
            USDC.safeTransfer(owner, amountOut);
        }
        emit Executed(owner, isBuy, amountIn, amountOut, fee, price, total);
    }

    /// @notice Forwards the contract's whole balance of `token` to the treasury: collected USDC fees, or tokens sent
    ///         here by mistake. Anyone may call this.
    function sweep(IERC20 token) external nonReentrant {
        token.safeTransfer(TREASURY, token.balanceOf(address(this)));
    }

    /// @notice Stops the contract for good. Only the treasury. After this `execute` and `setMandate` revert and
    ///         `isDue` reports nothing; `stop` and `sweep` keep working. It cannot touch funds or allowances.
    function retire() external {
        if (msg.sender != TREASURY) revert NotTreasury();
        retired = true;
        emit Retired();
    }

    // ─── Internal ───────────────────────────────────────────────────────────────────────────────────────────

    /// @return price USDC base units (6 decimals) per cbBTC, from the 8-decimal cbBTC/USD feed.
    function _quote() internal view returns (uint256 price) {
        (, int256 sequencerAnswer, uint256 upSince,,) = SEQUENCER_FEED.latestRoundData();
        // upSince 0 is an uninitialized round and counts as down, like a time in the future.
        if (
            sequencerAnswer != 0 || upSince == 0 || upSince > block.timestamp
                || block.timestamp - upSince < GRACE_PERIOD
        ) revert SequencerDown();

        (, int256 answer,, uint256 updatedAt,) = FEED_CBBTC_USD.latestRoundData();
        if (answer <= 0) revert InvalidFeedAnswer();
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > MAX_FEED_AGE) revert StaleFeed();
        // answer > 0 is enforced above, so the cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        price = uint256(answer) / FEED_UNITS_PER_USDC_UNIT;
        if (price == 0) revert InvalidFeedAnswer(); // a price that rounds to 0 is as unusable as a negative one
    }

    /// @dev Is this run the follow-up of a correction that the previous run left undone? Only on the next days:
    ///      after two INTERVALs without a run a correction starts from the band again.
    function _finishing(Mandate memory m) internal view returns (bool) {
        return m.unfinished && block.timestamp < m.lastExecutedAt + 2 * INTERVAL;
    }

    /// @dev The rule from the contract header. `finishing`: this run follows up an unfinished correction, so the band
    ///      does not apply. `amountIn` is in the input token (USDC for a buy, cbBTC for a sell); 0 = do nothing.
    ///      `unfinished`: at least MIN_TRADE_USDC of the drift is left after this run. The cap never leaves a smaller
    ///      remainder: the run then takes the whole drift. Balance and allowance come after, so they can leave less,
    ///      which is not followed up.
    function _plan(address owner, uint256 targetBps, bool finishing, uint256 price)
        internal
        view
        returns (bool isBuy, uint256 amountIn, uint256 total, bool unfinished)
    {
        uint256 cash = USDC.balanceOf(owner);
        uint256 btc = CBBTC.balanceOf(owner);
        uint256 position = btc * price / CBBTC_UNIT;
        total = cash + position;

        // Times BPS, so that the comparison with the band is exact and does not depend on rounding.
        isBuy = position * BPS < total * targetBps;
        uint256 drift = isBuy ? total * targetBps - position * BPS : position * BPS - total * targetBps;
        if (!finishing && drift <= total * BAND_BPS) return (isBuy, 0, total, false);
        drift /= BPS;
        uint256 run = Math.min(drift, Math.max(total * MAX_CORRECTION_BPS / BPS, MIN_TRADE_USDC));
        if (drift - run < MIN_TRADE_USDC) run = drift; // a remainder too small for a run of its own is taken now

        uint256 value; // of `amountIn`, in USDC at the Chainlink price
        if (isBuy) {
            amountIn = Math.min(run, Math.min(cash, USDC.allowance(owner, address(this))));
            value = amountIn;
        } else {
            // Rounded up, so that a run of exactly MIN_TRADE_USDC is not worth 1 unit less after the conversion back.
            amountIn = Math.mulDiv(run, CBBTC_UNIT, price, Math.Rounding.Ceil);
            amountIn = Math.min(amountIn, Math.min(btc, CBBTC.allowance(owner, address(this))));
            value = amountIn * price / CBBTC_UNIT;
        }
        if (value < MIN_TRADE_USDC) return (isBuy, 0, total, false);
        unfinished = drift >= value + MIN_TRADE_USDC;
    }

    /// @dev Swaps `amountIn` through the USDC/cbBTC pool into this contract and enforces the price bound on what
    ///      actually arrived. `expectedOut` is the Chainlink value of `amountIn` in the output token.
    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn, uint256 expectedOut, uint256 minAmountOut)
        private
        returns (uint256 received)
    {
        // Rounded up: at a small `expectedOut` a bound that rounds down would be looser than MAX_DEVIATION_BPS.
        uint256 minOut =
            Math.max(minAmountOut, Math.mulDiv(expectedOut, BPS - MAX_DEVIATION_BPS, BPS, Math.Rounding.Ceil));
        uint256 balanceBefore = tokenOut.balanceOf(address(this)); // USDC also holds the collected fees
        tokenIn.forceApprove(address(ROUTER), amountIn);
        ROUTER.exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                fee: POOL_FEE,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        received = tokenOut.balanceOf(address(this)) - balanceBefore;
        // A pool that runs dry takes only part of the input, and the router does not check that it took all of it: the
        // rest would stay here, with the allowance, and be swept to the treasury as if it were a fee.
        if (
            received == 0 || received < minOut || received > expectedOut * (BPS + MAX_DEVIATION_BPS) / BPS
                || tokenIn.allowance(address(this), address(ROUTER)) != 0
        ) revert OutsidePriceBounds(received, expectedOut);
    }
}
