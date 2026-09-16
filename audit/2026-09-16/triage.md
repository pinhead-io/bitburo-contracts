# Triage Slither 0.11.6 + Aderyn 0.6.8 — 2026-09-16

Scope: `src/Rebalancer.sol` op solc 0.8.37 (via-IR, cancun). Ruwe output: `slither.txt`, `aderyn.md`.
Resultaat: geen echte bugs. Alle findings zijn bedoeld gedrag of false positives.

| Tool | Detector | Plek | Oordeel |
|---|---|---|---|
| Slither (high) | arbitrary-send-erc20 | `_buy` r522, `_sell` r548 | Bedoeld: permissionless `execute` trekt alleen van een owner met actieve `params` en eigen allowance; begrensd door interval, oracle-quote, slippage en spot-check. |
| Slither (medium) | incorrect-equality | r309, r331, r476, r538 | False positive: `== 0` op bedragen, niet op balances die een aanvaller kan manipuleren. |
| Slither (medium) | uninitialized-local | `dueOwners` r289 | False positive: teller `n` start bewust op 0. |
| Slither / Aderyn L-2 | unused-return | `_quote`, `_spotOut`, `_readFeed`, `_sell` r555 | Bedoeld: niet-gebruikte tuple-velden; `_sell` meet de opbrengst via balansverschil. |
| Slither (low) | calls-loop | `dueOwners` → `_plan` | Alleen in een gepagineerde view voor de keeper; geen on-chain DoS. |
| Slither (low) | timestamp | interval- en sequencer-checks | Bedoeld: granulariteit van minuten/uren, validator-drift van seconden is irrelevant. |
| Slither (info) | naming-convention | — | Stijl. |
| Aderyn L-1 | large-numeric-literal | constanten | Stijl. |

Aderyn: 0 High. De via-IR-detector `state-variable-init-order` gaf niets.
