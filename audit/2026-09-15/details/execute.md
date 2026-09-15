# Rebalancer – adversariële review: permissionless `execute`, beloning en cadans

Scope: `src/Rebalancer.sol` (Solidity 0.8.28, OZ 5.6.1, via-IR), `src/interfaces/*.sol`, `README.md`, `test/Rebalancer.t.sol`, `test/RebalancerFork.t.sol`, `keeper/keeper.ts`, `cre/bitburo-keeper/main.ts` (+ `config.production.json`). Live contract op Base: `0xED47d549345b0dBB5A9b44E57Ff3AB4E6Ed0e6e5`; ik heb de constanten `KEEPER_REWARD_EURC=50000`, `FEE_BPS=25`, `MIN_INTERVAL=3600`, `MAX_SPOT_DEVIATION_BPS=50`, `EXECUTE_GAS=700000` en `ownerCount()=1` via `cast call` bevestigd, dus de broncode komt overeen met wat live staat.

PoC's staan in `scratchpad/poc/test/PocStarvation.t.sol` (mocks) en `scratchpad/poc/test/PocFork.t.sol` (fork van Base mainnet, blok ~51.337.327). Alle drie de fork-PoC's en de mock-PoC slagen; de repo is niet aangeraakt.

Regelverwijzingen zijn naar `src/Rebalancer.sol` tenzij anders vermeld.

---

## EX-01 — High — Stof-owners bezetten permanent alle vijf CRE-slots (starvation van de primaire wekker)

**Regels:** `setParams` 197–212 (geen ondergrens op `minTradeEurc`/`maxCorrectionBps`, `_owners` append-only), `dueOwners` 248–275 (registratievolgorde, offset in `_owners`), `_plan` 453–459 (`cap = max(total*maxCorrection, minTrade)`), `cre/bitburo-keeper/main.ts` 178–195 (eerste `maxOwnersPerReport` due owners vanaf offset 0), `config.production.json` (`maxOwnersPerReport: 5`, cron elk uur).

**Beschrijving.** De enige eisen aan een owner zijn `minTradeEurc >= 1` (basiseenheid, dus 0,000001 EURC), `maxCorrectionBps >= 1` en `interval >= 1 hours`. Een owner met 1 EURC saldo, `maxCorrectionBps = 1`, `minTradeEurc = 1`, `bandBps = 1`, `interval = 1 hours` is daardoor elk uur opnieuw due voor een run van 100 basiseenheden (0,0001 EURC):

```solidity
cap = Math.mulDiv(total, p.maxCorrectionBps, BPS);      // 1e6 * 1 / 10000 = 100
if (cap < p.minTradeEurc) cap = p.minTradeEurc;
if (correctionEurc > cap) correctionEurc = cap;         // 100
if (correctionEurc < p.minTradeEurc) { return ...; }    // 100 >= 1 -> due
```

De CRE-workflow neemt de eerste vijf due owners in registratievolgorde en stopt dan met bladeren:

```ts
for (let offset = 0n; offset < ownerCount && dueOwners.length < config.maxOwnersPerReport; offset += ...) {
  const page = readContract(..., "dueOwners", [offset, ...]);
  for (const owner of page) { if (dueOwners.length < config.maxOwnersPerReport) dueOwners.push(owner); }
}
```

`_owners` kan nooit krimpen en er is geen manier om een owner uit de lijst te halen (ook niet door de owner zelf; `active=false` laat hem in de lijst staan). Vijf stof-owners die vóór echte gebruikers zijn geregistreerd (op dit moment staat er 1 owner live, dus de eerste vijf plekken zijn nu voor het grijpen) staan dus voor altijd vooraan en zijn elk uur due. Elke CRE-run bevat daardoor alleen die vijf, en geen enkele echte gebruiker wordt nog door de CRE-wekker bediend.

**Aanvalsscenario (getallen).**
- Kosten aanvaller: 5 × `setParams` (98.669 gas gemeten, ≈ €0,001 op Base) + 5 × `approve` + 5 EURC totaal. Per stof-run verdwijnt 100 basiseenheden EURC naar de swap; na 48 uur staat een stof-owner op 995.247 van 1.000.000 (0,0048 EURC). Met 1 EURC houdt hij dit ruim 400 dagen vol.
- Opbrengst Bitburo: fee = `100 * 25 / 10000 = 0`, treasury na 240 stof-runs: 0 EURC (PoC).
- Kosten Bitburo: 5 × ~250.000 gas per uur voor niets (fork: 251.923 gas per geslaagde stof-run), plus de reputatieschade dat "elk uur automatisch rebalancen" voor alle echte klanten stil ligt. Het open keeper-script blijft een uitweg, maar dat is precies de wekker die Bitburo niet in de hand heeft.
- Bewijs: `PocStarvation.test_poc_dustOwnersStarveRealUserForever` (48 uur gesimuleerd, alice met 1.000 EURC is elk uur due en wordt nooit bediend); `PocFork.test_poc_dustRunSucceedsWithZeroFee` (echte Uniswap-route: amountIn 100, fee 0, 251.923 gas).

**Bestaande testdekking.** `test_setParams_boundaryValuesAccepted` legt juist vast dat `minTradeEurc = 1` en `maxCorrectionBps = 1` geldig zijn. `test_onReport_stopsCleanlyWhenGasRunsOut` en de CRE-test "pages through dueOwners and caps the report at maxOwnersPerReport" testen het afkappen op vijf, maar niet wie er dan buiten de boot valt over meerdere runs. Geen test met meer dan vijf due owners over meerdere uren.

**Aanbevolen fix.**
1. Nu, zonder contractwijziging (de workflow en het script zijn wél aanpasbaar): laat de CRE-workflow niet altijd bij offset 0 beginnen. Bijvoorbeeld een roterende startoffset per run (`(runIndex * maxOwnersPerReport) % ownerCount`, of een offset afgeleid van het blocknummer) en rond-lopen tot het rapport vol is. Daarmee komt iedereen aan de beurt, ongeacht wie er vooraan staat.
2. Nu: filter in de workflow én in `keeper.ts` op economische zin: neem alleen owners op met `|eurcDelta| >= 20 EURC` (dan is fee ≥ beloning) of minimaal een fee die de gas dekt. `isDue` geeft `eurcDelta` al terug, dus dat is één extra view-call per kandidaat.
3. Volgende contractversie: een globale ondergrens `MIN_TRADE_FLOOR` in `setParams` (bijvoorbeeld 20 EURC = 20e6, zodat fee ≥ `KEEPER_REWARD_EURC`), plus `maxCorrectionBps >= 100` of een ondergrens op `total` in `_plan`. Overweeg ook `dueOwners` een `startOffset`-rotatie of een `sinceLastAttempt`-filter te geven (zie EX-02).

---

## EX-02 — Medium — Owners waarvan `execute` altijd revert blijven eeuwig due en verspillen gas van elke keeper

**Regels:** `execute` 300–303 (`lastExecutedAt` wordt pas na `_plan` gezet en gaat mee terug bij een revert), `_dueAt` 277–284 en `dueOwners` 266 (kijken alleen naar `_plan`, niet naar eerdere mislukkingen), `onReport` 330–333 (`catch` schrijft alleen een event), `keeper/keeper.ts` 58–65 (stuurt zonder simulatie en zonder geheugen).

**Beschrijving.** `isDue`/`dueOwners` zeggen "ja" zodra `_plan` een `amountIn > 0` geeft. Of de swap daarna slaagt, weet het contract niet. Een revert laat `lastExecutedAt` op de oude waarde, dus de owner blijft due; elke wekker probeert het elke run opnieuw. Een aanvaller kan dat deterministisch afdwingen: met 10 basiseenheden EURC en dezelfde stof-params als EX-01 is `cap = max(0, 1) = 1`, dus `amountIn = 1`. Op de echte route rondt de eerste hop (1 basiseenheid, 0,05% fee) af naar 0 output, waarna de tweede hop in de Uniswap-pool revert op `amountSpecified != 0`. De run kost de aanroeper 158.398 gas (fork) en verandert niets.

Hetzelfde patroon ontstaat zonder kwade opzet: een owner die door Circle op de blacklist is gezet (`test_execute_revertsWhenOwnerBlacklisted` laat zien dat `lastExecutedAt` 0 blijft), een owner met `maxSlippageBps = 30` en een run die structureel meer dan 0,3% slippage haalt in de dunne EURC/USDC-pool, of een owner met `total` zo klein dat de output 0 wordt.

**Aanvalsscenario (getallen).** Vijf zulke owners kosten samen 50 basiseenheden EURC en vijf registraties. Ze bezetten de CRE-slots zoals in EX-01 (goedkoper nog: er wordt nooit iets van hen afgeschreven) en laten `keeper.ts` elk uur 5 × ~160.000 gas verliezen zonder beloning. Wie `keeper.ts` ongewijzigd draait, draait structureel verlies.

Bewijs: `PocFork.test_poc_dustOwnerAlwaysDueAlwaysReverts` (isDue true, execute revert, `lastExecutedAt` 0, isDue daarna nog steeds true).

**Bestaande testdekking.** `test_execute_lastExecutedAtNotSetOnRevert` en `test_onReport_skipsOnSwapFailure` testen dat een revert niets boekt, maar niemand test dat zo'n owner daarna eeuwig in `dueOwners` staat of dat een minimale amountIn op de echte route revert.

**Aanbevolen fix.**
- Keeper-script en CRE-workflow: simuleer eerst (`eth_call`/`estimateGas` op `execute`) en houd per owner een cool-down bij na een mislukking (bijvoorbeeld overslaan tot de volgende dag, exponentieel oplopend).
- Volgende contractversie: laat `onReport` in de `catch`-tak `lastAttemptAt[owner] = block.timestamp` schrijven (dat kan, `onReport` zelf revert niet) en laat `dueOwners` owners overslaan met een recente mislukte poging. Ook hier helpt de ondergrens uit EX-01: met `minTradeEurc >= 20 EURC` kan de afrondings-revert niet meer.

---

## EX-03 — Medium (by design, gedocumenteerd) — De aanroeper kiest het moment en kan zijn eigen `execute` sandwichen; verlies per run begrensd door `maxSlippageBps`

**Regels:** `_quoteChecked` 362–367 (spot-check 0,5% vóór de swap), `_buy` 483–484 / `_sell` 503–504 (`minOut` op de oraclekoers × (1 − `maxSlippageBps`)), `setParams` 201–202 (`maxSlippageBps` 30–100), `_buy` 479 / `_sell` 501 (de Slither "arbitrary-send-erc20"-regels).

**Beschrijving.** Dit is de kern van de Slither-bevindingen `arbitrary-send-erc20`: `safeTransferFrom(owner, …)` met een door de aanroeper gekozen `owner`. Mijn oordeel: by design en begrensd, geen diefstal mogelijk. Wat een derde kan doen is uitsluitend *wanneer* kiezen; bedrag (`_plan`, begrensd op correctie, cap, saldo en allowance), richting, route, ontvanger (`recipient: owner` bij kopen; bij verkopen gaat alles minus fee via `safeTransfer(owner, …)` terug) en fee liggen vast. Per run kan de owner hoogstens verliezen: fee 25 bps + slippage tot `maxSlippageBps` (30–100 bps) ten opzichte van de Chainlink-koers, en dat hooguit één keer per `interval` (≥ 1 uur) en alleen zolang de drift buiten de band ligt.

Het interessante detail: de spot-check begrenst de *pool* vóór de swap op 0,5% van de oracle, maar `minOut` staat los daarvan op oracle × (1 − `maxSlippageBps`). Een aanroeper die de pool atomair tot net binnen de 0,5% verschuift, `execute` aanroept en daarna terugdraait, incasseert dus (0,5% + eigen prijsimpact van de run) tot maximaal `maxSlippageBps`. Op Base is er geen publieke mempool, dus dit kan alleen wie de aanroeper zelf is, en dat mag iedereen zijn.

**Aanvalsscenario (getallen, fork-PoC `test_poc_executorSandwich`).** Buyer 20.000 EURC, cap 10% → run 2.000 EURC, `maxSlippageBps = 100`. De aanvaller verkoopt 7.138 EURC in de EURC/USDC-pool (spot +49 bps, check slaagt), roept `execute(buyer, atk)` aan, koopt de EURC terug. Resultaat: buyer ontvangt 2.969.711 sats tegenover 2.990.521 eerlijk (na fee) = verlies 69 bps ≈ 13,9 EURC; aanvaller houdt netto 4,72 EURC over (inclusief 0,05 beloning, na 2 × 0,05% poolfee over 7.138 EURC). Bij `maxSlippageBps = 30` zou deze run gewoon reverten ("Too little received"), dus de gebruiker bepaalt zelf zijn blootstelling.

**Bestaande testdekking.** `test_execute_revertsWhenSpotDeviatesFromOracle`, `test_fork_spotDeviationBlocksRun` en `test_execute_revertsOnSlippageBuy/Sell` dekken de grenzen afzonderlijk. Er is geen test die de bovengrens van het gecombineerde verlies (spot-push + slippage) vastlegt.

**Aanbevolen fix.** Geen contractwijziging nodig; wel: (1) laat de app standaard `maxSlippageBps = 30` (of 50) instellen en 100 alleen bewust; (2) documenteer in de README expliciet dat het maximale verlies per run `FEE_BPS + maxSlippageBps` is en dat de 0,5%-spot-check géén extra bovengrens is; (3) in een volgende versie kan `minOut` op `min(oracle, spot)` worden gebaseerd of `MAX_SPOT_DEVIATION_BPS` onder `MIN_SLIPPAGE_BPS` worden gelegd, zodat de spot-check ook echt de sandwich-ruimte begrenst.

---

## EX-04 — Low — Botsing CRE ↔ open keepers; verliezer betaalt een goedkope `NotDue`, maar het CRE-rapport wordt leeg verbruikt

**Regels:** `execute` 293 (`NotDue`), `onReport` 328–334 (geen herplanning na een `ReportSkipped`), `config.production.json` (`"0 0 * * * *"`).

**Beschrijving.** Twee wekkers die op dezelfde owner mikken: de tweede krijgt `NotDue`. Gemeten kost dat 2.615 gas bovenop de 21.000 basis, dus griefing via frontrunnen is economisch zinloos (Base heeft bovendien geen publieke mempool). Wel: als een keeper vlak vóór het hele uur de due owners afwerkt, bevat het CRE-rapport vijf owners die inmiddels `NotDue` zijn; de CRE-run is dan verspild en de owners die daardoor buiten het rapport vielen wachten een uur extra. Geen verlies van fondsen.

**Bestaande testdekking.** `test_execute_revertsNotDue` (contract), geen test voor een rapport met alleen al-uitgevoerde owners.

**Aanbevolen fix.** De rotatie uit EX-01 lost dit grotendeels op; daarnaast kan de workflow de `ReportSkipped`-events tellen en bij veel `NotDue` de volgende run een andere startoffset kiezen. Eventueel de CRE-cron niet op :00 laten lopen.

---

## EX-05 — Low — `TREASURY` op de Circle-blacklist = volledige stilstand van `execute` (onveranderbaar)

**Regels:** `_takeFee` 530 (`EURC.safeTransfer(TREASURY, fee - reward)`), `sweep` 341, constructor 172 (immutable, geen admin).

**Beschrijving.** Elke run met `fee > reward` (elke run vanaf ~20 EURC) stuurt EURC naar `TREASURY`. Wordt dat adres door Circle geblokkeerd (of raakt de sleutel kwijt), dan revert iedere `execute` en kan niemand dat repareren; gebruikers kunnen alleen hun allowance intrekken. Zelfde geldt voor `sweep`. Een geblacklist `rewardTo` treft alleen de aanroeper zelf (die kiest een ander adres).

**Bestaande testdekking.** `test_execute_revertsWhenOwnerBlacklisted` dekt de owner, niet de treasury.

**Aanbevolen fix.** Operationeel: treasury op een multisig zonder ander gebruik en vastgelegde noodprocedure (nieuwe deploy + migratie van de allowances). Contractueel in v2: fee-buffer in het contract met `pull`-patroon (`claimFees`), zodat een falende treasury-transfer een run niet blokkeert.

---

## EX-06 — Info — Beloning en fee: geen dubbele afroming, niet te farmen, maar wel onder de gaskosten bij kleine runs

**Regels:** `_takeFee` 524–531, `execute` 295 (`rewardTo == address(this)` → 0), `onReport` 330 (`rewardTo = TREASURY`).

**Vastgesteld veilig.**
- `reward = min(50_000, fee)` en de treasury krijgt `fee - reward`: de beloning komt uit de fee, niet erbovenop. `testFuzz_planBoundedAndAccountingClosed` bewijst `feePaid == fee` en `reward == min(50_000, fee)`.
- De beloning kan nooit groter zijn dan 25 bps van de run en nooit groter dan 0,05 EURC; volledige beloning vereist een run ≥ 20 EURC.
- Eigen accounts farmen is verliesgevend: je betaalt de fee zelf (bij runs < 20 EURC is fee = reward, netto 0 minus gas en 0,1% poolfee); herhaald `execute` is door `interval ≥ 1 h` en `NotDue` uitgesloten; bij `onReport` gaat de beloning naar de treasury, dus via de CRE valt niets te verdienen.
- `rewardTo = address(this)` wordt naar `address(0)` vertaald zodat er geen saldo blijft hangen (`test_execute_rewardToSelfGoesToTreasury`).

**Aandachtspunt.** `keeper.ts` filtert niet op omvang: bij een stof-owner (EX-01/02) is de beloning 0 en de gas ~250.000. Filter op `|eurcDelta|` of verwachte fee.

---

## EX-07 — Info — Cadans: uitvoerder kan niet te vroeg, niet vaker en kan de cadans alleen naar achteren schuiven

**Regels:** `execute` 293 en 303, `isDue` 237, `dueOwners` 263.

**Vastgesteld veilig.** `block.timestamp < lastExecutedAt + interval` → `NotDue`, dus te vroeg kan niet; `lastExecutedAt = block.timestamp` op het moment van uitvoering, dus een late uitvoering schuift de volgende venster met de vertraging op (geen inhalen, consistent met de app-semantiek). Een owner "permanent due houden" kan alleen doordat de drift buiten de band blijft (dan is het de gewenste corridorwerking, met per run maximaal `maxCorrectionBps` van het vermogen) of via een structureel revertende run (EX-02). `uint64(block.timestamp)` en `uint64 + uint32` kunnen niet overlopen. Sequencer-, versheid- en spot-checks zijn in `isDue`, `dueOwners` en `execute` identiek (`_tryQuote` → `quoteChecked`), dus de wekker en het contract kunnen niet uit elkaar lopen behalve door tijdsverloop tussen de view-call en de tx.

---

## EX-08 — Info — Reentrancy: gedekt op alle ingangen die waarde bewegen

**Regels:** `execute` 290 en `sweep` 339 (`nonReentrant`, OZ `ReentrancyGuardTransient`, gedeelde transient slot), `onReport` 330 (`this.execute{gas: …}`, externe self-call).

**Vastgesteld veilig.** `onReport` heeft zelf geen guard, maar roept `execute` extern aan, dat wél beschermd is; `onReport` doet verder geen externe call en is beperkt tot `FORWARDER` (`msg.sender`-check op regel 323), dus terugkeren via een token-hook kan niet. EURC (Circle FiatToken), cbBTC en USDC hebben geen transfer-hooks; `rewardTo` krijgt alleen een `safeTransfer` en kan niets terugroepen. `sweep` deelt de guard met `execute`, dus tijdens een run kan niemand het tijdelijke saldo wegvegen. Een revert binnen `try this.execute` draait ook de transient slot terug (onderdeel van de state), dus de guard blijft niet "aan" staan. Base draait Cancun (EIP-1153 beschikbaar; `foundry.toml` `evm_version = "cancun"`).

---

## EX-09 — Info — `setParams`/`sweep`/registratie: niemand kan andermans instellingen wijzigen; `sweep` raakt geen gebruikersfondsen, maar heeft twee kleine bijwerkingen

**Regels:** `setParams` 206–211 (`params[msg.sender]`), `sweep` 339–342, `_owners` 99.

**Vastgesteld veilig.** Alleen `msg.sender` kan zijn eigen `Params` zetten; er is geen `setParamsFor`, geen signature-pad en `onReport` kan geen params wijzigen. `sweep` stuurt uitsluitend naar `TREASURY`, het contract houdt buiten een tx nooit saldo (`invariant_contractNeverHoldsBalance`) en tijdens een tx blokkeert de guard. Het contract heeft geen enkele allowance van gebruikers *aan derden*; de `forceApprove` naar de router wordt door de router volledig verbruikt.

**Bijwerkingen (geen exploit).**
- `sweep(token)` roept willekeurige code aan met `msg.sender = Rebalancer`. Zo'n nep-token kan tijdens `balanceOf` `r.setParams(...)` aanroepen en het contract zelf als owner registreren (`execute(address(r))` eindigt in `NothingToDo`, saldo en allowance zijn 0). Alleen vervuiling van `_owners`, die toch al door iedereen te vervuilen is.
- Per ongeluk naar het contract gestuurde EURC/cbBTC van een gebruiker gaat naar de treasury, niet terug naar de gebruiker. Dat is beleid, maar leg het vast.
- Er is geen `unregister`: `_owners` groeit alleen. Inactieve owners kosten in `dueOwners` één SLOAD, actieve ~25k gas (twee `balanceOf`, twee `allowance`); met `PAGE_SIZE 50` blijft een pagina ver onder de RPC-limieten. Wel groeit het aantal view-calls per wekker-run lineair, zonder plafond (CRE heeft limieten op het aantal calls per run; bij duizenden nep-registraties valt de CRE-run stil; dit versterkt EX-01).

---

## Slither-bevindingen, beoordeeld

- `arbitrary-send-erc20` (High, regels 479 en 501): **by design, voldoende begrensd**, zie EX-03. Het bedrag is nooit groter dan `min(correctie, cap, saldo, allowance)`, de output gaat altijd naar de owner, de derde partij kiest alleen het moment; het maximale verlies per run is `FEE_BPS + maxSlippageBps`, per `interval` één keer. Noteer als "accepted risk" met verwijzing naar de mandaat-opzet.
- `incorrect-equality` (`total == 0`, `amountIn == 0`): vals-positief; dit zijn bewuste sentinels, geen vergelijking met externe berekende waarden.
- `unused-return` op `ROUTER.exactInput` in `_sell`: geen issue, de output wordt via `balanceOf`-delta gemeten (regel 507–516), wat robuuster is dan de returnwaarde.
- `reentrancy-events` in `onReport`: alleen een event na de self-call; geen state-afhankelijkheid.
- `timestamp`, `calls-loop`, `naming-convention`, `pragma`: geen risico's in deze context.
- Aderyn: alleen stijl (L-1 t/m L-4).

---

## Testgaten

1. **Economische ondergrens ontbreekt volledig**: geen test met `minTradeEurc = 1`/`maxCorrectionBps = 1` en klein saldo die laat zien dat zo'n owner elk uur due is met fee 0 (EX-01), noch een fork-test dat `amountIn = 1` op de echte route revert (EX-02).
2. **Meerdere due owners over meerdere runs**: alle `onReport`-tests hebben ≤ 5 owners in één tx. Geen test (contract of CRE `main.test.ts`) die vastlegt dat owner nummer 6+ ooit aan de beurt komt.
3. **Eeuwig-due na revert**: `test_execute_revertsWhenOwnerBlacklisted` en `test_execute_lastExecutedAtNotSetOnRevert` stoppen bij `lastExecutedAt == 0`; ze asserten niet dat `isDue`/`dueOwners` de owner blijven aanbieden, en er is geen keeper-test voor herhaald verlies.
4. **Bovengrens verlies per run**: geen fork-test die spot-push + slippage combineert en asserteert dat het verlies van de owner ≤ `FEE_BPS + maxSlippageBps` blijft (EX-03).
5. **Treasury-blacklist / falende treasury-transfer** (EX-05) is ongetest.
6. **Rapport met dubbele of al-uitgevoerde owners** (EX-04): geen test dat een duplicaat in `report` netjes `NotDue` geeft en de rest doorloopt.
7. **`sweep` met een kwaadaardig token** (EX-09): ongetest dat het niets anders kan dan `_owners` vervuilen.
8. **CRE-selectiegedrag**: `main.test.ts` test paginering en de cap, maar niet de volgorde-afhankelijkheid (wie valt af) en niet een filter op `eurcDelta`.
9. Foundry-gotcha voor toekomstige tijdreeks-tests: onder `via_ir` wordt `block.timestamp` binnen één testfunctie gecachet, waardoor `vm.warp(block.timestamp + …)` in een lus niet doorwerkt; gebruik `vm.getBlockTimestamp()`. (De huidige tests warpen hooguit één keer per test, dus dit raakt ze niet.)
