# Rebalancer – adversarial review: permissionless `execute`, reward and cadence

Scope: `src/Rebalancer.sol` (Solidity 0.8.28, OZ 5.6.1, via-IR), `src/interfaces/*.sol`, `README.md`, `test/Rebalancer.t.sol`, `test/RebalancerFork.t.sol`, `keeper/keeper.ts`, `cre/bitburo-keeper/main.ts` (+ `config.production.json`). Live contract on Base: `0xED47d549345b0dBB5A9b44E57Ff3AB4E6Ed0e6e5`; I confirmed the constants `KEEPER_REWARD_EURC=50000`, `FEE_BPS=25`, `MIN_INTERVAL=3600`, `MAX_SPOT_DEVIATION_BPS=50`, `EXECUTE_GAS=700000` and `ownerCount()=1` via `cast call`, so the source code matches what is live.

PoCs are in `scratchpad/poc/test/PocStarvation.t.sol` (mocks) and `scratchpad/poc/test/PocFork.t.sol` (fork of Base mainnet, block ~51,337,327). All three fork PoCs and the mock PoC pass; the repo was not touched.

Line references are to `src/Rebalancer.sol` unless stated otherwise.

---

## EX-01 — High — Dust owners permanently occupy all five CRE slots (starvation of the primary keeper)

**Lines:** `setParams` 197–212 (no lower bound on `minTradeEurc`/`maxCorrectionBps`, `_owners` append-only), `dueOwners` 248–275 (registration order, offset into `_owners`), `_plan` 453–459 (`cap = max(total*maxCorrection, minTrade)`), `cre/bitburo-keeper/main.ts` 178–195 (first `maxOwnersPerReport` due owners from offset 0), `config.production.json` (`maxOwnersPerReport: 5`, cron every hour).

**Description.** The only requirements on an owner are `minTradeEurc >= 1` (base unit, so 0.000001 EURC), `maxCorrectionBps >= 1` and `interval >= 1 hours`. An owner with a 1 EURC balance, `maxCorrectionBps = 1`, `minTradeEurc = 1`, `bandBps = 1`, `interval = 1 hours` is therefore due again every hour for a run of 100 base units (0.0001 EURC):

```solidity
cap = Math.mulDiv(total, p.maxCorrectionBps, BPS);      // 1e6 * 1 / 10000 = 100
if (cap < p.minTradeEurc) cap = p.minTradeEurc;
if (correctionEurc > cap) correctionEurc = cap;         // 100
if (correctionEurc < p.minTradeEurc) { return ...; }    // 100 >= 1 -> due
```

The CRE workflow takes the first five due owners in registration order and then stops paging:

```ts
for (let offset = 0n; offset < ownerCount && dueOwners.length < config.maxOwnersPerReport; offset += ...) {
  const page = readContract(..., "dueOwners", [offset, ...]);
  for (const owner of page) { if (dueOwners.length < config.maxOwnersPerReport) dueOwners.push(owner); }
}
```

`_owners` can never shrink and there is no way to take an owner out of the list (not even by the owner itself; `active=false` leaves him in the list). Five dust owners registered before real users (right now there is 1 owner live, so the first five places are up for grabs) will therefore be at the front forever and due every hour. Every CRE run then contains only those five, and not a single real user is served by the CRE keeper anymore.

**Attack scenario (numbers).**
- Attacker cost: 5 × `setParams` (98,669 gas measured, ≈ €0.001 on Base) + 5 × `approve` + 5 EURC in total. Each dust run sends 100 EURC base units to the swap; after 48 hours a dust owner is at 995,247 of 1,000,000 (0.0048 EURC). With 1 EURC he can keep this up for well over 400 days.
- Revenue for Bitburo: fee = `100 * 25 / 10000 = 0`, treasury after 240 dust runs: 0 EURC (PoC).
- Cost for Bitburo: 5 × ~250,000 gas per hour for nothing (fork: 251,923 gas per successful dust run), plus the reputational damage that "automatic rebalancing every hour" is down for all real customers. The open keeper script remains a way out, but that is exactly the keeper Bitburo does not control.
- Evidence: `PocStarvation.test_poc_dustOwnersStarveRealUserForever` (48 hours simulated, alice with 1,000 EURC is due every hour and never served); `PocFork.test_poc_dustRunSucceedsWithZeroFee` (real Uniswap route: amountIn 100, fee 0, 251,923 gas).

**Existing test coverage.** `test_setParams_boundaryValuesAccepted` actually pins down that `minTradeEurc = 1` and `maxCorrectionBps = 1` are valid. `test_onReport_stopsCleanlyWhenGasRunsOut` and the CRE test "pages through dueOwners and caps the report at maxOwnersPerReport" test the cut-off at five, but not who gets left out over multiple runs. No test with more than five due owners over multiple hours.

**Recommended fix.**
1. Now, without a contract change (the workflow and the script *can* be changed): do not let the CRE workflow always start at offset 0. For example a rotating start offset per run (`(runIndex * maxOwnersPerReport) % ownerCount`, or an offset derived from the block number) and wrap around until the report is full. That way everyone gets a turn, regardless of who is at the front.
2. Now: filter in the workflow and in `keeper.ts` on economic sense: only include owners with `|eurcDelta| >= 20 EURC` (then fee ≥ reward) or at least a fee that covers the gas. `isDue` already returns `eurcDelta`, so that is one extra view call per candidate.
3. Next contract version: a global lower bound `MIN_TRADE_FLOOR` in `setParams` (for example 20 EURC = 20e6, so that fee ≥ `KEEPER_REWARD_EURC`), plus `maxCorrectionBps >= 100` or a lower bound on `total` in `_plan`. Also consider giving `dueOwners` a `startOffset` rotation or a `sinceLastAttempt` filter (see EX-02).

---

## EX-02 — Medium — Owners whose `execute` always reverts stay due forever and waste every keeper's gas

**Lines:** `execute` 300–303 (`lastExecutedAt` is only set after `_plan` and is rolled back on a revert), `_dueAt` 277–284 and `dueOwners` 266 (look only at `_plan`, not at earlier failures), `onReport` 330–333 (`catch` only writes an event), `keeper/keeper.ts` 58–65 (sends without simulation and without memory).

**Description.** `isDue`/`dueOwners` say "yes" as soon as `_plan` gives an `amountIn > 0`. Whether the swap then succeeds, the contract does not know. A revert leaves `lastExecutedAt` at the old value, so the owner stays due; every keeper retries it every run. An attacker can force that deterministically: with 10 EURC base units and the same dust params as EX-01, `cap = max(0, 1) = 1`, so `amountIn = 1`. On the real route the first hop (1 base unit, 0.05% fee) rounds to 0 output, after which the second hop reverts in the Uniswap pool on `amountSpecified != 0`. The run costs the caller 158,398 gas (fork) and changes nothing.

The same pattern arises without malicious intent: an owner blacklisted by Circle (`test_execute_revertsWhenOwnerBlacklisted` shows that `lastExecutedAt` stays 0), an owner with `maxSlippageBps = 30` and a run that structurally gets more than 0.3% slippage in the thin EURC/USDC pool, or an owner with a `total` so small that the output becomes 0.

**Attack scenario (numbers).** Five such owners together cost 50 EURC base units and five registrations. They occupy the CRE slots as in EX-01 (even cheaper: nothing is ever debited from them) and make `keeper.ts` lose 5 × ~160,000 gas every hour without a reward. Whoever runs `keeper.ts` unchanged runs at a structural loss.

Evidence: `PocFork.test_poc_dustOwnerAlwaysDueAlwaysReverts` (isDue true, execute reverts, `lastExecutedAt` 0, isDue still true afterwards).

**Existing test coverage.** `test_execute_lastExecutedAtNotSetOnRevert` and `test_onReport_skipsOnSwapFailure` test that a revert books nothing, but nobody tests that such an owner then stays in `dueOwners` forever or that a minimal amountIn reverts on the real route.

**Recommended fix.**
- Keeper script and CRE workflow: simulate first (`eth_call`/`estimateGas` on `execute`) and keep a cool-down per owner after a failure (for example skip until the next day, increasing exponentially).
- Next contract version: have `onReport` write `lastAttemptAt[owner] = block.timestamp` in the `catch` branch (that is possible, `onReport` itself does not revert) and have `dueOwners` skip owners with a recent failed attempt. The lower bound from EX-01 helps here too: with `minTradeEurc >= 20 EURC` the rounding revert can no longer happen.

---

## EX-03 — Medium (by design, documented) — The caller picks the moment and can sandwich his own `execute`; loss per run bounded by `maxSlippageBps`

**Lines:** `_quoteChecked` 362–367 (spot check 0.5% before the swap), `_buy` 483–484 / `_sell` 503–504 (`minOut` at the oracle price × (1 − `maxSlippageBps`)), `setParams` 201–202 (`maxSlippageBps` 30–100), `_buy` 479 / `_sell` 501 (the Slither "arbitrary-send-erc20" lines).

**Description.** This is the core of the Slither findings `arbitrary-send-erc20`: `safeTransferFrom(owner, …)` with an `owner` chosen by the caller. My judgment: by design and bounded, no theft possible. The only thing a third party can do is choose *when*; amount (`_plan`, bounded by correction, cap, balance and allowance), direction, route, recipient (`recipient: owner` on buys; on sells everything minus the fee goes back via `safeTransfer(owner, …)`) and fee are fixed. Per run the owner can lose at most: fee 25 bps + slippage up to `maxSlippageBps` (30–100 bps) relative to the Chainlink price, and that at most once per `interval` (≥ 1 hour) and only as long as the drift is outside the band.

The interesting detail: the spot check bounds the *pool* before the swap to 0.5% of the oracle, but `minOut` is independently set at oracle × (1 − `maxSlippageBps`). A caller who atomically shifts the pool to just within the 0.5%, calls `execute` and then reverses it, therefore collects (0.5% + the run's own price impact) up to at most `maxSlippageBps`. On Base there is no public mempool, so only the caller himself can do this, and anyone may be the caller.

**Attack scenario (numbers, fork PoC `test_poc_executorSandwich`).** Buyer 20,000 EURC, cap 10% → run 2,000 EURC, `maxSlippageBps = 100`. The attacker sells 7,138 EURC into the EURC/USDC pool (spot +49 bps, check passes), calls `execute(buyer, atk)`, buys the EURC back. Result: buyer receives 2,969,711 sats versus 2,990,521 fair (after fee) = loss of 69 bps ≈ 13.9 EURC; attacker keeps a net 4.72 EURC (including the 0.05 reward, after 2 × 0.05% pool fee on 7,138 EURC). With `maxSlippageBps = 30` this run would simply revert ("Too little received"), so the user sets his own exposure.

**Existing test coverage.** `test_execute_revertsWhenSpotDeviatesFromOracle`, `test_fork_spotDeviationBlocksRun` and `test_execute_revertsOnSlippageBuy/Sell` cover the limits separately. There is no test that pins down the upper bound of the combined loss (spot push + slippage).

**Recommended fix.** No contract change needed; but: (1) have the app set `maxSlippageBps = 30` (or 50) by default and 100 only deliberately; (2) document explicitly in the README that the maximum loss per run is `FEE_BPS + maxSlippageBps` and that the 0.5% spot check is *not* an extra upper bound; (3) in a next version `minOut` can be based on `min(oracle, spot)` or `MAX_SPOT_DEVIATION_BPS` can be placed below `MIN_SLIPPAGE_BPS`, so that the spot check actually bounds the sandwich room.

---

## EX-04 — Low — CRE ↔ open keepers collision; the loser pays a cheap `NotDue`, but the CRE report is used up for nothing

**Lines:** `execute` 293 (`NotDue`), `onReport` 328–334 (no replanning after a `ReportSkipped`), `config.production.json` (`"0 0 * * * *"`).

**Description.** Two keepers aiming at the same owner: the second gets `NotDue`. Measured, that costs 2,615 gas on top of the 21,000 base, so griefing via front-running is economically pointless (Base also has no public mempool). However: if a keeper processes the due owners just before the top of the hour, the CRE report contains five owners that are by then `NotDue`; the CRE run is wasted and the owners that fell outside the report because of it wait an extra hour. No loss of funds.

**Existing test coverage.** `test_execute_revertsNotDue` (contract), no test for a report with only already-executed owners.

**Recommended fix.** The rotation from EX-01 largely solves this; in addition the workflow can count the `ReportSkipped` events and pick a different start offset for the next run when there are many `NotDue`. Possibly do not run the CRE cron at :00.

---

## EX-05 — Low — `TREASURY` on the Circle blacklist = complete standstill of `execute` (unchangeable)

**Lines:** `_takeFee` 530 (`EURC.safeTransfer(TREASURY, fee - reward)`), `sweep` 341, constructor 172 (immutable, no admin).

**Description.** Every run with `fee > reward` (every run from ~20 EURC) sends EURC to `TREASURY`. If Circle blocks that address (or the key is lost), every `execute` reverts and nobody can fix it; users can only revoke their allowance. The same applies to `sweep`. A blacklisted `rewardTo` only affects the caller himself (who picks another address).

**Existing test coverage.** `test_execute_revertsWhenOwnerBlacklisted` covers the owner, not the treasury.

**Recommended fix.** Operational: treasury on a multisig with no other use and a recorded emergency procedure (new deploy + migration of the allowances). Contractual in v2: fee buffer in the contract with a `pull` pattern (`claimFees`), so a failing treasury transfer does not block a run.

---

## EX-06 — Info — Reward and fee: no double skimming, cannot be farmed, but below the gas cost on small runs

**Lines:** `_takeFee` 524–531, `execute` 295 (`rewardTo == address(this)` → 0), `onReport` 330 (`rewardTo = TREASURY`).

**Established safe.**
- `reward = min(50_000, fee)` and the treasury gets `fee - reward`: the reward comes out of the fee, not on top of it. `testFuzz_planBoundedAndAccountingClosed` proves `feePaid == fee` and `reward == min(50_000, fee)`.
- The reward can never be larger than 25 bps of the run and never larger than 0.05 EURC; the full reward requires a run ≥ 20 EURC.
- Farming your own accounts loses money: you pay the fee yourself (for runs < 20 EURC fee = reward, net 0 minus gas and 0.1% pool fee); repeated `execute` is excluded by `interval ≥ 1 h` and `NotDue`; with `onReport` the reward goes to the treasury, so there is nothing to earn via CRE.
- `rewardTo = address(this)` is translated to `address(0)` so no balance gets stuck (`test_execute_rewardToSelfGoesToTreasury`).

**Point of attention.** `keeper.ts` does not filter on size: for a dust owner (EX-01/02) the reward is 0 and the gas ~250,000. Filter on `|eurcDelta|` or the expected fee.

---

## EX-07 — Info — Cadence: the executor cannot run too early or more often, and can only push the cadence later

**Lines:** `execute` 293 and 303, `isDue` 237, `dueOwners` 263.

**Established safe.** `block.timestamp < lastExecutedAt + interval` → `NotDue`, so too early is impossible; `lastExecutedAt = block.timestamp` at the moment of execution, so a late execution shifts the next window by the delay (no catching up, consistent with the app semantics). Keeping an owner "permanently due" is only possible if the drift stays outside the band (then it is the intended corridor behavior, with at most `maxCorrectionBps` of the holdings per run) or via a structurally reverting run (EX-02). `uint64(block.timestamp)` and `uint64 + uint32` cannot overflow. The sequencer, freshness and spot checks are identical in `isDue`, `dueOwners` and `execute` (`_tryQuote` → `quoteChecked`), so the keeper and the contract cannot diverge except through time passing between the view call and the tx.

---

## EX-08 — Info — Reentrancy: covered on all entry points that move value

**Lines:** `execute` 290 and `sweep` 339 (`nonReentrant`, OZ `ReentrancyGuardTransient`, shared transient slot), `onReport` 330 (`this.execute{gas: …}`, external self-call).

**Established safe.** `onReport` has no guard itself, but calls `execute` externally, which *is* protected; `onReport` makes no other external call and is restricted to `FORWARDER` (`msg.sender` check on line 323), so re-entering via a token hook is impossible. EURC (Circle FiatToken), cbBTC and USDC have no transfer hooks; `rewardTo` only receives a `safeTransfer` and cannot call back. `sweep` shares the guard with `execute`, so nobody can sweep away the temporary balance during a run. A revert inside `try this.execute` also rolls back the transient slot (part of the state), so the guard does not stay "on". Base runs Cancun (EIP-1153 available; `foundry.toml` `evm_version = "cancun"`).

---

## EX-09 — Info — `setParams`/`sweep`/registration: nobody can change someone else's settings; `sweep` does not touch user funds, but has two small side effects

**Lines:** `setParams` 206–211 (`params[msg.sender]`), `sweep` 339–342, `_owners` 99.

**Established safe.** Only `msg.sender` can set his own `Params`; there is no `setParamsFor`, no signature path and `onReport` cannot change params. `sweep` sends exclusively to `TREASURY`, the contract never holds a balance outside a tx (`invariant_contractNeverHoldsBalance`) and during a tx the guard blocks. The contract has no allowance whatsoever from users *to third parties*; the `forceApprove` to the router is fully consumed by the router.

**Side effects (no exploit).**
- `sweep(token)` calls arbitrary code with `msg.sender = Rebalancer`. Such a fake token can call `r.setParams(...)` during `balanceOf` and register the contract itself as an owner (`execute(address(r))` ends in `NothingToDo`, balance and allowance are 0). Only pollution of `_owners`, which anyone can pollute anyway.
- EURC/cbBTC a user sends to the contract by accident goes to the treasury, not back to the user. That is policy, but record it.
- There is no `unregister`: `_owners` only grows. Inactive owners cost one SLOAD in `dueOwners`, active ones ~25k gas (two `balanceOf`, two `allowance`); with `PAGE_SIZE 50` a page stays far below RPC limits. The number of view calls per keeper run does grow linearly, without a ceiling (CRE has limits on the number of calls per run; with thousands of fake registrations the CRE run stalls; this amplifies EX-01).

---

## Slither findings, assessed

- `arbitrary-send-erc20` (High, lines 479 and 501): **by design, sufficiently bounded**, see EX-03. The amount is never larger than `min(correction, cap, balance, allowance)`, the output always goes to the owner, the third party only picks the moment; the maximum loss per run is `FEE_BPS + maxSlippageBps`, once per `interval`. Record as "accepted risk" with a reference to the mandate design.
- `incorrect-equality` (`total == 0`, `amountIn == 0`): false positive; these are deliberate sentinels, not comparisons with externally computed values.
- `unused-return` on `ROUTER.exactInput` in `_sell`: not an issue, the output is measured via the `balanceOf` delta (lines 507–516), which is more robust than the return value.
- `reentrancy-events` in `onReport`: only an event after the self-call; no state dependency.
- `timestamp`, `calls-loop`, `naming-convention`, `pragma`: no risks in this context.
- Aderyn: style only (L-1 through L-4).

---

## Test gaps

1. [x] **Economic lower bound is missing entirely**: no test with `minTradeEurc = 1`/`maxCorrectionBps = 1` and a small balance showing that such an owner is due every hour with fee 0 (EX-01), nor a fork test that `amountIn = 1` reverts on the real route (EX-02).
   → Covered: the floor makes the setup impossible. `test_setParams_rejectsMinTradeBelowFloor`, `test_poc_microRunNoLongerPossible`, `test_execute_allowanceBelowMinTradeIsNothingToDo` and fork `test_dustOwnerCannotRegisterAnymore`. EX-02 (`amountIn = 1` on the route) is unreachable: `_plan` sets every run below `minTradeEurc` (≥ 20 EURC) to 0.
2. [x] **Multiple due owners over multiple runs**: all `onReport` tests have ≤ 5 owners in one tx. No test (contract or CRE `main.test.ts`) that pins down that owner number 6+ ever gets a turn.
   → Covered: `test_dueOwners_pagingReachesEveryDueOwner` (12 owners, pages of 5, the last one is executed too). The cap of 5 per report disappeared together with the report path.
3. [x] **Due forever after a revert**: `test_execute_revertsWhenOwnerBlacklisted` and `test_execute_lastExecutedAtNotSetOnRevert` stop at `lastExecutedAt == 0`; they do not assert that `isDue`/`dueOwners` keep offering the owner, and there is no keeper test for repeated loss.
   → Covered: `test_execute_revertsWhenOwnerBlacklisted` also asserts that `isDue` and `dueOwners` keep offering the owner; the keeper script's cool-down is in `keeper/selection.test.ts` („recordFailure doubles the wait per consecutive failure, capped at maxSeconds”).
4. [x] **Upper bound of loss per run**: no fork test combining spot push + slippage and asserting that the owner's loss stays ≤ `FEE_BPS + maxSlippageBps` (EX-03).
   → Covered: fork `test_fork_lossPerRunBoundedUnderSpotPush` (60 and 100 bps, pool pushed beforehand to the edge of the spot check) and unit `testFuzz_poc_lossPerRunBoundedByFeePlusSlippage`.
5. [x] **Treasury blacklist / failing treasury transfer** (EX-05) is untested.
   → Covered: `test_execute_continuesWhenTreasuryBlacklistedAndSweepRecoversFee`, `test_execute_sellRetainsWholeFeeWhenTreasuryBlacklisted`, `test_execute_continuesWhenTreasuryBlacklisted`, `test_poc_blacklistedTreasuryNoLongerBricksExecute`.
6. [dropped] **Report with duplicate or already-executed owners** (EX-04): no test that a duplicate in `report` cleanly gives `NotDue` and the rest continues.
   → There is no report anymore since the CRE surface was removed (a798bde). The equivalent, executing the same owner twice, gives `NotDue` in `test_execute_revertsNotDue`; double registration is impossible (`test_setParams_registersOnlyOnce`).
7. [x] **`sweep` with a malicious token** (EX-09): untested that it can do nothing other than pollute `_owners`.
   → Covered: `test_sweep_maliciousTokenCannotChangeState` (reading `balanceOf`) and `test_sweep_maliciousTokenReentryCanOnlyRegisterItself` (writing `transfer`: `execute` runs into the reentrancy guard, only self-registration succeeds).
8. [dropped] **CRE selection behavior**: `main.test.ts` tests paging and the cap, but not the order dependency (who drops out) and not a filter on `eurcDelta`.
   → The CRE workflow is gone (#2). The keeper script has no cap and walks all pages, so nobody drops out; the filter on `eurcDelta` is `runSizeSkipReason` in `keeper/selection.test.ts` („skips runs below the minimum in both directions”). The paging loop in `keeper.ts` itself is a script without a test setup and remains untested.
9. [x] Foundry gotcha for future time-series tests: under `via_ir` `block.timestamp` is cached within one test function, so `vm.warp(block.timestamp + …)` in a loop has no effect; use `vm.getBlockTimestamp()`. (The current tests warp at most once per test, so this does not affect them.)
   → Not a test gap but a pointer; followed in the time-series tests (`vm.getBlockTimestamp()`, see the header of `test/AuditMath.t.sol`).
