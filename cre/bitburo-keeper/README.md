# bitburo-keeper

Chainlink CRE-workflow die elk uur het Bitburo `Rebalancer`-contract op Base mainnet wekt.

> **Status: geparkeerd.** Deze workflow is niet uitgerold en heeft op mainnet nooit een rapport verwerkt; Chainlink Automation is medio 2026 gestopt en CRE Early Access is niet toegekend. De primaire wekker is de keeper in de Bitburo Laravel-app (`bitburo:run-keeper`), die hetzelfde register via `dueOwners` pagineert; het open script in `keeper/` is de terugvaloptie voor iedereen zonder Bitburo. De beschrijving hieronder blijft staan voor als CRE alsnog in beeld komt.

## Wat hij doet

1. Leest `latestRoundData()` van de Chainlink L2 Sequencer Uptime-feed voor Base. Is `answer` niet 0 (sequencer down), of is de sequencer korter dan `sequencerGracePeriodSeconds` geleden teruggekomen (`now − startedAt`), dan stopt de run: de prijsfeeds zijn dan niet te vertrouwen.
2. Leest `latestRoundData()` van de Chainlink cbBTC/USD-feed. Is die ouder dan `maxFeedAgeSeconds`, dan stopt de run: het contract zou toch reverten.
3. Leest `ownerCount()` en vraagt het Rebalancer-contract per pagina `dueOwners(offset, limit)`: één call per pagina, het contract filtert zelf met dezelfde regels als `isDue`. De run begint niet bij offset 0 maar bij een **roterend startpunt**: `(uurnummer × maxOwnersPerReport) mod ownerCount`, met het uurnummer uit de DON-tijd (`runtime.now()`, op alle nodes gelijk). Van daaruit loopt hij cyclisch door de hele lijst (eerst tot het einde, dan van 0 tot het startpunt). Zo komt elke due owner binnen `ceil(due / maxOwnersPerReport)` uur aan de beurt, ook als er owners vóór hem staan die elk uur due zijn.
4. Per kandidaat uit `dueOwners`:
   - leest `isDue(owner)` voor `eurcDelta`. Is `|eurcDelta|` kleiner dan `minRunEurc`, dan wordt de owner overgeslagen (dust: de fee van 25 bps dekt de gas niet en zulke owners kunnen anders de slots bezetten). Is hij groter dan `maxRunEurc`, dan ook (past niet in de 700.000 gas die `onReport` per owner geeft; het open keeper-script in `keeper/` heeft geen gascap en bedient die wel);
   - simuleert `execute(owner, address(0))` met `eth_estimateGas` via de CRE-EVM-client. Revert de simulatie (dust dat op de Uniswap-route naar 0 afrondt, blacklist, te krappe slippage) of vraagt hij meer dan `executeGasBudget`, dan wordt de owner overgeslagen: `onReport` zou hem toch met `ReportSkipped` overslaan en het slot is beter aan een ander besteed.
   Elke overgeslagen owner wordt met reden gelogd en staat in `skippedOwners` van het resultaat. Het bladeren stopt zodra het rapport `maxOwnersPerReport` owners bevat of er `maxCandidatesPerRun` kandidaten zijn beoordeeld; de rest komt in een volgende run.
5. Blijft er na het filteren geen owner over, dan wordt **geen rapport** geschreven (dat scheelt een lege forwarder-transactie). Anders codeert hij de owners als `abi.encode(address[])`, laat het rapport door de DON tekenen en stuurt het via de KeystoneForwarder naar `Rebalancer.onReport(metadata, report)`.
6. Controleert de uitkomst op twee niveaus: `txStatus` (de forwarder-transactie) én `receiverContractExecutionStatus` (is `onReport` zelf geslaagd?). De forwarder-transactie slaagt namelijk ook als `onReport` revert, bijvoorbeeld door een verkeerde workflow-owner. Een revert van de receiver laat de run falen met een duidelijke fout, zodat het in de CRE-monitoring zichtbaar is.

De workflow beslist niets over bedragen of richting. Dat doet het contract, met de instellingen van de gebruiker. De workflow kiest alleen wie er in het rapport komt.

## Configuratie (`config.*.json`)

| Sleutel | Betekenis |
|---|---|
| `schedule` | Cron met seconden; `0 0 * * * *` = elk heel uur |
| `chainSelectorName` | `ethereum-mainnet-base-1` (Base, chain id 8453) |
| `rebalancerAddress` | Adres van het Rebalancer-contract; nuladres zolang het niet is uitgerold |
| `sequencerFeedAddress` | Chainlink L2 Sequencer Uptime-feed op Base: `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` |
| `sequencerGracePeriodSeconds` | Wachttijd na een sequencer-herstart voordat de run weer doorgaat (3600 s) |
| `priceFeedAddress` | Chainlink cbBTC/USD op Base: `0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D` |
| `maxFeedAgeSeconds` | Heartbeat 1200 s plus marge |
| `ownersPageSize` | Aantal owners per `dueOwners()`-call |
| `maxOwnersPerReport` | Bovengrens per rapport (5): elke owner krijgt in `onReport` 700.000 gas, met reserve 750.000 passen er vijf in `gasLimit`. Bepaalt ook de stapgrootte van de rotatie |
| `maxCandidatesPerRun` | Hoeveel due owners per run hooguit door `isDue()` en de simulatie gaan (25). Elke kandidaat kost twee extra EVM-calls; dit houdt het aantal calls per run begrensd, ook als iemand de owner-lijst volpropt |
| `minRunEurc` | Ondergrens van `\|eurcDelta\|` in hele EURC (20). Bij 20 EURC is de fee (25 bps) precies de keeper-beloning van 0,05 EURC; daaronder is een run de gas niet waard |
| `maxRunEurc` | Bovengrens van `\|eurcDelta\|` in hele EURC (8.000). Op de Base-fork ging `execute` vanaf ~19.000 EURC out-of-gas binnen de 700.000 van `onReport`; 8.000 houdt marge voor een dunnere pool. Grotere runs zijn voor het keeper-script |
| `executeGasBudget` | Gasbudget dat `onReport` per owner geeft (`EXECUTE_GAS` = `"700000"`); een simulatie die meer vraagt wordt overgeslagen. De simulatie gebruikt `rewardTo = address(0)` (hele fee naar de treasury), wat iets minder gas kost dan de echte run met `TREASURY`; daarom is `maxRunEurc` de eerste verdedigingslinie en dit de tweede |
| `gasLimit` | Gaslimiet van de `onReport`-transactie (CRE-maximum is 5.000.000) |

## Contract-interface die de workflow verwacht

```solidity
function ownerCount() external view returns (uint256);
function dueOwners(uint256 offset, uint256 limit) external view returns (address[] memory);
function isDue(address owner) external view returns (bool due, int256 eurcDelta);
function execute(address owner, address rewardTo) external; // alleen gesimuleerd (eth_estimateGas)
function onReport(bytes calldata metadata, bytes calldata report) external; // report = abi.encode(address[] owners)
```

`onReport` accepteert alleen de KeystoneForwarder op Base (`0xF8344CFd5c43616a4366C34E3EEE75af79a74482`; simulatie `0x5e342a8438b4f5d39e72875fcee6f76b39cce548`) en het vaste workflow-ID.

## Wat de workflow niet kan

- **Geen cool-down per owner.** Een CRE-run heeft geen geheugen tussen executies (de `Runtime` biedt alleen config, tijd, logging, secrets, EVM/HTTP-calls en rapporten), dus de workflow kan niet onthouden dat een owner vorige run is gerevert. De simulatie vooraf vangt dat per run op: een owner die structureel revert kost één `eth_estimateGas` per uur in plaats van 700.000 gas on-chain. Het keeper-script heeft die cool-down wél (JSON-bestand). Bij de volgende contractversie hoort `lastAttemptAt` in de `catch`-tak van `onReport`, zodat `dueOwners` zulke owners zelf overslaat.
- **Simulatie raakt het live contract niet.** `cre workflow simulate` schrijft via de MockForwarder, die het contract weigert (`UnauthorizedForwarder`). De simulatie bewijst de lees-kant, het filteren en de rapport-encoding; de levering alleen via een echte run op mainnet (`ReportProcessed`-event op de forwarder).

## Commando's

Vanuit de projectroot (`cre/`):

```bash
cre workflow simulate bitburo-keeper --target staging-settings --non-interactive --trigger-index 0
```

Unit-tests en typecheck, vanuit deze map:

```bash
bun test
bun run typecheck
```

Uitrollen vereist CRE Early Access (`cre account access`). Niet uitrollen zonder akkoord van Arjan.
