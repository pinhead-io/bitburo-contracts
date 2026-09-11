# bitburo-keeper

Chainlink CRE-workflow die elk uur het Bitburo `Rebalancer`-contract op Base mainnet wekt.

## Wat hij doet

1. Leest `latestRoundData()` van de Chainlink L2 Sequencer Uptime-feed voor Base. Is `answer` niet 0 (sequencer down), of is de sequencer korter dan `sequencerGracePeriodSeconds` geleden teruggekomen (`now − startedAt`), dan stopt de run: de prijsfeeds zijn dan niet te vertrouwen.
2. Leest `latestRoundData()` van de Chainlink cbBTC/USD-feed. Is die ouder dan `maxFeedAgeSeconds`, dan stopt de run: het contract zou toch reverten.
3. Loopt `owners(offset, limit)` van het Rebalancer-contract af en vraagt per owner `isDue(owner)`.
4. Codeert de due owners als `abi.encode(address[])`, laat het rapport door de DON tekenen en stuurt het via de KeystoneForwarder naar `Rebalancer.onReport(metadata, report)`.

De workflow beslist niets over bedragen of richting. Dat doet het contract, met de instellingen van de gebruiker.

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
| `ownersPageSize` | Aantal owners per `owners()`-call |
| `maxOwnersPerReport` | Bovengrens per rapport, zodat `onReport` binnen `gasLimit` blijft |
| `gasLimit` | Gaslimiet van de `onReport`-transactie (CRE-maximum is 5.000.000) |

## Contract-interface die de workflow verwacht

```solidity
function owners(uint256 offset, uint256 limit) external view returns (address[] memory);
function isDue(address owner) external view returns (bool due, int256 eurcDelta);
function onReport(bytes calldata metadata, bytes calldata report) external; // report = abi.encode(address[] owners)
```

`onReport` accepteert alleen de KeystoneForwarder op Base (`0xF8344CFd5c43616a4366C34E3EEE75af79a74482`; simulatie `0x5e342a8438b4f5d39e72875fcee6f76b39cce548`) en het vaste workflow-ID.

## Commando's

Vanuit de projectroot (`cre/`):

```bash
cre workflow simulate bitburo-keeper --target staging-settings
```

Unit-tests, vanuit deze map:

```bash
bun test
```

Uitrollen vereist CRE Early Access (`cre account access`). Niet uitrollen zonder akkoord van Arjan.
