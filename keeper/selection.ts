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

export const formatEurc = (baseUnits: bigint): string => {
  const whole = baseUnits / EURC_UNIT;
  const fraction = (baseUnits % EURC_UNIT).toString().padStart(6, "0").replace(/0+$/, "");
  return fraction === "" ? whole.toString() : `${whole}.${fraction}`;
};

/**
 * Cool-down per owner na een mislukte execute. Het contract onthoudt mislukkingen niet (lastExecutedAt
 * wordt alleen bij succes gezet), dus een owner die structureel revert blijft due; zonder geheugen
 * zou elke run opnieuw gas kosten. De wachttijd verdubbelt per opeenvolgende mislukking tot `max`.
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
