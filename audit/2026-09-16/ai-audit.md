# AI audit Rebalancer — 2026-09-16

Self-audit ahead of the external audit. This report builds on `audit/2026-09-15/RAPPORT.md`. The IDs H-n, M-n and L-n refer to the summary table of that report; L-A, L-B and L-C are new. Note: the detailed reports in `audit/2026-09-15/details/` and code comments in the app use their own numbering (for example `M-01`, `ORC-1`), and Aderyn also numbers its own findings L-1/L-2. Those do not coincide with the IDs in this report.

## Summary

- **In this round, one open issue with loss for users found in `src/`: M-1 (Medium).** Whoever calls `execute` can still profitably sandwich their own run. The post-swap check reduces the profit, but does not close it. Confirmed with fork tests.
- **Three minor points (Low), without loss:** L-A, L-B, L-C.
- **Compiler from 0.8.28 to 0.8.37**, six known compiler bugs gone. The contract was probably affected by none of them.
- **Ten leads** to check by hand, plus what was checked and found in order.
- **Status of the 2026-09-15 report** (see [Status of findings 2026-09-15](#status-of-findings-2026-09-15)): 9 fixed (H-2, M-2, M-4, M-5, M-6, L-1, L-2, L-4, L-9), 6 partially fixed (H-1, M-7, M-8, M-9, L-7, L-8), 2 open (M-1, L-3), 3 obsolete with CRE (M-3, L-5, L-6). The contract fixes are also in the live contract; only `retire()` is missing there. The app fixes are on `development`, but not yet on app `production`. None of the Privy policies has been verified live.

## Scope and context

- **Code:** `src/Rebalancer.sol` on branch `chore/solc-0.8.37` (branched off `development`), commit `48cc7f9` (solc 0.8.37, `via_ir = true`, `evm_version = cancun`, OpenZeppelin 5.6.1). Line numbers in this report refer to that commit.
- **What the contract does:** users give it an allowance on EURC and cbBTC and set a target allocation with `setParams`. Anyone may call `execute(owner, rewardTo)` as soon as an owner is due. The contract prices the wallet with Chainlink (cbBTC/USD and EURC/USD), checks that the spot price of the supplied Uniswap v3 pools EURC/USDC and USDC/cbBTC is within 0.5% of that price, and swaps via SwapRouter02 over the path with fee tier 500 (0.05%). The contract does not enforce that the checked pools are also those 0.05% pools (see lead 1). It withholds a 0.25% fee in EURC; of that the caller gets at most 0.05 EURC and the rest goes to the treasury.
- **Live contract:** `0xE577D68948883FDF8e2694e38dF656D2D9CA2104`, deployed from commit `f8a6d49` (solc 0.8.28, still without `retire()` and with the CRE surface; see `README.md`). Checked with `git show f8a6d49:src/Rebalancer.sol`: **M-1, L-A, L-B and L-C are also in the live contract.** A fix therefore requires a new deploy.
- **Keepers:** there are two external alarm clocks that read `dueOwners`/`isDue` and call `execute`: `keeper/keeper.ts` in this repo and `app/Console/Commands/RunKeeperCommand.php` in the app repo `pinheadio/bitburo` (locally `~/Code/bitburo`). Paths starting with `app/` or `config/` are relative to that app repo. Chainlink CRE no longer exists (removed in v1.1.0).

## Tools used

| Tool | Version | Result | Output |
|---|---|---|---|
| Slither | 0.11.6 | 30 findings, all by design or false positive | `slither.txt`, `triage.md` |
| Aderyn | 0.6.8 | 0 High, 2 Low (large numeric literal: style; unchecked return: by design) | `aderyn.md`, `triage.md` |
| pashov/skills `solidity-auditor` | commit `c577eb7` | 11 of 12 perspectives completed (model Opus); flow-gap failed twice due to an API error | this report |
| QuillShield `oracle-flashloan-analysis` | commit `8bdd3c0` | Chainlink validation fully in order, sandwich check fails | this report |
| Echidna | 2.3.3 | Not usable with this test handler | `echidna/*.yaml`, see [Fuzzing](#fuzzing) |
| Foundry invariants | forge 1,000 runs × depth 100 | 5/5 green | see [Fuzzing](#fuzzing) |

`solidity-auditor` has twelve parallel AI reviewers each look at the code from one perspective: math-precision, access-control, economic-security, execution-trace, invariant, periphery, first-principles, asymmetry, boundary, numerical-gap, trust-gap, flow-gap. For each finding below, the perspectives that found it are listed. The more often, the more independently confirmed.

## Compiler (fixed in this branch)

Solc 0.8.28 has 6 known compiler bugs, all fixed in 0.8.37 (source: `docs/bugs_by_version.json` and `docs/bugs.json` in `github.com/argotorg/solidity`). The most severe is **SOL-2026-1 TransientStorageClearingHelperCollision** (high, via-IR + cancun, 0.8.28–0.8.33). It occurs when the same bytecode both does `delete` on a variable with the `transient` keyword and clears storage (`delete`, `pop()`, assigning a shorter array).

- **Current code and live code (`f8a6d49`):** no `delete`, `pop()` or `transient` keyword in `src/` (`git grep`). OpenZeppelin `ReentrancyGuardTransient` uses `TransientSlot` (assembly `tstore`), not the keyword. So probably not affected.
- **Commit `48cc7f9`** sets `foundry.toml` and all pragmas to 0.8.37; 127/127 tests green.
- The PoCs in `audit/2026-09-15/poc/` deliberately remain on 0.8.28 (snapshot).

---

## Findings

### M-1 (Medium, confirmed, still open) — Caller can profitably sandwich their own `execute`

**Where:** `execute` → `_buy`/`_sell`, with `_requireSpotNear` (`src/Rebalancer.sol:395`, `:539`, `:564`) and `minOut` (`:527`, `:551`).
**Found by:** QuillShield oracle checklist (proven on fork), economic-security, access-control, invariant, first-principles, execution-trace.

**Cause.** The spot check both before and after the swap allows 50 bps deviation from the Chainlink price (`MAX_SPOT_DEVIATION_BPS`, `:73`). `minOut` is 60–100 bps below the Chainlink price. In one transaction an attacker does: push the pool → `execute(victim, himself)` → push the pool back. As long as his push plus the victim's own price impact stays below 50 bps, everything succeeds and he keeps a profit. The NatSpec (`:33`) and `README.md:41` say the post-swap check "largely closes" that profit margin; that is not correct. The existing test `test_poc_selfSandwich_10k_slippage100` only confirms that a maximal push on a run of 10,000 EURC is not profitable; it does not test partial pushes. The documented loss bound per run (`FEE_BPS + maxSlippageBps` relative to Chainlink) does still hold.

**Proof.** Fork tests against Base mainnet at the latest block. The numbers therefore shift per run with the pool state.

*Sell runs* — `test/OracleSandwich.t.sol::test_poc_sweepSell`, run 2026-09-16 ~13:59. Per wallet the test first logs `EURC value of position` (the whole cbBTC position) and `baseline EURC received` (the run: 20% of the position; labels as translated on 17 Sept 2026, originally Dutch). The table uses the latter value. The test has no asserts; it is a measurement:

| Run (EURC received without attack) | Push (USDC) | Attacker profit | Victim loss |
|---|---|---|---|
| 4,929 | 2,099 | +3.55 USDC | 4.82 EURC |
| 4,929 | 4,198 | +7.80 USDC | 10.30 EURC (21 bps) |
| 2,466 | 6,298 | +2.51 USDC | 7.56 EURC |
| ~990 | all | loss | — |

*Buy runs, best push per run size* — `audit/2026-09-16/poc/OracleLagSandwich.t.sol`, run 2026-09-16 ~14:20, `maxSlippageBps` 100, profit including the 0.05 EURC reward:

| Run (EURC) | Chainlink cbBTC/USD | Best push (EURC) | Attacker profit | Victim loss |
|---|---|---|---|---|
| 2,500 | current | 6,000 | +5.16 EURC | 16,803 sats (≈11 EURC) |
| 4,000 | current | 4,500 | +8.92 EURC | 20,215 sats (≈13 EURC) |
| 5,000 | current | 3,500 | +9.56 EURC | 19,646 sats (≈13 EURC) |
| 2,500 | 0.3% too high | 9,000 | +9.00 EURC | 27,153 sats (≈18 EURC) |
| 5,000 | 0.3% too high | 6,250 | +18.71 EURC | 37,619 sats (≈25 EURC) |
| 8,000 | 0.3% too high | 3,250 | +17.49 EURC | 31,183 sats (≈21 EURC) |

"0.3% too high" simulates a Chainlink feed that legitimately lags: according to the Chainlink directory, the cbBTC/USD feed on Base has a deviation threshold of 0.3% and a heartbeat of 1,200 s. EURC/USD has 0.1% and 3,600 s.

**Impact.** In these measurements every run from about 2,500 EURC leaks 0.2–0.7% to whoever calls `execute` first. That repeats every interval, and the app keeper runs at fixed times, so the timing is predictable. Base has no public mempool, but that does not help here: the attacker *is* the caller.

**Fix (new contract version, not tested).**
1. Add `observe()` to `IUniswapV3Pool` and, before the swap, compare per pool the current tick with a short TWAP (5–10 min, ±10 bps). A push within the same transaction does not change the TWAP.
2. Keep the TWAP ↔ Chainlink check at 50 bps and base `expectedOut` on the TWAP price.
3. First check `observationCardinality` of both pools (`0x7279…66fB` and `0xfBB6…43ef`). It must be large enough to cover the TWAP window; otherwise `observe()` reverts. Rule of thumb: at least the number of blocks with a swap in that window. On Base (2 s per block) 10 minutes is at most 300 blocks. The oracle checklist read 200 on-chain for EURC/USDC; not re-measured, and USDC/cbBTC not looked at. Increase with `increaseObservationCardinalityNext` if needed.

Only lowering `MAX_SPOT_DEVIATION_BPS` does not work: the feeds may together lag by up to ~0.4%, so honest runs would then revert.

---

### L-A (Low) — `owners` and `dueOwners` revert on a large `limit`

**Where:** `src/Rebalancer.sol:248` (`owners`) and `:287` (`dueOwners`): `Math.min(offset + limit, total)`.
**Found by:** periphery, boundary, execution-trace, first-principles.

With `offset ≥ 1` and `limit = type(uint256).max`, `offset + limit` overflows and the call reverts with Panic 0x11. The NatSpec of `dueOwners` promises "Never reverts". The current keepers use a bounded page size (`keeper/keeper.ts:47`, env `PAGE_SIZE`, default 50; `app/Console/Commands/RunKeeperCommand.php:149`) and are not affected; a future integration that asks for "everything" would be.
**Fix:** `uint256 end = limit > total - offset ? total : offset + limit;` (after the existing `offset >= total` check).

### L-B (Low) — Fee floor does not apply to sells

**Where:** `MIN_TRADE_FLOOR` (`src/Rebalancer.sol:74-78`), `_sell` → `_takeFee(received, …)` (`:566`).
**Found by:** math-precision, numerical-gap, asymmetry, invariant, first-principles.

The NatSpec promises that the fee of the smallest run (20 EURC × 25 bps = 0.05 EURC) exactly covers the keeper reward. For a buy that holds: the fee is computed over the gross input amount. For a sell the floor is checked against the Chainlink value, but the fee is computed over `received`, i.e. after pool fees and slippage. Worked example: value 20.000160 EURC, `received` 19.980160 EURC → fee 49,950 < 50,000 → the caller gets the whole fee and the treasury 0. These are dust amounts.
**Fix:** fee over `max(received, expectedOut)`, or check the floor against `received`, or correct the NatSpec.

### L-C (Low) — `isDue` reports a larger run than `execute` performs

**Where:** `_dueAt` (`src/Rebalancer.sol:312`) returns `correctionEurc`; `execute` trades `amountIn` (`:502`, `:508`), which is bounded by balance and allowance.
**Found by:** numerical-gap, trust-gap.

Example: wallet 10,000 EURC, correction 1,000 EURC, allowance 20 EURC → `isDue` reports 1,000 EURC, `execute` trades 20 EURC. Both keepers filter on this number: `runSizeSkipReason` in `keeper/keeper.ts:111` (env `MIN_RUN_EURC`, default 20) and an inline `isLessThan($floor)` in `app/Console/Commands/RunKeeperCommand.php:232` (threshold `config/bitburo.php:203`, `BITBURO_REBALANCER_MIN_RUN_EURC`, default 20). As long as that threshold equals `MIN_TRADE_FLOOR` this has no effect. If it is raised, both keepers let through runs they meant to skip.
**Fix:** derive `eurcDelta` from `amountIn` (for a sell: `amountIn × price / 1e8`).

---

## Leads (check by hand)

1. **Pool fee tier not enforced in the constructor** (periphery, boundary, asymmetry, invariant, first-principles, execution-trace, trust-gap). `_poolOrder` (`:208`) only checks token0/token1, not `fee() == POOL_FEE` or `factory.getPool(…, 500)`. With a wrong pool, the spot check guards a pool the swap does not go through. Checked on-chain with `cast`: the pools in `script/Deploy.s.sol` are the 0.05% pools of the same factory as SwapRouter02. The current deploy script is therefore correct; this is hardening. Fix: both checks in the constructor.
2. **One push, several victims** (oracle checklist). Calling `execute` for several due owners after one push adds up their volumes, so small wallets together reach the profitable size of M-1. Not tested.
3. **Donation across the band boundary** (numerical-gap, trust-gap). `_plan` computes with live `balanceOf(owner)`. Beyond the band it corrects the whole deviation (`:491`), not just the part outside the band. A small donation pushes an owner who is just inside the band across it, and the attacker thus chooses the block for M-1 himself. Extra profit beyond M-1 is not proven.
4. **Honest runs revert without an attacker** (math-precision). The feeds may together deviate ~0.4% from the market. The post-swap check adds the run's own price impact to that, so large runs can exceed 50 bps and fail with `SpotDeviatesFromOracle` until the feed updates. No loss, but downtime; how often this happens is not measured.
5. **Oracle possibly partly based on DEX prices** (oracle checklist). The Chainlink directory labels both feeds as `dex_state_price`. If that includes the Base EURC/USDC pool, the oracle partly checks itself. Ask Chainlink.
6. **No absolute min/max on feed answers** (oracle checklist). Only relevant if a feed first fails badly.
7. **Front-running `setParams`/`approve(0)`** (invariant). A run on the old parameters just before a change by the user. Base orders transactions first-come-first-served via a private sequencer, so targeted front-running is unproven.
8. **Temporary DoS via spot push** (economic-security). This is L-3 from the previous report. New is the cost estimate: the attacker needs ~8,000 EURC capital to push the EURC/USDC pool 0.5%, but loses only ~8 EURC in pool fees (plus possibly arbitrage loss) because he gets the capital back.
9. **Registration spam against keeper slots** (boundary, trust-gap). `_owners` grows per new address and never shrinks; each page of `dueOwners` makes up to three token calls per active owner. `RunKeeperCommand` rotates its start offset (`RunKeeperCommand.php:144`), and `keeper.ts` scans all owners. H-2 in the previous report was about starvation of the CRE alarm clock; that no longer exists, but the same risk applies to these two keepers. With the offset rotation, structural starvation seems covered; the cost with many spam addresses is not measured.
10. **`_spotOut` divides by 0 when `sqrtPriceX96 < 2^48`** (periphery). `:419-420`. Not reachable with the current pools; but a pitfall when reused for other token pairs.

## Noted, no impact

- `setParams(active = false)` must still send valid params (access-control, asymmetry). The owner can send his stored params and is therefore not stuck.
- After `retire` a new address can still register (asymmetry). `execute` then already reverts, and reads are paginated.
- Treasury on the Circle blacklist: the fee stays in the contract and `sweep` reverts until the blacklisting is lifted (access-control, periphery). No loss for users; see M-6.
- Forcing a trade or reversing the direction with a donation costs the attacker more than the victim loses (access-control, economic-security, periphery, first-principles).

## Checked and in order

- **Chainlink:** `answer > 0`, `updatedAt` not in the future, `MAX_AGE_CBBTC` 1,500 s ≥ heartbeat 1,200 s, `MAX_AGE_EURC` 4,500 s ≥ heartbeat 3,600 s, 8 decimals enforced, sequencer uptime + 1 hour grace period. `answeredInRound` is rightly absent (deprecated by Chainlink).
- **Fee accounting:** reward + treasury + retained = fee; `trySafeTransfer` cannot be made to fail by a caller with little gas.
- **`received` on sell:** the balance difference is correct, even if retained fee is still in the contract.
- **Reentrancy:** `sweep` and `execute` share the same transient lock; EURC, USDC and cbBTC have no transfer hooks.
- **SwapRouter02 sentinels:** `amountIn = 0` and recipient `address(1)`/`address(2)` are unreachable.
- **Opposite pushes on both pools:** yield no profit, because the victim trades through both pools.
- **Price arithmetic in `_spot`/`_spotOut`:** direction and precision are correct for the token order on Base (EURC < USDC < cbBTC).
- **Rounding in `_plan`:** no oversell (sell bounded by balance) and no overshoot of the target.
- **`retire`:** can only stop, not move funds.

## Fuzzing

**Echidna 2.3.3 (foundry mode)** on `RebalancerInvariantTest` in `test/Rebalancer.t.sol`: four runs, no usable result. Configs in `audit/2026-09-16/echidna/`.
- **Trial run** with `allContracts` and the default limit of 50,000 calls: all invariants green, but too short.
- **`allcontracts.yaml`:** 2 million calls, 106 of 590 contract lines hit. Two invariants broke (`invariant_contractNeverHoldsBalance`, `invariant_ownerBalancesOnlyMoveThroughExecute`), but only because Echidna called `MockERC20.mint` directly, bypassing the ghost accounting of `RebalancerHandler`. An error in the test setup, not a bug.
- **Whitelist, two runs:** the first whitelist contained only the handler functions and thereby also excluded the invariants (`tests: 0/0`). The second, `whitelist.yaml`, also contains the invariants: all 5 green, but only 3 contract lines hit, so the handler was not really called. Result invalid.

Echidna or Medusa need a dedicated property harness. pashov `fizz` can generate one.

**Foundry invariants, deep:** all 5 invariants in `RebalancerInvariantTest` green, ~11,000 calls per handler function, no unexpected reverts (the default in `foundry.toml` is 64 runs × depth 32).

## Reproducing

All commands from the root of `bitburo-contracts`.

- **Forge path:** `forge` on the PATH is Laravel Forge; use `~/.foundry/bin/forge`.
- **Fork tests:** use `BASE_RPC_URL`, falling back to `https://mainnet.base.org` (which is rate-limited). They fork the latest block, so the numbers shift per run.

```bash
# Tests and deep invariants
~/.foundry/bin/forge test
FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=100 ~/.foundry/bin/forge test --match-contract RebalancerInvariantTest

# Static analysis
PATH="$HOME/.foundry/bin:$PATH" slither src/Rebalancer.sol --compile-force-framework foundry --filter-paths 'lib/|test/|script/' > audit/2026-09-16/slither.txt 2>&1
aderyn . -i src -o audit/2026-09-16/aderyn.md

# M-1: sell sweep (already in test/)
~/.foundry/bin/forge test --match-contract OracleSandwichTest --match-test test_poc_sweepSell -vv

# M-1: buy runs with and without a lagging feed (copy to test/ temporarily)
cp audit/2026-09-16/poc/OracleLagSandwich.t.sol test/
~/.foundry/bin/forge test --match-contract OracleLagSandwichTest -vv
rm test/OracleLagSandwich.t.sol

# Echidna (requires Slither and crytic-compile). Writes crytic-export/ and echidna-corpus/ in the root;
# those are not in .gitignore, so clean them up afterwards.
PATH="$HOME/.foundry/bin:$PATH" echidna . --contract RebalancerInvariantTest --config audit/2026-09-16/echidna/allcontracts.yaml
rm -rf crytic-export echidna-corpus
```

Output of `OracleLagSandwich.t.sol`, per test:
- `oracle`/`spot`: EURC base units (6 decimals) per cbBTC;
- `run(EURC 6dec)` and `baseline ok`: run size and whether the run succeeds without an attack;
- `best push`: push in EURC base units;
- `victim loss sats`: cbBTC received less than without an attack;
- last line: attacker profit in EURC base units.

Note: `_grid(walletEurc, …)` is given the EURC size of the wallet, not the run. With `targetBps` 8000 and `maxCorrectionBps` 10000 (`_fundVictim` in `test/OracleSandwich.t.sol`) the run is 80% of that: `_grid(3_125e6, …)` gives a run of 2,500 EURC. The test names state the run size.

Measurement output not saved: the full fork logs, the Echidna coverage (106/590 lines) and the call counts of the deep invariant run were not kept; repeat the commands above to measure them again.

External sources for values in this report (consulted on 2026-09-16, not stored in the repo):
- **Compiler bugs:** `https://github.com/argotorg/solidity/blob/develop/docs/bugs.json` and `docs/bugs_by_version.json`.
- **Chainlink feeds on Base** (heartbeat, deviation, `dex_state_price`): `https://docs.chain.link/data-feeds/price-feeds/addresses?network=base`.
- **`observationCardinality` of the EURC/USDC pool:** `cast call 0x7279…66fB "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)" --rpc-url $BASE_RPC_URL`, field 4 (full address in `script/Deploy.s.sol`).

Repeating the AI reviews:
- **pashov:** install `github.com/pashov/skills` (used: commit `c577eb7` in that repo) and ask "run solidity-auditor on src/Rebalancer.sol". The outcome differs per run; the authors recommend 2–3 runs.
- **QuillShield:** follow `plugins/oracle-flashloan-analysis/skills/oracle-flashloan-analysis/SKILL.md` from `github.com/quillai-network/quillshield_skills` (used: commit `8bdd3c0`), including the `references/` folder next to it; their `install.sh` does not copy it. Ignore the mandatory `answeredInRound` check.

## Status of findings 2026-09-15

Reviewed on 2026-09-16, read-only. The IDs are those from the summary table of `audit/2026-09-15/RAPPORT.md`, not the detailed reports' own numbering.

**What was examined**
- **Contract:** `src/Rebalancer.sol` on `development` @ `449ffb4` (line numbers "src") and `git show f8a6d49:src/Rebalancer.sol`, the source of the live contract `0xE577…2104` (line numbers "live").
- **On-chain, read-only** (`cast call` against `https://mainnet.base.org`, block 51,386,261): from the live contract `MIN_TRADE_FLOOR()` = 20e6, `MIN_CORRECTION_BPS()` = 10, `MIN_SLIPPAGE_BPS()` = 60, `MAX_AGE_EURC()` = 4500, `FEED_EURC_USD()` = `0x9867…01e0`, `FEED_DECIMALS()` = 8, `EXECUTE_GAS()` = 1e6, `ownerCount()` = 1; `retired()` reverts. On the old contract `0xED47…e6e5` the only owner `0x459E…A497` has `active = false` and allowance 0 on EURC and cbBTC.
- **Keepers:** `keeper/keeper.ts` and `keeper/selection.ts` in this repo, `app/Console/Commands/RunKeeperCommand.php` in the app.
- **App** (`pinheadio/bitburo`, `development` @ `ab97b71`): Privy commands, `ScheduleRunner`, `SweepExecutionsCommand`, `RebalancerMandateReader`, `resources/js/lib/rebalancer-abi.ts`, `strategy-card.tsx`.
- **Note:** almost all app fixes are in `b612102` (#144) and `8588913` (#145). Those are on `development`, not on app `production` (`bbc853a`, release v0.4.1; checked with `git merge-base --is-ancestor`). `RunKeeperCommand` itself (`118e811`, #142) is not yet on `production` either.
- **Privy:** nothing verified live. A read-only check of the policies requires Privy production keys; I did not use them.

**Column "src / live":** does the issue still apply in `src/` on `development` and in the live contract? "n/a" = not a contract item.

| ID | Title | Status | Evidence | src / live | What still needs to happen |
|---|---|---|---|---|---|
| H-1 | Server signer can sign `permit` and 7702 authorizations | partially fixed | App `SetupSwapPolicyCommand.php:147-149`: DENY on `eth_signTypedData_v4` for EURC/cbBTC (`:226-239`) and for every domain on chain 8453 (`:248-261`), DENY on `eth_sign7702Authorization` (`:271-284`); commit `8588913`. Test: `tests/Feature/SetupSwapPolicyCommandTest.php`, only checks the request body. | n/a | Release #145 and run `bitburo:setup-swap-policy --update` against production Privy; then review the live policy read-only (**not verified live**). Structural: remove the swap signer from the user wallets after the cutover; the old engine (`ScheduleRunner`) still exists. Test gap: no test against the real policy engine. |
| H-2 | Dust owners starve the alarm clock | fixed (CRE part obsolete) | Contract: `MIN_TRADE_FLOOR` and `MIN_CORRECTION_BPS` in `setParams` (src `:78`, `:81`, `:222-231`; live `:83`, `:86`, `:238-239`; commit `69ff682`; confirmed on-chain). Keepers: rotating scan window `RunKeeperCommand.php:283-291` (`b612102`) and floor `:232`; `keeper.ts:94` walks all pages without a cap. Tests: `test_setParams_rejectsMinTradeBelowFloor` (`test/Rebalancer.t.sol:214`), `test_dustOwnerCannotRegisterAnymore` (`test/PocFork.t.sol:58`), `test_dueOwners_pagingReachesEveryDueOwner` (`test/Rebalancer.t.sol:1176`), Pest "the scan window rotates every hour…" (`RunKeeperCommandTest.php:130`). | no / no | Release the app keeper (#142/#144). Cost under mass registration spam not measured (lead 9). |
| M-1 | Caller sandwiches their own run | open | Post-swap check `_requireSpotNear` (src `:539`, `:564`; live `:560`, `:585`; commit `69ff682`) reduces the profit, but the fork measurements in [M-1](#m-1-medium-confirmed-still-open--caller-can-profitably-sandwich-their-own-execute) still show up to +18.71 EURC. `test_poc_sweepSell` (`test/OracleSandwich.t.sol:331`) measures without asserts; `test_fork_lossPerRunBoundedUnderSpotPush` (`:231`) only guards the loss bound. | yes / yes | TWAP check in the new contract version, see step 2 below. |
| M-2 | 24-hour EURC/USD feed, no longer listed | fixed | `script/Deploy.s.sol:28` uses `0x9867…01e0` (`9011434`, `69ff682`); `MAX_AGE_EURC` 4,500 s (src `:90`, live `:102`); decimals check (src `:198-199`, live `:213-214`). On-chain: live `FEED_EURC_USD()` = `0x9867…01e0`. Tests: `test_fork_feedsAreFreshAndMatchConstants` (`test/RebalancerFork.t.sol:107`), `test_fork_feedCadenceWithinMaxAge` (`:135`, `319558b`). | no / no | — |
| M-3 | `EXECUTE_GAS` too tight | obsolete | CRE only: `onReport` and `EXECUTE_GAS` removed from `src/` in `a798bde` (#12), workflow removed in `e523548` (#2). Live still has `onReport` with `EXECUTE_GAS` 1e6 (live `:90`, `:367`), but no workflow calls it. Gas per run still measured in `test_fork_buyAndSellGasCost` (`test/RebalancerFork.t.sol:172`). | n/a / dead surface | — |
| M-4 | Owners that always revert remain due | fixed (in the alarm clocks) | The contract deliberately does not remember failures (src `:275-277`; `lastAttemptAt` was CRE-only, removed in `a798bde`). `keeper.ts` simulates and keeps a doubling cool-down (`selection.ts:53-63`, `e149b96`); the app simulates (`RunKeeperCommand.php:247`) and pauses after 3 failures (`:314`). Tests: `test_execute_revertsWhenOwnerBlacklisted` (`test/Rebalancer.t.sol:1002`), `keeper/selection.test.ts:48`, Pest `RunKeeperCommandTest.php:302`, `:325`. | behavior remains, alarm clocks catch it / same | Release the app keeper. The page loop in `keeper.ts` itself is untested. |
| M-5 | Small wallets cannot sell | fixed | `Math.Rounding.Ceil` (src `:507`, live `:528`; `69ff682`). Tests: `test_poc_smallWalletCanSellWithNonRoundPrice` (`test/AuditMath.t.sol:291`), `testFuzz_isDue_matchesCorrectionAtAnyPrice` (`test/Rebalancer.t.sol:1569`). | no / no | — |
| M-6 | Treasury on the blacklist blocks everything | fixed (contract) | `trySafeTransfer` + `FeeRetained` (src `:578-586`, live `:603-606`; `69ff682`), `sweep` recovers it (src `:351-354`). Tests: `test_execute_continuesWhenTreasuryBlacklistedAndSweepRecoversFee` (`test/Rebalancer.t.sol:808`), `test_poc_blacklistedTreasuryNoLongerBricksExecute` (`test/AuditMath.t.sol:250`). | no / no | The operational part (treasury key in a hardware wallet or multisig) cannot be determined from the code. |
| M-7 | Server dictates the mandate params | partially fixed | `MANDATE_LIMITS` and `mandateLimitViolation` in `resources/js/lib/rebalancer-abi.ts:90-140`; `encodeSetParams` refuses an active mandate outside the limits (`:151-157`); commit `8588913`. Tests: Vitest "keeps an out-of-range active mandate from being encoded at all" (`rebalancer-abi.test.ts:158`), browser "refuses to sign settings outside the safe bounds and says why" (`tests/Browser/StrategyTest.php:307`). | n/a | The defaults still come as a server prop (`strategy-card.tsx:759-766`): within the limits the server still chooses. No server validation. Release #145. |
| M-8 | Old mandates remain active and invisible after a redeploy | partially fixed | App reads and revokes mandates on `legacy_addresses` (`config/bitburo.php:205`, `RebalancerMandateReader.php:25-27`, `:117`; `8588913`); tests `WalletControllerTest.php:890`, `:944`, `:962` and `StrategyTest.php:542`. Old contract `0xED47…e6e5`: revoked on-chain (see above). Runbook in README "Retiring the contract" and `retire()` (src `:369-374`, `f866f20`). `WORKFLOW_OWNER` part obsolete (`a798bde`). | `retire` present / no `retire` | Release #145 and set `BITBURO_REBALANCER_LEGACY_ADDRESSES` in production (cannot be checked). `retire` only goes live with a new deploy (issue #7). |
| M-9 | No pause button, runbook or alerting; two engines at once | partially fixed | Mutual exclusion: `ScheduleRunner.php:248-285` (`hasActiveMandate`), tests `ScheduleRunnerTest.php:454`, `:470`. Alert on price deviation > 1% and output < 98.5%: `SweepExecutionsCommand.php:76`, `:83`, `:325-345`, tests `SweepExecutionsCommandTest.php:585`, `:604`. Keeper alerts by e-mail (app `README.md`, "Alerting per e-mail" ("Alerting by e-mail")). Emergency stop `retire()` only in src. Everything in the app via `b612102`/`8588913`. | emergency stop present / no emergency stop | New deploy for `retire`. Release the app. I found no incident runbook (who does what, communication) in either README. |
| L-1 | `minTradeEurc` without a floor | fixed | `MIN_TRADE_FLOOR` (src `:78`, live `:83`) and `NoOutput` (src `:538`, live `:559`); `69ff682`. Tests: `test_setParams_rejectsMinTradeBelowFloor` (`test/Rebalancer.t.sol:214`), `test_execute_revertsNoOutputWhenBuyYieldsZero` (`:958`), `test_poc_microRunNoLongerPossible` (`test/AuditMath.t.sol:270`). | no / no | — |
| L-2 | `MIN_SLIPPAGE_BPS` 30 too low | fixed | `MIN_SLIPPAGE_BPS = 60` (src `:72`, live `:77`; on-chain 60). Tests: `test_execute_minSlippageCoversSpotDeviationPlusPoolFees` (`test/Rebalancer.t.sol:938`), `test_poc_minSlippageBelowSpotDeviationPlusPoolFees` (`test/AuditMath.t.sol:231`). | no / no | — |
| L-3 | DoS by pushing the spot > 0.5% | open | `_requireSpotNear` (src `:401-405`) still reads `slot0` (`:418`); no TWAP. `test_fork_spotDeviationBlocksRun` (`test/RebalancerFork.t.sol:75`) only tests the revert. Cost estimate in lead 8. | yes / yes | Include with the TWAP fix of M-1. |
| L-4 | No `decimals()` check on the feeds | fixed | src `:198-199`, live `:213-214` (`69ff682`); on-chain `FEED_DECIMALS()` = 8. Test: `test_constructor_rejectsFeedWithWrongDecimals` (`test/Rebalancer.t.sol:1378`). | no / no | — |
| L-5 | Workflow ignores `receiverContractExecutionStatus` | obsolete | CRE only; workflow removed in `e523548` (#2). | n/a | — |
| L-6 | CRE ↔ keeper collision consumes a report | obsolete | CRE only (#2, `a798bde`). Two remaining alarm clocks on the same owner produce a cheap `NotDue` (`test_execute_revertsNotDue`, `test/Rebalancer.t.sol:468`). | n/a | — |
| L-7 | Keeper wallet and policy on the same Privy quorum | partially fixed, uncertain | `SetupKeeperQuorumCommand.php:103-142` puts the keeper wallet under its own key quorum; the policy stays with the app quorum (`8588913`). Tests: `SetupKeeperQuorumCommandTest.php:77`, `:115`, `:131`. Runbook in app `README.md`. | n/a | **Not verified live** whether the command has been run in production; #145 is not on `production`. Uncertain whether the split holds: according to Privy ("Update a wallet", docs.privy.io/wallets/wallets/update-a-wallet) the owner may change the wallet's `policy_ids` with its signature, so the keeper key may be able to detach the policy itself. Ask Privy. |
| L-8 | Event sync: three weak spots | partially fixed | (c) Cursor per contract address with fallback to the newest recorded block: `SweepExecutionsCommand.php:184-217` (`8588913`). (a) An undecodable log is still skipped with a warning (`:265-275`, test `SweepExecutionsCommandTest.php:482`); according to the docblock (`:58-61`) that becomes a Sentry event via `sentry_logs`, production config not checked. (b) No alarm for a stalled sweep or a wallet that stays in `skipped_recent_execution` for > 24 hours (`ReconcileWalletsCommand.php:66-70` only counts). | n/a | (a) fail instead of skipping, (b) build an alarm, and release. |
| L-9 | Sequencer feed `startedAt == 0` not caught | fixed | src `:382`, live `:403` (`69ff682`). Test: `test_execute_revertsSequencerDownWhenStartedAtZero` (`test/Rebalancer.t.sol:531`). | no / no | — |

**Tests run during this check**
- `RUN_FORK=false ~/.foundry/bin/forge test`: 109 passed, 0 failed, 3 skipped.
- `bun test` in `keeper/`: 10 passed.
- App, Vitest `resources/js/lib/rebalancer-abi.test.ts`: 17 passed.
- App, Pest on `SetupSwapPolicyCommandTest`, `SetupKeeperQuorumCommandTest`, `RunKeeperCommandTest`, `ScheduleRunnerTest`, `SweepExecutionsCommandTest` and `WalletControllerTest`: 170 passed, **3 failed**, all three in `WalletControllerTest`: "the five mandate reads go to the node as one batched request", "an unreadable chain is never cached…" and "the legacy addresses come from a comma separated environment value". The last one gets `0xED47…e6e5` from the local environment where it expects an empty list; I did not investigate the cause of the first two.

## Next steps

1. **Finish the open items from the 2026-09-15 report** (see [Status of findings 2026-09-15](#status-of-findings-2026-09-15)):
   - **New contract version:** M-1 and L-3 (TWAP), and getting `retire()` live for M-8/M-9.
   - **Without redeploy:** app PRs #142, #144 and #145 to `production` (H-1, H-2, M-4, M-7, M-8, M-9, L-7, L-8 depend on them); then `bitburo:setup-swap-policy --update` and `bitburo:setup-keeper-quorum` in production and review the live Privy policies read-only. Further L-8 (a) and (b), server validation or built-in defaults for M-7, an incident runbook for M-9, and removing the swap signer from the user wallets after the cutover (H-1).
   - **Investigate:** whether the wallet owner in Privy can detach the policy (L-7), and why three tests in `WalletControllerTest` fail locally.
2. **Design and fix M-1** (TWAP check), on a new branch from `development` after `chore/solc-0.8.37` has been merged into it. Add a fork test that proves with asserts that the attacker's profit is ≤ 0 for every push, also with a lagging feed. Use `audit/2026-09-16/poc/OracleLagSandwich.t.sol` as the basis: move it to `test/`, because it only compiles there (it imports `./OracleSandwich.t.sol`). Also update the NatSpec (`:33`) and `README.md:41`.
3. **Fix L-A, L-B, L-C** in the same contract version, each with a test.
4. **Include lead 1 (pool check in the constructor)** in the same version.
5. **Review leads 2–10** and decide per lead: fix, document or reject.
6. **New deploy — only with Arjan's explicit approval (`README.md:123`).** The live contract `0xE577…2104` has the same issues. It has no `retire()`, so the `retire` runbook in `README.md` does not work there (`README.md:14`, `:51`). Retiring it is only possible by each user sending `setParams` with `active = false` and `approve(0)` on EURC and cbBTC themselves. Before a new deploy, read the runbook in issue #7 of `pinheadio/bitburo-contracts` (`README.md:109`). Points of attention:
   - `deploy-mainnet.sh go` refuses as long as `broadcast/` already contains a deploy (`FORCE_REDEPLOY=1`). `broadcast/` is in `.gitignore`, so a fresh clone behaves differently.
   - After the deploy, update the app: `BITBURO_REBALANCER_ADDRESS`, `BITBURO_REBALANCER_DEPLOY_BLOCK` and the old address in `BITBURO_REBALANCER_LEGACY_ADDRESSES` (`config/bitburo.php:200-207`), and `REBALANCER` for `keeper/keeper.ts`.
7. **External audit** on that new version, with this report and the one of 2026-09-15 as input.
