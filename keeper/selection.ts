/**
 * Selectielogica van het keeper-script, los van RPC en bestandssysteem zodat het te testen is.
 */
import type { Address } from "viem";

export const EURC_UNIT = 1_000_000n;

/** Reden om een due owner over te slaan op grond van de run-omvang, of null als de run meedoet. */
export const runSizeSkipReason = (eurcDelta: bigint, minRunEurc: number): string | null => {
  const size = eurcDelta < 0n ? -eurcDelta : eurcDelta;
  if (size < BigInt(minRunEurc) * EURC_UNIT) {
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
};

export const isTemporaryFailure = (failure: Failure): boolean =>
  isBlockWindowRevert(failure.errorName) || failure.resimulationPassed === true;

/**
 * Wat te doen na een mislukte simulatie of transactie voor een owner, bij poging `attempt` (0 = eerste):
 * - "retry": tijdelijk (blokcheck, blokvenster of een on-chain revert die opnieuw gesimuleerd wel slaagt), probeer
 *   opnieuw in een volgend blok;
 * - "skip": na `maxRetries` nieuwe pogingen nog steeds tijdelijk; niets boeken, de volgende keeper-run probeert het
 *   weer;
 * - "fail": een echte mislukking, die telt voor de cool-down.
 */
export const failureAction = (
  failure: Failure | string | undefined,
  attempt: number,
  maxRetries: number,
): "retry" | "skip" | "fail" => {
  const f: Failure = typeof failure === "object" ? failure : { errorName: failure };
  if (!isTemporaryFailure(f)) {
    return "fail";
  }
  return attempt < maxRetries ? "retry" : "skip";
};

/**
 * Review I-1: `dueOwners` is een momentopname. Een owner die op dat moment niet due leek omdat een pool in dat blok
 * al aangeraakt was (door iemand anders, of door een eigen run), valt anders tot de volgende cron buiten de boot. De
 * keeper leest een pagina daarom minstens twee keer, elke keer in een later blok, en behandelt alleen owners die hij in
 * deze run nog niet had. Na de tweede lezing gaat hij alleen door zolang een lezing nog iemand nieuw oplevert, en
 * nooit verder dan `maxReads` lezingen.
 */
export const newOwners = (page: readonly Address[], handled: ReadonlySet<string>): Address[] =>
  page.filter((owner) => !handled.has(owner.toLowerCase()));

export const shouldReadPageAgain = (newInLastRead: number, reads: number, maxReads: number): boolean =>
  reads < maxReads && (reads < 2 || newInLastRead > 0);

/**
 * Een run die de tick van een pool verandert, raakt die pool voor de rest van het blok aan; een `eth_call` op dat blok
 * zou de volgende owner daarom onterecht als niet due of als PoolTouchedThisBlock zien. Lees en simuleer de volgende
 * owner (en de volgende pagina) dus pas in een blok ná de laatste geslaagde run.
 */
export const mustWaitForNextBlock = (latestBlock: bigint, lastRunBlock: bigint | null): boolean =>
  lastRunBlock !== null && latestBlock <= lastRunBlock;

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
