# Status of all internal findings

Prepared 17 September 2026 for the external audit, after the contract was rewritten on that day (route K of [`../2026-09-17-simplify/REPORT.md`](../2026-09-17-simplify/REPORT.md)). Scope: [`SCOPE.md`](SCOPE.md).

The earlier version of this file listed 77 rows against the permissionless EURC contract, with `file:line` references into code that no longer exists; it is in the git history at `b3ca31a`. Most of those rows concerned machinery that the rewrite removed. This version says, per class of finding, what became of it. Source keys: `09-15` = `audit/2026-09-15/RAPPORT.md`, `09-16` = `audit/2026-09-16/ai-audit.md`, `PR18` = the review of PR #18, `final` = the final review and its verification, `self` = `audit/2026-09-17-self/ai-audit.md`, `simplify` = `audit/2026-09-17-simplify/`.

`R.sol` = `src/Rebalancer.sol`; tests without a path are in `test/Rebalancer.t.sol`.

## Gone with the permissionless caller

These findings existed because anyone could call `execute` and so sandwich the run they triggered. Only the owner or the keeper that owner appointed can call it now (`R.sol:198`); what a dishonest keeper can do is the accepted risk in SCOPE §2 and §4.1.

| Findings | What they were | Status |
|---|---|---|
| `09-15` M-1, `09-16` M-1, `PR18` M-1, `09-16` lead 2 | The caller sandwiches its own run; push-then-JIT; one push, several victims | obsolete: the caller is no longer arbitrary. Bound for a dishonest keeper: 55 bps per run, enforced on the measured output (`R.sol:302-326`; `test_execute_lowerBound`, `test_fork_pushedPoolAgainstTheRunIsRefused`). |
| `09-15` L-3, `09-16` leads 4 and 8, `final` L3-R, `PR18` I-4 and I-5, `final` F-3, F-4 and F-4m, `self` L-E, L-F, leads 12 to 18, `PR18` L-1, I-2, I-3, `simplify` A-1, A-2, A-3(b), A-3(c), A-4, A-5 | Everything about the block check, the block window, liquidity sizing, the tick-boundary cases, rounds and chunks, the LP-attacker bounds, blocking runs by touching a pool, failure rates per block position, Base block timing | obsolete: block check, window, sizing, TickMath, rounds and the spot checks are removed. The follow-up of a capped correction is now one flag (`unfinished`, `R.sol:262-264`), and it reaches the target (`test_execute_correctionLargerThanTheCapIsFinishedOnTheNextDays`). |
| `09-15` H-2, `09-16` lead 9, `final` F-2, `09-16` L-A, `final` I-2 | Dust owners, registration spam, registry paging, the `dueOwners` cache | obsolete: no registry, no `owners`, no `dueOwners`. The keeper finds owners in the `MandateSet` events and forgets those that do not name it (`keeper/selection.ts` `withoutOwners`). The 20 USDC minimum per run stays (`R.sol:58`). |
| `self` L-D, `09-16` L-B, `final` F-1, I-8, K-1, K-4 | Keeper reward: fee-free trading through one's own keeper, fee floor on sells, tip cap from the reward, `REWARD_TO` validation | obsolete: no reward and no `rewardTo`. The fee is 25 bps of the USDC leg, of what was actually received for a sell (`R.sol:211`, `:219`). |
| `final` K-2, K-3, K-5, K-6, I-5, I-6, `PR18` I-1 | Keeper script: fee escalation, competing keepers, blockade handling, stuck transactions, lock | mostly obsolete with the fee war; the lock (`keeper/lock.ts`), the cool-down, the pending-nonce check and the RPC URL redaction are kept and tested (`keeper/selection.test.ts`, `keeper/lock.test.ts`). |
| `09-15` M-3, L-5, L-6 | Chainlink CRE | obsolete since v1.1.0. |

## Still relevant, and how it stands

| Finding | Status | Evidence |
|---|---|---|
| `09-15` M-2: a delisted or slow feed stops an immutable contract | accepted risk, narrowed | One feed now (cbBTC/USD, heartbeat 20 min); `MAX_FEED_AGE` 1500 s (`R.sol:63`); `test_fork_feedIsFreshAndCloseToThePool`. SCOPE §4.5. |
| `09-15` L-4, `final` I-4: decimals of feeds and tokens | fixed | Constructor checks USDC 6, cbBTC 8, feed 8 (`R.sol:132-134`); `test_constructor_rejectsWrongDecimals`. |
| `09-15` L-9, `self` Info-G: sequencer `startedAt` 0 or in the future | fixed | `R.sol:246-249`; `test_quote_revertsSequencerDown`. |
| `simplify` A-8: the constructor never called the feeds | fixed | `_quote()` in the constructor (`R.sol:135`); `test_constructor_rejectsDeadFeeds`. The deploy script checks pool and feed descriptions (`script/Deploy.s.sol:44-50`). |
| `09-16` lead 1: the monitored pool must be the pool of the swap | obsolete in the contract (it reads no pool); the deploy script asserts the pool the router resolves to | `test_fork_deployScriptChecksAndDeploys`. |
| `09-16` lead 6: no absolute min/max on the feed | accepted risk | A wrong feed makes the run fail one of the two price bounds; `test_execute_upperBoundStopsARunThatIsTooGood`. |
| `09-16` lead 5: `dex_state_price` circularity | accepted risk | Unchanged for cbBTC/USD; a dishonest keeper is already bounded at 55 bps. Still a question to Chainlink. |
| `09-15` ORC-7 / SCOPE §5.8: depeg of the cash token | changed by design | USDC counts as one dollar; a depeg beyond ~0.5% halts both directions instead of selling cbBTC (`test_execute_usdcDepegStopsBothDirections`). |
| `09-15` M-6: a blacklisted treasury bricks runs | fixed by design | No transfer to the treasury inside a run; the fee stays and `sweep` forwards it (`test_execute_continuesWhileTheTreasuryIsBlacklisted`). |
| `09-15` M-5: small wallets can never sell (rounding) | fixed | Rounded-up sell input (`R.sol:292`); `test_execute_sellAtANonRoundPrice`. |
| `09-15` L-1, L-2: micro runs, slippage below what a run needs | fixed by design | One constant minimum of 20 USDC and one constant bound of 55 bps (50 + the 5 bps pool fee). |
| `09-16` L-C: `isDue` reports what `execute` trades | fixed | Same `_plan`; `testFuzz_runMovesTowardsTheTargetWithinTheCap` asserts equality. |
| `09-16` lead 7: front-running a change or revocation | accepted risk | One more run within all bounds, now only by the appointed keeper. README "Changing or revoking is not atomic". |
| `09-16` lead 3: a donation pushes a wallet over the band | accepted risk | It costs more than 5% of the wallet to gain at most 0.055% of it. |
| `09-15` M-4: owners whose run always reverts | fixed in the keeper | Cool-down that doubles per failure (`keeper/selection.ts` `recordFailure`, `failureAction`). |
| `09-15` M-8, M-9: old mandates after a redeploy, no emergency stop | fixed | `retire()` (`R.sol:234-238`); `test_retire_*`, `invariant_noRunAfterRetire`. The legacy contract `0xE577…2104` has no `retire()`. |
| `simplify` A-3(a): one thin pool decides availability | narrowed | The route is one pool of ~$8M instead of ~$70k; still a single route. SCOPE §4.5 and §4.6. |
| `simplify` A-11: the treasury is an EOA that owns `retire()` | open, operational | To decide before the deployment (Safe or hardware key). |
| `simplify` A-12: the app keeper sends through ERC-4337 | open, app | The keeper must send plain transactions with a tight `minAmountOut`; the script in `keeper/` does. |
| `09-15` H-1, M-7, L-7, L-8 | out of scope (app) | As before. |

## New with the rewrite

The independent review of the new contract found nothing above Low; every point and what was done with it is in [`../2026-09-17-simplify/REVIEW-NEW-CONTRACT.md`](../2026-09-17-simplify/REVIEW-NEW-CONTRACT.md). Static analysis: [`../2026-09-17-simplify/static/triage.md`](../2026-09-17-simplify/static/triage.md).
