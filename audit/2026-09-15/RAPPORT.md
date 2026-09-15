# Interne audit Rebalancer-contract — 15 september 2026

**Scope.** `bitburo-contracts` @ c2cf093 (`src/Rebalancer.sol`, 545 regels, live op Base `0xED47…e6e5`), de CRE-workflow en het keeper-script, plus de Laravel-integratie in PR #142/#143.
**Methode.** Slither 0.11.6 + Aderyn 0.6.8, baseline-testsuite (79 groen), vijf onafhankelijke handmatige reviews per aanvalsvector (oracle, permissionless execute, CRE/onReport, rekenkunde, mandaat/integratie) met Foundry-PoC's en fork-tests op Base. Line-coverage was niet meetbaar (Foundry-instrumentatie breekt op `via_ir`).
**Uitkomst.** Geen Critical. 2 High, 9 Medium (na samenvoegen), 9 Low. Geen pad gevonden waarlangs een derde user-fondsen naar zichzelf sluist; het contract begrenst verlies per run op fee + slippage. De echte risico's zitten in (1) de Privy-policy buiten het contract, (2) liveness/DoS van de CRE-wekker, en (3) onherstelbaarheid door immutables zonder pauzeknop.

## High

### H-1 · Server-signer kan `permit` en 7702-autorisaties tekenen → volledige drain bij sleutelcompromis
*Bron: mandaat M-01.* De swap-only policy laat `eth_signTypedData_v4` en `eth_sign7702Authorization` op ALLOW. EURC en cbBTC ondersteunen EIP-2612 `permit`; een gecompromitteerde server-signer tekent een permit naar een aanvaller en die trekt elke gedelegeerde wallet leeg, buiten het contract om.
**Fix.** DENY op `eth_signTypedData_v4` met conditie op `verifyingContract in [EURC, cbBTC]` (en chainId 8453), DENY op 7702-autorisatie, of de swap-signer na de cutover verwijderen. Geen redeploy nodig. **Doen vóór volgende productiegebruik.**

### H-2 · Dust-owners kunnen de CRE-wekker permanent uithongeren
*Bron: execute EX-01, cre CRE-02, mandaat M-02 (samengevoegd).* `setParams` heeft geen economische ondergrens, `dueOwners` levert in registratievolgorde, de workflow neemt de eerste vijf. Vijf wallets met 1 EURC, `minTradeEurc=1`, `maxCorrectionBps=1`, interval 1 u zijn elk uur due en bezetten alle slots. PoC over 48 uur: echte gebruiker nooit bediend, kosten aanvaller 0,005 EURC, plus Bitburo's CRE-gas leeg.
**Fix zonder redeploy.** Roterende startoffset per run in de workflow en filter op `|eurcDelta| >= ~20 EURC` via `isDue` (ook in `keeper.ts`). **Volgende contractversie:** `MIN_TRADE_FLOOR` (≥ 1–20 EURC) en ondergrens op `maxCorrectionBps` in `setParams`.

## Medium

| ID | Bevinding | Bron | Fix |
|---|---|---|---|
| M-1 | Executor kan zijn eigen run atomair sandwichen via `slot0`; winstgevend vanaf ~2.500 EURC per run (fork-PoC: +27 EURC bij 10k, slachtoffer −0,3 tot −0,68 %). Begrensd door `maxSlippageBps` omdat `minOut` van de oracle komt. | oracle ORC-1, execute EX-03 | Volgende versie: TWAP via `observe()` en/of post-swap-deviatiecheck. Nu: app default `maxSlippageBps` 30–50, README documenteert max verlies = 25 bps + slippage. |
| M-2 | EURC/USD-feed `0xDAe3…8250` (24 u heartbeat) staat niet meer in Chainlinks referentiedirectory; bij deprecatie is het immutable contract permanent dood (`StaleFeed`). | oracle ORC-2 | Bij redeploy `0x9867…01e0` (1 u / 0,1 %) gebruiken, `decimals()==8` afdwingen, fork-test op feed-versheid. Nu: monitoren. |
| M-3 | `EXECUTE_GAS` 700k te krap: ~19k EURC-runs gaan out-of-gas, blijven eeuwig due, branden elk uur CRE-gas. | cre CRE-01 | Workflow: owners met grote `eurcDelta` overslaan en aan het open keeper-script laten. Volgende versie: gasbudget ~1M. |
| M-4 | Owners waarvan `execute` altijd revert (amountIn=1, blacklist, te krappe slippage) blijven eeuwig due en kosten elke keeper ~158k gas per poging. | execute EX-02 | Keeper/workflow: eerst simuleren + cool-down per owner. Volgende versie: `lastAttemptAt` in de catch-tak. |
| M-5 | Kleine wallets (total × cap < minTrade, bij defaults < 50 EURC) kunnen nooit verkopen door afronding van `wantBtc` naar beneden. Onzichtbaar in de suite omdat elke test een rond deelbare koers gebruikt. | math M-01 | `Math.Rounding.Ceil` op regel 467. Volgende versie. |
| M-6 | TREASURY op Circle-blacklist = elke run met fee > 0,05 EURC én `sweep` reverten voorgoed. | math M-02, execute EX-05 | Fee-transfer in `try`, fee bij falen in contract laten (sweep-baar). Treasury-sleutel in hardware wallet/multisig. |
| M-7 | Server dicteert de mandaat-params, gebruiker tekent blind; een foute `.env` of gemanipuleerde prop kan cap 100 %/band 1 bps/interval 1 u laten tekenen. | mandaat M-03 | Harde client-side grenzen in `encodeSetParams` + Vitest; defaults in de bundel bakken. |
| M-8 | Onbeperkte allowance + één contractadres in config: na redeploy blijven oude mandaten actief en onzichtbaar. `WORKFLOW_OWNER` is nu de deployer-EOA terwijl het echte CRE-owner-adres nog onbekend is (immutable). | mandaat M-04, M-05, cre CRE-04 | Decommissie-runbook (approve(0) + `active=false` op oud adres), `legacy_addresses` in config met intrekken-knop, workflow-owner vastleggen vóór definitieve deploy. |
| M-9 | Geen pauzeknop, runbook of alerting; oude Privy-swapmotor en on-chain mandaat kunnen tegelijk actief zijn (samen 20 %/dag, dubbele kosten, oversell op verouderde ledger). | mandaat M-06, M-07 | `ScheduleRunner` overslaan als `params(owner).active`; alert op prijsafwijking in `SweepExecutionsCommand`; runbook met revoke-all. |

## Low (kort)
- **L-1** `minTradeEurc` zonder ondergrens: microruns met fee 0, `minOut` 0, kopen die 0 sats opleveren (fuzz: 2.067 → 605 units in 20 runs). Fix: `MIN_TRADE_EURC = 1e6`, `if (amountOut == 0) revert`. *(math L-01)*
- **L-2** `MIN_SLIPPAGE_BPS` 30 < spotdeviatie 50 + poolfees 10: spot-check laat door, router revert. Fix: minimum 60 of `minOut` van de gecontroleerde spot. *(math L-02, oracle ORC-3)*
- **L-3** DoS van `isDue`/`execute` door spot > 0,5 % te duwen kost ~8.000 EURC kapitaal + poolfees per uur. *(oracle ORC-4)*
- **L-4** Geen `decimals()`-check op feeds in constructor. *(oracle ORC-5)*
- **L-5** Workflow negeert `receiverContractExecutionStatus`; nog nul `ReportProcessed`-events on-chain, dus de CRE-keten is op mainnet nooit bewezen. *(cre CRE-03)*
- **L-6** CRE ↔ keeper-botsing verbruikt een CRE-rapport leeg. *(execute EX-04)*
- **L-7** Keeper-wallet en policy hangen aan dezelfde Privy-quorum; owner kan de policy zelf verwijderen. *(mandaat M-08)*
- **L-8** Event-sync: drie zwakke plekken bij reorg/gemiste tx. *(mandaat M-09)*
- **L-9** Sequencer-feed `startedAt == 0` niet afgevangen. *(oracle ORC-6)*

## Veilig bevonden (met bewijs in de detailrapporten)
Toegangscontrole en metadata-decoding van `onReport` (geverifieerd tegen KeystoneForwarder 1.0.0), replay (forwarder-dedup + `lastExecutedAt`), reentrancy op alle waarde-ingangen, beloning komt uit de fee en is niet te farmen, cadans niet te vroeg/vaker te draaien, `setParams` alleen door `msg.sender`, `sweep` raakt geen gebruikersfondsen, alle decimaal-omrekeningen en `mulDiv`-precisie, fee exact 25 bps van het EURC-been, geen restanten in het contract, geen ping-pong (analytisch + 6.000 fuzz-runs), `minOut` uit de oracle (begrenst de sandwich), beide hops in de spot-check, staleness cbBTC, sequencer-grace, geen adres-mismatches tussen Laravel/keeper/CRE/Deploy.

## Statische analyse
Slither: 35 meldingen in `Rebalancer.sol`, waarvan de 2 High (`arbitrary-send-erc20`) by design en begrensd zijn, en alle Medium (strict-equality ×3, uninitialized `n`, unused-return ×4) false positives met onderbouwing. Aderyn: alleen Low. Geen van beide tools ziet H-1, H-2, M-1 of M-2.

## Nieuwe tests (in `poc/`, nog niet in de repo)
- `AuditMath.t.sol`: 12 fuzz/invariant/PoC-tests (corridor, fee == 25 bps, geen restanten, geen ping-pong, sell-blokkade kleine wallets). 12/12 groen.
- `PocStarvation.t.sol`, `PocFork.t.sol`: slot-starvation en sandwich op Base-fork.
- `OracleSandwich.t.sol`: sandwich-winst per rungrootte op Base-fork.
Valkuil: onder `via_ir` cachet Solidity `block.timestamp` binnen een test; gebruik `vm.getBlockTimestamp()` na `vm.warp`.

## Aanbevolen volgorde
1. **Nu, zonder redeploy:** H-1 (Privy DENY-regels), H-2 + M-3 + M-4 (workflow: rotatie, delta-filter, simulatie/cool-down), M-9 (wederzijdse uitsluiting), M-7 (client-side grenzen).
2. **Volgende contractversie (vóór externe audit):** M-1 (TWAP/post-swap-check), M-2 (nieuwe feed + decimals-check), M-3 (gasbudget), M-5 (Ceil), M-6 (fee in try), L-1/L-2/L-4/L-9, `MIN_TRADE_FLOOR`, workflow-owner definitief, `lastAttemptAt`.
3. **Tests uit `poc/` opnemen in de repo** en de testgaten uit de detailrapporten dichten (5 lijsten, ~40 items).
4. **Externe audit** op de nieuwe versie; dit rapport en de PoC's als input.
5. **Decommissie** van het huidige contract: approve(0) + `active=false` voor de bestaande owner, `legacy_addresses` in config.
