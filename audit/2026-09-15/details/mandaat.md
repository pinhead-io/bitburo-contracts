# Security review: wallet mandate / approval model of the Rebalancer

Date: 2026-09-15. Scope: `pinheadio/bitburo-contracts` (main, `c2cf093`) and `pinheadio/bitburo` (`development` `f4e8620` plus the open PRs #142 `feature/rebalancer-keeper` and #143 `feature/keeper-mandate-gate`, because `development` does not yet contain a single reference to the Rebalancer contract). Read only; nothing changed. Forge tests run (`RUN_FORK=false`): 79 passed, 1 skipped (fork). Checked on-chain via `cast` against Base mainnet.

## Established facts (on-chain, 2026-09-15)

| What | Value | Source |
|---|---|---|
| Rebalancer | `0xED47d549345b0dBB5A9b44E57Ff3AB4E6Ed0e6e5`, deploy block 51300986 | `broadcast/Deploy.s.sol/8453/run-latest.json` |
| TREASURY | `0xD6a4f92C9c2c35B4816deC5147231226Fb7598a9` (EOA, no code) | `cast call TREASURY()`, `cast code` |
| WORKFLOW_OWNER = deployer | `0xdeb5e5b8bDc70e8f2BBB3bACbAFA2a981ee2E7A7` (EOA, 0.0006 ETH) | `cast call WORKFLOW_OWNER()`, broadcast `from` |
| FORWARDER | `0xF8344CFd5c43616a4366C34E3EEE75af79a74482` (contract, 8.5 kB code) | `cast call FORWARDER()` |
| ownerCount | 1: `0x459EE9C4b9cd25a70F92A8433B339369FA62A497` (Arjan's test account) | `cast call owners(0,50)` |
| Params of that owner | active=true, target 8000, band 200, cap 1000, minTrade 5 EURC, interval 86400, slippage 100 | `cast call params(address)` |
| Allowances owner→contract | EURC and cbBTC: `type(uint256).max` | `cast call allowance` |
| Owner wallet | EIP-7702 delegated (`0xef0100d6cedd…7875b28`) — Privy Kernel account | `cast code` |
| EURC / cbBTC | both have `DOMAIN_SEPARATOR()` and `nonces()` → EIP-2612 `permit` present | `cast call` |

---

## Findings

### M-01 — High — Server signer with swap-only policy can still sign a `permit` or a 7702 authorization

**Reference:** bitburo `app/Console/Commands/SetupSwapPolicyCommand.php:25-28, 122-146` (`*` ALLOW without DENY on `eth_signTypedData_v4` and `eth_sign7702Authorization`); `resources/js/pages/wallet/index.tsx:609-615` and `resources/js/pages/billing/index.tsx:115-129` (this policy is attached to the swap signer on *every* delegated user wallet, including Arjan's main account that "stays on the old strategy").

**Description.** The policy allows `*` ALLOW (needed because `/swap` has no policy method of its own) and lays DENYs over `eth_sendTransaction`, `eth_signTransaction`, `wallet_sendCalls`, `eth_signUserOperation`, `transfer`, `earn_*`, key export and `personal_sign`. Two fund-moving methods remain open, and the code says so itself ("Known residual risk"):
- `eth_signTypedData_v4`: EURC and cbBTC on Base implement EIP-2612 (`DOMAIN_SEPARATOR`/`nonces` verified). A signed `Permit(owner, spender=attacker, value=max)` is functionally identical to `approve(attacker, max)`; then `transferFrom` by the attacker → whole wallet empty. (Caveat: the wallet is a 7702 account; the tokens then verify via ERC-1271 on the Kernel delegate. Whether that 1271 check accepts the Privy EOA signature I have not proven on-chain; the policy leak exists either way.)
- `eth_sign7702Authorization`: the signer can sign an authorization that delegates the EOA to an arbitrary contract; anyone may include it in a type-4 transaction, after which the attacker determines the account code and can siphon everything off. Privy: "EIP-7702 authorization signing is supported in the React SDK, REST API, and Node SDK" (docs.privy.io/wallets/using-wallets/ethereum/sign-7702-authorization).

**Scenario.** Attacker obtains `PRIVY_APP_SECRET` + `PRIVY_AUTHORIZATION_KEY` (the swap signer key; the same key is also owner of the keeper wallet, see M-08). POST `/v1/wallets/{id}/rpc` with `method: eth_signTypedData_v4` (Privy API reference `eth_signTypedData_v4`) → Permit → `transferFrom`. No MFA: the signer is a session signer. Loss: 100% of EURC + cbBTC of every delegated wallet.

**Privy semantics (quote).** "`DENY` actions take precedence over `ALLOW` actions. If no rules resolve, the policy will default to `DENY`." and the method list including `eth_signTypedData_v4` and `eth_sign7702Authorization`, with `*` (docs.privy.io/controls/policies/overview, "Rules" and "Policy evaluation"). The condition sources `ethereum_typed_data_domain` (`chainId`, `verifyingContract`) and `ethereum_7702_authorization` (`contract`) exist (same page, table "Field sources").

**Test coverage.** Pest: none (policy content is only tested as an array, not against Privy). Forge: n/a.

**Fix.** (1) Shortest: DENY rule on `eth_signTypedData_v4` with condition `ethereum_typed_data_domain.verifyingContract in [EURC, cbBTC]` and a DENY on `chainId eq 8453`; DENY `eth_sign7702Authorization` with `ethereum_7702_authorization.contract` `in` [current Kernel delegate] does not work as a denylist — according to the code comment Privy does not accept a condition-less DENY for this method; verify with Privy whether a `contract` condition with an impossible address plus ALLOW-less behavior suffices. (2) Structural and already the plan: after the cutover remove the swap signer from the user wallets entirely (`removeSigners`) — the contract model does not need a server signer. Until then: run `bitburo:setup-swap-policy --update` with the extra DENYs (takes effect immediately for all existing delegations, as the code already notes).

### M-02 — Medium — Open registration lets the CRE keeper be starved and Bitburo's CRE gas be drained

**Reference:** contracts `src/Rebalancer.sol:197-212` (`setParams` without threshold), `:248-275` (`dueOwners` paginates from `offset` in registration order), `cre/bitburo-keeper/main.ts:187-201` (stops at `maxOwnersPerReport`), `cre/bitburo-keeper/config.production.json` (`maxOwnersPerReport: 5`, `gasLimit: 4000000`).

**Description.** Anyone may register (`_owners` grows forever) and `dueOwners` returns due owners in registration order. The CRE workflow takes the first five. An attacker registers N addresses with `minTradeEurc = 1`, `bandBps = 1`, `interval = 1 hours`, 1 EURC balance + allowance. Those are "due" every hour (after every run the fraction immediately drifts >0.01% again). Consequence: (a) every hour the report contains only attacker addresses; every real user who registered *after* the attacker is never served via CRE; (b) every attacker execute costs ~700k gas from the workflow's gas budget (Bitburo pays), while the attacker pays ~0.0025 EURC fee per run.

**Scenario.** Registering 50 dust owners costs the attacker one-off gas. After that ~5 × 700k gas/hour from Bitburo, and legitimate users with a higher `_owners` index fall back on the Laravel keeper (which walks its own users and is therefore *not* affected) or the open script.

**Test coverage.** Forge: `test_dueOwners_filtersAndPaginatesLikeIsDue` (filter/paging only). CRE: "pages through dueOwners and caps the report at maxOwnersPerReport" (the cap only). Nothing tests starvation/cost asymmetry.

**Fix.** Contract (before the final deploy, immutable): require `minTradeEurc >= 5e6` (or `total >= X`) in `setParams`/`_plan`, and/or have `dueOwners` return nothing below a minimum total value. Workflow: rotate the start offset per run (e.g. `blockNumber % ownerCount`) or take a random page, and cap per owner based on the `Executed` history. Consider an allowlist of its own in the workflow (HTTP fetch of Bitburo's user list) — that also fits the compliance argument that Bitburo is not the only caller, as long as the open script continues to exist.

### M-03 — Medium — The parameters are dictated by the server; the user signs them blind, without client-side limits

**Reference:** bitburo (PR #142/#143) `app/Services/Rebalancer/RebalancerMandateReader.php:211-224` (`defaults()` from `config('bitburo.auto.*')`), `resources/js/components/strategy-card.tsx:646-680` (copies `defaults` 1-to-1 into `setParams`), `resources/js/lib/rebalancer-abi.ts:82-94` (no validation); contracts `src/Rebalancer.sol:197-205` (only limits: target 500–9500, band 1–9999, cap 1–10000, interval ≥ 1h, slippage 30–100).

**Description.** Decision 2026-09-14: "the user chooses NOTHING in the mandate". A compromised backend, a wrong `.env` or a manipulated Inertia prop can therefore offer `targetBps: 500`, `maxCorrectionBps: 10000`, `bandBps: 1`, `interval: 3600`, `maxSlippageBps: 100`; the card shows those values, but the user expects "the Bitburo standard" and signs with MFA. The contract limits the damage (money never leaves the wallet; slippage ≤ 1%; spot check 0.5%; fee 0.25%), but not the allocation: 75% of the BTC position can go to EURC in one run at a value leak of at most ~1.75% + 0.25% fee to the treasury.

**Maximum loss per user per day (arithmetic).** With Bitburo defaults (cap 10%, interval 24h): traded ≤ 10% of the total value/day (floor `minTradeEurc`); value leak per run ≤ fee 0.25% + slippage 1% + spot deviation 0.5% = 1.75% of the traded amount ⇒ ≤ 0.175% of the portfolio/day. With params manipulated by the server: up to 100% reallocated per run, 1.75% leak per run, and with `interval = 1 hours` + `bandBps = 1` a new run on every price move (each 0.25% fee on the small correction amount). A compromised backend *cannot* pull funds to itself via the contract (`rewardTo` max 0.05 EURC out of the fee; `TREASURY` immutable).

**Test coverage.** Vitest `rebalancer-abi.test.ts` (encoding), Browser `StrategyTest` ("offers a mandate with the application-wide settings", "shows the on-chain settings on the card") — no test that deviating defaults are rejected.

**Fix.** Hard client-side limits in `encodeSetParams`/the dialog (cap ≤ 1000, band ≥ 100, interval ≥ 86400, target ∈ [5000, 9500]) with an explicit confirmation of the displayed values; a Vitest that makes out-of-range `defaults` fail. Consider baking the defaults into the frontend bundle instead of passing them as a prop.

### M-04 — Medium — Unlimited allowance + a single contract address in config: a redeploy leaves old mandates active and invisible

**Reference:** bitburo (PR) `config/bitburo.php` (`rebalancer.address`, one address), `strategy-card.tsx:671-680, 898-915` (approve `MAX_UINT256` / approve 0 only to `rebalancer.contractAddress`), `RebalancerMandateReader::readChainState` (reads allowances only for that address). Decision (memory): "unlimited allowance"; the current contract is "throwaway before audit".

**Description.** The blast radius of the max allowance with *this* contract is limited: the contract is immutable, has no admin/upgrade, can only `transferFrom` in `_buy/_sell` within `_plan` (bounded by `maxCorrectionBps` and allowance), and the output always goes to the owner. The real risk is in the lifecycle: after the planned redeploy (audit version) existing owners keep `type(uint256).max` and `active` params on the old address. The old contract stays permissionlessly executable (open keeper script, anyone) and has its own `lastExecutedAt` clock: two contracts then trade side by side (2× daily cap, 2× fee), and the UI shows no revoke path for the old address (the card only knows the configured address).

**Scenario.** Cutover to the audited contract; Arjan's test account (and every beta user) stays registered with `0xED47…`; a third party runs the keeper script with `REBALANCER=0xED47…` and earns 0.05 EURC per run at the user's expense (0.25% fee + slippage).

**Test coverage.** Pest `WalletControllerTest` ("the wallet page reads the mandate from the chain") and `StrategyTest` (revoke) — all with one address. No test for a legacy address.

**Fix.** (1) Decommission runbook per redeploy: for every owner `approve(0)` on both tokens + `setParams(active=false)` on the old address, and after cutover a check script that reads `params`/`allowance` on all previous addresses. (2) `bitburo.rebalancer.legacy_addresses` in config; the card also reads and shows those allowances and offers "revoke". (3) Consider a bounded allowance (e.g. 2× daily cap in absolute terms) — costs an extra signature as holdings grow, but makes any bug in a future contract bounded by definition.

### M-05 — Medium — WORKFLOW_OWNER = deployer EOA; if the CRE workflow lands under a different address, the CRE path is dead for good

**Reference:** contracts `script/Deploy.s.sol:34, 50`, `src/Rebalancer.sol:322-325`, broadcast (`workflowOwner == from`); `cre/bitburo-keeper/config.production.json` and `config.staging.json` (identical, both point to the throwaway contract).

**Description.** `onReport` requires `metadata.workflowOwner == WORKFLOW_OWNER` (immutable). The contract was deployed with the deployer EOA as owner while memory says the owner should be "the CRE link-key EOA, not the Privy keeper wallet". CRE Early Access has not been granted, so the real owner address is not yet known. If the workflow lands under a different address, every report reverts and only a new deploy (with M-04) is the way out. In addition: staging and production point to the same contract, and the deployer key (which is also the workflow owner) is in Arjan's local `.env` — one key, two roles.

**Test coverage.** Forge `test_onReport_revertsUnauthorizedWorkflowOwner`, `…UnauthorizedForwarder` (behavior is correct; the risk is operational).

**Fix.** Before the final deploy: record the workflow owner address from `cre account`/link-key and pass it as `WORKFLOW_OWNER`; separate key for the deployer; document key management (hardware/multisig-like storage).

### M-06 — Medium — No pause button, no incident runbook, monitoring is missing

**Reference:** contracts `src/Rebalancer.sol:26` ("No admin, no upgrade, no pause button"), `README.md`; bitburo (PR) `routes/console.php:26-27` (keeper + sweep), no `docs/` runbook, no alert on `Executed`.

**Description.** Deliberate design: Bitburo cannot stop anything. In an incident (feed manipulation within 0.5%, pool drain, token upgrade of EURC/cbBTC, bug in `_plan` after a future redeploy) that means: (a) Bitburo can only halt its own keeper (empty `BITBURO_REBALANCER_ADDRESS`), not CRE or third parties; (b) every user has to sign 3 transactions + MFA themselves to stop; (c) there is no detection: the sweep books `Executed` but never compares `priceEurcPerBtc`/`amountOut` with a reference; (d) TREASURY is an EOA; who holds the key and how is recorded nowhere (compromise = fee loss + the billing policy allowlist has to change with it).

**Test coverage.** n/a.

**Fix.** Runbook (who does what, communication, a "revoke-all" page with one button that asks for the 3 signatures one after the other — already partly exists in the card); Sentry/log alert in `SweepExecutionsCommand::book()` on `|price − CoinGecko| > 1%` or `amountOut < expected × 0.985`; treasury key in a hardware wallet or multisig (immutable → choose before the final deploy).

### M-07 — Medium — Two trading engines run side by side without mutual exclusion

**Reference:** bitburo (PR) `routes/console.php:21-27` (`bitburo:run-schedules` and `bitburo:run-keeper` each every hour), `app/Services/ScheduleRunner.php:246-287` (ledger-based, cap 10%), `app/Console/Commands/RunKeeperCommand.php:110-137` (walks *all* users with a wallet).

**Description.** A user can have a delegated schedule (old path, Privy swap) and an on-chain mandate at the same time; nothing rules that out. Both correct towards 80/20 at 10%/day → together 20%/day, double fee-like costs (Privy swap fee + contract fee). The Laravel engine also relies on ledger balances that lag up to an hour behind contract swaps (sweep), so it can submit oversell orders that fail on-chain (sponsored gas).

**Test coverage.** No test covering the combination.

**Fix.** In `ScheduleRunner::runLocked` (or `RunDueSchedulesCommand`): skip if `RebalancerClient::params(owner).active` is true; or — the plan — cutover and remove the old engine.

### M-08 — Low — Keeper wallet and keeper policy hang off the same app key; the policy does not protect against key compromise

**Reference:** bitburo (PR) `app/Console/Commands/SetupKeeperWalletCommand.php:82-87` (`owner_id` = `services.privy.key_quorum_id`, the same quorum as the swap signer), `:171-194` (policy).

**Description.** The policy pins `to`, `chain_id`, `function_name = execute` and `execute.rewardTo = treasury` — correct and according to the docs (`ethereum_calldata` with `function_name` and `function_name.param_name`, docs.privy.io/controls/policies/overview, table). But: "A wallet's owner can add or remove signers on the wallet, and assign policies" (docs.privy.io/controls/authorization-keys/owners/overview). The owner is the app key itself, so whoever has that key rewrites the policy. At stake is only the reward (0.05 EURC/run) and sponsored gas; the contract protects the users. It does concentrate everything (swap signer on user wallets, keeper owner, policy management) on a single P-256 key.

**Test coverage.** Pest `SetupKeeperWalletCommandTest` (10 tests, policy body).

**Fix.** Separate key quorum for the keeper wallet owner; policy management via a separate key; after the cutover revoke the swap signer key.

### M-09 — Low — Event/state sync is solid, with three weak spots

**Reference:** bitburo (PR) `app/Console/Commands/SweepExecutionsCommand.php:94-142, 154-170, 205-242`, `app/Services/LedgerService.php::recordRebalance` (idempotent on `tx_hash` + `meta.log_index` under user lock), `app/Services/Privy/PrivyWebhookHandler.php::rebalancerLegVerdict`, `app/Services/WalletReconciler.php::hasRecentRebalancerExecution`.

**Description.** Found safe: sweep up to the `safe` block (no reorg double booking on Base without an L1 reorg), idempotent per log, webhook legs of contract swaps are recognized via counterparty/receipt/`Executed` topic with an owner filter, and the reconciler waits until the ledger has caught up with the contract (never books a swap output as a deposit). Weak: (a) an undecodable log moves the cursor on for good → silent gap (only a warning); (b) a chunk error stops the run, but with scale-to-zero and `withoutOverlapping(10)` the sweep can be down for hours without an alarm; (c) the cursor lives in the cache (`Cache::forever`) — a flush falls back to the ledger/deploy block, fine, but with a wrong `BITBURO_REBALANCER_DEPLOY_BLOCK` (e.g. 0 after a redeploy) it starts 2000 blocks below `safe` and misses everything before that.

**Test coverage.** Pest `SweepExecutionsCommandTest` (22 tests, incl. reorg limit, duplicate logs, cursor fallbacks), `LedgerRecordRebalanceTest` (6), `PrivyWebhookHandlerTest` (rebalancer leg), `ReconcileWalletCommandTest` (skip logic). Good.

**Fix.** Alarm (Sentry) when `ReconcileWalletsCommand` keeps a wallet in `skipped_recent_execution` for > 24h (the log is already there; turn it into a notification); on an undecodable log do not silently move on but fail.

### M-10 — Info — `setParams` does not reset `lastExecutedAt`; revoking turns params off but leaves allowances in place until the separate approve(0)

**Reference:** contracts `src/Rebalancer.sol:197-212, 303`; bitburo `strategy-card.tsx:898-915` (does both), `rebalancer-state.ts::revokeSteps`.

**Description.** Behavior is correct and the UI covers it (revoke = approve(0) × 2 + `active=false`; a half-signed mandate is recognized as "incomplete"). Point of attention: a user who only signs `active=false` (e.g. because of an aborted flow) keeps max allowances; the card shows that as "gepauzeerd" (paused). Document that "pause" ≠ "revoke".

**Test coverage.** Forge `test_execute_secondRunAfterIntervalUsesNewState`, `test_execute_revertsInactiveWhenDeactivated`; Vitest `rebalancer-state.test.ts` (revokeSteps); Browser `StrategyTest` ("shows a half-signed mandate as incomplete", "takes back the open approval…").

### M-11 — Info — Configuration drift in the band makes every existing mandate "outdated"

**Reference:** bitburo `config/bitburo.php:89` (default `rebalance_band` 0.05), local `.env` (0.02 according to `config:show`), on-chain `bandBps = 200`; `RebalancerMandateReader::isOutdated`.

**Description.** The card compares on-chain params with the current config; every change of `BITBURO_AUTO_*` in production forces all users to re-sign (with MFA). Not a security problem, but an operational decision that should be documented — and it shows that the "Bitburo standard" the user signs differs per environment (see M-03).

---

## Found safe

- **Registration:** `setParams` writes exclusively `params[msg.sender]` (`Rebalancer.sol:206`); neither Laravel, nor the server signer, nor the keeper wallet can set or change a user's params. The swap-only policy DENYs `eth_sendTransaction`, `eth_signTransaction`, `wallet_sendCalls` and `eth_signUserOperation` (`SetupSwapPolicyCommand.php:129-132`), and Privy lets DENY win — so the server signer cannot send `approve`, `setParams` or "unregister". The keeper policy only allows `execute(*, treasury)`.
- **Execute:** permissionless but the caller only picks the moment; amount, direction, `minOut` (oracle − slippage) and fee come from the contract; `rewardTo` ≤ `min(0.05 EURC, fee)`; `TREASURY` immutable; `nonReentrant` (transient); sequencer, staleness and spot-vs-oracle checks; `lastExecutedAt` only after a successful run (`test_execute_lastExecutedAtNotSetOnRevert`). Invariants: owner balances only move via `execute`, contract never holds a balance, treasury monotonic (64 runs × 32 depth, green).
- **Fee model:** fixed 25 bps, only in EURC, only to treasury/rewardTo; no way to take more than the fee out of a wallet.
- **Laravel keeper:** simulates first (`eth_call` from the zero address), idempotency key bound to `lastExecutedAt`, backoff after 3 errors/3h, walks its own users (no register DoS via the Laravel keeper), gate = `isDue` (mandate) in PR #143.
- **Frontend encoding:** all selectors (`isDue`, `execute`, `params`, `lastExecutedAt`, `setParams`, `approve`, `allowance`) and the `Executed` topic match `cast sig`/`cast keccak` exactly.
- **Revoke path:** present in the UI (`strategy-card.tsx` revoke dialog) and works on the chain (verified in memory on 14-09); MFA required.

## Test gaps

1. [x] Forge: no test for starvation/cost asymmetry of `dueOwners` with dust owners (M-02); no test with `minTradeEurc = 1` and a 1 EURC balance as "due".
   → Covered: fork `test_dustOwnerCannotRegisterAnymore` and `test_setParams_rejectsMinTradeBelowFloor` (the dust setup cannot be registered); `test_dueOwners_pagingReachesEveryDueOwner` shows that small wallets with allowed params are never due and push nobody out.
2. [x] Forge: no test showing that an owner with `maxCorrectionBps = 10000` sells his whole position in one run (fuzz covers it arithmetically, but not as an explicit "this is allowed" scenario for M-03).
   → Covered: `test_execute_boundedByBalance` sets `maxCorrectionBps = 10000` and asserts that one run buys 95 of 100 EURC and sells 95% of the cbBTC position (more is impossible: target lies between 5% and 95%).
3. [x] Pest/Vitest: no test that out-of-range `defaults` (cap > 1000, band < 100, interval < 86400) are rejected by the card (M-03).
   → Laravel repo, covered on the client side: Vitest `resources/js/lib/rebalancer-abi.test.ts` (`describe('mandateLimitViolation')`, including „keeps an out-of-range active mandate from being encoded at all”) and browser `tests/Browser/StrategyTest.php` („refuses to sign settings outside the safe bounds and says why”). A server-side validation of cap/band does not exist and is therefore not tested either.
4. [x] Pest: no test for a legacy contract address (showing/revoking the allowance after a redeploy) (M-04).
   → Laravel repo, covered: `tests/Feature/WalletControllerTest.php` („the wallet page reads what is left of the mandate on every legacy contract” and three related tests) and `tests/Browser/StrategyTest.php` („shows what is left on a previous vault and takes it back with the regular revoke”).
5. [x] Pest: no test that a user with an active schedule and an active mandate does not trade twice (M-07).
   → Laravel repo, covered: `tests/Feature/ScheduleRunnerTest.php` („a wallet under an active on-chain mandate is skipped, so the two engines never trade the same wallet” plus the disabled/unreadable variants). Not combined with a forced run.
6. Pest: no test/verification of the Privy policy rules against the real policy engine (all policy tests only compare the request body); the residual-risk methods in the swap policy are not covered anywhere (M-01).
   → Open, Laravel repo: `tests/Feature/SetupSwapPolicyCommandTest.php` checks the DENY rules only in the request body; nothing tests them against the real Privy policy engine.
7. [dropped] CRE: `main.test.ts` tests the cap, not the order dependency (M-02).
   → The CRE workflow is gone (#2); the keeper script has no cap.
8. No integration test for `bitburo:setup-keeper-wallet --update` after an address change (policy blocks until update; only a unit test on the body).
   → Open, Laravel repo: `tests/Feature/SetupKeeperWalletCommandTest.php` tests `--update` only with a mocked `PrivyApiClient`; no test that goes through an address change.

## Address mismatches

None found. Checked:

| Address | Deploy.s.sol | Fork test | CRE config | Laravel config | On-chain |
|---|---|---|---|---|---|
| EURC `0x60a3…adb42` | ✓ | ✓ | – | ✓ (`bitburo.networks.base.assets.eurc`) | ✓ `EURC()` |
| cbBTC `0xcbB7…33Bf` | ✓ | ✓ | – | ✓ | ✓ `CBBTC()` |
| USDC `0x8335…2913`, Router `0x2626…e481`, pools `0x7279…66fB`/`0xfBB6…43ef`, feeds `0x07DA…9f9D`/`0xDAe3…8250`, sequencer `0xBCF8…6433` | ✓ | ✓ | feeds/sequencer ✓ | – | `ROUTER()` ✓ |
| Forwarder `0xF834…4482` | ✓ | (mock) | README ✓ | – | ✓ `FORWARDER()`, is contract |
| Rebalancer `0xED47…e6e5` | – | – | staging = production ✓ | via `BITBURO_REBALANCER_ADDRESS` (not in repo) | ✓ |
| Chain 8453 / `ethereum-mainnet-base-1` | ✓ | ✓ | ✓ | ✓ (`bitburo.network = base` locally) | ✓ |
| Treasury `0xD6a4…98a9` | env `TREASURY` | – | – | `BITBURO_TREASURY_ADDRESS` locally = ✓ | ✓ `TREASURY()` |

Caveat (no mismatch, but drift): `rebalance_band` repo default 0.05 ≠ local `.env` 0.02 = on-chain 200 bps (M-11); I could not inspect the production `.env`.
