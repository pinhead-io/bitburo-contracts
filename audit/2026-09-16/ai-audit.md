# AI-audit Rebalancer — 2026-09-16

Scope: `src/Rebalancer.sol` op solc 0.8.37 (via-IR, cancun), commit `48cc7f9`.

| Tool | Versie | Resultaat |
|---|---|---|
| Slither | 0.11.6 | 30 meldingen, allemaal by design of false positive (`triage.md`) |
| Aderyn | 0.6.8 | 0 High, 2 Low (stijl) |
| pashov/skills `solidity-auditor` | commit `c577eb7`, VERSION 3 | 11 van 12 agents (Opus). Agent 12 (flow-gap) viel twee keer uit door een API-fout, dus dat perspectief ontbreekt |
| QuillShield `oracle-flashloan-analysis` | commit `8bdd3c0` | Chainlink-validatie volledig PASS, sandwich FAIL |
| Echidna | 2.3.3 | Niet bruikbaar met deze handler-opzet (zie onderaan) |
| Foundry invariants | forge, 1.000 runs × depth 100 | 5/5 groen |

Vergeleken met `audit/2026-09-15/RAPPORT.md`: **M-1 is nog open** — de post-swap-check verkleint de sandwich-winst, maar sluit hem niet. De overige punten hieronder zijn nieuw. Of de andere punten uit dat rapport (H-1, H-2, M-2 t/m M-9, L-1 t/m L-9) zijn opgelost, is in deze ronde niet systematisch nagelopen.

---

## Findings

### M-1 (nog open, uit 2026-09-15) — Caller kan zijn eigen `execute` nog steeds winstgevend sandwichen (Medium, bevestigd)

`Rebalancer.execute` → `_buy`/`_sell` + `_requireSpotNear`

**Oorzaak:** de spotcheck vóór en na de swap staat 50 bps afwijking van de oracle toe. `minOut` ligt 60–100 bps onder de oracle. Samen laten ze ruimte voor een gedeeltelijke push van de pool (push + eigen impact van het slachtoffer ≤ 50 bps) die nog steeds winst oplevert. Volgens de NatSpec (r33) sluit de post-swap-check die ruimte "grotendeels"; in de praktijk blijft er winst over.

**Bewijs (Base-fork, `test/OracleSandwich.t.sol::test_poc_sweepSell`, zelf gedraaid op 0.8.37):**

| Verkooprun (EURC) | Push (USDC) | Winst aanvaller | Verlies slachtoffer |
|---|---|---|---|
| 4.929 | 2.099 | +3,55 USDC | 4,82 EURC |
| 4.929 | 4.198 | **+7,80 USDC** | **10,30 EURC** (21 bps) |
| 2.466 | 6.298 | +2,51 USDC | 7,56 EURC |
| 990 | alle pushes | verlies | — |

Koopruns (oracle-agent, fork): 2.500–5.000 EURC levert +2,8 tot +4,0 EURC op.

**Wordt erger als de oracle legitiem achterloopt.** De oracle-agent heeft cbBTC/USD 0,3% te hoog gemockt. Dat valt binnen de deviation-drempel van de feed (0,3% volgens Chainlink-directory). Een koop van 5.000 EURC levert de aanvaller dan +13,6 EURC op en kost het slachtoffer ≈ 18,3 EURC (37 bps). Dit staat in de scratchpad-test `ScratchLag.t.sol` en zit nog niet in de repo.

**Gevolg:** elke run vanaf ~2,5k EURC lekt 0,2–0,55% naar wie als eerste `execute` aanroept, en dat herhaalt zich elk interval. De gedocumenteerde grens (max `FEE_BPS + maxSlippageBps` verlies ten opzichte van de oracle) blijft wel gelden.

**Fix (volgende versie):** vergelijk vóór de swap de huidige tick per pool met de eigen korte TWAP (`observe`, 5–10 min, ±10 bps). Houd daarnaast de check TWAP ↔ oracle op 50 bps aan en baseer `expectedOut` op de TWAP-prijs. Controleer eerst `observationCardinality` van de EURC/USDC-pool (on-chain 200). Alleen `MAX_SPOT_DEVIATION_BPS` verlagen werkt niet: de feeds mogen tot 0,3% + 0,1% achterlopen, dus dan reverten eerlijke runs.

---

## Low / informational

### L-A — `dueOwners` en `owners` reverten bij een grote `limit` (4 agents)
`Math.min(offset + limit, total)` (r250, r289) overflowt bij `offset ≥ 1` en `limit = type(uint256).max`. Dat is in strijd met de NatSpec "Revert nooit". De keeper gebruikt een vaste `pageSize` en wordt dus niet geraakt.
Fix: `uint256 end = limit > total - offset ? total : offset + limit;`

### L-B — Fee-ondergrens klopt niet voor verkopen (5 agents)
`MIN_TRADE_FLOOR` (r76-80) belooft dat de fee van de kleinste run de keeper-beloning dekt. Bij een verkoop wordt de floor gecontroleerd op de oraclewaarde, maar de fee berekend op `received` (na poolfees en slippage). Rekenvoorbeeld: waarde 20,000160 EURC, received 19,98 → fee 49.950 < 50.000 → treasury krijgt 0. Het gaat om stofbedragen, maar de NatSpec klopt niet.
Fix: fee over `max(received, expectedOut)`, of de floor controleren op `received`, of de NatSpec corrigeren.

### L-C — `isDue` rapporteert een grotere run dan `execute` uitvoert (2 agents)
`_dueAt` (r314) geeft `correctionEurc` terug, dus zonder de allowance-cap. `execute` handelt `amountIn`, en dat is wél gecapt. Voorbeeld: allowance 20 EURC → `eurcDelta` 1.000 EURC, run 20 EURC. De keeper-filter `runSizeSkipReason` (keeper.ts:111) vertrouwt op dat getal. Zolang `MIN_RUN_EURC = 20` gelijk is aan de floor heeft dit geen effect.
Fix: `eurcDelta` afleiden van `amountIn`.

---

## Leads (handmatig nalopen)

- **Pool-feetier niet afgedwongen in de constructor** (6 agents). `_poolOrder` controleert alleen token0/token1, niet `fee() == POOL_FEE` of `factory.getPool`. Drie agents hebben on-chain met `cast` geverifieerd dat de huidige deploy-pools de 0.05%-pools van de SwapRouter02-factory zijn. Dit is dus hardening voor een volgende deploy.
- **Meerdere wallets per push** (oracle-agent). Eén push gevolgd door meerdere `execute`-calls voor verschillende due owners telt hun volume op, waardoor kleine wallets samen de winstgevende grootte halen. Zelfde mechanisme als M-1; niet getest.
- **Donatie over de bandgrens** (agents 10, 11). Een kleine donatie duwt een owner die net binnen de band zit erover, en `_plan` corrigeert dan de volledige drift (r493). Daarmee kan de aanvaller zelf het blok kiezen voor M-1. Extra winst boven M-1 is niet bewezen.
- **Front-run van `setParams`/`approve(0)`** (agent 5). Een run op de oude parameters vlak vóór een wijziging. Op Base (FCFS-sequencer) is dat onbewezen.
- **Oracle mogelijk deels afgeleid van DEX-prijzen** (oracle-agent). De Chainlink-directory labelt beide feeds `dex_state_price`. Als daar de Base EURC/USDC-pool in zit, controleert de oracle deels zichzelf. Navragen bij Chainlink.
- **Geen absolute min/max op feed-antwoorden** (oracle-agent). Alleen relevant als een feed eerst ernstig faalt.
- **Goedkope DoS via spot-push** (agent 3). Ongeveer 8 EURC aan poolfees laat alle runs tijdelijk reverten. Dit is bekend als L-3.
- **H-2-restant** (agent 11). Starvation van keeper-slots kost met `MIN_TRADE_FLOOR` ~8 EURC per dag voor 5 slots, tenzij de CRE-wekker zijn start-offset rouleert. Nagaan of die rotatie er is.
- **`_spotOut` deelt door 0 bij `sqrtPriceX96 < 2^48`** (agent 6). Latent; niet bereikbaar met de huidige pools.

## Gecontroleerd en in orde
- **Chainlink-validatie:** `answer > 0`, `updatedAt` niet in de toekomst, MAX_AGE boven de heartbeat (1200 s / 3600 s), 8 decimals, sequencer + 1 uur grace period.
- **Fee-boekhouding:** reward + treasury + retained = fee; `trySafeTransfer` is niet gas-griefbaar.
- **`received` bij verkoop:** het balansverschil klopt ook als er nog fee in het contract zit.
- **Reentrancy:** `sweep`/`execute` delen de transient lock.
- **Router-sentinels:** onbereikbaar.
- **Tegengestelde pushes op beide pools:** leveren geen winst op.
- **Prijsrekenwerk:** tokenvolgorde en precisie van `_spot` zijn correct voor EURC < USDC < cbBTC.
- **Afronding in `_plan`:** geen oversell en geen overshoot.
- **`retire`:** kan alleen stoppen, geen fondsen bewegen.

## Fuzzing

**Echidna 2.3.3 (foundry-modus):** drie pogingen, geen bruikbaar resultaat.
- **Met `allContracts`:** 2 miljoen calls, 106/590 contractregels geraakt. Twee invariants braken (`contractNeverHoldsBalance`, `ownerBalancesOnlyMoveThroughExecute`), maar alleen doordat Echidna `MockERC20.mint` rechtstreeks aanriep, buiten de ghost-boekhouding van de handler. Dat is een fout in de testopzet, geen bug.
- **Met een whitelist op de handler-functies:** het filter werkt niet met de handler; slechts 3 contractregels geraakt. Uitkomst ongeldig.

**Foundry invariants, diep** (`FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=100`, standaard 64 × 32): 5/5 groen, ~11.000 calls per handler-functie per invariant, 0 onverwachte reverts.

Voor Echidna of Medusa is een eigen property-harness nodig, of pashov `fizz` die er een genereert.
