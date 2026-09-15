# Security-review: wallet-mandaat / approval-model Rebalancer

Datum: 2026-09-15. Scope: `pinheadio/bitburo-contracts` (main, `c2cf093`) en `pinheadio/bitburo` (`development` `f4e8620` plus de open PR's #142 `feature/rebalancer-keeper` en #143 `feature/keeper-mandate-gate`, want `development` bevat nog géén enkele verwijzing naar het Rebalancer-contract). Alleen gelezen; niets gewijzigd. Forge-tests gedraaid (`RUN_FORK=false`): 79 geslaagd, 1 overgeslagen (fork). On-chain gecontroleerd via `cast` tegen Base mainnet.

## Vastgestelde feiten (on-chain, 2026-09-15)

| Wat | Waarde | Bron |
|---|---|---|
| Rebalancer | `0xED47d549345b0dBB5A9b44E57Ff3AB4E6Ed0e6e5`, deploy-blok 51300986 | `broadcast/Deploy.s.sol/8453/run-latest.json` |
| TREASURY | `0xD6a4f92C9c2c35B4816deC5147231226Fb7598a9` (EOA, geen code) | `cast call TREASURY()`, `cast code` |
| WORKFLOW_OWNER = deployer | `0xdeb5e5b8bDc70e8f2BBB3bACbAFA2a981ee2E7A7` (EOA, 0,0006 ETH) | `cast call WORKFLOW_OWNER()`, broadcast `from` |
| FORWARDER | `0xF8344CFd5c43616a4366C34E3EEE75af79a74482` (contract, 8,5 kB code) | `cast call FORWARDER()` |
| ownerCount | 1: `0x459EE9C4b9cd25a70F92A8433B339369FA62A497` (Arjans testaccount) | `cast call owners(0,50)` |
| Params van die owner | active=true, target 8000, band 200, cap 1000, minTrade 5 EURC, interval 86400, slippage 100 | `cast call params(address)` |
| Allowances owner→contract | EURC én cbBTC: `type(uint256).max` | `cast call allowance` |
| Owner-wallet | EIP-7702-gedelegeerd (`0xef0100d6cedd…7875b28`) — Privy Kernel-account | `cast code` |
| EURC / cbBTC | beide hebben `DOMAIN_SEPARATOR()` en `nonces()` → EIP-2612 `permit` aanwezig | `cast call` |

---

## Bevindingen

### M-01 — High — Server-signer met swap-only policy kan nog steeds een `permit` of een 7702-autorisatie tekenen

**Verwijzing:** bitburo `app/Console/Commands/SetupSwapPolicyCommand.php:25-28, 122-146` (`*` ALLOW zonder DENY op `eth_signTypedData_v4` en `eth_sign7702Authorization`); `resources/js/pages/wallet/index.tsx:609-615` en `resources/js/pages/billing/index.tsx:115-129` (deze policy hangt aan de swap-signer op élke gedelegeerde user-wallet, ook op Arjans hoofdaccount dat "op de oude strategie blijft").

**Beschrijving.** De policy staat `*` ALLOW toe (nodig omdat `/swap` geen eigen policy-methode heeft) en legt DENY's over `eth_sendTransaction`, `eth_signTransaction`, `wallet_sendCalls`, `eth_signUserOperation`, `transfer`, `earn_*`, key-export en `personal_sign`. Twee funds-bewegende methodes blijven open, en de code zegt dat zelf ("Known residual risk"):
- `eth_signTypedData_v4`: EURC en cbBTC op Base implementeren EIP-2612 (`DOMAIN_SEPARATOR`/`nonces` geverifieerd). Een getekende `Permit(owner, spender=aanvaller, value=max)` is functioneel identiek aan `approve(aanvaller, max)`; daarna `transferFrom` door de aanvaller → hele wallet leeg. (Kanttekening: de wallet is een 7702-account; de tokens verifiëren dan via ERC-1271 op de Kernel-delegate. Of die 1271-check de Privy-EOA-handtekening accepteert heb ik niet on-chain bewezen; de policy-lek is er hoe dan ook.)
- `eth_sign7702Authorization`: de signer kan een autorisatie tekenen die de EOA aan een willekeurig contract delegeert; iedereen mag die in een type-4-transactie meesturen, waarna de aanvaller de account-code bepaalt en alles kan wegsluizen. Privy: "EIP-7702 authorization signing is supported in the React SDK, REST API, and Node SDK" (docs.privy.io/wallets/using-wallets/ethereum/sign-7702-authorization).

**Scenario.** Aanvaller bemachtigt `PRIVY_APP_SECRET` + `PRIVY_AUTHORIZATION_KEY` (de swap-signer-sleutel; dezelfde sleutel is ook owner van de keeper-wallet, zie M-08). POST `/v1/wallets/{id}/rpc` met `method: eth_signTypedData_v4` (Privy API-referentie `eth_signTypedData_v4`) → Permit → `transferFrom`. Geen MFA: de signer is een sessie-signer. Verlies: 100% van EURC + cbBTC van elke gedelegeerde wallet.

**Privy-semantiek (citaat).** "`DENY` actions take precedence over `ALLOW` actions. If no rules resolve, the policy will default to `DENY`." en methode-lijst inclusief `eth_signTypedData_v4` en `eth_sign7702Authorization`, met `*` (docs.privy.io/controls/policies/overview, "Rules" en "Policy evaluation"). Condition-bronnen `ethereum_typed_data_domain` (`chainId`, `verifyingContract`) en `ethereum_7702_authorization` (`contract`) bestaan (zelfde pagina, tabel "Field sources").

**Testdekking.** Pest: geen (policy-inhoud wordt alleen als array getest, niet tegen Privy). Forge: n.v.t.

**Fix.** (1) Kortst: DENY-regel `eth_signTypedData_v4` met conditie `ethereum_typed_data_domain.verifyingContract in [EURC, cbBTC]` én een DENY op `chainId eq 8453`; DENY `eth_sign7702Authorization` met `ethereum_7702_authorization.contract` `in` [huidige Kernel-delegate] werkt niet als denylist — Privy accepteert voor deze methode geen condition-loze DENY volgens de code-commentaar; verifieer bij Privy of `contract`-conditie met een onmogelijk adres plus ALLOW-loos gedrag voldoet. (2) Structureel en al het plan: na de cutover de swap-signer helemaal van de user-wallets halen (`removeSigners`) — het contractmodel heeft geen server-signer nodig. Tot die tijd: draai `bitburo:setup-swap-policy --update` met de extra DENY's (werkt direct voor alle bestaande delegaties, zoals de code al opmerkt).

### M-02 — Medium — Open registratie laat de CRE-wekker uithongeren en Bitburo's CRE-gas leegtrekken

**Verwijzing:** contracts `src/Rebalancer.sol:197-212` (`setParams` zonder drempel), `:248-275` (`dueOwners` pagineert vanaf `offset` in registratievolgorde), `cre/bitburo-keeper/main.ts:187-201` (stopt bij `maxOwnersPerReport`), `cre/bitburo-keeper/config.production.json` (`maxOwnersPerReport: 5`, `gasLimit: 4000000`).

**Beschrijving.** Iedereen mag zich registreren (`_owners` groeit voor altijd) en `dueOwners` levert due-owners in registratievolgorde. De CRE-workflow neemt de eerste vijf. Een aanvaller registreert N adressen met `minTradeEurc = 1`, `bandBps = 1`, `interval = 1 hours`, 1 EURC saldo + allowance. Die zijn elk uur "due" (na elke run drijft de fractie meteen weer >0,01% af). Gevolg: (a) elk uur bevat het rapport alleen aanvallersadressen; elke echte gebruiker die ná de aanvaller registreerde wordt nooit via CRE bediend; (b) elke aanvallers-execute kost ~700k gas op het gasbudget van de workflow (Bitburo betaalt), terwijl de aanvaller ~0,0025 EURC fee per run betaalt.

**Scenario.** 50 dust-owners registreren kost de aanvaller eenmalig gas. Daarna ~5 × 700k gas/uur van Bitburo, en legitieme users met een hoger `_owners`-index vallen terug op de Laravel-keeper (die z'n eigen users afloopt en dus níet getroffen is) of het open script.

**Testdekking.** Forge: `test_dueOwners_filtersAndPaginatesLikeIsDue` (alleen filter/paginering). CRE: "pages through dueOwners and caps the report at maxOwnersPerReport" (alleen de cap). Niets test uithongering/kostenasymmetrie.

**Fix.** Contract (vóór de definitieve deploy, immutable): eis `minTradeEurc >= 5e6` (of `total >= X`) in `setParams`/`_plan`, en/of laat `dueOwners` niets teruggeven onder een minimale totale waarde. Workflow: roteer de startoffset per run (bijv. `blockNumber % ownerCount`) of neem een willekeurige pagina, en cap per owner op basis van de `Executed`-historie. Overweeg in de workflow een eigen allowlist (HTTP-fetch van Bitburo's userlijst) — dat past ook bij het compliance-argument dat Bitburo niet de enige aanroeper is, zolang het open script blijft bestaan.

### M-03 — Medium — De parameters worden door de server gedicteerd; de gebruiker tekent ze blind, zonder client-side grenzen

**Verwijzing:** bitburo (PR #142/#143) `app/Services/Rebalancer/RebalancerMandateReader.php:211-224` (`defaults()` uit `config('bitburo.auto.*')`), `resources/js/components/strategy-card.tsx:646-680` (kopieert `defaults` 1-op-1 in `setParams`), `resources/js/lib/rebalancer-abi.ts:82-94` (geen validatie); contracts `src/Rebalancer.sol:197-205` (enige grenzen: target 500–9500, band 1–9999, cap 1–10000, interval ≥ 1u, slippage 30–100).

**Beschrijving.** Besluit 2026-09-14: "gebruiker kiest NIETS in het mandaat". Een gecompromitteerde backend, een foute `.env` of een gemanipuleerd Inertia-prop kan dus `targetBps: 500`, `maxCorrectionBps: 10000`, `bandBps: 1`, `interval: 3600`, `maxSlippageBps: 100` aanbieden; de kaart toont die waarden, maar de gebruiker verwacht "de Bitburo-standaard" en tekent met MFA. Het contract begrenst de schade (geld verlaat de wallet nooit; slippage ≤ 1%; spot-check 0,5%; fee 0,25%), maar niet de allocatie: 75% van de BTC-positie kan in één run naar EURC tegen maximaal ~1,75% waardelek + 0,25% fee naar de treasury.

**Maximaal verlies per gebruiker per dag (rekenkundig).** Met Bitburo-defaults (cap 10%, interval 24u): verhandeld ≤ 10% van de totale waarde/dag (floor `minTradeEurc`); waardelek per run ≤ fee 0,25% + slippage 1% + spot-afwijking 0,5% = 1,75% van het verhandelde ⇒ ≤ 0,175% van de portefeuille/dag. Met door de server gemanipuleerde params: tot 100% herverdeeld per run, 1,75% lek per run, en met `interval = 1 hours` + `bandBps = 1` bij elke koersbeweging een nieuwe run (elk 0,25% fee over het kleine correctiebedrag). Een gecompromitteerde backend kan géén fondsen naar zichzelf halen via het contract (`rewardTo` max 0,05 EURC uit de fee; `TREASURY` immutable).

**Testdekking.** Vitest `rebalancer-abi.test.ts` (encoding), Browser `StrategyTest` ("offers a mandate with the application-wide settings", "shows the on-chain settings on the card") — geen test dat afwijkende defaults geweigerd worden.

**Fix.** Client-side harde grenzen in `encodeSetParams`/de dialoog (cap ≤ 1000, band ≥ 100, interval ≥ 86400, target ∈ [5000, 9500]) met een expliciete bevestiging van de getoonde waarden; een Vitest die een buiten-bereik `defaults` laat falen. Overweeg de defaults in de frontend-bundel te bakken in plaats van als prop.

### M-04 — Medium — Onbeperkte allowance + één contractadres in config: redeploy laat oude mandaten actief en onzichtbaar

**Verwijzing:** bitburo (PR) `config/bitburo.php` (`rebalancer.address`, één adres), `strategy-card.tsx:671-680, 898-915` (approve `MAX_UINT256` / approve 0 alleen naar `rebalancer.contractAddress`), `RebalancerMandateReader::readChainState` (leest allowances alleen voor dat adres). Besluit (geheugen): "allowance onbeperkt"; het huidige contract is "wegwerp vóór audit".

**Beschrijving.** Blast radius van de max-allowance bij dít contract is beperkt: het contract is immutable, heeft geen admin/upgrade, kan alleen `transferFrom` in `_buy/_sell` binnen `_plan` (begrensd op `maxCorrectionBps` en allowance), en de output gaat altijd naar de owner. Het echte risico zit in de levenscyclus: na de geplande redeploy (audit-versie) houden bestaande owners `type(uint256).max` én `active` params op het oude adres. Het oude contract blijft permissionless executeerbaar (open keeper-script, iedereen) en heeft een eigen `lastExecutedAt`-klok: twee contracten handelen dan naast elkaar (2× dagcap, 2× fee), en de UI toont noch een intrek-pad voor het oude adres (de kaart kent alleen het geconfigureerde adres).

**Scenario.** Cutover naar het geauditeerde contract; Arjans testaccount (en elke bèta-user) blijft geregistreerd bij `0xED47…`; een derde draait het keeper-script met `REBALANCER=0xED47…` en verdient 0,05 EURC per run op kosten van de gebruiker (0,25% fee + slippage).

**Testdekking.** Pest `WalletControllerTest` ("the wallet page reads the mandate from the chain") en `StrategyTest` (revoke) — allemaal met één adres. Geen test voor een legacy-adres.

**Fix.** (1) Decommissie-runbook per redeploy: voor elke owner `approve(0)` op beide tokens + `setParams(active=false)` op het oude adres, en ná cutover een controle-script dat `params`/`allowance` op alle vorige adressen leest. (2) `bitburo.rebalancer.legacy_addresses` in config; de kaart leest en toont ook die allowances en biedt "intrekken" aan. (3) Overweeg een begrensde allowance (bijv. 2× dagcap in absolute termen) — kost een extra handtekening bij groei, maar maakt elke bug in een toekomstig contract per definitie begrensd.

### M-05 — Medium — WORKFLOW_OWNER = deployer-EOA; als de CRE-workflow onder een ander adres landt, is het CRE-pad voorgoed dood

**Verwijzing:** contracts `script/Deploy.s.sol:34, 50`, `src/Rebalancer.sol:322-325`, broadcast (`workflowOwner == from`); `cre/bitburo-keeper/config.production.json` en `config.staging.json` (identiek, beide wijzen naar het wegwerpcontract).

**Beschrijving.** `onReport` eist `metadata.workflowOwner == WORKFLOW_OWNER` (immutable). Het contract is gedeployd met de deployer-EOA als owner terwijl het geheugen zegt dat de owner "de CRE link-key EOA, niet de Privy keeper-wallet" moet zijn. CRE Early Access is niet toegekend, dus het echte owner-adres is nog niet bekend. Landt de workflow onder een ander adres, dan revert elk rapport en is alleen een nieuwe deploy (met M-04) de uitweg. Daarnaast: staging en production wijzen naar hetzelfde contract, en de deployer-sleutel (die ook de workflow-owner is) staat in Arjans lokale `.env` — één sleutel, twee rollen.

**Testdekking.** Forge `test_onReport_revertsUnauthorizedWorkflowOwner`, `…UnauthorizedForwarder` (gedrag klopt; het risico is operationeel).

**Fix.** Vóór de definitieve deploy: het workflow-owner-adres uit `cre account`/link-key vastleggen en als `WORKFLOW_OWNER` meegeven; aparte sleutel voor deployer; sleutelbeheer (hardware/multisig-achtige opslag) documenteren.

### M-06 — Medium — Geen pauzeknop, geen incident-runbook, monitoring ontbreekt

**Verwijzing:** contracts `src/Rebalancer.sol:26` ("Geen admin, geen upgrade, geen pauzeknop"), `README.md`; bitburo (PR) `routes/console.php:26-27` (keeper + sweep), geen `docs/`-runbook, geen alert op `Executed`.

**Beschrijving.** Bewust ontwerp: Bitburo kan niets stoppen. Dat betekent bij een incident (feed-manipulatie binnen 0,5%, pool-drain, token-upgrade van EURC/cbBTC, bug in `_plan` na een toekomstige redeploy): (a) Bitburo kan alleen zijn eigen keeper stilzetten (`BITBURO_REBALANCER_ADDRESS` legen), niet CRE of derden; (b) elke gebruiker moet zelf 3 transacties + MFA tekenen om te stoppen; (c) er is geen detectie: de sweep boekt `Executed` maar vergelijkt `priceEurcPerBtc`/`amountOut` nergens met een referentie; (d) TREASURY is een EOA; wie de sleutel bewaart en hoe is nergens vastgelegd (compromis = fee-verlies + de billing-policy allowlist moet mee).

**Testdekking.** n.v.t.

**Fix.** Runbook (wie doet wat, communicatie, "revoke-all"-pagina met één knop die de 3 handtekeningen na elkaar vraagt — bestaat al deels in de kaart); Sentry/log-alert in `SweepExecutionsCommand::book()` bij `|price − CoinGecko| > 1%` of `amountOut < expected × 0,985`; treasury-sleutel in een hardware wallet of multisig (immutable → kiezen vóór de definitieve deploy).

### M-07 — Medium — Twee handelsmotoren draaien naast elkaar zonder wederzijdse uitsluiting

**Verwijzing:** bitburo (PR) `routes/console.php:21-27` (`bitburo:run-schedules` én `bitburo:run-keeper` elk uur), `app/Services/ScheduleRunner.php:246-287` (ledger-gebaseerd, cap 10%), `app/Console/Commands/RunKeeperCommand.php:110-137` (loopt álle users met wallet af).

**Beschrijving.** Een user kan tegelijk een gedelegeerd schema (oude pad, Privy-swap) én een on-chain mandaat hebben; niets sluit dat uit. Beide corrigeren naar 80/20 met 10%/dag → samen 20%/dag, dubbele fee-achtige kosten (Privy-swapfee + contractfee). De Laravel-motor rekent bovendien op ledgerbalansen die tot een uur achterlopen op contract-swaps (sweep), dus zij kan oversell-orders indienen die on-chain falen (gesponsord gas).

**Testdekking.** Geen test die de combinatie afdekt.

**Fix.** In `ScheduleRunner::runLocked` (of `RunDueSchedulesCommand`): sla over als `RebalancerClient::params(owner).active` waar is; of — het plan — cutover en de oude motor verwijderen.

### M-08 — Low — Keeper-wallet en keeper-policy hangen aan dezelfde app-sleutel; de policy beschermt niet tegen sleutelcompromis

**Verwijzing:** bitburo (PR) `app/Console/Commands/SetupKeeperWalletCommand.php:82-87` (`owner_id` = `services.privy.key_quorum_id`, dezelfde quorum als de swap-signer), `:171-194` (policy).

**Beschrijving.** De policy pint `to`, `chain_id`, `function_name = execute` en `execute.rewardTo = treasury` — correct en volgens de docs (`ethereum_calldata` met `function_name` en `function_name.param_name`, docs.privy.io/controls/policies/overview, tabel). Maar: "A wallet's owner can add or remove signers on the wallet, and assign policies" (docs.privy.io/controls/authorization-keys/owners/overview). De owner is de app-sleutel zelf, dus wie die sleutel heeft, herschrijft de policy. Op het spel staat alleen de beloning (0,05 EURC/run) en gesponsord gas; het contract beschermt de gebruikers. Wél concentreert dit alles (swap-signer op user-wallets, keeper-owner, policy-beheer) op één P-256-sleutel.

**Testdekking.** Pest `SetupKeeperWalletCommandTest` (10 tests, policy-body).

**Fix.** Aparte key quorum voor de keeper-wallet-owner; policy-beheer via een aparte sleutel; na de cutover de swap-signer-sleutel intrekken.

### M-09 — Low — Event-/state-sync is degelijk, met drie zwakke plekken

**Verwijzing:** bitburo (PR) `app/Console/Commands/SweepExecutionsCommand.php:94-142, 154-170, 205-242`, `app/Services/LedgerService.php::recordRebalance` (idempotent op `tx_hash` + `meta.log_index` onder user-lock), `app/Services/Privy/PrivyWebhookHandler.php::rebalancerLegVerdict`, `app/Services/WalletReconciler.php::hasRecentRebalancerExecution`.

**Beschrijving.** Veilig bevonden: sweep tot het `safe`-blok (geen reorg-dubbelboeking op Base zonder L1-reorg), idempotent per log, webhook-legs van contract-swaps worden herkend via tegenpartij/receipt/`Executed`-topic met owner-filter, en de reconciler wacht tot de ledger het contract heeft ingehaald (nooit een swap-output als storting boeken). Zwak: (a) een ondecodeerbaar log schuift de cursor definitief door → stille lacune (alleen een warning); (b) een chunk-fout stopt de run, maar met scale-to-zero en `withoutOverlapping(10)` kan de sweep uren stil liggen zonder alarm; (c) de cursor staat in de cache (`Cache::forever`) — een flush valt terug op ledger/deploy-blok, prima, maar bij een verkeerd `BITBURO_REBALANCER_DEPLOY_BLOCK` (bijv. 0 na redeploy) start hij 2000 blokken onder `safe` en mist alles daarvóór.

**Testdekking.** Pest `SweepExecutionsCommandTest` (22 tests, incl. reorg-grens, dubbele logs, cursor-fallbacks), `LedgerRecordRebalanceTest` (6), `PrivyWebhookHandlerTest` (rebalancer-leg), `ReconcileWalletCommandTest` (skip-logica). Goed.

**Fix.** Alarm (Sentry) wanneer `ReconcileWalletsCommand` een wallet > 24u in `skipped_recent_execution` houdt (de log is er al; maak er een notificatie van); bij een ondecodeerbaar log niet stil doorschuiven maar falen.

### M-10 — Info — `setParams` reset `lastExecutedAt` niet; intrekken zet params uit maar laat allowances staan tot de aparte approve(0)

**Verwijzing:** contracts `src/Rebalancer.sol:197-212, 303`; bitburo `strategy-card.tsx:898-915` (doet beide), `rebalancer-state.ts::revokeSteps`.

**Beschrijving.** Gedrag klopt en de UI dekt het (revoke = approve(0) × 2 + `active=false`; een half-getekend mandaat wordt herkend als "incomplete"). Aandachtspunt: een user die alleen `active=false` tekent (bijv. door een afgebroken flow) houdt max-allowances; de kaart toont dat als "gepauzeerd". Documenteer dat "pauze" ≠ "intrekken".

**Testdekking.** Forge `test_execute_secondRunAfterIntervalUsesNewState`, `test_execute_revertsInactiveWhenDeactivated`; Vitest `rebalancer-state.test.ts` (revokeSteps); Browser `StrategyTest` ("shows a half-signed mandate as incomplete", "takes back the open approval…").

### M-11 — Info — Configuratiedrift in de band maakt elk bestaand mandaat "verouderd"

**Verwijzing:** bitburo `config/bitburo.php:89` (default `rebalance_band` 0.05), lokale `.env` (0.02 volgens `config:show`), on-chain `bandBps = 200`; `RebalancerMandateReader::isOutdated`.

**Beschrijving.** De kaart vergelijkt on-chain params met de actuele config; elke wijziging van `BITBURO_AUTO_*` in productie dwingt alle gebruikers tot her-tekenen (met MFA). Geen veiligheidsprobleem, wel een operationeel besluit dat gedocumenteerd hoort te zijn — en het toont dat de "Bitburo-standaard" die de gebruiker tekent per omgeving verschilt (zie M-03).

---

## Veilig bevonden

- **Registratie:** `setParams` schrijft uitsluitend `params[msg.sender]` (`Rebalancer.sol:206`); noch Laravel, noch de server-signer, noch de keeper-wallet kan params van een gebruiker zetten of wijzigen. De swap-only policy DENY't `eth_sendTransaction`, `eth_signTransaction`, `wallet_sendCalls` en `eth_signUserOperation` (`SetupSwapPolicyCommand.php:129-132`), en Privy laat DENY winnen — de server-signer kan dus geen `approve`, `setParams` of "unregister" sturen. De keeper-policy staat alleen `execute(*, treasury)` toe.
- **Execute:** permissionless maar de aanroeper kiest alleen het moment; bedrag, richting, `minOut` (oracle − slippage) en fee komen uit het contract; `rewardTo` ≤ `min(0,05 EURC, fee)`; `TREASURY` immutable; `nonReentrant` (transient); sequencer-, staleness- en spot-vs-oracle-checks; `lastExecutedAt` pas na een geslaagde run (`test_execute_lastExecutedAtNotSetOnRevert`). Invarianten: owner-balansen bewegen alleen via `execute`, contract houdt nooit saldo, treasury monotoon (64 runs × 32 diepte, groen).
- **Fee-model:** vast 25 bps, alleen in EURC, alleen naar treasury/rewardTo; geen weg om meer dan de fee uit een wallet te halen.
- **Laravel-keeper:** simuleert eerst (`eth_call` vanaf nuladres), idempotency-key gebonden aan `lastExecutedAt`, backoff na 3 fouten/3u, loopt eigen users af (geen register-DoS via de Laravel-keeper), gate = `isDue` (mandaat) in PR #143.
- **Frontend-encoding:** alle selectors (`isDue`, `execute`, `params`, `lastExecutedAt`, `setParams`, `approve`, `allowance`) en het `Executed`-topic komen exact overeen met `cast sig`/`cast keccak`.
- **Revoke-pad:** aanwezig in de UI (`strategy-card.tsx` revoke-dialoog) en werkt op de chain (geverifieerd in het geheugen op 14-09); MFA verplicht.

## Testgaten

1. Forge: geen test voor uithongering/kostenasymmetrie van `dueOwners` bij dust-owners (M-02); geen test met `minTradeEurc = 1` en 1 EURC saldo als "due".
2. Forge: geen test die aantoont dat een owner met `maxCorrectionBps = 10000` in één run zijn hele positie verkoopt (fuzz dekt het rekenkundig, maar niet als expliciet "dit is toegestaan"-scenario voor M-03).
3. Pest/Vitest: geen test dat buiten-bereik `defaults` (cap > 1000, band < 100, interval < 86400) door de kaart geweigerd worden (M-03).
4. Pest: geen test voor een legacy-contractadres (allowance tonen/intrekken na redeploy) (M-04).
5. Pest: geen test dat een user met actief schema én actief mandaat niet dubbel handelt (M-07).
6. Pest: geen test/verificatie van de Privy-policyregels tegen de echte policy-engine (alle policy-tests vergelijken alleen de request-body); de residual-risk-methodes in de swap-policy zijn nergens afgedekt (M-01).
7. CRE: `main.test.ts` test de cap, niet de volgorde-afhankelijkheid (M-02).
8. Geen integratietest voor `bitburo:setup-keeper-wallet --update` na een adreswissel (policy sluit tot update; alleen unit-test op body).

## Adres-mismatches

Geen gevonden. Gecontroleerd:

| Adres | Deploy.s.sol | Fork-test | CRE config | Laravel config | On-chain |
|---|---|---|---|---|---|
| EURC `0x60a3…adb42` | ✓ | ✓ | – | ✓ (`bitburo.networks.base.assets.eurc`) | ✓ `EURC()` |
| cbBTC `0xcbB7…33Bf` | ✓ | ✓ | – | ✓ | ✓ `CBBTC()` |
| USDC `0x8335…2913`, Router `0x2626…e481`, pools `0x7279…66fB`/`0xfBB6…43ef`, feeds `0x07DA…9f9D`/`0xDAe3…8250`, sequencer `0xBCF8…6433` | ✓ | ✓ | feeds/sequencer ✓ | – | `ROUTER()` ✓ |
| Forwarder `0xF834…4482` | ✓ | (mock) | README ✓ | – | ✓ `FORWARDER()`, is contract |
| Rebalancer `0xED47…e6e5` | – | – | staging = production ✓ | via `BITBURO_REBALANCER_ADDRESS` (niet in repo) | ✓ |
| Chain 8453 / `ethereum-mainnet-base-1` | ✓ | ✓ | ✓ | ✓ (`bitburo.network = base` lokaal) | ✓ |
| Treasury `0xD6a4…98a9` | env `TREASURY` | – | – | `BITBURO_TREASURY_ADDRESS` lokaal = ✓ | ✓ `TREASURY()` |

Kanttekening (geen mismatch, wel drift): `rebalance_band` repo-default 0.05 ≠ lokale `.env` 0.02 = on-chain 200 bps (M-11); productie-`.env` kon ik niet inzien.
