# Rebalancer – adversarial review: oracle and price manipulation

Scope: `src/Rebalancer.sol` (545 lines), `src/interfaces/*.sol`, `README.md`, `test/Rebalancer.t.sol`, `test/RebalancerFork.t.sol`, `script/Deploy.s.sol`. Live address on Base: `0xED47d549345b0dBB5A9b44E57Ff3AB4E6Ed0e6e5` (cre/bitburo-keeper/config.production.json:4). Fork PoCs: `scratchpad/poc-oracle/test/OracleSandwich.t.sol` (Base mainnet, block ~51,337,000, 15 September 2026). Repo was not changed.

Facts checked on-chain (cast against https://mainnet.base.org, 15-09-2026):

| Item | Value |
|---|---|
| cbBTC/USD `0x07DA…9f9D` | "cbBTC / USD", 8 dec, owner `0xf0Db…5B1b`, aggregator AccessControlledOCR2Aggregator; rounds every ~1,230 s; reference directory: heartbeat 1200 s, threshold 0.3 % |
| EURC/USD `0xDAe3…8250` (used by the contract) | "EURC / USD", 8 dec, same owner, phaseId 2; rounds every 86,418–86,422 s (24 h); price jumps between rounds of up to 0.35 % without an intermediate update; **does not appear** in Chainlink's reference directory `feeds-ethereum-mainnet-base-1.json` |
| EURC/USD `0x9867…01e0` (not used) | "EURC / USD", 8 dec, same owner, DualAggregator; rounds every 3,602 s; reference directory: heartbeat 3600 s, threshold 0.1 % |
| Sequencer `0xBCF8…6433` | answer 0, startedAt 1782491507 (80 days up) |
| min/maxAnswer of both price aggregators | 1 / 9.58e52 → no circuit-breaker cap |
| Pool EURC/USDC `0x7279…66fB` | token0 EURC, token1 USDC, liquidity 3.85e12, balance 34,738 EURC + 26,734 USDC |
| Pool USDC/cbBTC `0xfBB6…43ef` | token0 USDC, token1 cbBTC, fee 500, balance 3.85 M USDC + 50.8 cbBTC |
| Oracle vs. spot at the fork block | 66,710.78 vs. 66,674.34 EURC/cbBTC (5.5 bps) |

---

## Findings

### ORC-1 · Medium · Permissionless executor can atomically self-sandwich a run; profitable from ~2,500 EURC per run

**Lines:** `src/Rebalancer.sol:290` (`execute` permissionless), `:362-367` (`_quoteChecked`, tolerance 50 bps), `:371-383` (`_spot`/`_spotOut` read `slot0`), `:483-484` and `:503-504` (`minOut` = oracle × (1 − maxSlippageBps)), `:66` (`MAX_SLIPPAGE_BPS = 100`).

**Description.** The spot check reads the instantaneous `slot0` price of both pools. That price can be moved freely within one transaction; only the distance to the oracle (≤ 0.5 %) is bounded. Because anyone may call `execute` and `nonReentrant` only blocks nested calls, an attacker can in one transaction (1) push the thin EURC/USDC pool to just within 50 bps, (2) call `execute(owner, attacker)` and (3) reverse the push. The victim then swaps at a price that is 0.5 % + its own price impact worse than the oracle; the swap succeeds as long as that stays within `maxSlippageBps` (30–100 bps). The loss limit per run is therefore min(spot tolerance + impact, `maxSlippageBps`) relative to the oracle, once per `interval` per owner. The NatSpec (lines 30-37) and README (line 23) acknowledge this as a design choice; the fork PoC shows that it is not only theoretical.

**Attack scenario with numbers (fork PoC `test_poc_sweep` / `test_poc_sweepSell`, victim `maxSlippageBps = 100`, `maxCorrectionBps = 10000`).** Maximum push within 50 bps: selling 7,135 EURC into the EURC/USDC pool (buy direction) or 7,815 USDC (sell direction).

| Run (buy, EURC) | Push (EURC) | Victim loss | Attacker profit (EURC, after pool fees) |
|---|---|---|---|
| 1,000 | 7,135 | 5.70 EURC (0.57 %) | **−1.38** (not profitable) |
| 2,500 | 7,135 | 14.96 EURC (0.60 %) | **+7.91** |
| 5,000 | 7,135 | 33.83 EURC (0.68 %) | **+26.87** |
| 10,000 | 2,854 | 29.56 EURC (0.30 %) | **+27.01** (larger push: revert on `minOut`) |

| Run (sell, EURC value) | Push (USDC) | Victim loss | Attacker profit (USDC) |
|---|---|---|---|
| 1,000 | 7,815 | 4.50 EURC | −2.54 |
| 2,500 | 7,815 | 11.63 EURC | +5.71 |
| 5,000 | 7,815 | 24.53 EURC | +20.70 |

With `maxSlippageBps = 30` the 10,000 EURC run already fails without manipulation on "Too little received" (own impact 0.44 %); the attacker can then at most DoS (see ORC-4). The break-even point is around 2,000–2,500 EURC per run; above that the attacker structurally earns 0.3–0.55 % of the run amount, every interval again, without the victim noticing anything except a slightly lower `amountOut`.

**Existing test coverage.** `test_execute_revertsWhenSpotDeviatesFromOracle` (Rebalancer.t.sol:614) and `test_fork_spotDeviationBlocksRun` (RebalancerFork.t.sol:70) prove that > 50 bps reverts; `test_execute_revertsOnSlippageBuy/Sell` (:681/:692) that `minOut` works. Not a single test models an attacker who moves the pool within the tolerance and reverses it in the same transaction; the mock router computes against a fixed price without price impact, so a sandwich cannot even be expressed with the unit mocks.

**Recommended fix.**
1. Replace (or supplement) the `slot0` check with a TWAP via `pool.observe()` (e.g. 5–10 minutes, like Uniswap's `OracleLibrary.consult`): a TWAP cannot be moved atomically, so the attacker has to leave capital exposed to arbitrage.
2. Add a post-swap check: read `slot0` again after the swap and revert if the deviation from the oracle > `MAX_SPOT_DEVIATION_BPS`. The front-run + own impact then have to stay within 0.5 % together, which largely closes the sandwich's profit room.
3. Lower `MAX_SLIPPAGE_BPS` and/or base `minOut` on max(oracle, TWAP); consider tying `MAX_SPOT_DEVIATION_BPS` to `maxSlippageBps − 2 × POOL_FEE`.
4. Until then: document in the app that a low `maxCorrectionBps`/high `minTradeEurc` prevents large runs, and choose 30–50 bps as the default `maxSlippageBps`.

---

### ORC-2 · Medium · The EURC/USD feed is a 24-hour feed that is no longer in Chainlink's reference directory; the contract is unchangeable

**Lines:** `script/Deploy.s.sol:22` and `test/RebalancerFork.t.sol:17` (`FEED_EURC_USD = 0xDAe398…8250`), `src/Rebalancer.sol:49` (immutable), `:78` (`MAX_AGE_EURC = 86_400 + 3600`), `:385-393` (`_readFeed`).

**Description.** The contract reads EURC/USD from proxy `0xDAe3…8250`. On-chain: rounds exactly every 86,418–86,422 s (24 h heartbeat), price moves of up to 0.35 % between rounds without an intermediate update (so a deviation threshold ≥ 0.35 %; the search results of data.chain.link mention 0.3 % for the "RefPrice" feed). Chainlink's reference directory for Base (`feeds-ethereum-mainnet-base-1.json`) does not contain this address; it does contain `0x9867…01e0` ("EURC / USD", DualAggregator, heartbeat 3600 s, threshold 0.1 %), with on-chain rounds every 3,602 s. Both proxies have the same Chainlink owner (`0xf0Db…5B1b`), so `0xDAe3` is authentic and still running, but it is an older, slower feed that has disappeared from the public list. Consequences:

- **Deprecation risk.** If Chainlink stops this feed (not listed = classic harbinger), `_readFeed` permanently gives `StaleFeed` after 25 h, `isDue`/`dueOwners` always give (false, 0), and every `execute` reverts. There is no admin or upgrade (NatSpec line 26): the whole contract is then dead and all users have to approve again on a new address.
- **Tight margin.** 90,000 − 86,420 = 3,580 s. If Chainlink's 24-hour round runs one hour late (it happens), the whole service stops until the next round.
- **Lag room for ORC-1/ORC-3.** An oracle that can lag the market by up to 0.3 % (EURC) + 0.3 % (cbBTC) increases the distance between the "fair" price and the `minOut` anchor.

**Attack scenario/numbers.** No attacker needed: with a feed stop on day D the contract is unusable from D+25 h. With an ordinary delay of 1 h the service is down for 0–23 h.

**Existing test coverage.** `test_execute_revertsStaleFeedEurc` (Rebalancer.t.sol:551) tests the 90,000 s limit with mocks. No fork test checks the actual age/cadence of the feed or that the address is in Chainlink's list.

**Recommended fix.** On a redeploy use `0x9867186e52d2F1C2c565CDA6E747101Fa56501e0` (1 h heartbeat, 0.1 % threshold) with `MAX_AGE_EURC = 3600 + margin`; enforce `feed.decimals() == 8` in the constructor (see ORC-5); add a fork test that asserts `updatedAt` of both feeds < heartbeat + margin and checks the addresses against the reference directory. As long as the current contract is live: monitor `updatedAt` of `0xDAe3` externally (CRE/keeper) and prepare a migration path.

---

### ORC-3 · Low · Spot tolerance (0.5 %) is smaller than the summed feed deviation thresholds (0.3 % + ≥ 0.3 %): periodic false-positive reverts

**Lines:** `src/Rebalancer.sol:68` (`MAX_SPOT_DEVIATION_BPS = 50`), `:362-367`, `:77-78`.

**Description.** Per Chainlink parameters both feeds may deviate from the market by up to 0.3 % (cbBTC) and ≥ 0.3 % (EURC, 24 h) respectively before they update. The pool spot follows the market almost immediately (arbitrage). In the unfavorable combination (BTC +0.29 % since the last update, EUR/USD −0.29 % since yesterday) the spot is 0.58 % from the oracle and every `execute` reverts with `SpotDeviatesFromOracle`, while nothing is wrong. Because `lastExecutedAt` is not set (line 303 only comes after `_quoteChecked`), it is retried the next hour; the damage is limited to delay, but in a trending market that can last hours, and that is exactly when the user wants to rebalance. The README measures 4 bps at one quiet moment; that says nothing about volatile periods.

**Existing test coverage.** None: the mocks always set feed and spot together (`_setPrice`, Rebalancer.t.sol:82); the fork test only measures one snapshot (`test_fork_spotMatchesOracle`).

**Recommended fix.** Derive the tolerance from the feed parameters (≥ sum of the thresholds + pool fees, e.g. 75–100 bps) in combination with a TWAP (ORC-1), or replace the EURC feed with the 0.1 % variant (ORC-2), after which 50 bps does fit (0.3 % + 0.1 % + 0.1 % fees).

---

### ORC-4 · Low · DoS of `isDue`/`dueOwners`/`execute` by pushing the spot > 0.5 % costs ~8,000 EURC of capital and only pool fees

**Lines:** `src/Rebalancer.sol:240-243` and `:253-256` (`_tryQuote` → empty result), `:297` (`execute` reverts), `:371-373`.

**Description.** The EURC/USDC pool holds ~35 k EURC + 27 k USDC. Fork PoC `test_poc_dosBySpotPush`: selling 8,138 EURC pushes the spot > 50 bps; after that `isDue` gives false, `dueOwners` is empty and `execute` reverts. Attacker cost: 0.05 % pool fee there and back (~8 EURC) plus the temporary price risk; if the push stays in place, the market arbitrages it away. The attacker can repeat this every hour just before the CRE cron (the cron time is public, and so is `dueOwners`), so the service is structurally down for a few euros per hour. Users lose no money, but the core promise (automatic rebalancing) fails.

**Existing test coverage.** `test_fork_spotDeviationBlocksRun` (fork:70) tests the revert via a mocked feed, not via a real pool push; costs for an attacker are measured nowhere.

**Recommended fix.** TWAP instead of `slot0` (an attacker then has to stay exposed for minutes), and/or monitor and alert on a `ReportSkipped` with `SpotDeviatesFromOracle` in `onReport`.

---

### ORC-5 · Low · No check on `decimals()` of the feeds in the constructor

**Lines:** `src/Rebalancer.sol:48-49` (comment "8 decimals"), `:150-178` (constructor), `:357` (`price = cbbtcUsd * 1e6 / eurcUsd`).

**Description.** The conversion is only correct if both feeds have the same decimals (the factor then cancels out). Both are 8 on-chain, so correct for now. On a redeploy with a different feed (e.g. an 18-dec feed or an EUR/USD feed) the price would be off by a factor of 10^k; the spot check would catch that as a permanent DoS, not as a loss. `IAggregatorV3.decimals()` is already in the interface (IAggregatorV3.sol:6) but is never called.

**Existing test coverage.** No test with deviating feed decimals.

**Recommended fix.** In the constructor: `if (FEED_CBBTC_USD.decimals() != 8 || FEED_EURC_USD.decimals() != 8) revert InvalidParams();` plus a unit test.

---

### ORC-6 · Info · Sequencer feed: `startedAt == 0` (uninitialized round) is not caught

**Lines:** `src/Rebalancer.sol:352-353`.

**Description.** `block.timestamp - seqStartedAt < GRACE_PERIOD` is false when `startedAt == 0`, so an uninitialized round (`answer 0, startedAt 0`) counts as "up". Chainlink documents this edge case for L2 uptime feeds. On Base the feed has been at `startedAt = 1782491507` for 80 days; practically not exploitable, but the check `if (seqStartedAt == 0) revert SequencerDown();` is free.

**Existing test coverage.** `test_execute_revertsSequencerDownAnswerOne/WithinGrace` (Rebalancer.t.sol:512/519); no test for `startedAt == 0`.

---

### ORC-7 · Info · EURC depeg: the contract sells cbBTC into a depegging EURC

**Lines:** `src/Rebalancer.sol:355-357`, `:434-437` (position valued in EURC).

**Description.** The EURC/USD feed follows the market price of EURC itself (assetSubClass "Stablecoin"), not fiat EUR. If EURC drops to e.g. 0.90 USD while BTC is stable, `price` (EURC per cbBTC) rises by ~11 %, the cbBTC fraction rises above target + band and the next run sells cbBTC for depegged EURC. Oracle and pool spot move along (the EURC/USDC pool prices in the depeg), so the spot check does not intervene. This is not a bug but a design choice (EURC as numeraire) that in the worst case moves the user from a hard asset into a failing stablecoin. With a depeg of > 0.3 % the feed updates immediately on deviation (no 24 h lag), but between the update and the keeper's tick there is at most one interval.

**Existing test coverage.** No depeg scenario in the tests.

**Recommended fix (optional).** An "EURC health band": revert if `eurcUsd` deviates more than X % from an EUR/USD feed (available on Base), or from the previous value. At a minimum: document for users.

---

## Assessment of static analysis (my vector only)

| Tool / detector | Line | Verdict |
|---|---|---|
| Slither `unused-return` on `pool.slot0()` (:380), `SEQUENCER_FEED.latestRoundData()` (:352), `feed.latestRoundData()` (:386) | — | **False positive**: deliberate destructuring; `roundId`/`answeredInRound` are no longer meaningful since OCR2, `tick` etc. not needed. |
| Slither `timestamp` on `_quote`, `_readFeed`, `isDue`, `execute`, `dueOwners` | — | **False positive**: staleness and interval checks require `block.timestamp`; seconds-level manipulation by the sequencer is irrelevant at this scale. |
| Slither `unused-return` on `ROUTER.exactInput` in `_sell` (:508); Aderyn L-4 | — | **True but harmless**: the contract measures the amount actually received via the balance difference (:507-516), which is more robust than the return value. |
| Slither `incorrect-equality` (`total == 0`, `amountIn == 0`) | — | Outside my vector; exact 0 checks on integers are correct here. |
| Slither/Aderyn other (naming, literal, redundant statement) | — | No relation to oracle/price. |

Neither tool flags the core problems (slot0 manipulability, feed choice/heartbeat, tolerance vs. deviation thresholds); those require manual review.

---

## Investigated and found safe

- **Staleness/heartbeat cbBTC/USD:** `MAX_AGE_CBBTC = 1500` (:77) vs. observed cadence ~1,230 s and documented heartbeat 1,200 s: margin 300 s, okay. A future `updatedAt` and `updatedAt == 0` give `StaleFeed` (:389), not a Panic.
- **answer ≤ 0:** caught in `_readFeed` (:387); `price == 0` after conversion caught (:358, `test_execute_revertsWhenQuoteRoundsToZero`).
- **Round completeness (`answeredInRound < roundId`):** not checked, but no longer needed for OCR2 feeds (Chainlink has deprecated this); the `updatedAt` check covers it.
- **min/maxAnswer cap:** both aggregators have minAnswer 1 and maxAnswer 9.58e52, so no LUNA-like stuck price; and even then the spot check would revert instead of trading at a fictitious price.
- **Sequencer grace:** `answer != 0 || now − startedAt < 1 h` (:353) is the Chainlink reference pattern; tested at both limits (:512-527).
- **Decimals/precision of the conversion:** `mulDiv(cbbtcUsd(8), 1e6, eurcUsd(8))` → EURC base units per cbBTC; rounding error < 1e-6 EURC; 512-bit intermediate result, no overflow.
- **`_spotOut` arithmetic:** `ratioX96 = sqrtPriceX96²/2^96` fits in 224 bits; with `mulDiv` no overflow for any `uint160`. With the real pools (ratio ≈ 1.15 and ≈ 7.7e-4 respectively) more than enough precision; the fork test confirms a 5.5 bps distance to the oracle. Division by zero only if `sqrtPriceX96 < 2^48` (pool at MIN_TICK, practically impossible); and then `execute` reverts and `isDue` gives (false, 0) via the try/catch (:395-401), so no behavior different from a deviation.
- **Token order in the pools:** `_poolOrder` (:186-192) derives token0/token1 and reverts on wrong tokens; `_spot` sets the direction per pool correctly (:372-373); tested with reversed order (`test_spot_pairsWithReversedTokenOrder`).
- **Both hops checked:** `_spot` multiplies the spot of the USDC/cbBTC pool by that of the EURC/USDC pool (:372-373), so manipulation of either pool hits the check. Unit tests cover the cbBTC pool (>50 bps → revert) and the EURC pool (0.4 % → passes); the fork PoC confirms the EURC pool at > 50 bps.
- **Slippage anchor:** `minOut` is derived from the **oracle** (:483-484, :503-504), not from the manipulable spot. That is the right choice and the reason ORC-1 is bounded to `maxSlippageBps`.
- **Position valuation:** `_plan` uses only the oracle price (:436, :467); the amount to trade therefore cannot be influenced via the pool.
- **Oracle lag by itself:** an oracle lagging the market by 0.3 % costs the user nothing as long as the swap happens at market price; only the manipulation room (ORC-1/ORC-3) shifts along with it.
- **Third-party sandwich on Base:** the sequencer is FCFS without a public mempool; the realistic path is the executor itself (ORC-1), not a mempool sniper.

## Test gaps (oracle/price vector)

1. [x] Fork test with an atomic self-sandwich (front-run → `execute` → back-run) that asserts the attacker cannot get a positive PnL (currently fails, see ORC-1).
   → Covered: fork `test_poc_selfSandwich_10k_slippage100` (attack fails, PnL ≤ 0, victim unaffected) and `test_poc_executorSandwich`.
2. [x] Post-swap deviation: test that the spot after the swap is within the tolerance (does not exist because the check does not exist).
   → Covered: fork `test_fork_postSwapSpotWithinTolerance` and unit `test_execute_revertsWhenSpotDeviatesAfterSwap`.
3. [x] Fork test that checks the actual age and cadence of both feeds against `MAX_AGE_*` (and `updatedAt` not older than heartbeat + margin), plus a check that the feed addresses appear in Chainlink's reference directory.
   → Covered: fork `test_fork_feedsAreFreshAndMatchConstants` (age, decimals, description) and `test_fork_feedCadenceWithinMaxAge` (gaps between the last 24 rounds ≤ `MAX_AGE_*`). Chainlink's reference directory is off-chain and cannot be queried from Forge.
4. [x] Unit test that pushes only the EURC/USDC pool > 50 bps (currently only the 0.4 % pass; the fail side goes through the cbBTC pool).
   → Covered: `test_execute_revertsWhenOnlyEurcPoolDeviates`.
5. [x] Scenario in which feed and spot move independently (feed lags 0.3 %, spot ±0.3 %) to make ORC-3 visible; the mocks currently always couple them (`_setPrice`).
   → Covered: `test_execute_feedAndSpotDivergeIndependently`.
6. [x] Sequencer `startedAt == 0`.
   → Covered: `test_execute_revertsSequencerDownWhenStartedAtZero`.
7. [x] Feed with deviating `decimals()` (constructor must revert after the ORC-5 fix).
   → Covered: `test_constructor_rejectsFeedWithWrongDecimals`.
8. [x] EURC depeg scenario (feed 0.90, pool follows) with an assertion on the direction of the run.
   → Covered: `test_isDue_eurcDepegTurnsHoldIntoSell`.
9. [x] `_spotOut` at extreme `sqrtPriceX96` (MIN/MAX_SQRT_RATIO): no Panic leaking out via `isDue`/`dueOwners`.
   → Covered: `test_spot_extremeSqrtPriceNeverPanicsInViews`.
10. [x] The invariant handler has no action that only moves the pools (independently of `feedBtc`), so the spot check is never hit in the invariant suite.
   → Covered: handler action `shiftSpot` in `RebalancerHandler`, counted in `invariant_executeFailsOnlyForKnownReasons`.
