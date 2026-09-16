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
| `setParams(Params)` | Eigen instellingen zetten of wijzigen. Grenzen: `minTradeEurc` ≥ `MIN_TRADE_FLOOR` (20 EURC), `maxCorrectionBps` 10–10000, `maxSlippageBps` 60–100, `interval` ≥ 1 uur. Na `retire` alleen nog met `active = false` (mandaat intrekken); anders `ContractRetired`. |
| `isDue(owner) → (bool, int256)` | Zou `execute` nu iets doen, en hoeveel EURC (+ kopen, − verkopen)? Revert nooit. Kijkt niet naar `lastAttemptAt`. Na `retire` altijd `(false, 0)`. |
| `dueOwners(offset, limit) → address[]` | Eén call per pagina: de owners die nu due zijn. Zelfde regels als `isDue`, plus: een owner met een mislukte `onReport`-poging korter dan zijn `interval` geleden wordt overgeslagen. Dit is wat de wekkers gebruiken. Na `retire` altijd leeg. |
| `lastAttemptAt(owner) → uint64` | Tijdstip van de laatste mislukte poging via `onReport` (0 = nooit). |
| `execute(owner, rewardTo)` | Eén rebalance-stap; iedereen mag dit aanroepen. `rewardTo` = contract zelf telt als `address(0)`. Revert met `NoOutput` als de koop 0 cbBTC zou opleveren, en met `ContractRetired` na `retire`. |
| `onReport(metadata, report)` | Ingang voor Chainlink CRE; `report` = `abi.encode(address[])`. Elke owner krijgt `EXECUTE_GAS` (1.000.000); onder `EXECUTE_GAS_RESERVE` (1.050.000) restgas stopt de lus netjes. Een mislukte owner krijgt `ReportSkipped(owner, reason)`, bij lege reden ook `ReportOutOfGas(owner)`, en `lastAttemptAt[owner]` wordt gezet. Na `retire` krijgt elke owner `ReportSkipped(owner, ContractRetired)` zonder dat `execute` wordt geprobeerd; de call zelf revert niet. |
| `sweep(token)` | Stuurt een achtergebleven saldo naar de treasury (per ongeluk gestuurde tokens, of fee die door een mislukte treasury-transfer is blijven staan). Permissionless. Werkt ook na `retire`. |
| `retire()` | Eenmalige, onomkeerbare uitschakelaar. Alleen `TREASURY`; tweede aanroep revert met `AlreadyRetired`. Zet `retired = true` en emit `Retired()`. Kan niets met fondsen of instellingen. |
| `retired() → bool` | Staat het contract buiten gebruik? |
| `quote()` / `spot()` / `quoteChecked()` | Feedkoers; poolspot; feedkoers mét de spot-check van `execute`. Alle drie in EURC-basiseenheden per cbBTC. |

Constanten: `FEE_BPS` 25, `KEEPER_REWARD_EURC` 0,05 EURC, `MIN_TRADE_FLOOR` 20 EURC (fee van de kleinste run = precies de keeperbeloning), `MIN_CORRECTION_BPS` 10, `MIN_SLIPPAGE_BPS` 60 / `MAX_SLIPPAGE_BPS` 100, `MAX_SPOT_DEVIATION_BPS` 50, `MAX_AGE_CBBTC` 1500 s, `MAX_AGE_EURC` 4500 s (uurfeed `0x9867…01e0`), `FEED_DECIMALS` 8 (afgedwongen in de constructor).

### Fee, beloning en maximaal verlies per run

De fee is 25 bps van het EURC-been van elke run (bij kopen over het bruto bedrag, bij verkopen over het werkelijk ontvangen bedrag). Daaruit gaat `min(0,05 EURC, fee)` naar `rewardTo`, de rest naar de treasury. Beide transfers zijn niet-reverterend: faalt de beloning (bijvoorbeeld een geblacklist `rewardTo`), dan gaat de hele fee naar de treasury; faalt de treasury-transfer, dan blijft dat deel in het contract (`FeeRetained(amount)`) en haalt `sweep(EURC)` het later op. De rebalance zelf loopt dus nooit stuk op de fee-ontvanger.

**Het maximale verlies per run ten opzichte van de Chainlink-koers is `FEE_BPS + maxSlippageBps`** (0,85–1,25%). De spot-check hieronder is daar geen extra bovengrens op. **De cap (`maxCorrectionBps`) geldt per run, niet per dag**: met `interval` van 1 uur en cap 10% kan een wallet tot 24 × 10% per dag verplaatsen. Wie een dagcap wil, zet `interval` op een dag.

### Spot-vs-oracle-check en wallet-limiet

Vóór én ná elke swap vergelijkt het contract de spotkoers van de Uniswap-pools EURC/USDC (`0x7279…66fb`) en USDC/cbBTC (`0xfbb6…43ef`) met de Chainlink-koers. Wijkt de spot op een van beide momenten meer dan `MAX_SPOT_DEVIATION_BPS` (0,5%) af, dan revert `execute` met `SpotDeviatesFromOracle` en boekt niets; `isDue`/`dueOwners` geven bij een afwijking vooraf niets terug (de check achteraf kunnen ze niet voorspellen). Op de fork van 11 september 2026 lag de afwijking op 4 bps.

De check vooraf begrenst hoe ver een aanroeper de pool kan voorschuiven; de check achteraf dwingt af dat die voorschuiving plus de eigen prijsimpact van de run samen binnen 0,5% blijven. Dat sluit de winstruimte van een atomaire zelf-sandwich grotendeels, maar het maximale verlies per run blijft `FEE_BPS + maxSlippageBps` (zie hierboven). **De EURC/USDC-pool is dun: runs boven ongeveer 8.000 EURC per keer reverten vaker zolang de route Uniswap v3 is**, omdat de eigen prijsimpact dan zelf al richting de toegestane afwijking gaat. Grote wallets houden `maxCorrectionBps` dus laag.

Gas van `execute` op de fork (audit 15 september 2026, tegen het 700k-budget van de vorige versie): koop 344k–548k en verkoop 404k–587k voor runs van 475 tot 9.500 EURC; ~19.000 EURC ging out-of-gas. Daarom is `EXECUTE_GAS` nu 1.000.000 en `EXECUTE_GAS_RESERVE` 1.050.000. Gevolg voor het CRE-rapport (`gasLimit` 4.000.000, waarvan na de forwarder ~3,55M overblijft): bij runs die het volle budget gebruiken passen **drie** owners gegarandeerd (`test_onReport_threeFullBudgetOwnersFitInForwarderMargin`); bij normale runs (~450k) passen er vijf. `maxOwnersPerReport` in de CRE-config moet dus naar 3, of `gasLimit` omhoog naar ~5,5M voor vijf owners op vol budget.

### Wekker en mislukte pogingen

`onReport` schrijft bij een mislukte `execute` `lastAttemptAt[owner]`; `dueOwners` slaat die owner daarna een `interval` lang over. Een owner die structureel revert (blacklist, te krappe slippage, out-of-gas) kost de CRE-wekker zo hooguit één slot per interval in plaats van elk rapport. `isDue` en `execute` kijken er niet naar, dus het keeper-script en handmatige runs kunnen eerder opnieuw proberen.

## Contract buiten gebruik stellen

> **Nog niet beschikbaar op het live contract.** `0xE577…2104` is uitgerold vanaf commit `f8a6d49` en mist `retire()`; dit draaiboek geldt pas vanaf de eerstvolgende deploy. Moet het huidige contract vandaag stil, dan is de enige weg per gebruiker: `setParams` met `active = false` en `approve(0)` op EURC en cbBTC. Dat kan alleen de gebruiker zelf, de treasury niet.

Het contract heeft geen admin, upgrade of pauzeknop, wel één eenmalige en onomkeerbare uitschakelaar: `retire()`, alleen aan te roepen met de sleutel van `TREASURY`. Dit is het antwoord op audit-bevinding M-8/M-9 (oude mandaten die na een redeploy onzichtbaar actief blijven, en het ontbreken van een noodstop). Er is geen weg terug en geen `unretire`.

Wat het doet: `execute` revert daarna met `ContractRetired`, `isDue` geeft `(false, 0)`, `dueOwners` is leeg (de CRE-wekker en het keeper-script vinden dus vanzelf niets meer), `onReport` slaat elke owner over met `ReportSkipped`, en `setParams` accepteert alleen nog `active = false`. `sweep` blijft werken om achtergebleven fee op te halen.

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
| `src/Rebalancer.sol` | Het contract. Solidity 0.8.28, OpenZeppelin 5.6.1, via-IR. |
| `audit/` | Interne auditrapporten en PoC's per datum. |
| `src/interfaces/` | Minimale interfaces: Chainlink AggregatorV3, Uniswap SwapRouter02, CRE IReceiver. |
| `test/` | Unit-, fuzz- en invarianttests met mocks; fork-tests tegen Base mainnet. |
| `script/Deploy.s.sol` | Deploy-script met de geverifieerde Base-adressen. |
| `keeper/` | Open keeper-script in TypeScript. Iedereen kan het draaien, zonder Bitburo; de terugvaloptie naast de Laravel-keeper. Zelfde ondergrens, simulatie vooraf en een cool-down per owner na een mislukking. |

### Wekkers

De primaire wekker is `bitburo:run-keeper` in de Bitburo Laravel-app: die pagineert het register via `dueOwners` en wekt elk uur iedereen die aan de beurt is. Het script in `keeper/` is de open terugvaloptie die iedereen zonder Bitburo kan draaien.

De Chainlink CRE-workflow die hier ooit stond is verwijderd in v1.1.0. Chainlink Automation is medio 2026 gestopt, CRE Early Access is nooit toegekend en het pad heeft op mainnet geen enkel rapport verwerkt. Wat wel in het contract blijft zitten is het ontvangstoppervlak: `onReport`, `IReceiver`, en de immutables `FORWARDER` en `WORKFLOW_OWNER`. Dat staat in de bytecode op de keten en gaat er alleen met een nieuwe deploy uit. Op het live contract is `WORKFLOW_OWNER` bovendien de deployer, dus `onReport` is daar sowieso onbereikbaar. Wie CRE alsnog wil, vindt de workflow in de geschiedenis onder tag `v1.0.0`.

## Commando's

Foundry staat in `~/.foundry/bin` (het `forge` in PATH kan de Laravel Forge CLI zijn).

```bash
~/.foundry/bin/forge build
~/.foundry/bin/forge test -vv                      # unit + fuzz + invariant + fork (BASE_RPC_URL optioneel)
~/.foundry/bin/forge test --gas-report --match-contract RebalancerFork
RUN_FORK=false ~/.foundry/bin/forge test              # zonder fork
~/.foundry/bin/forge test --no-match-path "test/RebalancerFork.t.sol"   # idem, zonder RPC-aanroep
```

`test/AuditMath.t.sol`, `test/CrePoC.t.sol`, `test/PocFork.t.sol` en `test/OracleSandwich.t.sol` komen uit de interne audit van 15 september 2026; `audit/2026-09-15/poc/README.md` zegt per bestand wat ervan is overgenomen en wat is omgeschreven van bewijs-van-lek naar bewijs-van-fix. Let op bij tijdreeksen onder `via_ir`: Solidity cachet `block.timestamp` binnen een testfunctie, gebruik na `vm.warp` dus `vm.getBlockTimestamp()`.

Keeper-script (vanuit `keeper/`):

```bash
bun install
RPC_URL=https://mainnet.base.org REBALANCER=0x… DRY_RUN=1 bun run keeper.ts
bun test            # selectie- en cool-down-logica
```

Het script leest per due owner `isDue`, slaat runs onder `MIN_RUN_EURC` (standaard 20 EURC) over, simuleert `execute` eerst met `eth_call` en stuurt pas daarna de transactie. Een owner waarvan de simulatie of de transactie mislukt krijgt een cool-down die per opeenvolgende mislukking verdubbelt (`COOLDOWN_SECONDS`, standaard 3600 s, tot `COOLDOWN_MAX_SECONDS`, standaard 86.400 s), bijgehouden in `COOLDOWN_FILE` (standaard `./keeper-cooldowns.json`, staat in `.gitignore`). Zo blijft een owner die structureel revert (het contract zet `lastExecutedAt` alleen bij succes) niet elke run gas kosten. Het script heeft geen gascap en bedient dus ook owners met een run die te groot is voor de `EXECUTE_GAS` van 1.000.000 die `onReport` per owner meegeeft.

## Vaste regels

- Nooit uitrollen op mainnet zonder uitdrukkelijk akkoord van Arjan.
- Geen sleutels of `.env`-bestanden in git. De gitleaks-hook moet slagen.
- Contractwijzigingen altijd met tests, ook de fork-tests.
