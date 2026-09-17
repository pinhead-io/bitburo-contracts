# Proofs of concept for the audit of 15 September 2026

This folder is the archive as the audit delivered it. The files here do **not** run with
`forge test`: they are outside the test path and some use the import paths of a separate
scratch project (`repo/...`).

## Adopted into the suite

| PoC | Where now | What happened to it |
|---|---|---|
| `AuditMath.t.sol` | `test/AuditMath.t.sol` | Adopted unchanged during the hardening. |
| `CrePoC.t.sol` | `test/CrePoC.t.sol` | Four tests on the `onReport` surface unchanged. PoC-1 (slot starvation) rewritten: since the hardening the dust params can no longer be registered, so the test now asserts the rejection and the fee that the cheapest allowed run does cost. |
| `PocFork.t.sol` | `test/PocFork.t.sol` | Feed updated to `0x9867…01e0` (audit M-2). The two dust tests were merged into one test that asserts the setup is rejected. The sandwich test now asserts that `execute` reverts with `SpotDeviatesFromOracle`. |
| `OracleSandwich.t.sol` | `test/OracleSandwich.t.sol` | Feed updated. The 30 bps variant became 60 bps, the tightest allowed setting since audit L-2. The assertion of the 10k variant is inverted: the attack should no longer pay off. |
| `PocStarvation.t.sol` | dropped | The same attack as PoC-1 of `CrePoC`, with the same mocks. The rewritten test there covers it; a second copy added nothing. |

## Not adopted

`GasProbe.t.sol` and `CreForkGas.t.sol` are one-off measurements without assertions. They served to
calibrate `EXECUTE_GAS`, which led to the increase from 700,000 to 1,000,000. `CreForkGas.t.sol`
also hard-codes the since-replaced contract address `0xED47…e6e5`. Anyone who wants to measure
again copies them to `test/` and adjusts the address.

## What the rewritten tests show

The PoCs no longer reproduced on the hardened contract. That is the result, not a problem:

- Dust owners can no longer be registered. `MIN_TRADE_FLOOR` (20 EURC), `MIN_CORRECTION_BPS` (10) and
  `MIN_SLIPPAGE_BPS` (60) reject every dimension of the original setup.
- The self-sandwich from M-1 no longer yields anything. At both 60 and 100 bps slippage the router cuts
  the attack off with "Too little received", the attacker earns nothing above the regular reward of
  0.05 EURC, and the victim loses nothing. Since the hardening `_requireSpotNear` also runs after
  the swap, so the front-run and the run's own price impact together have to stay within the tolerance.

The rewritten tests pin that down: if any of those properties is ever lost, they fail.
