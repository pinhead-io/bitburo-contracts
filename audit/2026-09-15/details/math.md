# Rebalancer — adversariële review van de rekenkunde (_plan, _buy, _sell, fee, beloning)

Scope: `/Users/arjan/Code/bitburo-contracts/src/Rebalancer.sol` (Solidity 0.8.28, OZ 5.6.1, via-IR), interfaces, mocks, `test/Rebalancer.t.sol`, README. Geen wijziging in de repo; alle PoC's staan in het scratchpad (zie onderaan).

Notatie: EURC = 6 decimalen, cbBTC = 8 decimalen ("sat"), Chainlink = 8 decimalen, `price` = EURC-basiseenheden per 1 cbBTC (L350-359).

---

## M-01 — Kleine wallets (of cap == minTrade) kunnen nooit verkopen door afronding van `wantBtc`

- **Ernst:** Medium (deterministische functionele uitval voor een hele klasse gebruikers; geen verlies van geld)
- **Regels:** `src/Rebalancer.sol:454-458` (cap-vloer op minTrade), `:467` (`wantBtc = mulDiv(correctionEurc, CBBTC_UNIT, price)` — floor), `:469` (`mulDiv(amountIn, price, CBBTC_UNIT) < p.minTradeEurc → amountIn = 0`)
- **Beschrijving:** Als `total * maxCorrectionBps / BPS < minTradeEurc` wordt `cap = minTradeEurc` (L455) en dus `correctionEurc == minTradeEurc` zodra de drift groot genoeg is (L456). Bij verkoop wordt dat bedrag naar beneden afgerond naar sats (L467); de teruggerekende waarde (L469) is daardoor tot bijna 1 sat (~800 EURC-units bij 80k) kleiner dan `minTradeEurc`, en `amountIn` wordt 0. Alleen als `minTradeEurc * 1e8` exact deelbaar is door `price` slaagt de check. Met een echte feedkoers (6 decimalen, bv. 80.123,456789) gebeurt dat praktisch nooit. De koopkant heeft dit probleem niet (`amountIn = correctionEurc` exact, L464). Het effect is asymmetrisch: kleine wallets kunnen wél bijkopen, nooit afbouwen.
  Zelfde artefact bij grotere wallets zodra `cap - minTradeEurc < 1 sat aan waarde`.
- **Scenario:** app-defaults `minTrade = 5 EURC`, `maxCorrection = 10 %`, target 80/20. Wallet: 0 EURC + 50.000 sats (≈ 40,06 EURC) bij koers 80.123,456789. `total = 40,06e6`, `cap = max(4,006e6, 5e6) = 5e6`, drift·total = 8,01e6 → `correction = 5e6`. `wantBtc = 5e6·1e8 / 80.123.456.789 = 6240,37 → 6240`. Waarde = `6240 · 80.123.456.789 / 1e8 = 4.999.703 < 5.000.000` → `amountIn = 0` → `NothingToDo`, `isDue = false`. Alle wallets met `total < minTrade / maxCorrection` (hier: < 50 EURC) zitten permanent vast aan de verkoopkant.
- **Bestaande testdekking:** geen. Alle sell-tests gebruiken `PRICE = 80_000e6` (deelt exact: 5e6·1e8/80000e6 = 6250) of `VECTOR_PRICE = 100e6`; `testFuzz_planBoundedAndAccountingClosed` fuzzt de koers niet. De invariant-handler fuzzt wel de koers maar asserteert niets over due-heid.
- **PoC:** `test_poc_smallWalletCannotSell`, `testFuzz_poc_sellBlockedWhenCapEqualsMinTrade` (3000 runs: due ⇔ exact deelbaar).
- **Fix:** rond `wantBtc` naar boven af: `Math.mulDiv(correctionEurc, CBBTC_UNIT, price, Math.Rounding.Ceil)`. Dat is veilig: `amountIn` blijft begrensd op `btcBal` en allowance (L468) en de waarde overschrijdt `correctionEurc` met hooguit 1 sat. Alternatief: de minTrade-check op L469 uitvoeren op `correctionEurc` (al ≥ minTrade op L457) en alleen bij allowance-/saldo-clamping herberekenen.

## M-02 — Blacklisting van TREASURY door Circle zet het contract permanent op slot

- **Ernst:** Medium (lage kans, hoge impact; contract is immutable, er is geen uitweg behalve redeploy + nieuwe mandaten van alle gebruikers)
- **Regels:** `src/Rebalancer.sol:530` (`EURC.safeTransfer(TREASURY, fee - reward)`), `:51` (`TREASURY` immutable), `:339-342` (`sweep` naar TREASURY)
- **Beschrijving:** EURC is een Circle FiatToken met blacklist. Iedere run met `fee - reward > 0` (d.w.z. `fee > 0,05 EURC` ⇔ EURC-been > 200 EURC, of `rewardTo == address(0)`, wat `onReport` effectief doet omdat het `TREASURY` als rewardTo meegeeft en de rest óók naar TREASURY gaat) doet een transfer naar TREASURY. Is TREASURY geblacklist, dan revert elke zulke run, en ook `sweep(EURC)`. Alleen microruns (≤ 200 EURC) met een niet-geblacklist `rewardTo` blijven werken. Er is geen admin om TREASURY te wisselen.
- **Scenario:** TREASURY komt op de blacklist. Alice (1.000 EURC, buy 100 EURC, fee 0,25) → `execute` revert met "Blacklistable: account is blacklisted"; CRE-rapporten emitten alleen `ReportSkipped`; `isDue` blijft `true` (de plan-fase kijkt niet naar de blacklist), dus de wekkers proberen het elk uur opnieuw.
- **Bestaande testdekking:** `test_execute_revertsWhenOwnerBlacklisted` (owner), niet de treasury.
- **PoC:** `test_poc_blacklistedTreasuryBricksExecute`.
- **Fix (ontwerpkeuze):** (a) fee-transfer in `try` en bij falen de fee bij het contract laten (sweep-baar) of terug naar owner, zodat de rebalance zelf nooit stukloopt op de fee-ontvanger; of (b) treasury-adres als een door de treasury zelf roteerbaar (1-op-1, `msg.sender == TREASURY`) adres. Optie (a) houdt "geen admin" intact.

## L-01 — Geen ondergrens op `minTradeEurc`: microruns met fee 0, `amountOutMinimum` 0 en kopen die 0 sats opleveren

- **Ernst:** Low (alleen door de owner zelf te configureren; wel keeper-griefing en verlies van dust)
- **Regels:** `src/Rebalancer.sol:199-200` (`p.minTradeEurc == 0` is de enige eis), `:483-484` (`expectedOut = mulDiv(swapIn, 1e8, price)` → 0 bij `swapIn < price/1e8`; `minOut = 0`), `:525` (`fee = 0` voor `eurcAmount < 400`), `:303` (cadans schuift toch op)
- **Beschrijving:** `setParams` accepteert `minTradeEurc = 1` (0,000001 EURC). Dan: (1) koop-runs met `swapIn < 1 sat aan waarde` (< ~0,0008 EURC bij 80k) hebben `expectedOut = 0`, dus `amountOutMinimum = 0`: de owner betaalt EURC aan de pool en krijgt 0 cbBTC; de fractie blijft 0 en de volgende run is weer due → een lus die de wallet tot dust leegtrekt. (2) `fee = 0` onder 400 units → keeper doet ~400k gas voor 0 beloning. (3) `minOut` wordt door de floor grover naarmate `expectedOut` klein is (bij 10 sats verwacht is de effectieve slippage-tolerantie 10 %, niet 1 %): de sandwich-bescherming verwatert voor runs onder ongeveer 0,1 EURC.
- **Scenario:** cash 2.067 units, target 6 %, minTrade 1, cap 50 %: 20 opeenvolgende runs, elk `amountIn ≥ 1`, `amountOut = 0`, saldo van 2.067 → 605 units, 0 sats ontvangen (fuzz-tegenvoorbeeld uit `testFuzz_audit_noPingPongConstantPrice` met `minTrade = 1`). Tweede voorbeeld: cash 5.866, target 10 %: één run betaalt 586 units, ontvangt 0.
- **Bestaande testdekking:** `test_setParams_boundaryValuesAccepted` bevestigt juist dat `minTradeEurc = 1` geaccepteerd wordt; `testFuzz_planBoundedAndAccountingClosed` fuzzt `minTrade` vanaf 1 maar asserteert niet dat `amountOut > 0`.
- **PoC:** `test_poc_dustBuyLoopNeverConverges`, `test_poc_microBuyYieldsZeroOutput`, `test_poc_microRunZeroFeeZeroMinOut`.
- **Fix:** ondergrens in `setParams`, bv. `MIN_TRADE_EURC = 1e6` (1 EURC): dan is `fee ≥ 2.500` (> 0), `expectedOut ≥ ~1.250 sats` en de floor-fout in `minOut` < 1 bp. Extra vangnet: `if (amountOut == 0) revert` in `_buy`.

## L-02 — `MIN_SLIPPAGE_BPS` (30) < `MAX_SPOT_DEVIATION_BPS` (50) + poolfees (10): runs kunnen structureel onuitvoerbaar zijn

- **Ernst:** Low (liveness; geen verlies)
- **Regels:** `src/Rebalancer.sol:66-68`, `:366` (spot mag 0,5 % afwijken), `:484`/`:504` (`minOut = expected · (1 − maxSlippageBps)` t.o.v. de **oracle**-koers), `:63` (2 × 0,05 % poolfee)
- **Beschrijving:** `amountOutMinimum` wordt afgeleid van de Chainlink-koers, maar de swap gebeurt op de pool-spot. De spot mag 0,5 % ongunstig afwijken, de twee hops kosten 0,1 %, plus prijsimpact. Met `maxSlippageBps = 30` is de haalbare uitkomst dan tot 0,6 %+ onder de oracle, terwijl `minOut` maar 0,3 % toelaat: de spot-check laat de run door, de router revert met "Too little received", `lastExecutedAt` blijft staan, en de wekker probeert het elk uur opnieuw (gas voor niets). Pas bij `maxSlippageBps ≥ 60 + prijsimpact` is een run in elke toegestane markttoestand haalbaar.
- **Scenario:** oracle 80.000, spot 80.400 (+0,5 %, toegestaan), gebruiker `maxSlippageBps = 30`: koop 100 EURC → `minOut = 99,75e6·1e8/80.000e6 · 0,997 = 124.313 sats`; pool levert `99,75e6 / 80.400e6 · 0,999 · 1e8 ≈ 123.940` → revert.
- **Bestaande testdekking:** `test_execute_revertsOnSlippageBuy/Sell` (router-slippage > maxSlippage), maar niet de combinatie "spot binnen de grens + poolfees > maxSlippage".
- **PoC:** `test_poc_minSlippageBelowSpotDeviationPlusPoolFees`.
- **Fix:** `MIN_SLIPPAGE_BPS` op ≥ `MAX_SPOT_DEVIATION_BPS + 2·POOL_FEE/100` (= 60) zetten, of `minOut` van de gecontroleerde **spot** afleiden in plaats van de oracle. Documenteer in ieder geval in README/app dat 30 bps in de praktijk vaak revert.

## I-01 — Overshoot door fee+slippage is klein, in dezelfde richting en convergerend: geen ping-pong

- **Ernst:** Info (veilig bevonden, met kanttekening)
- **Regels:** `src/Rebalancer.sol:447-456`, `:479-481`, `:516-520`
- **Analyse:** zij `c` = correctie (EURC, oracle-termen), `f` = totaal verlies op het run-bedrag (fee 0,25 % + slippage ≤ 1 % ⇒ `f ≤ 1,25 %`), `T` = target.
  - Verkoop: positie daalt exact met `c` (want `wantBtc = c/price`), cash stijgt met `c(1−f)`. Nieuwe fractie = `T·total / (total − c·f)` **> T** → volgende run is opnieuw een verkoop.
  - Koop: positie stijgt met `c(1−f)`, cash daalt met `c`. Nieuwe fractie = `(T·total − c·f)/(total − c·f)` **< T** → volgende run is opnieuw een koop.
  De richting keert dus nooit om; de restdrift is `≤ f · c / total` en krimpt per run geometrisch. Bij 80/20, cap 10 %, `f = 1,25 %` is de restdrift ≤ 0,125 pt, ver binnen band 5 pt. Met een klein `bandBps` (< ~20 bps) én een klein `minTradeEurc` volgen wél extra staart-runs in dezelfde richting, elk met fee (voorbeeld: 1.000 EURC volledig in cbBTC, band 1 bps, minTrade 1: run 1 verkoopt 200 EURC, fractie daarna 0,8020; run 2 verkoopt nog 1,996 EURC; run 3 niets). Dat is een configuratie-effect, geen exploit.
- **Bewijs:** `testFuzz_audit_corridorFeeResidue` (3001 runs: restdrift ≤ `(25 + maxSlip) bps · amountIn / total'`, en de eerstvolgende `isDue` heeft altijd dezelfde richting) en `testFuzz_audit_noPingPongConstantPrice` (3001 runs, tot 60 opeenvolgende runs: richting keert nooit om, reeks eindigt). PoC `test_poc_sellOvershootTailRuns`.
- **Aanbeveling:** ondergrens op `bandBps` (bv. ≥ 25 + MAX_SLIPPAGE_BPS = 125) of de app laat geen band < ~1 % toe; dan is elke volledige correctie in één run klaar.

## I-02 — De cap is per run, niet per dag

- **Ernst:** Info (documentatie/verwachting)
- **Regels:** `src/Rebalancer.sol:454` (`cap = total · maxCorrectionBps`), `:75` (`MIN_INTERVAL = 1 hours`), `:293`
- **Beschrijving:** De briefing spreekt van een "dagcap 10 %". Het contract kent alleen een cap per `execute` en een interval ≥ 1 uur. Met `interval = 1 hours` en `maxCorrectionBps = 1000` kan een wallet 24 × 10 % per dag verplaatsen. Dat is correct volgens de NatSpec (L23 "per run") maar wijkt af van de app-terminologie.
- **PoC:** `test_poc_capIsPerRunNotPerDay` (5 runs in 5 uur: > 40 % verplaatst).
- **Fix:** geen contractwijziging nodig; laat de app `interval = 1 days` afdwingen als "dagcap" bedoeld is, of noem het "cap per run".

## I-03 — Slither-meldingen: alle vijf false positives

- `incorrect-equality` `total == 0` (L438): `total` is een som van twee ERC-20-saldi (geen berekende afgeleide met afrondingsruis); de gelijkheid is de exacte semantiek "wallet leeg" en beschermt de deling op L442. FP.
- `incorrect-equality` `amountIn == 0` (L279 en L300): `amountIn` is een sentinel die de code zelf expliciet op 0 zet (L465, L469, L439, L450, L458); er wordt niet vergeleken met een berekende waarde. FP.
- `uninitialized-local` `n` (L259): Solidity initialiseert lokale waardetypen op 0; `n` wordt alleen verhoogd. FP.
- `unused-return` `ROUTER.exactInput` (L508): bewust genegeerd; `_sell` meet het resultaat via `balanceOf`-verschil (L507, L516), wat robuuster is dan de router-return (klopt ook als de router minder rapporteert dan hij levert). FP. Kanttekening: als er tokens naar het contract worden gedoneerd vóór de run, zit dat in `eurcBefore` en wordt het niet meegerekend (correct); `sweep` ruimt het op. Getest in `testFuzz_audit_corridorFeeResidue` (donatie blijft exact staan).

## I-04 — Feed-decimalen worden niet gecontroleerd (maar vallen tegen elkaar weg)

- **Ernst:** Info
- **Regels:** `src/Rebalancer.sol:357` (`price = mulDiv(cbbtcUsd, 1e6, eurcUsd)`), `:48-49`
- **Beschrijving:** De formule deelt twee feeds op elkaar, dus de decimalen vallen weg zolang **beide** feeds dezelfde decimalen hebben (op Base: 8 en 8). De constructor controleert dat niet, hoewel `IAggregatorV3.decimals()` beschikbaar is. Een deploy met bv. een 18-dec EURC/USD-feed zou stil een koers 1e10 keer te klein geven. Immutable, dus alleen een deploy-risico.
- **Fix:** in de constructor `if (FEED_CBBTC_USD.decimals() != FEED_EURC_USD.decimals()) revert InvalidParams();`.

## I-05 — Fee-basis is asymmetrisch maar in beide gevallen exact 25 bps van het EURC-been

- **Ernst:** Info (veilig bevonden; documenteren)
- **Regels:** `src/Rebalancer.sol:480` (koop: fee over bruto `amountIn`, vóór de swap), `:518` (verkoop: fee over netto `received`, ná slippage), `:524-531`
- **Beschrijving:** Koop: `fee = amountIn · 25 / 10.000`, `swapIn = amountIn − fee` (de user betaalt 100 EURC, 99,75 gaat de pool in). Verkoop: `fee = received · 25 / 10.000` (over wat de pool werkelijk leverde, dus slippage verlaagt de fee). Beide zijn "25 bps van de EURC-waarde die door het contract stroomt"; er wordt nooit fee geheven over de hele portefeuille, en nooit zonder swap (de swap-revert maakt de hele run atomair ongedaan; `lastExecutedAt` wordt dan ook niet gezet, `test_execute_lastExecutedAtNotSetOnRevert`). `reward = min(0,05 EURC, fee)`, `treasury = fee − reward`; som is exact `fee`, betaald door de owner; nooit meer dan 25 bps. Afronding via `mulDiv` (floor) is in het voordeel van de user.
- **Bewijs:** `testFuzz_audit_corridorFeeResidue` (fee == `mulDiv(basis, 25, 10.000)`, reward == `min(50.000, fee)`, koers 20k–200k, router-slippage 0–maxSlip).

## I-06 — Owner kan een deel van de eigen fee terugpakken via `rewardTo`

- **Ernst:** Info
- **Regels:** `src/Rebalancer.sol:290`, `:526-528`
- **Beschrijving:** `execute(owner, owner)` geeft de owner `min(0,05 EURC, fee)` van zijn eigen fee terug; effectieve fee voor zelf-uitvoerende owners is `fee − 0,05`. Bounded en bekend ontwerp (permissionless). Geen actie nodig; vermelden in de fee-documentatie.

## I-07 — Allowance-clamping en cadans: deel-run schuift het interval volledig op

- **Ernst:** Info (ontwerp, gedocumenteerd op L423-425, maar met gevolg voor de wekkers)
- **Regels:** `src/Rebalancer.sol:464`, `:468`, `:303`
- **Beschrijving:** Bij `allowance < correctie` (maar ≥ minTrade) wordt alleen `allowance` verhandeld, de fee wordt over dat kleinere bedrag berekend (correct), en `lastExecutedAt` gaat naar `now`: de rest wacht een vol interval. `isDue` rapporteert intussen de **volledige** correctie (`eurcDelta`), niet het bedrag dat `execute` daadwerkelijk zal doen; een keeper die op `eurcDelta` een beloningsverwachting baseert, ziet een afwijking. Alle overige rekenstappen (minTrade-check op het geclampte bedrag, L465/L469) zijn consistent tussen `isDue` en `execute`, dus geen valse due-signalen.
- **Bestaande testdekking:** `test_execute_boundedByAllowance`, `test_isDue_deltaIsCorrectionBeforeAllowanceBound`, `test_execute_allowanceBelowMinTradeIsNothingToDo`.
- **PoC:** `test_poc_partialRunAdvancesCadence`.
- **Aanbeveling:** ofwel `isDue` het geclampte `amountIn` (in EURC) laten teruggeven, ofwel documenteren dat `eurcDelta` de ongeclampte wens is.

## I-08 — Cosmetisch

- `src/Rebalancer.sol:315` `correctionEurc;` is een no-op-statement (Aderyn meldt het ook); vervang door een naamloze return-slot (`(bool isBuy, uint256 amountIn,, uint256 total, uint256 fractionBps)`).
- `src/Rebalancer.sol:461-462`: de opmerking "correction ≤ |drift|·total ≤ saldo" klopt (ook mét de cap-vloer, want `correction = min(drift·total, cap) ≤ drift·total`); de saldo-clamp is inderdaad alleen defensief.

---

## Veilig bevonden (met bewijs)

| Onderwerp | Regels | Oordeel |
|---|---|---|
| Omrekening Chainlink → EURC/cbBTC | L357 | `cbbtcUsd(8) · 1e6 / eurcUsd(8)` → EURC-units per cbBTC; decimalen vallen weg (zie I-04). Verlies ≤ 1 unit per BTC. |
| Positiewaarde | L436 | `mulDiv(btcBal, price, 1e8)` in één 512-bit stap, floor. Geen deling-vóór-vermenigvuldiging. |
| Fractie/drift/correctie | L442-453 | WAD-rekenkunde met `mulDiv`; `targetWad`/`bandWad` exact (1e18 deelbaar door 1e4). Verlies < 1 EURC-unit op `correctionEurc`. `fractionBps` alleen voor het event. |
| Corridor-triggering binnen één tick | L293, L303 | Per owner maximaal één run per `interval`; `lastExecutedAt` vóór de swap gezet, atomair teruggedraaid bij revert. Prijsbeweging kan binnen een interval geen tweede run uitlokken. |
| `isDue`/`dueOwners` ≡ `execute` | L277-284, L298-300 | Beide gebruiken `_plan` en `_quoteChecked`; geen valse due-signalen (bevestigd in fuzz). |
| Overflow | L366, L381-382, L443-445 | `diff·BPS`, `sqrtP²/2^96` (< 2^224), `fractionWad·BPS` passen ruim in uint256. |
| Fee-som en betaler | L524-531 | `reward + treasury == fee`, `fee ≤ 25 bps`, altijd uit het EURC-been van de owner. Nul-transfers worden overgeslagen. |
| Restanten | L487-494, L507-520 | Koop: router-recipient = owner. Verkoop: recipient = contract, alles (`received − fee`) door naar owner. `forceApprove` wordt volledig verbruikt (fuzz: router-allowance na run == 0). Gedoneerde tokens blijven onaangeroerd en zijn sweep-baar. |
| Uniswap-pad | L489, L510 | `exactInput`, 2 hops via USDC op 0,05 %; SwapRouter02 heeft geen `deadline` (staleness wordt afgedekt door de feed-`MAX_AGE` en de spot-check). `amountOutMinimum` van oracle × (1 − maxSlippage), floor (zie L-01/L-02 voor de randen). |
| Reentrancy | L290, L339 | `ReentrancyGuardTransient` op `execute` en `sweep`; `onReport` roept `this.execute` extern aan (eigen guard-scope). EURC/cbBTC hebben geen hooks. |
| Dust/oscillatie | L457, L465, L469 | Onder `minTradeEurc` wordt niets gedaan en de cadans niet opgeschoven; geen oneindige oscillatie bij realistische `minTrade` (≥ 0,1 EURC). Uitzonderingen: M-01 (sell-vloer) en L-01 (microruns). |

## Testgaten in de bestaande suite

1. Geen enkele sell-test met een niet-rond koersgetal (`PRICE = 80_000e6`, `VECTOR_PRICE = 100e6` delen `minTrade` exact) → M-01 onzichtbaar. Voeg een fuzz op `price` toe aan `testFuzz_planBoundedAndAccountingClosed` en assert `due == (correction ≥ minTrade)`.
2. Geen test voor een geblacklist TREASURY of `rewardTo` (M-02).
3. Geen assertie `amountOut > 0` / `minOut > 0` bij kleine runs; `minTrade` wordt gefuzzt vanaf 1 zonder die controle (L-01).
4. Geen test voor "spot binnen 0,5 % + poolfees > maxSlippage" (L-02).
5. Geen test die na een run de nieuwe fractie t.o.v. band/target controleert of de richting van de volgende run (overshoot/ping-pong, I-01).
6. Geen test voor `decimals()`-mismatch van de feeds (I-04).
7. De invariant-handler laat `execute` reverten zonder te registreren waarom; een ghost-teller per revert-reden (NothingToDo vs "Too little received") zou L-02-achtige liveness-uitval zichtbaar maken.

## Fuzz-/invariant-uitkomst

- Testbestand: `/private/tmp/claude-501/-Users-arjan-Code-bitburo/b70b479c-bb69-42d9-8159-4abc1a801885/scratchpad/repo/test/AuditMath.t.sol` (kopie: `.../scratchpad/AuditMath.t.sol`); run-log: `.../scratchpad/audit-math-run.txt`.
- Commando: `RUN_FORK=false FOUNDRY_FUZZ_RUNS=3000 ~/.foundry/bin/forge test --match-contract AuditMathTest -vv` in de scratchpad-kopie van de repo.
- Resultaat: **12/12 geslaagd**.
  - `testFuzz_audit_corridorFeeResidue` (3001 runs; koers 20k–200k, alle params, allowances, router-slippage 0–maxSlip, donatie aan het contract): (a) na een niet-begrensde run is de restdrift ≤ `(25 + maxSlippage) bps · amountIn / total'` en, als de band dat toelaat, binnen de band; begrensde runs zitten op cap/allowance; de eerstvolgende `isDue` heeft nooit de omgekeerde richting; (b) `fee == mulDiv(EURC-been, 25, 10.000)` exact en `reward == min(50.000, fee)`; (c) het contract houdt na `execute` exact de vooraf gedoneerde hoeveelheid EURC (0 zonder donatie), 0 cbBTC en 0 router-allowance.
  - `testFuzz_audit_noPingPongConstantPrice` (3001 runs, tot 60 opeenvolgende runs bij constante koers, `minTrade ≥ 0,1 EURC`): richting keert nooit om, reeks eindigt.
  - `testFuzz_poc_sellBlockedWhenCapEqualsMinTrade` (3000 runs): verkoop is alleen due als `minTrade·1e8 % price == 0` (M-01).
  - Tegenvoorbeelden die tijdens het fuzzen boven kwamen en nu als PoC vastliggen: `test_poc_microBuyYieldsZeroOutput` (cash 5.866, target 10 %, minTrade 6 → betaalt 586, ontvangt 0) en `test_poc_dustBuyLoopNeverConverges` (20 runs, 2.067 → 605 units, 0 sats).
- Bestaande suite in dezelfde kopie (zonder fork): 76 unit/fuzz + 3 invariants geslaagd; de nieuwe tests wijzigen niets aan de repo.
- Let op bij eigen reproductie: via-IR cachet `block.timestamp` binnen een testfunctie; gebruik `vm.getBlockTimestamp()` in lussen (anders een valse `NotDue`).
