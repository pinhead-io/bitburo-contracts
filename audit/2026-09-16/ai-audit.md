# AI-audit Rebalancer — 2026-09-16

Zelf-audit vóór de externe audit. Dit rapport bouwt voort op `audit/2026-09-15/RAPPORT.md`. De ID's H-n, M-n en L-n verwijzen naar de samenvattingstabel van dat rapport; L-A, L-B en L-C zijn nieuw. Let op: de detailrapporten in `audit/2026-09-15/details/` en code-commentaar in de app gebruiken een eigen nummering (bijvoorbeeld `M-01`, `ORC-1`), en Aderyn nummert zijn eigen meldingen ook L-1/L-2. Die vallen niet samen met de ID's in dit rapport.

## Samenvatting

- **In deze ronde één open probleem met verlies voor gebruikers gevonden in `src/`: M-1 (Medium).** Wie `execute` aanroept, kan zijn eigen run nog steeds winstgevend sandwichen. De post-swap-check verkleint de winst, maar sluit hem niet. Bevestigd met fork-tests.
- **Drie kleine punten (Low), zonder verlies:** L-A, L-B, L-C.
- **Compiler van 0.8.28 naar 0.8.37**, zes bekende compilerbugs weg. Het contract werd waarschijnlijk door geen ervan geraakt.
- **Tien leads** om met de hand te controleren, plus wat is gecontroleerd en in orde bevonden.
- **Status van het rapport van 2026-09-15** (zie [Status bevindingen 2026-09-15](#status-bevindingen-2026-09-15)): 9 opgelost (H-2, M-2, M-4, M-5, M-6, L-1, L-2, L-4, L-9), 6 deels opgelost (H-1, M-7, M-8, M-9, L-7, L-8), 2 open (M-1, L-3), 3 vervallen met CRE (M-3, L-5, L-6). De contractfixes zitten ook in het live contract; alleen `retire()` ontbreekt daar. De fixes in de app staan op `development`, maar nog niet op app-`production`. Van de Privy-policy's is niets live geverifieerd.

## Scope en context

- **Code:** `src/Rebalancer.sol` op branch `chore/solc-0.8.37` (afgesplitst van `development`), commit `48cc7f9` (solc 0.8.37, `via_ir = true`, `evm_version = cancun`, OpenZeppelin 5.6.1). Regelnummers in dit rapport verwijzen naar die commit.
- **Wat het contract doet:** gebruikers geven het een allowance op EURC en cbBTC en stellen met `setParams` een doelverdeling in. Iedereen mag `execute(owner, rewardTo)` aanroepen zodra een owner due is. Het contract prijst de wallet met Chainlink (cbBTC/USD en EURC/USD), controleert dat de spotprijs van de meegegeven Uniswap v3-pools EURC/USDC en USDC/cbBTC binnen 0,5% van die prijs ligt, en swapt via SwapRouter02 over het pad met fee-tier 500 (0,05%). Dat de gecontroleerde pools ook die 0,05%-pools zijn, dwingt het contract niet af (zie lead 1). Het houdt 0,25% fee in EURC; daarvan krijgt de aanroeper maximaal 0,05 EURC en de rest gaat naar de treasury.
- **Live contract:** `0xE577D68948883FDF8e2694e38dF656D2D9CA2104`, uitgerold vanaf commit `f8a6d49` (solc 0.8.28, nog zonder `retire()` en met het CRE-oppervlak; zie `README.md`). Nagekeken met `git show f8a6d49:src/Rebalancer.sol`: **M-1, L-A, L-B en L-C zitten ook in het live contract.** Een fix vraagt dus een nieuwe deploy.
- **Keepers:** er zijn twee externe wekkers die `dueOwners`/`isDue` lezen en `execute` aanroepen: `keeper/keeper.ts` in deze repo en `app/Console/Commands/RunKeeperCommand.php` in de app-repo `pinheadio/bitburo` (lokaal `~/Code/bitburo`). Paden die met `app/` of `config/` beginnen, zijn relatief aan die app-repo. Chainlink CRE bestaat niet meer (verwijderd in v1.1.0).

## Gebruikte tools

| Tool | Versie | Resultaat | Output |
|---|---|---|---|
| Slither | 0.11.6 | 30 meldingen, allemaal by design of false positive | `slither.txt`, `triage.md` |
| Aderyn | 0.6.8 | 0 High, 2 Low (large numeric literal: stijl; unchecked return: by design) | `aderyn.md`, `triage.md` |
| pashov/skills `solidity-auditor` | commit `c577eb7` | 11 van 12 perspectieven afgerond (model Opus); flow-gap viel twee keer uit door een API-fout | dit rapport |
| QuillShield `oracle-flashloan-analysis` | commit `8bdd3c0` | Chainlink-validatie volledig in orde, sandwich-check faalt | dit rapport |
| Echidna | 2.3.3 | Niet bruikbaar met deze testhandler | `echidna/*.yaml`, zie [Fuzzing](#fuzzing) |
| Foundry invariants | forge 1.000 runs × depth 100 | 5/5 groen | zie [Fuzzing](#fuzzing) |

`solidity-auditor` laat twaalf parallelle AI-reviewers elk vanuit één perspectief naar de code kijken: math-precision, access-control, economic-security, execution-trace, invariant, periphery, first-principles, asymmetry, boundary, numerical-gap, trust-gap, flow-gap. Bij elke bevinding staat hieronder welke perspectieven hem vonden. Hoe vaker, hoe onafhankelijker bevestigd.

## Compiler (opgelost in deze branch)

Solc 0.8.28 heeft 6 bekende compilerbugs, allemaal opgelost in 0.8.37 (bron: `docs/bugs_by_version.json` en `docs/bugs.json` in `github.com/argotorg/solidity`). De zwaarste is **SOL-2026-1 TransientStorageClearingHelperCollision** (high, via-IR + cancun, 0.8.28–0.8.33). Die treedt op wanneer dezelfde bytecode zowel `delete` doet op een variabele met het `transient`-keyword als storage cleart (`delete`, `pop()`, kortere array toewijzen).

- **Huidige code en live code (`f8a6d49`):** geen `delete`, `pop()` of `transient`-keyword in `src/` (`git grep`). OpenZeppelin `ReentrancyGuardTransient` gebruikt `TransientSlot` (assembly `tstore`), niet het keyword. Waarschijnlijk dus niet geraakt.
- **Commit `48cc7f9`** zet `foundry.toml` en alle pragma's op 0.8.37; 127/127 tests groen.
- De PoC's in `audit/2026-09-15/poc/` staan bewust nog op 0.8.28 (momentopname).

---

## Bevindingen

### M-1 (Medium, bevestigd, nog open) — Aanroeper kan zijn eigen `execute` winstgevend sandwichen

**Waar:** `execute` → `_buy`/`_sell`, met `_requireSpotNear` (`src/Rebalancer.sol:395`, `:539`, `:564`) en `minOut` (`:527`, `:551`).
**Gevonden door:** QuillShield oracle-checklist (bewezen op fork), economic-security, access-control, invariant, first-principles, execution-trace.

**Oorzaak.** De spotcheck vóór én na de swap staat 50 bps afwijking van de Chainlink-prijs toe (`MAX_SPOT_DEVIATION_BPS`, `:73`). `minOut` ligt 60–100 bps onder de Chainlink-prijs. Een aanvaller doet in één transactie: pool duwen → `execute(slachtoffer, zichzelf)` → pool terugduwen. Zolang zijn push plus de eigen prijsimpact van het slachtoffer onder 50 bps blijft, slaagt alles en houdt hij winst over. De NatSpec (`:33`) en `README.md:41` zeggen dat de post-swap-check die winstruimte "grotendeels sluit"; dat klopt niet. De bestaande test `test_poc_selfSandwich_10k_slippage100` bevestigt alleen dat een maximale push bij een run van 10.000 EURC niet winstgevend is; gedeeltelijke pushes test hij niet. De gedocumenteerde verliesgrens per run (`FEE_BPS + maxSlippageBps` ten opzichte van Chainlink) blijft wel gelden.

**Bewijs.** Fork-tests tegen Base mainnet op het laatste blok. De getallen verschuiven dus per run met de poolstand.

*Verkoopruns* — `test/OracleSandwich.t.sol::test_poc_sweepSell`, gedraaid 2026-09-16 ~13:59. De test logt per wallet eerst `EURC-waarde positie` (de hele cbBTC-positie) en `baseline EURC ontvangen` (de run: 20% van de positie). De tabel gebruikt die laatste waarde. De test heeft geen asserts; het is een meting:

| Run (EURC ontvangen zonder aanval) | Push (USDC) | Winst aanvaller | Verlies slachtoffer |
|---|---|---|---|
| 4.929 | 2.099 | +3,55 USDC | 4,82 EURC |
| 4.929 | 4.198 | +7,80 USDC | 10,30 EURC (21 bps) |
| 2.466 | 6.298 | +2,51 USDC | 7,56 EURC |
| ~990 | alle | verlies | — |

*Koopruns, beste push per rungrootte* — `audit/2026-09-16/poc/OracleLagSandwich.t.sol`, gedraaid 2026-09-16 ~14:20, `maxSlippageBps` 100, winst inclusief 0,05 EURC beloning:

| Run (EURC) | Chainlink cbBTC/USD | Beste push (EURC) | Winst aanvaller | Verlies slachtoffer |
|---|---|---|---|---|
| 2.500 | actueel | 6.000 | +5,16 EURC | 16.803 sats (≈11 EURC) |
| 4.000 | actueel | 4.500 | +8,92 EURC | 20.215 sats (≈13 EURC) |
| 5.000 | actueel | 3.500 | +9,56 EURC | 19.646 sats (≈13 EURC) |
| 2.500 | 0,3% te hoog | 9.000 | +9,00 EURC | 27.153 sats (≈18 EURC) |
| 5.000 | 0,3% te hoog | 6.250 | +18,71 EURC | 37.619 sats (≈25 EURC) |
| 8.000 | 0,3% te hoog | 3.250 | +17,49 EURC | 31.183 sats (≈21 EURC) |

"0,3% te hoog" simuleert een Chainlink-feed die legitiem achterloopt: de cbBTC/USD-feed op Base heeft volgens de Chainlink-directory een deviation-drempel van 0,3% en een heartbeat van 1.200 s. EURC/USD heeft 0,1% en 3.600 s.

**Gevolg.** Elke run vanaf ongeveer 2.500 EURC lekt in deze metingen 0,2–0,7% naar wie als eerste `execute` aanroept. Dat herhaalt zich elk interval, en de app-keeper draait op vaste momenten, dus de timing is voorspelbaar. Base heeft geen publieke mempool, maar dat helpt hier niet: de aanvaller ís de aanroeper.

**Fix (nieuwe contractversie, niet getest).**
1. Voeg `observe()` toe aan `IUniswapV3Pool` en vergelijk vóór de swap per pool de huidige tick met een korte TWAP (5–10 min, ±10 bps). Een push binnen dezelfde transactie verandert de TWAP niet.
2. Houd de check TWAP ↔ Chainlink op 50 bps en baseer `expectedOut` op de TWAP-prijs.
3. Controleer eerst `observationCardinality` van beide pools (`0x7279…66fB` en `0xfBB6…43ef`). Die moet groot genoeg zijn om het TWAP-venster te dekken; anders revert `observe()`. Vuistregel: minstens het aantal blokken met een swap in dat venster. Op Base (2 s per blok) is 10 minuten maximaal 300 blokken. De oracle-checklist las voor EURC/USDC on-chain 200; niet opnieuw gemeten, en USDC/cbBTC niet bekeken. Verhoog zo nodig met `increaseObservationCardinalityNext`.

Alleen `MAX_SPOT_DEVIATION_BPS` verlagen werkt niet: de feeds mogen samen tot ~0,4% achterlopen, dus dan reverten eerlijke runs.

---

### L-A (Low) — `owners` en `dueOwners` reverten bij een grote `limit`

**Waar:** `src/Rebalancer.sol:248` (`owners`) en `:287` (`dueOwners`): `Math.min(offset + limit, total)`.
**Gevonden door:** periphery, boundary, execution-trace, first-principles.

Met `offset ≥ 1` en `limit = type(uint256).max` overflowt `offset + limit` en revert de call met Panic 0x11. De NatSpec van `dueOwners` belooft "Revert nooit". De huidige keepers gebruiken een begrensde paginagrootte (`keeper/keeper.ts:47`, env `PAGE_SIZE`, standaard 50; `app/Console/Commands/RunKeeperCommand.php:149`) en worden niet geraakt; een toekomstige integratie die "alles" vraagt wel.
**Fix:** `uint256 end = limit > total - offset ? total : offset + limit;` (na de bestaande `offset >= total`-check).

### L-B (Low) — Fee-ondergrens geldt niet voor verkopen

**Waar:** `MIN_TRADE_FLOOR` (`src/Rebalancer.sol:74-78`), `_sell` → `_takeFee(received, …)` (`:566`).
**Gevonden door:** math-precision, numerical-gap, asymmetry, invariant, first-principles.

De NatSpec belooft dat de fee van de kleinste run (20 EURC × 25 bps = 0,05 EURC) precies de keeper-beloning dekt. Bij een koop klopt dat: de fee wordt berekend over het bruto-inputbedrag. Bij een verkoop wordt de ondergrens gecontroleerd op de Chainlink-waarde, maar de fee berekend over `received`, dus na poolfees en slippage. Rekenvoorbeeld: waarde 20,000160 EURC, `received` 19,980160 EURC → fee 49.950 < 50.000 → de aanroeper krijgt de hele fee en de treasury 0. Het gaat om stofbedragen.
**Fix:** fee over `max(received, expectedOut)`, of de ondergrens controleren op `received`, of de NatSpec corrigeren.

### L-C (Low) — `isDue` meldt een grotere run dan `execute` uitvoert

**Waar:** `_dueAt` (`src/Rebalancer.sol:312`) geeft `correctionEurc` terug; `execute` handelt `amountIn` (`:502`, `:508`), dat wél begrensd is door saldo en allowance.
**Gevonden door:** numerical-gap, trust-gap.

Voorbeeld: wallet 10.000 EURC, correctie 1.000 EURC, allowance 20 EURC → `isDue` meldt 1.000 EURC, `execute` handelt 20 EURC. Beide keepers filteren op dit getal: `runSizeSkipReason` in `keeper/keeper.ts:111` (env `MIN_RUN_EURC`, standaard 20) en een inline `isLessThan($floor)` in `app/Console/Commands/RunKeeperCommand.php:232` (grens `config/bitburo.php:203`, `BITBURO_REBALANCER_MIN_RUN_EURC`, standaard 20). Zolang die grens gelijk is aan `MIN_TRADE_FLOOR` heeft dit geen effect. Wordt hij verhoogd, dan laten beide keepers runs door die ze juist wilden overslaan.
**Fix:** `eurcDelta` afleiden van `amountIn` (bij verkoop: `amountIn × price / 1e8`).

---

## Leads (met de hand nalopen)

1. **Pool-feetier niet afgedwongen in de constructor** (periphery, boundary, asymmetry, invariant, first-principles, execution-trace, trust-gap). `_poolOrder` (`:208`) controleert alleen token0/token1, niet `fee() == POOL_FEE` of `factory.getPool(…, 500)`. Bij een verkeerde pool bewaakt de spotcheck een pool waar de swap niet doorheen gaat. Met `cast` on-chain nagekeken: de pools in `script/Deploy.s.sol` zijn de 0,05%-pools van dezelfde factory als SwapRouter02. Het huidige deployscript is dus goed; dit is hardening. Fix: beide checks in de constructor.
2. **Eén push, meerdere slachtoffers** (oracle-checklist). Na één push `execute` aanroepen voor meerdere due owners telt hun volumes op, zodat kleine wallets samen de winstgevende grootte van M-1 halen. Niet getest.
3. **Donatie over de bandgrens** (numerical-gap, trust-gap). `_plan` rekent met live `balanceOf(owner)`. Voorbij de band corrigeert het de hele afwijking (`:491`), niet alleen het deel buiten de band. Een kleine donatie duwt een owner die net binnen de band zit erover, en de aanvaller kiest zo zelf het blok voor M-1. Extra winst boven M-1 is niet bewezen.
4. **Eerlijke runs reverten zonder aanvaller** (math-precision). De feeds mogen samen ~0,4% van de markt afwijken. De post-swap-check telt daar de eigen prijsimpact van de run bij op, dus grote runs kunnen boven 50 bps komen en met `SpotDeviatesFromOracle` falen tot de feed bijwerkt. Geen verlies, wel uitval; hoe vaak dit gebeurt is niet gemeten.
5. **Oracle mogelijk deels gebaseerd op DEX-prijzen** (oracle-checklist). De Chainlink-directory labelt beide feeds als `dex_state_price`. Als daar de Base EURC/USDC-pool in zit, controleert de oracle deels zichzelf. Navragen bij Chainlink.
6. **Geen absolute min/max op feed-antwoorden** (oracle-checklist). Alleen relevant als een feed eerst ernstig faalt.
7. **Voorkruipen van `setParams`/`approve(0)`** (invariant). Een run op de oude parameters vlak vóór een wijziging van de gebruiker. Base ordent transacties first-come-first-served via een private sequencer, dus gericht voorkruipen is onbewezen.
8. **Tijdelijke DoS via spot-push** (economic-security). Dit is L-3 uit het vorige rapport. Nieuw is de kostenraming: de aanvaller heeft ~8.000 EURC kapitaal nodig om de EURC/USDC-pool 0,5% te duwen, maar verliest daarbij alleen ~8 EURC aan poolfees (plus eventueel arbitrageverlies) omdat hij het kapitaal terugkrijgt.
9. **Registratiespam tegen keeper-slots** (boundary, trust-gap). `_owners` groeit per nieuw adres en krimpt nooit; elke pagina van `dueOwners` doet per actieve owner tot drie token-calls. `RunKeeperCommand` rouleert zijn startoffset (`RunKeeperCommand.php:144`), en `keeper.ts` scant alle owners. H-2 ging in het vorige rapport over uithongering van de CRE-wekker; die bestaat niet meer, maar hetzelfde risico geldt voor deze twee keepers. Met de offset-rotatie lijkt structurele uithongering afgedekt; de kosten bij veel spam-adressen zijn niet gemeten.
10. **`_spotOut` deelt door 0 bij `sqrtPriceX96 < 2^48`** (periphery). `:419-420`. Niet bereikbaar met de huidige pools; wel een valkuil bij hergebruik voor andere tokenparen.

## Opgemerkt, geen impact

- `setParams(active = false)` moet nog geldige params meesturen (access-control, asymmetry). De owner kan zijn opgeslagen params meesturen en zit dus niet vast.
- Na `retire` kan een nieuw adres zich nog registreren (asymmetry). `execute` revert dan al, en reads zijn gepagineerd.
- Treasury op de Circle-blacklist: de fee blijft in het contract en `sweep` revert tot de blacklist is opgeheven (access-control, periphery). Geen verlies voor gebruikers; zie M-6.
- Een trade afdwingen of de richting omdraaien met een donatie kost de aanvaller meer dan het slachtoffer verliest (access-control, economic-security, periphery, first-principles).

## Gecontroleerd en in orde

- **Chainlink:** `answer > 0`, `updatedAt` niet in de toekomst, `MAX_AGE_CBBTC` 1.500 s ≥ heartbeat 1.200 s, `MAX_AGE_EURC` 4.500 s ≥ heartbeat 3.600 s, 8 decimals afgedwongen, sequencer-uptime + 1 uur grace period. `answeredInRound` ontbreekt terecht (door Chainlink afgeschaft).
- **Fee-boekhouding:** beloning + treasury + achtergehouden = fee; `trySafeTransfer` is niet te laten falen door de aanroeper met weinig gas.
- **`received` bij verkoop:** het balansverschil klopt, ook als er nog achtergehouden fee in het contract zit.
- **Reentrancy:** `sweep` en `execute` delen dezelfde transient lock; EURC, USDC en cbBTC hebben geen transfer-hooks.
- **SwapRouter02-sentinels:** `amountIn = 0` en ontvanger `address(1)`/`address(2)` zijn onbereikbaar.
- **Tegengestelde pushes op beide pools:** leveren geen winst op, omdat het slachtoffer via beide pools handelt.
- **Prijsrekenwerk in `_spot`/`_spotOut`:** richting en precisie kloppen voor de tokenvolgorde op Base (EURC < USDC < cbBTC).
- **Afronding in `_plan`:** geen oversell (verkoop begrensd op saldo) en geen overshoot van het doel.
- **`retire`:** kan alleen stoppen, geen fondsen bewegen.

## Fuzzing

**Echidna 2.3.3 (foundry-modus)** op `RebalancerInvariantTest` in `test/Rebalancer.t.sol`: vier runs, geen bruikbaar resultaat. Configs in `audit/2026-09-16/echidna/`.
- **Proefrun** met `allContracts` en de standaardlimiet van 50.000 calls: alle invariants groen, maar te kort.
- **`allcontracts.yaml`:** 2 miljoen calls, 106 van 590 contractregels geraakt. Twee invariants braken (`invariant_contractNeverHoldsBalance`, `invariant_ownerBalancesOnlyMoveThroughExecute`), maar alleen doordat Echidna `MockERC20.mint` rechtstreeks aanriep, buiten de ghost-boekhouding van `RebalancerHandler` om. Fout in de testopzet, geen bug.
- **Whitelist, twee runs:** de eerste whitelist bevatte alleen de handler-functies en sloot daardoor ook de invariants uit (`tests: 0/0`). De tweede, `whitelist.yaml`, bevat ook de invariants: alle 5 groen, maar maar 3 contractregels geraakt, dus de handler werd niet echt aangeroepen. Uitkomst ongeldig.

Voor Echidna of Medusa is een eigen property-harness nodig. pashov `fizz` kan er een genereren.

**Foundry invariants, diep:** alle 5 invariants in `RebalancerInvariantTest` groen, ~11.000 calls per handler-functie, geen onverwachte reverts (standaard staat 64 runs × depth 32 in `foundry.toml`).

## Reproduceren

Alle commando's vanuit de root van `bitburo-contracts`.

- **Forge-pad:** `forge` op het PATH is Laravel Forge; gebruik `~/.foundry/bin/forge`.
- **Fork-tests:** gebruiken `BASE_RPC_URL`, met terugval op `https://mainnet.base.org` (die is rate-limited). Ze forken het laatste blok, dus de getallen verschuiven per run.

```bash
# Tests en diepe invariants
~/.foundry/bin/forge test
FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=100 ~/.foundry/bin/forge test --match-contract RebalancerInvariantTest

# Statische analyse
PATH="$HOME/.foundry/bin:$PATH" slither src/Rebalancer.sol --compile-force-framework foundry --filter-paths 'lib/|test/|script/' > audit/2026-09-16/slither.txt 2>&1
aderyn . -i src -o audit/2026-09-16/aderyn.md

# M-1: verkoop-sweep (staat al in test/)
~/.foundry/bin/forge test --match-contract OracleSandwichTest --match-test test_poc_sweepSell -vv

# M-1: koopruns met en zonder achterlopende feed (tijdelijk naar test/ kopiëren)
cp audit/2026-09-16/poc/OracleLagSandwich.t.sol test/
~/.foundry/bin/forge test --match-contract OracleLagSandwichTest -vv
rm test/OracleLagSandwich.t.sol

# Echidna (vereist Slither en crytic-compile). Schrijft crytic-export/ en echidna-corpus/ in de root;
# die staan niet in .gitignore, dus ruim ze daarna op.
PATH="$HOME/.foundry/bin:$PATH" echidna . --contract RebalancerInvariantTest --config audit/2026-09-16/echidna/allcontracts.yaml
rm -rf crytic-export echidna-corpus
```

Output van `OracleLagSandwich.t.sol`, per test:
- `oracle`/`spot`: EURC-basiseenheden (6 decimalen) per cbBTC;
- `run(EURC 6dec)` en `baseline ok`: rungrootte en of de run zonder aanval slaagt;
- `best push`: push in EURC-basiseenheden;
- `victim loss sats`: minder ontvangen cbBTC dan zonder aanval;
- laatste regel: winst van de aanvaller in EURC-basiseenheden.

Let op: `_grid(walletEurc, …)` krijgt de EURC-omvang van de wallet mee, niet de run. Met `targetBps` 8000 en `maxCorrectionBps` 10000 (`_fundVictim` in `test/OracleSandwich.t.sol`) is de run 80% daarvan: `_grid(3_125e6, …)` geeft een run van 2.500 EURC. De testnamen noemen de rungrootte.

Niet opgeslagen meetuitvoer: de volledige fork-logs, de Echidna-coverage (106/590 regels) en de call-aantallen van de diepe invariant-run zijn niet bewaard; herhaal de commando's hierboven om ze opnieuw te meten.

Externe bronnen voor waarden in dit rapport (op 2026-09-16 geraadpleegd, niet in de repo opgeslagen):
- **Compilerbugs:** `https://github.com/argotorg/solidity/blob/develop/docs/bugs.json` en `docs/bugs_by_version.json`.
- **Chainlink-feeds op Base** (heartbeat, deviation, `dex_state_price`): `https://docs.chain.link/data-feeds/price-feeds/addresses?network=base`.
- **`observationCardinality` van de EURC/USDC-pool:** `cast call 0x7279…66fB "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)" --rpc-url $BASE_RPC_URL`, veld 4 (volledig adres in `script/Deploy.s.sol`).

AI-reviews herhalen:
- **pashov:** installeer `github.com/pashov/skills` (gebruikt: commit `c577eb7` in die repo) en vraag "run solidity-auditor on src/Rebalancer.sol". De uitkomst verschilt per run; de makers raden 2–3 runs aan.
- **QuillShield:** volg `plugins/oracle-flashloan-analysis/skills/oracle-flashloan-analysis/SKILL.md` uit `github.com/quillai-network/quillshield_skills` (gebruikt: commit `8bdd3c0`), inclusief de `references/`-map ernaast; hun `install.sh` kopieert die niet mee. Negeer daarbij de verplichte `answeredInRound`-check.

## Status bevindingen 2026-09-15

Nagelopen op 2026-09-16, alleen lezend. De ID's zijn die uit de samenvattingstabel van `audit/2026-09-15/RAPPORT.md`, niet de eigen nummering van de detailrapporten.

**Wat is bekeken**
- **Contract:** `src/Rebalancer.sol` op `development` @ `449ffb4` (regelnummers "src") en `git show f8a6d49:src/Rebalancer.sol`, de bron van het live contract `0xE577…2104` (regelnummers "live").
- **On-chain, read-only** (`cast call` tegen `https://mainnet.base.org`, blok 51.386.261): van het live contract `MIN_TRADE_FLOOR()` = 20e6, `MIN_CORRECTION_BPS()` = 10, `MIN_SLIPPAGE_BPS()` = 60, `MAX_AGE_EURC()` = 4500, `FEED_EURC_USD()` = `0x9867…01e0`, `FEED_DECIMALS()` = 8, `EXECUTE_GAS()` = 1e6, `ownerCount()` = 1; `retired()` revert. Op het oude contract `0xED47…e6e5` heeft de enige owner `0x459E…A497` `active = false` en allowance 0 op EURC en cbBTC.
- **Keepers:** `keeper/keeper.ts` en `keeper/selection.ts` in deze repo, `app/Console/Commands/RunKeeperCommand.php` in de app.
- **App** (`pinheadio/bitburo`, `development` @ `ab97b71`): Privy-commands, `ScheduleRunner`, `SweepExecutionsCommand`, `RebalancerMandateReader`, `resources/js/lib/rebalancer-abi.ts`, `strategy-card.tsx`.
- **Let op:** vrijwel alle app-fixes zitten in `b612102` (#144) en `8588913` (#145). Die staan op `development`, niet op app-`production` (`bbc853a`, release v0.4.1; gecontroleerd met `git merge-base --is-ancestor`). Ook `RunKeeperCommand` zelf (`118e811`, #142) staat nog niet op `production`.
- **Privy:** niets live geverifieerd. Een read-only controle van de policy's vraagt productiesleutels van Privy; die heb ik niet gebruikt.

**Kolom "src / live":** geldt het probleem nog in `src/` op `development` en in het live contract? "n.v.t." = geen contractpunt.

| ID | Titel | Status | Bewijs | src / live | Wat er nog moet gebeuren |
|---|---|---|---|---|---|
| H-1 | Server-signer kan `permit` en 7702-autorisaties tekenen | deels opgelost | App `SetupSwapPolicyCommand.php:147-149`: DENY op `eth_signTypedData_v4` voor EURC/cbBTC (`:226-239`) en voor elk domein op chain 8453 (`:248-261`), DENY op `eth_sign7702Authorization` (`:271-284`); commit `8588913`. Test: `tests/Feature/SetupSwapPolicyCommandTest.php`, controleert alleen de request-body. | n.v.t. | #145 releasen en `bitburo:setup-swap-policy --update` tegen productie-Privy draaien; daarna de live policy read-only nalezen (**niet live geverifieerd**). Structureel: de swap-signer van de user-wallets halen na de cutover; de oude motor (`ScheduleRunner`) bestaat nog. Testgat: geen toets tegen de echte policy-engine. |
| H-2 | Dust-owners hongeren de wekker uit | opgelost (CRE-deel vervallen) | Contract: `MIN_TRADE_FLOOR` en `MIN_CORRECTION_BPS` in `setParams` (src `:78`, `:81`, `:222-231`; live `:83`, `:86`, `:238-239`; commit `69ff682`; on-chain bevestigd). Keepers: roterend scanvenster `RunKeeperCommand.php:283-291` (`b612102`) en ondergrens `:232`; `keeper.ts:94` loopt alle pagina's zonder cap. Tests: `test_setParams_rejectsMinTradeBelowFloor` (`test/Rebalancer.t.sol:214`), `test_dustOwnerCannotRegisterAnymore` (`test/PocFork.t.sol:58`), `test_dueOwners_pagingReachesEveryDueOwner` (`test/Rebalancer.t.sol:1176`), Pest „the scan window rotates every hour…" (`RunKeeperCommandTest.php:130`). | nee / nee | App-keeper releasen (#142/#144). Kosten bij massale registratiespam niet gemeten (lead 9). |
| M-1 | Aanroeper sandwicht zijn eigen run | open | Post-swap-check `_requireSpotNear` (src `:539`, `:564`; live `:560`, `:585`; commit `69ff682`) verkleint de winst, maar de fork-metingen in [M-1](#m-1-medium-bevestigd-nog-open--aanroeper-kan-zijn-eigen-execute-winstgevend-sandwichen) tonen nog tot +18,71 EURC. `test_poc_sweepSell` (`test/OracleSandwich.t.sol:331`) meet zonder asserts; `test_fork_lossPerRunBoundedUnderSpotPush` (`:231`) bewaakt alleen de verliesgrens. | ja / ja | TWAP-check in de nieuwe contractversie, zie stap 2 hieronder. |
| M-2 | EURC/USD-feed van 24 uur, niet meer gelist | opgelost | `script/Deploy.s.sol:28` gebruikt `0x9867…01e0` (`9011434`, `69ff682`); `MAX_AGE_EURC` 4.500 s (src `:90`, live `:102`); decimals-check (src `:198-199`, live `:213-214`). On-chain: live `FEED_EURC_USD()` = `0x9867…01e0`. Tests: `test_fork_feedsAreFreshAndMatchConstants` (`test/RebalancerFork.t.sol:107`), `test_fork_feedCadenceWithinMaxAge` (`:135`, `319558b`). | nee / nee | — |
| M-3 | `EXECUTE_GAS` te krap | vervallen | Alleen CRE: `onReport` en `EXECUTE_GAS` uit `src/` in `a798bde` (#12), workflow weg in `e523548` (#2). Live heeft nog `onReport` met `EXECUTE_GAS` 1e6 (live `:90`, `:367`), maar geen workflow roept het aan. Gas per run nog gemeten in `test_fork_buyAndSellGasCost` (`test/RebalancerFork.t.sol:172`). | n.v.t. / dood oppervlak | — |
| M-4 | Owners die altijd reverten blijven due | opgelost (in de wekkers) | Het contract onthoudt mislukkingen bewust niet (src `:275-277`; `lastAttemptAt` was CRE-only, weg in `a798bde`). `keeper.ts` simuleert en houdt een verdubbelende cool-down bij (`selection.ts:53-63`, `e149b96`); de app simuleert (`RunKeeperCommand.php:247`) en pauzeert na 3 mislukkingen (`:314`). Tests: `test_execute_revertsWhenOwnerBlacklisted` (`test/Rebalancer.t.sol:1002`), `keeper/selection.test.ts:48`, Pest `RunKeeperCommandTest.php:302`, `:325`. | gedrag blijft, wekkers vangen het af / idem | App-keeper releasen. De paginalus in `keeper.ts` zelf is ongetest. |
| M-5 | Kleine wallets kunnen niet verkopen | opgelost | `Math.Rounding.Ceil` (src `:507`, live `:528`; `69ff682`). Tests: `test_poc_smallWalletCanSellWithNonRoundPrice` (`test/AuditMath.t.sol:291`), `testFuzz_isDue_matchesCorrectionAtAnyPrice` (`test/Rebalancer.t.sol:1569`). | nee / nee | — |
| M-6 | Treasury op de blacklist blokkeert alles | opgelost (contract) | `trySafeTransfer` + `FeeRetained` (src `:578-586`, live `:603-606`; `69ff682`), `sweep` haalt het op (src `:351-354`). Tests: `test_execute_continuesWhenTreasuryBlacklistedAndSweepRecoversFee` (`test/Rebalancer.t.sol:808`), `test_poc_blacklistedTreasuryNoLongerBricksExecute` (`test/AuditMath.t.sol:250`). | nee / nee | Operationeel deel (treasury-sleutel in hardware wallet of multisig) is niet uit de code vast te stellen. |
| M-7 | Server dicteert de mandaat-params | deels opgelost | `MANDATE_LIMITS` en `mandateLimitViolation` in `resources/js/lib/rebalancer-abi.ts:90-140`; `encodeSetParams` weigert een actief mandaat buiten de grenzen (`:151-157`); commit `8588913`. Tests: Vitest „keeps an out-of-range active mandate from being encoded at all" (`rebalancer-abi.test.ts:158`), browser „refuses to sign settings outside the safe bounds and says why" (`tests/Browser/StrategyTest.php:307`). | n.v.t. | De defaults komen nog als server-prop (`strategy-card.tsx:759-766`): binnen de grenzen kiest de server nog steeds. Geen servervalidatie. #145 releasen. |
| M-8 | Oude mandaten blijven na een redeploy actief en onzichtbaar | deels opgelost | App leest en trekt mandaten op `legacy_addresses` in (`config/bitburo.php:205`, `RebalancerMandateReader.php:25-27`, `:117`; `8588913`); tests `WalletControllerTest.php:890`, `:944`, `:962` en `StrategyTest.php:542`. Oud contract `0xED47…e6e5`: on-chain ingetrokken (zie boven). Draaiboek in `README.md` („Contract buiten gebruik stellen") en `retire()` (src `:369-374`, `f866f20`). `WORKFLOW_OWNER`-deel vervallen (`a798bde`). | `retire` aanwezig / geen `retire` | #145 releasen en `BITBURO_REBALANCER_LEGACY_ADDRESSES` in productie zetten (niet te controleren). `retire` komt pas live met een nieuwe deploy (issue #7). |
| M-9 | Geen pauzeknop, runbook of alerting; twee motoren tegelijk | deels opgelost | Wederzijdse uitsluiting: `ScheduleRunner.php:248-285` (`hasActiveMandate`), tests `ScheduleRunnerTest.php:454`, `:470`. Alert op koersafwijking > 1% en output < 98,5%: `SweepExecutionsCommand.php:76`, `:83`, `:325-345`, tests `SweepExecutionsCommandTest.php:585`, `:604`. Keeper-alerts per e-mail (app-`README.md`, „Alerting per e-mail"). Noodstop `retire()` alleen in src. Alles in de app via `b612102`/`8588913`. | noodstop aanwezig / geen noodstop | Nieuwe deploy voor `retire`. App releasen. Een incident-runbook (wie doet wat, communicatie) heb ik in geen van beide READMEs gevonden. |
| L-1 | `minTradeEurc` zonder ondergrens | opgelost | `MIN_TRADE_FLOOR` (src `:78`, live `:83`) en `NoOutput` (src `:538`, live `:559`); `69ff682`. Tests: `test_setParams_rejectsMinTradeBelowFloor` (`test/Rebalancer.t.sol:214`), `test_execute_revertsNoOutputWhenBuyYieldsZero` (`:958`), `test_poc_microRunNoLongerPossible` (`test/AuditMath.t.sol:270`). | nee / nee | — |
| L-2 | `MIN_SLIPPAGE_BPS` 30 te laag | opgelost | `MIN_SLIPPAGE_BPS = 60` (src `:72`, live `:77`; on-chain 60). Tests: `test_execute_minSlippageCoversSpotDeviationPlusPoolFees` (`test/Rebalancer.t.sol:938`), `test_poc_minSlippageBelowSpotDeviationPlusPoolFees` (`test/AuditMath.t.sol:231`). | nee / nee | — |
| L-3 | DoS door de spot > 0,5% te duwen | open | `_requireSpotNear` (src `:401-405`) leest nog `slot0` (`:418`); geen TWAP. `test_fork_spotDeviationBlocksRun` (`test/RebalancerFork.t.sol:75`) test alleen de revert. Kostenraming in lead 8. | ja / ja | Meenemen met de TWAP-fix van M-1. |
| L-4 | Geen `decimals()`-check op de feeds | opgelost | src `:198-199`, live `:213-214` (`69ff682`); on-chain `FEED_DECIMALS()` = 8. Test: `test_constructor_rejectsFeedWithWrongDecimals` (`test/Rebalancer.t.sol:1378`). | nee / nee | — |
| L-5 | Workflow negeert `receiverContractExecutionStatus` | vervallen | Alleen CRE; workflow weg in `e523548` (#2). | n.v.t. | — |
| L-6 | Botsing CRE ↔ keeper verbruikt een rapport | vervallen | Alleen CRE (#2, `a798bde`). Twee overgebleven wekkers op dezelfde owner geven een goedkope `NotDue` (`test_execute_revertsNotDue`, `test/Rebalancer.t.sol:468`). | n.v.t. | — |
| L-7 | Keeper-wallet en policy aan dezelfde Privy-quorum | deels opgelost, onzeker | `SetupKeeperQuorumCommand.php:103-142` zet de keeper-wallet onder een eigen key quorum; de policy blijft bij de app-quorum (`8588913`). Tests: `SetupKeeperQuorumCommandTest.php:77`, `:115`, `:131`. Draaiboek in app-`README.md`. | n.v.t. | **Niet live geverifieerd** of het commando in productie is gedraaid; #145 staat niet op `production`. Onzeker of de splitsing sluit: volgens Privy („Update a wallet", docs.privy.io/wallets/wallets/update-a-wallet) mag de owner met zijn handtekening `policy_ids` van de wallet wijzigen, dus de keeper-sleutel kan de policy mogelijk zelf loskoppelen. Navragen bij Privy. |
| L-8 | Event-sync: drie zwakke plekken | deels opgelost | (c) Cursor per contractadres met terugval op het nieuwste geboekte blok: `SweepExecutionsCommand.php:184-217` (`8588913`). (a) Een ondecodeerbaar log wordt nog steeds overgeslagen met een warning (`:265-275`, test `SweepExecutionsCommandTest.php:482`); volgens de docblock (`:58-61`) wordt dat een Sentry-event via `sentry_logs`, productieconfig niet nagekeken. (b) Geen alarm voor een stilliggende sweep of een wallet die > 24 uur in `skipped_recent_execution` blijft (`ReconcileWalletsCommand.php:66-70` telt alleen). | n.v.t. | (a) laten falen in plaats van doorschuiven, (b) alarm bouwen, en releasen. |
| L-9 | Sequencer-feed `startedAt == 0` niet afgevangen | opgelost | src `:382`, live `:403` (`69ff682`). Test: `test_execute_revertsSequencerDownWhenStartedAtZero` (`test/Rebalancer.t.sol:531`). | nee / nee | — |

**Tests gedraaid bij deze controle**
- `RUN_FORK=false ~/.foundry/bin/forge test`: 109 geslaagd, 0 gefaald, 3 overgeslagen.
- `bun test` in `keeper/`: 10 geslaagd.
- App, Vitest `resources/js/lib/rebalancer-abi.test.ts`: 17 geslaagd.
- App, Pest op `SetupSwapPolicyCommandTest`, `SetupKeeperQuorumCommandTest`, `RunKeeperCommandTest`, `ScheduleRunnerTest`, `SweepExecutionsCommandTest` en `WalletControllerTest`: 170 geslaagd, **3 gefaald**, alle drie in `WalletControllerTest`: „the five mandate reads go to the node as one batched request", „an unreadable chain is never cached…" en „the legacy addresses come from a comma separated environment value". Die laatste krijgt `0xED47…e6e5` uit de lokale omgeving waar hij een lege lijst verwacht; de oorzaak van de eerste twee heb ik niet onderzocht.

## Volgende stappen

1. **Openstaande punten uit het rapport van 2026-09-15 afwerken** (zie [Status bevindingen 2026-09-15](#status-bevindingen-2026-09-15)):
   - **Nieuwe contractversie:** M-1 en L-3 (TWAP), en `retire()` live krijgen voor M-8/M-9.
   - **Zonder redeploy:** app-PR's #142, #144 en #145 naar `production` (H-1, H-2, M-4, M-7, M-8, M-9, L-7, L-8 hangen daarvan af); daarna `bitburo:setup-swap-policy --update` en `bitburo:setup-keeper-quorum` in productie en de live Privy-policy's read-only nalezen. Verder L-8 (a) en (b), servervalidatie of ingebakken defaults voor M-7, een incident-runbook voor M-9, en de swap-signer van de user-wallets halen na de cutover (H-1).
   - **Uitzoeken:** of de wallet-owner in Privy de policy kan loskoppelen (L-7), en waarom drie tests in `WalletControllerTest` lokaal falen.
2. **M-1 ontwerpen en fixen** (TWAP-check), op een nieuwe branch vanaf `development` nadat `chore/solc-0.8.37` daarin is gemerged. Voeg een fork-test toe die met asserts aantoont dat de winst van de aanvaller bij elke push ≤ 0 is, ook met een achterlopende feed. Neem `audit/2026-09-16/poc/OracleLagSandwich.t.sol` als basis: verplaats hem naar `test/`, want alleen daar compileert hij (hij importeert `./OracleSandwich.t.sol`). Pas ook de NatSpec (`:33`) en `README.md:41` aan.
3. **L-A, L-B, L-C fixen** in dezelfde contractversie, elk met een test.
4. **Lead 1 (poolcheck in de constructor)** meenemen in dezelfde versie.
5. **Leads 2–10** nalopen en per lead besluiten: fixen, documenteren of verwerpen.
6. **Nieuwe deploy — alleen met uitdrukkelijk akkoord van Arjan (`README.md:123`).** Het live contract `0xE577…2104` heeft dezelfde problemen. Het heeft geen `retire()`, dus het `retire`-draaiboek in `README.md` werkt daar niet (`README.md:14`, `:51`). Buiten gebruik stellen kan alleen doordat elke gebruiker zelf `setParams` met `active = false` en `approve(0)` op EURC en cbBTC stuurt. Lees vóór een nieuwe deploy het draaiboek in issue #7 van `pinheadio/bitburo-contracts` (`README.md:109`). Aandachtspunten:
   - `deploy-mainnet.sh go` weigert zolang `broadcast/` al een deploy bevat (`FORCE_REDEPLOY=1`). `broadcast/` staat in `.gitignore`, dus een verse clone gedraagt zich anders.
   - Na de deploy de app bijwerken: `BITBURO_REBALANCER_ADDRESS`, `BITBURO_REBALANCER_DEPLOY_BLOCK` en het oude adres in `BITBURO_REBALANCER_LEGACY_ADDRESSES` (`config/bitburo.php:200-207`), en `REBALANCER` voor `keeper/keeper.ts`.
7. **Externe audit** op die nieuwe versie, met dit rapport en dat van 2026-09-15 als input.
