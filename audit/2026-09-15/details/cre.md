# Rebalancer — aanvalsvector `onReport` / Chainlink CRE-integratie

Scope: `src/Rebalancer.sol` (commit c2cf093, live op Base als 0xED47d549345b0dBB5A9b44E57Ff3AB4E6Ed0e6e5), `src/interfaces/IReceiver.sol`, `script/Deploy.s.sol`, `test/Rebalancer.t.sol`, `test/RebalancerFork.t.sol`, `cre/bitburo-keeper/*`, plus de KeystoneForwarder-bron van Chainlink en de on-chain toestand op Base (15 september 2026, blok 51.337.316).

Bronnen die ik voor de CRE-semantiek heb gebruikt (niet uit geheugen):

- Chainlink docs, *Building Consumer Contracts*: https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts
- Chainlink docs, *Forwarder Directory*: https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory-ts
- Chainlink docs, *EVM client SDK-referentie* (`WriteReportReply`): https://docs.chain.link/cre/reference/sdk/evm-client-ts
- KeystoneForwarder 1.0.0-bron: https://github.com/smartcontractkit/chainlink-evm/blob/develop/contracts/cre/src/v1/KeystoneForwarder.sol (lokaal gekopieerd naar `scratchpad/KeystoneForwarder.sol`)
- On-chain: `cast call` naar de forwarder (`typeAndVersion()` = "KeystoneForwarder 1.0.0", `isForwarder(self)` = true) en naar het live contract.

PoC-tests staan in `scratchpad/poc/test/CrePoC.t.sol` (mocks) en `scratchpad/poc/test/CreForkGas.t.sol` (Base-fork tegen het live contract). Alle PoC's slagen; niets in de repo is gewijzigd.

---

## Samenvatting

De toegangscontrole, metadata-decoding, ERC-165 en replay-bescherming zijn correct en sluiten aan op de forwarder-bron. Belangrijk kader: `onReport` geeft de forwarder **geen enkele bevoegdheid die een willekeurige aanroeper niet al via `execute` heeft**; het rapport is alleen een lijst adressen. Fondsen zijn via deze ingang dus niet te raken. Wat wél kwetsbaar is, is de *beschikbaarheid* van de CRE-wekker: het vaste gasbudget van 700.000 per owner is te krap voor grotere wallets (fork-meting: vanaf ~20.000 EURC per run gaat `execute` out-of-gas), en de combinatie van registratievolgorde + maximaal vijf owners per rapport laat een aanvaller voor bijna niets de vijf slots per uur bezetten. Beide zijn Medium; beide zijn te ondervangen zonder redeploy (workflow-kant), maar niet in het contract zelf.

| ID | Ernst | Titel |
|---|---|---|
| CRE-01 | Medium | `EXECUTE_GAS` (700k) is te krap voor grotere trades; zulke owners branden elk uur 700k CRE-gas en worden nooit bediend |
| CRE-02 | Medium | Slot-starvation: vijf goedkope "dust"-owners die vroeg registreren bezetten permanent alle CRE-slots |
| CRE-03 | Low | Workflow negeert `receiverContractExecutionStatus`; receiver-reverts blijven onzichtbaar. Er is nog geen enkele CRE-levering on-chain |
| CRE-04 | Low | `FORWARDER` en `WORKFLOW_OWNER` zijn immutable: forwarder-migratie of sleutelwissel maakt `onReport` dood; herstel = redeploy + alle gebruikers opnieuw approven |
| CRE-05 | Info | `workflowId`/`workflowName` worden niet gecontroleerd (bewust; acceptabel) |
| CRE-06 | Info | Replay: forwarder-dedup + contract-idempotentie; veilig |
| CRE-07 | Info | Metadata-offsets, ERC-165 en forwarder-adres kloppen met bron en docs; veilig |
| CRE-08 | Info | Gaslus, 63/64-regel, try/catch, returnbomb, lijstlengte; veilig |
| CRE-09 | Info | Deploy: geen admin/upgrade-pad; constructor-args geverifieerd; `WORKFLOW_OWNER`-sleutel niet verifieerbaar vanuit de repo |
| CRE-10 | Info | Slot-frontrun door een derde is onschadelijk |
| CRE-11 | Info | `cre workflow simulate` kan `onReport` van het live contract niet raken (MockForwarder) |

---

## CRE-01 — Medium — `EXECUTE_GAS` van 700.000 is te krap voor grotere trades

**Regelverwijzing:** `src/Rebalancer.sol:70-72` (constanten), `src/Rebalancer.sol:329-333` (lus), `README.md:25`.

**Beschrijving.** `onReport` geeft elke owner een hard plafond van `EXECUTE_GAS = 700_000`. De README baseert dat op één fork-meting (koop 404.653, verkoop 426.991) bij 1.000 EURC. Uniswap v3-gas groeit echter met het aantal gekruiste ticks, en de EURC/USDC-pool is dun (fork: 34.641 EURC / 26.845 USDC). Meting op de Base-fork tegen het **live** contract (`CreForkGas.t.sol`, `execute` met precies 700.000 gas, `maxCorrectionBps` = 10000):

| Run-bedrag (EURC) | Koop: gas | Verkoop: gas |
|---|---|---|
| 475 | 343.812 | 404.457 |
| 950 | 343.846 | 405.403 |
| 2.375 | 381.494 | 437.882 |
| 4.750 | 428.994 | 491.867 |
| 9.500 | 548.385 | 587.215 |
| 19.000 | **OOG** (683.182 verbruikt, lege reden) | **revert `TF`** (683.924 verbruikt) |

Bij ~10.000 EURC per run is de marge nog ~110k; bij ~19.000 EURC faalt `execute` binnen het budget, terwijl `isDue`/`dueOwners` voor dezelfde owner gewoon `true` teruggeven (die simuleren de swap niet). De owner wordt dus **elk uur** in het rapport opgenomen, verbruikt telkens het volle budget, en krijgt `ReportSkipped(owner, "")` — een lege reden, niet te onderscheiden van andere lege reverts.

**Aanvalsscenario / faalscenario.** Geen aanvaller nodig: een legitieme wallet met een grote correctie (bijvoorbeeld 25.000 EURC met `maxCorrectionBps` 10000, of 250.000 EURC met 1000) is via CRE structureel onbedienbaar en kost Bitburo elk uur ~700k gas op Base. Een kwaadwillende kan dit ook opzettelijk opzetten (vijf zulke wallets = 3,5M gas per uur uit de CRE-portemonnee en alle vijf slots, zie CRE-02); de kapitaalinzet blijft in eigen bezit want de run revert.

Merk op: de grens (~19k) hangt af van de liquiditeit/tick-dichtheid van het moment en kan ook bij kleinere bedragen optreden als de pool nog dunner wordt.

**Bestaande testdekking.** `test_onReport_executeGasBudgetIsPerOwner` (mock, kunstmatige burn) en `test_fork_onReportRunsBuyAndSellWithinGasBudget` (1.000 EURC / 0,02 cbBTC). Geen test met grotere bedragen; geen test die aantoont dat `isDue` true blijft terwijl `execute` binnen 700k faalt.

**Aanbevolen fix.**
1. Workflow-kant (geen redeploy): sluit owners uit met `|eurcDelta|` boven een configureerbare grens (bijvoorbeeld 8.000 EURC) door `isDue(owner)` te lezen voor de kandidaten uit `dueOwners`, en log ze apart. Laat het open keeper-script (`keeper/keeper.ts`, geen gascap) deze owners bedienen.
2. Voeg aan `ReportSkipped` een herkenbare reden toe voor out-of-gas (lege `reason` + `gasleft()` kan niet in de catch; alternatief: `if (reason.length == 0) emit ReportOutOfGas(owner)`), zodat monitoring dit onderscheidt. Vereist redeploy; alleen meenemen bij een volgende versie.
3. Bij een volgende versie: `EXECUTE_GAS` op ~1.000.000 en `EXECUTE_GAS_RESERVE` op ~1.050.000, met `maxOwnersPerReport` = 3 bij 4M, of `gasLimit` omhoog (README noemt een CRE-maximum van 5M; dat kon ik niet in de docs verifiëren).

**Bron.** Eigen fork-meting (hierboven); Chainlink docs *Building Consumer Contracts*: "Keep `onReport` gas-efficient; the workflow's `gasLimit` must cover the full execution" (via de lokale skill-kopie `.agents/skills/chainlink-cre-skill/references/evm-client.md:569`).

---

## CRE-02 — Medium — Slot-starvation via registratievolgorde en dust-parameters

**Regelverwijzing:** `src/Rebalancer.sol:197-212` (`setParams`: minimum `minTradeEurc` = 1 basiseenheid, `bandBps` ≥ 1, `maxCorrectionBps` ≥ 1, `interval` ≥ 1 uur), `src/Rebalancer.sol:248-275` (`dueOwners` in registratievolgorde), `cre/bitburo-keeper/main.ts:187-201` (eerste `maxOwnersPerReport` = 5 due owners), `cre/bitburo-keeper/config.production.json:10`.

**Beschrijving.** De workflow neemt altijd de eerste vijf due owners in de volgorde van `_owners` (registratievolgorde) en stopt dan. Wie vroeg registreert heeft blijvend voorrang. Iedereen kan gratis registreren, en de parametergrenzen staan een configuratie toe die *elk uur* due is en *nooit* uit de band raakt: `bandBps` = 1, `maxCorrectionBps` = 1, `minTradeEurc` = 1, `interval` = 1 uur. Bij 1.000 EURC en target 80% is de drift 80%, maar de correctie wordt afgekapt op 1 bps = 0,10 EURC; na de run is de drift nog steeds ~80%, dus de owner is het volgende uur weer due.

**PoC** (`CrePoC.t.sol::test_poc_starvationByRegistrationOrder`, slaagt): vijf "sybil"-adressen registreren met bovenstaande dust-params, daarna registreert `alice` met normale params. Drie opeenvolgende uren geeft `dueOwners(0,50)` zes owners terug; het rapport bevat de eerste vijf; alle vijf sybils worden bediend, `alice.lastExecutedAt` blijft 0. Kosten voor de aanvaller na 15 runs: 3.740 basiseenheden EURC (0,0037 EURC) aan fee; de CRE-gas (5 × ~250–470k per uur) betaalt Bitburo.

**Aanvalsscenario.** Een concurrent of grappenmaker registreert vijf wallets met 1.000 EURC elk (kapitaal blijft van hem) en dust-params. Vanaf dat moment wordt geen enkele later geregistreerde gebruiker nog door de CRE-wekker bediend; alleen het open keeper-script en handmatige `execute`-aanroepen werken nog. Gecombineerd met CRE-01 (wallets die binnen 700k falen) kost het bovendien 3,5M gas per uur. Ook zonder kwade opzet ontstaat starvation zodra meer dan vijf vroege owners een interval van 1 uur hebben en structureel due zijn.

**Bestaande testdekking.** `main.test.ts` "pages through dueOwners and caps the report at maxOwnersPerReport" toont de eerste-N-selectie, niet het gevolg. Geen contract- of workflowtest voor herhaalde selectie over meerdere uren.

**Aanbevolen fix (workflow-kant, geen redeploy).**
1. Roteer het startpunt per run: `offset0 = (uurnummer × maxOwnersPerReport) mod ownerCount` (of een hash van `workflowExecutionId`), en loop cyclisch door alle pagina's. Dan komt elke due owner gemiddeld binnen `ceil(due/5)` uur aan de beurt.
2. Filter economisch: lees `isDue(owner)` voor de kandidaten en sla owners over met `|eurcDelta|` onder bijvoorbeeld 5 EURC (fee 25 bps op 0,10 EURC is 250 basiseenheden; dat dekt geen gas). Dat sluit de dust-configuratie uit zonder contractwijziging.
3. Bij een volgende contractversie: verhoog het minimum van `minTradeEurc` (bijvoorbeeld 1 EURC) en/of `maxCorrectionBps` (bijvoorbeeld 10 bps), zodat een run altijd minstens de eigen gaskosten in fee oplevert.

---

## CRE-03 — Low — Workflow negeert `receiverContractExecutionStatus`; nog geen CRE-levering on-chain

**Regelverwijzing:** `cre/bitburo-keeper/main.ts:218-228`; forwarder `route()` (KeystoneForwarder.sol regels 156-166).

**Beschrijving.** De forwarder roept de receiver aan met een raw `call` en negeert het resultaat behalve als bool: `success := call(remainingGas, receiver, 0, …)`; alleen `s_transmissions[id].success` en `ReportProcessed(receiver, executionId, reportId, success)` leggen het vast. **De transactie zelf slaagt dus ook als `onReport` revert.** De SDK meldt dat apart: `WriteReportReply.receiverContractExecutionStatus` met `RECEIVER_CONTRACT_EXECUTION_STATUS_SUCCESS | REVERTED` (docs *EVM client*; type in `node_modules/@chainlink/cre-sdk/dist/generated/capabilities/blockchain/evm/v1alpha/client_pb.d.ts:1193,1269-1280`). De workflow controleert alleen `txStatus !== TxStatus.SUCCESS` en logt daarna "onReport verstuurd". Een `UnauthorizedWorkflowOwner`, een verkeerd gecodeerd rapport, of metadata korter dan 62 bytes (`_decodeMetadata` slicet zonder lengtecheck en revert dan de hele call — PoC `test_poc_metadataHandling`) blijft daardoor onopgemerkt: elk uur "succes" in de logs, nul uitvoeringen.

**On-chain toestand.** Sinds de deploy (blok 51.300.986) zijn er **0** `ReportProcessed`-events op de forwarder met `receiver` = Rebalancer (alle 2000-blok-vensters tot 51.337.400 doorzocht) en geen `ReportSkipped`-events op het contract. Het enige `Executed`-event (tx 0x8a0604d2…, blok 51.302.126) is verstuurd via de ERC-4337 EntryPoint (0x0000000071727De22E5E9d8BAf0edAc6f37da032), dus vanuit de app/keeper, niet via CRE. De keten forwarder → `onReport` is op mainnet nog nooit bewezen; of `WORKFLOW_OWNER` (0xdeb5…e7A7) gelijk is aan de sleutel waarmee de workflow is/wordt gedeployd, kon ik vanuit de repo niet vaststellen (`cre/.env` is voor mij afgeschermd).

**Aanvalsscenario.** Geen aanvaller; operationeel risico: een stille mismatch tussen `WORKFLOW_OWNER` en de CRE-account, of een rapport-encoding-wijziging, laat de wekker maandenlang "groen" zijn terwijl niets gebeurt.

**Bestaande testdekking.** Geen test in `main.test.ts` voor `receiverContractExecutionStatus === REVERTED`.

**Aanbevolen fix.** In `main.ts` na `writeReport`: `if (txResult.receiverContractExecutionStatus === ReceiverContractExecutionStatus.REVERTED) throw new Error(…)` (of minstens loggen + in `RunSummary` opnemen), test erbij. Eén end-to-end run op mainnet met één due owner uitvoeren en het `ReportProcessed(…, true)`-event vastleggen als bewijs. Monitoring op `ReportProcessed(receiver = Rebalancer, result = false)`.

**Bron.** https://docs.chain.link/cre/reference/sdk/evm-client-ts ("receiverContractExecutionStatus … RECEIVER_CONTRACT_EXECUTION_STATUS_SUCCESS or RECEIVER_CONTRACT_EXECUTION_STATUS_REVERTED"); KeystoneForwarder.sol `route()`.

---

## CRE-04 — Low — Immutable `FORWARDER`/`WORKFLOW_OWNER`: migratie of sleutelwissel maakt `onReport` dood

**Regelverwijzing:** `src/Rebalancer.sol:53-55, 173-174, 323-325`; `script/Deploy.s.sol:27-29` ("Bewust niet via env te overschrijven").

**Beschrijving.** Beide adressen zijn immutable en er is geen admin. Chainlinks eigen `ReceiverTemplate` maakt het forwarder-adres juist *wijzigbaar* ("The forwarder address is required at deployment, configurable after", met `setForwarderAddress()`), en de docs waarschuwen dat forwarder-adressen per omgeving verschillen. De KeystoneForwarder 1.0.0 heeft wel een router-mechanisme (`s_forwarders`, `addForwarder`) waardoor nieuwe Chainlink-entrypoints via `this.route` kunnen doorsturen met `msg.sender` = de bestaande forwarder — dat vangt een deel van toekomstige migraties op. Maar zodra de DON naar een nieuw forwarder-contract gaat, of de CRE-account (de `WORKFLOW_OWNER`-sleutel) wisselt of verloren gaat, revert `onReport` permanent.

**Gevolg.** Herstel is alleen mogelijk met een nieuw contract op een nieuw adres: elke gebruiker moet opnieuw `approve` (EURC én cbBTC) en `setParams` doen; `lastExecutedAt` en de owner-lijst gaan verloren; de app moet het adres omzetten. Tot die tijd blijft alleen het permissionless pad (`execute` via keeper-script/Laravel) over — dat werkt wel, dus dit is geen fondsen- of stilstandrisico, maar een migratiekostenrisico.

**Bestaande testdekking.** `test_onReport_revertsUnauthorizedForwarder`, `test_onReport_revertsUnauthorizedWorkflowOwner`. Geen documentatie/runbook voor een migratie.

**Aanbevolen fix.** Twee opties, ter keuze aan Arjan:
- (a) Accepteren (past bij "geen admin") en het runbook vastleggen: keeper-script als primaire fallback, migratiestappen, en een monitor op de forwarder-versie (`typeAndVersion()`) en op Chainlinks *Forwarder Directory*.
- (b) Bij een volgende versie een minimaal, tijdgebonden pad: een `FORWARDER_UPDATER`-adres dat alleen het forwarder-adres mag wijzigen (geen andere macht), eventueel met een 7-daagse timelock. Dat tast de "nooit wat of hoeveel"-garantie niet aan, omdat `onReport` niets kan wat `execute` niet kan.

**Bron.** https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts (ReceiverTemplate, `setForwarderAddress`); https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory-ts ("Forwarder contracts differ between local simulation and production").

---

## CRE-05 — Info — `workflowId` en `workflowName` worden niet gecontroleerd

**Regelverwijzing:** `src/Rebalancer.sol:324-325, 536-544`.

Alleen `workflowOwner` wordt vergeleken. Elke workflow van dezelfde eigenaar (ook `bitburo-keeper-staging`, of een nieuwe versie met andere CID) mag rapporteren — PoC `test_poc_metadataHandling` bevestigt dat een andere `workflowId` doorgaat. De docs noemen workflowId-validatie "highest security" en workflowName alleen in combinatie met author-validatie (bytes10-truncatie). Omdat de workflowId de content-hash van de workflow is en bij elke deploy wijzigt, zou hard-coden in een immutable contract onwerkbaar zijn. Het gevolg van een gecompromitteerde eigenaarssleutel is beperkt tot: rapporten indienen die niets meer kunnen dan `execute` (CRE-gas verbruiken). **Veilig bevonden**, bewust ontwerp.

---

## CRE-06 — Info — Replay

**Regelverwijzing:** KeystoneForwarder.sol regels 138-166 (`route`), 170-175 (`getTransmissionId`); `src/Rebalancer.sol:290-303`.

De forwarder dedupt op `keccak256(receiver ‖ workflowExecutionId ‖ reportId)`: na een succesvolle levering revert een herhaling met `AlreadyAttempted`. Een mislukte levering (receiver revert) mag opnieuw met meer gas ("If this function call reverts, it can be retried with a higher gas limit", docs IReceiver). Omdat `onReport` per owner try/catch doet en dus normaal nooit revert, wordt het rapport bij de eerste levering als succes gemarkeerd. Zelfs als een rapport tóch tweemaal wordt afgeleverd, is het contract idempotent: `lastExecutedAt` + `interval` geeft `NotDue` (PoC `test_poc_replayIsIdempotent`). De cron-timestamp-methode uit de docs is hier niet nodig omdat het rapport geen data bevat die "verouderd" kan zijn — het is een lijst adressen die het contract zelf opnieuw beoordeelt. `report()` op de forwarder is permissionless (iedereen kan een getekend rapport eerder indienen); dat is hier onschadelijk. **Veilig bevonden.**

---

## CRE-07 — Info — Metadata-offsets, ERC-165 en forwarder-adres

**Regelverwijzing:** `src/Rebalancer.sol:344-346, 536-544`; `src/interfaces/IReceiver.sol`; `script/Deploy.s.sol:29`.

- Forwarder-bron `_getMetadata` en `report()`: metadata die de receiver krijgt is `rawReport[45:109]` = `workflow_cid` (32) ‖ `workflow_name` (10) ‖ `workflow_owner` (20) ‖ `report_id` (2) = 64 bytes. Het contract leest `[0:32]`, `[32:42]`, `[42:62]` — **correct**, identiek aan `ReceiverTemplate._decodeMetadata` uit de docs.
- `type(IReceiver).interfaceId` = `0x805f2132` (alleen `onReport`, IERC165-overerving telt niet mee), gelijk aan wat de forwarder via `ERC165Checker.supportsInterface(receiver, type(IReceiver).interfaceId)` met 30k gas opvraagt; `supportsInterface` is `pure` en goedkoop. On-chain gecontroleerd: `supportsInterface(0x805f2132)` = true.
- `FORWARDER` = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482 = productie-KeystoneForwarder voor `ethereum-mainnet-base-1` in de Forwarder Directory; on-chain `typeAndVersion()` = "KeystoneForwarder 1.0.0", contractcode aanwezig.
- Zelfde adres als op Base Sepolia/Ethereum Sepolia (deterministische deploy); de README van de workflow noemt correct het aparte MockForwarder-adres 0x5e34…548 voor simulatie.

**Veilig bevonden.**

---

## CRE-08 — Info — Gaslus, 63/64-regel, try/catch, returnbomb, lijstlengte

**Regelverwijzing:** `src/Rebalancer.sol:327-334`.

- 63/64: de lus breekt bij `gasleft() < 750_000`; bij ≥ 750k krijgt `this.execute{gas: 700_000}` altijd het volle bedrag (63/64 × 750k ≈ 738k > 700k). PoC `test_poc_fiveFullBudgetOwnersFit`: vijf owners passen met 3,7M gas ook als elke run ~700k nadert (2,24M verbruikt bij 5 × ~447k). De forwarder geeft `gasleft() − 5.000` door na eigen overhead (~30k + ERC-165 ≤ 90k + handtekeningen), dus van de 4M `gasLimit` blijft ruim 3,55M over — voldoende voor 750k + 4 × 700k in het slechtste geval.
- OOG/revert in één owner: gevangen door `try/catch`, `lastExecutedAt` niet gezet, rest van de lijst gaat door (bestaande tests). De hele call revert alleen bij ongeldige metadata/rapport — dan is de afzender per definitie de forwarder met een misvormd rapport.
- Kwaadaardige owner: alle code die binnen `execute` draait is vast (EURC, cbBTC, SwapRouter02, feeds, pools); `rewardTo` is `TREASURY`; een owner kan geen hook of returnbomb injecteren. `catch (bytes memory reason)` kopieert alleen revert-data van die vaste contracten (Uniswap-strings, custom errors). De enige "wapens" van een owner zijn balans/allowance/params — zie CRE-01/02.
- Lijstlengte: onbegrensd in het contract, maar door de reserve-check gas-begrensd; de workflow capt op 5.

**Veilig bevonden** (de economische varianten staan onder CRE-01/02).

---

## CRE-09 — Info — Deploy-script en post-deploy-macht

**Regelverwijzing:** `script/Deploy.s.sol`, `broadcast/Deploy.s.sol/8453/run-latest.json`, `src/Rebalancer.sol:150-178`.

- Geen `Ownable`, geen proxy, geen selfdestruct, geen setters behalve `setParams` (alleen voor `msg.sender` zelf). Na deploy kan niemand iets aan het contract wijzigen; `sweep` stuurt alleen achtergebleven saldo naar de vaste treasury.
- Constructor-args in de broadcast komen overeen met de live immutables: `FORWARDER()` = 0xF834…4482, `WORKFLOW_OWNER()` = 0xdeb5…e7A7 (EOA, geen code), `TREASURY()` = 0xD6a4…98a9. Alle adressen in het script zijn de bekende Base-adressen; `_requireContract` en `_poolOrder` vangen verkeerde adressen af (getest).
- Bytecode: de lokale build (via-IR, runs 1000) heeft exact dezelfde lengte als de on-chain code (24.856 hex-tekens); 678 afwijkende bytes zijn te verklaren door immutables en metadata-hash, maar dat is geen sluitend bewijs. Basescan-verificatie kon ik zonder API-sleutel niet opvragen — graag handmatig bevestigen dat het contract geverifieerd is.
- Of 0xdeb5…e7A7 daadwerkelijk de CRE-workflow-eigenaar is: niet verifieerbaar vanuit de repo (zie CRE-03).

---

## CRE-10 — Info — Slot-frontrun door een derde

PoC `test_poc_frontrunSlot`: iemand die vlak vóór het rapport zelf `execute(owner, hem)` aanroept, krijgt de 0,05 EURC-beloning; het rapport slaat de owner over met `NotDue`. Dat is precies het beoogde permissionless ontwerp; het kost Bitburo hooguit één slot en de beloning. **Onschadelijk.**

---

## CRE-11 — Info — Simulatie raakt het live contract niet

`cre workflow simulate` gebruikt de MockForwarder (0x5e34…548, docs Forwarder Directory); het live contract accepteert alleen 0xF834…4482 en revert met `UnauthorizedForwarder`. De simulatie test dus de lees-kant (`dueOwners`) en de rapport-encoding, niet de levering. Dat is inherent aan het immutable ontwerp; het onderstreept CRE-03 (één echte end-to-end run als bewijs).

---

## Testgaten

1. **Gas per trade-omvang op de fork**: geen test boven 1.000 EURC; toevoegen: parametrische fork-test die `execute{gas: EXECUTE_GAS}` bij 2,5k/5k/10k/20k EURC meet en vastlegt tot welk bedrag het budget volstaat (CRE-01).
2. **`isDue` true terwijl `execute` binnen `EXECUTE_GAS` faalt**: geen test die de divergentie tussen de view en de uitvoering laat zien, noch dat zo'n owner elk uur opnieuw in `dueOwners` staat (CRE-01).
3. **Meervoudige-uren-selectie in de workflow**: `main.test.ts` test één run; geen test die aantoont dat dezelfde vijf owners elk uur opnieuw worden gekozen en een zesde nooit (CRE-02).
4. **`receiverContractExecutionStatus === REVERTED`** in `main.test.ts` (CRE-03).
5. **Metadata korter dan 62 bytes** en **rapport dat niet als `address[]` decodeert**: geen contracttest dat de hele call dan revert (gedrag is acceptabel, maar hoort vastgelegd).
6. **Replay via `onReport`**: `NotDue` is alleen via `execute` getest, niet als tweede levering van hetzelfde rapport (CRE-06; PoC beschikbaar).
7. **Vijf owners op vol budget binnen de werkelijke forwarder-marge**: geen test met 3,5–3,7M gas en vijf owners die elk ~650k verbruiken (PoC beschikbaar).
8. **End-to-end op mainnet**: geen enkel `ReportProcessed`-event voor dit contract; de CRE-keten is nog niet bewezen (CRE-03).
9. **Fuzz op `_decodeMetadata`-offsets** tegen de forwarder-layout (bijvoorbeeld door de echte `rawReport[45:109]`-slice na te bouwen) ontbreekt; nu alleen een handgeschreven 64-byte fixture.
