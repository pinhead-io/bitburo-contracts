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
| `setParams(Params)` | Eigen instellingen zetten of wijzigen. Grenzen: `minTradeEurc` ≥ `MIN_TRADE_FLOOR` (20 EURC), `maxCorrectionBps` 10–10000, `maxSlippageBps` 60–100, `interval` ≥ 1 uur. Breekt een lopende ronde af (zie [Delen](#grote-correcties-in-delen)). Na `retire` alleen nog met `active = false` (mandaat intrekken); anders `ContractRetired`. |
| `isDue(owner) → (bool, int256)` | Zou `execute` nu iets doen, en hoeveel EURC (+ kopen, − verkopen)? Het bedrag is wat `execute` nu werkelijk zou handelen, dus al begrensd op saldo, allowance en het blokvenster (bij verkopen de te verkopen cbBTC tegen de Chainlink-koers). Tijdens een ronde is dat het volgende deel. Revert nooit; een vol blokvenster of een onbekende beginkoers geeft `(false, 0)`. Na `retire` altijd `(false, 0)`. |
| `owners(offset, limit) → address[]` / `ownerCount()` | Pagina uit alle geregistreerde owners (ook inactieve); het aantal. Revert nooit, ook niet bij `limit = type(uint256).max`. |
| `dueOwners(offset, limit) → address[]` | Eén call per pagina: de owners die nu due zijn, zelfde regels als `isDue`. Dit is wat de wekkers gebruiken. Alle owners in de lijst delen hetzelfde blokvenster: na één run in een blok is er voor de rest meestal geen ruimte meer. Revert nooit, ook niet bij een grote `limit`. Na `retire` altijd leeg. |
| `execute(owner, rewardTo)` | Eén rebalance-stap (een hele correctie of één deel ervan); iedereen mag dit aanroepen. `rewardTo` = contract zelf telt als `address(0)`. Revert met `BlockMoveExceeded(pool)` als een pool vóór of na de swap te ver van zijn koers aan het begin van het blok ligt of er te weinig ruimte over is (tijdelijk: volgend blok opnieuw proberen), met `BlockStartUnknown(pool)` als die beginkoers niet vast te stellen is, met `NoOutput` als de koop 0 cbBTC zou opleveren, en met `ContractRetired` na `retire`. |
| `lastExecutedAt(owner) → uint64` | Tijdstip van de laatste geslaagde run, ook van een deel. Een nieuwe ronde kan pas `interval` daarna. |
| `rounds(owner) → (bool isBuy, uint128 remainingEurc)` | Lopende ronde: richting en wat er nog over is van het budget. `remainingEurc = 0` = geen ronde. |
| `sweep(token)` | Stuurt een achtergebleven saldo naar de treasury (per ongeluk gestuurde tokens, of fee die door een mislukte treasury-transfer is blijven staan). Permissionless. Werkt ook na `retire`. |
| `retire()` | Eenmalige, onomkeerbare uitschakelaar. Alleen `TREASURY`; tweede aanroep revert met `AlreadyRetired`. Zet `retired = true` en emit `Retired()`. Kan niets met fondsen of instellingen. |
| `retired() → bool` | Staat het contract buiten gebruik? |
| `quote()` / `spot()` / `quoteChecked()` | Feedkoers; poolspot; feedkoers mét de spot-check van `execute`. Alle drie in EURC-basiseenheden per cbBTC. |

Constanten: `FEE_BPS` 25, `KEEPER_REWARD_EURC` 0,05 EURC, `MIN_TRADE_FLOOR` 20 EURC (fee van de kleinste run = precies de keeperbeloning), `MIN_CORRECTION_BPS` 10, `MIN_SLIPPAGE_BPS` 60 / `MAX_SLIPPAGE_BPS` 100, `MAX_SPOT_DEVIATION_BPS` 50, `MAX_AGE_CBBTC` 1500 s, `MAX_AGE_EURC` 4500 s (uurfeed `0x9867…01e0`), `FEED_DECIMALS` 8 (afgedwongen in de constructor), `POOL_FEE` 500 (0,05%), `MAX_BLOCK_MOVE_BPS` 6, `SIZING_BPS` 7500 (75%), `CHUNK_INTERVAL` 10 minuten.

De constructor controleert ook de twee pools: tokens (`UnexpectedPoolTokens`), fee-tier gelijk aan `POOL_FEE` (`UnexpectedPoolFee`), dat het precies de pools zijn die `getPool(…, 500)` geeft op de factory van de router (`ROUTER.factory()`, anders `PoolNotFromRouterFactory`), en dat elke pool minstens twee observaties bewaart (`ObservationCardinalityTooLow`; nodig voor het blokvenster, zie hieronder). Zo bewaakt de spotcheck gegarandeerd de pools waar de swap doorheen gaat (audit lead 1). Op Base geeft SwapRouter02 `0x2626…e481` factory `0x3312…FDfD`, en die geeft voor beide paren bij fee 500 de pools uit `script/Deploy.s.sol` (op 16 september 2026 met `cast call` gecontroleerd).

### Fee, beloning en maximaal verlies per run

De fee is 25 bps van het EURC-been van elke run: bij kopen over het bruto bedrag, bij verkopen over het hoogste van het werkelijk ontvangen bedrag en de verwachte opbrengst tegen de Chainlink-koers, en nooit meer dan het ontvangen bedrag. Zo dekt ook een verkoop op de vloer van 20 EURC na poolfees en slippage nog de volledige beloning (audit L-B). Daaruit gaat `min(0,05 EURC, fee)` naar `rewardTo`, de rest naar de treasury. Een deel van een ronde is een gewone run: ook daar gaan fee en beloning af, en ook elk deel is minstens `MIN_TRADE_FLOOR`, zodat de fee de beloning dekt. Beide transfers zijn niet-reverterend: faalt de beloning (bijvoorbeeld een geblacklist `rewardTo`), dan gaat de hele fee naar de treasury; faalt de treasury-transfer, dan blijft dat deel in het contract (`FeeRetained(amount)`) en haalt `sweep(EURC)` het later op. De rebalance zelf loopt dus nooit stuk op de fee-ontvanger.

**Het maximale verlies per run ten opzichte van de Chainlink-koers is `FEE_BPS + maxSlippageBps`** (0,85–1,25%). De spot-check hieronder is daar geen extra bovengrens op. **De cap (`maxCorrectionBps`) geldt per ronde, niet per dag**: met `interval` van 1 uur en cap 10% kan een wallet tot 24 × 10% per dag verplaatsen. Een ronde kan in delen gaan, maar samen nooit boven haar budget (zie [Delen](#grote-correcties-in-delen)). Wie een dagcap wil, zet `interval` op een dag.

### Sandwich-bescherming (audit M-1, L-3)

`execute` is permissionless, dus de aanroeper kan in één transactie de pool duwen, `execute` aanroepen en terugduwen. Drie lagen houden dat onrendabel.

**1. Blokvenster per pool.** Uniswap v3 schrijft een observatie zodra de tick in een blok voor het eerst verandert (of in-range liquiditeit wijzigt), en hooguit één per blok. Daaruit leidt het contract de tick aan het begin van het huidige blok af, zoals Uniswaps `OracleLibrary.getBlockStartingTickAndLiquidity` en `OracleSlippage` in SwapRouter02 dat doen (herschreven, niet gekopieerd; `TickMath` komt uit Uniswap v4-core onder MIT, zie `src/libraries/TickMath.sol`). Vóór én ná de swap moet de koers van beide pools binnen `MAX_BLOCK_MOVE_BPS` (6 bp) van die beginkoers liggen, inclusief de eigen swap; anders `BlockMoveExceeded(pool)`.
- **Waarom dat sluit.** Per eenheid die een aanvaller vooraf duwt en na de run terugruilt, verdient hij hooguit de koersbeweging tussen blokbegin en het einde van de run (≤ 6 bp), terwijl hij twee keer de poolfee betaalt (10 bp).
- **Afronding.** De begintick is afgerond: de echte beginkoers ligt ergens binnen die tick (≈ 1 bp). Het venster rekent vanaf de ongunstige rand van de tick, dus de afronding kost eerlijke runs hooguit 1 bp ruimte (per richting 5–6 bp) en geeft een aanvaller nooit ruimte.
- **Meerdere runs in één blok** tellen samen op in hetzelfde venster (audit lead 2). In de praktijk past er per pool per blok één volle run; kleine runs kunnen samen.
- **Beperkingen.** Een aanvaller die zelf een groot deel van de actieve liquiditeit bezit, krijgt een deel van zijn eigen poolfee terug. Gemeten op de fork bleef zijn beste extra winst 0,09 bp van de run (aandeel 95%); `test_fork_lpAttackerProfitBelowHalfBpOfRun` bewaakt < 0,5 bp. Duwen over meerdere blokken ziet het venster niet; dat begrenzen de spotcheck (laag 3) en arbitrage tussen blokken.

**2. Runomvang uit de liquiditeit.** `_plan` schat met de huidige liquiditeit (constant verondersteld) hoeveel input de koers naar de rand van het venster zou brengen, en gebruikt daarvan `SIZING_BPS` (75%). De marge vangt liquiditeit die over een tickgrens dunner wordt. Op de fork van 16 september 2026 was een run daardoor ~820 EURC bij een onbewogen pool; een grotere correctie gaat in delen.

**3. Spot tegen Chainlink.** Vóór én ná elke swap moet de spot van beide pools (EURC/USDC `0x7279…66fb`, USDC/cbBTC `0xfbb6…43ef`) binnen `MAX_SPOT_DEVIATION_BPS` (0,5%) van de Chainlink-koers liggen; anders `SpotDeviatesFromOracle`. `amountOutMinimum` volgt uit Chainlink en `maxSlippageBps`, dus het maximale verlies per run ten opzichte van de Chainlink-koers blijft `FEE_BPS + maxSlippageBps`.

**Blokkeren (audit L-3).** Wie de pool meer dan 0,5% van Chainlink duwt en daar houdt, houdt alle runs tegen zolang hij dat volhoudt tegen arbitrage in; daar is niets aan veranderd (`test_poc_dosBySpotPush` laat zien dat de owner weer due is zodra de pool terug is). Nieuw is dat binnen één blok een push van 6 bp al volstaat om runs in dát blok tegen te houden. Dat raakt alleen dat ene blok: de wekker probeert het in het volgende opnieuw, en de aanvaller betaalt elk blok opnieuw de poolfee heen en terug.

Fork-tests met asserts (`test/BlockWindowFork.t.sol`, gedraaid op 16 september 2026):
- **Aanvalsraster.** Pushes van 0,5 tot 30 bp in één of beide pools, mee en tegen de run in, koop en verkoop, runs van 100 EURC tot op de liquiditeitsgrens, met actuele feeds en met cbBTC/USD 0,3% te hoog. Beste extra winst van de aanvaller (na aftrek van de beloning die een eerlijke aanroeper ook krijgt): −0,060 EURC bij kopen en −0,062 EURC bij verkopen. Geen push buiten het venster kwam door.
- **Twee owners in één blok na één push:** geen winst.
- **Eerlijke correctie van 8.000 EURC**, met arbitrage tussen de delen: koop in 10 delen (1 uur 30), verkoop in 8 delen (1 uur 10; daarna binnen de band), zonder één revert.

### Grote correcties in delen

Is een run door de liquiditeit begrensd en de correctie nog niet klaar, dan opent die run een ronde (`rounds(owner)`):
- **Wanneer.** Het volgende deel mag `CHUNK_INTERVAL` (10 minuten) na de vorige run in plaats van na `interval`, alleen in dezelfde richting.
- **Tot wanneer.** Tot de afwijking binnen de band is, of tot het budget van de ronde op is: `maxCorrectionBps` van de waarde bij de eerste run, minstens `minTradeEurc`. Daarna geldt weer `interval`, gerekend vanaf de laatste run.
- **Afsluiten.** Een run sluit de ronde af als hij volgens een schatting zonder fee de owner binnen de band brengt. Met fee blijft er soms een kleine rest net buiten de band; die wacht op `interval`. Ook een restbudget onder `minTradeEurc` sluit de ronde, en een run die door saldo of allowance begrensd is, opent er geen.

Regels die dit veilig houden (unit-tests in `test/BlockWindow.t.sol`, invariants in `RebalancerInvariantTest*`):
- **Geen ping-pong.** Een richtingswissel start nooit een deel: `NothingToDo` tot `interval` verstreken is.
- **`setParams` breekt een lopende ronde af.**
- **Budget.** Het budget van een ronde ligt vast bij de eerste run. Delen gaan er samen niet boven, ook niet na een donatie aan de owner (audit lead 3). Zo'n donatie kan wel een run over de bandgrens duwen en het moment kiezen, maar met het blokvenster levert dat geen atomaire winst op.
- **Vloer per deel.** Een deel mag kleiner zijn dan `minTradeEurc` (die geldt voor de correctie), maar nooit kleiner dan `MIN_TRADE_FLOOR`. Past er in dit blok minder dan dat, dan is de owner niet due, revert `execute` met `BlockMoveExceeded`, en blijft de ronde staan tot er weer ruimte is. Lukt dat niet binnen `interval` na de laatste run, dan begint daarna een nieuwe ronde.
- **Koers brengt de owner binnen de band.** Brengt koersbeweging (geen run) de owner tussen twee delen binnen de band, dan is de ronde on-chain niet afgesloten; daarvoor is een schrijfactie nodig. Raakt hij binnen `interval` na het laatste deel in dezelfde richting weer buiten de band, dan kan er nog een deel volgen, binnen het restbudget.

Gas van `execute` op de fork (16 september 2026, zelfde blok, run van 500 EURC): koop 397k (was 370k vóór het blokvenster), verkoop 425k (was 399k). Een volgend deel in dezelfde test kost ~240k (koop) en ~262k (verkoop), omdat de storage dan warm is. `test_fork_buyAndSellGasCost` bewaakt de grens van 1.000.000, zodat een wekker weet wat hij moet begroten.

### Wekker en mislukte pogingen

Het contract onthoudt mislukte pogingen niet: `lastExecutedAt` wordt alleen bij succes gezet, dus een owner die structureel revert (blacklist, te krappe slippage) blijft due. De wekkers vangen dat zelf op: beide simuleren `execute` eerst en houden een cool-down per owner bij die per opeenvolgende mislukking verdubbelt.

Voor wekkers sinds het blokvenster:
- **Draaifrequentie.** Draai elke 10 minuten, zodat delen van een ronde op tijd worden opgepakt. Let op: start een run steeds precies 10 minuten na de vorige, dan is het vorige deel een paar seconden te kort geleden en schuift het volgende deel een beurt op (in de praktijk 10–20 minuten per deel).
- **Blokvenster-reverts.** `BlockMoveExceeded` en `BlockStartUnknown` zijn tijdelijk. Probeer het in een volgend blok opnieuw en tel ze niet als mislukking voor de cool-down.
- **Eén run per blok.** Probeer na een geslaagde run de volgende owner pas in een later blok. In hetzelfde blok is het venster meestal vol, en een `eth_call` op dat blok meldt de owner dan onterecht als niet due.

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

De primaire wekker is `bitburo:run-keeper` in de Bitburo Laravel-app: die pagineert het register via `dueOwners` en wekt iedereen die aan de beurt is. Sinds het blokvenster hoort die elke 10 minuten te draaien en blokvenster-reverts in een volgend blok opnieuw te proberen (zie [Wekker en mislukte pogingen](#wekker-en-mislukte-pogingen)); dat staat nog niet in de app. Het script in `keeper/` is de open terugvaloptie die iedereen zonder Bitburo kan draaien.

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

`test/BlockWindow.t.sol` (unit) en `test/BlockWindowFork.t.sol` (fork) testen het blokvenster en de delen uit audit M-1. `test/OracleLagSandwich.t.sol` stond als meting in `audit/2026-09-16/poc/` en is nu een test met asserts, net als de sandwich-PoC's in `test/OracleSandwich.t.sol`. `test/AuditMath.t.sol`, `test/CrePoC.t.sol`, `test/PocFork.t.sol` en `test/OracleSandwich.t.sol` komen uit de interne audit van 15 september 2026; `audit/2026-09-15/poc/README.md` zegt per bestand wat ervan is overgenomen en wat is omgeschreven van bewijs-van-lek naar bewijs-van-fix. Let op bij tijdreeksen onder `via_ir`: Solidity cachet `block.timestamp` binnen een testfunctie, gebruik na `vm.warp` dus `vm.getBlockTimestamp()`.

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

Het script leest per due owner `isDue`, slaat runs onder `MIN_RUN_EURC` (standaard 20 EURC) over, simuleert `execute` eerst met `eth_call` en stuurt pas daarna de transactie. Een owner waarvan de simulatie of de transactie mislukt krijgt een cool-down die per opeenvolgende mislukking verdubbelt (`COOLDOWN_SECONDS`, standaard 3600 s, tot `COOLDOWN_MAX_SECONDS`, standaard 86.400 s), bijgehouden in `COOLDOWN_FILE` (standaard `./keeper-cooldowns.json`, staat in `.gitignore`). Zo blijft een owner die structureel revert (het contract zet `lastExecutedAt` alleen bij succes) niet elke run gas kosten. Een revert door het blokvenster (`BlockMoveExceeded`, `BlockStartUnknown`) telt daar niet voor: het script probeert die owner opnieuw in een volgend blok, tot `BLOCK_RETRIES` keer (standaard 3), en wacht daarbij hooguit `BLOCK_WAIT_SECONDS` (standaard 30) op een nieuw blok. Na een geslaagde run leest en simuleert het de volgende owner pas in een later blok. Draai het elke 10 minuten (bijvoorbeeld cron `*/10`). Het script heeft geen gascap.

## Vaste regels

- Nooit uitrollen op mainnet zonder uitdrukkelijk akkoord van Arjan.
- Geen sleutels of `.env`-bestanden in git. De gitleaks-hook moet slagen.
- Contractwijzigingen altijd met tests, ook de fork-tests.
