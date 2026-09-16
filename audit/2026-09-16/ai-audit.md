# AI-audit Rebalancer — 2026-09-16

Zelf-audit vóór de externe audit. Dit rapport bouwt voort op `audit/2026-09-15/RAPPORT.md`. De ID's H-n, M-n en L-n verwijzen naar de samenvattingstabel van dat rapport; L-A, L-B en L-C zijn nieuw. Let op: de detailrapporten in `audit/2026-09-15/details/` en code-commentaar in de app gebruiken een eigen nummering (bijvoorbeeld `M-01`, `ORC-1`), en Aderyn nummert zijn eigen meldingen ook L-1/L-2. Die vallen niet samen met de ID's in dit rapport.

## Samenvatting

- **In deze ronde één open probleem met verlies voor gebruikers gevonden in `src/`: M-1 (Medium).** Wie `execute` aanroept, kan zijn eigen run nog steeds winstgevend sandwichen. De post-swap-check verkleint de winst, maar sluit hem niet. Bevestigd met fork-tests.
- **Drie kleine punten (Low), zonder verlies:** L-A, L-B, L-C.
- **Compiler van 0.8.28 naar 0.8.37**, zes bekende compilerbugs weg. Het contract werd waarschijnlijk door geen ervan geraakt.
- **Tien leads** om met de hand te controleren, plus wat is gecontroleerd en in orde bevonden.
- **Nog niet gedaan:** nagaan welke punten uit het rapport van 2026-09-15 inmiddels zijn opgelost. Sommige daarvan zitten buiten het contract. H-1 (Privy-policy) lijkt opgelost: `app/Console/Commands/SetupSwapPolicyCommand.php` bevat DENY-regels voor permits en 7702-autorisaties. Of die policy ook live staat, is niet nagekeken. Zie [Volgende stappen](#volgende-stappen).

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

## Volgende stappen

1. **Status van het rapport van 2026-09-15 bijwerken.** Per punt (H-1, H-2, M-1 t/m M-9, L-1 t/m L-9) nagaan of het is opgelost. Deze ronde bevestigde alleen dat M-1 open is. Waar je moet kijken:
   - **Contract (`src/`):** een snelle blik suggereert dat M-2, M-5, M-6, L-1, L-2, L-4 en L-9 zijn opgelost, en dat M-3, L-5 en L-6 (CRE) zijn vervallen met het verwijderen van CRE in v1.1.0. Niet geverifieerd.
   - **Spot-DoS (L-3):** `_requireSpotNear` in `src/Rebalancer.sol:401` en lead 8 hierboven.
   - **Privy-policy's (H-1, L-7):** in de app-repo `app/Console/Commands/SetupSwapPolicyCommand.php`, `SetupBillingPolicyCommand.php` en `SetupKeeperQuorumCommand.php`.
   - **Keepers (H-2, M-4):** `keeper/keeper.ts`, `keeper/selection.ts` en `app/Console/Commands/RunKeeperCommand.php`.
   - **App/frontend (M-7, M-8, M-9, L-8):** de app-repo; zie de detailrapporten in `audit/2026-09-15/details/`.
2. **M-1 ontwerpen en fixen** (TWAP-check), op een nieuwe branch vanaf `development` nadat `chore/solc-0.8.37` daarin is gemerged. Voeg een fork-test toe die met asserts aantoont dat de winst van de aanvaller bij elke push ≤ 0 is, ook met een achterlopende feed. Neem `audit/2026-09-16/poc/OracleLagSandwich.t.sol` als basis: verplaats hem naar `test/`, want alleen daar compileert hij (hij importeert `./OracleSandwich.t.sol`). Pas ook de NatSpec (`:33`) en `README.md:41` aan.
3. **L-A, L-B, L-C fixen** in dezelfde contractversie, elk met een test.
4. **Lead 1 (poolcheck in de constructor)** meenemen in dezelfde versie.
5. **Leads 2–10** nalopen en per lead besluiten: fixen, documenteren of verwerpen.
6. **Nieuwe deploy — alleen met uitdrukkelijk akkoord van Arjan (`README.md:123`).** Het live contract `0xE577…2104` heeft dezelfde problemen. Het heeft geen `retire()`, dus het `retire`-draaiboek in `README.md` werkt daar niet (`README.md:14`, `:51`). Buiten gebruik stellen kan alleen doordat elke gebruiker zelf `setParams` met `active = false` en `approve(0)` op EURC en cbBTC stuurt. Lees vóór een nieuwe deploy het draaiboek in issue #7 van `pinheadio/bitburo-contracts` (`README.md:109`). Aandachtspunten:
   - `deploy-mainnet.sh go` weigert zolang `broadcast/` al een deploy bevat (`FORCE_REDEPLOY=1`). `broadcast/` staat in `.gitignore`, dus een verse clone gedraagt zich anders.
   - Na de deploy de app bijwerken: `BITBURO_REBALANCER_ADDRESS`, `BITBURO_REBALANCER_DEPLOY_BLOCK` en het oude adres in `BITBURO_REBALANCER_LEGACY_ADDRESSES` (`config/bitburo.php:200-207`), en `REBALANCER` voor `keeper/keeper.ts`.
7. **Externe audit** op die nieuwe versie, met dit rapport en dat van 2026-09-15 als input.
