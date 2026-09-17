# Triage Slither 0.11.6 + Aderyn 0.6.8 — 2026-09-17

Scope: `src/` op commit `bab2ed3` (`development`), solc 0.8.37, `via_ir = true`, `evm_version = cancun`. Ruwe output: `slither.txt`/`slither.json` (39 meldingen) en `aderyn.md` (1 High, 4 Low). Regelnummers verwijzen naar `bab2ed3`.

**Resultaat: geen echte bugs.** Alle meldingen zijn bedoeld gedrag, stijl of false positive.

## Slither

| Detector (impact) | Aantal | Plek | Oordeel | Reden |
|---|---|---|---|---|
| arbitrary-send-erc20 (High) | 2 | `_buy` `src/Rebalancer.sol:960`, `_sell` `:988` | bedoeld | `execute` is permissionless, maar trekt alleen van een owner met `params.active` (`:530`) en een eigen allowance. Bedrag, richting en ontvanger volgen uit `_plan` en de params van de owner; de output gaat altijd naar `owner` (`:971`, `:1008`). De aanroeper kiest alleen het moment en `rewardTo` (≤ 0,05 EURC). |
| incorrect-equality (Medium) | 5 | `:500`, `:543`, `:884`, `:976` (`== 0` op bedragen), `:691` (`lastTimestamp == uint32(block.timestamp)`) | false positive | `== 0` op berekende bedragen, niet op balances waarmee een aanvaller een gelijkheid kan breken. `:691` is de blokcheck zelf: gelijkheid betekent "observatie in dit blok" (Base-bloktijden zijn uniek per blok; `uint32` loopt pas in 2106 over). |
| divide-before-multiply (Medium) | 1 | `_maxInput` `:784-786` | bedoeld | Bewust afronden van de tick naar een veelvoud van `TICK_SPACING`, met correctie voor negatieve ticks (`:785`). Voorbeeld: tick −5 → `−5 / 10 = 0`, rest ≠ 0 → −1 → grens −10 (floor). Getest in `test_cliff_negativeTickInCbbtcPool` (`test/BlockWindow.t.sol`). |
| uninitialized-local (Medium) | 4 | `caps` `:438`, `:468`, `:540`; `n` `:466` | false positive | `RunCaps caps` moet leeg starten (lege cache, NatSpec `:726-729`); teller `n` start bewust op 0. |
| unused-return (Medium) | 8 | `_quote` `:600`, `_spotOut` `:641`, `_window` `:689-690`, `_requireWithinWindow` `:712`, `_maxInput` `:790`, `_readFeed` `:812`, `_sell` `:995` | bedoeld | Niet-gebruikte tuple-velden. `answeredInRound` is door Chainlink afgeschaft. `_sell` meet de opbrengst via het balansverschil (`:994`, `:1003`), wat ook achtergebleven fee in het contract correct uitsluit. |
| calls-loop (Low) | 5 | `dueOwners` → `_plan` `:880`, `:881`, `:924`, `:931`; `_maxInput` `:790` | bedoeld | Alleen in de gepagineerde view `dueOwners`; `limit` kiest de aanroeper. `pool.ticks` wordt per richting één keer per pagina gelezen (`RunCaps`, review I-2). Geen on-chain DoS: geen schrijvende functie loopt over owners. |
| timestamp (Low) | 4 | `_timing` `:514`, `:517`; `_quote` `:602`; `_readFeed` `:815`; `_window` `:691` | bedoeld | Intervallen van minuten tot uren; op Base bepaalt de sequencer de tijdstempel (2 s per blok). `:691` is de blokcheck. |
| naming-convention (Info) | 10 | immutables `:107-121` | stijl | Immutables in HOOFDLETTERS zijn bewust (zelfde stijl als constanten). |

## Aderyn

| ID Aderyn | Plek | Oordeel | Reden |
|---|---|---|---|
| H-1 Incorrect Assembly Shift Parameter Order (3×) | `src/libraries/TickMath.sol:64` (2×), `:95` | **false positive** | In Yul is `shl(x, y)` "logical shift left y by x bits" en `shr(x, y)` "logical shift right y by x bits" (`docs/yul.rst:809`, `:811` in `github.com/argotorg/solidity`, blob `f36a29e`, gelezen 2026-09-17). `shl(128, 1)` is dus `1 << 128` en `shr(32, …)` is `… >> 32`, precies wat bedoeld is. `getSqrtPriceAtTick` is, op de revert-stijl na (`revert InvalidTick(tick)` in plaats van `InvalidTick.selector.revertWith(tick)`), identiek aan Uniswap v4-core commit `46c6834` (`diff -w` op 2026-09-17). Fork-tests die de vensterranden tegen echte pools meten, zijn groen (`forge-test.txt`). |
| L-1 Large Numeric Literal (2×) | `src/Rebalancer.sol:130`, `:177` | stijl | `50_000` en `10_000` zijn leesbaar met scheidingstekens. |
| L-2 Literal Instead of Constant (19×) | `TickMath.sol:66-84` | stijl | Magische getallen van de Uniswap-tabel; ongewijzigd overgenomen. |
| L-3 Loop Contains `require`/`revert` (1×) | `src/Rebalancer.sol:469` (`dueOwners`) | bedoeld | Het pad in de lus revert niet bij echte tokens en pools: feed-, sequencer- en spotfouten zijn vóór de lus via `try this.quoteChecked()` afgevangen (`:455`, `_tryQuote` `:821-827`), extreme ticks geven een leeg venster (`:697-700`). Getest met `test_dueOwners_emptyOnFeedFailureNeverReverts` en `test_spot_extremeSqrtPriceNeverPanicsInViews`. |
| L-4 Unchecked Return (1×) | `src/Rebalancer.sol:995` | bedoeld | Zie Slither unused-return: `_sell` meet via het balansverschil. |

Vergeleken met 2026-09-16 (30 meldingen Slither, 0 High / 2 Low Aderyn): de extra meldingen komen door de nieuwe code voor het blokvenster (`_window`, `_maxInput`, `RunCaps`) en door `TickMath.sol`, dat toen nog niet bestond.
