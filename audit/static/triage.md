# Static analysis of the rewritten Rebalancer: triage

Run on 17 September 2026 at commit `882582a` with `FORK_BLOCK=51425248 bash audit/run-static.sh audit/static`: solc 0.8.37 (0 known bugs), forge 1.5.1, Slither 0.11.6 (25 results), Aderyn 0.6.8 (0 High, 3 Low). Tests in the same run: 84 passed, deep invariants (1000 runs x depth 100) 14 passed. Nothing below needs a code change.

## Slither, results in `src/Rebalancer.sol`

| Detector | Where | Verdict |
|---|---|---|
| `arbitrary-send-erc20` (arbitrary `from` in `transferFrom`) | `execute`, both `safeTransferFrom(owner, …)` | By design: the mandate is an ERC-20 allowance and `owner` is the mandate's owner. Guarded by `msg.sender == owner || msg.sender == keeper` (`:198`), the interval, the rule in `_plan` and the price bound in `_swap`; the output only ever goes back to `owner`. Tests: `test_execute_revertsForStranger`, `test_execute_replacedKeeperIsRefused`, `invariant_onlyOwnerOrKeeperRuns`. |
| `reentrancy-balance` / `reentrancy-no-eth` in `_swap` | balance read before and after `ROUTER.exactInputSingle` | By design: the balance difference is the measurement. `execute` and `sweep` are `nonReentrant`, and USDC, cbBTC and SwapRouter02 call no third-party code. Test: `test_sweep_maliciousTokenCannotReenter` (fails without the guard). |
| `divide-before-multiply` in `_plan` | `position = btc * price / 1e8`, then `position * BPS` | Accepted: `position` loses less than one USDC base unit (1e-6 USDC), and the same `position` is used for `total`, so both sides of the comparison agree. |
| `incorrect-equality` | `amountIn == 0`, `received == 0`, `targetBps == 0` | Intended sentinels, not balance comparisons. |
| `unused-return` | `latestRoundData` (only the fields that are used), `exactInputSingle` | Intended: the router's return value is deliberately not trusted; the balance difference is. |
| `timestamp` | `INTERVAL`, feed age, grace period, `_finishing` | Intended: day-scale and minute-scale comparisons; a sequencer's few seconds of freedom change nothing. |
| naming, solc version, low-level/assembly notes in `lib/` | OpenZeppelin | Not ours. |

## Aderyn

| ID | What | Verdict |
|---|---|---|
| L-1 Large numeric literal | `10_000`, `1e8`, `20e6` | Named constants with a comment; readable as they are. |
| L-2 Literal instead of constant | the decimals `6` and `8` in the constructor, used once each | Left: a constant per check would not make it clearer. |
| L-3 Unchecked return | `_quote()` in the constructor, `exactInputSingle` | The constructor call is a liveness check that reverts on failure; the router's return value is deliberately unused (see Slither). |
