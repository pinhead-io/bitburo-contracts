# bitburo-contracts

The smart contract behind [Bitburo](https://bitburo.nl), and the keeper script that runs it.

Bitburo keeps your wallet at a fixed split between Bitcoin and dollars: 80% cbBTC and 20% USDC, on Base. Your funds never leave your own wallet. You give this contract permission to rebalance it, and at most once a day, when the wallet has drifted far enough from the split, the contract swaps the difference on Uniswap and sends the result straight back to you. Bitburo cannot withdraw your funds, and you can stop at any moment.

- **Live contract:** [`0x0C83C3785deF69B25c08b190C607D5890dfACE66`](https://basescan.org/address/0x0C83C3785deF69B25c08b190C607D5890dfACE66) on Base, verified on Basescan
- **Audit:** [softstack, October 2026](https://softstack.io/audits/bitburo)
- **Licence:** MIT
- **Contact and security reports:** hallo@bitburo.nl

## How it works

1. **You give a mandate.** In the app you sign three transactions: an `approve` on USDC, an `approve` on cbBTC, and `setMandate(8000, <Bitburo's keeper>)`, where 8000 means 80.00% cbBTC. The app's wallet provider, Privy, pays the gas, so you need no ETH.
2. **The keeper checks every hour.** Bitburo's keeper asks the contract whether your wallet is due: whether it has drifted more than 2% of its value away from the target, and had no run in the last day.
3. **The contract trades.** For a wallet that is due, the keeper calls `execute`. The contract pulls only what the run needs, swaps it in the Uniswap v3 USDC/cbBTC 0.05% pool, checks the price against Chainlink, and sends the output straight to your wallet. One run corrects at most 10% of the wallet; a larger drift is finished over the next days.
4. **The fee.** 0.25% of the USDC side of every run stays in the contract. Once a day it is forwarded to Bitburo's treasury.

## What Bitburo can and cannot do

The rules live in the contract, not on Bitburo's servers. Direction, size, timing and the price bound are constants in immutable code. Nobody can change them, Bitburo included.

- **Your funds stay in your wallet.** Between transactions the contract holds nothing but collected fees.
- **Bitburo's keeper only decides *when*.** It can also demand a better price than the contract's own bound. It cannot choose the direction or the amount, run more than once a day, trade outside the price bound, or send anything anywhere but your wallet.
- **Bitburo's treasury** receives the fees and can switch the whole contract off once, with `retire()`. It cannot touch funds, mandates or allowances.
- **You do not need Bitburo.** You can appoint another keeper, or run the open keeper script in `keeper/` for your own wallet.

Bitburo's keeper is a Privy server wallet, [`0xDE89810E6a9013860FE1e529b349C7ba906C8f56`](https://basescan.org/address/0xDE89810E6a9013860FE1e529b349C7ba906C8f56). Its Privy policy allows only `execute(address,uint256)`, and `sweep(address)` with the USDC address, on this contract. It pays its own gas.

## How to stop

Use the wallet that gave the mandate, with any tool that can sign for it (for example the *Write Contract* tab on Basescan):

1. **Revoke the allowances first.** Call `approve(0x0C83C3785deF69B25c08b190C607D5890dfACE66, 0)` on [USDC](https://basescan.org/token/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) and on [cbBTC](https://basescan.org/token/0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf). From then on the contract cannot move anything from your wallet.
2. **Then remove the mandate** with `stop()` on the contract.

The order matters. A keeper that sees your `stop()` before it lands can still place one last run in front of it, within all the limits below. Revoking the allowances first rules that out.

## Risks

- **Smart contract risk.** The code has been audited, but an audit is no guarantee. The contract is immutable: a bug cannot be patched, only stopped with `retire()`, after which you give a new mandate to a new contract.
- **Price per run.** A run can end at most 0.80% below the Chainlink price: 0.25% fee plus a 0.55% price bound. The feed's own lag comes on top (it updates at a 0.3% move or every 20 minutes).
- **A dishonest keeper** can time a run and trade around it, pushing your price down to that bound: at most 0.55% of the traded amount per run, one run a day, at most 10% of the wallet per run. You can replace the keeper at any moment. See [Who is trusted with what](#who-is-trusted-with-what).
- **USDC.** During a USDC depeg the contract stands still instead of selling cbBTC for sinking dollars. If Circle blacklists the contract, every run stops; your funds are in your own wallet and are not affected.
- **Base and Chainlink.** When the Base sequencer is down, or came back up less than an hour ago, or the price feed is stale, the contract refuses to trade rather than trade blind.

## Contract and audit

| What | Address | Note |
|---|---|---|
| Rebalancer (live) | `0x0C83C3785deF69B25c08b190C607D5890dfACE66` | Live since 1 October 2026, block 52,034,272, tx `0x08c18b0ac3e77c8bec825287867d28ba23e72f5d41823990f87fbfe554731ae2`. Code: `src/` at tag `audit-2026-10-01`. |

**Audit.** [softstack](https://softstack.io/audits/bitburo) audited `src/Rebalancer.sol` and `keeper/keeper.ts` at commit `b5ed2cb` (tag `audit-2026-10-01`), completed on 6 October 2026: 4 findings, 1 low and 3 informational. The report records how each finding was handled. Code that changed after that tag is outside the audit.

**Check it yourself.** The deployed runtime bytecode (6,794 bytes) is identical to a build of the tag apart from the six immutables. Build it with solc `0.8.37`, `via_ir = true`, optimizer 1,000 runs, `evm_version = cancun`, OpenZeppelin Contracts `v5.6.1` and Foundry `1.5.1` (see [Development](#development)).

### External contracts

All on Base, all passed to the constructor and immutable afterwards. The constructor checks that the treasury is not the zero address, that the router has code, the token and feed decimals, and that both feeds answer; `script/Deploy.s.sol` also checks that the router's factory resolves fee 500 to the pool below and that each feed carries the expected description. The contract itself never reads the pool.

| Role | Address | Notes |
|---|---|---|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | 6 decimals |
| cbBTC | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` | 8 decimals |
| Uniswap SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` | only `exactInputSingle` is called |
| Pool USDC/cbBTC 0.05% | `0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef` | not called directly |
| Chainlink cbBTC/USD | `0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D` | 8 decimals, heartbeat 20 min, deviation 0.3% |
| Chainlink L2 Sequencer Uptime | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` | answer 0 = up; refreshed once a day, refused when older than 3 days |
| Treasury | `0xD6a4f92C9c2c35B4816deC5147231226Fb7598a9` | an EOA |

## Technical reference

### Contract interface

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

Constants (all fixed; another profile needs a new deployment): `BAND_BPS` 200, `MAX_CORRECTION_BPS` 1000 per run (plus a remainder below the minimum), `MIN_TRADE_USDC` 2 USDC, `INTERVAL` 1 day, `FEE_BPS` 25, `MAX_DEVIATION_BPS` 55, `POOL_FEE` 500, `MIN_TARGET_BPS` 500 / `MAX_TARGET_BPS` 9500, `GRACE_PERIOD` 1 hour, `MAX_FEED_AGE` 1500 s, `MAX_SEQUENCER_FEED_AGE` 3 days.

The app uses a fixed target of 8000 for every user; the contract accepts any target from 500 to 9500.

### The rule

`position` = cbBTC balance at the Chainlink price, `total` = USDC balance + `position`, `drift` = |`position` − `total` × target|.

- **Start.** A correction starts when `drift` > 2% of `total`. The comparison is exact: a wallet exactly on the edge of the band is not due, at any price. A buy needs the position below `total` × (target − 200) / 10,000 and a sell needs it above `total` × (target + 200) / 10,000. A target within 2% of 0% or 100% would only ever trade in one direction, but the range (500 to 9500) stays clear of that: every mandate can trade both ways.
- **Size.** One run corrects the drift, at most max(10% of `total`, 2 USDC). When that would leave less than 2 USDC of the drift, too little for a run of its own, the run takes the whole drift instead, so a correction ends on the target rather than just short of it. The fee is not compensated: such a run still ends off the target by part of its fee. Balance and allowance cap the run after that, and it only goes ahead if it is worth at least 2 USDC. For wallets below 20 USDC the 2 USDC minimum is the budget, so there a run can be a fifth of the wallet, and just under 4 USDC when it takes the remainder. A run of the minimum is measured in whole satoshi: up to 100,000 USDC per cbBTC one satoshi is at most 5 bps of it, so a pool 50 bps off the feed still executes; above that price such a run can revert on a pool that far off, harmlessly, until the next attempt.
- **Pace.** At most one run per owner per day.
- **Finish.** A run that leaves at least 2 USDC of its correction undone (the 10% cap, or the balance or allowance) marks the mandate `unfinished`; the run of the next day then continues to the target, also inside the band. The cap never leaves less than 2 USDC, except that a sell, rounded up to whole satoshi, can leave up to one satoshi less; balance or allowance can leave less too. Such a remainder is not followed up. After two days without a run, or after `setMandate`, a correction starts from the band again. Measured in the unit suite: all cash with a 71% target reaches 71% in eight daily runs; without this rule it would stop near 70%.

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

Only the owner and the keeper the owner appoints can start a run. That is a deliberate trade: a contract anyone may call has to defend every run against the caller itself (who can move the pool around the run), which takes far more code than the rebalance does. Here a keeper is trusted within the contract's bounds, can be replaced by the owner at any time, and the owner can always run their own wallet.

**What a dishonest keeper can do.** It can trade around the run it triggers (push the pool, run, push back) and so move the owner's price down to the lower bound: at most 0.55% of the traded amount per run, one run per day, at most 10% of the wallet plus less than 2 USDC per run (less than 4 USDC for the smallest wallets), and only while a correction is due. It can make a wallet due by sending tokens to it, as anyone can: from the target that takes a donation of more than 2% of the wallet, but for a wallet close to the edge of the band a small amount is enough. The run that follows corrects the whole drift, about 2% of the wallet, so the keeper gains at most 0.55% of that: 0.011% of the wallet. The donation stays with the owner. Every run and its price are visible in `Executed`. The owner can replace the keeper at any moment, and the treasury can stop everything with `retire()`.

**Keepers must send plain transactions.** `execute` checks `msg.sender`, not who composed the transaction. If a keeper sends through a bundler or relayer (ERC-4337, a sponsored send), that party can wrap the call and trade around it. The keeper script therefore sends from its own key, straight to the sequencer, and passes the simulated output minus a small tolerance as `minAmountOut`, so that wrapping it gains nothing. Bitburo's keeper is deliberately not gas-sponsored for the same reason.

**Changing or revoking is not atomic.** A keeper that sees a `stop()`, a keeper change or an `approve(0)` before it lands can still place one run in front of it, within all the bounds above. Whoever wants no further run for sure sends `approve(0)` on both tokens first.

### Fee

25 bps of the USDC leg of every run: of the gross USDC for a buy, of the USDC received for a sell. The fee stays in the contract and `sweep(USDC)` forwards it to the treasury, so a run never depends on the treasury being able to receive (Circle can blacklist an address). Bitburo's keeper calls `sweep(USDC)` once a day, as soon as the contract holds at least 1 USDC. If Circle blacklists the contract itself, every run and every `sweep` reverts and the fees not yet swept are frozen for as long as that lasts; the users' funds are in their own wallets and stay out of it. Between transactions the contract holds nothing but those uncollected fees.

### Retiring the contract

`retire()` is the answer to two situations: a redeploy (old mandates must not stay active unnoticed) and an emergency (a leaked keeper key, a bug). Only the `TREASURY` key can call it and there is no way back (a second call changes nothing).

```bash
cast call <address> "retire()" --rpc-url https://mainnet.base.org --from <treasury-address>      # simulate first
cast send <address> "retire()" --rpc-url https://mainnet.base.org --account <treasury-keystore>
cast call <address> "retired()(bool)" --rpc-url https://mainnet.base.org                          # true
```

Afterwards users can still call `stop()` and `approve(0)`; neither is needed for safety, because nothing can use the allowance any more.

## Running your own keeper

Anyone can run the keeper script in `keeper/` for the owners who appointed them, or for their own wallet. From `keeper/`:

```bash
bun install
RPC_URL=https://mainnet.base.org REBALANCER=0x… FROM_BLOCK=<deploy block> DRY_RUN=1 KEEPER_ADDRESS=0x… bun run keeper.ts
RPC_URL=… REBALANCER=0x… FROM_BLOCK=<deploy block> KEEPER_PRIVATE_KEY=0x… bun run keeper.ts
bun test            # the pure logic in selection.ts and the lock
bun run typecheck
```

One run of the script: find the owners that named this keeper (the `MandateSet` events from `FROM_BLOCK`, remembered in `keeper-owners.json`, plus an optional `OWNERS_FILE`), ask `mandates` and `isDue` per page in a Multicall3 (owners that no longer name this keeper are forgotten, so that events naming it for empty or foreign wallets do not make the list grow for ever), simulate `execute(owner, 0)` for every due owner, and send `execute(owner, simulated output − TOLERANCE_BPS)` as a plain transaction. Market and oracle conditions and a state that changed since `isDue` are skipped until the next run; any other revert, and a transaction that ran out of `GAS_LIMIT`, puts the owner on a cool-down that doubles per failure (`keeper-cooldowns.json`). One run at a time (`keeper.lock`), and nothing is sent while an earlier transaction of the key is still pending. The contract allows one run per owner per day, so every 10 to 60 minutes is plenty. All settings: the header of `keeper/keeper.ts`.

The script was run end to end against a local anvil fork of Base on 17 September 2026 (real router, pool and feeds): it found the owner from the event, ran a buy of 1,000 USDC and a sell of 0.02 cbBTC, found nothing to do in the next run, and forgot an owner that called `stop()`.

## Development

| Path | What |
|---|---|
| `src/Rebalancer.sol` | The contract. Solidity 0.8.37, OpenZeppelin 5.6.1, via-IR. |
| `src/interfaces/` | Minimal interfaces, self-written and MIT: the two Chainlink calls and the one SwapRouter02 call the contract makes. |
| `test/Rebalancer.t.sol` | Unit and fuzz tests with mocks, and the invariants (with and without `retire`). |
| `test/RebalancerFork.t.sol` | Fork tests against the real tokens, router, pool and feeds on Base, including the deploy script. |
| `script/Deploy.s.sol` | Deploy script with the verified Base addresses and the checks the constructor does not do. |
| `keeper/` | Keeper script in TypeScript. |

### Build and test

```bash
git clone https://github.com/pinhead-io/bitburo-contracts && cd bitburo-contracts
git checkout audit-2026-10-01                             # the audited, deployed code; skip for the latest
git submodule update --init lib/openzeppelin-contracts   # forge-std is vendored
~/.foundry/bin/forge build --sizes                        # "forge" on PATH may be another tool
~/.foundry/bin/forge fmt --check
RUN_FORK=false ~/.foundry/bin/forge test                  # unit, fuzz, invariants; no RPC needed
FORK_BLOCK=52034272 ~/.foundry/bin/forge test             # everything, fork suite at the deploy block
~/.foundry/bin/forge test                                 # fork suite at the latest block
FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=100 ~/.foundry/bin/forge test --match-test invariant
cd keeper && bun install && bun test && bunx tsc --noEmit
```

The fork suite reads `BASE_RPC_URL` (default `https://mainnet.base.org`). Fork tests that need an honest run to pass skip themselves when the pool stands more than 0.40% from the feed at that block. Under `via_ir` Solidity caches `block.timestamp` within a test function, so after `vm.warp` use `vm.getBlockTimestamp()`.

### Deploying

```bash
cast wallet import bitburo-deployer --interactive     # one-off, puts the key in a keystore
export BITBURO_TREASURY=0x…                           # receives the fees and may call retire(); fixed for good by the deploy
DEPLOYER_ACCOUNT=bitburo-deployer bash deploy-mainnet.sh dry
DEPLOYER_ACCOUNT=bitburo-deployer bash deploy-mainnet.sh go
DEPLOYER_ACCOUNT=bitburo-deployer bash deploy-mainnet.sh verify
```

`dry` runs the on-chain checks the constructor does not do and prints `quote()` and the treasury as the contract would store it. `go` refuses as long as there is already a deploy in `broadcast/`; use `FORCE_REDEPLOY=1` for a deliberate new deployment. `verify` refuses on another commit than the deployed one or with uncommitted changes in `src/` or `script/`. A test deployment with `forge script --broadcast` against a local fork with chain id 8453 also writes `broadcast/Deploy.s.sol/8453/run-latest.json`, the record `verify` relies on; point `FOUNDRY_BROADCAST` and `FOUNDRY_CACHE_PATH` somewhere else for that.

## Security

Found a vulnerability? Please report it privately to hallo@bitburo.nl rather than in a public issue.
