# AI-audit Rebalancer — 2026-09-17

Zelf-audit van `development` na de merge van PR #18. Dit rapport bouwt voort op `audit/2026-09-16/ai-audit.md` en op het externe auditpakket `audit/2026-09-17/` (`SCOPE.md`, `FINDINGS-STATUS.md`). Het pakket blijft ongewijzigd; deze zelf-audit staat daarom in een eigen map.

**ID's.** Eerdere ID's worden hergebruikt zoals `FINDINGS-STATUS.md` ze noemt, met de bron ervoor (bijvoorbeeld `09-16/lead 5`, `final-review/F-4`, `PR18-review/I-4`). Nieuw in dit rapport:
- **L-D, L-E, L-F:** Low. Ze gaan verder waar de L-A tot en met L-C van 16 september ophielden.
- **Info-G, Info-H:** informatief.
- **Leads 11 tot en met 18:** ze gaan verder waar de leads 1 tot en met 10 van 16 september ophielden.

Aderyn nummert zijn eigen meldingen H-1 en L-1 tot en met L-4 (`aderyn.md`). Die vallen niet samen met deze ID's.

## Samenvatting

- **Geen bevinding van Medium of hoger.** De blokcheck, het blokvenster en de Chainlink-validatie houden stand. Negen AI-reviewers, de QuillShield oracle-checklist, 211 tests en 14 diepe invariants vonden er geen gat in.
- **Drie nieuwe Low-bevindingen, geen daarvan met verlies voor gebruikers bij de huidige instellingen van Uniswap:**
  - **L-D (raakt het verdienmodel):** een run op de vloer van 20 EURC levert de treasury niets op. Een owner die zelf `execute` aanroept met `rewardTo` = zichzelf, handelt dan zonder fee. Met `maxCorrectionBps` 10 is elke run van een wallet tot 20.000 EURC zo'n vloerrun. Bewezen met een test: 24 runs, 480 EURC volume, 0 EURC voor de treasury. Het live contract heeft dit ook.
  - **L-E:** staat de koers precies op een tickgrens, dan kan iemand in het blok van de run liquiditeit bijzetten zonder dat de blokcheck het ziet, anders dan de NatSpec zegt. Op de fork gemeten: het slachtoffer krijgt een iets betere prijs, de JIT-positie int +3,72 bp van de run aan poolfee (ten koste van andere LP's), en de run blijft onder de in-range bovengrens.
  - **L-F:** een Chainlink-feed die binnen zijn drempel achterloopt, verruimt de geaccepteerde push in het vorige blok (`PR18-review/I-4`, SCOPE §5.3) van 40–50 bp naar 80–90 bp. Winst voor een aanvaller alleen als drie dingen samenvallen: protocolfee 0 (nu 68), 99% van de liquiditeit, en geen arbitrage tussen de blokken. Dan +82,3 bp in plaats van +44,2 bp. Bij de huidige protocolfee verliest de aanvaller 300 bp.
- **Twee informatieve punten:** Info-G, een Panic in plaats van `SequencerDown`, en Info-H, een verouderd commentaar in `script/Deploy.s.sol`.
- **Compiler en statische analyse:** solc 0.8.37 heeft 0 bekende compilerbugs. Slither (39 meldingen) en Aderyn (1 High, 4 Low) vonden geen echte bugs (`triage.md`). De "High" van Aderyn in `TickMath.sol` is een false positive.
- **Niet gedaan of mislukt:**
  - **Drie van de twaalf pashov-perspectieven ontbreken.** Numerical-gap, trust-gap en flow-gap stopten twee keer door de API-safeguard (`reasoning_extraction`).
  - **Echidna en Medusa niet gedraaid.** Daarvoor is een eigen property-harness nodig, en die is er niet.
  - **Geen deploy of on-chain wijziging.** Alleen `cast call`.
- **Status eerdere bevindingen:** `FINDINGS-STATUS.md` noemt geen open rij, en dat klopt nog.
  - **Bijgewerkt:** de app-PR's #146–#150, die daar als OPEN staan, zijn vanochtend gemerged in app-`development` (sectie [Status eerdere bevindingen](#status-eerdere-bevindingen)).

## Scope en context

- **Code:** `src/Rebalancer.sol` en `src/libraries/TickMath.sol` op `development`, commit `bab2ed3`, de merge van PR #18 op 2026-09-17 08:18 CEST. `src/interfaces/*` zijn alleen gelezen als context. Regelnummers in dit rapport verwijzen naar `bab2ed3`; `src/` is daar byte-gelijk aan de auditcommit `05ed03c` uit SCOPE §1.1. De branch `chore/audit-2026-09-17` voegt alleen `audit/` toe.
- **Compiler:**
  - solc 0.8.37, `via_ir = true`, `optimizer_runs = 1000`, `evm_version = cancun` (`foundry.toml`);
  - OpenZeppelin v5.6.1;
  - forge 1.5.1-stable.
- **Wat het contract doet:** een gebruiker geeft het contract een allowance op EURC en cbBTC en kiest een doelverdeling. Iedereen mag `execute(owner, rewardTo)` aanroepen zodra die owner buiten zijn band ligt. Het contract swapt dan via twee Uniswap v3-pools van 0,05% (EURC/USDC en USDC/cbBTC), binnen een blokvenster van 6 bp en binnen 50 bp van Chainlink, en houdt 0,25% fee in EURC in. Van die fee gaat maximaal 0,05 EURC naar `rewardTo`, de rest naar de treasury.
- **Live contract:** `0xE577D68948883FDF8e2694e38dF656D2D9CA2104`, uitgerold vanaf commit `f8a6d49` (`README.md:11`).
  - **Wat daar ontbreekt:** het heeft geen blokvenster en geen `retire()`, dus de oude M-1 (zelf-sandwich) zit er nog in.
  - **Per bevinding:** hieronder staat telkens of hij ook live geldt. Nagekeken met `git show f8a6d49:src/Rebalancer.sol` en met `cast call` op blok 51.426.659: `KEEPER_REWARD_EURC()` = 50.000 en `MIN_TRADE_FLOOR()` = 20.000.000.
- **Off-chain gebruikers van het contract:**
  - **Deze repo:** `keeper/keeper.ts`, `keeper/selection.ts` en `keeper/lock.ts` (de open keeper).
  - **App-repo `pinheadio/bitburo`** (lokaal `~/Code/bitburo`, `development` @ `bf04fbc`):
    - keeper-command: `app/Console/Commands/RunKeeperCommand.php`;
    - event-sync: `app/Console/Commands/SweepExecutionsCommand.php`;
    - lezen van het mandaat: `app/Services/Rebalancer/RebalancerMandateReader.php` en `app/Services/Rebalancer/RebalancerClient.php`;
    - ABI: `app/Support/RebalancerAbi.php`, `resources/js/lib/rebalancer-state.ts`;
    - configuratie: `config/bitburo.php`.

## Gebruikte tools

| Tool | Versie / commit | Resultaat | Output |
|---|---|---|---|
| Compilerbuglijst | `docs/bugs_by_version.json` van `argotorg/solidity` | 0 bugs voor 0.8.37 | `compiler-bugs.txt` |
| forge test (alle suites, fork gepind) | forge 1.5.1 | 211 geslaagd, 0 gefaald, 0 overgeslagen | `forge-test.txt` |
| Foundry invariants | 1.000 runs × depth 100 | 14 geslaagd | `invariants.txt` |
| Slither | 0.11.6 | 39 meldingen, geen echte bug | `slither.txt`, `slither.json`, `triage.md` |
| Aderyn | 0.6.8 | 1 High (false positive), 4 Low (stijl of bedoeld) | `aderyn.md`, `aderyn-run.log`, `triage.md` |
| pashov/skills `solidity-auditor` | commit `c577eb7` (VERSION 3), model Opus | 9 van 12 perspectieven afgerond | dit rapport |
| QuillShield `oracle-flashloan-analysis` | commit `8bdd3c0` | checklist volledig; 1 nieuwe Low (L-F), 1 Info (Info-H) | dit rapport, `poc/PrevBlockLagFork.t.sol` |
| keeper `bun test` | bun 1.3.5 | 97 geslaagd, 0 gefaald | niet opgeslagen |
| Eigen PoC's | — | 11 tests geslaagd | `poc/`, `poc/output.txt` |

`audit/run-static.sh` leverde de eerste vijf rijen. Het script stopte eerst op de bash van macOS (3.2): een leeg array onder `set -u`. Dat is gerepareerd in `cc54fe0`, dat nu ook tijdstip en `FORK_BLOCK` in `versions.txt` schrijft.

**Perspectieven van `solidity-auditor`:**
- **Afgerond:** math-precision, access-control, economic-security, execution-trace, invariant, periphery, first-principles, asymmetry en boundary. Economic-security lukte bij de tweede poging.
- **Ontbroken:** numerical-gap, trust-gap en flow-gap. Elk stopte twee keer door de API-safeguard `reasoning_extraction` (onder meer request-ID's `req_011Cf8qVGrFqEkf8sGJTfd14`, `req_011Cf8qeLEf36RMJ4ZS1hEbf`, `req_011Cf8qeUA9tK4JDn5JGDfpC`). Deze drie zijn in deze ronde dus niet gedekt.
- **Bij elke bevinding** staat welke perspectieven hem vonden.

## Compiler

Solc 0.8.37 heeft volgens `docs/bugs_by_version.json` geen bekende compilerbugs (`compiler-bugs.txt`, opgehaald 2026-09-17 12:11). Er is geen upgrade nodig. De zes bugs van 0.8.28 zijn in de vorige ronde behandeld (`audit/2026-09-16/ai-audit.md`, sectie Compiler).

---

## Bevindingen

### L-D (Low, bevestigd) — Runs op de vloer leveren de treasury niets op; een owner die zichzelf beloont, handelt zonder fee

**Waar:**
- `KEEPER_REWARD_EURC` (`src/Rebalancer.sol:130`), `MIN_TRADE_FLOOR` (`:138-145`);
- `_takeFee` (`:1020-1031`, beloning `:1025-1028`);
- `execute` accepteert elke `rewardTo` behalve het contract zelf (`:534`);
- budget van een ronde `max(total × maxCorrectionBps, minTradeEurc)` (`_plan` `:905`).

**Gevonden door:** boundary, economic-security (als FINDING), first-principles (genoemd als "bedoeld ontwerp", maar dat staat niet in README of SCOPE).

**Oorzaak.** De vloer van 20 EURC is zo gekozen dat de fee van de kleinste run precies de beloning is: 20e6 × 25 / 10.000 = 50.000 (NatSpec `:138-140`). Daardoor gaat bij elke run op de vloer de hele fee naar `rewardTo` en `fee − reward = 0` naar de treasury, wie er ook aanroept. `rewardTo` kiest de aanroeper vrij, dus een owner met een eigen keeper stuurt de beloning naar zichzelf en betaalt netto geen fee. Een owner bepaalt zelf dat al zijn runs vloerruns zijn: met `maxCorrectionBps` 10 (het minimum, `MIN_CORRECTION_BPS` `:161`) is het budget `max(total × 0,1%, 20 EURC)`. Dat is 20 EURC voor elke wallet tot 20.000 EURC. Grotere bedragen kan hij over meerdere adressen verdelen. Bij grotere runs krijgt een owner die zichzelf beloont 0,05 EURC per run terug: bij een wallet van 100.000 EURC met `maxCorrectionBps` 10 is dat 20% van de fee van 0,25 EURC. De enige kosten voor de owner zijn gas (~475.000 gas per run, `README.md:259`).

In README en SCOPE §3.1 staat alleen dat "de fee altijd de beloning dekt". Dat de treasury bij vloerruns niets krijgt en dat de owner de beloning zelf kan innen, staat nergens.

**Bewijs.** `poc/SelfKeeperFeeCapture.t.sol` (mocks, geen fork), gedraaid 2026-09-17 12:57 vanuit `test/`:

| Test | Opzet | Uitkomst |
|---|---|---|
| `test_poc_selfKeeperTradesFeeFreeAtFloor` | wallet 20.000 EURC, doel 80% cbBTC, `maxCorrectionBps` 10, `interval` 1 uur; 24× `execute(alice, alice)` | elke run 20 EURC (`isDue`-delta 20.000.000); volume 480 EURC; netto fee van alice 0; treasury 0 |
| `test_poc_floorRunsYieldNothingForTreasuryWithAnyKeeper` | zelfde wallet, externe keeper | keeper 50.000, treasury 0 |
| `test_poc_normalRunStillPaysTreasury` | `maxCorrectionBps` 1000, run 2.000 EURC, owner beloont zichzelf | treasury 4.950.000 (4,95 EURC) |

**Gevolg.** Geen verlies voor gebruikers. Het raakt wel de enige inkomstenbron van Bitburo, de contractfee (zie memory "verdienmodel alleen fee"):
- **Kleine wallets met een eigen keeper** handelen fee-vrij.
- **Grotere wallets** kunnen hetzelfde bereiken door zich over meerdere adressen te verdelen.
- **Ook met een externe keeper** krijgt de treasury bij elke vloerrun niets.

**Live contract:** ja. `f8a6d49` heeft dezelfde beloning, vloer en `rewardTo`-regel (live `:71`, `:83`, `:340`, `_takeFee` `:599-606`; on-chain bevestigd hierboven). Bij verkopen geldt het live nog iets vaker, omdat de fee daar over `received` wordt berekend (`09-16/L-B`).

**Fix (nieuwe contractversie, niet getest; keuze voor Arjan):**
1. Houd de beloning ruim onder de fee van de kleinste run, bijvoorbeeld `reward = min(KEEPER_REWARD_EURC, fee / 2)`, of verhoog `MIN_TRADE_FLOOR` naar 40 EURC. Dan houdt de treasury per run minstens de helft. Een owner die zichzelf beloont, betaalt nog steeds minstens de helft van de fee.
2. Geen beloning als `rewardTo == owner`. Dat is alleen een drempel: een tweede adres van de owner omzeilt hem.

Optie 1 verandert de economie van de keepers: bij een run van 20 EURC krijgt een keeper dan 0,025 EURC. `keeper/keeper.ts` gebruikt de beloning in het tipplafond (`README.md:259`). Laat die berekening meeveranderen.

---

### L-E (Low, bevestigd) — JIT-liquiditeit op de tickgrens schrijft geen observatie

**Waar:**
- NatSpec laag 1 (`src/Rebalancer.sol:41-43`): "Is er in dit blok geen observatie, dan staan tick en in-range liquiditeit nog zoals aan het begin van het blok: een aanvaller kan … geen JIT-liquiditeit in de range zetten";
- `_window` (`:688-708`), `_maxInput` (`:781-805`).

**Gevonden door:** execution-trace. De invariant-reviewer vond de verwante variant net buiten de range, maar die is al bekend (SCOPE §5.2).

**Oorzaak.** Uniswap v3 rekent een positie tot de range als `tickLower ≤ tick < tickUpper`. Een swap die precies op een tickgrens eindigt, laat de koers op P(b) staan met tick b − 1 (omlaag) of tick b (omhoog).
- **In die stand geldt als buiten de range:**
  - bij tick b − 1: een positie met ondergrens b;
  - bij tick b: een positie met bovengrens b.
- **Gevolg voor de blokcheck:** een mint schrijft dan geen observatie, dus de blokcheck ziet hem niet.
- **Wat de run doet:** een run in de richting van die positie kruist b meteen en handelt vanaf de eerste eenheid tegen die liquiditeit. Die liquiditeit is dus in feite wél in de range gezet.

De aanvaller moet de koers daarvoor in een eerder blok precies op P(b) zetten. Het is dezelfde klasse als de geaccepteerde "JIT buiten de range" (SCOPE §5.2, `README.md:67`), maar de NatSpec-zin op `:42-43` klopt daardoor niet in deze stand.

**Bewijs.** `poc/BoundaryJitFork.t.sol`, fork van Base met `FORK_BLOCK=51425248`. De tests draaien op blok 51.425.250 (twee keer `_nextBlock`). Gedraaid 2026-09-17 12:57, met 99× de actieve liquiditeit van EURC/USDC als JIT-positie van 50 ticks op grens b, correctie 2.000 EURC:

| Richting | Grens b | Observatie na JIT | Run zonder / met JIT (EURC) | In-range bovengrens (EURC) | Slachtoffer zonder / met JIT | PnL JIT-positie (zonder beloning) |
|---|---|---|---|---|---|---|
| koop (tick = b) | 1380 | nee | 642,437568 / 704,508107 | 704,508107 | 962.475 / 1.055.661 sats (per EURC 1.498,2 → 1.498,4 sats) | +0,262427 EURC = +3,72 bp van de run |
| verkoop (tick = b − 1) | 1370 | nee | 525,482378 / 525,482378 | 525,481952 | 523,726785 / 523,806271 EURC | +0,195584 EURC = +3,72 bp van de run |

- **Slachtoffer:** krijgt met de JIT per eenheid nooit minder. Geasserteerd.
- **Runomvang:** blijft onder de in-range bovengrens, met een marge van 1 sat omdat de verkoop-delta naar boven afrondt. Geasserteerd. Bij de koop tilt de JIT een liquiditeitsklif op tot precies die bovengrens, het gedrag uit SCOPE §5.2.
- **Winst:** de +3,72 bp is gewone poolfee (99% × 5 bp × ¾ na de protocolfee) op het volume van het slachtoffer. Die gaat ten koste van de andere LP's, niet van het slachtoffer.
- **Andere maat dan de README:** `README.md:67` zegt dat JIT buiten de range "geen winst oplevert". Daar gaat het om de extra winst van een push bij gelijke JIT; deze meting vergelijkt JIT met geen JIT, zonder push.

**Combinatie met een push binnen de tick:** niet gemeten.
- **In de pool met de JIT kan het niet:** een push in de schadelijke richting vanaf P(b) kruist b meteen, verandert de tick en wordt dus geweigerd.
- **In de andere pool wel:** daar blijft de bekende grens van `final-review/F-4` gelden.

**Gevolg.** Geen extra verlies voor gebruikers. De NatSpec (`:41-43`), SCOPE §3.3 punt 1 en vraag 1(c) aan de auditors gaan ervan uit dat JIT in de range in het blok van de run niet kan. In deze randstand kan het wel, zonder schade voor het slachtoffer.

**Live contract:** n.v.t. `f8a6d49` heeft geen blokcheck.

**Fix:** alleen documentatie. Voeg de randstand toe aan de NatSpec (`:41-43`) en aan README "JIT buiten de range", en noem hem bij SCOPE vraag 1(c). Een codefix, bijvoorbeeld een run weigeren als de koers precies op een initialiseerbare grens staat, kost eerlijke runs beschikbaarheid en voorkomt geen verlies.

---

### L-F (Low, bevestigd) — Chainlink-achterstand verruimt de push in het vorige blok

**Waar:**
- `_requireSpotNear` (`src/Rebalancer.sol:621-625`) met `MAX_SPOT_DEVIATION_BPS` 50 (`:137`), vóór en na de swap (`:539`, `:977`, `:1004`);
- `amountOutMinimum` uit de oracle (`:965`, `:991`);
- blokcheck `:691`, die een push in blok N − 1 niet ziet (NatSpec `:60-61`).

**Gevonden door:** QuillShield oracle-checklist, gemeten op de fork. Economic-security gaf de push door een dominante LP in het vorige blok als lead, zonder de achterstand.

**Oorzaak.** De spotcheck vergelijkt de pool met Chainlink, niet met de markt. Chainlink mag binnen de deviation-drempel achterlopen: cbBTC/USD 0,3%, EURC/USD 0,1% (Chainlink-directory, sectie Reproduceren). Loopt de feed in het voordeel van de aanvaller achter, dan telt die achterstand op bij de tolerantie van 50 bp. De geaccepteerde push aan het eind van het vorige blok (`PR18-review/I-4`, SCOPE §5.3) mag dan veel groter zijn. SCOPE §5.3 rekent zonder achterstand: grootste push 25 bp (koop) / 50 bp (verkoop), LP 99% bij protocolfee 0 tot +41,5 bp.

**Bewijs.** `poc/PrevBlockLagFork.t.sol` (geschreven door de QuillShield-reviewer, door mij opnieuw gedraaid met identieke uitkomst). Fork met `FORK_BLOCK=51425248`, gedraaid 2026-09-17 12:56. De opzet:
- **Correctie:** 10.000 EURC, `maxSlippageBps` 100.
- **Push:** alleen in EURC/USDC, in blok N − 1, en na de run weer teruggedraaid.
- **Timing:** `execute` bovenaan blok N, geen arbitrage tussen de blokken.
- **Achterstand:** gemockt met `vm.mockCall` op `latestRoundData`, cbBTC/USD 30 bp en EURC/USD 10 bp in het voordeel van de aanvaller.
- **Maten:** "extra winst" is de winst van de aanvaller met push min dezelfde opzet zonder push, in bp van de run. "Slachtoffer extra" is de slechtere effectieve koers ten opzichte van de run zonder push.

| Aanvaller | Achterstand | Grootste geaccepteerde push | Extra winst aanvaller | Slachtoffer extra | Slachtoffer t.o.v. echte koers (incl. 25 bp fee) |
|---|---|---|---|---|---|
| LP 99%, protocolfee 0, koop | geen | 50 bp | **+44,24 bp** | 50,2 bp | 83,0 bp |
| LP 99%, protocolfee 0, koop | 30 + 10 bp | 90 bp | **+82,33 bp** (+82,33 EURC) | 90,6 bp | 123,5 bp |
| LP 99%, protocolfee 0, verkoop | geen | 40 bp | +33,36 bp | 40,0 bp | 81,3 bp |
| LP 99%, protocolfee 0, verkoop | 30 + 10 bp | 80 bp | +67,32 bp | 79,7 bp | 120,7 bp |
| LP 99%, huidige protocolfee (68), koop | 30 + 10 bp | 90 bp | −300,0 bp (−300,01 EURC) | 90,6 bp | 123,5 bp |
| geen LP, huidige protocolfee, koop | 30 + 10 bp | 80 bp | −485,2 bp (−5,98 EURC op een run van 123,2 EURC) | 80,3 bp | 113,5 bp |

Alle regels staan in `poc/output.txt` (prefix `PBL,`). Een push boven de grootste geaccepteerde push revert met `SpotDeviatesFromOracle` (`0x1b3ce45e`).

**Gevolg.**
- **Bij de huidige protocolfee** maakt niemand winst: de aanvaller verliest 300 tot 485 bp om het slachtoffer ~80–90 bp slechter te laten handelen. Dat is griefing tegen eigen verlies.
- **Bij protocolfee 0 (hypothetisch)** met 99% van de liquiditeit en zonder arbitrage verdubbelt de geaccepteerde restwinst uit SCOPE §5.3 ongeveer.
- **Verliesgrens:** de grens `FEE_BPS + maxSlippageBps` geldt tegenover de achterlopende feed, niet tegenover de markt. Gemeten tot 123,5 bp tegenover de echte koers; theoretisch tot 125 bp plus de achterstand van ~40 bp.
- **Niet gemeten:** een push in beide pools met achterstand (lead 17).

**Live contract:** ja, en daar zwaarder. `f8a6d49` heeft geen blokcheck, dus ook de push in hetzelfde blok (de oude `09-16/M-1`) krijgt daar de achterstand erbij (`09-16/M-1`, tabel "0,3% te hoog": tot +18,71 EURC).

**Fix:** documentatie. Voeg de achterstandsterm toe aan SCOPE §5.3, README "Niet gedekt" en de NatSpec `:60-61`, en noem hem bij vraag 2 aan de auditors. `MAX_SPOT_DEVIATION_BPS` verlagen verkleint de ruimte, maar laat eerlijke runs vaker reverten (SCOPE §4.5: > 50 bp in 0,14% van de uurmetingen). De kosten daarvan zijn niet gemeten.

---

### Info-G — Sequencer-feed met `startedAt` in de toekomst geeft een Panic in plaats van `SequencerDown`

**Waar:** `_quote` `src/Rebalancer.sol:602`: `block.timestamp - seqStartedAt < GRACE_PERIOD` zonder de check `seqStartedAt > block.timestamp`. Voor de prijsfeeds staat die check er wel (`_readFeed` `:815`).

**Gevonden door:** access-control, math-precision, asymmetry, first-principles, economic-security.

**Gevolg:**
- **`execute`:** revert met Panic 0x11 in plaats van `SequencerDown`.
- **`isDue` en `dueOwners`:** vangen de fout af via `_tryQuote` (`:821-827`).
- **`keeper/selection.ts`:** telt `SequencerDown` niet als tijdelijke fout (`isTemporaryFailure` `:53-54`). Een onbekende Panic krijgt dus dezelfde behandeling; de melding van de asymmetry-reviewer dat de keeper hierdoor anders reageert, klopt niet.
- **Kan het voorkomen?** Niet nagegaan of de uptime-feed op Base ooit een `startedAt` na de L2-tijdstempel geeft.
- **Live:** ja (live `:403`).

**Fix:** `seqStartedAt > block.timestamp ||` toevoegen aan de voorwaarde op `:602`.

### Info-H — Verouderd commentaar in het deployscript

**Waar:** `script/Deploy.s.sol:26-27`: "De vorige feed 0xDAe398…8250 (24 u) staat niet meer in de directory".

**Gevonden door:** QuillShield oracle-checklist. Door mij nagekeken in de JSON van de Chainlink-directory op 2026-09-17 12:58: `0xDAe398520e2B67cd3f27aeF9Cf14D93D927f8250` staat er nog, als "EURC / USD", heartbeat 86.400 s, drempel 0,3.

**Gevolg:** geen. De conclusie klopt nog: `MAX_AGE_EURC` 4.500 s (`src/Rebalancer.sol:176`) zou die feed meteen weigeren.

**Fix:** zin aanpassen naar "heeft een heartbeat van 24 uur".

---

## Leads (met de hand nalopen)

11. **Rondebudget schaalt niet mee met de wallet** (execution-trace, invariant).
    - **Wat:** in een deel is het budget `rounds[owner].remainingEurc` (`:900-903`), vastgesteld bij de eerste run.
    - **Voorbeeld:** wallet 1.000.000 EURC, `maxCorrectionBps` 1000, budget 100.000 EURC. De eerste run doet 30.000; de owner haalt daarna geld weg tot 100.000 EURC. Volgende delen mogen dan tot min(40.000, 70.000, liquiditeit), meer dan 10% van de wallet van dat moment.
    - **Wie kan het:** alleen de owner zelf (opnemen), of de koers.
    - **Richting en grenzen:** elk deel gaat richting het doel en blijft begrensd door band en venster.
    - **Documentatie:** SCOPE §3.4 noemt het vaste budget "ook na een donatie", maar niet het krimpen.
    - **Te besluiten:** documenteren, of het budget in een deel ook begrenzen op `max(total × maxCorrectionBps, minTradeEurc)`.
12. **Ronde blijft staan als de koers de owner zelf binnen de band brengt** (access-control). Tot `interval` blijft een deel elke `CHUNK_INTERVAL` mogelijk als de afwijking in dezelfde richting terugkomt. Al bekend: SCOPE vraag 4 ("does not close the round on-chain") en `PR18-review/I-3` (geaccepteerd). Geen nieuwe actie.
13. **`MAX_BLOCK_MOVE_BPS < TICK_SPACING` staat alleen in commentaar** (first-principles). `_maxInput` gaat uit van hooguit één initialiseerbare grens in het venster (NatSpec `:151-153`, `:776-779`). Klopt voor 6 < 10; een latere versie met andere constanten zou dit stil breken. Hardening: een check op compile- of constructortijd.
14. **LP dwingt delen af door liquiditeit weg te halen** (first-principles). Een grote LP haalt in blok N − 1 liquiditeit weg, zodat de run door de liquiditeit begrensd is en een ronde opent. Fee en budget blijven evenredig; verlies voor de owner niet aangetoond, alleen invloed op de timing.
15. **Verkoopinput kan de schatting van `_maxInput` tot 1 sat plus ~0,5% overschrijden** (math-precision).
    - **Oorzaak:** `wantBtc` rondt naar boven af (`:930`), en de USDC op hop 1 wordt tegen de poolkoers gewaardeerd, niet tegen de oracle.
    - **Vangnet:** de marge van 25% in `SIZING_BPS` vangt het op, en het venster wordt na de swap opnieuw gecontroleerd (`:562-563`).
    - **Gezien in L-E:** de verkoop-delta lag 426 basiseenheden boven de in-range bovengrens.
    - **Niet aangetoond:** een run die hierdoor faalt.
16. **Aannames over de pools en de chain** (periphery).
    - **Ongewijzigde v3-code:** de blokcheck gaat ervan uit dat de pools op Base ongewijzigde v3-core-code draaien. Per actie op de fork aangetoond met `test_observationSemantics_perAction` (`test/BlockWindowReviewFork.t.sol:525`).
    - **Unieke tijdstempel per blok:** de check gaat er ook van uit dat elk blok een eigen tijdstempel heeft. Delen twee blokken er een, dan weigert de check alleen te vaak (first-principles), en dat is veilig.
17. **L-F met een push in beide pools** (QuillShield). Alleen EURC/USDC is geduwd; de omvang en winst bij een push in USDC/cbBTC erbij zijn niet gemeten.
18. **Achterstand plus push binnen de tick, voor een LP-aanvaller** (QuillShield). De achterstand veranderde de uitvoeringskoers niet: de rijen met en zonder achterstand gaven bij dezelfde push dezelfde koers. Daarom wordt geen nieuw effect verwacht, maar voor een LP-aanvaller is dit niet apart gemeten.

## Opgemerkt, geen impact

- **Fee rondt naar beneden af** (`:1024`, math-precision). Verschil minder dan 1 basiseenheid EURC per run, in het voordeel van de owner.
- **Na `retire` moet intrekken nog geldige params meesturen, en registreren blijft mogelijk** (asymmetry). Staat al zo in het rapport van 16 september.
- **Gasuithongering van `trySafeTransfer`** (boundary, periphery, execution-trace, invariant). Wie de treasury-transfer zonder gas laat lopen, houdt ~1/64 over. Dat is te weinig voor de rest van `_sell` of `_buy`, dus de hele transactie revert.
- **Push door een dominante LP in het vorige blok** (economic-security). Dat is `PR18-review/I-4` en SCOPE §5.3, uitgebreid met de achterstand in L-F.

## Gecontroleerd en in orde

- **Blokcheck.** Getoetst tegen Uniswap v3-core `d8b1c635` (QuillShield: `UniswapV3Pool.sol:327-348`, `:715-760`, `Oracle.sol:90`; execution-trace, invariant, asymmetry, boundary):
  - **Wanneer er een observatie komt:** elke tickwissel en elke mint of burn in de range schrijft er een, hooguit één per blok.
  - **Terug duwen verbergt niets:** heen en terug duwen binnen één blok schrijft een observatie.
  - **Randstand met een swap:** bij koers op P(t) en tick t − 1 kruist een swap omhoog meteen (observatie), en omlaag blijft hij in t − 1.
  - **Uitzonderingen:** alleen de bekende push binnen de tick (`final-review/F-4`), JIT buiten de range (SCOPE §5.2) en L-E.
- **Vensterrekenwerk** (math-precision, periphery, asymmetry, first-principles, boundary):
  - de onder- en bovengrens ronden naar een smaller venster;
  - omlaag kunnen hooguit de ticks t tot en met t − 5 gekruist worden, omhoog t + 1 tot en met t + 5 (1,0001^6 = 1,00060015), dus per richting hooguit één veelvoud van 10;
  - de grensbepaling voor negatieve ticks klopt (−5 → −10, −15 → −20), net als die voor een koers precies op een grens.
- **Liquiditeit voorbij de grens:** `min(L, L ± liquidityNet)` maakt een run nooit groter. Een mint of burn in de range schrijft een observatie.
- **`_convert` en `_spot`:** geen overflow bij sqrtPriceX96 = 2^160 − 1; `ratioX128 ≥ 1` voor elke geldige koers. De tokenvolgorde-vlaggen kloppen in alle vier de hops.
- **Fee-boekhouding:**
  - `reward + treasury + retained == fee`;
  - elke run is minstens de vloer, dus fee ≥ 50.000, ook bij verkopen (fee-grondslag `max(received, expectedOut)`);
  - `received` is een balansverschil en telt achtergehouden fee niet mee.
- **Router:** approvals voor exact het swapbedrag; `amountIn` = 0 (de sentinel `CONTRACT_BALANCE`) is onbereikbaar; ontvanger `address(1)` of `address(2)` kan geen owner zijn.
- **Reentrancy:**
  - `execute` en `sweep` delen de transient lock;
  - EURC en cbBTC hebben geen hooks;
  - `execute` aanroepen vanuit een swap- of flash-callback van een pool revert, omdat die pool dan op slot staat (LOK).
- **Views reverten niet:** feed-, sequencer- en spotfouten via `try this.quoteChecked()`, en er is geen deling door nul of overflow in `_maxInput`.
- **USDC-depeg:** valt weg in de gecombineerde spot. Beide pools noteren tegen USDC, dus EURC/USDC × USDC/cbBTC = EURC/cbBTC (economic-security).
- **Chainlink-validatie** (QuillShield-checklist, alle items PASS of N.A.):
  - `answer > 0`, geen `updatedAt` in de toekomst, `MAX_AGE_CBBTC` 1.500 s ≥ heartbeat 1.200 s, `MAX_AGE_EURC` 4.500 s ≥ heartbeat 3.600 s;
  - decimals 8, sequencer up plus 1 uur grace, `startedAt != 0`;
  - `answeredInRound` terecht afwezig.
  - **Update-cadans:** QuillShield mat via `getRoundData` als grootste gat tussen updates 1.232 s (cbBTC/USD, 400 rondes) en 3.636 s (EURC/USD, 150 rondes), beide onder de maximale leeftijd. Door mij niet herhaald.
- **Interfaces:** `slot0` (7 velden), `ticks` (8), `observations` (4) en `liquidityNet` als `int128` komen overeen met de v3-ABI.
- **`TickMath.getSqrtPriceAtTick`:** gelijk aan Uniswap v4-core `46c6834`, op de revert-stijl na (`triage.md`).

## Fuzzing

- **Foundry invariants, diep:** 14 van 14 geslaagd bij 1.000 runs × depth 100. Het gaat om de 7 invariants in twee handler-opstellingen: `RebalancerInvariantTest` en `RebalancerInvariantTestNoRetire`. Output in `invariants.txt`.
- **Echidna en Medusa:** niet gedraaid. De foundry-modus van Echidna werkt niet met deze handler; dat bleek op 2026-09-16 (`audit/2026-09-16/ai-audit.md`, sectie Fuzzing: `allContracts` roept mocks direct aan, `filterFunctions` bereikt de handler nauwelijks). Er is nog geen eigen property-harness; pashov `fizz` kan er een genereren, en dat vraagt eerst een akkoord.

## Reproduceren

Alle commando's vanuit de root van `bitburo-contracts`, op commit `bab2ed3` of de branch `chore/audit-2026-09-17`.

```bash
# Deterministische stappen (compilerbugs, tests, invariants, Slither, Aderyn)
set -a; source .env; set +a                 # BASE_RPC_URL; waarde niet tonen
FORK_BLOCK=51425248 bash audit/run-static.sh audit/2026-09-17-self

# Keeper
cd keeper && bun test && cd ..

# PoC's: kopiëren naar test/, draaien, weer weghalen
cp audit/2026-09-17-self/poc/*.t.sol test/
RUN_FORK=false ~/.foundry/bin/forge test --match-contract SelfKeeperFeeCaptureTest -vv                       # L-D
FORK_BLOCK=51425248 ~/.foundry/bin/forge test --match-contract BoundaryJitForkTest --match-test boundaryJit -vv   # L-E
FORK_BLOCK=51425248 ~/.foundry/bin/forge test --match-contract QuillPrevBlockLagTest -vv                     # L-F
rm test/SelfKeeperFeeCapture.t.sol test/BoundaryJitFork.t.sol test/PrevBlockLagFork.t.sol
```

**Valkuilen:**
- `forge` op het PATH is Laravel Forge; gebruik `~/.foundry/bin/forge`. `run-static.sh` zet Foundry zelf voorop.
- `BoundaryJitForkTest` erft van `BlockWindowReviewForkTest`. Zonder `--match-test boundaryJit` draaien alle 16 geërfde fork-tests mee.
- De PoC's compileren alleen in `test/`, want ze importeren `./Rebalancer.t.sol` of `./BlockWindowFork.t.sol`.
- Fork-tests zonder `FORK_BLOCK` forken het laatste blok, en de getallen verschuiven dan per run. De RPC moet historische staat voor blok 51.425.248 leveren; `https://mainnet.base.org` is rate-limited.
- Onder `via_ir` cachet Solidity `block.timestamp` in een testfunctie. Gebruik na `vm.warp` `vm.getBlockTimestamp()`.
- `run-static.sh` op de bash van macOS werkt pas vanaf `cc54fe0`.

**Metingen en tijdstippen (CEST, 2026-09-17):**
- `run-static.sh`: gestart 12:11, forge test klaar 12:12:58, Aderyn 12:13:34 (`versions.txt`).
- PoC's (`poc/output.txt`): 12:56 (L-F) en 12:57 (L-D, L-E), op `FORK_BLOCK=51425248`.
- `cast call` op het live contract: blok 51.426.659.

**Externe bronnen** (op 2026-09-17 geraadpleegd, niet in de repo opgeslagen):
- **Compilerbugs:** `https://github.com/argotorg/solidity/blob/develop/docs/bugs.json` en `docs/bugs_by_version.json`.
- **Yul `shl` en `shr`:** `docs/yul.rst:809`, `:811` in `github.com/argotorg/solidity` (blob `f36a29e`).
- **Uniswap v4-core `TickMath.sol`** op commit `46c6834`: `github.com/Uniswap/v4-core`.
- **Uniswap v3-core** `UniswapV3Pool.sol` en `Oracle.sol` op commit `d8b1c635`: `github.com/Uniswap/v3-core` (gelezen door de QuillShield-reviewer).
- **Chainlink-feeds op Base:** `https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json`, de data achter `https://docs.chain.link/data-feeds/price-feeds/addresses?network=base`.
  - cbBTC/USD `0x07DA…9f9D`: heartbeat 1.200 s, 0,3%.
  - EURC/USD `0x9867…01e0`: 3.600 s, 0,1%.
  - EURC/USD `0xDAe3…8250`: 86.400 s, 0,3%.

**AI-reviews herhalen:**
- **pashov:** `git clone https://github.com/pashov/skills` (gebruikt: `c577eb7`). Volg `solidity-auditor/SKILL.md` met als bestanden `src/Rebalancer.sol` en `src/libraries/TickMath.sol`. De uitkomst verschilt per run.
- **QuillShield:** `git clone https://github.com/quillai-network/quillshield_skills` (gebruikt: `8bdd3c0`). Volg `plugins/oracle-flashloan-analysis/skills/oracle-flashloan-analysis/SKILL.md` en lees de map `references/` ernaast; `install.sh` kopieert die niet mee. Negeer `answeredInRound`.

**Niet opgeslagen:**
- de volledige transcripten van de AI-reviewers;
- de uitvoer van `bun test`;
- de ruwe `getRoundData`-reeks van de cadansmeting (QuillShield);
- de eerste, deels mislukte run van `run-static.sh`, die na de compilerbugcheck stopte.

## Status eerdere bevindingen

`audit/2026-09-17/FINDINGS-STATUS.md` (64 rijen, "No row is open") geldt voor `05ed03c`. `src/`, `test/`, `script/` en `keeper/` op `bab2ed3` zijn daaraan gelijk (SCOPE §1.1). Wat sindsdien veranderde, nagekeken op 2026-09-17 met `gh pr view <n> --repo pinheadio/bitburo --json state,mergedAt`:

| Rij in FINDINGS-STATUS | Stond | Nu |
|---|---|---|
| `09-15/H-1` (#147, #150), `09-15/M-7` (#148), `09-15/M-9` (#147, #148), `09-15/L-7` (#148), `09-15/L-8` (#146), `L3-research/L3-R` (#149) | app-PR's OPEN | #146, #147, #150 gemerged 08:18–08:33, #148 om 08:23, #149 om 09:29 (CEST), alle in app-`development` (@ `bf04fbc`). Niet op app-`production` gecontroleerd; niets in productie geverifieerd. |
| `final-review/F-4`, `PR18-review/I-4` (SCOPE §5.3, §5.4) | geaccepteerd | L-F voegt de achterstandsterm toe aan `PR18-review/I-4`. Opnieuw beoordelen of de acceptatie blijft staan. |
| SCOPE §5.2 (JIT buiten de range) | geaccepteerd | L-E is een randstand van hetzelfde mechanisme. Aanvullen in NatSpec en README. |

Geen eerdere bevinding is door deze ronde heropend.

## Volgende stappen

1. **L-D besluiten (Arjan).** Kies tussen beloning ≤ fee / 2, een hogere `MIN_TRADE_FLOOR`, geen beloning voor `rewardTo == owner`, of accepteren. Een codefix vraagt een nieuwe contractversie en een aanpassing van het tipplafond in `keeper/keeper.ts` (`README.md:259`). Doe het op een nieuwe branch vanaf `development`, met een test naar het voorbeeld van `poc/SelfKeeperFeeCapture.t.sol`, maar dan met asserts op het gekozen gedrag.
2. **Documentatie bijwerken** (zelfde branch of een eigen branch vanaf `development`):
   - **L-E:** NatSpec `src/Rebalancer.sol:41-43`, README "JIT buiten de range" (`README.md:67`), SCOPE §3.3 punt 1 en vraag 1(c).
   - **L-F:** NatSpec `:60-61`, README "Niet gedekt" (`README.md:63`), SCOPE §5.3 en vraag 2.
   - **Info-H:** `script/Deploy.s.sol:26-27`.
   - **Lead 11:** SCOPE §3.4.
   - **Auditpakket:** de externe auditor krijgt `audit/2026-09-17/`. Neem deze punten daar op of voeg dit rapport toe, anders mist hij ze.
3. **Info-G** meenemen in dezelfde contractversie als L-D (één voorwaarde op `:602`), met een test naar het voorbeeld van `test_execute_revertsSequencerDownWhenStartedAtZero` (`test/Rebalancer.t.sol:577`).
4. **Leads 11, 13, 14, 15, 17 en 18** per stuk nalopen en besluiten: fixen, documenteren of verwerpen. Lead 17 en 18 zijn uit te breiden in `poc/PrevBlockLagFork.t.sol`.
5. **De drie ontbrekende pashov-perspectieven** (numerical-gap, trust-gap, flow-gap) later opnieuw proberen, bijvoorbeeld met een ander model. Of de externe audit dat laten dekken.
6. **Nieuwe deploy: alleen met uitdrukkelijk akkoord van Arjan.**
   - **Live mist nog:** het live contract `0xE577…2104` (`f8a6d49`) heeft geen blokvenster en geen `retire()` (`README.md:14`). Daar gelden de oude `09-16/M-1`, L-D, L-F (zwaarder) en Info-G nog.
   - **Draaiboek:** lees eerst het draaiboek in issue #7 van `pinheadio/bitburo-contracts`.
   - **Valkuil `broadcast/`:** `deploy-mainnet.sh go` weigert zolang `broadcast/` al een deploy bevat (`FORCE_REDEPLOY=1`). `broadcast/` staat in `.gitignore`, dus een verse clone gedraagt zich anders.
   - **App bijwerken na de deploy:**
     - `BITBURO_REBALANCER_ADDRESS` en `BITBURO_REBALANCER_DEPLOY_BLOCK`;
     - het oude adres in `BITBURO_REBALANCER_LEGACY_ADDRESSES` (`config/bitburo.php`);
     - `REBALANCER` voor `keeper/keeper.ts`.
7. **Externe audit** op de versie die uit stap 1 tot en met 3 komt, met dit rapport als aanvulling op `audit/2026-09-17/`.
