# Rebalancer – adversariële review: oracle- en prijsmanipulatie

Scope: `src/Rebalancer.sol` (545 regels), `src/interfaces/*.sol`, `README.md`, `test/Rebalancer.t.sol`, `test/RebalancerFork.t.sol`, `script/Deploy.s.sol`. Live-adres op Base: `0xED47d549345b0dBB5A9b44E57Ff3AB4E6Ed0e6e5` (cre/bitburo-keeper/config.production.json:4). Fork-PoC's: `scratchpad/poc-oracle/test/OracleSandwich.t.sol` (Base mainnet, blok ~51.337.000, 15 september 2026). Repo is niet gewijzigd.

On-chain gecontroleerde feiten (cast tegen https://mainnet.base.org, 15-09-2026):

| Item | Waarde |
|---|---|
| cbBTC/USD `0x07DA…9f9D` | "cbBTC / USD", 8 dec, owner `0xf0Db…5B1b`, aggregator AccessControlledOCR2Aggregator; rondes elke ~1.230 s; referentiedirectory: heartbeat 1200 s, drempel 0,3 % |
| EURC/USD `0xDAe3…8250` (gebruikt door het contract) | "EURC / USD", 8 dec, zelfde owner, phaseId 2; rondes elke 86.418–86.422 s (24 h); prijssprongen tussen rondes tot 0,35 % zonder tussentijdse update; **komt niet voor** in Chainlinks referentiedirectory `feeds-ethereum-mainnet-base-1.json` |
| EURC/USD `0x9867…01e0` (niet gebruikt) | "EURC / USD", 8 dec, zelfde owner, DualAggregator; rondes elke 3.602 s; referentiedirectory: heartbeat 3600 s, drempel 0,1 % |
| Sequencer `0xBCF8…6433` | answer 0, startedAt 1782491507 (80 dagen up) |
| min/maxAnswer van beide prijs-aggregators | 1 / 9,58e52 → geen circuit-breaker-kap |
| Pool EURC/USDC `0x7279…66fB` | token0 EURC, token1 USDC, liquidity 3,85e12, saldo 34.738 EURC + 26.734 USDC |
| Pool USDC/cbBTC `0xfBB6…43ef` | token0 USDC, token1 cbBTC, fee 500, saldo 3,85 M USDC + 50,8 cbBTC |
| Oracle vs. spot op het fork-blok | 66.710,78 vs. 66.674,34 EURC/cbBTC (5,5 bps) |

---

## Bevindingen

### ORC-1 · Medium · Permissionless executor kan een run atomair zelf-sandwichen; winstgevend vanaf ~2.500 EURC per run

**Regels:** `src/Rebalancer.sol:290` (`execute` permissionless), `:362-367` (`_quoteChecked`, tolerantie 50 bps), `:371-383` (`_spot`/`_spotOut` lezen `slot0`), `:483-484` en `:503-504` (`minOut` = oracle × (1 − maxSlippageBps)), `:66` (`MAX_SLIPPAGE_BPS = 100`).

**Beschrijving.** De spot-check leest de momentane `slot0`-prijs van beide pools. Die prijs is binnen één transactie vrij te verschuiven; alleen de afstand tot de oracle (≤ 0,5 %) is begrensd. Omdat `execute` door iedereen aangeroepen mag worden en `nonReentrant` alleen geneste aanroepen blokkeert, kan een aanvaller in één transactie (1) de dunne EURC/USDC-pool tot net binnen 50 bps verschuiven, (2) `execute(owner, aanvaller)` aanroepen en (3) de verschuiving terugdraaien. Het slachtoffer swapt dan tegen een prijs die 0,5 % + eigen prijsimpact slechter is dan de oracle; de swap slaagt zolang dat binnen `maxSlippageBps` (30–100 bps) blijft. De verliesgrens per run is dus min(spot-tolerantie + impact, `maxSlippageBps`) ten opzichte van de oracle, één keer per `interval` per owner. De NatSpec (regels 30-37) en README (regel 23) erkennen dit als ontwerpkeuze; de fork-PoC laat zien dat het niet alleen theoretisch is.

**Aanvalsscenario met getallen (fork-PoC `test_poc_sweep` / `test_poc_sweepSell`, slachtoffer `maxSlippageBps = 100`, `maxCorrectionBps = 10000`).** Maximale push binnen 50 bps: 7.135 EURC verkopen in de EURC/USDC-pool (koop-richting) of 7.815 USDC (verkoop-richting).

| Run (koop, EURC) | Push (EURC) | Verlies slachtoffer | Winst aanvaller (EURC, na poolfees) |
|---|---|---|---|
| 1.000 | 7.135 | 5,70 EURC (0,57 %) | **−1,38** (niet winstgevend) |
| 2.500 | 7.135 | 14,96 EURC (0,60 %) | **+7,91** |
| 5.000 | 7.135 | 33,83 EURC (0,68 %) | **+26,87** |
| 10.000 | 2.854 | 29,56 EURC (0,30 %) | **+27,01** (grotere push: revert op `minOut`) |

| Run (verkoop, EURC-waarde) | Push (USDC) | Verlies slachtoffer | Winst aanvaller (USDC) |
|---|---|---|---|
| 1.000 | 7.815 | 4,50 EURC | −2,54 |
| 2.500 | 7.815 | 11,63 EURC | +5,71 |
| 5.000 | 7.815 | 24,53 EURC | +20,70 |

Bij `maxSlippageBps = 30` faalt de run van 10.000 EURC al zonder manipulatie op "Too little received" (eigen impact 0,44 %); de aanvaller kan dan hooguit DoS'en (zie ORC-4). Het break-even punt ligt rond 2.000–2.500 EURC per run; daarboven verdient de aanvaller structureel 0,3–0,55 % van het runbedrag, elke interval opnieuw, zonder dat het slachtoffer iets merkt behalve een iets lagere `amountOut`.

**Bestaande testdekking.** `test_execute_revertsWhenSpotDeviatesFromOracle` (Rebalancer.t.sol:614) en `test_fork_spotDeviationBlocksRun` (RebalancerFork.t.sol:70) bewijzen dat > 50 bps revert; `test_execute_revertsOnSlippageBuy/Sell` (:681/:692) dat `minOut` werkt. Geen enkele test modelleert een aanvaller die de pool binnen de tolerantie verschuift en terugdraait in dezelfde transactie; de mock-router rekent tegen een vaste koers zonder prijsimpact, dus een sandwich is met de unit-mocks niet eens uit te drukken.

**Aanbevolen fix.**
1. Vervang (of vul aan) de `slot0`-check door een TWAP via `pool.observe()` (bijv. 5–10 minuten, zoals Uniswaps `OracleLibrary.consult`): een TWAP is niet atomair te verschuiven, waardoor de aanvaller kapitaal blootgesteld moet laten staan tegen arbitrage.
2. Voeg een post-swap-check toe: lees `slot0` opnieuw ná de swap en revert als de afwijking van de oracle > `MAX_SPOT_DEVIATION_BPS`. Front-run + eigen impact moeten dan samen binnen 0,5 % blijven, wat de winstruimte van de sandwich grotendeels sluit.
3. Verlaag `MAX_SLIPPAGE_BPS` en/of laat `minOut` uitgaan van max(oracle, TWAP); overweeg `MAX_SPOT_DEVIATION_BPS` te koppelen aan `maxSlippageBps − 2 × POOL_FEE`.
4. Tot dan: documenteer in de app dat een lage `maxCorrectionBps`/hoge `minTradeEurc` grote runs voorkomt, en kies 30–50 bps als standaard-`maxSlippageBps`.

---

### ORC-2 · Medium · EURC/USD-feed is een 24-uurs feed die niet meer in Chainlinks referentiedirectory staat; contract is onveranderbaar

**Regels:** `script/Deploy.s.sol:22` en `test/RebalancerFork.t.sol:17` (`FEED_EURC_USD = 0xDAe398…8250`), `src/Rebalancer.sol:49` (immutable), `:78` (`MAX_AGE_EURC = 86_400 + 3600`), `:385-393` (`_readFeed`).

**Beschrijving.** Het contract leest EURC/USD van proxy `0xDAe3…8250`. On-chain: rondes exact elke 86.418–86.422 s (24 h-heartbeat), prijsbewegingen tot 0,35 % tussen rondes zonder tussentijdse update (dus deviatiedrempel ≥ 0,35 %, de zoekresultaten van data.chain.link noemen 0,3 % voor de "RefPrice"-feed). Chainlinks referentiedirectory voor Base (`feeds-ethereum-mainnet-base-1.json`) bevat dit adres niet; wél `0x9867…01e0` ("EURC / USD", DualAggregator, heartbeat 3600 s, drempel 0,1 %), met on-chain rondes elke 3.602 s. Beide proxies hebben dezelfde Chainlink-owner (`0xf0Db…5B1b`), dus `0xDAe3` is authentiek en draait nog, maar het is een oudere, tragere feed die uit de publieke lijst is verdwenen. Gevolgen:

- **Deprecatierisico.** Stopt Chainlink deze feed (niet gelistet = klassieke voorbode), dan geeft `_readFeed` na 25 h permanent `StaleFeed`, `isDue`/`dueOwners` geven altijd (false, 0), en elke `execute` revert. Er is geen admin of upgrade (NatSpec regel 26): het hele contract is dan dood en alle gebruikers moeten opnieuw approven op een nieuw adres.
- **Krappe marge.** 90.000 − 86.420 = 3.580 s. Loopt Chainlinks 24-uursronde één uur uit (komt voor), dan valt de hele dienst stil tot de volgende ronde.
- **Lag-ruimte voor ORC-1/ORC-3.** Een oracle die tot 0,3 % (EURC) + 0,3 % (cbBTC) achter de markt kan lopen, vergroot de afstand tussen de "eerlijke" prijs en het `minOut`-anker.

**Aanvalsscenario/getallen.** Geen aanvaller nodig: bij een feed-stop op dag D is het contract vanaf D+25 h onbruikbaar. Bij een gewone uitloop van 1 h is de dienst 0–23 h stil.

**Bestaande testdekking.** `test_execute_revertsStaleFeedEurc` (Rebalancer.t.sol:551) test de grens 90.000 s met mocks. Geen fork-test controleert de werkelijke leeftijd/cadans van de feed of dat het adres in Chainlinks lijst staat.

**Aanbevolen fix.** Bij een herdeploy `0x9867186e52d2F1C2c565CDA6E747101Fa56501e0` gebruiken (1 h heartbeat, 0,1 % drempel) met `MAX_AGE_EURC = 3600 + marge`; in de constructor `feed.decimals() == 8` afdwingen (zie ORC-5); een fork-test toevoegen die `updatedAt` van beide feeds < heartbeat + marge asserteert en de adressen tegen de referentiedirectory legt. Zolang het huidige contract live is: monitor `updatedAt` van `0xDAe3` extern (CRE/keeper) en bereid een migratiepad voor.

---

### ORC-3 · Low · Spot-tolerantie (0,5 %) is kleiner dan de opgetelde feed-deviatiedrempels (0,3 % + ≥ 0,3 %): periodieke false-positive reverts

**Regels:** `src/Rebalancer.sol:68` (`MAX_SPOT_DEVIATION_BPS = 50`), `:362-367`, `:77-78`.

**Beschrijving.** Beide feeds mogen per Chainlink-parameters tot 0,3 % (cbBTC) resp. ≥ 0,3 % (EURC, 24 h) van de markt afwijken vóór ze updaten. De poolspot volgt de markt vrijwel direct (arbitrage). In de ongunstige combinatie (BTC +0,29 % sinds laatste update, EUR/USD −0,29 % sinds gisteren) ligt de spot 0,58 % van de oracle en revert elke `execute` met `SpotDeviatesFromOracle`, terwijl niets mis is. Omdat `lastExecutedAt` niet wordt gezet (regel 303 komt pas na `_quoteChecked`), wordt het volgende uur opnieuw geprobeerd; de schade is beperkt tot uitstel, maar bij een trending markt kan dat uren duren en juist dán wil de gebruiker herbalanceren. De README meet 4 bps op één rustig moment; dat zegt niets over volatiele periodes.

**Bestaande testdekking.** Geen: de mocks zetten feed en spot altijd samen (`_setPrice`, Rebalancer.t.sol:82); de fork-test meet alleen één momentopname (`test_fork_spotMatchesOracle`).

**Aanbevolen fix.** Tolerantie afleiden van de feedparameters (≥ som van de drempels + poolfees, bijv. 75–100 bps) in combinatie met een TWAP (ORC-1), of de EURC-feed vervangen door de 0,1 %-variant (ORC-2), waarna 50 bps wél past (0,3 % + 0,1 % + 0,1 % fees).

---

### ORC-4 · Low · DoS van `isDue`/`dueOwners`/`execute` door de spot > 0,5 % te verschuiven kost ~8.000 EURC aan kapitaal en alleen poolfees

**Regels:** `src/Rebalancer.sol:240-243` en `:253-256` (`_tryQuote` → leeg resultaat), `:297` (`execute` revert), `:371-373`.

**Beschrijving.** De EURC/USDC-pool bevat ~35 k EURC + 27 k USDC. Fork-PoC `test_poc_dosBySpotPush`: 8.138 EURC verkopen zet de spot > 50 bps; daarna geeft `isDue` false, `dueOwners` leeg en revert `execute`. Kosten aanvaller: 0,05 % poolfee heen en terug (~8 EURC) plus het tijdelijke koersrisico; blijft de push staan, dan arbitreert de markt het weg. De aanvaller kan dit elk uur vlak vóór de CRE-cron herhalen (cron-tijd is publiek, `dueOwners` ook), zodat de dienst structureel stil ligt tegen een paar euro per uur. Gebruikers verliezen geen geld, maar de kernbelofte (automatisch herbalanceren) faalt.

**Bestaande testdekking.** `test_fork_spotDeviationBlocksRun` (fork:70) test de revert via een gemockte feed, niet via een echte pool-push; kosten voor een aanvaller worden nergens gemeten.

**Aanbevolen fix.** TWAP i.p.v. `slot0` (een aanvaller moet dan minutenlang blootgesteld blijven), en/of bij `SpotDeviatesFromOracle` in `onReport` een `ReportSkipped` monitoren en alarmeren.

---

### ORC-5 · Low · Geen controle op `decimals()` van de feeds in de constructor

**Regels:** `src/Rebalancer.sol:48-49` (commentaar "8 decimalen"), `:150-178` (constructor), `:357` (`price = cbbtcUsd * 1e6 / eurcUsd`).

**Beschrijving.** De omrekening klopt alleen als beide feeds dezelfde decimalen hebben (de factor valt dan weg). Beide zijn on-chain 8, dus nu correct. Bij een herdeploy met een andere feed (bijv. een 18-dec-feed of een EUR/USD-feed) zou de koers een factor 10^k fout zijn; de spot-check zou dat afvangen als permanente DoS, niet als verlies. `IAggregatorV3.decimals()` staat al in de interface (IAggregatorV3.sol:6) maar wordt nergens aangeroepen.

**Bestaande testdekking.** Geen test met afwijkende feed-decimalen.

**Aanbevolen fix.** In de constructor: `if (FEED_CBBTC_USD.decimals() != 8 || FEED_EURC_USD.decimals() != 8) revert InvalidParams();` plus een unit-test.

---

### ORC-6 · Info · Sequencer-feed: `startedAt == 0` (ongeïnitialiseerde ronde) wordt niet afgevangen

**Regels:** `src/Rebalancer.sol:352-353`.

**Beschrijving.** `block.timestamp - seqStartedAt < GRACE_PERIOD` is onwaar bij `startedAt == 0`, dus een ongeïnitialiseerde ronde (`answer 0, startedAt 0`) telt als "up". Chainlink documenteert dit randgeval voor L2-uptimefeeds. Op Base staat de feed al 80 dagen op `startedAt = 1782491507`; praktisch niet uitbuitbaar, maar de check `if (seqStartedAt == 0) revert SequencerDown();` is gratis.

**Bestaande testdekking.** `test_execute_revertsSequencerDownAnswerOne/WithinGrace` (Rebalancer.t.sol:512/519); geen test voor `startedAt == 0`.

---

### ORC-7 · Info · EURC-depeg: het contract verkoopt cbBTC in een depeggende EURC

**Regels:** `src/Rebalancer.sol:355-357`, `:434-437` (positie in EURC gewaardeerd).

**Beschrijving.** De EURC/USD-feed volgt de marktprijs van EURC zelf (assetSubClass "Stablecoin"), niet EUR fiat. Daalt EURC naar bijv. 0,90 USD terwijl BTC stabiel is, dan stijgt `price` (EURC per cbBTC) met ~11 %, stijgt de cbBTC-fractie boven doel + band en verkoopt de volgende run cbBTC voor gedepegde EURC. Oracle en poolspot bewegen mee (de EURC/USDC-pool prijst de depeg in), dus de spot-check grijpt niet in. Dit is geen bug maar een ontwerpkeuze (EURC als numeraire) die de gebruiker in het slechtste geval van hard asset naar een falende stablecoin schuift. Bij een depeg van > 0,3 % update de feed direct op deviatie (geen 24 h-lag), maar tussen update en de tick van de keeper zit maximaal één interval.

**Bestaande testdekking.** Geen depeg-scenario in de tests.

**Aanbevolen fix (optioneel).** Een "EURC-gezondheidsband": revert als `eurcUsd` meer dan X % afwijkt van een EUR/USD-feed (op Base beschikbaar), of van de vorige waarde. Minimaal: documenteren voor gebruikers.

---

## Beoordeling statische analyse (alleen mijn vector)

| Tool / detector | Regel | Oordeel |
|---|---|---|
| Slither `unused-return` op `pool.slot0()` (:380), `SEQUENCER_FEED.latestRoundData()` (:352), `feed.latestRoundData()` (:386) | — | **False positive**: bewuste destructuring; `roundId`/`answeredInRound` zijn sinds OCR2 niet meer betekenisvol, `tick` e.d. niet nodig. |
| Slither `timestamp` op `_quote`, `_readFeed`, `isDue`, `execute`, `dueOwners` | — | **False positive**: staleness- en intervalchecks vereisen `block.timestamp`; seconden-manipulatie door de sequencer is irrelevant op deze schaal. |
| Slither `unused-return` op `ROUTER.exactInput` in `_sell` (:508); Aderyn L-4 | — | **True maar onschadelijk**: het contract meet het echt ontvangen bedrag via balansverschil (:507-516), wat robuuster is dan de returnwaarde. |
| Slither `incorrect-equality` (`total == 0`, `amountIn == 0`) | — | Buiten mijn vector; exacte 0-checks op integers zijn hier correct. |
| Slither/Aderyn overige (naming, literal, redundant statement) | — | Geen relatie met oracle/prijs. |

Geen van beide tools signaleert de kernproblemen (slot0-manipuleerbaarheid, feedkeuze/heartbeat, tolerantie vs. deviatiedrempels); die vragen handmatige review.

---

## Onderzocht en veilig bevonden

- **Staleness/heartbeat cbBTC/USD:** `MAX_AGE_CBBTC = 1500` (:77) vs. waargenomen cadans ~1.230 s en gedocumenteerde heartbeat 1.200 s: marge 300 s, oké. Toekomstige `updatedAt` en `updatedAt == 0` geven `StaleFeed` (:389), geen Panic.
- **answer ≤ 0:** afgevangen in `_readFeed` (:387); `price == 0` na omrekening afgevangen (:358, `test_execute_revertsWhenQuoteRoundsToZero`).
- **Round-completeness (`answeredInRound < roundId`):** niet gecheckt, maar voor OCR2-feeds niet meer nodig (Chainlink heeft dit gedeprecieerd); `updatedAt`-check dekt het.
- **min/maxAnswer-kap:** beide aggregators hebben minAnswer 1 en maxAnswer 9,58e52, dus geen LUNA-achtige vastgeplakte prijs; en zelfs dán zou de spot-check reverten in plaats van tegen een fictieve koers te handelen.
- **Sequencer-grace:** `answer != 0 || now − startedAt < 1 h` (:353) is het Chainlink-referentiepatroon; getest op beide grenzen (:512-527).
- **Decimalen/precisie omrekening:** `mulDiv(cbbtcUsd(8), 1e6, eurcUsd(8))` → EURC-basiseenheden per cbBTC; afrondfout < 1e-6 EURC; 512-bit tussenresultaat, geen overflow.
- **`_spotOut`-rekenwerk:** `ratioX96 = sqrtPriceX96²/2^96` past in 224 bit; met `mulDiv` geen overflow voor elke `uint160`. Met de echte pools (ratio ≈ 1,15 resp. ≈ 7,7e-4) ruim voldoende precisie; fork-test bevestigt 5,5 bps afstand tot de oracle. Deling door nul alleen als `sqrtPriceX96 < 2^48` (pool bij MIN_TICK, praktisch onmogelijk); en dan revert `execute` en geeft `isDue` (false, 0) via de try/catch (:395-401), dus geen ander gedrag dan een deviatie.
- **Token-volgorde in de pools:** `_poolOrder` (:186-192) leidt token0/token1 af en revert bij verkeerde tokens; `_spot` zet de richting per pool correct (:372-373); getest met omgekeerde volgorde (`test_spot_pairsWithReversedTokenOrder`).
- **Beide hops gecheckt:** `_spot` vermenigvuldigt de spot van de USDC/cbBTC-pool met die van de EURC/USDC-pool (:372-373), dus manipulatie van elk van beide pools raakt de check. Unit-tests dekken de cbBTC-pool (>50 bps → revert) en de EURC-pool (0,4 % → slaagt); de fork-PoC bevestigt de EURC-pool bij > 50 bps.
- **Slippage-anker:** `minOut` wordt van de **oracle** afgeleid (:483-484, :503-504), niet van de manipuleerbare spot. Dat is de juiste keuze en de reden dat ORC-1 begrensd is tot `maxSlippageBps`.
- **Positie-waardering:** `_plan` gebruikt uitsluitend de oracle-koers (:436, :467); de te verhandelen hoeveelheid is dus niet via de pool te beïnvloeden.
- **Oracle-lag op zichzelf:** een oracle die 0,3 % achter de markt loopt kost de gebruiker niets zolang de swap tegen marktprijs plaatsvindt; alleen de manipulatieruimte (ORC-1/ORC-3) verschuift mee.
- **Derde-partij-sandwich op Base:** de sequencer is FCFS zonder publieke mempool; het realistische pad is de executor zelf (ORC-1), niet een mempool-sniper.

## Testgaten (oracle/prijs-vector)

1. [x] Fork-test met atomaire zelf-sandwich (front-run → `execute` → back-run) die asserteert dat de aanvaller géén positieve PnL kan halen (faalt nu, zie ORC-1).
   → Gedekt: fork `test_poc_selfSandwich_10k_slippage100` (aanval faalt, PnL ≤ 0, slachtoffer ongemoeid) en `test_poc_executorSandwich`.
2. [x] Post-swap-deviatie: test dat de spot ná de swap binnen de tolerantie ligt (bestaat niet omdat de check niet bestaat).
   → Gedekt: fork `test_fork_postSwapSpotWithinTolerance` en unit `test_execute_revertsWhenSpotDeviatesAfterSwap`.
3. [x] Fork-test die de werkelijke leeftijd en cadans van beide feeds toetst aan `MAX_AGE_*` (en `updatedAt` niet ouder dan heartbeat + marge), plus een check dat de feedadressen in Chainlinks referentiedirectory voorkomen.
   → Gedekt: fork `test_fork_feedsAreFreshAndMatchConstants` (leeftijd, decimals, description) en `test_fork_feedCadenceWithinMaxAge` (gaten tussen de laatste 24 rondes ≤ `MAX_AGE_*`). De referentiedirectory van Chainlink is off-chain en niet vanuit Forge te raadplegen.
4. [x] Unit-test die alleen de EURC/USDC-pool > 50 bps verschuift (nu alleen 0,4 %-pass; de fail-kant loopt via de cbBTC-pool).
   → Gedekt: `test_execute_revertsWhenOnlyEurcPoolDeviates`.
5. [x] Scenario waarin feed en spot los van elkaar bewegen (feed lagt 0,3 %, spot ±0,3 %) om ORC-3 zichtbaar te maken; de mocks koppelen ze nu altijd (`_setPrice`).
   → Gedekt: `test_execute_feedAndSpotDivergeIndependently`.
6. [x] Sequencer `startedAt == 0`.
   → Gedekt: `test_execute_revertsSequencerDownWhenStartedAtZero`.
7. [x] Feed met afwijkende `decimals()` (constructor moet reverten na fix ORC-5).
   → Gedekt: `test_constructor_rejectsFeedWithWrongDecimals`.
8. [x] EURC-depeg-scenario (feed 0,90, pool volgt) met assertie over de richting van de run.
   → Gedekt: `test_isDue_eurcDepegTurnsHoldIntoSell`.
9. [x] `_spotOut` bij extreme `sqrtPriceX96` (MIN/MAX_SQRT_RATIO): geen Panic naar buiten via `isDue`/`dueOwners`.
   → Gedekt: `test_spot_extremeSqrtPriceNeverPanicsInViews`.
10. [x] Invariant-handler heeft geen actie die alleen de pools verschuift (los van `feedBtc`), dus de spot-check wordt in de invariant-suite nooit geraakt.
   → Gedekt: handler-actie `shiftSpot` in `RebalancerHandler`, geteld in `invariant_executeFailsOnlyForKnownReasons`.
