# bitburo-contracts

Het onveranderbare `Rebalancer`-contract van Bitburo op Base mainnet, plus de twee externe wekkers.

De gebruiker geeft het contract een ERC-20-mandaat (allowance) voor EURC en cbBTC en zet zijn eigen instellingen. Het contract rebalancet vanuit de wallet van de gebruiker naar de gekozen verdeling; het geld blijft in de wallet. Bitburo heeft geen sleutel waarmee het instellingen of fondsen kan aanraken; de enige bevoegdheid van de treasury is de eenmalige uitschakelaar `retire()` (zie [Contract buiten gebruik stellen](#contract-buiten-gebruik-stellen)). Ontwerp en besluiten: zie de overdracht (privé artifact, bij Arjan).

## Live op Base mainnet

| Wat | Adres | Vanaf |
|---|---|---|
| Rebalancer (actief) | `0xE577D68948883FDF8e2694e38dF656D2D9CA2104` | blok 51341661, uitgerold vanaf commit `f8a6d49` |
| Rebalancer (oud) | `0xED47…e6e5` | vervangen; blijft permissionless uitvoerbaar zolang gebruikers er een allowance hebben staan |

> **Let op: het live contract dateert van vóór `retire()`.** Het is uitgerold vanaf commit `f8a6d49`; `retire()` kwam er één commit later bij en zit dus niet in de bytecode op de keten. `retired()` aanroepen op `0xE577…2104` revert. Alles wat hieronder over `retire`, `retired`, `ContractRetired` en `AlreadyRetired` staat geldt pas vanaf de eerstvolgende deploy. Tot die tijd is er geen noodstop; zie [Contract buiten gebruik stellen](#contract-buiten-gebruik-stellen).

## Contract-interface

| Functie | Wat |
|---|---|
| `setParams(Params)` | Eigen instellingen zetten of wijzigen. Grenzen: `bandBps` 125–9999 (`MIN_BAND_BPS`, zie hieronder), `minTradeEurc` ≥ `MIN_TRADE_FLOOR` (20 EURC), `maxCorrectionBps` 10–10000, `maxSlippageBps` 60–100, `interval` ≥ 1 uur. Breekt een lopende ronde af (zie [Delen](#grote-correcties-in-delen)). Na `retire` alleen nog met `active = false` (mandaat intrekken); anders `ContractRetired`. |
| `isDue(owner) → (bool, int256)` | Zou `execute` nu iets doen, en hoeveel EURC (+ kopen, − verkopen)? Het bedrag is wat `execute` nu werkelijk zou handelen, dus al begrensd op saldo, allowance en het blokvenster (bij verkopen de te verkopen cbBTC tegen de Chainlink-koers). Tijdens een ronde is dat het volgende deel. Revert nooit; een pool die in dit blok al een observatie schreef, of te weinig ruimte in het blokvenster, geeft `(false, 0)`. Na `retire` altijd `(false, 0)`. |
| `owners(offset, limit) → address[]` / `ownerCount()` | Pagina uit alle geregistreerde owners (ook inactieve); het aantal. Revert nooit, ook niet bij `limit = type(uint256).max`. |
| `dueOwners(offset, limit) → address[]` | Eén call per pagina: de owners die nu due zijn, zelfde regels als `isDue`. Dit is wat de wekkers gebruiken. Alle owners in de lijst delen hetzelfde blokvenster: na één run in een blok is er voor de rest meestal geen ruimte meer. Heeft een pool in dit blok al een observatie, dan is de lijst leeg. Revert nooit, ook niet bij een grote `limit`. Na `retire` altijd leeg. |
| `execute(owner, rewardTo)` | Eén rebalance-stap (een hele correctie of één deel ervan); iedereen mag dit aanroepen. `rewardTo` = contract zelf telt als `address(0)`. Revert vóór de swap met `PoolTouchedThisBlock(pool)` (selector `0x817a53db`) als een pool in dit blok al een oracle-observatie schreef, met `BlockMoveExceeded(pool)` (`0x66356d6d`) als er te weinig ruimte of liquiditeit is of de koers na de swap buiten het blokvenster ligt (beide tijdelijk: volgend blok opnieuw proberen), met `NoOutput` als de koop 0 cbBTC zou opleveren, en met `ContractRetired` na `retire`. |
| `lastExecutedAt(owner) → uint64` | Tijdstip van de laatste geslaagde run, ook van een deel. Een nieuwe ronde kan pas `interval` daarna. |
| `rounds(owner) → (bool isBuy, uint128 remainingEurc)` | Lopende ronde: richting en wat er nog over is van het budget. `remainingEurc = 0` = geen ronde. |
| `sweep(token)` | Stuurt een achtergebleven saldo naar de treasury (per ongeluk gestuurde tokens, of fee die door een mislukte treasury-transfer is blijven staan). Permissionless. Werkt ook na `retire`. |
| `retire()` | Eenmalige, onomkeerbare uitschakelaar. Alleen `TREASURY`; tweede aanroep revert met `AlreadyRetired`. Zet `retired = true` en emit `Retired()`. Kan niets met fondsen of instellingen. |
| `retired() → bool` | Staat het contract buiten gebruik? |
| `quote()` / `spot()` / `quoteChecked()` | Feedkoers; poolspot; feedkoers mét de spot-check van `execute`. Alle drie in EURC-basiseenheden per cbBTC. |

Constanten: `FEE_BPS` 25, `KEEPER_REWARD_EURC` 0,05 EURC, `MIN_TRADE_FLOOR` 20 EURC (fee van de kleinste run = precies de keeperbeloning), `MIN_CORRECTION_BPS` 10, `MIN_BAND_BPS` 125 (= `FEE_BPS` + `MAX_SLIPPAGE_BPS`: een run gebeurt pas bij een afwijking groter dan wat een run maximaal kost, zodat een permissionless aanroeper een wallet niet herhaaldelijk kan laten handelen op kleine koersbewegingen zonder dat de verhouding echt verbetert, en een volledige correctie in één run klaar is; rekenaudit `audit/2026-09-15/details/math.md` I-01), `MIN_SLIPPAGE_BPS` 60 / `MAX_SLIPPAGE_BPS` 100, `MAX_SPOT_DEVIATION_BPS` 50, `MAX_AGE_CBBTC` 1500 s, `MAX_AGE_EURC` 4500 s (uurfeed `0x9867…01e0`), `FEED_DECIMALS` 8 (afgedwongen in de constructor), `POOL_FEE` 500 (0,05%), `TICK_SPACING` 10, `MAX_BLOCK_MOVE_BPS` 6, `SIZING_BPS` 7500 (75%), `CHUNK_INTERVAL` 10 minuten.

De constructor controleert ook de twee pools: tokens (`UnexpectedPoolTokens`), fee-tier gelijk aan `POOL_FEE` (`UnexpectedPoolFee`), tickSpacing gelijk aan `TICK_SPACING` (`UnexpectedTickSpacing`; de runomvang rekent erop, zie hieronder), en dat het precies de pools zijn die `getPool(…, 500)` geeft op de factory van de router (`ROUTER.factory()`, anders `PoolNotFromRouterFactory`). Zo bewaakt de spotcheck gegarandeerd de pools waar de swap doorheen gaat (audit lead 1). Op Base geeft SwapRouter02 `0x2626…e481` factory `0x3312…FDfD`, en die geeft voor beide paren bij fee 500 de pools uit `script/Deploy.s.sol` (op 16 september 2026 met `cast call` gecontroleerd; beide pools en `feeAmountTickSpacing(500)` van die factory geven tickSpacing 10).

### Fee, beloning en maximaal verlies per run

De fee is 25 bps van het EURC-been van elke run: bij kopen over het bruto bedrag, bij verkopen over het hoogste van het werkelijk ontvangen bedrag en de verwachte opbrengst tegen de Chainlink-koers, en nooit meer dan het ontvangen bedrag. Zo dekt ook een verkoop op de vloer van 20 EURC na poolfees en slippage nog de volledige beloning (audit L-B). Daaruit gaat `min(0,05 EURC, fee)` naar `rewardTo`, de rest naar de treasury. Een deel van een ronde is een gewone run: ook daar gaan fee en beloning af, en ook elk deel is minstens `MIN_TRADE_FLOOR`, zodat de fee de beloning dekt. Beide transfers zijn niet-reverterend: faalt de beloning (bijvoorbeeld een geblacklist `rewardTo`), dan gaat de hele fee naar de treasury; faalt de treasury-transfer, dan blijft dat deel in het contract (`FeeRetained(amount)`) en haalt `sweep(EURC)` het later op. De rebalance zelf loopt dus nooit stuk op de fee-ontvanger.

**Het maximale verlies per run ten opzichte van de Chainlink-koers is `FEE_BPS + maxSlippageBps`** (0,85–1,25%). De spot-check hieronder is daar geen extra bovengrens op. **De cap (`maxCorrectionBps`) geldt per ronde, niet per dag**: met `interval` van 1 uur en cap 10% kan een wallet tot 24 × 10% per dag verplaatsen. Een ronde kan in delen gaan, maar samen nooit boven haar budget (zie [Delen](#grote-correcties-in-delen)). Wie een dagcap wil, zet `interval` op een dag.

### Sandwich-bescherming (audit M-1, L-3)

`execute` is permissionless, dus de aanroeper kan in één transactie de pool duwen, `execute` aanroepen en terugduwen. Drie lagen houden dat onrendabel.

**1. Blokcheck en blokvenster per pool.** Een run gebeurt alleen als geen van beide pools in hetzelfde blok al een oracle-observatie schreef: `observations[slot0.observationIndex].blockTimestamp` mag niet gelijk zijn aan de timestamp van het blok. Anders revert `execute` vóór de swap met `PoolTouchedThisBlock(pool)` en melden `isDue` en `dueOwners` niets. Daarbovenop moet de koers vóór én ná de swap binnen `MAX_BLOCK_MOVE_BPS` (6 bp) van de tick aan het begin van het blok liggen, inclusief de eigen swap; anders `BlockMoveExceeded(pool)`.
- **Wat een observatie schrijft** (Uniswap v3-core, commit `d8b1c635`): een swap die de tick verandert (`UniswapV3Pool.sol:732-748`), en een mint of burn met liquiditeit > 0 van een positie waarvan de range de huidige tick bevat (`_modifyPosition`, `:327` en `:336-348`). Hooguit één per blok (`Oracle.sol:90`). Een swap binnen de tick, een mint of burn buiten de range, een burn van 0, `collect` en `flash` schrijven niets. Op de fork per actie bevestigd.
- **Waarom dat sluit.** Zonder observatie in het blok staan tick en in-range liquiditeit nog zoals aan het begin van het blok. Een aanvaller kan in het blok van de run dus hooguit binnen de begintick duwen (≤ 1 tick ≈ 1 bp per pool) en geen JIT-liquiditeit in de range zetten. Dat sluit push-then-JIT uit de review van PR #18 (tot +4,4 bp van de run) en pushes over de tickgrens. De begintick is daardoor ook gewoon `slot0.tick`; de afleiding uit twee observaties, `BlockStartUnknown` en de eis van twee observaties in de constructor zijn weg.
- **Afronding.** De koers binnen de begintick is niet bekend (een swap binnen de tick schrijft niets). Het venster rekent vanaf de ongunstige rand van de tick, dus de afronding kost eerlijke runs hooguit 1 bp ruimte (per richting 5–6 bp) en geeft een aanvaller nooit ruimte.
- **Meerdere runs in één blok** delen hetzelfde venster, maar alleen zolang geen run de tick verandert; daarna is de pool in dat blok aangeraakt en revert de volgende run met `PoolTouchedThisBlock`.
- **Uitval.** Gemeten over 2.000 blokken rond blok 51.390.800 (logs van beide pools, steekproef van 80 blokken tegen `observations` gecontroleerd): 0% van de pogingen valt uit als de transactie bovenaan het blok staat, 4,3% halverwege en 7 tot 11% onderaan. Een geweigerde poging kost een wekker die eerst simuleert geen gas en lukt in een volgend blok. Let op: een `eth_call` op het laatste blok ziet elke activiteit in dát blok ook als aanraking (in 363 van de 2.000 blokken was er activiteit in een van beide pools), dus lees en simuleer opnieuw in een volgend blok.
- **Restrisico: LP met een groot aandeel.** Een aanvaller die in een eerder blok zelf het grootste deel van de actieve liquiditeit minde, krijgt een deel van de poolfee van zijn push binnen de tick terug. Bij de huidige protocolfee (1/4 van de LP-fee naar Uniswap) levert dat geen winst op: gemeten −1,02 bp van de run of slechter bij correcties tot 10.000 EURC. Alleen als Uniswap de protocolfee op 0 zet, is er winst, hooguit ~1 bp van de run per pool; gemeten maximaal +0,80 bp (0,80 EURC op 10.000, LP-aandeel 99%). Bij een run van ~12.300 EURC tegen een LP-aandeel van 95% was ook bij de huidige protocolfee +0,05 bp gemeten (`test_fork_lpAttackerProfitAtCurrentProtocolFee`).
- **Niet gedekt: duwen aan het eind van het vorige blok** (review I-4). Dat ziet de blokcheck niet. Het is niet atomair (arbitrage ertussen) en de spotcheck (laag 3) begrenst het.

**2. Runomvang uit de liquiditeit.** `_plan` schat hoeveel input de koers naar de rand van het venster zou brengen en gebruikt daarvan `SIZING_BPS` (75%). Daarbij rekent het met de kleinste liquiditeit tot die rand (review L-1): de in-range liquiditeit nu, en voorbij de eerstvolgende initialiseerbare tickgrens in de swaprichting de liquiditeit na het kruisen (`liquidityNet` via `ticks()`). Met tickSpacing 10 ligt er binnen het venster per richting hooguit één zo'n grens, dus een `tickBitmap`-lookup is niet nodig. Zo loopt een owner niet meer vast op een positie die net boven of onder de koers ophoudt (vroeger `isDue` true en `execute` in elk blok een revert); de run wordt kleiner. Is er voorbij de grens geen liquiditeit, dan is er geen run. Liquiditeit buiten de range maakt de run nooit groter dan de in-range liquiditeit toelaat; ze kan wel een bestaande klif opheffen (gemeten: een koopdeel van 562 naar 742 EURC, precies tot die grens). Op de fork van blok 51.390.800 is een eerlijk deel 644,7 EURC bij kopen (grens 1420 met `liquidityNet` 1,03e12 ligt in het venster; vóór deze fix 851,4) en 781,3 EURC bij verkopen; een grotere correctie gaat in delen.

**3. Spot tegen Chainlink.** Vóór én ná elke swap moet de spot van beide pools (EURC/USDC `0x7279…66fb`, USDC/cbBTC `0xfbb6…43ef`) binnen `MAX_SPOT_DEVIATION_BPS` (0,5%) van de Chainlink-koers liggen; anders `SpotDeviatesFromOracle`. `amountOutMinimum` volgt uit Chainlink en `maxSlippageBps`, dus het maximale verlies per run ten opzichte van de Chainlink-koers blijft `FEE_BPS + maxSlippageBps`.

**Blokkeren (audit L-3).** Wie de pool meer dan 0,5% van Chainlink duwt en daar houdt, houdt alle runs tegen zolang hij dat volhoudt tegen arbitrage in; daar is niets aan veranderd (`test_poc_dosBySpotPush` laat zien dat de owner weer due is zodra de pool terug is). Nieuw is dat binnen één blok elke swap over de tickgrens (of een mint of burn in de range) al volstaat om runs in dát blok tegen te houden. Dat raakt alleen dat ene blok: de wekker probeert het in het volgende opnieuw, en de aanvaller betaalt elk blok opnieuw de poolfee.

Fork-tests met asserts (`test/BlockWindowFork.t.sol` en `test/BlockWindowReviewFork.t.sol`, gedraaid op 16 september 2026 op blok 51.390.800):
- **Aanvalsraster.** Pushes van 0,5 tot 30 bp en binnen de tick, in één of beide pools, mee en tegen de run in, koop en verkoop, runs van 100 EURC tot op de liquiditeitsgrens, met actuele feeds en met cbBTC/USD 0,3% te hoog. Elke push over de tickgrens wordt geweigerd met `PoolTouchedThisBlock`; geen enkele geslaagde push levert winst op.
- **Review-PoC's.** Push-then-JIT wordt geweigerd, ook met vijf owners na één push. Op de liquiditeitsklif zijn `isDue` en `execute` het in elk blok eens en komt de owner in delen door de klif.
- **Scenario's**, elk voor correcties van 2.000, 5.000 en 10.000 EURC, koop en verkoop (extra winst van de aanvaller ten opzichte van dezelfde opzet zonder push, hoogste waarde):

| scenario | huidige protocolfee | protocolfee 0 |
|---|---|---|
| push-then-JIT (ook twee owners) | geweigerd | geweigerd (de blokcheck hangt niet van de fee af) |
| LP uit een eerder blok (99% of 99,9%) | −1,02 bp | +0,80 bp |
| duwen zonder LP | −0,30 bp | niet van toepassing |
| JIT buiten de range | −0,30 bp | −7,51 bp |
| twee owners in één blok, LP uit een eerder blok | −5,95 bp | +0,45 bp |
| twee owners in één blok, zonder LP | −7,51 bp | niet van toepassing |

- **Eerlijke correctie van 8.000 EURC**, met arbitrage tussen de delen: koop in 12 delen (vóór de klif-fix 9), verkoop in 8 delen, zonder één revert.

### Grote correcties in delen

Is een run door de liquiditeit begrensd en de correctie nog niet klaar, dan opent die run een ronde (`rounds(owner)`):
- **Wanneer.** Het volgende deel mag `CHUNK_INTERVAL` (10 minuten) na de vorige run in plaats van na `interval`, alleen in dezelfde richting.
- **Tot wanneer.** Tot de afwijking binnen de band is, of tot het budget van de ronde op is: `maxCorrectionBps` van de waarde bij de eerste run, minstens `minTradeEurc`. Daarna geldt weer `interval`, gerekend vanaf de laatste run.
- **Afsluiten.** Een run sluit de ronde af als hij volgens een schatting zonder fee de owner binnen de band brengt. Met fee blijft er soms een kleine rest net buiten de band; die wacht op `interval`. Ook een restbudget onder `minTradeEurc` sluit de ronde, en een run die door saldo of allowance begrensd is, opent er geen.

Regels die dit veilig houden (unit-tests in `test/BlockWindow.t.sol`, invariants in `RebalancerInvariantTest*`):
- **Geen ping-pong.** Een richtingswissel start nooit een deel: `NothingToDo` tot `interval` verstreken is.
- **`setParams` breekt een lopende ronde af.**
- **Budget.** Het budget van een ronde ligt vast bij de eerste run. Delen gaan er samen niet boven, ook niet na een donatie aan de owner (audit lead 3). Zo'n donatie kan wel een run over de bandgrens duwen en het moment kiezen, maar met het blokvenster levert dat geen atomaire winst op.
- **Vloer per deel.** Een deel mag kleiner zijn dan `minTradeEurc` (die geldt voor de correctie), maar nooit kleiner dan `MIN_TRADE_FLOOR`. Past er in dit blok minder dan dat, dan is de owner niet due, revert `execute` met `BlockMoveExceeded` (of eerder met `PoolTouchedThisBlock`), en blijft de ronde staan tot er weer ruimte is. Lukt dat niet binnen `interval` na de laatste run, dan begint daarna een nieuwe ronde.
- **Koers brengt de owner binnen de band.** Brengt koersbeweging (geen run) de owner tussen twee delen binnen de band, dan is de ronde on-chain niet afgesloten; daarvoor is een schrijfactie nodig. Raakt hij binnen `interval` na het laatste deel in dezelfde richting weer buiten de band, dan kan er nog een deel volgen, binnen het restbudget.

Gas van `execute` op de fork (16 september 2026, zelfde blok, run van 500 EURC): koop 397k (was 370k vóór het blokvenster), verkoop 425k (was 399k). Een volgend deel in dezelfde test kost ~240k (koop) en ~262k (verkoop), omdat de storage dan warm is. De blokcheck en de klif-fix samen kosten ~7k extra per run (eerste deel op blok 51.390.800: koop 398.654 → 405.660, verkoop 436.590 → 443.652) en 358 bytes runtime-bytecode (16.775 → 17.133). `test_fork_buyAndSellGasCost` bewaakt de grens van 1.000.000, zodat een wekker weet wat hij moet begroten.

### Wekker en mislukte pogingen

Het contract onthoudt mislukte pogingen niet: `lastExecutedAt` wordt alleen bij succes gezet, dus een owner die structureel revert (blacklist, te krappe slippage) blijft due. De wekkers vangen dat zelf op: beide simuleren `execute` eerst en houden een cool-down per owner bij die per opeenvolgende mislukking verdubbelt.

Voor wekkers sinds het blokvenster:
- **Draaifrequentie.** Draai elke 10 minuten, zodat delen van een ronde op tijd worden opgepakt. Let op: start een run steeds precies 10 minuten na de vorige, dan is het vorige deel een paar seconden te kort geleden en schuift het volgende deel een beurt op (in de praktijk 10–20 minuten per deel).
- **Tijdelijke reverts.** `PoolTouchedThisBlock(address)` (`0x817a53db`) en `BlockMoveExceeded(address)` (`0x66356d6d`) zijn tijdelijk. Probeer het in een volgend blok opnieuw en tel ze niet als mislukking voor de cool-down. Hetzelfde geldt voor een transactie die on-chain revert terwijl een nieuwe simulatie op dat blok slaagt.
- **Eén run per blok.** Probeer na een geslaagde run de volgende owner pas in een later blok. Een run die de tick verandert, raakt de pool voor de rest van het blok aan, en een `eth_call` op dat blok meldt de owner dan onterecht als niet due.
- **`dueOwners` is een momentopname.** Een `eth_call` op het laatste blok ziet ook activiteit van anderen in dat blok als aanraking. Lees een pagina daarom in een later blok nog eens en behandel owners die er dan pas in staan.

## Contract buiten gebruik stellen

> **Nog niet beschikbaar op het live contract.** `0xE577…2104` is uitgerold vanaf commit `f8a6d49` en mist `retire()`; dit draaiboek geldt pas vanaf de eerstvolgende deploy. Moet het huidige contract vandaag stil, dan is de enige weg per gebruiker: `setParams` met `active = false` en `approve(0)` op EURC en cbBTC. Dat kan alleen de gebruiker zelf, de treasury niet.

Het contract heeft geen admin, upgrade of pauzeknop, wel één eenmalige en onomkeerbare uitschakelaar: `retire()`, alleen aan te roepen met de sleutel van `TREASURY`. Dit is het antwoord op audit-bevinding M-8/M-9 (oude mandaten die na een redeploy onzichtbaar actief blijven, en het ontbreken van een noodstop). Er is geen weg terug en geen `unretire`.

Wat het doet: `execute` revert daarna met `ContractRetired`, `isDue` geeft `(false, 0)`, `dueOwners` is leeg (de wekkers vinden dus vanzelf niets meer), en `setParams` accepteert alleen nog `active = false`. `sweep` blijft werken om achtergebleven fee op te halen.

Wat het niet kan: fondsen verplaatsen. Het contract houdt nooit gebruikersfondsen; het mandaat is een ERC-20-allowance die in de tokencontracten bij de gebruiker staat en waar `retire` niets aan verandert. Het enige pad dat die allowance ooit gebruikte (`execute`) is na `retire` dicht.

Uitvoeren met de treasury-sleutel (eerst simuleren met `cast call`, dan pas `cast send`):

```bash
cast call <adres> "retire()" --rpc-url https://mainnet.base.org --from <treasury-adres>
cast send <adres> "retire()" --rpc-url https://mainnet.base.org --private-key <treasury-private-key>
cast call <adres> "retired()(bool)" --rpc-url https://mainnet.base.org   # true
```

Daarna in de app: het adres als oud adres registreren (`legacy_addresses` uit audit M-8), zodat gebruikers hun oude mandaat via de app kunnen intrekken. Dat intrekken is `setParams` met `active = false` (werkt na `retire` gewoon; `active = true` revert) en `approve(0)` op EURC en cbBTC voor het oude adres. Beide zijn voor de veiligheid niet nodig — er is niets meer dat de allowance kan gebruiken — maar ze zetten het mandaat op inactief en halen de allowance uit de tokenstate, zodat de wallet ook zonder kennis van `retire` als schoon te lezen is.

## Onderdelen

| Map | Wat |
|---|---|
| `src/Rebalancer.sol` | Het contract. Solidity 0.8.37, OpenZeppelin 5.6.1, via-IR. |
| `audit/` | Interne auditrapporten en PoC's per datum. |
| `src/interfaces/` | Minimale interfaces: Chainlink AggregatorV3, Uniswap v3-pool en -factory, SwapRouter02. |
| `src/libraries/TickMath.sol` | `getSqrtPriceAtTick` uit Uniswap v4-core (MIT, met licentietekst), voor het blokvenster. |
| `test/` | Unit-, fuzz- en invarianttests met mocks; fork-tests tegen Base mainnet. |
| `script/Deploy.s.sol` | Deploy-script met de geverifieerde Base-adressen. |
| `keeper/` | Open keeper-script in TypeScript. Iedereen kan het draaien, zonder Bitburo; de terugvaloptie naast de Laravel-keeper. Zelfde ondergrens, simulatie vooraf en een cool-down per owner na een mislukking. |

### Wekkers

De primaire wekker is `bitburo:run-keeper` in de Bitburo Laravel-app: die pagineert het register via `dueOwners` en wekt iedereen die aan de beurt is. Sinds het blokvenster hoort die elke 10 minuten te draaien en `PoolTouchedThisBlock` en `BlockMoveExceeded` in een volgend blok opnieuw te proberen (zie [Wekker en mislukte pogingen](#wekker-en-mislukte-pogingen)); dat staat nog niet in de app. Het script in `keeper/` is de open terugvaloptie die iedereen zonder Bitburo kan draaien.

Van Chainlink CRE is niets meer over. In v1.1.0 gingen zowel de workflow als het ontvangstoppervlak in het contract eruit: `onReport`, `IReceiver`, `supportsInterface`, de immutables `FORWARDER` en `WORKFLOW_OWNER`, en `lastAttemptAt`. Chainlink Automation is medio 2026 gestopt, CRE Early Access is nooit toegekend en het pad heeft op mainnet geen enkel rapport verwerkt. Dat scheelt 1.604 bytes runtime-bytecode en een hoop uitleg. Wie het terug wil halen, vindt alles onder tag `v1.0.0`. Let op: het oppervlak zit nog wél in elk uitgerold contract van vóór v1.1.0, dus ook in `0xE577…2104`.

## Commando's

Foundry staat in `~/.foundry/bin` (het `forge` in PATH kan de Laravel Forge CLI zijn).

```bash
~/.foundry/bin/forge build
~/.foundry/bin/forge test -vv                      # unit + fuzz + invariant + fork (BASE_RPC_URL optioneel)
FORK_BLOCK=<blok> ~/.foundry/bin/forge test --match-path test/BlockWindowFork.t.sol -vv   # M-1-metingen op een vast blok
~/.foundry/bin/forge test --gas-report --match-contract RebalancerFork
RUN_FORK=false ~/.foundry/bin/forge test              # zonder fork
~/.foundry/bin/forge test --no-match-path "test/RebalancerFork.t.sol"   # idem, zonder RPC-aanroep
```

| Testbestand | Contracten | Wat |
|---|---|---|
| `test/Rebalancer.t.sol` | `RebalancerTest`, `RebalancerInvariantTest`, `RebalancerInvariantTestNoRetire` (basis `RebalancerTestBase`) | Unit- en fuzztests met mocks (params, rekenregel, fee, sweep, retire, constructor) en de invariants. |
| `test/BlockWindow.t.sol` | `BlockWindowTest` | Unit: blokcheck, blokvenster, runomvang en delen uit audit M-1. |
| `test/BlockWindowFork.t.sol` | `BlockWindowForkTest`, `BlockWindowAttackForkTest`, `BlockWindowChunksForkTest`, `BlockWindowLpForkTest` | Fork: aanvalsrasters, twee owners in één blok, eerlijke correctie in delen, LP-aanvaller. |
| `test/BlockWindowReviewFork.t.sol` | `BlockWindowReviewForkTest` | Fork: de PoC's en scenario's uit de review van PR #18 als asserts. |
| `test/OracleSandwich.t.sol` | `OracleSandwichTest` (basis `OracleSandwichBase`) | Fork: sandwich-PoC's uit de audit van 15 september 2026, omgeschreven naar bewijs van de fix, en `test_poc_dosBySpotPush`. |
| `test/OracleLagSandwich.t.sol` | `OracleLagSandwichTest` (basis `OracleSandwichBase`) | Fork: sandwich per rungrootte, met cbBTC/USD 0,3% te hoog; stond als meting in `audit/2026-09-16/poc/`. |
| `test/RebalancerFork.t.sol` | `RebalancerForkTest` | Fork: koop en verkoop tegen de echte pools en feeds, gasgrens van `execute`, spotcheck. |
| `test/PocFork.t.sol` | `PocFork` | Fork: PoC's uit de audit van 15 september 2026. |
| `test/AuditMath.t.sol` | `AuditMathTest` | Fuzz-, invariant- en PoC-tests voor de rekenkunde van `_plan`, `_buy`, `_sell` en `_takeFee`, uit de audit van 15 september 2026. |
| `test/mocks/` | – | Mocks voor tokens, feeds, pool, factory en router. |

`test/AuditMath.t.sol`, `test/PocFork.t.sol` en `test/OracleSandwich.t.sol` komen uit de interne audit van 15 september 2026; `audit/2026-09-15/poc/README.md` zegt per bestand wat ervan is overgenomen en wat is omgeschreven van bewijs-van-lek naar bewijs-van-fix. Het `test/CrePoC.t.sol` dat daar genoemd wordt, is met het CRE-oppervlak verwijderd (v1.1.0, commit `a798bde`). Let op bij tijdreeksen onder `via_ir`: Solidity cachet `block.timestamp` binnen een testfunctie, gebruik na `vm.warp` dus `vm.getBlockTimestamp()`.

Deployen naar Base mainnet:

```bash
cast wallet import bitburo-deployer --interactive     # eenmalig, zet de sleutel in een keystore
DEPLOYER_ACCOUNT=bitburo-deployer bash deploy-mainnet.sh dry
DEPLOYER_ACCOUNT=bitburo-deployer bash deploy-mainnet.sh go
DEPLOYER_ACCOUNT=bitburo-deployer bash deploy-mainnet.sh verify
```

`go` weigert zolang er al een deploy in `broadcast/` staat: een tweede run zet een tweede, los contract op mainnet terwijl gebruikers hun allowance op het oude adres houden. Wil je dat echt, dan `FORCE_REDEPLOY=1`, en lees eerst het draaiboek in issue #7. `verify` weigert zolang je op een andere commit staat dan die is uitgerold, of zolang `src/` of `script/` ongecommitte wijzigingen heeft; Basescan kan de bytecode anders niet matchen. Zonder keystore werkt `DEPLOYER_PRIVATE_KEY` nog steeds, maar dan staat de sleutel in de procestabel.

Keeper-script (vanuit `keeper/`):

```bash
bun install
RPC_URL=https://mainnet.base.org REBALANCER=0x… DRY_RUN=1 bun run keeper.ts
bun test            # selectie- en cool-down-logica
```

Het script leest per due owner `isDue`, slaat runs onder `MIN_RUN_EURC` (standaard 20 EURC) over, simuleert `execute` eerst met `eth_call` en stuurt pas daarna de transactie. Een owner waarvan de simulatie of de transactie mislukt krijgt een cool-down die per opeenvolgende mislukking verdubbelt (`COOLDOWN_SECONDS`, standaard 3600 s, tot `COOLDOWN_MAX_SECONDS`, standaard 86.400 s), bijgehouden in `COOLDOWN_FILE` (standaard `./keeper-cooldowns.json`, staat in `.gitignore`). Zo blijft een owner die structureel revert (het contract zet `lastExecutedAt` alleen bij succes) niet elke run gas kosten. Een tijdelijke revert (`PoolTouchedThisBlock`, `BlockMoveExceeded`, of een on-chain revert waarvan de hersimulatie slaagt) telt daar niet voor: het script probeert die owner opnieuw in een volgend blok, tot `BLOCK_RETRIES` keer (standaard 3), en wacht daarbij hooguit `BLOCK_WAIT_SECONDS` (standaard 30) op een nieuw blok. Na een geslaagde run leest en simuleert het de volgende owner pas in een later blok. Elke `dueOwners`-pagina leest het minstens twee keer in opeenvolgende blokken, en daarna zolang er nieuwe owners bijkomen (hooguit `BLOCK_RETRIES` + 1 keer), zodat een owner die door een aangeraakte pool niet due leek in dezelfde run alsnog aan de beurt komt. Draai het elke 10 minuten (bijvoorbeeld cron `*/10`). Het script heeft geen gascap.

## Vaste regels

- Nooit uitrollen op mainnet zonder uitdrukkelijk akkoord van Arjan.
- Geen sleutels of `.env`-bestanden in git. De gitleaks-hook moet slagen.
- Contractwijzigingen altijd met tests, ook de fork-tests.
