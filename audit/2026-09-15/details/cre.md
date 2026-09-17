# Rebalancer — attack vector `onReport` / Chainlink CRE integration

Scope: `src/Rebalancer.sol` (commit c2cf093, live on Base as 0xED47d549345b0dBB5A9b44E57Ff3AB4E6Ed0e6e5), `src/interfaces/IReceiver.sol`, `script/Deploy.s.sol`, `test/Rebalancer.t.sol`, `test/RebalancerFork.t.sol`, `cre/bitburo-keeper/*`, plus Chainlink's KeystoneForwarder source and the on-chain state on Base (15 September 2026, block 51,337,316).

Sources I used for the CRE semantics (not from memory):

- Chainlink docs, *Building Consumer Contracts*: https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts
- Chainlink docs, *Forwarder Directory*: https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory-ts
- Chainlink docs, *EVM client SDK reference* (`WriteReportReply`): https://docs.chain.link/cre/reference/sdk/evm-client-ts
- KeystoneForwarder 1.0.0 source: https://github.com/smartcontractkit/chainlink-evm/blob/develop/contracts/cre/src/v1/KeystoneForwarder.sol (copied locally to `scratchpad/KeystoneForwarder.sol`)
- On-chain: `cast call` to the forwarder (`typeAndVersion()` = "KeystoneForwarder 1.0.0", `isForwarder(self)` = true) and to the live contract.

PoC tests are in `scratchpad/poc/test/CrePoC.t.sol` (mocks) and `scratchpad/poc/test/CreForkGas.t.sol` (Base fork against the live contract). All PoCs pass; nothing in the repo was changed.

---

## Summary

Access control, metadata decoding, ERC-165 and replay protection are correct and match the forwarder source. Important framing: `onReport` gives the forwarder **no authority whatsoever that an arbitrary caller does not already have via `execute`**; the report is just a list of addresses. Funds therefore cannot be reached through this entry point. What *is* vulnerable is the *availability* of the CRE keeper: the fixed gas budget of 700,000 per owner is too tight for larger wallets (fork measurement: from ~20,000 EURC per run `execute` goes out of gas), and the combination of registration order + at most five owners per report lets an attacker occupy the five slots per hour for almost nothing. Both are Medium; both can be mitigated without a redeploy (on the workflow side), but not in the contract itself.

| ID | Severity | Title |
|---|---|---|
| CRE-01 | Medium | `EXECUTE_GAS` (700k) is too tight for larger trades; such owners burn 700k CRE gas every hour and are never served |
| CRE-02 | Medium | Slot starvation: five cheap "dust" owners that register early permanently occupy all CRE slots |
| CRE-03 | Low | Workflow ignores `receiverContractExecutionStatus`; receiver reverts stay invisible. There has not yet been a single CRE delivery on-chain |
| CRE-04 | Low | `FORWARDER` and `WORKFLOW_OWNER` are immutable: a forwarder migration or key change kills `onReport`; recovery = redeploy + all users approve again |
| CRE-05 | Info | `workflowId`/`workflowName` are not checked (deliberate; acceptable) |
| CRE-06 | Info | Replay: forwarder dedup + contract idempotence; safe |
| CRE-07 | Info | Metadata offsets, ERC-165 and forwarder address match source and docs; safe |
| CRE-08 | Info | Gas loop, 63/64 rule, try/catch, returnbomb, list length; safe |
| CRE-09 | Info | Deploy: no admin/upgrade path; constructor args verified; `WORKFLOW_OWNER` key not verifiable from the repo |
| CRE-10 | Info | Slot front-run by a third party is harmless |
| CRE-11 | Info | `cre workflow simulate` cannot reach `onReport` of the live contract (MockForwarder) |

---

## CRE-01 — Medium — `EXECUTE_GAS` of 700,000 is too tight for larger trades

**Line reference:** `src/Rebalancer.sol:70-72` (constants), `src/Rebalancer.sol:329-333` (loop), `README.md:25`.

**Description.** `onReport` gives every owner a hard ceiling of `EXECUTE_GAS = 700_000`. The README bases that on a single fork measurement (buy 404,653, sell 426,991) at 1,000 EURC. Uniswap v3 gas, however, grows with the number of ticks crossed, and the EURC/USDC pool is thin (fork: 34,641 EURC / 26,845 USDC). Measurement on the Base fork against the **live** contract (`CreForkGas.t.sol`, `execute` with exactly 700,000 gas, `maxCorrectionBps` = 10000):

| Run amount (EURC) | Buy: gas | Sell: gas |
|---|---|---|
| 475 | 343,812 | 404,457 |
| 950 | 343,846 | 405,403 |
| 2,375 | 381,494 | 437,882 |
| 4,750 | 428,994 | 491,867 |
| 9,500 | 548,385 | 587,215 |
| 19,000 | **OOG** (683,182 used, empty reason) | **revert `TF`** (683,924 used) |

At ~10,000 EURC per run the margin is still ~110k; at ~19,000 EURC `execute` fails within the budget, while `isDue`/`dueOwners` simply return `true` for the same owner (they do not simulate the swap). The owner is therefore included in the report **every hour**, uses the full budget each time, and gets `ReportSkipped(owner, "")` — an empty reason, indistinguishable from other empty reverts.

**Attack scenario / failure scenario.** No attacker needed: a legitimate wallet with a large correction (for example 25,000 EURC with `maxCorrectionBps` 10000, or 250,000 EURC with 1000) is structurally unserviceable via CRE and costs Bitburo ~700k gas on Base every hour. A malicious actor can also set this up on purpose (five such wallets = 3.5M gas per hour from the CRE wallet and all five slots, see CRE-02); the capital stays in their own hands because the run reverts.

Note: the limit (~19k) depends on the liquidity/tick density at the moment and can also occur at smaller amounts if the pool gets even thinner.

**Existing test coverage.** `test_onReport_executeGasBudgetIsPerOwner` (mock, artificial burn) and `test_fork_onReportRunsBuyAndSellWithinGasBudget` (1,000 EURC / 0.02 cbBTC). No test with larger amounts; no test showing that `isDue` stays true while `execute` fails within 700k.

**Recommended fix.**
1. Workflow side (no redeploy): exclude owners with `|eurcDelta|` above a configurable limit (for example 8,000 EURC) by reading `isDue(owner)` for the candidates from `dueOwners`, and log them separately. Let the open keeper script (`keeper/keeper.ts`, no gas cap) serve these owners.
2. Add a recognizable reason for out-of-gas to `ReportSkipped` (empty `reason` + `gasleft()` is not possible in the catch; alternative: `if (reason.length == 0) emit ReportOutOfGas(owner)`), so monitoring can tell them apart. Requires a redeploy; only include in a next version.
3. In a next version: `EXECUTE_GAS` at ~1,000,000 and `EXECUTE_GAS_RESERVE` at ~1,050,000, with `maxOwnersPerReport` = 3 at 4M, or raise `gasLimit` (the README mentions a CRE maximum of 5M; I could not verify that in the docs).

**Source.** Own fork measurement (above); Chainlink docs *Building Consumer Contracts*: "Keep `onReport` gas-efficient; the workflow's `gasLimit` must cover the full execution" (via the local skill copy `.agents/skills/chainlink-cre-skill/references/evm-client.md:569`).

---

## CRE-02 — Medium — Slot starvation via registration order and dust parameters

**Line reference:** `src/Rebalancer.sol:197-212` (`setParams`: minimum `minTradeEurc` = 1 base unit, `bandBps` ≥ 1, `maxCorrectionBps` ≥ 1, `interval` ≥ 1 hour), `src/Rebalancer.sol:248-275` (`dueOwners` in registration order), `cre/bitburo-keeper/main.ts:187-201` (first `maxOwnersPerReport` = 5 due owners), `cre/bitburo-keeper/config.production.json:10`.

**Description.** The workflow always takes the first five due owners in the order of `_owners` (registration order) and then stops. Whoever registers early has permanent priority. Anyone can register for free, and the parameter limits allow a configuration that is due *every hour* and *never* gets back inside the band: `bandBps` = 1, `maxCorrectionBps` = 1, `minTradeEurc` = 1, `interval` = 1 hour. At 1,000 EURC and target 80% the drift is 80%, but the correction is capped at 1 bps = 0.10 EURC; after the run the drift is still ~80%, so the owner is due again the next hour.

**PoC** (`CrePoC.t.sol::test_poc_starvationByRegistrationOrder`, passes): five "sybil" addresses register with the dust params above, then `alice` registers with normal params. For three consecutive hours `dueOwners(0,50)` returns six owners; the report contains the first five; all five sybils are served, `alice.lastExecutedAt` stays 0. Cost to the attacker after 15 runs: 3,740 EURC base units (0.0037 EURC) in fees; Bitburo pays the CRE gas (5 × ~250–470k per hour).

**Attack scenario.** A competitor or prankster registers five wallets with 1,000 EURC each (the capital stays theirs) and dust params. From that moment on, no user registered later is served by the CRE keeper anymore; only the open keeper script and manual `execute` calls still work. Combined with CRE-01 (wallets that fail within 700k) it also costs 3.5M gas per hour. Even without malicious intent, starvation occurs as soon as more than five early owners have an interval of 1 hour and are structurally due.

**Existing test coverage.** `main.test.ts` "pages through dueOwners and caps the report at maxOwnersPerReport" shows the first-N selection, not its consequence. No contract or workflow test for repeated selection over multiple hours.

**Recommended fix (workflow side, no redeploy).**
1. Rotate the starting point per run: `offset0 = (hour number × maxOwnersPerReport) mod ownerCount` (or a hash of `workflowExecutionId`), and cycle through all pages. Every due owner then gets a turn within `ceil(due/5)` hours on average.
2. Filter economically: read `isDue(owner)` for the candidates and skip owners with `|eurcDelta|` below for example 5 EURC (a 25 bps fee on 0.10 EURC is 250 base units; that does not cover gas). That rules out the dust configuration without a contract change.
3. In a next contract version: raise the minimum of `minTradeEurc` (for example 1 EURC) and/or `maxCorrectionBps` (for example 10 bps), so a run always yields at least its own gas cost in fees.

---

## CRE-03 — Low — Workflow ignores `receiverContractExecutionStatus`; no CRE delivery on-chain yet

**Line reference:** `cre/bitburo-keeper/main.ts:218-228`; forwarder `route()` (KeystoneForwarder.sol lines 156-166).

**Description.** The forwarder calls the receiver with a raw `call` and ignores the result except as a bool: `success := call(remainingGas, receiver, 0, …)`; only `s_transmissions[id].success` and `ReportProcessed(receiver, executionId, reportId, success)` record it. **The transaction itself therefore also succeeds when `onReport` reverts.** The SDK reports that separately: `WriteReportReply.receiverContractExecutionStatus` with `RECEIVER_CONTRACT_EXECUTION_STATUS_SUCCESS | REVERTED` (docs *EVM client*; type in `node_modules/@chainlink/cre-sdk/dist/generated/capabilities/blockchain/evm/v1alpha/client_pb.d.ts:1193,1269-1280`). The workflow only checks `txStatus !== TxStatus.SUCCESS` and then logs "onReport verstuurd" (onReport sent). An `UnauthorizedWorkflowOwner`, an incorrectly encoded report, or metadata shorter than 62 bytes (`_decodeMetadata` slices without a length check and then reverts the whole call — PoC `test_poc_metadataHandling`) therefore goes unnoticed: "success" in the logs every hour, zero executions.

**On-chain state.** Since the deploy (block 51,300,986) there have been **0** `ReportProcessed` events on the forwarder with `receiver` = Rebalancer (all 2000-block windows up to 51,337,400 searched) and no `ReportSkipped` events on the contract. The only `Executed` event (tx 0x8a0604d2…, block 51,302,126) was sent via the ERC-4337 EntryPoint (0x0000000071727De22E5E9d8BAf0edAc6f37da032), so from the app/keeper, not via CRE. The chain forwarder → `onReport` has never been proven on mainnet; whether `WORKFLOW_OWNER` (0xdeb5…e7A7) equals the key with which the workflow is/will be deployed, I could not determine from the repo (`cre/.env` is shielded from me).

**Attack scenario.** No attacker; operational risk: a silent mismatch between `WORKFLOW_OWNER` and the CRE account, or a change in the report encoding, keeps the keeper "green" for months while nothing happens.

**Existing test coverage.** No test in `main.test.ts` for `receiverContractExecutionStatus === REVERTED`.

**Recommended fix.** In `main.ts` after `writeReport`: `if (txResult.receiverContractExecutionStatus === ReceiverContractExecutionStatus.REVERTED) throw new Error(…)` (or at least log it + include it in `RunSummary`), with a test. Perform one end-to-end run on mainnet with one due owner and record the `ReportProcessed(…, true)` event as proof. Monitoring on `ReportProcessed(receiver = Rebalancer, result = false)`.

**Source.** https://docs.chain.link/cre/reference/sdk/evm-client-ts ("receiverContractExecutionStatus … RECEIVER_CONTRACT_EXECUTION_STATUS_SUCCESS or RECEIVER_CONTRACT_EXECUTION_STATUS_REVERTED"); KeystoneForwarder.sol `route()`.

---

## CRE-04 — Low — Immutable `FORWARDER`/`WORKFLOW_OWNER`: migration or key change kills `onReport`

**Line reference:** `src/Rebalancer.sol:53-55, 173-174, 323-325`; `script/Deploy.s.sol:27-29` ("Deliberately not overridable via env").

**Description.** Both addresses are immutable and there is no admin. Chainlink's own `ReceiverTemplate` actually makes the forwarder address *changeable* ("The forwarder address is required at deployment, configurable after", with `setForwarderAddress()`), and the docs warn that forwarder addresses differ per environment. KeystoneForwarder 1.0.0 does have a router mechanism (`s_forwarders`, `addForwarder`) through which new Chainlink entry points can forward via `this.route` with `msg.sender` = the existing forwarder — that absorbs part of future migrations. But as soon as the DON moves to a new forwarder contract, or the CRE account (the `WORKFLOW_OWNER` key) changes or is lost, `onReport` reverts permanently.

**Consequence.** Recovery is only possible with a new contract at a new address: every user has to `approve` again (EURC and cbBTC) and call `setParams`; `lastExecutedAt` and the owner list are lost; the app has to switch the address. Until then only the permissionless path (`execute` via keeper script/Laravel) remains — that does work, so this is not a funds or downtime risk, but a migration cost risk.

**Existing test coverage.** `test_onReport_revertsUnauthorizedForwarder`, `test_onReport_revertsUnauthorizedWorkflowOwner`. No documentation/runbook for a migration.

**Recommended fix.** Two options, Arjan's choice:
- (a) Accept (fits "no admin") and record the runbook: keeper script as the primary fallback, migration steps, and a monitor on the forwarder version (`typeAndVersion()`) and on Chainlink's *Forwarder Directory*.
- (b) In a next version a minimal, time-bound path: a `FORWARDER_UPDATER` address that may only change the forwarder address (no other power), optionally with a 7-day timelock. That does not affect the "never what or how much" guarantee, because `onReport` cannot do anything `execute` cannot.

**Source.** https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts (ReceiverTemplate, `setForwarderAddress`); https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory-ts ("Forwarder contracts differ between local simulation and production").

---

## CRE-05 — Info — `workflowId` and `workflowName` are not checked

**Line reference:** `src/Rebalancer.sol:324-325, 536-544`.

Only `workflowOwner` is compared. Every workflow of the same owner (including `bitburo-keeper-staging`, or a new version with a different CID) may report — PoC `test_poc_metadataHandling` confirms that a different `workflowId` goes through. The docs call workflowId validation "highest security" and workflowName only in combination with author validation (bytes10 truncation). Because the workflowId is the content hash of the workflow and changes with every deploy, hard-coding it in an immutable contract would be unworkable. The consequence of a compromised owner key is limited to: submitting reports that can do nothing more than `execute` (consuming CRE gas). **Found safe**, deliberate design.

---

## CRE-06 — Info — Replay

**Line reference:** KeystoneForwarder.sol lines 138-166 (`route`), 170-175 (`getTransmissionId`); `src/Rebalancer.sol:290-303`.

The forwarder dedups on `keccak256(receiver ‖ workflowExecutionId ‖ reportId)`: after a successful delivery a repeat reverts with `AlreadyAttempted`. A failed delivery (receiver reverts) may be retried with more gas ("If this function call reverts, it can be retried with a higher gas limit", docs IReceiver). Because `onReport` does try/catch per owner and therefore normally never reverts, the report is marked as success on the first delivery. Even if a report is delivered twice after all, the contract is idempotent: `lastExecutedAt` + `interval` gives `NotDue` (PoC `test_poc_replayIsIdempotent`). The cron timestamp method from the docs is not needed here because the report contains no data that can be "stale" — it is a list of addresses that the contract itself re-evaluates. `report()` on the forwarder is permissionless (anyone can submit a signed report earlier); that is harmless here. **Found safe.**

---

## CRE-07 — Info — Metadata offsets, ERC-165 and forwarder address

**Line reference:** `src/Rebalancer.sol:344-346, 536-544`; `src/interfaces/IReceiver.sol`; `script/Deploy.s.sol:29`.

- Forwarder source `_getMetadata` and `report()`: the metadata the receiver gets is `rawReport[45:109]` = `workflow_cid` (32) ‖ `workflow_name` (10) ‖ `workflow_owner` (20) ‖ `report_id` (2) = 64 bytes. The contract reads `[0:32]`, `[32:42]`, `[42:62]` — **correct**, identical to `ReceiverTemplate._decodeMetadata` from the docs.
- `type(IReceiver).interfaceId` = `0x805f2132` (only `onReport`, IERC165 inheritance does not count), equal to what the forwarder queries via `ERC165Checker.supportsInterface(receiver, type(IReceiver).interfaceId)` with 30k gas; `supportsInterface` is `pure` and cheap. Checked on-chain: `supportsInterface(0x805f2132)` = true.
- `FORWARDER` = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482 = production KeystoneForwarder for `ethereum-mainnet-base-1` in the Forwarder Directory; on-chain `typeAndVersion()` = "KeystoneForwarder 1.0.0", contract code present.
- Same address as on Base Sepolia/Ethereum Sepolia (deterministic deploy); the workflow's README correctly names the separate MockForwarder address 0x5e34…548 for simulation.

**Found safe.**

---

## CRE-08 — Info — Gas loop, 63/64 rule, try/catch, returnbomb, list length

**Line reference:** `src/Rebalancer.sol:327-334`.

- 63/64: the loop breaks at `gasleft() < 750_000`; at ≥ 750k `this.execute{gas: 700_000}` always gets the full amount (63/64 × 750k ≈ 738k > 700k). PoC `test_poc_fiveFullBudgetOwnersFit`: five owners fit in 3.7M gas even when each run approaches ~700k (2.24M used at 5 × ~447k). The forwarder passes on `gasleft() − 5,000` after its own overhead (~30k + ERC-165 ≤ 90k + signatures), so of the 4M `gasLimit` well over 3.55M remains — enough for 750k + 4 × 700k in the worst case.
- OOG/revert in one owner: caught by `try/catch`, `lastExecutedAt` not set, the rest of the list continues (existing tests). The whole call only reverts on invalid metadata/report — in which case the sender is by definition the forwarder with a malformed report.
- Malicious owner: all code that runs inside `execute` is fixed (EURC, cbBTC, SwapRouter02, feeds, pools); `rewardTo` is `TREASURY`; an owner cannot inject a hook or returnbomb. `catch (bytes memory reason)` only copies revert data from those fixed contracts (Uniswap strings, custom errors). An owner's only "weapons" are balance/allowance/params — see CRE-01/02.
- List length: unbounded in the contract, but gas-bounded by the reserve check; the workflow caps at 5.

**Found safe** (the economic variants are under CRE-01/02).

---

## CRE-09 — Info — Deploy script and post-deploy power

**Line reference:** `script/Deploy.s.sol`, `broadcast/Deploy.s.sol/8453/run-latest.json`, `src/Rebalancer.sol:150-178`.

- No `Ownable`, no proxy, no selfdestruct, no setters except `setParams` (only for `msg.sender` itself). After deploy nobody can change anything about the contract; `sweep` only sends leftover balance to the fixed treasury.
- Constructor args in the broadcast match the live immutables: `FORWARDER()` = 0xF834…4482, `WORKFLOW_OWNER()` = 0xdeb5…e7A7 (EOA, no code), `TREASURY()` = 0xD6a4…98a9. All addresses in the script are the known Base addresses; `_requireContract` and `_poolOrder` catch wrong addresses (tested).
- Bytecode: the local build (via-IR, runs 1000) has exactly the same length as the on-chain code (24,856 hex characters); 678 differing bytes can be explained by immutables and the metadata hash, but that is not conclusive proof. I could not query the Basescan verification without an API key — please confirm manually that the contract is verified.
- Whether 0xdeb5…e7A7 actually is the CRE workflow owner: not verifiable from the repo (see CRE-03).

---

## CRE-10 — Info — Slot front-run by a third party

PoC `test_poc_frontrunSlot`: someone who calls `execute(owner, him)` himself just before the report gets the 0.05 EURC reward; the report skips the owner with `NotDue`. That is exactly the intended permissionless design; it costs Bitburo at most one slot and the reward. **Harmless.**

---

## CRE-11 — Info — Simulation does not reach the live contract

`cre workflow simulate` uses the MockForwarder (0x5e34…548, docs Forwarder Directory); the live contract only accepts 0xF834…4482 and reverts with `UnauthorizedForwarder`. The simulation therefore tests the read side (`dueOwners`) and the report encoding, not the delivery. That is inherent to the immutable design; it underlines CRE-03 (one real end-to-end run as proof).

---

## Test gaps

1. [dropped] **Gas per trade size on the fork**: no test above 1,000 EURC; add: a parametric fork test that measures `execute{gas: EXECUTE_GAS}` at 2.5k/5k/10k/20k EURC and records up to which amount the budget suffices (CRE-01).
   → `EXECUTE_GAS` no longer exists (a798bde); keepers estimate gas themselves via simulation. The gas of a buy and a sell is still measured in fork `test_fork_buyAndSellGasCost`.
2. [dropped] **`isDue` true while `execute` fails within `EXECUTE_GAS`**: no test showing the divergence between the view and the execution, nor that such an owner is in `dueOwners` again every hour (CRE-01).
   → No gas budget in the contract anymore. That a failed owner stays due is covered by `test_execute_revertsWhenOwnerBlacklisted`.
3. [dropped] **Multi-hour selection in the workflow**: `main.test.ts` tests one run; no test showing that the same five owners are chosen again every hour and a sixth never (CRE-02).
   → The CRE workflow is gone (#2).
4. [dropped] **`receiverContractExecutionStatus === REVERTED`** in `main.test.ts` (CRE-03).
   → The CRE workflow and `main.test.ts` are gone (#2).
5. [dropped] **Metadata shorter than 62 bytes** and **a report that does not decode as `address[]`**: no contract test that the whole call then reverts (the behavior is acceptable, but should be pinned down).
   → `onReport` and the metadata decoding are gone (a798bde).
6. [dropped] **Replay via `onReport`**: `NotDue` is only tested via `execute`, not as a second delivery of the same report (CRE-06; PoC available).
   → `onReport` is gone (a798bde); a double `execute` gives `NotDue` in `test_execute_revertsNotDue`.
7. [dropped] **Five owners at full budget within the actual forwarder margin**: no test with 3.5–3.7M gas and five owners each using ~650k (PoC available).
   → No forwarder and no report anymore (a798bde).
8. [dropped] **End-to-end on mainnet**: not a single `ReportProcessed` event for this contract; the CRE chain has not yet been proven (CRE-03).
   → The CRE path is no longer used; `ReportProcessed` no longer exists for this contract.
9. [dropped] **Fuzz on the `_decodeMetadata` offsets** against the forwarder layout (for example by rebuilding the real `rawReport[45:109]` slice) is missing; currently only a handwritten 64-byte fixture.
   → `_decodeMetadata` is gone (a798bde).
