/**
 * Selectielogica van het keeper-script, los van RPC en bestandssysteem zodat het te testen is.
 */
import type { Address, Hex } from "viem";

export const EURC_UNIT = 1_000_000n;

/** Reden om een due owner over te slaan op grond van de run-omvang, of null als de run meedoet. */
export const runSizeSkipReason = (eurcDelta: bigint, minRunEurc: number): string | null => {
  const size = eurcDelta < 0n ? -eurcDelta : eurcDelta;
  if (size < BigInt(Math.ceil(minRunEurc * Number(EURC_UNIT)))) {
    return `run te klein (${formatEurc(size)} EURC < ${minRunEurc} EURC)`;
  }
  return null;
};

/**
 * Reverts van de blokcheck en het blokvenster (audit M-1, review PR #18). Die zijn tijdelijk, dus ze tellen niet als
 * mislukking voor de cool-down; in een volgend blok lukt het meestal wel:
 * - PoolTouchedThisBlock(address pool), selector 0x817a53db: een pool schreef in dit blok al een oracle-observatie
 *   (een swap die de tick veranderde, of een mint of burn in de range), door iemand anders of door een eerdere run.
 *   Een `eth_call` op het laatste blok ziet dat ook als er in dát blok iets in de pool gebeurde.
 * - BlockMoveExceeded(address pool), selector 0x66356d6d: te weinig ruimte of liquiditeit in het venster, of de run
 *   haalde de vensterrand.
 */
export const BLOCK_WINDOW_ERRORS: readonly string[] = ["PoolTouchedThisBlock", "BlockMoveExceeded"];

export const isBlockWindowRevert = (errorName: string | undefined): boolean =>
  errorName !== undefined && BLOCK_WINDOW_ERRORS.includes(errorName);

/**
 * Wat een mislukking is: de naam van de contract-error (als die te decoderen was), en of het een transactie was die
 * on-chain revertte terwijl een nieuwe simulatie op het blok van die transactie slaagt. Dat laatste wijst op een
 * tijdelijke stand vóór de transactie in hetzelfde blok (bijvoorbeeld een swap die het venster vulde), niet op een
 * owner die structureel revert.
 */
export type Failure = {
  errorName: string | undefined;
  resimulationPassed?: boolean;
  /**
   * Geen revert van het contract maar een fout van de node of het netwerk (429, timeout, "header not found"). Zegt niets
   * over de owner, dus geen cool-down.
   */
  transient?: boolean;
  /**
   * Eindreview F-1: de owner is in hetzelfde blok vóór de eigen transactie al door een andere keeper uitgevoerd (een
   * `Executed`-log voor die owner met een lagere `transactionIndex`). Geen blokkade en geen mislukking: de owner is
   * bediend. Geen nieuwe poging, geen cool-down, geen hogere tip.
   */
  servedByOther?: boolean;
};

export const isTemporaryFailure = (failure: Failure): boolean =>
  isBlockWindowRevert(failure.errorName) || failure.resimulationPassed === true || failure.transient === true;

/**
 * Uitkomst van de hersimulatie na een eigen transactie die on-chain revertte: op de staat aan het begin van dat blok
 * (vorig blok, met de overrides van het blok zelf), zodat alleen transacties vóór de eigen transactie het verschil
 * kunnen maken en niet wat er ná kwam.
 */
export type Resimulation = { kind: "passed" } | { kind: "reverted"; errorName: string | undefined } | { kind: "error" };

/**
 * Oordeel over een on-chain revert:
 * - staat vóór de eigen transactie een `Executed` voor dezelfde owner (`servedBefore`), dan heeft een andere keeper de
 *   run gedaan: bediend, geen blokkade, geen cool-down (eindreview F-1). Dat gaat vóór alles, want elke `execute`
 *   swapt door beide pools en logt daar een Swap; zonder deze regel zag elke verloren race eruit als een blokkade;
 * - de hersimulatie slaagt: iets eerder in het blok liet de transactie reverten; tijdelijk;
 * - de hersimulatie revert met een blokvenster-error, of de node gaf een fout: tijdelijk;
 * - de hersimulatie revert met een andere error: die error is de echte reden (cool-down);
 * - `blockade`: tijdelijk én een transactie vóór de eigen raakte een pool aan (Swap, Mint of Burn) en was zelf geen
 *   directe `execute` op de Rebalancer (`blockingTransactions`). Alleen dan loopt de priority fee op; een eerdere
 *   feed-update of een andere keeper die een owner uitvoerde, is geen reden om meer te bieden.
 */
export const onchainRevertVerdict = (
  resimulation: Resimulation,
  touchedBefore: boolean,
  servedBefore = false,
): { failure: Failure; blockade: boolean } => {
  if (servedBefore) {
    return { failure: { errorName: undefined, servedByOther: true }, blockade: false };
  }
  const failure: Failure =
    resimulation.kind === "passed"
      ? { errorName: undefined, resimulationPassed: true }
      : resimulation.kind === "error"
        ? { errorName: undefined, transient: true }
        : { errorName: resimulation.errorName };
  return { failure, blockade: touchedBefore && isTemporaryFailure(failure) };
};

/**
 * Wat te doen na een mislukte simulatie of transactie voor een owner (audit L-3):
 * - "retry": tijdelijk (blokcheck, blokvenster of een on-chain revert die opnieuw gesimuleerd wel slaagt), probeer
 *   opnieuw in een volgend blok, zolang het retry-budget van deze keeper-run loopt (`nowSeconds < retryDeadline`);
 * - "skip": het budget is op en het is nog steeds tijdelijk; niets boeken, de volgende keeper-run probeert het weer;
 * - "fail": een echte mislukking, die telt voor de cool-down.
 * Een owner die een andere keeper in hetzelfde blok al uitvoerde (`servedByOther`), is altijd "skip".
 *
 * Het budget is een tijd en geen aantal pogingen: een aanvaller die een pool elk blok aanraakt, moet dat dan het hele
 * budget volhouden, niet alleen een paar voorspelbare blokken.
 */
export const failureAction = (
  failure: Failure | string | undefined,
  nowSeconds: number,
  retryDeadline: number,
): "retry" | "skip" | "fail" => {
  const f: Failure = typeof failure === "object" ? failure : { errorName: failure };
  if (f.servedByOther === true) {
    return "skip";
  }
  if (!isTemporaryFailure(f)) {
    return "fail";
  }
  return nowSeconds < retryDeadline ? "retry" : "skip";
};

/**
 * Eind van het retry-budget van een keeper-run: `RETRY_SECONDS` na de start. Standaard 540 s, het advies om elke
 * 10 minuten te draaien min een minuut marge, zodat de run klaar is voordat de volgende begint.
 */
export const retryDeadline = (startSeconds: number, retrySeconds: number): number => startSeconds + retrySeconds;

/**
 * Review I-1: een lezing van `isDue` (per portie kandidaten) is een momentopname. Een owner die op dat moment niet due
 * leek omdat een pool in dat blok al aangeraakt was (door iemand anders, of door een eigen run), valt anders tot de
 * volgende cron buiten de boot. De keeper leest een portie daarom minstens twee keer, elke keer in een later blok, en behandelt alleen owners die hij in
 * deze run nog niet had. Na de tweede lezing gaat hij alleen door zolang een lezing nog iemand nieuw oplevert, en
 * nooit verder dan `maxReads` lezingen.
 *
 * Leest de keeper met de overrides van het volgende blok (`nextBlockOverrides`), dan ziet hij geen aanraking uit het
 * laatste blok en is één lezing genoeg; de dubbele lezing geldt alleen bij de terugval op het laatste blok.
 */
export const newOwners = (page: readonly Address[], handled: ReadonlySet<string>): Address[] =>
  page.filter((owner) => !handled.has(owner.toLowerCase()));

export const shouldReadPageAgain = (
  newInLastRead: number,
  reads: number,
  maxReads: number,
  readsNextBlock = false,
): boolean => !readsNextBlock && reads < maxReads && (reads < 2 || newInLastRead > 0);

// ─── Audit L-3: lezen alsof het het volgende blok is ─────────────────────────────────────────────────────────────

/** Tijd tussen twee blokken op Base. */
export const BASE_BLOCK_SECONDS = 2n;

export type BlockOverrides = { number: bigint; time: bigint };

/**
 * Overrides waarmee een `eth_call` op de state van het laatste blok draait alsof het het volgende blok is. Het
 * contract vergelijkt de laatste observatie van een pool met `block.timestamp`; in het volgende blok is een aanraking
 * uit het laatste blok dus geen aanraking meer. Zonder dit ziet de keeper een aanraking in het laatste blok als "niet
 * due" en verstuurt hij niets, en hoeft een aanvaller niet eens vóór de keeper in het blok te staan (L-3).
 */
export const nextBlockOverrides = (latest: { number: bigint; timestamp: bigint }): BlockOverrides => ({
  number: latest.number + 1n,
  time: latest.timestamp + BASE_BLOCK_SECONDS,
});

/**
 * Creation code die `block.timestamp` en `block.number` teruggeeft (TIMESTAMP PUSH1 0 MSTORE NUMBER PUSH1 0x20 MSTORE
 * PUSH1 0x40 PUSH1 0 RETURN). Als `eth_call` zonder `to` laat de keeper de node dit uitvoeren met de overrides, om te
 * controleren dat de node ze toepast. Zelfde probe als de app-keeper.
 */
export const OVERRIDE_PROBE_CODE = "0x426000524360205260406000f3" as const;

/**
 * Past de node de overrides toe? Alleen als precies de overschreven timestamp en het overschreven bloknummer
 * terugkomen: een node die een onbekende override negeert, geeft geen fout maar de echte waarden.
 */
export const overridesApplied = (returnData: string | undefined, overrides: BlockOverrides): boolean => {
  if (returnData === undefined || !/^0x[0-9a-fA-F]{128}$/.test(returnData)) {
    return false;
  }
  const time = BigInt(`0x${returnData.slice(2, 66)}`);
  const number = BigInt(`0x${returnData.slice(66, 130)}`);
  return time === overrides.time && number === overrides.number;
};

// ─── Audit L-3: priority fee ────────────────────────────────────────────────────────────────────────────────────

export const GWEI = 1_000_000_000n;

/** wei → gwei als tekst, zonder nullen achteraan ("0.05"). */
export const formatGwei = (wei: bigint): string => {
  const fraction = (wei % GWEI).toString().padStart(9, "0").replace(/0+$/, "");
  return fraction === "" ? `${wei / GWEI}` : `${wei / GWEI}.${fraction}`;
};

/** "0.05" gwei → wei, zonder afrondingsfouten van een float. */
export const parseGwei = (value: string): bigint => {
  const match = /^(\d+)(?:\.(\d{1,9}))?$/.exec(value.trim());
  if (match === null) {
    throw new Error(`geen geldig aantal gwei: ${value}`);
  }
  return BigInt(match[1]) * GWEI + BigInt((match[2] ?? "").padEnd(9, "0"));
};

export type FeePolicy = {
  /** Priority fee zonder blokkade (PRIORITY_FEE_GWEI, standaard 0,05 gwei). */
  base: bigint;
  /** Plafond (MAX_PRIORITY_FEE_GWEI, standaard 3 gwei). */
  max: bigint;
};

/**
 * Priority fee na een blokkade: een eigen transactie die on-chain revertte door een tijdelijke oorzaak, dus omdat een
 * andere transactie eerder in hetzelfde blok een pool aanraakte of het venster vulde.
 *
 * Base ordent binnen een Flashblock op priority fee; wie vóór de aanraker staat, draait. De stap:
 * - minstens een verdubbeling. Van 0,05 naar het plafond van 3 gwei zijn dat 6 stappen (0,1 – 0,2 – 0,4 – 0,8 – 1,6 –
 *   3). Met gemiddeld één verzending per `SEND_RETRY_BLOCKS` (standaard 30 blokken ≈ 1 minuut) zit de keeper
 *   binnen ~6 minuten, dus binnen één run van 10 minuten, op het plafond; bij een stap van +25% zijn dat 19 pogingen en
 *   verliest hij twee runs. Tegelijk betaalt hij hooguit het dubbele van de tip die nodig was.
 * - is de tip van de aanraker bekend (`blockerTip`), dan direct 10% daarboven als dat meer is: één poging in plaats
 *   van een reeks verdubbelingen, en een marge tegen een aanvaller die zijn tip steeds een beetje verhoogt.
 * - nooit boven `max`. Bij 3 gwei kost blokkeren de aanvaller ~1.050 EURC per uur (92.630 gas per blok × 1.800 blokken,
 *   gemeten gas; L-3-metingen), tegen ~15 EURC per uur voor de keeper (één gerevertte poging van ~40k gas per minuut).
 */
export const nextPriorityFee = (current: bigint, blockerTip: bigint | undefined, policy: FeePolicy): bigint => {
  let next = current * 2n;
  if (blockerTip !== undefined) {
    const outbid = (blockerTip * 11n + 9n) / 10n + 1n;
    if (outbid > next) next = outbid;
  }
  if (next < policy.base) next = policy.base;
  return next > policy.max ? policy.max : next;
};

/** Opgeslagen priority fee tussen keeper-runs (`FEE_STATE_FILE`). */
export type FeeState = { priorityFeeWei: string; lastBlockadeAt: number };

/**
 * Priority fee aan het begin van een run. Zonder geheugen zou elke run weer op de basis beginnen en weer ~6 blokkades
 * nodig hebben om het plafond te halen; de aanvaller betaalt dan vooral lage tips. Daarom houdt de keeper de tip vast
 * zolang de laatste blokkade minder dan `holdSeconds` (FEE_HOLD_SECONDS, standaard 3600) geleden is, en begint hij
 * daarna weer op de basis. Zonder aanval kost dat hooguit een uur runs op de verhoogde tip.
 */
export const startPriorityFee = (
  state: FeeState | undefined,
  nowSeconds: number,
  policy: FeePolicy,
  holdSeconds: number,
): bigint => {
  if (state === undefined || nowSeconds - state.lastBlockadeAt >= holdSeconds) {
    return policy.base;
  }
  const fee = BigInt(state.priorityFeeWei);
  if (fee < policy.base) return policy.base;
  return fee > policy.max ? policy.max : fee;
};

export const parseFeeState = (json: string): FeeState | undefined => {
  const parsed: unknown = JSON.parse(json);
  if (
    parsed === null ||
    typeof parsed !== "object" ||
    typeof (parsed as FeeState).priorityFeeWei !== "string" ||
    !/^\d+$/.test((parsed as FeeState).priorityFeeWei) ||
    typeof (parsed as FeeState).lastBlockadeAt !== "number"
  ) {
    return undefined;
  }
  return { priorityFeeWei: (parsed as FeeState).priorityFeeWei, lastBlockadeAt: (parsed as FeeState).lastBlockadeAt };
};

/**
 * `maxFeePerGas` bij een gekozen priority fee: twee keer de base fee van het laatste blok plus de tip. De transactie
 * betaalt de werkelijke base fee plus de tip; het dubbele is ruimte voor een stijgende base fee tot de opname.
 * Beide fees worden expliciet meegegeven, anders schat viem ze allebei zelf en verdwijnt de gekozen tip.
 */
export const maxFeePerGas = (baseFeePerGas: bigint, priorityFee: bigint): bigint => baseFeePerGas * 2n + priorityFee;

/** Werkelijke tip van een opgenomen transactie: min(maxPriorityFeePerGas, maxFeePerGas − base fee), of gasPrice − base fee. */
export const effectiveTip = (
  tx: { maxPriorityFeePerGas?: bigint; maxFeePerGas?: bigint; gasPrice?: bigint },
  baseFeePerGas: bigint,
): bigint => {
  if (tx.maxPriorityFeePerGas !== undefined && tx.maxFeePerGas !== undefined) {
    const headroom = tx.maxFeePerGas - baseFeePerGas;
    return tx.maxPriorityFeePerGas < headroom ? tx.maxPriorityFeePerGas : headroom;
  }
  const price = tx.gasPrice ?? baseFeePerGas;
  return price > baseFeePerGas ? price - baseFeePerGas : 0n;
};

/**
 * Hoogste tip van de transacties die vóór de eigen transactie in het blok een pool aanraakten (een log van een van
 * beide pools, met een lagere `transactionIndex`). `undefined` als er geen is.
 */
export const blockerTip = (
  poolTxs: readonly { transactionIndex: number; tip: bigint }[],
  ownIndex: number,
): bigint | undefined =>
  poolTxs
    .filter((tx) => tx.transactionIndex < ownIndex)
    .reduce<bigint | undefined>((max, tx) => (max === undefined || tx.tip > max ? tx.tip : max), undefined);

/** Selector van `execute(address,address)` op de Rebalancer. */
export const EXECUTE_SELECTOR = "0xd80aea15" as const;

/**
 * Eindreview F-1: is deze transactie een directe `execute` op de Rebalancer? Zo'n transactie swapt door beide pools en
 * laat dus Swap-logs achter, maar is een andere keeper die een owner bedient, geen aanvaller die de pool aanraakt. Een
 * contract dat een aanraking en een `execute` bundelt, is geen directe aanroep en telt wel als aanraker.
 */
export const isDirectExecute = (tx: { to?: Address | null; input?: Hex }, rebalancer: Address): boolean =>
  tx.to != null &&
  tx.to.toLowerCase() === rebalancer.toLowerCase() &&
  tx.input !== undefined &&
  tx.input.slice(0, 10).toLowerCase() === EXECUTE_SELECTOR;

/**
 * Transacties vóór de eigen transactie die een pool aanraakten (een pool-log met een lagere `transactionIndex`), zonder
 * directe `execute`'s op de Rebalancer (`isDirectExecute`). Alleen die tellen voor een blokkade en voor `blockerTip`.
 */
export const blockingTransactions = <T extends { transactionIndex: number; to?: Address | null; input?: Hex }>(
  poolTxs: readonly T[],
  ownIndex: number,
  rebalancer: Address,
): T[] => poolTxs.filter((tx) => tx.transactionIndex < ownIndex && !isDirectExecute(tx, rebalancer));

/**
 * Eindreview F-1: staat er vóór de eigen transactie (`ownIndex`) een `Executed`-log voor `owner`? Dan heeft een andere
 * keeper die owner in dit blok al bediend.
 */
export const servedBefore = (
  executedLogs: readonly { owner: Address; transactionIndex: number }[],
  owner: Address,
  ownIndex: number,
): boolean =>
  executedLogs.some((log) => log.transactionIndex < ownIndex && log.owner.toLowerCase() === owner.toLowerCase());

/**
 * Eindreview F-1: de tip zakt weer. Na een eigen transactie die geen blokkade was (geslaagd, of bediend door een ander),
 * en aan het eind van een run zonder blokkade en zonder eigen transactie, halveert de tip, niet lager dan de basis. Van
 * het plafond van 3 gwei naar 0,05 gwei zijn dat 6 stappen: bij een run per 10 minuten zonder concurrentie hooguit een
 * uur, en sneller zodra runs slagen. Halveren (en niet meteen de basis) houdt een aanvaller die even stopt niet
 * goedkoop: hij moet een reeks blokken laten lopen voordat de tip weer laag is.
 */
export const decayPriorityFee = (current: bigint, policy: FeePolicy): bigint => {
  const next = current / 2n;
  if (next < policy.base) return policy.base;
  return next > policy.max ? policy.max : next;
};

export const BPS = 10_000n;

/**
 * Omrekening van EURC-basiseenheden (6 decimalen) naar wei, met twee Chainlink-koersen van 8 decimalen (EURC/USD en
 * ETH/USD): wei = eurc × 10^12 × EURC/USD ÷ ETH/USD. 0 bij een ongeldige koers.
 */
export const eurcToWei = (eurcBaseUnits: bigint, eurcUsd: bigint, ethUsd: bigint): bigint =>
  eurcUsd <= 0n || ethUsd <= 0n ? 0n : (eurcBaseUnits * 10n ** 12n * eurcUsd) / ethUsd;

/**
 * Eindreview F-1: plafond van de tip uit wat een run oplevert. Per geslaagde run betaalt de keeper tip × gas aan de
 * sequencer en krijgt hij de beloning (`rewardWei`, KEEPER_REWARD_EURC in wei; 0 zonder REWARD_TO). De tip mag daarom
 * niet hoger zijn dan
 *
 *   tip × gasEstimate ≤ rewardShareBps / 10.000 × rewardWei + budgetWei
 *
 * - `rewardShareBps` (TIP_REWARD_SHARE_BPS): welk deel van de beloning de keeper aan tip wil uitgeven;
 * - `budgetWei` (TIP_BUDGET_ETH, standaard 0,0015 ETH): wat hij per run bovenop de beloning wil betalen om een blokkade
 *   te breken (L-3). De standaard houdt het plafond van 3 gwei bereikbaar (3 gwei × 500.000 gas = 0,0015 ETH), waarop
 *   het L-3-criterium van ≥ 1.000 EURC per uur voor de aanvaller rust. Bij 0 is er geen verhoging boven wat de beloning
 *   dekt, en hoeft een aanvaller die elk blok aanraakt alleen meer te bieden dan dat;
 * - `gasEstimate` (GAS_ESTIMATE): gas van een geslaagde run, niet de GAS_LIMIT: de tip wordt over het verbruikte gas
 *   betaald (gemeten 475.267 voor een koop op blok 51.403.300). Een gerevertte poging verbruikt minder.
 *
 * Zo kan concurrentie tussen keepers de tip nooit opdrijven tot boven wat de keeper per run wil betalen, ook niet als
 * die tot het plafond van MAX_PRIORITY_FEE_GWEI zou oplopen. Het plafond is nooit lager dan de basistip: die blijft
 * nodig om te versturen.
 */
export const capFeePolicy = (
  policy: FeePolicy,
  input: { rewardWei: bigint; rewardShareBps: bigint; budgetWei: bigint; gasEstimate: bigint },
): FeePolicy => {
  if (input.gasEstimate <= 0n) return policy;
  const cap = ((input.rewardWei * input.rewardShareBps) / BPS + input.budgetWei) / input.gasEstimate;
  const max = cap < policy.max ? cap : policy.max;
  return { base: policy.base, max: max < policy.base ? policy.base : max };
};

/**
 * Na een blokkade verstuurt de keeper pas weer na een willekeurig aantal blokken, gemiddeld `sendRetryBlocks`
 * (uniform 1 tot 2 × `sendRetryBlocks` − 1; simuleren mag elk blok). Twee redenen:
 * - een gerevertte poging kost ~40k gas; gemiddeld één per ~30 blokken (≈ 1 minuut) houdt de kosten voor de keeper
 *   onder aanval rond 1/69 van die van de aanvaller, die elk blok moet aanraken (L-3-metingen);
 * - willekeurig, want de gerevertte transactie staat on-chain: bij een vaste wachttijd weet de aanvaller precies in
 *   welk blok de volgende poging komt en hoeft hij alleen dáár een hoge tip te betalen. Nu moet hij dat in elk blok
 *   van het hele bereik.
 * `random` in [0, 1), bijvoorbeeld `Math.random()`; één keer trekken per blokkade.
 */
export const nextSendBlock = (blockadeBlock: bigint, sendRetryBlocks: number, random: number): bigint => {
  const span = 2 * sendRetryBlocks - 1;
  const offset = Math.min(Math.floor(random * span), span - 1);
  return blockadeBlock + 1n + BigInt(Math.max(offset, 0));
};

// ─── Audit lead 9: registratiespam ─────────────────────────────────────────────────────────────────────────────

export const CBBTC_UNIT = 100_000_000n;

/** Wat de keeper van een geregistreerde owner leest om vooraf te filteren (één multicall per portie). */
export type OwnerFunds = {
  owner: Address;
  active: boolean;
  eurcBalance: bigint;
  eurcAllowance: bigint;
  cbbtcBalance: bigint;
  cbbtcAllowance: bigint;
};

const min = (a: bigint, b: bigint): bigint => (a < b ? a : b);

/**
 * Grootste run die het contract voor deze owner ooit kan doen, per richting, in EURC-basiseenheden. `_plan` begrenst
 * de input op min(saldo, allowance) van het input-token: bij kopen EURC, bij verkopen cbBTC tegen de feedkoers
 * (`quote()`, afgerond naar beneden zoals `Math.mulDiv`), en de run moet minstens MIN_TRADE_FLOOR zijn.
 */
export const maxRunValues = (funds: OwnerFunds, priceEurcPerBtc: bigint): { buy: bigint; sell: bigint } => ({
  buy: min(funds.eurcBalance, funds.eurcAllowance),
  sell: (min(funds.cbbtcBalance, funds.cbbtcAllowance) * priceEurcPerBtc) / CBBTC_UNIT,
});

/**
 * Lead 9: filter het register off-chain vóór `isDue`. Een owner blijft over als hij actief is en in minstens één
 * richting een run van `minRun` kan halen (min(saldo, allowance) van het input-token). Dat is een noodzakelijke
 * voorwaarde van het contract (`value >= min(run, minTradeEurc)` met run en minTradeEurc allebei ≥ MIN_TRADE_FLOOR),
 * dus met `minRun` = max(MIN_TRADE_FLOOR, MIN_RUN_EURC) valt er geen owner af die de keeper anders zou uitvoeren. Een
 * lege of allowance-loze spam-registratie valt wel af: wie de keeper wil ophouden, moet per adres minstens die waarde
 * met allowance aanhouden.
 */
export const isCandidate = (funds: OwnerFunds, priceEurcPerBtc: bigint, minRun: bigint): boolean => {
  if (!funds.active) {
    return false;
  }
  const { buy, sell } = maxRunValues(funds, priceEurcPerBtc);
  return buy >= minRun || sell >= minRun;
};

export const filterCandidates = (rows: readonly OwnerFunds[], priceEurcPerBtc: bigint, minRun: bigint): Address[] =>
  rows.filter((row) => isCandidate(row, priceEurcPerBtc, minRun)).map((row) => row.owner);

/** Ondergrens voor het filter: de grootste van MIN_TRADE_FLOOR (contract) en MIN_RUN_EURC (keeper), in basiseenheden. */
export const minRunBaseUnits = (minTradeFloor: bigint, minRunEurc: number): bigint => {
  const keeper = BigInt(Math.ceil(minRunEurc * Number(EURC_UNIT)));
  return keeper > minTradeFloor ? keeper : minTradeFloor;
};

export const chunks = <T>(items: readonly T[], size: number): T[][] => {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
};

/**
 * Vroegste blok voor de volgende poging voor een owner:
 * - ná de vorige poging voor die owner (`retryAfterBlock`) en ná de laatste eigen transactie (`lastRunBlock`). Een run
 *   die de tick van een pool verandert, raakt die pool voor de rest van het blok aan; lees en simuleer de volgende
 *   owner (en de volgende pagina) dus pas in een later blok;
 * - na een blokkade niet vóór `sendFrom` (`nextSendBlock`); `throttled` zegt dat die grens bepaalt.
 * `target` null: niet wachten.
 */
export const nextAttemptBlock = (
  retryAfterBlock: bigint | null,
  lastRunBlock: bigint | null,
  sendFrom: bigint | null,
): { target: bigint | null; throttled: boolean } => {
  const after = retryAfterBlock !== null && (lastRunBlock === null || retryAfterBlock > lastRunBlock) ? retryAfterBlock : lastRunBlock;
  const target = after === null ? null : after + 1n;
  if (sendFrom !== null && (target === null || sendFrom > target)) {
    return { target: sendFrom, throttled: true };
  }
  return { target, throttled: false };
};

export const formatEurc = (baseUnits: bigint): string => {
  const whole = baseUnits / EURC_UNIT;
  const fraction = (baseUnits % EURC_UNIT).toString().padStart(6, "0").replace(/0+$/, "");
  return fraction === "" ? whole.toString() : `${whole}.${fraction}`;
};

/**
 * Cool-down per owner na een mislukte execute. Het contract onthoudt mislukkingen niet (lastExecutedAt
 * wordt alleen bij succes gezet), dus een owner die structureel revert blijft due; zonder geheugen
 * zou elke run opnieuw gas kosten. De wachttijd verdubbelt per opeenvolgende mislukking tot `max`.
 * Tijdelijke mislukkingen tellen niet mee (zie `failureAction`).
 */
export type CooldownEntry = {
  /** Unix-seconden tot wanneer de owner wordt overgeslagen. */
  until: number;
  /** Aantal opeenvolgende mislukkingen. */
  failures: number;
  /** Eerste regel van de laatste foutmelding. */
  lastError: string;
};

export type CooldownState = Record<string, CooldownEntry>;

export type CooldownPolicy = {
  baseSeconds: number;
  maxSeconds: number;
};

const key = (owner: Address): string => owner.toLowerCase();

export const cooldownUntil = (state: CooldownState, owner: Address): number | null => state[key(owner)]?.until ?? null;

export const isCoolingDown = (state: CooldownState, owner: Address, nowSeconds: number): boolean => {
  const until = cooldownUntil(state, owner);
  return until !== null && nowSeconds < until;
};

export const recordFailure = (
  state: CooldownState,
  owner: Address,
  nowSeconds: number,
  error: string,
  policy: CooldownPolicy,
): CooldownState => {
  const failures = (state[key(owner)]?.failures ?? 0) + 1;
  const wait = Math.min(policy.baseSeconds * 2 ** (failures - 1), policy.maxSeconds);
  return { ...state, [key(owner)]: { until: nowSeconds + wait, failures, lastError: error.split("\n")[0] } };
};

export const clearFailure = (state: CooldownState, owner: Address): CooldownState => {
  if (state[key(owner)] === undefined) {
    return state;
  }
  const { [key(owner)]: _, ...rest } = state;
  return rest;
};

/** Laat verlopen cool-downs vallen zodat het bestand niet blijft groeien. */
export const pruneExpired = (state: CooldownState, nowSeconds: number): CooldownState =>
  Object.fromEntries(Object.entries(state).filter(([, entry]) => nowSeconds < entry.until));

export const parseCooldownState = (json: string): CooldownState => {
  const parsed: unknown = JSON.parse(json);
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("cool-down-bestand is geen JSON-object");
  }
  const state: CooldownState = {};
  for (const [owner, entry] of Object.entries(parsed as Record<string, unknown>)) {
    if (
      entry === null ||
      typeof entry !== "object" ||
      typeof (entry as CooldownEntry).until !== "number" ||
      typeof (entry as CooldownEntry).failures !== "number"
    ) {
      throw new Error(`cool-down-bestand: ongeldige regel voor ${owner}`);
    }
    const { until, failures, lastError } = entry as CooldownEntry;
    state[owner.toLowerCase()] = { until, failures, lastError: typeof lastError === "string" ? lastError : "" };
  }
  return state;
};
