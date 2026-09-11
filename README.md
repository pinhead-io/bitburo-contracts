# bitburo-contracts

Het onveranderbare `Rebalancer`-contract van Bitburo op Base mainnet, plus de twee externe wekkers.

De gebruiker geeft het contract een ERC-20-mandaat (allowance) voor EURC en cbBTC en zet zijn eigen instellingen. Het contract rebalancet vanuit de wallet van de gebruiker naar de gekozen verdeling; het geld blijft in de wallet. Bitburo heeft geen sleutel en kan niets wijzigen. Ontwerp en besluiten: zie de overdracht (privé artifact, bij Arjan).

## Contract-interface

| Functie | Wat |
|---|---|
| `setParams(Params)` | Eigen instellingen zetten of wijzigen (`maxSlippageBps` 30–100). |
| `isDue(owner) → (bool, int256)` | Zou `execute` nu iets doen, en hoeveel EURC (+ kopen, − verkopen)? Revert nooit. |
| `dueOwners(offset, limit) → address[]` | Eén call per pagina: de owners die nu due zijn. Zelfde regels als `isDue`; revert nooit. Dit is wat de wekkers gebruiken. |
| `execute(owner, rewardTo)` | Eén rebalance-stap; iedereen mag dit aanroepen. `rewardTo` = contract zelf telt als `address(0)`. |
| `onReport(metadata, report)` | Ingang voor Chainlink CRE; `report` = `abi.encode(address[])`. Elke owner krijgt `EXECUTE_GAS` (700.000); onder `EXECUTE_GAS_RESERVE` (750.000) restgas stopt de lus netjes. |
| `sweep(token)` | Stuurt een per ongeluk achtergebleven saldo naar de treasury. Permissionless. |
| `quote()` / `spot()` / `quoteChecked()` | Feedkoers; poolspot; feedkoers mét de spot-check van `execute`. Alle drie in EURC-basiseenheden per cbBTC. |

### Spot-vs-oracle-check en wallet-limiet

Vóór elke swap vergelijkt het contract de spotkoers van de Uniswap-pools EURC/USDC (`0x7279…66fb`) en USDC/cbBTC (`0xfbb6…43ef`) met de Chainlink-koers. Wijkt de spot meer dan `MAX_SPOT_DEVIATION_BPS` (0,5%) af, dan revert `execute` met `SpotDeviatesFromOracle` en geeft `isDue`/`dueOwners` niets terug. Op de fork van 11 september 2026 lag de afwijking op 4 bps.

Dit begrenst wat een aanroeper via de pool kan onttrekken tot ongeveer 0,5% van het run-bedrag plus de door de gebruiker toegestane slippage (0,3–1%). Het maakt manipulatie niet onmogelijk, alleen onaantrekkelijk. **De EURC/USDC-pool is dun: runs boven ongeveer 10.000 EURC per keer zijn onverstandig zolang de route Uniswap v3 is**, omdat de eigen prijsimpact dan al richting de toegestane afwijking gaat en de run vaker zal reverten of onnodig duur is. Grote wallets houden `maxCorrectionBps` dus laag.

Gas van `execute` op de fork (11 september 2026): koop 404.653, verkoop 426.991. Daarop zijn `EXECUTE_GAS` en `EXECUTE_GAS_RESERVE` afgestemd; vijf owners passen in de 4.000.000 gas van het CRE-rapport (`maxOwnersPerReport` = 5).

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
RUN_FORK=false ~/.foundry/bin/forge test              # zonder fork
```

CRE-workflow simuleren (vanuit `cre/`):

```bash
~/.cre/bin/cre workflow simulate bitburo-keeper --target staging-settings --non-interactive --trigger-index 0
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
