# bitburo-contracts

Bitburo's immutable `Rebalancer` contract for Base mainnet, plus the keeper script that runs it.

The user keeps USDC and cbBTC in their own wallet, gives the contract an ERC-20 allowance on both and calls `setMandate` with the cbBTC share they want and the keeper that may run it. When the wallet drifts more than 5% of its value away from that share, the owner or that keeper calls `execute`: the contract pulls the input token, swaps it in the Uniswap v3 USDC/cbBTC 0.05% pool, checks the result against Chainlink and sends the output back to the wallet. Bitburo holds no key that can touch funds or mandates; the treasury's only power is the one-time kill switch `retire()`.

Only the owner and the keeper the owner appoints can start a run. That is a deliberate trade: a contract anyone may call has to defend every run against the caller itself (who can move the pool around the run), which takes far more code than the rebalance does. Here a keeper is trusted within the contract's bounds, can be replaced by the owner at any time, and the owner can always run their own wallet. The risks this leaves are listed in [`audit/SCOPE.md`](audit/SCOPE.md).

## Deployments

| What | Address | Note |
|---|---|---|
| Rebalancer (this code) | not deployed yet | Deploy only after Arjan's explicit approval. |
| Rebalancer v1.1 (EURC, permissionless) | `0xE577D68948883FDF8e2694e38dF656D2D9CA2104` | Legacy. Predates `retire()`; users revoke with `setParams(active = false)` and `approve(0)`. Code: tag `v1.1.0` and commit `b3ca31a`. |
| Rebalancer v1.0 | `0xED47…e6e5` | Legacy. |

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

Constants (all fixed; another profile needs a new deployment): `BAND_BPS` 500, `MAX_CORRECTION_BPS` 1000 per run, `MIN_TRADE_USDC` 20 USDC, `INTERVAL` 1 day, `FEE_BPS` 25, `MAX_DEVIATION_BPS` 55, `POOL_FEE` 500, `MIN_TARGET_BPS` 500 / `MAX_TARGET_BPS` 9500, `GRACE_PERIOD` 1 hour, `MAX_FEED_AGE` 1500 s.

### The rule

`position` = cbBTC balance at the Chainlink price, `total` = USDC balance + `position`, `drift` = |`position` − `total` × target|.

- **Start.** A correction starts when `drift` > 5% of `total`. The comparison is exact: a wallet exactly on the edge of the band is not due, at any price. A target within 5% of 0% or 100% therefore only ever trades in one direction.
- **Size.** One run corrects the drift, at most max(10% of `total`, 20 USDC), capped by balance and allowance, and only if the run is worth at least 20 USDC. For wallets below 200 USDC the 20 USDC minimum is the budget, so there a run can be most of the wallet.
- **Pace.** At most one run per owner per day.
- **Finish.** A run that leaves at least 20 USDC of its correction undone (the 10% cap, or the allowance) marks the mandate `unfinished`; the run of the next day then continues to the target, also inside the band. After two days without a run, or after `setMandate`, a correction starts from the band again. Measured in the unit suite: all cash with a 74% target reaches 74% in eight daily runs; without this rule it would stop near 70%. The follow-up goes to the target from whichever side: if a price move or the owner's own transfer took the wallet past the target in the meantime, it trades back, also inside the band (a 10,000 USDC wallet that bought 1,000 USDC sells 43 USDC the next day after cbBTC rose 3%).

### Price bound and maximum loss per run

The contract receives the swap output itself, measures it as a balance difference and requires it to lie within `MAX_DEVIATION_BPS` (0.55%) of the Chainlink value of the input, pool fee of 0.05% included, **in both directions**, and to be at least `minAmountOut`. The pool must also have taken all of the input: SwapRouter02 does not check that, and a pool that runs dry takes only part of it, which would leave the rest in the contract and send it to the treasury with the next `sweep`. Otherwise the run reverts (`OutsidePriceBounds`, or Uniswap's own `Too little received`).

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

**What a dishonest keeper can do.** It can trade around the run it triggers (push the pool, run, push back) and so move the owner's price down to the lower bound: at most 0.55% of the traded amount per run, one run per day, at most 10% of the wallet per run (20 USDC for the smallest wallets), and only while a correction is due. It cannot make a wallet due: that takes a donation of more than 5% of the wallet to gain at most 0.055% of it. Every run and its price are visible in `Executed`. The owner can replace the keeper at any moment, and the treasury can stop everything with `retire()`.

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

### Known limits

- **One pool, one feed, one router, all immutable.** If the USDC/cbBTC 0.05% pool dries up, Chainlink replaces the cbBTC/USD feed or Circle or Coinbase blocks the contract, runs stop and a new deployment is needed. Funds are never at risk from that: they are in the users' wallets.
- **Large wallets.** There is no splitting of a run. Measured on a fork of block 51,425,248 (pool depth ~3,350 USDC per bp): the 10% run of a wallet of 1, 2 and 3 million USDC landed 0.20%, 0.35% and 0.49% below Chainlink; the 400,000 USDC run of a 4 million wallet was refused by the bound and stays refused until the pool is deeper.
- **Settings are constants.** Band, cap, interval, minimum and price bound cannot be changed per user.
- **The feed is computed from DEX pools.** Chainlink lists the Base cbBTC/USD feed with the methodology `dex_state_price`: end-of-block states of onchain DEX pools, weighted by volume, with outlier and time-lag filters. A push inside one block does not reach it, but a push held long enough across those pools can move the answer, and with it the price bound. See `audit/SCOPE.md` §4.

## Components

| Path | What |
|---|---|
| `src/Rebalancer.sol` | The contract. Solidity 0.8.37, OpenZeppelin 5.6.1, via-IR. |
| `src/interfaces/` | Minimal interfaces, self-written and MIT: the two Chainlink calls and the one SwapRouter02 call the contract makes. |
| `test/Rebalancer.t.sol` | Unit and fuzz tests with mocks, and the invariants (with and without `retire`). |
| `test/RebalancerFork.t.sol` | Fork tests against the real tokens, router, pool and feeds on Base, including the deploy script. |
| `script/Deploy.s.sol` | Deploy script with the verified Base addresses and the checks the constructor does not do. |
| `keeper/` | Keeper script in TypeScript. Anyone can run it for the owners who appointed them, or for their own wallet. |
| `audit/` | The package for the external audit: scope, accepted risks and questions (`SCOPE.md`), the internal review of this code (`REVIEW.md`), the static analysis (`static/`, produced by `run-static.sh`) and the Medusa/Echidna harness (`fuzz/`). |

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

## Standing rules

- Never deploy to mainnet without Arjan's explicit approval.
- No keys or `.env` files in git. The gitleaks hook must pass.
- Contract changes always with tests, including the fork tests.
