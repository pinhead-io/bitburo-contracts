# bitburo-contracts

Het onveranderbare `Rebalancer`-contract van Bitburo op Base mainnet, plus de twee externe wekkers.

De gebruiker geeft het contract een ERC-20-mandaat (allowance) voor EURC en cbBTC en zet zijn eigen instellingen. Het contract rebalancet vanuit de wallet van de gebruiker naar de gekozen verdeling; het geld blijft in de wallet. Bitburo heeft geen sleutel en kan niets wijzigen. Ontwerp en besluiten: zie de overdracht (privé artifact, bij Arjan).

## Onderdelen

| Map | Wat |
|---|---|
| `src/Rebalancer.sol` | Het contract. Solidity 0.8.28, OpenZeppelin 5.6.1, via-IR. |
| `src/interfaces/` | Minimale interfaces: Chainlink AggregatorV3, Uniswap SwapRouter02, CRE IReceiver. |
| `test/` | Unit-, fuzz- en invarianttests met mocks; fork-tests tegen Base mainnet. |
| `script/Deploy.s.sol` | Deploy-script met de geverifieerde Base-adressen. |
| `cre/` | Chainlink CRE-workflow `bitburo-keeper` (cron, elk uur). Beoogde primaire wekker. |
| `keeper/` | Open keeper-script in TypeScript. Iedereen kan het draaien, zonder Bitburo. |

## Commando's

Foundry staat in `~/.foundry/bin` (het `forge` in PATH kan de Laravel Forge CLI zijn).

```bash
~/.foundry/bin/forge build
~/.foundry/bin/forge test -vv                      # unit + fuzz + invariant + fork (BASE_RPC_URL optioneel)
~/.foundry/bin/forge test --gas-report --match-contract RebalancerFork
```

CRE-workflow simuleren (vanuit `cre/`):

```bash
~/.cre/bin/cre workflow simulate bitburo-keeper --target staging-settings
```

Keeper-script (vanuit `keeper/`):

```bash
bun install
RPC_URL=https://mainnet.base.org REBALANCER=0x… DRY_RUN=1 bun run keeper.ts
```

## Vaste regels

- Nooit uitrollen op mainnet zonder uitdrukkelijk akkoord van Arjan.
- Geen sleutels of `.env`-bestanden in git. De gitleaks-hook moet slagen.
- Contractwijzigingen altijd met tests, ook de fork-tests.
