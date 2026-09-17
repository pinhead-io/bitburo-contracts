# Rebalancer — adversarial review of the arithmetic (_plan, _buy, _sell, fee, reward)

Scope: `/Users/arjan/Code/bitburo-contracts/src/Rebalancer.sol` (Solidity 0.8.28, OZ 5.6.1, via-IR), interfaces, mocks, `test/Rebalancer.t.sol`, README. No change in the repo; all PoCs are in the scratchpad (see bottom).

Notation: EURC = 6 decimals, cbBTC = 8 decimals ("sat"), Chainlink = 8 decimals, `price` = EURC base units per 1 cbBTC (L350-359).

---

## M-01 — Small wallets (or cap == minTrade) can never sell because of rounding of `wantBtc`

- **Severity:** Medium (deterministic functional outage for a whole class of users; no loss of money)
- **Lines:** `src/Rebalancer.sol:454-458` (cap floor at minTrade), `:467` (`wantBtc = mulDiv(correctionEurc, CBBTC_UNIT, price)` — floor), `:469` (`mulDiv(amountIn, price, CBBTC_UNIT) < p.minTradeEurc → amountIn = 0`)
- **Description:** If `total * maxCorrectionBps / BPS < minTradeEurc`, then `cap = minTradeEurc` (L455) and therefore `correctionEurc == minTradeEurc` as soon as the drift is large enough (L456). On a sell that amount is rounded down to sats (L467); the value converted back (L469) is therefore up to almost 1 sat (~800 EURC units at 80k) smaller than `minTradeEurc`, and `amountIn` becomes 0. Only if `minTradeEurc * 1e8` is exactly divisible by `price` does the check pass. With a real feed price (6 decimals, e.g. 80,123.456789) that practically never happens. The buy side does not have this problem (`amountIn = correctionEurc` exactly, L464). The effect is asymmetric: small wallets *can* buy more, but can never reduce.
  Same artefact for larger wallets as soon as `cap - minTradeEurc < 1 sat of value`.
- **Scenario:** app defaults `minTrade = 5 EURC`, `maxCorrection = 10 %`, target 80/20. Wallet: 0 EURC + 50,000 sats (≈ 40.06 EURC) at price 80,123.456789. `total = 40.06e6`, `cap = max(4.006e6, 5e6) = 5e6`, drift·total = 8.01e6 → `correction = 5e6`. `wantBtc = 5e6·1e8 / 80,123,456,789 = 6240.37 → 6240`. Value = `6240 · 80,123,456,789 / 1e8 = 4,999,703 < 5,000,000` → `amountIn = 0` → `NothingToDo`, `isDue = false`. All wallets with `total < minTrade / maxCorrection` (here: < 50 EURC) are permanently stuck on the sell side.
- **Existing test coverage:** none. All sell tests use `PRICE = 80_000e6` (divides exactly: 5e6·1e8/80000e6 = 6250) or `VECTOR_PRICE = 100e6`; `testFuzz_planBoundedAndAccountingClosed` does not fuzz the price. The invariant handler does fuzz the price but asserts nothing about due-ness.
- **PoC:** `test_poc_smallWalletCannotSell`, `testFuzz_poc_sellBlockedWhenCapEqualsMinTrade` (3000 runs: due ⇔ exactly divisible).
- **Fix:** round `wantBtc` up: `Math.mulDiv(correctionEurc, CBBTC_UNIT, price, Math.Rounding.Ceil)`. That is safe: `amountIn` stays bounded by `btcBal` and allowance (L468) and the value exceeds `correctionEurc` by at most 1 sat. Alternative: perform the minTrade check on L469 on `correctionEurc` (already ≥ minTrade on L457) and only recompute when clamping by allowance/balance.

## M-02 — Blacklisting of TREASURY by Circle locks the contract permanently

- **Severity:** Medium (low likelihood, high impact; the contract is immutable, there is no way out except redeploy + new mandates from all users)
- **Lines:** `src/Rebalancer.sol:530` (`EURC.safeTransfer(TREASURY, fee - reward)`), `:51` (`TREASURY` immutable), `:339-342` (`sweep` to TREASURY)
- **Description:** EURC is a Circle FiatToken with a blacklist. Every run with `fee - reward > 0` (i.e. `fee > 0.05 EURC` ⇔ EURC leg > 200 EURC, or `rewardTo == address(0)`, which `onReport` effectively does because it passes `TREASURY` as rewardTo and the rest *also* goes to TREASURY) makes a transfer to TREASURY. If TREASURY is blacklisted, every such run reverts, and so does `sweep(EURC)`. Only microruns (≤ 200 EURC) with a non-blacklisted `rewardTo` keep working. There is no admin to change TREASURY.
- **Scenario:** TREASURY gets on the blacklist. Alice (1,000 EURC, buy 100 EURC, fee 0.25) → `execute` reverts with "Blacklistable: account is blacklisted"; CRE reports only emit `ReportSkipped`; `isDue` stays `true` (the plan phase does not look at the blacklist), so the keepers retry every hour.
- **Existing test coverage:** `test_execute_revertsWhenOwnerBlacklisted` (owner), not the treasury.
- **PoC:** `test_poc_blacklistedTreasuryBricksExecute`.
- **Fix (design choice):** (a) fee transfer in `try` and on failure leave the fee with the contract (sweepable) or return it to the owner, so the rebalance itself never breaks on the fee recipient; or (b) make the treasury address rotatable by the treasury itself (1-to-1, `msg.sender == TREASURY`). Option (a) keeps "no admin" intact.

## L-01 — No lower bound on `minTradeEurc`: microruns with fee 0, `amountOutMinimum` 0 and buys that yield 0 sats

- **Severity:** Low (can only be configured by the owner himself; but keeper griefing and loss of dust)
- **Lines:** `src/Rebalancer.sol:199-200` (`p.minTradeEurc == 0` is the only requirement), `:483-484` (`expectedOut = mulDiv(swapIn, 1e8, price)` → 0 when `swapIn < price/1e8`; `minOut = 0`), `:525` (`fee = 0` for `eurcAmount < 400`), `:303` (cadence moves forward anyway)
- **Description:** `setParams` accepts `minTradeEurc = 1` (0.000001 EURC). Then: (1) buy runs with `swapIn < 1 sat of value` (< ~0.0008 EURC at 80k) have `expectedOut = 0`, so `amountOutMinimum = 0`: the owner pays EURC to the pool and gets 0 cbBTC; the fraction stays 0 and the next run is due again → a loop that drains the wallet down to dust. (2) `fee = 0` below 400 units → the keeper spends ~400k gas for 0 reward. (3) `minOut` gets coarser through the floor as `expectedOut` gets small (at 10 sats expected the effective slippage tolerance is 10 %, not 1 %): the sandwich protection dilutes for runs below roughly 0.1 EURC.
- **Scenario:** cash 2,067 units, target 6 %, minTrade 1, cap 50 %: 20 consecutive runs, each `amountIn ≥ 1`, `amountOut = 0`, balance from 2,067 → 605 units, 0 sats received (fuzz counterexample from `testFuzz_audit_noPingPongConstantPrice` with `minTrade = 1`). Second example: cash 5,866, target 10 %: one run pays 586 units, receives 0.
- **Existing test coverage:** `test_setParams_boundaryValuesAccepted` actually confirms that `minTradeEurc = 1` is accepted; `testFuzz_planBoundedAndAccountingClosed` fuzzes `minTrade` from 1 but does not assert that `amountOut > 0`.
- **PoC:** `test_poc_dustBuyLoopNeverConverges`, `test_poc_microBuyYieldsZeroOutput`, `test_poc_microRunZeroFeeZeroMinOut`.
- **Fix:** lower bound in `setParams`, e.g. `MIN_TRADE_EURC = 1e6` (1 EURC): then `fee ≥ 2,500` (> 0), `expectedOut ≥ ~1,250 sats` and the floor error in `minOut` < 1 bp. Extra safety net: `if (amountOut == 0) revert` in `_buy`.

## L-02 — `MIN_SLIPPAGE_BPS` (30) < `MAX_SPOT_DEVIATION_BPS` (50) + pool fees (10): runs can be structurally unexecutable

- **Severity:** Low (liveness; no loss)
- **Lines:** `src/Rebalancer.sol:66-68`, `:366` (spot may deviate 0.5 %), `:484`/`:504` (`minOut = expected · (1 − maxSlippageBps)` relative to the **oracle** price), `:63` (2 × 0.05 % pool fee)
- **Description:** `amountOutMinimum` is derived from the Chainlink price, but the swap happens at the pool spot. The spot may deviate unfavorably by 0.5 %, the two hops cost 0.1 %, plus price impact. With `maxSlippageBps = 30` the achievable outcome is then up to 0.6 %+ below the oracle, while `minOut` only allows 0.3 %: the spot check lets the run through, the router reverts with "Too little received", `lastExecutedAt` stays where it is, and the keeper retries every hour (gas for nothing). Only at `maxSlippageBps ≥ 60 + price impact` is a run achievable in every allowed market state.
- **Scenario:** oracle 80,000, spot 80,400 (+0.5 %, allowed), user `maxSlippageBps = 30`: buy 100 EURC → `minOut = 99.75e6·1e8/80,000e6 · 0.997 = 124,313 sats`; pool delivers `99.75e6 / 80,400e6 · 0.999 · 1e8 ≈ 123,940` → revert.
- **Existing test coverage:** `test_execute_revertsOnSlippageBuy/Sell` (router slippage > maxSlippage), but not the combination "spot within the limit + pool fees > maxSlippage".
- **PoC:** `test_poc_minSlippageBelowSpotDeviationPlusPoolFees`.
- **Fix:** set `MIN_SLIPPAGE_BPS` to ≥ `MAX_SPOT_DEVIATION_BPS + 2·POOL_FEE/100` (= 60), or derive `minOut` from the checked **spot** instead of the oracle. In any case document in the README/app that 30 bps often reverts in practice.

## I-01 — Overshoot from fee+slippage is small, in the same direction and converging: no ping-pong

- **Severity:** Info (found safe, with a caveat)
- **Lines:** `src/Rebalancer.sol:447-456`, `:479-481`, `:516-520`
- **Analysis:** let `c` = correction (EURC, oracle terms), `f` = total loss on the run amount (fee 0.25 % + slippage ≤ 1 % ⇒ `f ≤ 1.25 %`), `T` = target.
  - Sell: position drops by exactly `c` (because `wantBtc = c/price`), cash rises by `c(1−f)`. New fraction = `T·total / (total − c·f)` **> T** → the next run is again a sell.
  - Buy: position rises by `c(1−f)`, cash drops by `c`. New fraction = `(T·total − c·f)/(total − c·f)` **< T** → the next run is again a buy.
  The direction therefore never reverses; the residual drift is `≤ f · c / total` and shrinks geometrically per run. At 80/20, cap 10 %, `f = 1.25 %` the residual drift is ≤ 0.125 pt, well within band 5 pt. With a small `bandBps` (< ~20 bps) *and* a small `minTradeEurc` extra tail runs in the same direction do follow, each with a fee (example: 1,000 EURC fully in cbBTC, band 1 bps, minTrade 1: run 1 sells 200 EURC, fraction afterwards 0.8020; run 2 sells another 1.996 EURC; run 3 nothing). That is a configuration effect, not an exploit.
- **Evidence:** `testFuzz_audit_corridorFeeResidue` (3001 runs: residual drift ≤ `(25 + maxSlip) bps · amountIn / total'`, and the next `isDue` always has the same direction) and `testFuzz_audit_noPingPongConstantPrice` (3001 runs, up to 60 consecutive runs: direction never reverses, series ends). PoC `test_poc_sellOvershootTailRuns`.
- **Recommendation:** lower bound on `bandBps` (e.g. ≥ 25 + MAX_SLIPPAGE_BPS = 125) or the app does not allow a band < ~1 %; then every full correction is done in one run.

## I-02 — The cap is per run, not per day

- **Severity:** Info (documentation/expectation)
- **Lines:** `src/Rebalancer.sol:454` (`cap = total · maxCorrectionBps`), `:75` (`MIN_INTERVAL = 1 hours`), `:293`
- **Description:** The briefing speaks of a "daily cap of 10 %". The contract only knows a cap per `execute` and an interval ≥ 1 hour. With `interval = 1 hours` and `maxCorrectionBps = 1000` a wallet can move 24 × 10 % per day. That is correct according to the NatSpec (L23 "per run") but deviates from the app terminology.
- **PoC:** `test_poc_capIsPerRunNotPerDay` (5 runs in 5 hours: > 40 % moved).
- **Fix:** no contract change needed; have the app enforce `interval = 1 days` if a "daily cap" is intended, or call it "cap per run".

## I-03 — Slither findings: all five false positives

- `incorrect-equality` `total == 0` (L438): `total` is a sum of two ERC-20 balances (not a computed derivative with rounding noise); the equality is the exact semantics "wallet empty" and protects the division on L442. FP.
- `incorrect-equality` `amountIn == 0` (L279 and L300): `amountIn` is a sentinel that the code itself explicitly sets to 0 (L465, L469, L439, L450, L458); it is not compared with a computed value. FP.
- `uninitialized-local` `n` (L259): Solidity initializes local value types to 0; `n` is only incremented. FP.
- `unused-return` `ROUTER.exactInput` (L508): deliberately ignored; `_sell` measures the result via the `balanceOf` difference (L507, L516), which is more robust than the router return (also correct if the router reports less than it delivers). FP. Caveat: if tokens are donated to the contract before the run, they are included in `eurcBefore` and are not counted (correct); `sweep` cleans them up. Tested in `testFuzz_audit_corridorFeeResidue` (donation stays exactly in place).

## I-04 — Feed decimals are not checked (but cancel out)

- **Severity:** Info
- **Lines:** `src/Rebalancer.sol:357` (`price = mulDiv(cbbtcUsd, 1e6, eurcUsd)`), `:48-49`
- **Description:** The formula divides two feeds by each other, so the decimals cancel out as long as **both** feeds have the same decimals (on Base: 8 and 8). The constructor does not check that, although `IAggregatorV3.decimals()` is available. A deploy with e.g. an 18-dec EURC/USD feed would silently give a price 1e10 times too small. Immutable, so only a deploy risk.
- **Fix:** in the constructor `if (FEED_CBBTC_USD.decimals() != FEED_EURC_USD.decimals()) revert InvalidParams();`.

## I-05 — Fee basis is asymmetric but in both cases exactly 25 bps of the EURC leg

- **Severity:** Info (found safe; document)
- **Lines:** `src/Rebalancer.sol:480` (buy: fee on gross `amountIn`, before the swap), `:518` (sell: fee on net `received`, after slippage), `:524-531`
- **Description:** Buy: `fee = amountIn · 25 / 10,000`, `swapIn = amountIn − fee` (the user pays 100 EURC, 99.75 goes into the pool). Sell: `fee = received · 25 / 10,000` (on what the pool actually delivered, so slippage lowers the fee). Both are "25 bps of the EURC value flowing through the contract"; a fee is never charged on the whole portfolio, and never without a swap (the swap revert atomically undoes the whole run; `lastExecutedAt` is then not set either, `test_execute_lastExecutedAtNotSetOnRevert`). `reward = min(0.05 EURC, fee)`, `treasury = fee − reward`; the sum is exactly `fee`, paid by the owner; never more than 25 bps. Rounding via `mulDiv` (floor) is in the user's favor.
- **Evidence:** `testFuzz_audit_corridorFeeResidue` (fee == `mulDiv(basis, 25, 10,000)`, reward == `min(50,000, fee)`, price 20k–200k, router slippage 0–maxSlip).

## I-06 — Owner can take back part of his own fee via `rewardTo`

- **Severity:** Info
- **Lines:** `src/Rebalancer.sol:290`, `:526-528`
- **Description:** `execute(owner, owner)` gives the owner `min(0.05 EURC, fee)` of his own fee back; the effective fee for self-executing owners is `fee − 0.05`. Bounded and known design (permissionless). No action needed; mention in the fee documentation.

## I-07 — Allowance clamping and cadence: a partial run moves the interval forward completely

- **Severity:** Info (design, documented on L423-425, but with consequences for the keepers)
- **Lines:** `src/Rebalancer.sol:464`, `:468`, `:303`
- **Description:** With `allowance < correction` (but ≥ minTrade) only `allowance` is traded, the fee is computed on that smaller amount (correct), and `lastExecutedAt` goes to `now`: the rest waits a full interval. Meanwhile `isDue` reports the **full** correction (`eurcDelta`), not the amount `execute` will actually do; a keeper that bases a reward expectation on `eurcDelta` sees a deviation. All other calculation steps (minTrade check on the clamped amount, L465/L469) are consistent between `isDue` and `execute`, so no false due signals.
- **Existing test coverage:** `test_execute_boundedByAllowance`, `test_isDue_deltaIsCorrectionBeforeAllowanceBound`, `test_execute_allowanceBelowMinTradeIsNothingToDo`.
- **PoC:** `test_poc_partialRunAdvancesCadence`.
- **Recommendation:** either have `isDue` return the clamped `amountIn` (in EURC), or document that `eurcDelta` is the unclamped wish.

## I-08 — Cosmetic

- `src/Rebalancer.sol:315` `correctionEurc;` is a no-op statement (Aderyn reports it too); replace with an unnamed return slot (`(bool isBuy, uint256 amountIn,, uint256 total, uint256 fractionBps)`).
- `src/Rebalancer.sol:461-462`: the comment "correction ≤ |drift|·total ≤ balance" is correct (also with the cap floor, because `correction = min(drift·total, cap) ≤ drift·total`); the balance clamp is indeed only defensive.

---

## Found safe (with evidence)

| Subject | Lines | Verdict |
|---|---|---|
| Conversion Chainlink → EURC/cbBTC | L357 | `cbbtcUsd(8) · 1e6 / eurcUsd(8)` → EURC units per cbBTC; decimals cancel out (see I-04). Loss ≤ 1 unit per BTC. |
| Position value | L436 | `mulDiv(btcBal, price, 1e8)` in a single 512-bit step, floor. No division before multiplication. |
| Fraction/drift/correction | L442-453 | WAD arithmetic with `mulDiv`; `targetWad`/`bandWad` exact (1e18 divisible by 1e4). Loss < 1 EURC unit on `correctionEurc`. `fractionBps` only for the event. |
| Corridor triggering within one tick | L293, L303 | Per owner at most one run per `interval`; `lastExecutedAt` set before the swap, rolled back atomically on revert. Price movement cannot provoke a second run within an interval. |
| `isDue`/`dueOwners` ≡ `execute` | L277-284, L298-300 | Both use `_plan` and `_quoteChecked`; no false due signals (confirmed in fuzz). |
| Overflow | L366, L381-382, L443-445 | `diff·BPS`, `sqrtP²/2^96` (< 2^224), `fractionWad·BPS` fit comfortably in uint256. |
| Fee sum and payer | L524-531 | `reward + treasury == fee`, `fee ≤ 25 bps`, always from the owner's EURC leg. Zero transfers are skipped. |
| Residue | L487-494, L507-520 | Buy: router recipient = owner. Sell: recipient = contract, everything (`received − fee`) passed on to the owner. `forceApprove` is fully consumed (fuzz: router allowance after run == 0). Donated tokens stay untouched and are sweepable. |
| Uniswap path | L489, L510 | `exactInput`, 2 hops via USDC at 0.05 %; SwapRouter02 has no `deadline` (staleness is covered by the feed `MAX_AGE` and the spot check). `amountOutMinimum` from oracle × (1 − maxSlippage), floor (see L-01/L-02 for the edges). |
| Reentrancy | L290, L339 | `ReentrancyGuardTransient` on `execute` and `sweep`; `onReport` calls `this.execute` externally (own guard scope). EURC/cbBTC have no hooks. |
| Dust/oscillation | L457, L465, L469 | Below `minTradeEurc` nothing is done and the cadence is not moved; no infinite oscillation with a realistic `minTrade` (≥ 0.1 EURC). Exceptions: M-01 (sell floor) and L-01 (microruns). |

## Test gaps in the existing suite

1. [x] Not a single sell test with a non-round price (`PRICE = 80_000e6`, `VECTOR_PRICE = 100e6` divide `minTrade` exactly) → M-01 invisible. Add a fuzz on `price` to `testFuzz_planBoundedAndAccountingClosed` and assert `due == (correction ≥ minTrade)`.
   → Covered: `testFuzz_isDue_matchesCorrectionAtAnyPrice` (price free between 20k and 200k, asserts `due == (correction ≥ minTrade)` and that `execute` then succeeds), plus `testFuzz_poc_sellOnMinTradeFloorAlwaysDue` and `test_poc_smallWalletCanSellWithNonRoundPrice`.
2. [x] No test for a blacklisted TREASURY or `rewardTo` (M-02).
   → Covered: `test_execute_continuesWhenTreasuryBlacklistedAndSweepRecoversFee`, `test_execute_sellRetainsWholeFeeWhenTreasuryBlacklisted`, `test_execute_rewardFallsBackToTreasuryWhenRewardToBlacklisted`.
3. [x] No assertion `amountOut > 0` / `minOut > 0` on small runs; `minTrade` is fuzzed from 1 without that check (L-01).
   → Covered: `testFuzz_audit_corridorFeeResidue` asserts cbBTC output > 0 on a buy and `amountOutMinimum` > 0 on both buy and sell; `test_execute_revertsNoOutputWhenBuyYieldsZero`.
4. [x] No test for "spot within 0.5 % + pool fees > maxSlippage" (L-02).
   → Covered: `test_execute_minSlippageCoversSpotDeviationPlusPoolFees`, `test_poc_minSlippageBelowSpotDeviationPlusPoolFees`.
5. [x] No test that checks, after a run, the new fraction relative to band/target or the direction of the next run (overshoot/ping-pong, I-01).
   → Covered: `testFuzz_audit_corridorFeeResidue`, `testFuzz_audit_noPingPongConstantPrice`, `test_poc_sellOvershootTailRuns`.
6. [x] No test for a `decimals()` mismatch of the feeds (I-04).
   → Covered: `test_constructor_rejectsFeedWithWrongDecimals`.
7. [x] The invariant handler lets `execute` revert without recording why; a ghost counter per revert reason (NothingToDo vs "Too little received") would make L-02-like liveness outages visible.
   → Covered: ghost counters per revert reason in `RebalancerHandler`, checked by `invariant_executeFailsOnlyForKnownReasons`.

## Fuzz/invariant outcome

- Test file: `/private/tmp/claude-501/-Users-arjan-Code-bitburo/b70b479c-bb69-42d9-8159-4abc1a801885/scratchpad/repo/test/AuditMath.t.sol` (copy: `.../scratchpad/AuditMath.t.sol`); run log: `.../scratchpad/audit-math-run.txt`.
- Command: `RUN_FORK=false FOUNDRY_FUZZ_RUNS=3000 ~/.foundry/bin/forge test --match-contract AuditMathTest -vv` in the scratchpad copy of the repo.
- Result: **12/12 passed**.
  - `testFuzz_audit_corridorFeeResidue` (3001 runs; price 20k–200k, all params, allowances, router slippage 0–maxSlip, donation to the contract): (a) after an unbounded run the residual drift is ≤ `(25 + maxSlippage) bps · amountIn / total'` and, if the band allows it, within the band; bounded runs sit at cap/allowance; the next `isDue` never has the opposite direction; (b) `fee == mulDiv(EURC leg, 25, 10,000)` exactly and `reward == min(50,000, fee)`; (c) after `execute` the contract holds exactly the amount of EURC donated beforehand (0 without a donation), 0 cbBTC and 0 router allowance.
  - `testFuzz_audit_noPingPongConstantPrice` (3001 runs, up to 60 consecutive runs at a constant price, `minTrade ≥ 0.1 EURC`): direction never reverses, series ends.
  - `testFuzz_poc_sellBlockedWhenCapEqualsMinTrade` (3000 runs): a sell is only due if `minTrade·1e8 % price == 0` (M-01).
  - Counterexamples that surfaced during fuzzing and are now pinned down as PoCs: `test_poc_microBuyYieldsZeroOutput` (cash 5,866, target 10 %, minTrade 6 → pays 586, receives 0) and `test_poc_dustBuyLoopNeverConverges` (20 runs, 2,067 → 605 units, 0 sats).
- Existing suite in the same copy (without fork): 76 unit/fuzz + 3 invariants passed; the new tests change nothing in the repo.
- Note when reproducing yourself: via-IR caches `block.timestamp` within a test function; use `vm.getBlockTimestamp()` in loops (otherwise a false `NotDue`).
