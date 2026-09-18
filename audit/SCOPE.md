# Rebalancer: scope for the external audit

Prepared 17 September 2026, after the contract was rewritten on that day. Companion files: [`REVIEW.md`](REVIEW.md) (independent internal review of this code) and [`static/triage.md`](static/triage.md) (Slither and Aderyn, raw output in [`static/`](static/)).

## 1. What is in scope

### 1.1 Audit version

The latest commit on `development` when the audit starts; we confirm the hash when we contact the auditor. All `file:line` references below were checked on 18 Sept 2026.

### 1.2 Files and size

nSLOC: block comments and `//` comments removed, then every non-blank line counted.

| File | Lines | nSLOC | In scope |
|---|---|---|---|
| `src/Rebalancer.sol` | 331 | 216 | **yes, primary** |
| `src/interfaces/IV3SwapRouter.sol` | 21 | 13 | yes (self-written; selector `0x04e45aaf`) |
| `src/interfaces/IAggregatorV3.sol` | 12 | 8 | yes |
| `script/Deploy.s.sol` | 63 | 39 | yes (constructor arguments and the checks the constructor does not do) |
| `keeper/keeper.ts`, `keeper/selection.ts`, `keeper/lock.ts` | 389 / 352 / 134 | 309 / 221 / 86 | optional: reference keeper, not deployed on chain |

Runtime bytecode of `Rebalancer`: 6,694 bytes.

### 1.3 Compiler and settings

solc `0.8.37` (pragma pinned; released 10 Sept 2026, no known bugs listed), `via_ir = true`, optimizer 1000 runs, `evm_version = cancun`. OpenZeppelin Contracts `v5.6.1` (`5fd1781b`): `IERC20`, `IERC20Metadata`, `SafeERC20`, `ReentrancyGuardTransient`, `Math`. Foundry `1.5.1`.

### 1.4 Chain and external dependencies

Base mainnet (chain id 8453). Verified on chain with `cast call` on 17 Sept 2026 (block ~51,431,600):

| Role | Address | Verified |
|---|---|---|
| USDC (6 dec) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | decimals 6 |
| cbBTC (8 dec) | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` | decimals 8 |
| Uniswap SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` | `exactInputSingle` selector `0x04e45aaf` in the bytecode; `factory()` = `0x3312…FDfD` |
| Pool USDC/cbBTC 0.05% | `0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef` | `getPool(USDC, cbBTC, 500)` of that factory; 3.77M USDC + 50.45 cbBTC; in-range liquidity 2.42e12 (~3,350 USDC per bp) |
| Chainlink cbBTC/USD | `0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D` | "cbBTC / USD", 8 decimals, heartbeat 20 min, deviation 0.3%; methodology `dex_state_price` in Chainlink's feed registry (§4, risk 10) |
| Chainlink L2 Sequencer Uptime | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` | answer 0 (up) |
| Treasury | `0xD6a4f92C9c2c35B4816deC5147231226Fb7598a9` (`deploy-mainnet.sh`) | an EOA; it also owns `retire()` |

The contract does not read the pool. The deploy script checks that the router's factory resolves fee 500 to the pool above and that the feeds carry the expected descriptions (`script/Deploy.s.sol:44-50`); the fork suite runs the script (`test_fork_deployScriptChecksAndDeploys`).

### 1.5 Out of scope

The deployed legacy contracts `0xE577…2104` and `0xED47…e6e5`, the Bitburo app (`pinheadio/bitburo`) and its keeper command, Privy, Uniswap, Chainlink and the token contracts themselves, `test/`, `audit/`, `deploy-mainnet.sh`.

## 2. System overview and trust model

An owner gives the contract an ERC-20 allowance on USDC and cbBTC and calls `setMandate(targetBps, keeper)` (`:143`). Funds stay in the owner's wallet. When the wallet's cbBTC share drifts more than 5% of its value from the target, the owner or the keeper that owner appointed calls `execute(owner, minAmountOut)` (`:194`): the contract pulls the input token, swaps it through SwapRouter02 `exactInputSingle` in the USDC/cbBTC 0.05% pool with itself as recipient, checks what arrived against Chainlink and that the pool took all of the input (`_swap`, `:303`), keeps 25 bps of the USDC leg as fee and sends the rest to the owner. Anyone can forward the collected fees to the treasury with `sweep` (`:229`).

| Actor | Can | Cannot |
|---|---|---|
| Owner | set, change, revoke their own mandate; run their own wallet; replace the keeper | touch anyone else's mandate |
| Keeper appointed by an owner | choose the moment of that owner's run; demand a better price | choose direction or amount; run more than once a day; trade outside the price bound; send output anywhere but the owner; run an owner who did not appoint it |
| Anyone | `sweep(token)` to the treasury | anything else |
| Treasury | receive fees; `retire()` | touch funds, mandates or allowances; undo `retire` |

No admin, no upgrade, no pause. All settings are constants (`:52-66`); the only mutable global flag is `retired`.

**The keeper is trusted within the bounds, not beyond.** A dishonest keeper (or whoever composes its transactions: a bundler, a relayer) can trade around the run it triggers and so move the owner's price down to the lower bound: at most 0.55% of the traded amount, once a day, on at most 10% of the wallet, and only when a correction is due. This is a deliberate trade against the previous design, in which `execute` was permissionless and ~400 nSLOC of novel machinery defended against the caller. Trusted: SwapRouter02 and the pool, Chainlink, Circle (USDC) and Coinbase (cbBTC).

## 3. Invariants and requirements

Tests: `test/Rebalancer.t.sol` (unit, fuzz, invariants with and without `retire`) and `test/RebalancerFork.t.sol` (real tokens, router, pool and feeds).

1. **Custody.** A user's tokens only move in a run the rule prescribes, called by that user or their keeper, and the output only goes to that user. `test_execute_revertsForStranger`, `test_execute_replacedKeeperIsRefused`, `test_execute_ownerWithoutKeeper`, `test_execute_treasuryHasNoSpecialRights`, `invariant_onlyOwnerOrKeeperRuns`, `test_fork_strangerIsRefused`.
2. **Loss bound per run.** Against the Chainlink price a run loses at most `FEE_BPS + MAX_DEVIATION_BPS` = 80 bps, enforced on the measured balance difference, also if the router did not enforce its own minimum. `test_execute_lowerBound`, `test_execute_ownBoundHoldsWhenTheRouterDoesNotEnforceTheMinimum`, `test_execute_partialFillIsRefused`, `test_execute_zeroOutputIsRefused`, `testFuzz_lossPerRunBoundedByFeePlusDeviation`, `invariant_lossPerRunWithinFeePlusDeviation`, `test_fork_pushedPoolAgainstTheRunIsRefused`.
3. **Upper bound.** A swap that yields more than 55 bps above the Chainlink value is refused: a stuck feed or a USDC depeg halts both directions. `test_execute_upperBoundStopsARunThatIsTooGood`, `test_execute_usdcDepegStopsBothDirections`, `test_fork_poolFarBetterThanTheFeedIsRefused`.
4. **`minAmountOut` only tightens.** `test_execute_minAmountOutCanOnlyTighten`, `test_fork_keeperCanDemandTheQuotedOutput`.
5. **The rule** (`_plan`, `:270`). Start outside the band (exact comparison), run ≤ max(10% of the value, 20 USDC), ≥ 20 USDC, towards the target and not past it, capped by balance and allowance; at most one run per owner per day; an unfinished correction continues on the next days and the flag expires after two days. `test_execute_buy_exactAmounts`, `test_execute_sell_exactAmounts`, `test_execute_bandEdgeDoesNotDependOnRounding`, `test_execute_correctionLargerThanTheCapIsFinishedOnTheNextDays`, `test_execute_unfinishedCorrectionExpiresAfterTwoIntervals`, `testFuzz_runMovesTowardsTheTargetWithinTheCap`, `invariant_atMostOneRunPerInterval`, `invariant_runWithinMinimumAndCap`.
6. **Accounting.** Between calls the contract holds only uncollected fees (and tokens sent to it by mistake), never cbBTC or an allowance to the router, and what it holds never leaks into a run. A run in which the pool took only part of the input is refused, also when what arrived meets the bound: the router does not check that the pool took everything, and the rest would stay in the contract. `invariant_contractHoldsOnlyUnsweptFeesAndDonations`, `invariant_routerAllowanceIsZeroBetweenCalls`, `test_sell_isNotAffectedByCollectedFees`, `test_execute_partialFillIsRefused`, `test_execute_partialFillWithinTheBoundIsRefused`, `test_fork_tokensLowerTheAllowanceOnTransferFrom`.
7. **Oracle.** Sequencer up and past the grace period, answer > 0 and not rounding to 0, age ≤ 1500 s, no future timestamps. `test_quote_revertsSequencerDown`, `test_quote_revertsStaleFeed`, `test_quote_revertsInvalidAnswer`, `test_fork_feedIsFreshAndCloseToThePool`.
8. **`retire`, `stop`, the interval.** `test_retire_*`, `test_stop_*`, `test_setMandate_doesNotShortenTheInterval`, `invariant_noRunAfterRetire`.
9. **Reentrancy.** `test_sweep_maliciousTokenCannotReenter` (fails without the guard).

## 4. Known and accepted risks

1. **Trust in the keeper**, as described in §2. Keepers must send plain transactions from their own key and pass a tight `minAmountOut`: a keeper that sends through a bundler or relayer (ERC-4337, a sponsored send) lets that party wrap the call and trade around it. Bitburo's keeper sends plain transactions from its Privy server wallet, with a fixed gas limit and the simulated output minus 10 bps as `minAmountOut`.
2. **Feed lag.** The bound is against Chainlink, not against the market: cbBTC/USD may lag by its 0.3% deviation threshold, more in fast markets. A dishonest keeper can time a run for that.
3. **USDC counts as one dollar.** Deliberate: with a USDC/USD feed the contract would sell cbBTC for sinking USDC during a depeg. Without it a depeg of more than ~0.5% halts both directions.
4. **Changing or revoking is not atomic.** One more run within all bounds can be placed in front of a `stop()`, a keeper change or an `approve(0)`.
5. **One pool, one feed, one router, immutable.** If any of them goes away, runs stop and a new deployment is needed; funds are never at risk from that. `MAX_FEED_AGE` leaves 268 s above the largest heartbeat gap seen in 59 hours.
6. **No splitting of large runs.** Measured at block 51,425,248: the 10% run of a wallet of 1, 2 and 3 million USDC lands 0.20%, 0.35% and 0.49% below Chainlink; a 4 million wallet is refused until the pool is deeper.
7. **Small wallets.** Below 200 USDC the 20 USDC minimum is the budget, so one run can be most of the wallet.
8. **Treasury blacklisted by Circle.** Runs continue (no transfer to the treasury inside a run); `sweep(USDC)` reverts until the blacklist is lifted.
9. **Compiler age.** solc 0.8.37 was one week old on 17 Sept 2026.
10. **The feed is computed from DEX pools.** Chainlink's feed registry lists the Base cbBTC/USD feed with the methodology `dex_state_price`, which Chainlink documents as end-of-block states of onchain DEX pools, weighted by volume, with outlier and time-lag filters (docs.chain.link, "DEX State Price Streams"; it does not publish which pools). The price bound is therefore not fully independent of the pools on Base, possibly including the one the contract trades in. A push inside one block (a sandwich) does not reach the answer; a push held across blocks and across those pools can, and a due run then trades at the moved answer, within the bound. The attacker pays arbitrage against every monitored pool for as long as it takes the answer to follow and the keeper to run. The alternative, Chainlink BTC/USD on Base (`0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F`: CEX prices, deviation 0.1%, heartbeat 20 min, 8 decimals), would need no change to the contract's logic; sampled every 6 hours over 30 days, the pool stood at most 15.3 bps from it (p90 7.8) against 30.6 bps from cbBTC/USD (p90 21.0) (`feed-vs-pool.py`, data in `static/feed-vs-pool-30d.json`). The contract keeps cbBTC/USD; see question 6.

## 5. Questions for the auditors

1. Is the two-sided bound on the measured balance difference (`_swap`, `:303-330`) a sound replacement for a separate pool-spot check, including its role as a halt during a USDC depeg or with a stuck feed? Any rounding or decimals case in which a run passes outside 55 bps, or in which honest runs of the minimum size can never pass?
2. Can any sequence of `setMandate`, `stop`, runs, price moves, donations and allowance changes bypass the daily interval, run inside the band without an unfinished correction, flip direction at a loss, or keep a wallet trading every day (`_finishing`, `:263`; `_plan`, `:270-299`)?
3. With SwapRouter02 and a v3 pool as they are deployed on Base: the contract refuses a run after which the router still has an allowance, which is how it tells that the pool did not take all of the input (`_swap`, `:326-329`). Is there a partial-fill, callback or recipient case that this misses, in which input or output ends up anywhere but the contract?
4. Is accepting the keeper trust in §2 reasonable for an immutable contract, and is there a cheap on-chain measure that would shrink it further without bringing back the removed machinery?
5. Is pinning a one-week-old compiler with `via_ir` the right call here, or would you deploy with an older release whose known bugs this code cannot reach?
6. Would you keep the cbBTC/USD feed, which Chainlink computes from DEX pools (§4, risk 10), or construct the contract with BTC/USD? How long and how widely would a push have to be held on Base to move the cbBTC/USD answer?

## 6. How to build and test

```bash
git clone https://github.com/pinheadio/bitburo-contracts && cd bitburo-contracts
git checkout development
git submodule update --init lib/openzeppelin-contracts   # forge-std is vendored
~/.foundry/bin/forge build --sizes                        # "forge" on PATH may be another tool
~/.foundry/bin/forge fmt --check
RUN_FORK=false ~/.foundry/bin/forge test
FORK_BLOCK=51425248 ~/.foundry/bin/forge test
FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=100 ~/.foundry/bin/forge test --match-test invariant
cd keeper && bun install && bun test && bunx tsc --noEmit
```

Results on 17 Sept 2026: `forge fmt --check` exit 0; `RUN_FORK=false`: 75 passed, 1 suite skipped; `FORK_BLOCK=51425248`: 84 passed, 0 failed (61 unit and fuzz, 2 × 7 invariants, 9 fork); deep invariants: 14 passed; keeper: 40 tests passed, `tsc` exit 0 (42 since the keeper fixes of 18 Sept 2026). Gas on the fork: buy ~198k, sell ~209k. The fork suite reads `BASE_RPC_URL` (default `https://mainnet.base.org`); tests that need an honest run to pass skip themselves when the pool stands more than 0.40% from the feed at that block.
