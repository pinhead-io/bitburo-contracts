# Rebalancer: audit and simplification review

17 September 2026, on `development` at `b3ca31a` (the contract before the simplification). Measurements and sketches were made in a scratch copy outside the repository; fork measurements at Base block 51,425,248 through the public RPC.

## 1. Context and conclusion

The project owner suspected that the contract had become needlessly complicated. The brief: look for vulnerabilities, look for what can be simpler, smaller or more efficient (less code means less attack surface), and question earlier decisions as well.

Method: the whole contract read line by line, Uniswap v3-core `d8b1c635` re-read, the app and the keeper script searched for what they actually use, three independent reviewers (a blind audit, an attack on the proposed simplifications, a threat model), five sketches built and measured, three findings proven with a test or a fork measurement.

**Conclusion**

1. **No bug was found that lets user funds leave.** Custody, rounds, arithmetic, the Uniswap assumptions and TickMath hold (checked independently by two reviewers).
2. **Three real findings (Low):** large wallets are structurally under-corrected (A-1), an accepted risk rests on a measurement that does not hold (A-2), and availability hangs on one pool of ~$70k and on block timing that Base changes in October (A-3).
3. **The suspicion was right.** One decision, "anyone may call `execute`", causes most of the code, the keeper complexity and 21 accepted residual risks. The rest is sediment: fixes that stayed after a later fix made them redundant, and configurability the app does not use.
4. **Measured sketches** (they compile with `forge build --sizes`; they were not tested):

   | Variant | nSLOC | Runtime | Lines |
   |---|---|---|---|
   | Before (EURC, two pools) | 613 + 44 TickMath | 17,544 B | 1,063 |
   | Decision-free trims only | 528 + 44 | 16,590 B | 950 |
   | Route P-min with EURC | 357 + 44 | 12,316 B | 446 |
   | Route K with EURC | 219 | 8,053 B | 283 |
   | **Route P-min with USDC**: permissionless, all three layers stay, A-1 and A-2 repaired | **301 + 44 (−47%)** | 10,612 B | 381 |
   | **Route K with USDC**: the owner appoints the keeper | **191, no TickMath, no pool interfaces (−71%)** | 6,208 B | 250 |

5. **USDC makes both routes simpler and better** (§4): one pool, one hop, one price feed, and a pool of ~$8M instead of ~$70k.

**Decisions of the project owner (17 September 2026):** drop the keeper reward; only the target is adjustable per user; the ABI may break (no real users yet); USDC instead of EURC; **route K**; **USDC counts as USD (one feed)**.

## 2. Findings on the contract before the simplification

| ID | Severity | Finding | Evidence |
|---|---|---|---|
| A-1 | Low (functional) | **A correction in chunks stops at the band edge; a correction in one run reaches the target.** A round closes as soon as the estimate lands inside the band (`src/Rebalancer.sol:923`, `:973` at `b3ca31a`). Wallets whose correction exceeds one chunk (~650–800 EURC, so from ~13k EUR at a 5% band) stay up to 5 percentage points away from their target. | `poc/ChunkStopsAtBandEdge.t.sol`, same wallet (100k, 74% cbBTC, target 80%, band 5%): deep pool, 1 run → 79.99%; thin pool, 3 chunks → **75.12%**. `test_chunk_runsUntilWithinBand` pinned this behaviour (`test/BlockWindow.t.sol:624`). |
| A-2 | Low (accepted risk rests on a wrong claim) | **"At the current protocol fee the attacker always loses" does not hold for large runs.** The previous-block push (L-F, I-4, lead 17) was measured at the current fee for 10,000 EURC only; `_largerRuns` sets `feeOff = true` (`audit/2026-09-17-self/poc/Leads17And18Fork.t.sol:369-375`). The cost of the push is fixed, the profit grows with the run, and run capacity grows with liquidity the attacker adds one block earlier. | `poc/LargeRunsCurrentFeeFork.t.sol`, LP 99%, push in EURC/USDC only, current fee, no arbitrage between the blocks: run 10k −17.1 bp · 30k −2.4 · 40k −0.5 · **45k +1.4** · 50k +6.3 · 75k **+17.4** (with feed lag **+31.8**, ≈ +230 EURC). At 75k: LP 50% −3.3 · 75% +0.1 · 90% +11.6. The victim loses 40–90 bp extra, within fee + slippage. Not atomic; needs a wallet ≥ ~450k EUR and $0.4–4.5M of capital for a few blocks. Affected `FINDINGS-STATUS.md:119,:128`, `SCOPE.md:251-253,:301`, `README.md:66-67,:79`. |
| A-3 | Low (availability) | **One pool of ~$70k and Base's block timing decide whether the contract works.** (a) EURC/USDC 0.05% holds 40,115 EURC + 22,550 USDC (on chain, block 51,431,588); there is no other route. If ~97% of that liquidity leaves, every run reverts with `BlockMoveExceeded` for good. (b) The strict block check makes every run depend on "nobody touched the pools in this block yet"; 18% of measured blocks already had activity and blocking costs ~1.8 EUR per hour (L-3), which the app keeper cannot counter through Privy. (c) Base's Denim upgrade (planned for October 2026) moves to five blocks per second with `block.timestamp` in whole seconds and ends Flashblocks. The check then works per second (the safe side), but every failure-rate measurement, the L-3 cost and "next block = +2 s" in both keepers become wrong. | `cast call` on the pool; docs.base.org/upgrades/denim/200ms-blocks; `src/Rebalancer.sol:717`, `:942-945`. |
| A-4 | Info | **`maxSlippageBps` never bound.** The post-swap spot check enforced (1+d)(1+I) ≤ 1.005, so received ≥ 0.99403 × expected: `amountOutMinimum` at 60–100 bp could never bind. The real maximum per run was ~85 bp for everyone, not 0.85–1.25%; `README.md:40` was wrong. | Two reviewers independently; `:647-651` against `:992-993`. |
| A-5 | Info | **The post-swap spot check was redundant since the block window** (added in `69ff682`, before the window `40da5f2`). It only produced the honest-run failures of lead 4. | `:1005`, `:1032`. |
| A-6 | Info | **At a fixed slippage the pre-swap spot check duplicates `amountOutMinimum`** in the adverse direction (d + impact ≤ ~50 bp). On top of that it only blocked runs where the pool stood better than Chainlink. A wrong feed always points in the direction in which the minimum output fails. | Own derivation, confirmed by the threat model. |
| A-7 | Info | **The sell fee on `max(received, expectedOut)` (L-B) had no purpose since L-D** and charged a fee on money the user did not receive; the `maxFee` cap was dead. | `:1034`, `:1055-1057`. |
| A-8 | Info | **Dead or implied code:** `NoOutput` (needs a price above ~1 billion EUR per BTC), the extreme-tick branch and `:808`, `_windowFitsTickSpacing` (two constants), `rewardTo == this`, `reward > 0` / `toTreasury > 0`, `UnexpectedPoolTokens/Fee` and almost every `_requireContract` (implied by `factory.getPool`, `UniswapV3Factory.sol:41,:68`), `description()` in the feed interface. Conversely something was missing: the constructor never called the sequencer feed. | `:1004`, `:723-726`, `:353-355`, `:556`, `:303-311`. |
| A-9 | Info | **Unused freedom.** The app fixes every setting ("nothing here is the user's to choose"); the contract validated 7 fields with 12 bound constants and had two minimums. `dueOwners` and the `RunCaps` cache only served foreign owners in the app keeper; the keeper script did not use them. | App `strategy-card.tsx:549-551`, `mandate-settings.json`; `keeper/keeper.ts:159-175`. |
| A-10 | Info (efficiency) | Four `Math.sqrt` over constants per run, `slot0` read eight times, two fee transfers, three mappings per owner. On Base that is cents; the gain is less code. | `_window`, `_spot`, `_takeFee`. |
| A-11 | Info (operations, docs) | The treasury is an EOA that also owns `retire()`. NatSpec had become an audit log (~350 of 1,063 lines, largely a copy of the README). "A run is only a few hundred EURC" (`SCOPE.md:301`, `README.md:79`) was not a bound: capacity scales with an attacker's liquidity. | – |
| A-12 | Info (route K only) | The app keeper sends through ERC-4337 (EntryPoint v0.7 `handleOps` is `public nonReentrant`, without a restriction on the caller). Whoever holds the signed UserOp can push around it atomically. In route K the keeper must send a plain EOA transaction and pass a tight `minAmountOut`. | EntryPoint v0.7.0 source; read on chain. |

**Checked and fine:** output only goes to the owner; the router only pulls from `msg.sender` and its allowance is 0 afterwards; `amountIn == 0` and SwapRouter02's special recipients are unreachable; `execute` from a pool callback fails on `LOK` (`UniswapV3Pool.sol:615-787`); observations only on a tick change (`:733-735`) and an in-range mint or burn (`:327-341`), at most one per timestamp (`Oracle.sol:90`); the window contains [P(t), P(t+1)] for 605,781 tested ticks; at most one tick boundary per direction; the sign of `liquidityNet`; TickMath equal to v4-core `46c6834`; budget, direction and `setParams` in the rounds; sequencer and staleness checks.

**Not verified:** byte equality of the Base pools with v3-core, the known-bugs list of solc 0.8.37, which bundler Privy uses, the activation date of Denim.

## 3. Earlier decisions reconsidered

| Decision | Verdict |
|---|---|
| `execute` permissionless | **Reversed (route K).** What was rejected before was a *global, irreplaceable* keeper. A keeper the *owner appoints* is replaceable without an admin. Honest callers are in practice only Bitburo and the owner; without a reward the openness mostly serves attackers. |
| Block check + 6 bp window + sizing from liquidity | Each of the three is needed while `execute` is permissionless; no smaller alternative was found (fixed maximum run, commit-reveal, `tx.origin`, opt-in and a minimum output against the block-start price fail or save 25–30% at most and keep L-3). Outside permissionless all of it goes. |
| Spot check before and after the swap | Gone: the contract enforces a symmetric bound on the realised output against Chainlink instead (A-5, A-6). |
| Adjustable slippage 60–100 bp | A constant (A-4). |
| Keeper reward, `rewardTo` | Dropped. Gone with it: the L-D class, the tip cap based on the reward. |
| Sell fee on max(received, expectedOut) | Dropped (A-7). |
| Seven adjustable fields | Only `targetBps`. One minimum instead of two. Irreversible: another profile needs a new deployment. |
| Registry, `owners`, `dueOwners`, cache | Dropped. The keeper serves the owners who appointed it; discovery goes through the `MandateSet` event. The on-chain registry and its spam (lead 9, final-review F-2) are gone; events naming a keeper can still be spammed, which the keeper script bounds by forgetting owners whose mandate does not name it. |
| "Views never revert" | Dropped: `isDue` may revert when the feed fails; Multicall3 with `allowFailure` handles that. |
| Fee straight to the treasury with try-transfer + `FeeRetained` | Replaced: the fee stays in the contract and `sweep(USDC)` collects it. |
| Constructor with 10 error types | Decimals, a live `quote()` and a router with code; the deploy script asserts the rest. |
| `retire()` | Kept. In route K it is the emergency brake. |
| No TWAP, no loss budget, no min/max on feeds | Agreed. |
| EURC as the cash currency, route through the thin EURC/USDC pool | **Replaced by USDC.** The thin pool caused the ~700 EURC chunks and A-3(a). |
| NatSpec as a log | Rationale lives in README; the code says what and why in a few lines. |

## 4. USDC and the two routes

### 4.1 What USDC changes

Verified on chain (Base block ~51,431,600) and in the SwapRouter02 source:

| | Before (EURC) | With USDC |
|---|---|---|
| Route | EURC → USDC → cbBTC, two pools, `exactInput` with a path | USDC ⇄ cbBTC, one pool, `exactInputSingle` (selector `0x04e45aaf` is in the router on Base) |
| Limiting pool | EURC/USDC 0.05%: 40,115 EURC + 22,550 USDC (~$70k) | USDC/cbBTC 0.05%: 3.77M USDC + 50.45 cbBTC (~$8M) |
| Depth | ~215 EURC per bp | ~3,350 USDC per bp (in-range liquidity 2.42e12) |
| Price feeds | cbBTC/USD + EURC/USD + sequencer | cbBTC/USD + sequencer; `price = answer / 100` |
| Pool fee per run | 10 bp | 5 bp |
| Fixed slippage / maximum loss per run | 60 bp / 85 bp | 55 bp / 80 bp |

**USDC counts as USD (one feed).** A USDC/USD feed exists on Base (`0x7e86…bc6B`), but with it the contract would sell cbBTC for sinking USDC during a depeg, as it did for EURC. Without it a depeg slows the contract down: the realised output falls outside the symmetric bound around the Chainlink price and the run reverts, in both directions.

Outside the contract: users then hold dollars (exchange-rate risk for EUR users), the app converts to euro for display, fee income arrives in USDC.

### 4.2 The two routes (with USDC)

**Route P-min (permissionless stays).** `setTarget`, `stop`, `isDue`, `quote`, `execute(owner)`, `sweep`, `retire`. Block check, window, sizing with the cliff fix, rounds and the pre-swap spot check stay, for one pool, with A-1 repaired and a hard `MAX_RUN_USDC`.

**Route K (the owner appoints the keeper), chosen.** `setMandate(targetBps, keeper)`, `stop`, `isDue`, `quote`, `execute(owner, minAmountOut)`, `sweep`, `retire`. Only the owner or their keeper may call `execute`; `minAmountOut` can only tighten the price bound. One run per day, at most 10% of the wallet, realised output within 55 bp of Chainlink. One slot per owner. No pool reads, no TickMath, no rounds, no registry.

| | Before | P-min (USDC) | K (USDC) |
|---|---|---|---|
| Who can sandwich a run profitably | Nobody without LP; a large LP through the previous block from ~45k (A-2) | Measured loss for the attacker in the deep pool; `MAX_RUN_USDC` as a hard bound | Only the appointed keeper (or whoever composes its transactions), bounded by the 55 bp output bound |
| Maximum loss per run against Chainlink | 85 bp (A-4) | 80 bp | 80 bp |
| Extra trust | None | None | The keeper key. On abuse ≤ ~0.055% of the wallet per day and only while the wallet is outside the band; forcing a wallet outside the band costs an attacker ≥ 100× what it yields; every run is visible in `Executed`; `retire()` stops everything |
| Availability | L-3 for 1.8 EUR/hour, 4–11% failures later in the block, Denim rework, pool of $70k | L-3, failures and Denim rework stay; pool of $8M | No block check, no L-3, no Denim dependency; pool of $8M |
| Throughput | ~700 EURC per chunk, one per hour | ~12,500–15,000 USDC per run | One run per day up to 10% of the wallet; from wallets of ~$2M a single run approaches the 55 bp bound |
| New mechanism without production precedent | Yes | Yes | No, a standard pattern |
| Keeper script | ~1,360 nSLOC, fee war | Somewhat smaller, Denim rework | Loop, quote, send |
| Key rotation | n/a | n/a | Users sign again |
| What is given up | – | – | "Anyone can run it" and "Bitburo cannot influence execution" |

**Why K.** The machinery protected an amount in the order of the contract's own fee against an attack that only exists because anyone may call. For that it cost: a mechanism without production precedent, a griefing vector the production keeper cannot counter, 21 accepted residual risks of which one turned out to be wrong (A-2), a functional bug (A-1) and a dependency on block timing that changes within a month. K trades that for one bounded, visible and stoppable point of trust, in less than a third of the code.

## 5. As built

The contract on this branch is route K with USDC, with these refinements over the sketch that was measured in §1:

- Both directions swap into the contract and the output is measured as a balance difference; the contract itself requires it to lie within 55 bps of the Chainlink value in both directions (the router's `amountOutMinimum` is set as well, so too little fails early). The upper bound is what halts the contract during a USDC depeg or with a stuck feed.
- `execute` returns the swap output, so a keeper simulates with `minAmountOut = 0` and then demands that amount minus a small tolerance.
- The band comparison is exact, and a correction larger than the 10% cap is finished on the next days (`unfinished`), so the wallet reaches the target instead of stopping inside the band. Both came out of the independent review of the new code: [`REVIEW-NEW-CONTRACT.md`](REVIEW-NEW-CONTRACT.md).
- Size: 215 nSLOC (was 613 + 44), runtime 6,583 bytes (was 17,544). Gas on the fork: buy ~198k, sell ~209k (was ~400k and ~425k). 84 tests; deep invariants 1000 x 100; Slither and Aderyn triage in [`static/triage.md`](static/triage.md).
- Measured on a fork of block 51,425,248: the 10% run of a wallet of 1, 2 and 3 million USDC lands 0.20%, 0.35% and 0.49% below Chainlink; a 4 million wallet is refused by the bound.

## 6. How to reproduce

- A-1: check out `b3ca31a`, copy `poc/ChunkStopsAtBandEdge.t.sol` into `test/`, run `RUN_FORK=false ~/.foundry/bin/forge test --match-test test_poc_a1 -vv`.
- A-2: check out `b3ca31a`, copy `poc/LargeRunsCurrentFeeFork.t.sol` and `audit/2026-09-17-self/poc/Leads17And18Fork.t.sol` into `test/`, run `FORK_BLOCK=51425248 ~/.foundry/bin/forge test --match-contract LargeRunsCurrentFeeForkPoC --match-test test_poc_a2 -vv`.
- Output of both: `poc/output.txt`.
