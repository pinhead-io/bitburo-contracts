# Internal audit of the Rebalancer contract — 15 September 2026

**Scope.** `bitburo-contracts` @ c2cf093 (`src/Rebalancer.sol`, 545 lines, live on Base `0xED47…e6e5`), the CRE workflow and the keeper script, plus the Laravel integration in PR #142/#143.
**Method.** Slither 0.11.6 + Aderyn 0.6.8, baseline test suite (79 green), five independent manual reviews per attack vector (oracle, permissionless execute, CRE/onReport, arithmetic, mandate/integration) with Foundry PoCs and fork tests on Base. Line coverage could not be measured (Foundry instrumentation breaks on `via_ir`).
**Outcome.** No Critical. 2 High, 9 Medium (after merging), 9 Low. No path found by which a third party funnels user funds to itself; the contract bounds the loss per run to fee + slippage. The real risks are in (1) the Privy policy outside the contract, (2) liveness/DoS of the CRE keeper, and (3) unrecoverability due to immutables without a pause button.

## High

### H-1 · Server signer can sign `permit` and 7702 authorizations → full drain on key compromise
*Source: mandate M-01.* The swap-only policy leaves `eth_signTypedData_v4` and `eth_sign7702Authorization` on ALLOW. EURC and cbBTC support EIP-2612 `permit`; a compromised server signer signs a permit to an attacker, who then empties every delegated wallet, bypassing the contract.
**Fix.** DENY on `eth_signTypedData_v4` with a condition on `verifyingContract in [EURC, cbBTC]` (and chainId 8453), DENY on 7702 authorization, or remove the swap signer after the cutover. No redeploy needed. **Do before the next production use.**

### H-2 · Dust owners can permanently starve the CRE keeper
*Source: execute EX-01, cre CRE-02, mandate M-02 (merged).* `setParams` has no economic lower bound, `dueOwners` returns in registration order, the workflow takes the first five. Five wallets with 1 EURC, `minTradeEurc=1`, `maxCorrectionBps=1`, interval 1 h are each due every hour and occupy all slots. PoC over 48 hours: real user never served, attacker cost 0.005 EURC, plus Bitburo's CRE gas drained.
**Fix without redeploy.** Rotating start offset per run in the workflow and a filter on `|eurcDelta| >= ~20 EURC` via `isDue` (also in `keeper.ts`). **Next contract version:** `MIN_TRADE_FLOOR` (≥ 1–20 EURC) and a lower bound on `maxCorrectionBps` in `setParams`.

## Medium

| ID | Finding | Source | Fix |
|---|---|---|---|
| M-1 | Executor can atomically sandwich its own run via `slot0`; profitable from ~2,500 EURC per run (fork PoC: +27 EURC at 10k, victim −0.3 to −0.68 %). Bounded by `maxSlippageBps` because `minOut` comes from the oracle. | oracle ORC-1, execute EX-03 | Next version: TWAP via `observe()` and/or post-swap deviation check. Now: app default `maxSlippageBps` 30–50, README documents max loss = 25 bps + slippage. |
| M-2 | EURC/USD feed `0xDAe3…8250` (24 h heartbeat) is no longer in Chainlink's reference directory; on deprecation the immutable contract is permanently dead (`StaleFeed`). | oracle ORC-2 | On redeploy use `0x9867…01e0` (1 h / 0.1 %), enforce `decimals()==8`, fork test on feed freshness. Now: monitor. |
| M-3 | `EXECUTE_GAS` 700k too tight: ~19k EURC runs go out of gas, stay due forever, burn CRE gas every hour. | cre CRE-01 | Workflow: skip owners with a large `eurcDelta` and leave them to the open keeper script. Next version: gas budget ~1M. |
| M-4 | Owners whose `execute` always reverts (amountIn=1, blacklist, slippage too tight) stay due forever and cost every keeper ~158k gas per attempt. | execute EX-02 | Keeper/workflow: simulate first + cool-down per owner. Next version: `lastAttemptAt` in the catch branch. |
| M-5 | Small wallets (total × cap < minTrade, with defaults < 50 EURC) can never sell because `wantBtc` is rounded down. Invisible in the suite because every test uses an evenly dividing price. | math M-01 | `Math.Rounding.Ceil` on line 467. Next version. |
| M-6 | TREASURY on Circle's blacklist = every run with fee > 0.05 EURC and `sweep` revert for good. | math M-02, execute EX-05 | Fee transfer in `try`, on failure leave the fee in the contract (sweepable). Treasury key in a hardware wallet/multisig. |
| M-7 | Server dictates the mandate params, user signs blind; a wrong `.env` or manipulated prop can get cap 100 %/band 1 bps/interval 1 h signed. | mandate M-03 | Hard client-side limits in `encodeSetParams` + Vitest; bake the defaults into the bundle. |
| M-8 | Unlimited allowance + a single contract address in config: after a redeploy old mandates stay active and invisible. `WORKFLOW_OWNER` is currently the deployer EOA while the real CRE owner address is still unknown (immutable). | mandate M-04, M-05, cre CRE-04 | Decommission runbook (approve(0) + `active=false` on the old address), `legacy_addresses` in config with a revoke button, fix the workflow owner before the final deploy. |
| M-9 | No pause button, runbook or alerting; the old Privy swap engine and the on-chain mandate can be active at the same time (together 20 %/day, double costs, oversell on a stale ledger). | mandate M-06, M-07 | Skip `ScheduleRunner` if `params(owner).active`; alert on price deviation in `SweepExecutionsCommand`; runbook with revoke-all. |

## Low (brief)
- **L-1** `minTradeEurc` without a lower bound: microruns with fee 0, `minOut` 0, buys that yield 0 sats (fuzz: 2,067 → 605 units in 20 runs). Fix: `MIN_TRADE_EURC = 1e6`, `if (amountOut == 0) revert`. *(math L-01)*
- **L-2** `MIN_SLIPPAGE_BPS` 30 < spot deviation 50 + pool fees 10: spot check lets it through, router reverts. Fix: minimum 60 or `minOut` from the checked spot. *(math L-02, oracle ORC-3)*
- **L-3** DoS of `isDue`/`execute` by pushing spot > 0.5 % costs ~8,000 EURC capital + pool fees per hour. *(oracle ORC-4)*
- **L-4** No `decimals()` check on feeds in the constructor. *(oracle ORC-5)*
- **L-5** Workflow ignores `receiverContractExecutionStatus`; still zero `ReportProcessed` events on-chain, so the CRE chain has never been proven on mainnet. *(cre CRE-03)*
- **L-6** CRE ↔ keeper collision uses up a CRE report for nothing. *(execute EX-04)*
- **L-7** Keeper wallet and policy hang off the same Privy quorum; the owner can remove the policy itself. *(mandate M-08)*
- **L-8** Event sync: three weak spots on reorg/missed tx. *(mandate M-09)*
- **L-9** Sequencer feed `startedAt == 0` not caught. *(oracle ORC-6)*

## Found safe (with evidence in the detail reports)
Access control and metadata decoding of `onReport` (verified against KeystoneForwarder 1.0.0), replay (forwarder dedup + `lastExecutedAt`), reentrancy on all value entry points, reward comes out of the fee and cannot be farmed, cadence cannot be run too early/more often, `setParams` only by `msg.sender`, `sweep` does not touch user funds, all decimal conversions and `mulDiv` precision, fee exactly 25 bps of the EURC leg, no residue in the contract, no ping-pong (analytical + 6,000 fuzz runs), `minOut` from the oracle (bounds the sandwich), both hops in the spot check, cbBTC staleness, sequencer grace, no address mismatches between Laravel/keeper/CRE/Deploy.

## Static analysis
Slither: 35 findings in `Rebalancer.sol`, of which the 2 High (`arbitrary-send-erc20`) are by design and bounded, and all Medium (strict-equality ×3, uninitialized `n`, unused-return ×4) are false positives with justification. Aderyn: Low only. Neither tool sees H-1, H-2, M-1 or M-2.

## New tests (in `poc/`, not yet in the repo)
- `AuditMath.t.sol`: 12 fuzz/invariant/PoC tests (corridor, fee == 25 bps, no residue, no ping-pong, sell blockade for small wallets). 12/12 green.
- `PocStarvation.t.sol`, `PocFork.t.sol`: slot starvation and sandwich on a Base fork.
- `OracleSandwich.t.sol`: sandwich profit per run size on a Base fork.
Pitfall: under `via_ir` Solidity caches `block.timestamp` within a test; use `vm.getBlockTimestamp()` after `vm.warp`.

## Recommended order
1. **Now, without redeploy:** H-1 (Privy DENY rules), H-2 + M-3 + M-4 (workflow: rotation, delta filter, simulation/cool-down), M-9 (mutual exclusion), M-7 (client-side limits).
2. **Next contract version (before the external audit):** M-1 (TWAP/post-swap check), M-2 (new feed + decimals check), M-3 (gas budget), M-5 (Ceil), M-6 (fee in try), L-1/L-2/L-4/L-9, `MIN_TRADE_FLOOR`, final workflow owner, `lastAttemptAt`.
3. **Move the tests from `poc/` into the repo** and close the test gaps from the detail reports (5 lists, ~40 items).
4. **External audit** of the new version; this report and the PoCs as input.
5. **Decommission** the current contract: approve(0) + `active=false` for the existing owner, `legacy_addresses` in config.
