# bitburo-contracts

Bitburo's immutable `Rebalancer` contract for Base mainnet, plus the keeper script that runs it.

The user keeps USDC and cbBTC in their own wallet, gives the contract an ERC-20 allowance on both and calls `setMandate` with the cbBTC share they want and the keeper that may run it. When the wallet drifts more than 5% of its value away from that share, the owner or that keeper calls `execute`: the contract pulls the input token, swaps it in the Uniswap v3 USDC/cbBTC 0.05% pool, checks the result against Chainlink and sends the output back to the wallet. Bitburo holds no key that can touch funds or mandates; the treasury's only power is the one-time kill switch `retire()`.

Only the owner and the keeper the owner appoints can start a run. That is a deliberate trade: a contract anyone may call has to defend every run against the caller itself (who can move the pool around the run), which takes far more code than the rebalance does. Here a keeper is trusted within the contract's bounds, can be replaced by the owner at any time, and the owner can always run their own wallet.

## Deployments

| What | Address | Note |
|---|---|---|
| Rebalancer (this code) | `0x1Df884A2A28BbD729714D4f9697972293872BB42` | Live since 21 September 2026, block 51,604,724, tx `0xc062d3a63e5d4d995162a66471f462c7d09574d5c686fbc1c18dfa5f7c1b0ce4`. Code: commit `ef39299`. Verified on Basescan. |
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

### Known limits

- **One pool, one feed, one router, all immutable.** If the USDC/cbBTC 0.05% pool dries up, Chainlink replaces the cbBTC/USD feed or Circle or Coinbase blocks the contract, runs stop and a new deployment is needed. Funds are never at risk from that: they are in the users' wallets.
- **Large wallets.** There is no splitting of a run. Measured on a fork of block 51,425,248 (pool depth ~3,350 USDC per bp): the 10% run of a wallet of 1, 2 and 3 million USDC landed 0.20%, 0.35% and 0.49% below Chainlink; the 400,000 USDC run of a 4 million wallet was refused by the bound and stays refused until the pool is deeper.
- **Settings are constants.** Band, cap, interval, minimum and price bound cannot be changed per user.

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
7. `deploy-mainnet.sh dry`. It runs the three on-chain checks the constructor does not — the router's USDC/cbBTC 0.05% pool, the cbBTC/USD feed and the sequencer feed — and prints `quote()`. Check that price against the market: a dead feed shows up here.
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
