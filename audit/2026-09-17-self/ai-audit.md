# AI audit Rebalancer — 2026-09-17

Self-audit of `development` after the merge of PR #18. This report builds on `audit/2026-09-16/ai-audit.md` and on the external audit package `audit/2026-09-17/` (`SCOPE.md`, `FINDINGS-STATUS.md`). The package stays unchanged; this self-audit therefore lives in its own folder.

**IDs.** Earlier IDs are reused as `FINDINGS-STATUS.md` names them, prefixed with their source (for example `09-16/lead 5`, `final-review/F-4`, `PR18-review/I-4`). New in this report:
- **L-D, L-E, L-F:** Low. They continue where L-A through L-C of 16 September left off.
- **Info-G, Info-H:** informational. The letter continues after L-F; there is no Info-A through Info-F.
- **Leads 11 through 18:** they continue where leads 1 through 10 of 16 September left off.

Aderyn numbers its own findings H-1 and L-1 through L-4 (`aderyn.md`). Those do not coincide with these IDs.

## Summary

- **No finding of Medium or higher.** The block check, the block window and the Chainlink validation hold up. Nine AI reviewers, the QuillShield oracle checklist, 211 tests and 14 deep invariants found no hole in them.
- **Three new Low findings, none of them with loss for users under the current Uniswap settings:**
  - **L-D (affects the revenue model):** a run at the 20 EURC floor yields nothing for the treasury. An owner who calls `execute` himself with `rewardTo` = himself then trades without a fee. With `maxCorrectionBps` 10 and `minTradeEurc` 20 EURC, every run of a wallet up to 20,000 EURC is such a floor run. Proven with a test: 24 runs, 480 EURC volume, 0 EURC for the treasury. The live contract has this too.
  - **L-E:** if the price sits exactly on a tick boundary, someone can add liquidity in the block of the run without the block check seeing it, contrary to what the NatSpec says. Measured on the fork: the victim gets a slightly better price, the JIT position collects +3.72 bp of the run in pool fees (at the expense of other LPs), and the run ends up at most 1 sat (rounding of the sell) above the in-range upper bound.
  - **L-F:** a Chainlink feed that lags within its threshold widens the accepted push in the previous block (`PR18-review/I-4`, SCOPE §5.3) in this measurement from 40–50 bp to 80–90 bp. Profit for an attacker was measured under three conditions together: protocol fee 0 (now 68), 99% of the liquidity (only 0% and 99% measured), and no arbitrage between the blocks. Then +82.3 bp instead of +44.2 bp. At the current protocol fee, the attacker loses 161 to 485 bp of the run with the largest accepted push and full lag.
- **Two informational points:** Info-G, a Panic instead of `SequencerDown`, and Info-H, an outdated comment in `script/Deploy.s.sol`.
- **Compiler and static analysis:** solc 0.8.37 has 0 known compiler bugs. Slither (39 findings) and Aderyn (1 High, 4 Low) found no real bugs (`triage.md`). Aderyn's "High" in `TickMath.sol` is a false positive.
- **Not done or failed:**
  - **Three of the twelve pashov perspectives are missing.** Numerical-gap, trust-gap and flow-gap stopped twice due to the API safeguard (`reasoning_extraction`).
  - **Echidna and Medusa not run.** That requires a dedicated property harness, and there is none.
  - **No deploy or on-chain change.** Only `cast call`.
- **Status of earlier findings:** `FINDINGS-STATUS.md` lists no open row, and that still holds.
  - **Updated:** the app PRs #146–#150, listed there as OPEN, were merged into app `development` this morning (section [Status of earlier findings](#status-of-earlier-findings)).

## Scope and context

- **Code:** `src/Rebalancer.sol` and `src/libraries/TickMath.sol` on `development`, commit `bab2ed3`, the merge of PR #18 on 2026-09-17 08:18 CEST. `src/interfaces/*` were only read as context. Line numbers in this report refer to `bab2ed3`; `src/` there is byte-identical to the audit commit `05ed03c` from SCOPE §1.1. PR #19 (merge `d8ea8a1`) only added `audit/`.
- **Compiler:**
  - solc 0.8.37, `via_ir = true`, `optimizer_runs = 1000`, `evm_version = cancun` (`foundry.toml`);
  - OpenZeppelin v5.6.1;
  - forge 1.5.1-stable.
- **What the contract does:** a user gives the contract an allowance on EURC and cbBTC and chooses a target allocation. Anyone may call `execute(owner, rewardTo)` as soon as that owner is outside his band. The contract then swaps via two 0.05% Uniswap v3 pools (EURC/USDC and USDC/cbBTC), within a block window of 6 bp and within 50 bp of Chainlink, and withholds a 0.25% fee in EURC. Of that fee at most 0.05 EURC goes to `rewardTo`, the rest to the treasury.
- **Live contract:** `0xE577D68948883FDF8e2694e38dF656D2D9CA2104`, deployed from commit `f8a6d49` (`README.md:11`).
  - **What is missing there:** it has no block window and no `retire()`, so the old M-1 (self-sandwich) is still in it.
  - **Per finding:** below, each finding states whether it also applies live. Checked with `git show f8a6d49:src/Rebalancer.sol` and with `cast call` at block 51,426,659: `KEEPER_REWARD_EURC()` = 50,000 and `MIN_TRADE_FLOOR()` = 20,000,000.
- **Off-chain users of the contract:**
  - **This repo:** `keeper/keeper.ts`, `keeper/selection.ts` and `keeper/lock.ts` (the open keeper).
  - **App repo `pinheadio/bitburo`** (locally `~/Code/bitburo`, `development` @ `bf04fbc`):
    - keeper command: `app/Console/Commands/RunKeeperCommand.php`;
    - event sync: `app/Console/Commands/SweepExecutionsCommand.php`;
    - reading the mandate: `app/Services/Rebalancer/RebalancerMandateReader.php` and `app/Services/Rebalancer/RebalancerClient.php`;
    - ABI: `app/Support/RebalancerAbi.php`, `resources/js/lib/rebalancer-state.ts`;
    - configuration: `config/bitburo.php`.

## Tools used

| Tool | Version / commit | Result | Output |
|---|---|---|---|
| Compiler bug list | `docs/bugs_by_version.json` and `docs/bugs.json` from `argotorg/solidity` | 0 bugs for 0.8.37 | `compiler-bugs.txt` |
| forge test (all suites, fork pinned) | forge 1.5.1 | 211 passed, 0 failed, 0 skipped | `forge-test.txt` |
| Foundry invariants | 1,000 runs × depth 100 | 14 passed | `invariants.txt` |
| Slither | 0.11.6 | 39 findings, no real bug | `slither.txt`, `slither.json`, `triage.md` |
| Aderyn | 0.6.8 | 1 High (false positive), 4 Low (style or intended) | `aderyn.md`, `aderyn-run.log`, `triage.md` |
| pashov/skills `solidity-auditor` | commit `c577eb7` (VERSION 3), model Opus | 9 of 12 perspectives completed | this report |
| QuillShield `oracle-flashloan-analysis` | commit `8bdd3c0` | checklist complete; 1 new Low (L-F), 1 Info (Info-H) | this report, `poc/PrevBlockLagFork.t.sol` |
| keeper `bun test` | bun 1.3.5 | 97 passed, 0 failed | not saved |
| Own PoCs | — | 11 tests passed | `poc/`, `poc/output.txt` |

`audit/run-static.sh` produced the first five rows. The script first stopped on the macOS bash (3.2): an empty array under `set -u`. That was fixed in `cc54fe0`, which now also writes the time and `FORK_BLOCK` to `versions.txt`. The recorded run (started 12:11) ran with that bash fix still uncommitted, before `cc54fe0` (12:14:58); `versions.txt` therefore says `commit: bab2ed3`. The `run at` and `FORK_BLOCK` lines in that `versions.txt` were added by hand, including the end times of forge test and Aderyn (from the file times).

**Perspectives of `solidity-auditor`:**
- **Completed:** math-precision, access-control, economic-security, execution-trace, invariant, periphery, first-principles, asymmetry and boundary. Economic-security succeeded on the second attempt.
- **Missing:** numerical-gap, trust-gap and flow-gap. Each stopped twice due to the API safeguard `reasoning_extraction` (among others request IDs `req_011Cf8qVGrFqEkf8sGJTfd14`, `req_011Cf8qeLEf36RMJ4ZS1hEbf`, `req_011Cf8qeUA9tK4JDn5JGDfpC`). These three are therefore not covered in this round.
- **Each finding** lists the perspectives that found it.

## Compiler

According to `docs/bugs_by_version.json` and `docs/bugs.json`, solc 0.8.37 has no known compiler bugs (`compiler-bugs.txt`, fetched 2026-09-17 12:11; time from `versions.txt`). No upgrade is needed. The six bugs of 0.8.28 were covered in the previous round (`audit/2026-09-16/ai-audit.md`, section Compiler).

---

## Findings

### L-D (Low, confirmed) — Runs at the floor yield nothing for the treasury; an owner who rewards himself trades without a fee

**Where:**
- `KEEPER_REWARD_EURC` (`src/Rebalancer.sol:130`), `MIN_TRADE_FLOOR` (`:138-145`);
- `_takeFee` (`:1020-1031`, reward `:1025-1028`);
- `execute` accepts any `rewardTo`; the contract itself becomes `address(0)`, in which case the whole fee goes to the treasury (`:534`);
- budget of a round `max(total × maxCorrectionBps, minTradeEurc)` (`_plan` `:905`).

**Found by:** boundary, economic-security (as FINDING), first-principles (mentioned as "intended design", but that is not stated in README or SCOPE).

**Cause.** The 20 EURC floor was chosen so that the fee of the smallest run is exactly the reward: 20e6 × 25 / 10,000 = 50,000 (NatSpec `:138-140`). As a result, on every run at the floor the whole fee goes to `rewardTo` and `fee − reward = 0` to the treasury, whoever calls. The caller chooses `rewardTo` freely, so an owner with his own keeper sends the reward to himself and pays no net fee. An owner decides himself that all his runs are floor runs: with `maxCorrectionBps` 10 (the minimum, `MIN_CORRECTION_BPS` `:161`) and `minTradeEurc` 20 EURC (the floor), the budget is `max(total × 0.1%, 20 EURC)`. That is 20 EURC for every wallet up to 20,000 EURC. Larger amounts he can split over several addresses. On larger runs an owner who rewards himself gets 0.05 EURC per run back: for a wallet of 100,000 EURC with `maxCorrectionBps` 10 that is 20% of the 0.25 EURC fee. The only cost for the owner is gas (~475,000 gas per run, `README.md:259`).

README and SCOPE §3.1 only state that "the fee always covers the reward". That the treasury gets nothing on floor runs and that the owner can collect the reward himself is stated nowhere.

**Proof.** `poc/SelfKeeperFeeCapture.t.sol` (mocks, no fork), run 2026-09-17 12:57 from `test/`:

| Test | Setup | Outcome |
|---|---|---|
| `test_poc_selfKeeperTradesFeeFreeAtFloor` | wallet 20,000 EURC, target 80% cbBTC, `maxCorrectionBps` 10, `interval` 1 hour; 24× `execute(alice, alice)` | each run 20 EURC (`isDue` delta 20,000,000); volume 480 EURC; net fee of alice 0; treasury 0 |
| `test_poc_floorRunsYieldNothingForTreasuryWithAnyKeeper` | same wallet, external keeper | keeper 50,000, treasury 0 |
| `test_poc_normalRunStillPaysTreasury` | `maxCorrectionBps` 1000, run 2,000 EURC, owner rewards himself | treasury 4,950,000 (4.95 EURC) |

**Impact.** No loss for users. It does affect Bitburo's only source of income, the 0.25% contract fee (since app PR #150 "Verwijder het abonnement: de contractfee is de enige kosten" ("Remove the subscription: the contract fee is the only cost")):
- **Small wallets with their own keeper** trade fee-free.
- **Larger wallets** can achieve the same by splitting over several addresses.
- **Also with an external keeper** that sets `rewardTo` to its own address, the treasury gets nothing on each floor run. The app keeper does not do that: its Privy policy pins `rewardTo` to the treasury (`app/Console/Commands/SetupKeeperWalletCommand.php:17-20` @ `bf04fbc`), so on its runs the treasury gets the whole fee.

**Live contract:** yes. `f8a6d49` has the same reward, floor and `rewardTo` rule (live `:71`, `:83`, `:340`, `_takeFee` `:599-606`; confirmed on-chain above). On sells it applies live somewhat more often, because the fee there is computed over `received` (`09-16/L-B`).

**Fix (new contract version, not tested; choice for Arjan):**
1. Keep the reward well below the fee of the smallest run, for example `reward = min(KEEPER_REWARD_EURC, fee / 2)`, or raise `MIN_TRADE_FLOOR` to 40 EURC. Then the treasury keeps at least half per run. An owner who rewards himself still pays at least half of the fee.
2. No reward if `rewardTo == owner`. That is only a hurdle: a second address of the owner bypasses it.

Option 1 changes the keeper economics: on a run of 20 EURC a keeper then gets 0.025 EURC. `keeper/keeper.ts` uses the reward in the tip cap (`README.md:259`). Have that calculation change along with it.

---

### L-E (Low, confirmed) — JIT liquidity on the tick boundary writes no observation

**Where:**
- NatSpec layer 1 (`src/Rebalancer.sol:41-43`): "If there is no observation in this block, tick and in-range liquidity are still as at the start of the block: in this block an attacker can at most push within the start tick (≤ 1 tick ≈ 1 bp per pool) and cannot add JIT liquidity in the range" (this report quoted the Dutch NatSpec before the L-E exception was added);
- `_window` (`:688-708`), `_maxInput` (`:781-805`).

**Found by:** execution-trace. The invariant reviewer found the related variant just outside the range, but that one is already known (SCOPE §5.2).

**Cause.** Uniswap v3 counts a position as in range if `tickLower ≤ tick < tickUpper`. A swap that ends exactly on a tick boundary leaves the price at P(b) with tick b − 1 (downward, only if b is initialized; otherwise tick b) or tick b (upward). The PoC therefore first initializes b with a small position.
- **In that state, the following counts as outside the range:**
  - at tick b − 1: a position with lower bound b;
  - at tick b: a position with upper bound b.
- **Consequence for the block check:** a mint then writes no observation, so the block check does not see it.
- **What the run does:** a run in the direction of that position crosses b immediately and trades against that liquidity from the first unit. That liquidity has thus in effect been put in range after all.

For this the attacker has to put the price exactly on P(b) in an earlier block. It is the same class as the accepted "JIT outside the range" (SCOPE §5.2, `README.md:67`), but because of this the NatSpec sentence on `:42-43` is not correct in this state.

**Proof.** `poc/BoundaryJitFork.t.sol`, fork of Base with `FORK_BLOCK=51425248`. The tests run at block number 51,425,250, simulated with two calls to `_nextBlock` (`vm.roll`/`vm.warp`), with the state of block 51,425,248. Run 2026-09-17 12:57, with 99× the active liquidity of EURC/USDC as a JIT position of 50 ticks on boundary b, correction 2,000 EURC:

| Direction | Boundary b | Observation after JIT | Run without / with JIT (EURC) | In-range upper bound (EURC) | Victim without / with JIT | PnL JIT position (excluding reward) |
|---|---|---|---|---|---|---|
| buy (tick = b) | 1380 | no | 642.437568 / 704.508107 | 704.508107 | 962,475 / 1,055,661 sats (per EURC 1,498.2 → 1,498.4 sats) | +0.262427 EURC = +3.72 bp of the run |
| sell (tick = b − 1) | 1370 | no | 525.482378 / 525.482378 | 525.481952 | 523.726785 / 523.806271 EURC | +0.195584 EURC = +3.72 bp of the run |

- **Victim:** never gets less in total with the JIT (asserted, `poc/BoundaryJitFork.t.sol:121-122`). Nor per unit: for the sell the run is equal, for the buy it was computed from the logs (1,498.2 → 1,498.4 sats per EURC), not asserted.
- **Run size:** ends up at most 1 sat above the in-range upper bound. Asserted with `plain.inRangeBound + r.quote() / 1e8`: the sell delta of `isDue` rounds `amountIn` up and was 426 base units (0.000426 EURC) above the bound, for the buy exactly on it. For the buy, the JIT lifts a liquidity cliff up to exactly that upper bound, the behavior from SCOPE §5.2.
- **Profit:** the +3.72 bp is ordinary pool fee (99% × 5 bp × ¾ after the protocol fee) on the victim's volume. It comes at the expense of the other LPs, not of the victim.
- **Different measure than the README:** `README.md:67` says JIT outside the range "yields no profit". That concerns the extra profit of a push given the same JIT; this measurement compares JIT with no JIT, without a push.

**Combination with a push within the tick:** not measured.
- **In the pool with the JIT it is not possible:** a push in the harmful direction from P(b) crosses b immediately, changes the tick and is therefore refused.
- **In the other pool it is:** there the known bound of `final-review/F-4` continues to apply.

**Impact.** No extra loss for users. The NatSpec (`:41-43`), SCOPE §3.3 item 1 and question 1(c) to the auditors assume that JIT in range in the block of the run is impossible. In this edge state it is possible, without harm to the victim.

**Live contract:** n/a. `f8a6d49` has no block check.

**Fix:** documentation only. Add the edge state to the NatSpec (`:41-43`) and to README "JIT outside the range", and mention it with SCOPE question 1(c). A code fix, for example refusing a run when the price sits exactly on an initializable boundary, costs honest runs availability and prevents no loss.

---

### L-F (Low, confirmed) — Chainlink lag widens the push in the previous block

**Where:**
- `_requireSpotNear` (`src/Rebalancer.sol:621-625`) with `MAX_SPOT_DEVIATION_BPS` 50 (`:137`), before and after the swap (`:539`, `:977`, `:1004`);
- `amountOutMinimum` from the oracle (`:965`, `:991`);
- block check `:691`, which does not see a push in block N − 1 (NatSpec `:60-61`).

**Found by:** QuillShield oracle checklist, measured on the fork. Economic-security reported the push by a dominant LP in the previous block as a lead, without the lag.

**Cause.** The spot check compares the pool with Chainlink, not with the market. Chainlink may lag within the deviation threshold: cbBTC/USD 0.3%, EURC/USD 0.1% (Chainlink directory, section Reproducing). If the feed lags in the attacker's favor, that lag adds to the 50 bp tolerance. The accepted push at the end of the previous block (`PR18-review/I-4`, SCOPE §5.3) may then be much larger. SCOPE §5.3 calculates without lag: largest push 25 bp (buy) / 50 bp (sell), LP 99% at protocol fee 0 up to +41.5 bp. That measurement comes from the L-3 research (not in the repo, different block, correction of 10,000 EURC). The measurement below, at block 51,425,248 with a push in EURC/USDC only, gave 50 bp (buy) / 40 bp (sell) and +44.2 bp without lag: the largest push depends on how far the spot was from Chainlink beforehand.

**Proof.** `poc/PrevBlockLagFork.t.sol` (written by the QuillShield reviewer, re-run by me with identical outcome). Fork with `FORK_BLOCK=51425248`, run 2026-09-17 12:57 (first run 12:56 in a scratch copy). The setup:
- **Correction:** 10,000 EURC, `maxSlippageBps` 100.
- **Push:** only in EURC/USDC, in block N − 1, and reversed again after the run.
- **Timing:** `execute` at the top of block N, no arbitrage between the blocks.
- **Lag:** mocked with `vm.mockCall` on `latestRoundData`, cbBTC/USD 30 bp and EURC/USD 10 bp in the attacker's favor.
- **Measures:** "extra profit" is the attacker's profit with push minus the same setup without push, in bp of the run. "Victim extra" is the worse effective price relative to the run without push.

| Attacker | Lag | Largest accepted push | Extra attacker profit | Victim extra | Victim vs. real price (incl. 25 bp fee) |
|---|---|---|---|---|---|
| LP 99%, protocol fee 0, buy | none | 50 bp | **+44.24 bp** | 50.2 bp | 83.0 bp |
| LP 99%, protocol fee 0, buy | 30 + 10 bp | 90 bp | **+82.33 bp** (+82.33 EURC) | 90.6 bp | 123.5 bp |
| LP 99%, protocol fee 0, sell | none | 40 bp | +33.36 bp | 40.0 bp | 81.3 bp |
| LP 99%, protocol fee 0, sell | 30 + 10 bp | 80 bp | +67.32 bp | 79.7 bp | 120.7 bp |
| LP 99%, current protocol fee (68), buy | 30 + 10 bp | 90 bp | −300.0 bp (−300.01 EURC) | 90.6 bp | 123.5 bp |
| no LP, current protocol fee, buy | 30 + 10 bp | 80 bp | −485.2 bp (−5.98 EURC on a run of 123.2 EURC) | 80.3 bp | 113.5 bp |

All lines are in `poc/output.txt` (prefix `PBL,`). A push above the largest accepted push reverts with `SpotDeviatesFromOracle` (`0x1b3ce45e`).

**Impact.**
- **At the current protocol fee** nobody makes a profit: with full lag the attacker loses 161 to 485 bp of the run (buy 300–485 bp, sell 161–271 bp; `poc/output.txt`) to make the victim trade ~80–90 bp worse. That is griefing at his own loss.
- **At protocol fee 0 (hypothetical)** with 99% of the liquidity and without arbitrage, the accepted residual profit from SCOPE §5.3 roughly doubles.
- **Loss bound:** the bound `FEE_BPS + maxSlippageBps` applies relative to the lagging feed, not relative to the market. Measured up to 123.5 bp relative to the real price; theoretically up to 125 bp plus the lag of ~40 bp.
- **Not measured:** a push in both pools with lag (lead 17).

**Live contract:** yes, and more severe there. `f8a6d49` has no block check, so the push in the same block (the old `09-16/M-1`) also gets the lag added there (`09-16/M-1`, table "0.3% too high": up to +18.71 EURC).

**Fix:** documentation. Add the lag term to SCOPE §5.3, README "Not covered" and the NatSpec `:60-61`, and add a question for the auditors: SCOPE §6 has no question about §5.3 (question 2 is about §3.3 and §5.4). Lowering `MAX_SPOT_DEVIATION_BPS` reduces the room, but makes honest runs revert more often (SCOPE §4.5: > 50 bp in 0.14% of the hourly measurements). The cost of that has not been measured.

---

### Info-G — Sequencer feed with `startedAt` in the future gives a Panic instead of `SequencerDown`

**Where:** `_quote` `src/Rebalancer.sol:602`: `block.timestamp - seqStartedAt < GRACE_PERIOD` without the check `seqStartedAt > block.timestamp`. For the price feeds that check is present (`_readFeed` `:815`).

**Found by:** access-control, math-precision, asymmetry, first-principles, economic-security.

**Impact:**
- **`execute`:** reverts with Panic 0x11 instead of `SequencerDown`.
- **`isDue` and `dueOwners`:** catch the error via `_tryQuote` (`:821-827`).
- **`keeper/selection.ts`:** does not count `SequencerDown` as a temporary failure (`isTemporaryFailure` `:53-54`). An unknown Panic therefore gets the same treatment; the asymmetry reviewer's claim that the keeper reacts differently because of this is not correct.
- **Can it happen?** Not checked whether the uptime feed on Base ever gives a `startedAt` after the L2 timestamp.
- **Live:** yes (live `:403`).

**Fix:** add `seqStartedAt > block.timestamp ||` to the condition on `:602`.

### Info-H — Outdated comment in the deploy script

**Where:** `script/Deploy.s.sol:26-27`: "The previous feed 0xDAe398…8250 (24 h) is no longer in the directory".

**Found by:** QuillShield oracle checklist. Checked by me in the JSON of the Chainlink directory on 2026-09-17 12:58: `0xDAe398520e2B67cd3f27aeF9Cf14D93D927f8250` is still listed, as "EURC / USD", heartbeat 86,400 s, threshold 0.3.

**Impact:** none. The conclusion still holds: `MAX_AGE_EURC` 4,500 s (`src/Rebalancer.sol:176`) would reject that feed immediately.

**Fix:** change the sentence to "has a heartbeat of 24 hours".

---

## Leads (check by hand)

11. **Round budget does not scale with the wallet** (execution-trace, invariant).
    - **What:** in a chunk the budget is `rounds[owner].remainingEurc` (`:900-903`), fixed at the first run.
    - **Example:** wallet 1,000,000 EURC, `maxCorrectionBps` 1000, budget 100,000 EURC. The first run does 30,000 (liquidity), 70,000 budget remains. The owner then withdraws funds down to 100,000 EURC, still 40% off target: correction = 40% × 100,000 = 40,000. Subsequent chunks may then go up to min(40,000, 70,000, liquidity), more than the 10% × 100,000 = 10,000 a new round would get.
    - **Who can do it:** only the owner himself (withdrawing), or the price.
    - **Direction and bounds:** each chunk goes toward the target and stays bounded by band and window.
    - **Documentation:** SCOPE §3.4 mentions the fixed budget "also after a donation", but not the shrinking.
    - **To decide:** document, or also bound the budget in a chunk by `max(total × maxCorrectionBps, minTradeEurc)`.
12. **Round stays open when the price brings the owner back within the band by itself** (access-control). Until `interval`, a chunk remains possible every `CHUNK_INTERVAL` if the deviation returns in the same direction. Already known: SCOPE question 4 ("does not close the round on-chain") and `PR18-review/I-3` (accepted). No new action.
13. **`MAX_BLOCK_MOVE_BPS < TICK_SPACING` is only stated in a comment** (first-principles). `_maxInput` assumes at most one initializable boundary in the window (NatSpec `:151-153`, `:776-779`). Holds for 6 < 10; a later version with different constants would silently break this. Hardening: a check at compile or constructor time.
14. **LP forces chunks by removing liquidity** (first-principles). A large LP removes liquidity in block N − 1, so the run is bounded by liquidity and opens a round. Fee and budget stay proportional; loss for the owner not demonstrated, only influence on the timing.
15. **Sell input can exceed the `_maxInput` estimate by up to 1 sat plus ~0.5%** (math-precision).
    - **Cause:** `wantBtc` rounds up (`:930`), and the USDC on hop 1 is valued at the pool price, not at the oracle.
    - **Safety net:** the 25% margin in `SIZING_BPS` absorbs it, and the window is checked again after the swap (`:562-563`).
    - **Seen in L-E:** the sell delta was 426 base units above the in-range upper bound.
    - **Not demonstrated:** a run that fails because of this.
16. **Assumptions about the pools and the chain** (periphery).
    - **Unmodified v3 code:** the block check assumes the pools on Base run unmodified v3-core code. Demonstrated per action on the fork with `test_observationSemantics_perAction` (`test/BlockWindowReviewFork.t.sol:525`).
    - **Unique timestamp per block:** the check also assumes that every block has its own timestamp. If two blocks share one, the check merely refuses too often (first-principles), and that is safe.
17. **L-F with a push in both pools** (QuillShield). Only EURC/USDC was pushed; the size and profit with an additional push in USDC/cbBTC were not measured.
18. **Lag plus push within the tick, for an LP attacker** (QuillShield). The lag barely changed the execution price: the rows with and without lag gave the same price at the same push for buys and up to 0.1 bp difference for sells (for example 81.25 / 81.18 / 81.15 bp at a push of 40 bp). Therefore no new effect is expected, but for an LP attacker this has not been measured separately.

## Noted, no impact

- **Fee rounds down** (`:1024`, math-precision). Difference less than 1 EURC base unit per run, in the owner's favor.
- **After `retire`, revoking still requires sending valid params, and registering remains possible** (asymmetry). Correct in the code (`:375-384`); the registering is already in the report of 16 September (`audit/2026-09-16/ai-audit.md:129`), the revoking with valid params is not.
- **Gas starvation of `trySafeTransfer`** (boundary, periphery, execution-trace, invariant). Whoever lets the treasury transfer run out of gas keeps ~1/64. That is too little for the rest of `_sell` or `_buy`, so the whole transaction reverts.
- **Push by a dominant LP in the previous block** (economic-security). That is `PR18-review/I-4` and SCOPE §5.3, extended with the lag in L-F.

## Checked and in order

- **Block check.** Tested against Uniswap v3-core `d8b1c635` (QuillShield: `UniswapV3Pool.sol:327-348`, `:715-760`, `Oracle.sol:90`; execution-trace, invariant, asymmetry, boundary):
  - **When an observation is written:** every tick change and every mint or burn in range writes one, at most one per block.
  - **Pushing back hides nothing:** pushing there and back within one block writes an observation.
  - **Edge state with a swap:** with the price at P(t) and tick t − 1, a swap upward crosses immediately (observation), and downward it stays in t − 1.
  - **Exceptions:** only the known push within the tick (`final-review/F-4`), JIT outside the range (SCOPE §5.2) and L-E.
- **Window arithmetic** (math-precision, periphery, asymmetry, first-principles, boundary):
  - the lower and upper bounds round toward a narrower window;
  - downward at most ticks t through t − 5 can be crossed, upward t + 1 through t + 5 (1.0001^6 = 1.00060015), so at most one multiple of 10 per direction;
  - the boundary determination for negative ticks is correct (−5 → −10, −15 → −20), as is the one for a price exactly on a boundary.
- **Liquidity beyond the boundary:** `min(L, L ± liquidityNet)` never makes a run larger. A mint or burn in range writes an observation.
- **`_convert` and `_spot`:** no overflow at sqrtPriceX96 = 2^160 − 1; `ratioX128 ≥ 1` for every valid price. The token order flags are correct in all four hops.
- **Fee accounting:**
  - `reward + treasury + retained == fee`;
  - every run is at least the floor, so fee ≥ 50,000, also on sells (fee base `max(received, expectedOut)`);
  - `received` is a balance difference and does not count retained fee.
- **Router:** approvals for exactly the swap amount; `amountIn` = 0 (the sentinel `CONTRACT_BALANCE`) is unreachable; recipient `address(1)` or `address(2)` cannot be an owner.
- **Reentrancy:**
  - `execute` and `sweep` share the transient lock;
  - EURC and cbBTC have no hooks;
  - calling `execute` from a swap or flash callback of a pool reverts, because that pool is then locked (LOK).
- **Views do not revert:** feed, sequencer and spot errors via `try this.quoteChecked()`, and there is no division by zero or overflow in `_maxInput`.
- **USDC depeg:** cancels out in the combined spot. Both pools quote against USDC, so EURC/USDC × USDC/cbBTC = EURC/cbBTC (economic-security).
- **Chainlink validation** (QuillShield checklist, all items PASS or N.A.):
  - `answer > 0`, no `updatedAt` in the future, `MAX_AGE_CBBTC` 1,500 s ≥ heartbeat 1,200 s, `MAX_AGE_EURC` 4,500 s ≥ heartbeat 3,600 s;
  - decimals 8, sequencer up plus 1 hour grace, `startedAt != 0`;
  - `answeredInRound` rightly absent.
  - **Update cadence:** QuillShield measured via `getRoundData` a largest gap between updates of 1,232 s (cbBTC/USD, 400 rounds) and 3,636 s (EURC/USD, 150 rounds), both below the maximum age. Not repeated by me.
- **Interfaces:** `slot0` (7 fields), `ticks` (8), `observations` (4) and `liquidityNet` as `int128` match the v3 ABI.
- **`TickMath.getSqrtPriceAtTick`:** identical to Uniswap v4-core `46c6834`, apart from the revert style (`triage.md`).

## Fuzzing

- **Foundry invariants, deep:** 14 of 14 passed at 1,000 runs × depth 100. These are the 7 invariants in two handler setups: `RebalancerInvariantTest` and `RebalancerInvariantTestNoRetire`. Output in `invariants.txt`.
- **Echidna and Medusa:** not run. Echidna's foundry mode does not work with this handler; that became clear on 2026-09-16 (`audit/2026-09-16/ai-audit.md`, section Fuzzing: `allContracts` calls mocks directly, `filterFunctions` barely reaches the handler). There is no dedicated property harness yet; pashov `fizz` can generate one, and that requires approval first.

## Reproducing

All commands from the root of `bitburo-contracts`, on `development` from `d8ea8a1` (merge of PR #19; the branch `chore/audit-2026-09-17` has been deleted). The code under test (`src/`, `test/`, `script/`, `keeper/`) is identical to `bab2ed3`.

**Requirements:**
- Foundry (`~/.foundry/bin/forge`, `cast`), `slither`, `aderyn`, `gh` (logged in: `run-static.sh` fetches the compiler bug list with `gh api`) and `python3` (`run-static.sh` checks for them), and bun for the keeper.
- `.env` in the root with `BASE_RPC_URL`: an RPC for Base that serves historical state (archive). There is no `.env.example`; only that one variable is needed. `.env` is in `.gitignore`.
- OpenZeppelin submodule: `git submodule update --init lib/openzeppelin-contracts`.

```bash
# Deterministic steps (compiler bugs, tests, invariants, Slither, Aderyn)
set -a; source .env; set +a                 # BASE_RPC_URL; do not print the value
# To a new folder; audit/2026-09-17-self contains the recorded output (versions.txt was completed by hand)
FORK_BLOCK=51425248 bash audit/run-static.sh audit/2026-09-17-self-rerun

# Keeper
(cd keeper && bun install && bun test)

# PoCs: copy to test/, run, remove again
cp audit/2026-09-17-self/poc/*.t.sol test/
RUN_FORK=false ~/.foundry/bin/forge test --match-contract SelfKeeperFeeCaptureTest -vv                       # L-D
FORK_BLOCK=51425248 ~/.foundry/bin/forge test --match-contract BoundaryJitForkTest --match-test boundaryJit -vv   # L-E
FORK_BLOCK=51425248 ~/.foundry/bin/forge test --match-contract QuillPrevBlockLagTest -vv                     # L-F
rm test/SelfKeeperFeeCapture.t.sol test/BoundaryJitFork.t.sol test/PrevBlockLagFork.t.sol
```

**Pitfalls:**
- `forge` on the PATH is Laravel Forge; use `~/.foundry/bin/forge`. `run-static.sh` puts Foundry first itself.
- `BoundaryJitForkTest` inherits from `BlockWindowReviewForkTest`. Without `--match-test boundaryJit` all 16 inherited fork tests run as well.
- The PoCs only compile in `test/`, because they import `./Rebalancer.t.sol`, `./BlockWindowFork.t.sol` or `./BlockWindowReviewFork.t.sol`.
- Fork tests without `FORK_BLOCK` fork the latest block, and the numbers then shift per run. The RPC must serve historical state for block 51,425,248; `https://mainnet.base.org` is rate-limited.
- Under `via_ir`, Solidity caches `block.timestamp` in a test function. After `vm.warp` use `vm.getBlockTimestamp()`.
- `run-static.sh` on the macOS bash only works from `cc54fe0` onward.

**Measurements and times (CEST, 2026-09-17):**
- `run-static.sh`: started ~12:11, forge test done ~12:12:58, Aderyn ~12:13:34. Put into `versions.txt` by hand from the file times (last write time) of the output, so approximate; the invariants alone took 33 s (`invariants.txt`).
- PoCs: L-F at 12:56 in a scratch copy, then all three together from `test/` in this repo at 12:57, at `FORK_BLOCK=51425248`. `poc/output.txt` is the output of that last run (without timestamps; times from the file times).
- `cast call` on the live contract: block 51,426,659.

**External sources** (consulted on 2026-09-17, not stored in the repo):
- **Compiler bugs:** `https://github.com/argotorg/solidity/blob/develop/docs/bugs.json` and `docs/bugs_by_version.json`.
- **Yul `shl` and `shr`:** `docs/yul.rst:809`, `:811` in `github.com/argotorg/solidity` (blob `f36a29e`).
- **Uniswap v4-core `TickMath.sol`** at commit `46c6834`: `github.com/Uniswap/v4-core`.
- **Uniswap v3-core** `UniswapV3Pool.sol` and `Oracle.sol` at commit `d8b1c635`: `github.com/Uniswap/v3-core` (read by the QuillShield reviewer).
- **Chainlink feeds on Base:** `https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json`, the data behind `https://docs.chain.link/data-feeds/price-feeds/addresses?network=base`.
  - cbBTC/USD `0x07DA…9f9D`: heartbeat 1,200 s, 0.3%.
  - EURC/USD `0x9867…01e0`: 3,600 s, 0.1%.
  - EURC/USD `0xDAe3…8250`: 86,400 s, 0.3%.

**Repeating the AI reviews:**
- **pashov:** `git clone https://github.com/pashov/skills` (used: `c577eb7`). Follow `solidity-auditor/SKILL.md` with the files `src/Rebalancer.sol` and `src/libraries/TickMath.sol`. The outcome differs per run.
- **QuillShield:** `git clone https://github.com/quillai-network/quillshield_skills` (used: `8bdd3c0`). Follow `plugins/oracle-flashloan-analysis/skills/oracle-flashloan-analysis/SKILL.md` and read the `references/` folder next to it; `install.sh` does not copy it. Ignore `answeredInRound`.

**Not saved:**
- the full transcripts of the AI reviewers;
- the output of `bun test`;
- the raw `getRoundData` series of the cadence measurement (QuillShield);
- the first, partly failed run of `run-static.sh`, which stopped after the compiler bug check.

## Status of earlier findings

`audit/2026-09-17/FINDINGS-STATUS.md` (64 rows, "No row is open") applies to `05ed03c`. `src/`, `test/`, `script/` and `keeper/` at `bab2ed3` are identical to it (SCOPE §1.1). What changed since then, checked on 2026-09-17 with `gh pr view <n> --repo pinheadio/bitburo --json state,mergedAt`:

| Row in FINDINGS-STATUS | Was | Now |
|---|---|---|
| `09-15/H-1` (#147, #150), `09-15/M-7` (#148), `09-15/M-9` (#147, #148), `09-15/L-7` (#148), `09-15/L-8` (#146), `L3-research/L3-R` (#149) | app PRs OPEN | #146, #147, #150 merged 08:18–08:33, #148 at 08:23, #149 at 09:29 (CEST), all in app `development` (@ `bf04fbc`). Not checked on app `production`; nothing verified in production. |
| `final-review/F-4`, `PR18-review/I-4` (SCOPE §5.3, §5.4) | accepted | L-F adds the lag term to `PR18-review/I-4`. Reassess whether the acceptance stands. |
| SCOPE §5.2 (JIT outside the range) | accepted | L-E is an edge state of the same mechanism. Add to NatSpec and README. |

No earlier finding was reopened by this round.

## Next steps

1. **Decide on L-D (Arjan).** Choose between reward ≤ fee / 2, a higher `MIN_TRADE_FLOOR`, no reward for `rewardTo == owner`, or accepting it. A code fix requires a new contract version and an adjustment of the tip cap in `keeper/keeper.ts` (`README.md:259`). Do it on a new branch from `development`, with a test modeled on `poc/SelfKeeperFeeCapture.t.sol`, but with asserts on the chosen behavior.
2. **Update documentation** (same branch or a separate branch from `development`):
   - **L-E:** NatSpec `src/Rebalancer.sol:41-43`, README "JIT outside the range" (`README.md:67`), SCOPE §3.3 item 1 and question 1(c).
   - **L-F:** NatSpec `:60-61`, README "Not covered" (`README.md:63`), SCOPE §5.3 and a new question in §6.
   - **Info-H:** `script/Deploy.s.sol:26-27`.
   - **Lead 11:** SCOPE §3.4, after the decision in step 4.
   - **Audit package:** the external auditor receives `audit/2026-09-17/`. Include these points there or add this report, otherwise he will miss them.
3. **Include Info-G** in the next contract version (one condition on `:602`), with a test modeled on `test_execute_revertsSequencerDownWhenStartedAtZero` (`test/Rebalancer.t.sol:577`).
4. **Review leads 11, 13, 14, 15, 17 and 18** one by one and decide: fix, document or reject. Lead 11 first, because step 2 depends on it. Leads 17 and 18 can be extended in `poc/PrevBlockLagFork.t.sol`. Lead 12 is already accepted and lead 16 already tested on the fork: no action needed there.
5. **Retry the three missing pashov perspectives** (numerical-gap, trust-gap, flow-gap) later, for example with a different model. Or let the external audit cover that.
6. **New deploy: only with Arjan's explicit approval.**
   - **Still missing live:** the live contract `0xE577…2104` (`f8a6d49`) has no block window (`git show f8a6d49:src/Rebalancer.sol`, no `observations`) and no `retire()` (`README.md:14`). The old `09-16/M-1`, L-D, L-F (more severe) and Info-G still apply there.
   - **Runbook:** first read the runbook in issue #7 of `pinheadio/bitburo-contracts`.
   - **Pitfall `broadcast/`:** `deploy-mainnet.sh go` refuses as long as `broadcast/` already contains a deploy, unless `FORCE_REDEPLOY=1` (`deploy-mainnet.sh:82`). `broadcast/` is in `.gitignore`, so a fresh clone behaves differently.
   - **Update the app after the deploy:**
     - `BITBURO_REBALANCER_ADDRESS` and `BITBURO_REBALANCER_DEPLOY_BLOCK`;
     - the old address in `BITBURO_REBALANCER_LEGACY_ADDRESSES` (`config/bitburo.php`);
     - `REBALANCER` for `keeper/keeper.ts`;
     - `php artisan bitburo:setup-keeper-wallet --update`: the Privy policy of the app keeper pins the contract address and must be redone after every change of `BITBURO_REBALANCER_ADDRESS` (signature in `app/Console/Commands/SetupKeeperWalletCommand.php:45`).
7. **External audit** on the version that comes out of steps 1 through 3, with this report as a supplement to `audit/2026-09-17/`.
