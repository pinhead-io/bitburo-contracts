// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IV3SwapRouter} from "./interfaces/IV3SwapRouter.sol";
import {TickMath} from "./libraries/TickMath.sol";

/**
 * @title Rebalancer
 * @notice A single immutable contract that, using an ERC-20 mandate (allowance) from the user, rebalances the
 *         user's wallet between EURC and cbBTC towards an allocation chosen by the user. The funds stay in the
 *         user's wallet; outside a transaction the contract never holds a balance.
 *
 * @dev The calculation rule is a one-to-one copy of AutoTradeStrategy::rebalanceAmount from the Bitburo app:
 *      fraction = position / total; drift = fraction - target; |drift| <= band -> nothing;
 *      correction = |drift| * total; cap = max(total * maxCorrection, minTrade); correction = min(correction, cap);
 *      correction < minTrade -> nothing. Drift < 0 -> buy (EURC -> cbBTC), otherwise sell.
 *
 *      No admin, no upgrade, no pause button. `execute` is permissionless; the caller can only choose
 *      when, never what or how much. The fee is fixed and always goes to the treasury in EURC, with a fixed
 *      reward for the caller. The treasury's only power is `retire`: a one-time,
 *      irreversible switch that stops the contract permanently (see there). It cannot do anything with funds.
 *
 *      Sandwich protection (audit M-1, L-3), in three layers:
 *      1. Block check and block window per pool. A run happens only if neither pool has already written an
 *         oracle observation in this block (`observations[slot0.observationIndex].blockTimestamp == block.timestamp`,
 *         otherwise `PoolTouchedThisBlock`). According to Uniswap v3-core (commit d8b1c635) exactly these actions
 *         write an observation:
 *         - a swap that changes the tick (UniswapV3Pool.sol:732-748);
 *         - a mint or burn with liquidity > 0 of a position whose range contains the current tick
 *           (`_modifyPosition`, :327 and :336-348).
 *         At most one per block (Oracle.sol:90). A swap within the tick, a mint or burn outside the range, a
 *         burn of 0, `collect` and `flash` write nothing. If there is no observation in this block, tick and
 *         in-range liquidity are still as at the start of the block: in this block an attacker can at most push
 *         within the start tick (≤ 1 tick ≈ 1 bp per pool) and cannot add JIT liquidity in the range. Exception
 *         (self-audit 2026-09-17, L-E): if the price sits exactly on a tick boundary b, Uniswap treats a position
 *         with b as its boundary in the swap direction as outside the range; a mint writes nothing, but the run
 *         crosses b immediately and trades against it. That does not make the run larger than the in-range upper
 *         bound and gives the victim a better price; the JIT position only collects pool fee, at the expense of
 *         other LPs. Both before and after the swap the price must also lie within MAX_BLOCK_MOVE_BPS of that start
 *         tick, including the run's own swap. Residual risk (review F-4): a push within the start tick writes
 *         nothing and cannot be seen without an observation, so the victim may trade up to ~1 tick per pushed pool
 *         worse (tick granularity). An LP with a large share that minted in an earlier block gets most of the pool
 *         fee of that push back; what remains for him is the protocol fee share. That is a Uniswap governance
 *         setting (`feeProtocol` currently 68, 1/4 on both pools). Two measures, each in bp of the run:
 *         - extra loss for the victim (with push versus without push, for the same run): < 2.05 bp, ~1 tick
 *           per pushed pool, independent of the protocol fee (measured +1.99 bp);
 *         - extra profit for the attacker (with push versus without push, for the same correction, each at its own
 *           run): < 0.5 bp at the current protocol fee (measured up to +0.18 bp; around the capacity of the window
 *           ≤ −1.68 bp). If Uniswap sets the protocol fee to 0 (hypothetical), that profit depends on the block and
 *           has no fixed bound: measured +1.39 to +4.07 bp over five blocks (share of 99% or 99.9% of both
 *           pools, a run just below capacity; highest at block 51,407,293). The surplus above the victim's loss
 *           comes from the volume that falls away: if the push makes the run smaller, the attacker as LP also
 *           does not lose on the margin on that volume. The victim loses no more than ~1 tick per
 *           pushed pool. Accepted risk; see README.
 *         Pushing at the end of the previous block is not detected (review I-4; not atomic, layer 3 and arbitrage
 *         bound it). Layer 3 measures against Chainlink, not against the market: if a feed lags within its
 *         deviation threshold in the attacker's favour (cbBTC/USD 0.3%, EURC/USD 0.1%), that push may be
 *         larger (self-audit 2026-09-17, L-F; see README).
 *         Multiple `execute`s in the same block share the same window, but only as long as no run changes the
 *         tick; after that the pool has been touched in this block.
 *      2. Run size from liquidity. `_plan` caps the run so that the estimated final price uses at most SIZING_BPS
 *         of the remaining room up to the window edge, calculated with the smallest liquidity up to that edge (also
 *         beyond a tick boundary in the window, review L-1). Liquidity outside the range never makes a run larger
 *         than the in-range liquidity allows (though it can remove a cliff that first made the run smaller).
 *         If the correction does not fit within that, it is done in chunks (see `rounds`).
 *      3. Spot against Chainlink. Before and after every swap the spot of both pools must lie within
 *         MAX_SPOT_DEVIATION_BPS of the Chainlink price, and `amountOutMinimum` follows from Chainlink and
 *         `maxSlippageBps`. That bounds pushing over multiple blocks, which the block window does not see. The
 *         maximum loss per run relative to the Chainlink price remains FEE_BPS + maxSlippageBps
 *         (0.85% to 1.25%). Because the run's own swap moves the combined spot by at most ~12 bp (6 bp per pool),
 *         an honest run can only get stuck on the spot check after the swap if the spot already deviated by more
 *         than ~38 bp in the run direction beforehand (audit lead 4; measured in 0.69% of hourly samples over 30
 *         days, see README). According to Chainlink both feeds are `dex_state_price`; which pools they use is not
 *         published, so the monitored pools may partly be in the feed (audit lead 5, see README).
 *
 *      Chunks: a run capped by liquidity opens a round. The next chunk in the same direction
 *      may follow after CHUNK_INTERVAL instead of after `interval`, until the deviation is within the band or the
 *      round's budget (maxCorrectionBps of the value at the first run, and per chunk never more than
 *      maxCorrectionBps of the current value) is used up. Every chunk is a normal run with fee and keeper reward.
 *
 *      Failure: a run reverts before the swap with `PoolTouchedThisBlock` if a pool already wrote an observation
 *      in this block (by others or by an earlier run), and with `BlockMoveExceeded` if there is too little room or
 *      liquidity or the run reaches the window edge. Both are temporary: retry in a later block.
 *      Measured on Base (2,000 blocks around block 51,390,800), the block check makes 0% of attempts fail when the
 *      transaction is at the top of the block, 4.3% halfway and 7 to 11% at the bottom.
 *
 *      Blocking runs (audit L-3): whoever touches a pool every block (a burn of 1 liquidity in the range costs
 *      ~92,630 gas, measured ~1.8 EURC per hour) blocks all runs in those blocks, without earning anything from
 *      it. No contract change makes that more expensive while a touch still costs only gas; the answer lies in
 *      the keepers: reading with block overrides for the next block, retrying for the whole retry budget,
 *      and sending with a priority fee that rises after a blockade, so that the attacker has to pay that tip every
 *      block (see README and keeper/keeper.ts).
 *
 *      Availability: the fee transfer to the treasury and the reward are done with a non-reverting
 *      transfer. If the treasury transfer fails (for example a Circle blacklist), the fee stays in
 *      the contract (FeeRetained) and `sweep` can still collect it later; the rebalance itself never breaks
 *      on the fee recipient.
 */
contract Rebalancer is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ─── Fixed parameters────────────────────────────────────────────────────────────────────────────────────

    IERC20 public immutable EURC; // 6 decimals
    IERC20 public immutable CBBTC; // 8 decimals
    address public immutable USDC; // only as an intermediate hop in the Uniswap path
    IV3SwapRouter public immutable ROUTER; // Uniswap SwapRouter02
    IAggregatorV3 public immutable FEED_CBBTC_USD; // 8 decimals
    /// @dev On Base the Standard proxy `0x9867…01e0` of the SVR feed EURC/USD, not the SVR proxy `0x8a55…E287`: this
    ///      way the delay for the MEV-Share auction does not apply (audit lead 5).
    IAggregatorV3 public immutable FEED_EURC_USD; // 8 decimals
    IAggregatorV3 public immutable SEQUENCER_FEED; // L2 Sequencer Uptime, answer 0 = up
    address public immutable TREASURY;
    /// @notice Uniswap v3 pool EURC/USDC (0.05%), only read for the spot-vs-oracle check. The constructor enforces
    ///         that this is the POOL_FEE pool of ROUTER's factory, i.e. the pool the swap goes through.
    IUniswapV3Pool public immutable POOL_EURC_USDC;
    /// @notice Uniswap v3 pool USDC/cbBTC (0.05%), only read for the spot-vs-oracle check. Same constructor check.
    IUniswapV3Pool public immutable POOL_USDC_CBBTC;
    bool private immutable _eurcIsToken0;
    bool private immutable _usdcIsToken0;

    uint24 public constant POOL_FEE = 500; // 0.05% on both hops
    /// @notice tickSpacing of the POOL_FEE pools (UniswapV3Factory: feeAmountTickSpacing[500] = 10, cannot change).
    ///         The constructor enforces it; `_maxInput` relies on it.
    int24 public constant TICK_SPACING = 10;
    uint16 public constant FEE_BPS = 25;
    /// @notice Reward for the caller, at most half of the run's fee (self-audit 2026-09-17, L-D): this way the
    ///         treasury keeps at least half of every run, even if the caller is the owner themselves.
    uint256 public constant KEEPER_REWARD_EURC = 50_000; // 0.05 EURC
    uint16 public constant MAX_SLIPPAGE_BPS = 100;
    /// @notice Lower bound for `maxSlippageBps`: MAX_SPOT_DEVIATION_BPS + 2 × 5 bps pool fee. `amountOutMinimum`
    ///         is derived from the oracle, while the swap runs against the pool spot; that may deviate 0.5% and
    ///         costs 0.1% in pool fees. Below 60 bps a run that passes the spot check could structurally
    ///         revert with "Too little received".
    uint16 public constant MIN_SLIPPAGE_BPS = 60;
    uint16 public constant MAX_SPOT_DEVIATION_BPS = 50;
    /// @notice Lower bound for `minTradeEurc` (20 EURC) and for every run, including every chunk of a round. With
    ///         FEE_BPS = 25 the fee of the smallest run is then 0.05 EURC, so that a dust owner cannot keep the
    ///         keepers busy for free: the reward is then 0.025 EURC (half of the fee, see KEEPER_REWARD_EURC) and the
    ///         treasury gets the other half. That holds for buying and selling alike: for a buy the fee base is
    ///         the gross input amount, for a sell max(received, expected proceeds), where the expected
    ///         proceeds are the same oracle value against which the lower bound was checked (audit L-B). Moreover,
    ///         `expectedOut` for a buy is then ≥ ~25,000 sats at 80,000 EURC/cbBTC, so that the rounding in
    ///         `amountOutMinimum` stays below 1 bp.
    uint64 public constant MIN_TRADE_FLOOR = 20e6;
    /// @notice How far the price of each pool may lie within one block from the price at the start of that
    ///         block, including the run's own swap (audit M-1). Below the pool fee there and back (2 × 5 bp), so
    ///         that a self-sandwich makes a loss per pushed unit. The start tick is rounded; the window is
    ///         calculated from the least favourable edge of that tick, so that the rounding (≤ 1 tick ≈ 1 bp) only
    ///         costs honest runs room and never gives an attacker room.
    ///         Must stay well below TICK_SPACING ticks (1 tick ≈ 1 bp): `_maxInput` assumes that between the
    ///         price and the window edge there is at most one initializable tick boundary.
    uint16 public constant MAX_BLOCK_MOVE_BPS = 6;
    /// @notice Which share of the remaining room up to the window edge a run may use according to the estimate at
    ///         constant liquidity. The margin absorbs liquidity that becomes thinner across a tick boundary.
    uint16 public constant SIZING_BPS = 7500;
    /// @notice Minimum time between two chunks of one round.
    uint32 public constant CHUNK_INTERVAL = 10 minutes;
    /// @notice Lower bound for `maxCorrectionBps` (0.1% per run): rules out configurations that make a
    ///         negligible correction every interval and thereby stay due forever.
    uint16 public constant MIN_CORRECTION_BPS = 10;
    /// @notice Lower bound for `bandBps` (1.25%): FEE_BPS + MAX_SLIPPAGE_BPS, the most a run costs. A run
    ///         therefore only happens at a deviation larger than that loss. This way a permissionless caller cannot
    ///         make a wallet trade repeatedly on small price moves without the allocation actually
    ///         improving, and a full correction is done in one run: the residual deviation from fee and slippage
    ///         (≤ 1.25% of the run amount) falls within the band (calculation audit 2026-09-15, I-01).
    uint16 public constant MIN_BAND_BPS = 125;
    uint16 public constant MIN_TARGET_BPS = 500;
    uint16 public constant MAX_TARGET_BPS = 9500;
    uint32 public constant MIN_INTERVAL = 1 hours;
    uint256 public constant GRACE_PERIOD = 1 hours;
    /// @notice Both feeds must have this number of decimals; the conversion in `_quote` divides them by each other.
    uint8 public constant FEED_DECIMALS = 8;
    uint256 public constant MAX_AGE_CBBTC = 1200 + 300; // heartbeat 20 min + margin
    /// @notice EURC/USD feed 0x9867…01e0 on Base: heartbeat 1 hour, deviation 0.1%; same 25% margin as cbBTC.
    uint256 public constant MAX_AGE_EURC = 3600 + 900;
    uint256 public constant BPS = 10_000;
    uint256 private constant WAD = 1e18;
    uint256 private constant EURC_UNIT = 1e6;
    uint256 private constant CBBTC_UNIT = 1e8;
    /// @dev Decimals that EURC_UNIT, CBBTC_UNIT, MIN_TRADE_FLOOR and KEEPER_REWARD_EURC rely on; USDC as the
    ///      intermediate hop with 6. The constructor enforces them (review I-4).
    uint8 private constant EURC_DECIMALS = 6;
    uint8 private constant CBBTC_DECIMALS = 8;
    uint8 private constant USDC_DECIMALS = 6;
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant Q128 = 1 << 128;

    // ─── Per user────────────────────────────────────────────────────────────────────────────────────────────

    struct Params {
        bool active;
        uint16 targetBps; // cbBTC share, 500–9500, multiple of 100
        uint16 bandBps; // MIN_BAND_BPS–9999
        uint16 maxCorrectionBps; // MIN_CORRECTION_BPS–10000, share of the total value per run
        uint64 minTradeEurc; // EURC base units, >= MIN_TRADE_FLOOR
        uint32 interval; // minimum time between runs, >= MIN_INTERVAL
        uint16 maxSlippageBps; // MIN_SLIPPAGE_BPS–MAX_SLIPPAGE_BPS
    }

    /// @notice An ongoing rebalance round: the previous run was capped by liquidity and the correction is not
    ///         done yet. `remainingEurc` is what is left of the round's budget; 0 = no round.
    struct Round {
        bool isBuy;
        uint128 remainingEurc;
    }

    mapping(address owner => Params) public params;
    /// @notice Timestamp of the last run, including a chunk. A new round can only start `interval` after it.
    mapping(address owner => uint64) public lastExecutedAt;
    /// @notice Ongoing round per owner. A chunk may follow CHUNK_INTERVAL after the previous run, only in the
    ///         `isBuy` direction and up to `remainingEurc`. `setParams` aborts the round.
    mapping(address owner => Round) public rounds;
    address[] private _owners;
    mapping(address owner => bool) private _isRegistered;
    /// @notice True once the treasury has called `retire`. Irreversible: after that `execute` does nothing anymore,
    ///         `isDue`/`dueOwners` return nothing and `setParams` can only revoke a mandate
    ///         (`active = false`). `sweep` keeps working.
    bool public retired;

    // ─── Events and errors───────────────────────────────────────────────────────────────────────────────────

    event ParamsUpdated(address indexed owner, Params params);
    /// @notice The contract has been permanently decommissioned by the treasury.
    event Retired();
    event Executed(
        address indexed owner,
        bool isBuy,
        uint256 amountIn,
        uint256 fee,
        uint256 reward,
        address rewardTo,
        uint256 amountOut,
        uint256 priceEurcPerBtc,
        uint256 totalValueEurc,
        uint256 fractionBps
    );
    /// @notice The fee transfer to the treasury failed; `amount` EURC stays in the contract and can be swept.
    event FeeRetained(uint256 amount);

    error InvalidParams();
    error Inactive();
    error NotDue();
    error SequencerDown();
    error StaleFeed(address feed);
    error InvalidFeedAnswer(address feed);
    error NothingToDo();
    error ZeroAddress();
    error NotAContract(address account);
    error UnexpectedPoolTokens(address pool);
    /// @notice The pool does not have the fee tier POOL_FEE that the swap goes through.
    error UnexpectedPoolFee(address pool);
    /// @notice The pool does not have the tickSpacing TICK_SPACING that the run size calculation relies on.
    error UnexpectedTickSpacing(address pool);
    /// @notice The pool is not the POOL_FEE pool of the router's factory, and therefore not the pool of the swap.
    error PoolNotFromRouterFactory(address pool);
    error SpotDeviatesFromOracle(uint256 spot, uint256 oracle);
    /// @notice After the swap the price of `pool` lies further than MAX_BLOCK_MOVE_BPS from the price at the start of
    ///         this block, or there is too little room or liquidity for a run of MIN_TRADE_FLOOR. Temporary: retry
    ///         in a later block.
    error BlockMoveExceeded(address pool);
    /// @notice `pool` already wrote an oracle observation in this block (tick change by a swap, or a mint or burn in
    ///         the range), before this run. Temporary: retry in a later block.
    error PoolTouchedThisBlock(address pool);
    error UnexpectedFeedDecimals(address feed);
    /// @notice `token` does not have the decimals the contract relies on (EURC 6, cbBTC 8, USDC 6).
    error UnexpectedTokenDecimals(address token);
    /// @notice MAX_BLOCK_MOVE_BPS does not fit well within TICK_SPACING; `_maxInput` would then miss boundaries.
    error WindowExceedsTickSpacing();
    error NoOutput();
    /// @notice The contract has been decommissioned; only `setParams` with `active = false` and `sweep` still work.
    error ContractRetired();
    error AlreadyRetired();
    error NotTreasury(address caller);

    // ─── Constructor ────────────────────────────────────────────────────────────────────────────────────────

    struct Deployment {
        address eurc;
        address cbbtc;
        address usdc;
        address router;
        address feedCbbtcUsd;
        address feedEurcUsd;
        address sequencerFeed;
        address poolEurcUsdc;
        address poolUsdcCbbtc;
        address treasury;
    }

    constructor(Deployment memory d) {
        if (d.treasury == address(0)) revert ZeroAddress();
        _requireContract(d.eurc);
        _requireContract(d.cbbtc);
        _requireContract(d.usdc);
        _requireContract(d.router);
        _requireContract(d.feedCbbtcUsd);
        _requireContract(d.feedEurcUsd);
        _requireContract(d.sequencerFeed);
        _requireContract(d.poolEurcUsdc);
        _requireContract(d.poolUsdcCbbtc);

        EURC = IERC20(d.eurc);
        CBBTC = IERC20(d.cbbtc);
        USDC = d.usdc;
        ROUTER = IV3SwapRouter(d.router);
        FEED_CBBTC_USD = IAggregatorV3(d.feedCbbtcUsd);
        FEED_EURC_USD = IAggregatorV3(d.feedEurcUsd);
        SEQUENCER_FEED = IAggregatorV3(d.sequencerFeed);
        POOL_EURC_USDC = IUniswapV3Pool(d.poolEurcUsdc);
        POOL_USDC_CBBTC = IUniswapV3Pool(d.poolUsdcCbbtc);
        TREASURY = d.treasury;

        _eurcIsToken0 = _poolOrder(POOL_EURC_USDC, d.eurc, d.usdc);
        _usdcIsToken0 = _poolOrder(POOL_USDC_CBBTC, d.usdc, d.cbbtc);
        // The spot check must monitor the pools the swap actually goes through (audit lead 1): the POOL_FEE pools
        // of the same factory as the router.
        address factory = ROUTER.factory();
        _requireContract(factory);
        _requireSwapPool(IUniswapV3Factory(factory), POOL_EURC_USDC, d.eurc, d.usdc);
        _requireSwapPool(IUniswapV3Factory(factory), POOL_USDC_CBBTC, d.usdc, d.cbbtc);

        // `_quote` divides the two feeds by each other; that is only correct if both have the same decimals.
        if (FEED_CBBTC_USD.decimals() != FEED_DECIMALS) revert UnexpectedFeedDecimals(d.feedCbbtcUsd);
        if (FEED_EURC_USD.decimals() != FEED_DECIMALS) revert UnexpectedFeedDecimals(d.feedEurcUsd);

        // The units and lower bounds above are fixed numbers in base units; a token with different decimals
        // (for example swapped addresses) would miscalculate every run by a factor of 100 or more (review I-4).
        // USDC is in the swap path; the conversion via the pool does not depend on its decimals, but a different
        // token in that position is a deployment error.
        _requireDecimals(d.eurc, EURC_DECIMALS);
        _requireDecimals(d.cbbtc, CBBTC_DECIMALS);
        _requireDecimals(d.usdc, USDC_DECIMALS);

        // `_maxInput` looks at no more than one initializable tick boundary in the window; that is only correct as
        // long as the window (1 tick ≈ 1 bp) spans fewer ticks than TICK_SPACING (self-audit 2026-09-17, lead 13).
        if (!_windowFitsTickSpacing(MAX_BLOCK_MOVE_BPS, TICK_SPACING)) revert WindowExceedsTickSpacing();
    }

    /// @dev Per direction, a swap within the window crosses at most `moveBps` consecutive ticks (down t through
    ///      t − moveBps + 1, up t + 1 through t + moveBps − 1). Fewer than `spacing` consecutive ticks
    ///      contain at most one multiple of `spacing`.
    function _windowFitsTickSpacing(uint16 moveBps, int24 spacing) internal pure returns (bool) {
        return spacing > 0 && int256(uint256(moveBps)) < int256(spacing);
    }

    function _requireDecimals(address token, uint8 expected) private view {
        if (IERC20Metadata(token).decimals() != expected) revert UnexpectedTokenDecimals(token);
    }

    function _requireContract(address account) private view {
        if (account == address(0)) revert ZeroAddress();
        if (account.code.length == 0) revert NotAContract(account);
    }

    /// @return aIsToken0 True if `a` is token0 of the pool; reverts if the pool does not contain exactly {a, b}.
    function _poolOrder(IUniswapV3Pool pool, address a, address b) private view returns (bool aIsToken0) {
        address token0 = pool.token0();
        address token1 = pool.token1();
        if (token0 == a && token1 == b) return true;
        if (token0 == b && token1 == a) return false;
        revert UnexpectedPoolTokens(address(pool));
    }

    /// @dev Reverts if `pool` is not the POOL_FEE pool of {a, b} from `factory`.
    function _requireSwapPool(IUniswapV3Factory factory, IUniswapV3Pool pool, address a, address b) private view {
        if (pool.fee() != POOL_FEE) revert UnexpectedPoolFee(address(pool));
        if (pool.tickSpacing() != TICK_SPACING) revert UnexpectedTickSpacing(address(pool));
        if (factory.getPool(a, b, POOL_FEE) != address(pool)) revert PoolNotFromRouterFactory(address(pool));
    }

    // ─── User────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Sets or changes the caller's own settings. Only msg.sender can change its own settings.
    /// @dev Economic lower bounds: `minTradeEurc >= MIN_TRADE_FLOOR`, `maxCorrectionBps >= MIN_CORRECTION_BPS` and
    ///      `bandBps >= MIN_BAND_BPS`.
    ///      After `retire` only `active = false` is still allowed (revoking the mandate); setting an active mandate
    ///      then reverts with `ContractRetired`. Aborts an ongoing round: the next run is again a new
    ///      round, `interval` after the last run.
    ///      Not atomic (audit lead 7): whoever sees this transaction (or an `approve(0)`) before it is in a Flashblock
    ///      can put one `execute` on the old settings in front of it with a higher priority fee, within the
    ///      normal limits of a run. After that `interval` applies; whoever wants no further run for sure sends
    ///      `approve(0)` first. Registering requires no balance or allowance and the registry never shrinks (audit
    ///      lead 9). A balance requirement can be circumvented and would make "configure first, then deposit"
    ///      impossible; keepers therefore filter the registry off-chain on balance and allowance themselves.
    function setParams(Params calldata p) external {
        if (retired && p.active) revert ContractRetired();
        if (
            p.targetBps < MIN_TARGET_BPS || p.targetBps > MAX_TARGET_BPS || p.targetBps % 100 != 0
                || p.bandBps < MIN_BAND_BPS || p.bandBps >= BPS || p.maxCorrectionBps < MIN_CORRECTION_BPS
                || p.maxCorrectionBps > BPS || p.minTradeEurc < MIN_TRADE_FLOOR || p.interval < MIN_INTERVAL
                || p.maxSlippageBps < MIN_SLIPPAGE_BPS || p.maxSlippageBps > MAX_SLIPPAGE_BPS
        ) {
            revert InvalidParams();
        }
        params[msg.sender] = p;
        delete rounds[msg.sender];
        if (!_isRegistered[msg.sender]) {
            _isRegistered[msg.sender] = true;
            _owners.push(msg.sender);
        }
        emit ParamsUpdated(msg.sender, p);
    }

    // ─── Reading─────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Page from the list of addresses that have ever set settings (including inactive ones). Never reverts,
    ///         not even with `limit = type(uint256).max`.
    function owners(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 total = _owners.length;
        if (offset >= total) {
            return new address[](0);
        }
        // Not `offset + limit`: that overflows with a large `limit` (audit L-A).
        uint256 end = limit > total - offset ? total : offset + limit;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _owners[i];
        }
    }

    function ownerCount() external view returns (uint256) {
        return _owners.length;
    }

    /// @notice Would `execute(owner, …)` do something now? `eurcDelta` > 0 = buy for that amount, < 0 = sell.
    ///         The amount is what `execute` would actually trade now, so already capped by balance and allowance:
    ///         for a buy the EURC input amount, for a sell the cbBTC input at the oracle price (audit L-C).
    ///         During a round this is the next chunk, so at most what currently fits in the block window.
    /// @dev Never reverts: a failure in the feeds or sequencer, too large a spot deviation, a pool that already wrote
    ///      an observation in this block, or too little room in the block window gives (false, 0). After `retire`
    ///      always (false, 0).
    function isDue(address owner) external view returns (bool due, int256 eurcDelta) {
        Params memory p = params[owner];
        if (retired || !p.active) {
            return (false, 0);
        }
        (bool timeDue, bool chunk) = _timing(owner, p);
        if (!timeDue) {
            return (false, 0);
        }
        (bool ok, uint256 price) = _tryQuote();
        if (!ok) {
            return (false, 0);
        }
        (address touched, Window memory w1, Window memory w2) = _windows();
        if (touched != address(0)) {
            return (false, 0);
        }
        RunCaps memory caps;
        return _dueAt(owner, p, price, chunk, w1, w2, caps);
    }

    /// @notice Page from the owner list, filtered on who is due now (same rules as `isDue`). Never reverts.
    /// @dev An owner that structurally reverts (blacklist, slippage too tight) stays in the list; the
    ///      contract does not remember failed attempts. The keepers therefore simulate first and keep their own
    ///      cool-down per owner. After `retire` always an empty list. All owners in the list share the same
    ///      block window: after one run in this block there is usually no room left for the rest (a run that
    ///      changes the tick touches the pool). If a pool already has an observation in this block, the list is empty.
    ///      Price, block windows and the run size per direction are read once per page (review I-2); a
    ///      page of 50 due owners costs a measured ~1.24 million gas.
    function dueOwners(uint256 offset, uint256 limit) external view returns (address[] memory due) {
        uint256 total = _owners.length;
        if (retired || offset >= total) {
            return new address[](0);
        }
        (bool ok, uint256 price) = _tryQuote();
        if (!ok) {
            return new address[](0);
        }
        (address touched, Window memory w1, Window memory w2) = _windows();
        if (touched != address(0)) {
            return new address[](0);
        }
        // Not `offset + limit`: that overflows with a large `limit` (audit L-A).
        uint256 end = limit > total - offset ? total : offset + limit;
        address[] memory candidates = new address[](end - offset);
        uint256 n;
        // One cache for the whole page: the run size per direction does not depend on the owner (review I-2).
        RunCaps memory caps;
        for (uint256 i = offset; i < end; i++) {
            address owner = _owners[i];
            Params memory p = params[owner];
            if (!p.active) {
                continue;
            }
            (bool timeDue, bool chunk) = _timing(owner, p);
            if (!timeDue) {
                continue;
            }
            (bool isDueNow,) = _dueAt(owner, p, price, chunk, w1, w2, caps);
            if (isDueNow) {
                candidates[n++] = owner;
            }
        }
        due = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            due[i] = candidates[i];
        }
    }

    function _dueAt(
        address owner,
        Params memory p,
        uint256 price,
        bool chunk,
        Window memory w1,
        Window memory w2,
        RunCaps memory caps
    ) internal view returns (bool due, int256 eurcDelta) {
        Plan memory pl = _plan(owner, p, price, chunk, w1, w2, caps);
        if (pl.amountIn == 0) {
            return (false, 0);
        }
        // From `amountIn`, not from the correction before capping: otherwise isDue reports a larger run than execute.
        uint256 eurcAmount = pl.isBuy ? pl.amountIn : Math.mulDiv(pl.amountIn, price, CBBTC_UNIT);
        eurcDelta = pl.isBuy ? int256(eurcAmount) : -int256(eurcAmount);
        return (true, eurcDelta);
    }

    /// @return timeDue Does the clock allow a run now?
    /// @return chunk   True if that is only allowed as a chunk of the ongoing round (CHUNK_INTERVAL after the previous
    ///                 run); false if `interval` has elapsed and this is a new round. A new round takes precedence.
    function _timing(address owner, Params memory p) internal view returns (bool timeDue, bool chunk) {
        uint256 last = lastExecutedAt[owner];
        if (block.timestamp >= last + p.interval) {
            return (true, false);
        }
        return (rounds[owner].remainingEurc > 0 && block.timestamp >= last + CHUNK_INTERVAL, true);
    }

    // ─── Execution───────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Performs one rebalance step for `owner`. Anyone may call this.
    /// @param rewardTo Recipient of the reward from the fee; address(0) = entire fee to the treasury.
    /// @dev Reverts with `ContractRetired` once the treasury has called `retire`, before the swap with
    ///      `PoolTouchedThisBlock` if a pool already wrote an observation in this block, with `BlockMoveExceeded` if
    ///      there is too little room or liquidity or the price after the swap lies outside the window.
    function execute(address owner, address rewardTo) external nonReentrant {
        if (retired) revert ContractRetired();
        Params memory p = params[owner];
        if (!p.active) revert Inactive();
        (bool timeDue, bool chunk) = _timing(owner, p);
        if (!timeDue) revert NotDue();
        // A reward to the contract itself would get stuck; in that case the entire fee goes to the treasury instead.
        if (rewardTo == address(this)) rewardTo = address(0);

        // Block check first: a push in this block that would also hit the spot check is thus reported as temporary.
        (address touched, Window memory w1, Window memory w2) = _windows();
        if (touched != address(0)) revert PoolTouchedThisBlock(touched);
        uint256 price = _quoteChecked();
        RunCaps memory caps;
        Plan memory pl = _plan(owner, p, price, chunk, w1, w2, caps);
        if (pl.blockedBy != address(0)) revert BlockMoveExceeded(pl.blockedBy);
        if (pl.amountIn == 0) revert NothingToDo();

        // From here on the run is recorded, even if the swap were still to revert (then everything reverts).
        lastExecutedAt[owner] = uint64(block.timestamp);
        if (pl.roundLeftEurc > 0) {
            rounds[owner] = Round({isBuy: pl.isBuy, remainingEurc: uint128(pl.roundLeftEurc)});
        } else {
            delete rounds[owner];
        }

        uint256 fee;
        uint256 reward;
        uint256 amountOut;
        if (pl.isBuy) {
            (fee, reward, amountOut) = _buy(owner, p, pl.amountIn, price, rewardTo);
        } else {
            (fee, reward, amountOut) = _sell(owner, p, pl.amountIn, price, rewardTo);
        }
        // Block window after the swap: prior push plus own impact together within MAX_BLOCK_MOVE_BPS.
        _requireWithinWindow(POOL_EURC_USDC, w1);
        _requireWithinWindow(POOL_USDC_CBBTC, w2);

        emit Executed(owner, pl.isBuy, pl.amountIn, fee, reward, rewardTo, amountOut, price, pl.total, pl.fractionBps);
    }

    /// @notice Sends the full balance of `token` in this contract to the treasury. Anyone may call
    ///         this; outside a transaction the contract should hold no balance, except fee left behind by a
    ///         failed treasury transfer (`FeeRetained`).
    function sweep(IERC20 token) external nonReentrant {
        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) token.safeTransfer(TREASURY, balance);
    }

    /// @notice Decommissions the contract once and irreversibly. Only the treasury may do this.
    /// @dev This is the treasury's only power and the only flag that can change the contract's
    ///      behaviour; there is no way back and no counterpart (`unretire`). After `retire`:
    ///      - `execute` reverts with `ContractRetired`, so no swap or fee is ever recorded again;
    ///      - `isDue` returns (false, 0) and `dueOwners` an empty list, so keepers stop by themselves;
    ///      - `setParams` only accepts `active = false`, so that users can revoke their mandate;
    ///      - `sweep` keeps working to send left-behind fee to the treasury.
    ///
    ///      This remains non-custodial: the contract never holds user funds. The mandate is an ERC-20
    ///      allowance that sits with the user in the token contracts; `retire` changes nothing there and cannot
    ///      do anything with it. The only path that ever used that allowance (`execute`) is closed after `retire`,
    ///      so the treasury cannot move funds with this switch, only stop the contract. The user
    ///      keeps control: `approve(0)` on EURC/cbBTC and/or `setParams` with `active = false`.
    function retire() external {
        if (msg.sender != TREASURY) revert NotTreasury(msg.sender);
        if (retired) revert AlreadyRetired();
        retired = true;
        emit Retired();
    }

    // ─── Internal: price─────────────────────────────────────────────────────────────────────────────────────

    /// @return price EURC base units (6 dec) per 1 cbBTC.
    function _quote() internal view returns (uint256 price) {
        (, int256 seqAnswer, uint256 seqStartedAt,,) = SEQUENCER_FEED.latestRoundData();
        // startedAt == 0 is an uninitialized round of the uptime feed and counts as "unknown", not as up.
        // A startedAt in the future as well: SequencerDown instead of a Panic (self-audit 2026-09-17, Info-G).
        if (
            seqAnswer != 0 || seqStartedAt == 0 || seqStartedAt > block.timestamp
                || block.timestamp - seqStartedAt < GRACE_PERIOD
        ) {
            revert SequencerDown();
        }

        uint256 cbbtcUsd = _readFeed(FEED_CBBTC_USD, MAX_AGE_CBBTC);
        uint256 eurcUsd = _readFeed(FEED_EURC_USD, MAX_AGE_EURC);
        price = Math.mulDiv(cbbtcUsd, EURC_UNIT, eurcUsd);
        if (price == 0) revert InvalidFeedAnswer(address(FEED_CBBTC_USD));
    }

    /// @dev Oracle price, rejected if the pool spot deviates from it by more than MAX_SPOT_DEVIATION_BPS.
    function _quoteChecked() internal view returns (uint256 price) {
        price = _quote();
        _requireSpotNear(price);
    }

    /// @dev Reverts if the current pool spot deviates from `price` by more than MAX_SPOT_DEVIATION_BPS. Called
    ///      before the swap (via `_quoteChecked`) and after the swap, so that a prior push and the own price impact
    ///      together must stay within the tolerance.
    function _requireSpotNear(uint256 price) internal view {
        uint256 spotPrice = _spot();
        uint256 diff = spotPrice > price ? spotPrice - price : price - spotPrice;
        if (diff * BPS > price * MAX_SPOT_DEVIATION_BPS) revert SpotDeviatesFromOracle(spotPrice, price);
    }

    /// @return price EURC base units (6 dec) per 1 cbBTC according to the current spot of both pools (mid price,
    ///               without pool fees).
    function _spot() internal view returns (uint256 price) {
        uint256 usdcPerBtc = _spotOut(POOL_USDC_CBBTC, !_usdcIsToken0, CBBTC_UNIT);
        price = _spotOut(POOL_EURC_USDC, !_eurcIsToken0, usdcPerBtc);
    }

    /// @dev How many base units of the other token `amountIn` base units are worth at the spot of
    ///      `pool`. `inIsToken0` says whether the input token is token0. Calculates via ratioX128 = sqrtPriceX96² /
    ///      2^64 (fits in uint256 for every uint160 sqrtPriceX96), like Uniswap's OracleLibrary.getQuoteAtTick for
    ///      large prices. Not via ratioX96 = sqrtPriceX96² / 2^96: that is 0 for sqrtPriceX96 < 2^48 and
    ///      dividing by it then caused a Panic (audit lead 10). ratioX128 is ≥ 1 for every sqrtPriceX96 ≥ 2^32, so
    ///      for every valid Uniswap price (MIN_SQRT_RATIO = 4295128739 > 2^32).
    function _spotOut(IUniswapV3Pool pool, bool inIsToken0, uint256 amountIn) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        return _convert(sqrtPriceX96, inIsToken0, amountIn);
    }

    /// @dev See `_spotOut`, with a given sqrtPriceX96.
    function _convert(uint160 sqrtPriceX96, bool inIsToken0, uint256 amountIn) internal pure returns (uint256) {
        uint256 ratioX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, Q64);
        return inIsToken0 ? Math.mulDiv(amountIn, ratioX128, Q128) : Math.mulDiv(amountIn, Q128, ratioX128);
    }

    // ─── Internal: block window──────────────────────────────────────────────────────────────────────────────

    /// @dev The allowed sqrtPriceX96 of a pool in this block, plus the state against which the run is measured.
    struct Window {
        uint160 lower;
        uint160 upper;
        uint160 sqrtPriceX96;
        uint128 liquidity;
        int24 tick;
    }

    /// @return touched address(0), or the first pool that already wrote an observation in this block.
    function _windows() internal view returns (address touched, Window memory w1, Window memory w2) {
        bool t;
        (t, w1) = _window(POOL_EURC_USDC);
        if (t) return (address(POOL_EURC_USDC), w1, w2);
        (t, w2) = _window(POOL_USDC_CBBTC);
        if (t) return (address(POOL_USDC_CBBTC), w1, w2);
    }

    /// @dev Block check and window [lower, upper] for sqrtPriceX96 of `pool` in this block. Does not revert.
    ///
    ///      Block check. `touched = true` if the pool already wrote an observation in this block; the window is then
    ///      empty and is not used. Which actions write is listed at the top of the contract. Oracle.write sets
    ///      `observationIndex` to the new observation (also with cardinality 1, where it overwrites index 0), so
    ///      `observations(observationIndex)` is always the latest.
    ///
    ///      Start tick. Without an observation in this block the tick has not changed since the start of the block
    ///      (every tick change writes, and the first write of a block always goes through): start tick = slot0.tick.
    ///      A derivation from two observations is therefore not needed. That stays so until after the swap: the
    ///      window is calculated before the swap and held against the new price after the swap.
    ///
    ///      Rounding. The actual starting price lies somewhere in [P(t), P(t+1)] (sqrtPriceX96 at tick t and t+1),
    ///      because a swap within the tick moves the price without an observation. The lower bound is calculated from
    ///      P(t+1) and the upper bound from P(t), so that the allowed move from the actual starting price in both
    ///      directions is at most MAX_BLOCK_MOVE_BPS. The rounding of TickMath, the square root and mulDiv always goes
    ///      towards a narrower window.
    function _window(IUniswapV3Pool pool) internal view returns (bool touched, Window memory w) {
        (uint160 sqrtPriceX96, int24 tick, uint16 index,,,,) = pool.slot0();
        (uint32 lastTimestamp,,,) = pool.observations(index);
        if (lastTimestamp == uint32(block.timestamp)) return (true, w);
        w.sqrtPriceX96 = sqrtPriceX96;
        w.liquidity = pool.liquidity();
        w.tick = tick;
        // A real pool always has MIN_TICK <= tick < MAX_TICK (the swap rejects MIN/MAX_SQRT_RATIO as limit).
        // Otherwise an empty window: no run (BlockMoveExceeded), and no revert in TickMath.
        if (tick < TickMath.MIN_TICK || tick >= TickMath.MAX_TICK) {
            w.lower = type(uint160).max;
            return (false, w);
        }
        uint256 down =
            Math.sqrt(Math.mulDiv(BPS - MAX_BLOCK_MOVE_BPS, Q96 * Q96, BPS, Math.Rounding.Ceil), Math.Rounding.Ceil);
        uint256 up = Math.sqrt(Math.mulDiv(BPS + MAX_BLOCK_MOVE_BPS, Q96 * Q96, BPS));
        // TickMath rounds up; for the upper bound therefore subtract 1, so that P(t) is never too high. Just below
        // MAX_TICK, P(t) × √(1 + 6 bp) no longer fits in uint160; then the largest sqrtPriceX96 applies as bound.
        w.lower = uint160(Math.mulDiv(TickMath.getSqrtPriceAtTick(tick + 1), down, Q96, Math.Rounding.Ceil));
        w.upper = uint160(Math.min(Math.mulDiv(TickMath.getSqrtPriceAtTick(tick) - 1, up, Q96), type(uint160).max));
    }

    /// @dev Reverts with `BlockMoveExceeded` if the current price of `pool` lies outside the window.
    function _requireWithinWindow(IUniswapV3Pool pool, Window memory w) internal view {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        if (sqrtPriceX96 < w.lower || sqrtPriceX96 > w.upper) revert BlockMoveExceeded(address(pool));
    }

    /// @dev Result of `_maxRunEurc` per direction, remembered within one call. Empty = not yet calculated.
    struct RunCaps {
        bool buyKnown;
        bool sellKnown;
        uint256 buyEurc;
        uint256 sellEurc;
        address buyBinding;
        address sellBinding;
    }

    /// @dev `_maxRunEurc` with `caps` as cache (review I-2). The result depends only on the direction, `price`, the
    ///      windows and the pool and tick state of this block, and none of that depends on the owner or changes
    ///      within a view call. `dueOwners` shares one cache across the page and so reads the ticks at most once per
    ///      direction; `isDue` and `execute` pass an empty cache and calculate exactly as without a cache.
    function _maxRunCached(bool isBuy, uint256 price, Window memory w1, Window memory w2, RunCaps memory caps)
        internal
        view
        returns (uint256 eurc, address binding)
    {
        if (isBuy) {
            if (!caps.buyKnown) {
                (caps.buyEurc, caps.buyBinding) = _maxRunEurc(true, price, w1, w2);
                caps.buyKnown = true;
            }
            return (caps.buyEurc, caps.buyBinding);
        }
        if (!caps.sellKnown) {
            (caps.sellEurc, caps.sellBinding) = _maxRunEurc(false, price, w1, w2);
            caps.sellKnown = true;
        }
        return (caps.sellEurc, caps.sellBinding);
    }

    /// @return eurc    Largest run in EURC for which the estimated final price in both pools stays within SIZING_BPS
    ///                 of the remaining room up to the window edge. 0 if a pool already lies outside its window or
    ///                 has no liquidity beyond the tick boundary in the window.
    /// @return binding The pool that determines the bound.
    function _maxRunEurc(bool isBuy, uint256 price, Window memory w1, Window memory w2)
        internal
        view
        returns (uint256 eurc, address binding)
    {
        // Hop EURC/USDC: for a buy EURC goes in, for a sell USDC. Both converted to EURC via this pool.
        uint256 in1 = _maxInput(POOL_EURC_USDC, w1, isBuy == _eurcIsToken0);
        uint256 eurc1 = isBuy ? in1 : _convert(w1.sqrtPriceX96, !_eurcIsToken0, in1);
        // Hop USDC/cbBTC: for a buy USDC goes in (converted via EURC/USDC), for a sell cbBTC (via the oracle).
        uint256 in2 = _maxInput(POOL_USDC_CBBTC, w2, isBuy == _usdcIsToken0);
        uint256 eurc2 = isBuy ? _convert(w1.sqrtPriceX96, !_eurcIsToken0, in2) : Math.mulDiv(in2, price, CBBTC_UNIT);
        return eurc1 <= eurc2 ? (eurc1, address(POOL_EURC_USDC)) : (eurc2, address(POOL_USDC_CBBTC));
    }

    /// @dev Input amount that moves the price SIZING_BPS of the way to the window edge in the swap direction
    ///      (Uniswap formulas for amount0/amount1 between two sqrtPrices, without pool fee: the fee does not move the
    ///      price, so this is on the cautious side). A pool outside its window gives 0. Capped at 2^96
    ///      base units, so that the conversion to EURC never overflows.
    ///
    ///      Liquidity (review L-1). The calculation uses the smallest liquidity up to the window edge: the in-range
    ///      liquidity now, and beyond the next initializable tick boundary in the swap direction the liquidity
    ///      after crossing (± `liquidityNet` of that tick). Downwards that is floor(tick / TICK_SPACING) ×
    ///      TICK_SPACING, also when the price sits exactly on it (UniswapV3Pool.swap then crosses that tick
    ///      immediately); upwards the boundary above it. With start tick t (1 tick ≈ 1 bp) a swap within the window
    ///      can cross at most the boundaries t through t − 5 downwards and t + 1 through t + 5 upwards. Per direction
    ///      those are fewer than TICK_SPACING consecutive ticks, so at most one multiple of TICK_SPACING, and no
    ///      `tickBitmap` lookup is needed: an uninitialized tick has `liquidityNet` 0. Larger liquidity beyond the
    ///      boundary never makes the run larger; if 0, no run. A boundary exactly on the window edge counts (cautious).
    function _maxInput(IUniswapV3Pool pool, Window memory w, bool zeroForOne) internal view returns (uint256 amount) {
        if (w.sqrtPriceX96 < w.lower || w.sqrtPriceX96 > w.upper) return 0;
        uint256 liquidity = w.liquidity;
        int24 boundary = w.tick / TICK_SPACING;
        if (w.tick < 0 && w.tick % TICK_SPACING != 0) boundary--;
        boundary = boundary * TICK_SPACING + (zeroForOne ? int24(0) : TICK_SPACING);
        if (boundary >= TickMath.MIN_TICK && boundary <= TickMath.MAX_TICK) {
            uint160 atBoundary = TickMath.getSqrtPriceAtTick(boundary);
            if (zeroForOne ? atBoundary >= w.lower : atBoundary <= w.upper) {
                (, int128 net,,,,,,) = pool.ticks(boundary);
                // Crossing downwards subtracts `liquidityNet`, crossing upwards adds it (UniswapV3Pool.swap).
                int256 beyond = zeroForOne ? int256(liquidity) - net : int256(liquidity) + net;
                if (beyond <= 0) return 0;
                liquidity = Math.min(liquidity, uint256(beyond));
            }
        }
        if (zeroForOne) {
            // token0 in: price down to `lower`. amount0 = L × 2^96 × (√P − √lower) / (√P × √lower).
            amount = Math.mulDiv(liquidity << 96, w.sqrtPriceX96 - w.lower, w.sqrtPriceX96) / w.lower;
        } else {
            // token1 in: price up to `upper`. amount1 = L × (√upper − √P) / 2^96.
            amount = Math.mulDiv(liquidity, w.upper - w.sqrtPriceX96, Q96);
        }
        amount = Math.min(amount, type(uint96).max) * SIZING_BPS / BPS;
    }

    /// @dev No absolute min/max on `answer` (audit lead 6): the aggregators themselves enforce no meaningful ones
    ///      (minAnswer 1, maxAnswer 2^176 − 1), and a fixed bound would permanently halt this immutable contract at a
    ///      real extreme price. The price is held against both pools before and after every swap (`_requireSpotNear`);
    ///      a faulty feed only produces a trade if the pools sit at the same faulty price.
    function _readFeed(IAggregatorV3 feed, uint256 maxAge) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidFeedAnswer(address(feed));
        // An updatedAt in the future is just as unusable as one that is too old; both give StaleFeed, not a Panic.
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) revert StaleFeed(address(feed));
        // answer > 0 is enforced above, so the cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(answer);
    }

    function _tryQuote() internal view returns (bool ok, uint256 price) {
        try this.quoteChecked() returns (uint256 p) {
            return (true, p);
        } catch {
            return (false, 0);
        }
    }

    /// @notice Current price according to the feeds (EURC base units per cbBTC). Reverts on failure.
    function quote() external view returns (uint256) {
        return _quote();
    }

    /// @notice Current price according to the feeds, with all the checks of `execute`: also reverts if the pool spot
    ///         deviates too far from the feeds.
    function quoteChecked() external view returns (uint256) {
        return _quoteChecked();
    }

    /// @notice Spot price of the two Uniswap pools (EURC base units per cbBTC, mid price without fees).
    function spot() external view returns (uint256) {
        return _spot();
    }

    // ─── Internal: calculation rule──────────────────────────────────────────────────────────────────────────

    /// @dev Result of `_plan`.
    struct Plan {
        bool isBuy; // direction
        uint256 amountIn; // in the input token, already capped by balance, allowance and block window; 0 = do nothing
        uint256 total; // total value in EURC
        uint256 fractionBps; // current cbBTC share in bps
        uint256 roundLeftEurc; // > 0: the round continues with this budget (run was capped by liquidity)
        address blockedBy; // != 0: there is a correction, but it does not fit in this pool's block window right now
    }

    /**
     * @dev Calculation rule per run.
     *      1. Correction as in the app: |drift| × total, only outside the band.
     *      2. Budget: for a new round max(total × maxCorrectionBps, minTradeEurc); for a chunk what is left of the
     *         round, but never more than that budget of the current value (self-audit lead 11). The
     *         remainder is then calculated from that smaller budget and stays low, even if the value recovers later. A
     *         chunk in the opposite direction of the round does not happen (no ping-pong).
     *      3. correction = min(correction, budget); below minTradeEurc -> nothing (also: the round is done).
     *      4. run = min(correction, `_maxRunEurc`). Below MIN_TRADE_FLOOR -> `blockedBy`: the correction waits for
     *         room in a later block; an ongoing round stays open until there is room again or `interval` after the
     *         last run elapses, after which a new round starts. A chunk between MIN_TRADE_FLOOR and
     *         minTradeEurc is allowed: minTradeEurc applies to the correction, the floor to every run.
     *      5. Cap by balance and allowance. If that would bring the run below min(run, minTradeEurc) -> nothing.
     *      6. If liquidity was the limit (run < correction) and not balance or allowance, the round continues with
     *         budget − traded value, provided that remainder is still at least minTradeEurc.
     */
    function _plan(
        address owner,
        Params memory p,
        uint256 price,
        bool chunk,
        Window memory w1,
        Window memory w2,
        RunCaps memory caps
    ) internal view returns (Plan memory pl) {
        uint256 cash = EURC.balanceOf(owner);
        uint256 btcBal = CBBTC.balanceOf(owner);
        uint256 position = Math.mulDiv(btcBal, price, CBBTC_UNIT);
        pl.total = cash + position;
        if (pl.total == 0) {
            return pl;
        }

        uint256 fractionWad = Math.mulDiv(position, WAD, pl.total);
        uint256 targetWad = uint256(p.targetBps) * WAD / BPS;
        uint256 bandWad = uint256(p.bandBps) * WAD / BPS;
        pl.fractionBps = fractionWad * BPS / WAD;

        pl.isBuy = fractionWad < targetWad;
        uint256 driftWad = pl.isBuy ? targetWad - fractionWad : fractionWad - targetWad;
        if (driftWad <= bandWad) {
            return pl;
        }

        uint256 budget = Math.max(Math.mulDiv(pl.total, p.maxCorrectionBps, BPS), p.minTradeEurc);
        if (chunk) {
            Round memory rd = rounds[owner];
            if (rd.isBuy != pl.isBuy) return pl;
            // Never more than the budget of the current value: if the wallet shrinks during the round (withdrawal
            // or a price drop), the budget shrinks with it (self-audit 2026-09-17, lead 11).
            budget = Math.min(rd.remainingEurc, budget);
        }
        uint256 correction = Math.min(Math.mulDiv(driftWad, pl.total, WAD), budget);
        if (correction < p.minTradeEurc) {
            return pl;
        }

        (uint256 maxRun, address binding) = _maxRunCached(pl.isBuy, price, w1, w2, caps);
        uint256 run = Math.min(correction, maxRun);
        if (run < MIN_TRADE_FLOOR) {
            pl.blockedBy = binding;
            return pl;
        }

        // The cap by balance is defensive: run <= |drift| * total <= balance of the input token, so in
        // practice only the allowance caps. Kept as a safety net against later changes.
        uint256 value;
        uint256 spent;
        if (pl.isBuy) {
            pl.amountIn = Math.min(run, Math.min(cash, EURC.allowance(owner, address(this))));
            value = pl.amountIn;
            spent = value;
        } else {
            // Rounded up: otherwise the back-calculated value of a run that sits exactly on the minTrade floor is
            // up to almost 1 sat too small and a small wallet could never sell.
            uint256 wantBtc = Math.mulDiv(run, CBBTC_UNIT, price, Math.Rounding.Ceil);
            pl.amountIn = Math.min(wantBtc, Math.min(btcBal, CBBTC.allowance(owner, address(this))));
            value = Math.mulDiv(pl.amountIn, price, CBBTC_UNIT);
            spent = Math.mulDiv(pl.amountIn, price, CBBTC_UNIT, Math.Rounding.Ceil);
        }
        if (value < Math.min(run, p.minTradeEurc)) {
            pl.amountIn = 0;
            return pl;
        }

        // Continue only if the deviation after this run still lies outside the band. That estimate ignores fee and
        // slippage and is therefore optimistic: with costs the owner is further from the target after the run. If the
        // estimate says "outside the band", that is indeed so; if it says "inside", the round ends and a small
        // remainder waits for the normal interval.
        uint256 driftEurc = Math.mulDiv(driftWad, pl.total, WAD);
        if (run < correction && value >= run && driftEurc > value + Math.mulDiv(bandWad, pl.total, WAD)) {
            uint256 left = budget > spent ? budget - spent : 0;
            if (left >= p.minTradeEurc) pl.roundLeftEurc = Math.min(left, type(uint128).max);
        }
    }

    // ─── Internal: swaps─────────────────────────────────────────────────────────────────────────────────────

    /// @dev Buy: fee on the gross amount, the rest into the pool, output directly to the owner. Reverts with
    ///      `NoOutput` if the router yields 0 cbBTC, and with `SpotDeviatesFromOracle` if the spot after the swap
    ///      lies too far from the oracle.
    function _buy(address owner, Params memory p, uint256 amountIn, uint256 price, address rewardTo)
        internal
        returns (uint256 fee, uint256 reward, uint256 amountOut)
    {
        EURC.safeTransferFrom(owner, address(this), amountIn);
        (fee, reward) = _takeFee(amountIn, amountIn, rewardTo);
        uint256 swapIn = amountIn - fee;

        uint256 expectedOut = Math.mulDiv(swapIn, CBBTC_UNIT, price);
        uint256 minOut = Math.mulDiv(expectedOut, BPS - p.maxSlippageBps, BPS);

        EURC.forceApprove(address(ROUTER), swapIn);
        amountOut = ROUTER.exactInput(
            IV3SwapRouter.ExactInputParams({
                path: abi.encodePacked(address(EURC), POOL_FEE, USDC, POOL_FEE, address(CBBTC)),
                recipient: owner,
                amountIn: swapIn,
                amountOutMinimum: minOut
            })
        );
        if (amountOut == 0) revert NoOutput();
        _requireSpotNear(price);
    }

    /// @dev Sell: output to the contract, fee on max(received, expectedOut), rest to the owner. The fee is
    ///      capped at the amount received. On `expectedOut` and not only on `received`, so that the fee of a run
    ///      at MIN_TRADE_FLOOR does not drop below KEEPER_REWARD_EURC after pool fees and slippage (audit L-B).
    ///      Reverts with `SpotDeviatesFromOracle` if the spot after the swap lies too far from the oracle.
    function _sell(address owner, Params memory p, uint256 amountIn, uint256 price, address rewardTo)
        internal
        returns (uint256 fee, uint256 reward, uint256 amountOut)
    {
        CBBTC.safeTransferFrom(owner, address(this), amountIn);

        uint256 expectedOut = Math.mulDiv(amountIn, price, CBBTC_UNIT);
        uint256 minOut = Math.mulDiv(expectedOut, BPS - p.maxSlippageBps, BPS);

        CBBTC.forceApprove(address(ROUTER), amountIn);
        uint256 eurcBefore = EURC.balanceOf(address(this));
        ROUTER.exactInput(
            IV3SwapRouter.ExactInputParams({
                path: abi.encodePacked(address(CBBTC), POOL_FEE, USDC, POOL_FEE, address(EURC)),
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minOut
            })
        );
        uint256 received = EURC.balanceOf(address(this)) - eurcBefore;
        _requireSpotNear(price);

        (fee, reward) = _takeFee(Math.max(received, expectedOut), received, rewardTo);
        amountOut = received - fee;
        EURC.safeTransfer(owner, amountOut);
    }

    /// @dev Fee in EURC: FEE_BPS on `feeBase`, capped at `maxFee` (the EURC amount the fee comes out of).
    ///      For a buy both are the gross input amount; for a sell `feeBase` is max(received,
    ///      expectedOut) and `maxFee` the amount received. Reward taken out of it to rewardTo, at most
    ///      min(KEEPER_REWARD_EURC, fee / 2), rest to the treasury. Half as the bound, so that a run at the floor
    ///      does not leave the treasury empty and an owner who sets `rewardTo` to themselves does not trade without
    ///      a fee (self-audit 2026-09-17, L-D).
    ///      Both transfers are non-reverting (`trySafeTransfer`), so that the run never breaks on the fee recipient:
    ///      - if the reward fails (e.g. a blacklisted rewardTo), `reward` is 0 and the entire fee goes to the
    ///        treasury;
    ///      - if the treasury transfer fails, that part stays in the contract (`FeeRetained`) and `sweep` collects
    ///        it later.
    ///      In both cases the fee is withheld in full from the owner; `reward + treasury + retained == fee`.
    function _takeFee(uint256 feeBase, uint256 maxFee, address rewardTo)
        internal
        returns (uint256 fee, uint256 reward)
    {
        fee = Math.min(Math.mulDiv(feeBase, FEE_BPS, BPS), maxFee);
        if (rewardTo != address(0)) {
            reward = Math.min(KEEPER_REWARD_EURC, fee / 2);
            if (reward > 0 && !EURC.trySafeTransfer(rewardTo, reward)) reward = 0;
        }
        uint256 toTreasury = fee - reward;
        if (toTreasury > 0 && !EURC.trySafeTransfer(TREASURY, toTreasury)) emit FeeRetained(toTreasury);
    }
}
