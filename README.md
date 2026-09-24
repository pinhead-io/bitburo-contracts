# bitburo-contracts

> **Audit version:** tag `audit-2026-09-22`. Its `src/` is identical to commit `d6f81f9`, deployed on Base at `0xc80b56e539c45CEB593410EdCc65F0157f80597d`. The `src/` in this checkout differs from both: a run also takes a remainder of the drift below the minimum (see *The rule*). That change is neither audited nor deployed; a new audit tag will follow.

Bitburo's immutable `Rebalancer` contract for Base mainnet, plus the keeper script that runs it.

The user keeps USDC and cbBTC in their own wallet, gives the contract an ERC-20 allowance on both and calls `setMandate` with the cbBTC share they want and the keeper that may run it. When the wallet drifts more than 2% of its value away from that share, the owner or that keeper calls `execute`: the contract pulls the input token, swaps it in the Uniswap v3 USDC/cbBTC 0.05% pool, checks the result against Chainlink and sends the output back to the wallet. Bitburo holds no key that can touch funds or mandates; the treasury's only power is the one-time kill switch `retire()`.

Only the owner and the keeper the owner appoints can start a run. That is a deliberate trade: a contract anyone may call has to defend every run against the caller itself (who can move the pool around the run), which takes far more code than the rebalance does. Here a keeper is trusted within the contract's bounds, can be replaced by the owner at any time, and the owner can always run their own wallet.

## What Bitburo is

Bitburo is a web application in private beta that keeps a user's wallet at a fixed split between Bitcoin and dollars: today 80% cbBTC and 20% USDC for every user, on Base. The user never hands over funds. They sign in with Privy, which gives them an embedded wallet on Base, and give this contract a mandate over that wallet. From then on the contract rebalances the wallet towards the target once a day at most, whenever it has drifted far enough, and the app shows the result.

The application is the interface; this contract does the work. That split is deliberate: Bitburo should not take custody of funds or make trading decisions of its own. So:

- **The funds stay in the user's wallet.** The contract pulls only what a run needs, swaps it and sends the output straight back. Between transactions it holds nothing but collected fees.
- **The rule is in the contract, not in Bitburo's servers.** Direction, size, timing limits and the price bound are constants in immutable code. Bitburo's keeper only decides *when* to call `execute`, and may demand a better price than the contract's own bound.
- **The user can leave at any moment**, with `stop()` or by revoking the allowance, and the contract keeps working without Bitburo: anyone can run the open keeper script in `keeper/` for their own wallet, or appoint someone else.
- **Nothing in this contract gives Bitburo a way to move a user's funds.** Its keeper can only call `execute` for owners who appointed it, within the rule; the treasury can only receive fees and, once, `retire()` the contract.

How the application uses the contract:

| Step | Who | What |
|---|---|---|
| Mandate | the user, in the browser | Signs `approve` for USDC and cbBTC and `setMandate(8000, <Bitburo keeper>)`. Privy sponsors the gas, so the user needs no ETH. |
| Run | Bitburo's keeper, hourly | Reads `mandates` and `isDue` for its own users through Multicall3, simulates `execute(owner, 0)` from the keeper address, then sends `execute(owner, simulated − 10 bps)` as a plain transaction with a fixed gas limit of 500,000. The keeper is a Privy server wallet (`0xDE89810E6a9013860FE1e529b349C7ba906C8f56`) whose Privy policy allows only `execute(address,uint256)` on this contract. It pays its own gas; it is deliberately not sponsored (see *Keepers must send plain transactions* below). |
| Booking | Bitburo's server, hourly | Reads the `Executed` logs up to the chain's safe block and books them in the app's ledger, so a run the owner started himself is recorded too. |
| Revenue | anyone | 25 bps of the USDC leg of every run stays in the contract until someone calls `sweep(USDC)`, which sends it to the treasury. |

**Status.** Live on Base since 22 September 2026 (address below). Private beta: no third-party funds will be accepted until this audit is concluded.

## Deployments

| What | Address | Note |
|---|---|---|
| Rebalancer (live) | `0xc80b56e539c45CEB593410EdCc65F0157f80597d` | Live since 22 September 2026, block 51,657,846, tx `0xa3a15fe3a2f75673fa1598c4df86ef9cb2c963b0f789ed285f4c63e93885e557`. Code: commit `d6f81f9`. Verified on Basescan. Replaces `0x1Df884A2A28BbD729714D4f9697972293872BB42` (band 5%, minimum 5 USDC, block 51,604,724, commit `ef39299`), which stays on chain without mandates. |

## Audit reference

### Version

- **Tag:** `audit-2026-09-22`. `development` moves on as new work is merged; the tag does not.
- **Source:** `src/` is identical at the tag and at commit `d6f81f9`, from which the live contract was deployed (`git diff --quiet d6f81f9 audit-2026-09-22 -- src/`). The `src/` in this checkout is not: it adds the remainder rule under *Size*. A new audit tag will follow.
- **Deployed:** `0xc80b56e539c45CEB593410EdCc65F0157f80597d` on Base (chain id 8453), block 51,657,846, verified on Basescan. Runtime bytecode 6,705 bytes.

### Files

nSLOC: comment lines and blank lines removed, every remaining line counted.

| File | Lines | nSLOC |
|---|---|---|
| `src/Rebalancer.sol` | 349 | 217 |
| `src/interfaces/IV3SwapRouter.sol` | 21 | 13 |
| `src/interfaces/IAggregatorV3.sol` | 12 | 8 |
| `script/Deploy.s.sol` | 66 | 40 |
| `keeper/keeper.ts` | 389 | 309 |
| `keeper/selection.ts` | 352 | 225 |
| `keeper/lock.ts` | 134 | 86 |

### Compiler and dependencies

solc `0.8.37` (pragma pinned; released 10 September 2026), `via_ir = true`, optimizer 1,000 runs, `evm_version = cancun`. OpenZeppelin Contracts `v5.6.1` (`5fd1781b`), of which the contract uses `IERC20`, `IERC20Metadata`, `SafeERC20`, `ReentrancyGuardTransient` and `Math`. Foundry `1.5.1`.

### External contracts

All on Base, all passed to the constructor and immutable afterwards. The constructor checks that the treasury is not the zero address, that the router has code, the token and feed decimals, and that both feeds answer; `script/Deploy.s.sol` also checks that the router's factory resolves fee 500 to the pool below and that each feed carries the expected description. The contract itself never reads the pool.

| Role | Address | Notes |
|---|---|---|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | 6 decimals |
| cbBTC | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` | 8 decimals |
| Uniswap SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` | only `exactInputSingle` is called |
| Pool USDC/cbBTC 0.05% | `0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef` | not called directly |
| Chainlink cbBTC/USD | `0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D` | 8 decimals, heartbeat 20 min, deviation 0.3% |
| Chainlink L2 Sequencer Uptime | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` | answer 0 = up |
| Treasury | `0xD6a4f92C9c2c35B4816deC5147231226Fb7598a9` | an EOA |

### Build and test

```bash
git clone https://github.com/mediaproc/bitburo-contracts && cd bitburo-contracts
git checkout audit-2026-09-22
git submodule update --init lib/openzeppelin-contracts   # forge-std is vendored
~/.foundry/bin/forge build --sizes                        # "forge" on PATH may be another tool
~/.foundry/bin/forge fmt --check
RUN_FORK=false ~/.foundry/bin/forge test                  # unit, fuzz, invariants; no RPC needed
FORK_BLOCK=51657846 ~/.foundry/bin/forge test             # everything, fork suite at the deploy block
FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=100 ~/.foundry/bin/forge test --match-test invariant
cd keeper && bun install && bun test && bunx tsc --noEmit
```

Results on 24 September 2026, for this checkout rather than the tag: `forge fmt --check` exit 0; `RUN_FORK=false`: 81 passed, 0 failed, 1 skipped (the fork suite); `FORK_BLOCK=51657846`: 91 passed, 0 failed; deep invariants: 14 passed; keeper: 42 tests passed, `tsc` exit 0. The fork suite reads `BASE_RPC_URL` (default `https://mainnet.base.org`).

## Contract interface

| Function | What |
|---|---|
| `setMandate(targetBps, keeper)` | Set or change your own mandate: the cbBTC share you want (`500`–`9500` bps) and the address that may run your wallet besides yourself (`address(0)` = only you). Does not shorten the interval. Reverts with `ContractRetired` after `retire`. |
| `stop()` | Revoke your mandate. Always works, also after `retire`. |
| `execute(owner, minAmountOut) → swapOutput` | One rebalance run. Only `owner` or the keeper that owner appointed; anyone else gets `NotOwnerOrKeeper`. `minAmountOut` can only make the price bound stricter (0 = only the Chainlink bound). Returns what the swap delivered (cbBTC for a buy, USDC before the fee for a sell), so a keeper can simulate with 0 and demand that amount in the transaction. |
| `isDue(owner) → (bool, int256)` | Would `execute` trade now, and how much USDC (+ buy, − sell, at the Chainlink price)? Same code path as `execute`. Reverts, like `execute`, when the sequencer or the price feed fails. It does not look at the pool: whether the price bound holds only shows when the swap runs, so simulate `execute` before sending it. |
| `quote() → uint256` | Chainlink price in USDC base units per cbBTC, with USDC counted as one dollar. |
| `mandates(owner) → (targetBps, lastExecutedAt, unfinished, keeper)` | The stored mandate. `targetBps` 0 = none. `unfinished` = the last run left at least 2 USDC of its correction undone. |
| `sweep(token)` | Forwards the contract's whole balance of `token` to the treasury: the collected USDC fees, or tokens sent there by mistake. Anyone may call it. |
| `retire()` / `retired()` | Irreversible kill switch, only `TREASURY`. After it `execute` and `setMandate` revert and `isDue` reports nothing; `stop` and `sweep` keep working. It cannot touch funds or allowances. |

Constants (all fixed; another profile needs a new deployment): `BAND_BPS` 200, `MAX_CORRECTION_BPS` 1000 per run (plus a remainder below the minimum), `MIN_TRADE_USDC` 2 USDC, `INTERVAL` 1 day, `FEE_BPS` 25, `MAX_DEVIATION_BPS` 55, `POOL_FEE` 500, `MIN_TARGET_BPS` 500 / `MAX_TARGET_BPS` 9500, `GRACE_PERIOD` 1 hour, `MAX_FEED_AGE` 1500 s.

### The rule

`position` = cbBTC balance at the Chainlink price, `total` = USDC balance + `position`, `drift` = |`position` − `total` × target|.

- **Start.** A correction starts when `drift` > 2% of `total`. The comparison is exact: a wallet exactly on the edge of the band is not due, at any price. A buy needs the position below `total` × (target − 200) / 10,000 and a sell needs it above `total` × (target + 200) / 10,000. A target within 2% of 0% or 100% would only ever trade in one direction, but the range (500 to 9500) stays clear of that: every mandate can trade both ways.
- **Size.** One run corrects the drift, at most max(10% of `total`, 2 USDC). When that would leave less than 2 USDC of the drift, too little for a run of its own, the run takes the whole drift instead, so a correction ends on the target rather than just short of it. The fee is not compensated: such a run still ends off the target by part of its fee. Balance and allowance cap the run after that, and it only goes ahead if it is worth at least 2 USDC. For wallets below 20 USDC the 2 USDC minimum is the budget, so there a run can be a fifth of the wallet, and just under 4 USDC when it takes the remainder. A run of the minimum is measured in whole satoshi: up to 100,000 USDC per cbBTC one satoshi is at most 5 bps of it, so a pool 50 bps off the feed still executes; above that price such a run can revert on a pool that far off, harmlessly, until the next attempt.
- **Pace.** At most one run per owner per day.
- **Finish.** A run that leaves at least 2 USDC of its correction undone (the 10% cap, or the balance or allowance) marks the mandate `unfinished`; the run of the next day then continues to the target, also inside the band. The cap never leaves less than 2 USDC, but balance or allowance can; such a remainder is not followed up. After two days without a run, or after `setMandate`, a correction starts from the band again. Measured in the unit suite: all cash with a 71% target reaches 71% in eight daily runs; without this rule it would stop near 70%.

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

**What a dishonest keeper can do.** It can trade around the run it triggers (push the pool, run, push back) and so move the owner's price down to the lower bound: at most 0.55% of the traded amount per run, one run per day, at most 10% of the wallet plus less than 2 USDC per run (less than 4 USDC for the smallest wallets), and only while a correction is due. It cannot make a wallet due: that takes a donation of more than 2% of the wallet to gain at most 0.055% of it. Every run and its price are visible in `Executed`. The owner can replace the keeper at any moment, and the treasury can stop everything with `retire()`.

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
8. Prove the constant you changed is really in the bytecode: `forge inspect src/Rebalancer.sol:Rebalancer bytecode` and grep for its hex (2,000,000 is `1e8480`). Cheap, and it rules out a stale build for good.

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
