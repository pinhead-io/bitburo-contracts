# bitburo-contracts

Bitburo's immutable `Rebalancer` contract for Base mainnet, plus the keeper script that runs it.

The user keeps USDC and cbBTC in their own wallet, gives the contract an ERC-20 allowance on both and calls `setMandate` with the cbBTC share they want and the keeper that may run it. When the wallet drifts more than 5% of its value away from that share, the owner or that keeper calls `execute`: the contract pulls the input token, swaps it in the Uniswap v3 USDC/cbBTC 0.05% pool, checks the result against Chainlink and sends the output back to the wallet. Bitburo holds no key that can touch funds or mandates; the treasury's only power is the one-time kill switch `retire()`.

Only the owner and the keeper the owner appoints can start a run. That is a deliberate trade: a contract anyone may call has to defend every run against the caller itself (who can move the pool around the run), which takes far more code than the rebalance does. Here a keeper is trusted within the contract's bounds, can be replaced by the owner at any time, and the owner can always run their own wallet.

## What Bitburo is

Bitburo is a web application in private beta that keeps a user's wallet at a fixed split between Bitcoin and dollars: today 80% cbBTC and 20% USDC for every user, on Base. The user never hands over funds. They sign in with Privy, which gives them an embedded wallet on Base, and give this contract a mandate over that wallet. From then on the contract rebalances the wallet towards the target once a day at most, whenever it has drifted far enough, and the app shows the result.

The application is the interface; this contract does the work. That split is deliberate: Bitburo should not take custody of funds or make trading decisions of its own. So:

- **The funds stay in the user's wallet.** The contract pulls only what a run needs, swaps it and sends the output straight back. Between transactions it holds nothing but collected fees.
- **The rule is in the contract, not in Bitburo's servers.** Direction, size, timing limits and the price bound are constants in immutable code. Bitburo's keeper only decides *when* to call `execute`, and may demand a better price than the contract's own bound.
- **The user can leave at any moment**, with `stop()` or by revoking the allowance, and the contract keeps working without Bitburo: anyone can run the open keeper script in `keeper/` for their own wallet, or appoint someone else.
- **Nothing in this contract gives Bitburo a way to move a user's funds.** Its keeper can only call `execute` for owners who appointed it, within the rule; the treasury can only receive fees and, once, `retire()` the contract.

How the application uses the contract, for context (the app is not in scope):

| Step | Who | What |
|---|---|---|
| Mandate | the user, in the browser | Signs `approve` for USDC and cbBTC and `setMandate(8000, <Bitburo keeper>)`. Privy sponsors the gas, so the user needs no ETH. |
| Run | Bitburo's keeper, hourly | Reads `mandates` and `isDue` for its own users through Multicall3, simulates `execute(owner, 0)` from the keeper address, then sends `execute(owner, simulated − 10 bps)` as a plain transaction with a fixed gas limit of 500,000. The keeper is a Privy server wallet (`0xDE89810E6a9013860FE1e529b349C7ba906C8f56`) whose Privy policy allows only `execute(address,uint256)` on this contract. It pays its own gas; it is deliberately not sponsored (see *Keepers must send plain transactions* below). |
| Booking | Bitburo's server, hourly | Reads the `Executed` logs up to the chain's safe block and books them in the app's ledger, so a run the owner started himself is recorded too. |
| Revenue | anyone | 25 bps of the USDC leg of every run stays in the contract until someone calls `sweep(USDC)`, which sends it to the treasury. |

**Status.** Live on Base since 21 September 2026 (address below). Private beta: no third-party funds will be accepted until this audit is concluded. Earlier contracts (see *Deployments*) let anyone call `execute` for a fixed reward; that design needed far more code to defend a run against its own caller and was replaced by the owner-appointed keeper.

## Deployments

| What | Address | Note |
|---|---|---|
| Rebalancer (this code) | `0x1Df884A2A28BbD729714D4f9697972293872BB42` | Live since 21 September 2026, block 51,604,724, tx `0xc062d3a63e5d4d995162a66471f462c7d09574d5c686fbc1c18dfa5f7c1b0ce4`. Code: commit `ef39299`. Verified on Basescan. |
| Rebalancer v1.1 (EURC, permissionless) | `0xE577D68948883FDF8e2694e38dF656D2D9CA2104` | Legacy. Predates `retire()`; users revoke with `setParams(active = false)` and `approve(0)`. Code: tag `v1.1.0` and commit `b3ca31a`. |
| Rebalancer v1.0 | `0xED47…e6e5` | Legacy. |

## Audit guide

### Target

- **Code under audit:** `src/` in this repository. It is identical at commit `ef39299`, from which the live contract was deployed, and at the head of `development`; check with `git diff --quiet ef39299 HEAD -- src/`. The commit that carries this guide changes documentation only.
- **Tag:** `audit-2026-09-22` marks the version handed to the auditor. Check out the tag rather than `development`: the tag always points at this version, while `development` moves on as new work is merged.
- **Deployed instance:** `0x1Df884A2A28BbD729714D4f9697972293872BB42` on Base (chain id 8453), block 51,604,724, verified on Basescan with the settings below. Runtime bytecode 6,685 bytes.

### Scope

nSLOC: comment lines and blank lines removed, every remaining line counted.

| File | Lines | nSLOC | In scope |
|---|---|---|---|
| `src/Rebalancer.sol` | 340 | 216 | **yes, primary** |
| `src/interfaces/IV3SwapRouter.sol` | 21 | 13 | yes (self-written; `exactInputSingle` selector `0x04e45aaf`) |
| `src/interfaces/IAggregatorV3.sol` | 12 | 8 | yes |
| `script/Deploy.s.sol` | 66 | 40 | yes: the constructor arguments, and the checks the constructor does not do |
| `keeper/keeper.ts`, `keeper/selection.ts`, `keeper/lock.ts` | 389 / 352 / 134 | 309 / 225 / 86 | optional: the open reference keeper, not deployed on chain |

**Out of scope:** the legacy contracts `0xE577…2104` and `0xED47…e6e5`; the Bitburo application (`pinheadio/bitburo`) and its own keeper, which mirrors `keeper/`; Privy; Uniswap, Chainlink, USDC and cbBTC themselves; `test/`; `deploy-mainnet.sh`.

### Compiler and dependencies

solc `0.8.37` (pragma pinned; released 10 September 2026), `via_ir = true`, optimizer 1,000 runs, `evm_version = cancun`. OpenZeppelin Contracts `v5.6.1` (`5fd1781b`), of which the contract uses `IERC20`, `IERC20Metadata`, `SafeERC20`, `ReentrancyGuardTransient` and `Math`. Foundry `1.5.1`.

### External contracts

All on Base, all passed to the constructor and immutable afterwards. The constructor checks that the treasury is not the zero address, that the router has code, the token and feed decimals, and that both feeds answer; `script/Deploy.s.sol` also checks that the router's factory resolves fee 500 to the pool below and that each feed carries the expected description. The contract itself never reads the pool.

| Role | Address | Notes |
|---|---|---|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | 6 decimals; counted as exactly one dollar |
| cbBTC | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` | 8 decimals |
| Uniswap SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` | only `exactInputSingle` is called |
| Pool USDC/cbBTC 0.05% | `0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef` | not called directly; on 22 Sept 2026 (block 51,640,408) it held 5,035,935 USDC and 24.38 cbBTC |
| Chainlink cbBTC/USD | `0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D` | 8 decimals, heartbeat 20 min, deviation 0.3%; see risk 10 |
| Chainlink L2 Sequencer Uptime | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` | answer 0 = up |
| Treasury | `0xD6a4f92C9c2c35B4816deC5147231226Fb7598a9` | an EOA; receives fees and alone can call `retire()` |

### Invariants and the tests that check them

`test/Rebalancer.t.sol` holds the unit and fuzz tests and two invariant suites (with and without `retire`); `test/RebalancerFork.t.sol` runs against the real tokens, router, pool and feeds.

1. **Custody.** A user's tokens only move in a run the rule prescribes, started by that user or the keeper they appointed, and the output only goes to that user. `test_execute_revertsForStranger`, `test_execute_replacedKeeperIsRefused`, `test_execute_ownerWithoutKeeper`, `test_execute_treasuryHasNoSpecialRights`, `invariant_onlyOwnerOrKeeperRuns`, `test_fork_strangerIsRefused`.
2. **Loss bound per run.** Against the Chainlink price a run loses at most `FEE_BPS + MAX_DEVIATION_BPS` = 80 bps, enforced on the measured balance difference, also when the router does not enforce its own minimum. `test_execute_lowerBound`, `test_execute_ownBoundHoldsWhenTheRouterDoesNotEnforceTheMinimum`, `test_execute_zeroOutputIsRefused`, `testFuzz_lossPerRunBoundedByFeePlusDeviation`, `invariant_lossPerRunWithinFeePlusDeviation`, `test_fork_pushedPoolAgainstTheRunIsRefused`.
3. **Upper bound.** A swap that yields more than 55 bps above the Chainlink value is refused, so a stuck feed or a USDC depeg halts both directions. `test_execute_upperBoundStopsARunThatIsTooGood`, `test_execute_usdcDepegStopsBothDirections`, `test_fork_poolFarBetterThanTheFeedIsRefused`.
4. **`minAmountOut` only tightens the bound.** `test_execute_minAmountOutCanOnlyTighten`, `test_fork_keeperCanDemandTheQuotedOutput`.
5. **The rule** (`_plan`, `Rebalancer.sol:279`). A correction starts only outside the band (exact comparison); a run is at most max(10% of the value, 5 USDC) and at least 5 USDC, goes towards the target and not past it, and is capped by balance and allowance; at most one run per owner per day; an unfinished correction continues on the next days and its flag expires after two days. `test_execute_buy_exactAmounts`, `test_execute_sell_exactAmounts`, `test_execute_bandEdgeDoesNotDependOnRounding`, `test_execute_correctionLargerThanTheCapIsFinishedOnTheNextDays`, `test_execute_unfinishedCorrectionExpiresAfterTwoIntervals`, `test_execute_followUpGoesToTheTargetFromEitherSide`, `testFuzz_runMovesTowardsTheTargetWithinTheCap`, `invariant_atMostOneRunPerInterval`, `invariant_runWithinMinimumAndCap`.
6. **Accounting.** Between calls the contract holds only uncollected fees and tokens sent to it by mistake, never cbBTC and never an allowance to the router, and what it holds never leaks into a run. A run in which the pool took only part of the input is refused, also when what arrived meets the bound. `invariant_contractHoldsOnlyUnsweptFeesAndDonations`, `invariant_routerAllowanceIsZeroBetweenCalls`, `test_sell_isNotAffectedByCollectedFees`, `test_execute_partialFillIsRefused`, `test_execute_partialFillWithinTheBoundIsRefused`, `test_fork_tokensLowerTheAllowanceOnTransferFrom`.
7. **Oracle.** The sequencer is up and past its grace period; the answer is above 0 and does not round to 0; it is at most 1,500 s old and not from the future. `test_quote_revertsSequencerDown`, `test_quote_revertsStaleFeed`, `test_quote_revertsInvalidAnswer`, `test_fork_feedIsFreshAndCloseToThePool`.
8. **`retire`, `stop` and the interval.** `test_retire_*`, `test_stop_*`, `test_setMandate_doesNotShortenTheInterval`, `invariant_noRunAfterRetire`.
9. **Reentrancy.** `test_sweep_maliciousTokenCannotReenter`, which fails without the guard.

### Known and accepted risks

1. **Trust in the keeper.** A dishonest keeper, or whoever composes its transactions, can trade around the run it triggers and push the owner's price to the lower bound: at most 0.55% of the traded amount, once a day, on at most 10% of the wallet, and only while a correction is due. This is the price of the owner-appointed keeper; the owner can replace it at any moment. Keepers must send plain transactions (see *Keepers must send plain transactions*).
2. **Feed lag.** The bound is against Chainlink, not against the market. cbBTC/USD may lag by its 0.3% deviation threshold, more in fast markets, and a dishonest keeper can time a run for that.
3. **USDC counts as one dollar.** Deliberate: with a USDC/USD feed the contract would sell cbBTC for sinking USDC during a depeg. Without one, a depeg of more than about 0.5% halts both directions.
4. **Changing or revoking is not atomic.** One more run within all bounds can be placed in front of a `stop()`, a keeper change or an `approve(0)`.
5. **One pool, one feed, one router, all immutable.** If any of them goes away, or Circle or Coinbase blocks the contract, runs stop and a new deployment is needed. Funds are never at risk from that; they are in the users' wallets. `MAX_FEED_AGE` (1,500 s) left 268 s above the largest heartbeat gap in a 59-hour sample taken on 18 September 2026.
6. **No splitting of large runs.** Measured on a fork of block 51,425,248: the 10% run of a wallet of 1, 2 and 3 million USDC landed 0.20%, 0.35% and 0.49% below Chainlink; the 400,000 USDC run of a 4 million wallet was refused by the bound. How much fits depends on the pool at that moment: on 21 September 2026 the pool stood 17 bps above the feed and a 100,000 USDC buy did not fit, while at the deploy block it did. `test_fork_runOf100kFitsTheBound` therefore skips itself when the pool stands more than 20 bps from the feed, and the fork suite should be run at a pinned block.
7. **Small wallets.** The minimum run is 5 USDC. Below 50 USDC that minimum is the budget, so one run can be most of a very small wallet; below about 100 USDC the band is effectively wider than 5%, because the drift must reach 5 USDC before a run is worth making. The minimum is set by rounding, not by economics: a run is measured in whole satoshi, and one satoshi is 1.7 bps of a 5 USDC run at 85,000 USDC per cbBTC and 5 bps at 250,000, against a price bound of 55 bps (at 1 USDC it would be 8.5 and 25 bps). It must also stay strictly positive: at 0, `unfinished = drift >= value + MIN_TRADE_USDC` is always true and every run would mark itself unfinished.
8. **Treasury blacklisted by Circle.** Runs continue, because no transfer to the treasury happens inside a run; `sweep(USDC)` reverts until the blacklist is lifted.
9. **Compiler age.** solc 0.8.37 was released on 10 September 2026, eleven days before the deploy.
10. **The feed is computed from DEX pools.** Chainlink's feed registry lists the Base cbBTC/USD feed with the methodology `dex_state_price`: end-of-block states of on-chain DEX pools, weighted by volume, with outlier and time-lag filters (docs.chain.link, "DEX State Price Streams"; the pools are not published). The price bound is therefore not fully independent of the pools on Base, possibly including the one the contract trades in. A push within one block (a sandwich) does not reach the answer; a push held across blocks and across those pools can, and a due run then trades at the moved answer, within the bound, while the attacker pays arbitrage against every monitored pool meanwhile. The alternative, Chainlink BTC/USD on Base (`0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F`: CEX prices, deviation 0.1%, heartbeat 20 min, 8 decimals), would need no change to the logic. In a 30-day sample taken on 18 September 2026, every 6 hours, the pool stood at most 15.3 bps from BTC/USD (p90 7.8) against 30.6 bps from cbBTC/USD (p90 21.0). The contract keeps cbBTC/USD; see question 6.
11. **A follow-up can trade back.** A run that leaves part of its correction undone lets the next day's run ignore the band. That run goes to the target at that day's price, so after a price move or the owner's own transfer it can trade in the opposite direction, inside the band (`test_execute_followUpGoesToTheTargetFromEitherSide`). Nobody can cause this for profit; the owner pays the fee and slippage on that trade.
12. **The treasury is a single EOA.** Its key can collect fees and stop the contract for good with `retire()`. It cannot touch funds, mandates or allowances, so a leaked treasury key means a halted contract, not lost funds.

### Questions for the auditors

1. Is the two-sided bound on the measured balance difference (`_swap`, `Rebalancer.sol:312-339`) a sound replacement for a separate pool-spot check, including its role as a halt during a USDC depeg or with a stuck feed? Is there a rounding or decimals case in which a run passes outside 55 bps, or in which honest runs of the minimum size can never pass?
2. Can any sequence of `setMandate`, `stop`, runs, price moves, donations and allowance changes bypass the daily interval, run inside the band without an unfinished correction, flip direction at a loss, or keep a wallet trading every day (`_finishing`, `:272`; `_plan`, `:279-308`)? A follow-up that reverses direction is known and accepted (risk 11).
3. The contract tells that the pool did not take all of the input by the allowance the router has left (`_swap`, `:337`). With SwapRouter02 and a v3 pool as deployed on Base, is there a partial-fill, callback or recipient case this misses, in which input or output ends up anywhere but the contract?
4. Is the keeper trust of risk 1 reasonable for an immutable contract, and is there a cheap on-chain measure that would shrink it further without returning to a permissionless `execute`?
5. Is pinning a recent compiler with `via_ir` the right call here, or would you have deployed with an older release whose known bugs this code cannot reach?
6. Would you keep the cbBTC/USD feed, which Chainlink computes from DEX pools (risk 10), or deploy with BTC/USD? How long and how widely would a push have to be held on Base to move the cbBTC/USD answer?

### Build and test

```bash
git clone https://github.com/pinheadio/bitburo-contracts && cd bitburo-contracts
git checkout audit-2026-09-22
git submodule update --init lib/openzeppelin-contracts   # forge-std is vendored
~/.foundry/bin/forge build --sizes                        # "forge" on PATH may be another tool
~/.foundry/bin/forge fmt --check
RUN_FORK=false ~/.foundry/bin/forge test                  # unit, fuzz, invariants; no RPC needed
FORK_BLOCK=51604724 ~/.foundry/bin/forge test             # everything, fork suite at the deploy block
FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=100 ~/.foundry/bin/forge test --match-test invariant
cd keeper && bun install && bun test && bunx tsc --noEmit
```

Results on 22 September 2026: `forge fmt --check` exit 0; `RUN_FORK=false`: 77 passed, 0 failed, 1 skipped (the fork suite); `FORK_BLOCK=51604724`: 87 passed, 0 failed (63 unit and fuzz, 2 × 7 invariants, 10 fork); deep invariants: 14 passed; keeper: 42 tests passed, `tsc` exit 0. The fork suite reads `BASE_RPC_URL` (default `https://mainnet.base.org`). The first live run on the deployed contract (tx `0xda082875c2812db7e0ee43fd07cd793f01b9217a12c8266cedf6c1da08fcc880`, a 5 USDC buy) used 242,494 gas.

## Contract interface

| Function | What |
|---|---|
| `setMandate(targetBps, keeper)` | Set or change your own mandate: the cbBTC share you want (`500`–`9500` bps) and the address that may run your wallet besides yourself (`address(0)` = only you). Does not shorten the interval. Reverts with `ContractRetired` after `retire`. |
| `stop()` | Revoke your mandate. Always works, also after `retire`. |
| `execute(owner, minAmountOut) → swapOutput` | One rebalance run. Only `owner` or the keeper that owner appointed; anyone else gets `NotOwnerOrKeeper`. `minAmountOut` can only make the price bound stricter (0 = only the Chainlink bound). Returns what the swap delivered (cbBTC for a buy, USDC before the fee for a sell), so a keeper can simulate with 0 and demand that amount in the transaction. |
| `isDue(owner) → (bool, int256)` | Would `execute` trade now, and how much USDC (+ buy, − sell, at the Chainlink price)? Same code path as `execute`. Reverts, like `execute`, when the sequencer or the price feed fails. It does not look at the pool: whether the price bound holds only shows when the swap runs, so simulate `execute` before sending it. |
| `quote() → uint256` | Chainlink price in USDC base units per cbBTC, with USDC counted as one dollar. |
| `mandates(owner) → (targetBps, lastExecutedAt, unfinished, keeper)` | The stored mandate. `targetBps` 0 = none. `unfinished` = the last run left part of its correction undone. |
| `sweep(token)` | Forwards the contract's whole balance of `token` to the treasury: the collected USDC fees, or tokens sent there by mistake. Anyone may call it. |
| `retire()` / `retired()` | Irreversible kill switch, only `TREASURY`. After it `execute` and `setMandate` revert and `isDue` reports nothing; `stop` and `sweep` keep working. It cannot touch funds or allowances. |

Constants (all fixed; another profile needs a new deployment): `BAND_BPS` 500, `MAX_CORRECTION_BPS` 1000 per run, `MIN_TRADE_USDC` 5 USDC, `INTERVAL` 1 day, `FEE_BPS` 25, `MAX_DEVIATION_BPS` 55, `POOL_FEE` 500, `MIN_TARGET_BPS` 500 / `MAX_TARGET_BPS` 9500, `GRACE_PERIOD` 1 hour, `MAX_FEED_AGE` 1500 s.

### The rule

`position` = cbBTC balance at the Chainlink price, `total` = USDC balance + `position`, `drift` = |`position` − `total` × target|.

- **Start.** A correction starts when `drift` > 5% of `total`. The comparison is exact: a wallet exactly on the edge of the band is not due, at any price. A target within 5% of 0% or 100% therefore only ever trades in one direction. The two ends of the range are the extreme case of that: a buy needs the position below `total` × (target − 500) / 10,000 and a sell needs it above `total` × (target + 500) / 10,000, so `MIN_TARGET_BPS` (500) can never buy and `MAX_TARGET_BPS` (9500) can never sell, whatever the wallet holds. Both are sell-only and buy-only mandates respectively, and a wallet that holds none of the token it would have to buy simply stays inside the band for good.
- **Size.** One run corrects the drift, at most max(10% of `total`, 5 USDC), capped by balance and allowance, and only if the run is worth at least 5 USDC. For wallets below 50 USDC the 5 USDC minimum is the budget, so there a run can be a fifth of the wallet.
- **Pace.** At most one run per owner per day.
- **Finish.** A run that leaves at least 5 USDC of its correction undone (the 10% cap, or the allowance) marks the mandate `unfinished`; the run of the next day then continues to the target, also inside the band. After two days without a run, or after `setMandate`, a correction starts from the band again. Measured in the unit suite: all cash with a 74% target reaches 74% in eight daily runs; without this rule it would stop near 70%.

### Price bound and maximum loss per run

The contract receives the swap output itself, measures it as a balance difference and requires it to lie within `MAX_DEVIATION_BPS` (0.55%) of the Chainlink value of the input, pool fee of 0.05% included, **in both directions**, and to be at least `minAmountOut`. Otherwise the run reverts (`OutsidePriceBounds`, or Uniswap's own `Too little received`).

- **Lower bound.** A run can lose at most `FEE_BPS + MAX_DEVIATION_BPS` = 0.80% against the Chainlink price, whatever anyone does to the pool. Against the market the feed's lag comes on top: cbBTC/USD updates at a 0.3% deviation or every 20 minutes.
- **Upper bound.** When the pool gives much *more* than Chainlink says, feed and pool disagree: a stuck feed, or a USDC depeg. The feed is cbBTC/USD and USDC counts as one dollar, so during a depeg the pool asks more USDC per cbBTC than the feed says: a buy then fails the lower bound and a sell the upper bound. The contract stands still instead of selling cbBTC for sinking USDC.
- Measured on a Base fork (block 51,425,248): a buy of 100,000 USDC landed 0.20% below Chainlink; a pool pushed 5% either way is refused.

### Who is trusted with what

| Actor | Can | Cannot |
|---|---|---|
| Owner | set, change and revoke their own mandate; run their own wallet; replace the keeper | touch anyone else's mandate |
| The keeper an owner appointed | choose the moment of a run and demand a better price | choose direction or amount, run more than once a day, trade outside the price bound, send output anywhere but the owner's wallet, run an owner who did not appoint it |
| Anyone | `sweep` to the treasury | send it anywhere else |
| Treasury | receive fees; `retire()` once | touch funds, mandates or allowances; undo `retire` |

**What a dishonest keeper can do.** It can trade around the run it triggers (push the pool, run, push back) and so move the owner's price down to the lower bound: at most 0.55% of the traded amount per run, one run per day, at most 10% of the wallet per run (5 USDC for the smallest wallets), and only while a correction is due. It cannot make a wallet due: that takes a donation of more than 5% of the wallet to gain at most 0.055% of it. Every run and its price are visible in `Executed`. The owner can replace the keeper at any moment, and the treasury can stop everything with `retire()`.

**Keepers must send plain transactions.** `execute` checks `msg.sender`, not who composed the transaction. If a keeper sends through a bundler or relayer (ERC-4337, a sponsored send), that party can wrap the call and trade around it. The keeper script therefore sends from its own key, straight to the sequencer, and passes the simulated output minus a small tolerance as `minAmountOut`, so that wrapping it gains nothing.

**Changing or revoking is not atomic.** A keeper that sees a `stop()`, a keeper change or an `approve(0)` before it lands can still place one run in front of it, within all the bounds above. Whoever wants no further run for sure sends `approve(0)` on both tokens first.

### Fee

25 bps of the USDC leg of every run: of the gross USDC for a buy, of the USDC received for a sell. The fee stays in the contract and `sweep(USDC)` forwards it to the treasury, so a run never depends on the treasury being able to receive (Circle can blacklist an address). Between transactions the contract holds nothing but those uncollected fees.

### Retiring the contract

`retire()` is the answer to two situations: a redeploy (old mandates must not stay active unnoticed) and an emergency (a leaked keeper key, a bug). Only the `TREASURY` key can call it and there is no way back (a second call changes nothing).

```bash
cast call <address> "retire()" --rpc-url https://mainnet.base.org --from <treasury-address>      # simulate first
cast send <address> "retire()" --rpc-url https://mainnet.base.org --account <treasury-keystore>
cast call <address> "retired()(bool)" --rpc-url https://mainnet.base.org                          # true
```

Afterwards users can still call `stop()` and `approve(0)`; neither is needed for safety, because nothing can use the allowance any more.

## Components

| Path | What |
|---|---|
| `src/Rebalancer.sol` | The contract. Solidity 0.8.37, OpenZeppelin 5.6.1, via-IR. |
| `src/interfaces/` | Minimal interfaces, self-written and MIT: the two Chainlink calls and the one SwapRouter02 call the contract makes. |
| `test/Rebalancer.t.sol` | Unit and fuzz tests with mocks, and the invariants (with and without `retire`). |
| `test/RebalancerFork.t.sol` | Fork tests against the real tokens, router, pool and feeds on Base, including the deploy script. |
| `script/Deploy.s.sol` | Deploy script with the verified Base addresses and the checks the constructor does not do. |
| `keeper/` | Keeper script in TypeScript. Anyone can run it for the owners who appointed them, or for their own wallet. |

## Commands

Foundry lives in `~/.foundry/bin` (the `forge` in PATH may be the Laravel Forge CLI).

```bash
~/.foundry/bin/forge build --sizes
RUN_FORK=false ~/.foundry/bin/forge test            # unit + fuzz + invariants, no RPC needed
FORK_BLOCK=<block> ~/.foundry/bin/forge test        # everything, fork suite at a fixed block (reproducible)
~/.foundry/bin/forge test                           # fork suite at the latest block (BASE_RPC_URL optional)
FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=100 ~/.foundry/bin/forge test --match-test invariant
```

Fork tests that need an honest run to pass skip themselves when the pool stands more than 0.40% from the feed at that block. Under `via_ir` Solidity caches `block.timestamp` within a test function, so after `vm.warp` use `vm.getBlockTimestamp()`.

Deploying to Base mainnet:

```bash
cast wallet import bitburo-deployer --interactive     # one-off, puts the key in a keystore
DEPLOYER_ACCOUNT=bitburo-deployer bash deploy-mainnet.sh dry
DEPLOYER_ACCOUNT=bitburo-deployer bash deploy-mainnet.sh go
DEPLOYER_ACCOUNT=bitburo-deployer bash deploy-mainnet.sh verify
```

`go` refuses as long as there is already a deploy in `broadcast/`; use `FORCE_REDEPLOY=1` for a deliberate new deployment. `verify` refuses on another commit than the deployed one or with uncommitted changes in `src/` or `script/`. A test deployment with `forge script --broadcast` against a local fork with chain id 8453 also writes `broadcast/Deploy.s.sol/8453/run-latest.json`, the record `verify` relies on; point `FOUNDRY_BROADCAST` and `FOUNDRY_CACHE_PATH` somewhere else for that.

Keeper script (from `keeper/`):

```bash
bun install
RPC_URL=https://mainnet.base.org REBALANCER=0x… FROM_BLOCK=<deploy block> DRY_RUN=1 KEEPER_ADDRESS=0x… bun run keeper.ts
RPC_URL=… REBALANCER=0x… FROM_BLOCK=<deploy block> KEEPER_PRIVATE_KEY=0x… bun run keeper.ts
bun test            # the pure logic in selection.ts and the lock
bun run typecheck
```

One run of the script: find the owners that named this keeper (the `MandateSet` events from `FROM_BLOCK`, remembered in `keeper-owners.json`, plus an optional `OWNERS_FILE`), ask `mandates` and `isDue` per page in a Multicall3 (owners that no longer name this keeper are forgotten, so that events naming it for empty or foreign wallets do not make the list grow for ever), simulate `execute(owner, 0)` for every due owner, and send `execute(owner, simulated output − TOLERANCE_BPS)` as a plain transaction. Market and oracle conditions and a state that changed since `isDue` are skipped until the next run; any other revert puts the owner on a cool-down that doubles per failure (`keeper-cooldowns.json`). One run at a time (`keeper.lock`), and nothing is sent while an earlier transaction of the key is still pending. The contract allows one run per owner per day, so every 10 to 60 minutes is plenty. All settings: the header of `keeper/keeper.ts`.

The script was run end to end against a local anvil fork of Base on 17 September 2026 (real router, pool and feeds): it found the owner from the event, ran a buy of 1,000 USDC and a sell of 0.02 cbBTC, found nothing to do in the next run, and forgot an owner that called `stop()`.

## Deployment run book

What a mainnet deploy looked like on 21 September 2026, in the order it has to happen. Every step here caught something at least once.

**Before the deploy**

1. `~/.foundry/bin/forge clean && ~/.foundry/bin/forge build`. Without it `forge` reports "compilation skipped" and deploys bytecode from a cache that may hold artifacts of files that no longer exist. A deploy cannot be undone; a two-minute rebuild can.
2. `~/.foundry/bin/forge test` on that clean build. On 21 September this alone turned up a fuzz counterexample the cached run had not produced.
3. Fuzz far past the default: `--fuzz-runs 20000` for the suite, `--fuzz-runs 150000 --match-test testFuzz_`. The two rounding bugs of that day appeared at 20,000 and never at 256.
4. Changed a constant? Grep the tests for assumptions that leaned on the old value — a header saying "the smallest run is >= 8,000 sats" silently encodes `MIN_TRADE_USDC` at 20 USDC and stops being true the moment you lower it.
5. Check the deployer's balance and today's gas price: `cast balance <deployer> --rpc-url <base> --ether` and `cast gas-price`. A deploy is around 1.58M gas.
6. Read the deployer's nonce and compute the address it will produce: `cast nonce` then `cast compute-address <deployer> --nonce <n>`. Knowing the address in advance lets you prepare the app's configuration, and it warns you not to send anything else from that key until the deploy has landed.
7. `deploy-mainnet.sh dry`. It runs the three on-chain checks the constructor does not — the router's USDC/cbBTC 0.05% pool, the cbBTC/USD feed and the sequencer feed — and prints `quote()` and the treasury as the contract stored it. Check that price against the market — a dead feed shows up here — and check the treasury letter by letter: it receives every fee and alone can call `retire()`, and it can never be changed after the deploy.
8. Prove the constant you changed is really in the bytecode: `forge inspect src/Rebalancer.sol:Rebalancer bytecode` and grep for its hex (5,000,000 is `4c4b40`). Cheap, and it rules out a stale build for good.

**The deploy**

9. `FORCE_REDEPLOY=1 bash deploy-mainnet.sh go`, with `BASESCAN_API_KEY` loaded so verification runs straight away. The flag is needed whenever `broadcast/` still holds an earlier deploy; it is a brake, not an error.
10. Write the address, block and commit down outside this machine. `broadcast/` is gitignored.

**After the deploy**

11. Read the deployed contract back over RPC — constants, token addresses, treasury, `retired()`, `quote()` — rather than trusting the deploy log.
12. Record address, block, tx and commit in the Deployments table above.
13. In the app: `BITBURO_REBALANCER_ADDRESS` and `BITBURO_REBALANCER_DEPLOY_BLOCK` together, never one without the other, or the sweep searches a quarter of a million empty blocks. Leave `BITBURO_REBALANCER_LEGACY_ADDRESSES` empty when nobody holds an allowance on the previous contract; check that on chain rather than assuming it.
14. `php artisan bitburo:setup-keeper-wallet --update`, or Privy refuses every keeper send. One policy serves test and production, so this takes effect immediately in both.
15. Prove the chain is readable end to end before anyone signs a mandate: `bitburo:sweep-executions` (books nothing yet, but must complete) and `bitburo:run-keeper --dry-run` (reads the contract, checks it is not retired, sends nothing).

## Standing rules

- Never deploy to mainnet without Arjan's explicit approval.
- No keys or `.env` files in git. The gitleaks hook must pass.
- Contract changes always with tests, including the fork tests.
