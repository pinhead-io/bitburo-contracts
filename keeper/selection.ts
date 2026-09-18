/**
 * Pure logic of the keeper script: no network, no files, no clock. Everything here is covered by `selection.test.ts`.
 */
import { type Address, isAddress } from "viem";

export const BPS = 10_000n;

const same = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase();

// ─── Which owners ──────────────────────────────────────────────────────────────────────────────────────────────

/** `mandates(owner)` of the Rebalancer. `targetBps` 0 = no mandate. */
export type Mandate = { targetBps: number; lastExecutedAt: bigint; unfinished: boolean; keeper: Address };

/** The contract's own rule: `execute(owner, …)` only accepts the owner or the keeper that owner appointed. */
export const mayRun = (mandate: Mandate, owner: Address, caller: Address): boolean =>
  mandate.targetBps > 0 && (same(owner, caller) || same(mandate.keeper, caller));

/**
 * `OWNERS_FILE`: addresses this keeper serves, next to the ones it finds in the `MandateSet` events. Separated by
 * whitespace or commas; `#` starts a comment until the end of the line. An invalid address is an error (better not
 * to start than to silently skip a user); duplicates count once, regardless of case. Strict like viem when it
 * encodes: a mixed-case address needs a valid EIP-55 checksum, because a wrong checksum usually means a typo.
 */
export const parseOwnersFile = (text: string): Address[] => {
  const seen = new Set<string>();
  const out: Address[] = [];
  for (const line of text.split(/\r?\n/)) {
    for (const token of line.replace(/#.*$/, "").split(/[\s,]+/)) {
      if (token === "") continue;
      if (!isAddress(token, { strict: false })) throw new Error(`OWNERS_FILE: not a valid address: ${token}`);
      if (!isAddress(token)) throw new Error(`OWNERS_FILE: invalid checksum (EIP-55): ${token}`);
      if (seen.has(token.toLowerCase())) continue;
      seen.add(token.toLowerCase());
      out.push(token as Address);
    }
  }
  return out;
};

/** All lists in order, every address once (case-insensitive). */
export const mergeOwners = (...lists: readonly (readonly Address[])[]): Address[] => {
  const seen = new Set<string>();
  const out: Address[] = [];
  for (const owner of lists.flat()) {
    if (seen.has(owner.toLowerCase())) continue;
    seen.add(owner.toLowerCase());
    out.push(owner);
  }
  return out;
};

export const chunks = <T>(items: readonly T[], size: number): T[][] => {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
};

// ─── Finding owners in the MandateSet events ───────────────────────────────────────────────────────────────────

/** What the keeper remembers between runs: the owners it found and the first block it has not searched yet. */
export type OwnersState = { nextBlock: bigint; owners: Address[] };

/** State from the file, or a fresh state that starts at `fromBlock`. Garbage is an error: never search from 0 by accident. */
export const parseOwnersState = (json: string | undefined, fromBlock: bigint): OwnersState => {
  if (json === undefined) return { nextBlock: fromBlock, owners: [] };
  const parsed: unknown = JSON.parse(json);
  if (parsed === null || typeof parsed !== "object") throw new Error("owners state file is not a JSON object");
  const { nextBlock, owners } = parsed as { nextBlock?: unknown; owners?: unknown };
  if (typeof nextBlock !== "string" || !/^\d+$/.test(nextBlock)) throw new Error("owners state file: invalid nextBlock");
  if (!Array.isArray(owners) || !owners.every((o) => typeof o === "string" && isAddress(o, { strict: false }))) {
    throw new Error("owners state file: invalid owners");
  }
  return { nextBlock: BigInt(nextBlock), owners: owners as Address[] };
};

/**
 * Forget owners that no longer name this keeper (they stopped, or appointed someone else). If they come back, their new
 * `MandateSet` event is found again, because the search continues from `nextBlock`. This keeps the list, and so the
 * reads per run, bounded by the owners that actually appoint this keeper.
 */
export const withoutOwners = (state: OwnersState, gone: readonly Address[]): OwnersState => {
  const drop = new Set(gone.map((owner) => owner.toLowerCase()));
  return { nextBlock: state.nextBlock, owners: state.owners.filter((owner) => !drop.has(owner.toLowerCase())) };
};

export const formatOwnersState = (state: OwnersState): string =>
  `${JSON.stringify({ nextBlock: state.nextBlock.toString(), owners: state.owners }, null, 2)}\n`;

/** Inclusive block ranges of at most `step` blocks from `from` up to and including `to`. Empty if `from` > `to`. */
export const logRanges = (from: bigint, to: bigint, step: bigint): { fromBlock: bigint; toBlock: bigint }[] => {
  if (step < 1n) throw new Error("log range must be at least 1 block");
  const out: { fromBlock: bigint; toBlock: bigint }[] = [];
  for (let start = from; start <= to; start += step) {
    out.push({ fromBlock: start, toBlock: start + step - 1n < to ? start + step - 1n : to });
  }
  return out;
};

// ─── The price the keeper demands ──────────────────────────────────────────────────────────────────────────────

/**
 * `minAmountOut` for `execute`: what the simulation just yielded, minus a small tolerance for what the pool may move
 * until the transaction lands. The contract only lets this make its own Chainlink bound stricter, so a tolerance that
 * is too wide costs nothing extra and one that is too tight only makes the transaction revert.
 */
export const minAmountOut = (simulatedOut: bigint, toleranceBps: bigint): bigint => {
  if (toleranceBps < 0n || toleranceBps > BPS) throw new Error("tolerance must be between 0 and 10000 bps");
  return (simulatedOut * (BPS - toleranceBps)) / BPS;
};

// ─── What to do after a failure ────────────────────────────────────────────────────────────────────────────────

/** A failed simulation or transaction: the decoded contract error, a revert reason string, or neither (node error). */
export type Failure = { errorName?: string; reason?: string };

/**
 * - "skip": nothing is wrong with the owner, try again next run. Market and oracle conditions (the price bound, a
 *   stale feed, the sequencer), a state that changed since `isDue` (someone else ran the wallet, the price moved back
 *   into the band, the owner replaced the keeper), and node errors.
 * - "stop": the contract has been retired; no run will ever succeed again.
 * - "cooldown": everything else reverts for a reason that will not go away by itself (a blacklisted owner, a paused
 *   token); the owner is skipped for a while, doubling per failure, so that it does not cost a simulation every run.
 */
export type FailureAction = "skip" | "stop" | "cooldown";

const SKIP_ERRORS: readonly string[] = [
  "OutsidePriceBounds",
  "StaleFeed",
  "SequencerDown",
  "InvalidFeedAnswer",
  "NotDue",
  "NothingToDo",
  "Inactive",
  "NotOwnerOrKeeper",
];
/** Uniswap's own message when `amountOutMinimum` is not met: the same condition as OutsidePriceBounds. */
const SKIP_REASONS: readonly string[] = ["Too little received"];

/** viem decodes a plain `revert("…")` as the built-in error `Error(string)`: the name says nothing, the reason does. */
const STRING_REVERT = "Error";

export const failureAction = (failure: Failure): FailureAction => {
  if (failure.errorName === "ContractRetired") return "stop";
  if (failure.errorName !== undefined && failure.errorName !== STRING_REVERT) {
    return SKIP_ERRORS.includes(failure.errorName) ? "skip" : "cooldown";
  }
  if (failure.reason !== undefined) return SKIP_REASONS.some((r) => failure.reason?.includes(r)) ? "skip" : "cooldown";
  return failure.errorName === undefined ? "skip" : "cooldown";
};

/** Is one of our own transactions still pending? Then a new one would queue behind it; send nothing this run. */
export const ownTransactionPending = (latestNonce: number, pendingNonce: number): boolean => pendingNonce > latestNonce;

// ─── Cool-down per owner ───────────────────────────────────────────────────────────────────────────────────────

/**
 * The contract does not remember failures (`lastExecutedAt` is only set on success), so an owner that reverts
 * structurally stays due. The wait doubles per consecutive failure up to `maxSeconds`.
 */
export type CooldownEntry = {
  /** Unix seconds until which the owner is skipped. */
  until: number;
  /** Number of consecutive failures. */
  failures: number;
  /** First line of the last error message. */
  lastError: string;
};

export type CooldownState = Record<string, CooldownEntry>;

export type CooldownPolicy = { baseSeconds: number; maxSeconds: number };

const key = (owner: Address): string => owner.toLowerCase();

export const isCoolingDown = (state: CooldownState, owner: Address, nowSeconds: number): boolean => {
  const until = state[key(owner)]?.until;
  return until !== undefined && nowSeconds < until;
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
  if (state[key(owner)] === undefined) return state;
  const { [key(owner)]: _, ...rest } = state;
  return rest;
};

/**
 * Drop cool-downs that ended more than `keepSeconds` ago, so that the file does not keep growing. An entry outlives
 * its own cool-down on purpose: it carries the number of consecutive failures, and an owner who fails again right
 * after his wait must get the doubled wait, not the first one again. A success clears the entry (`clearFailure`).
 */
export const pruneExpired = (state: CooldownState, nowSeconds: number, keepSeconds: number): CooldownState =>
  Object.fromEntries(Object.entries(state).filter(([, entry]) => nowSeconds < entry.until + keepSeconds));

export const parseCooldownState = (json: string): CooldownState => {
  const parsed: unknown = JSON.parse(json);
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("cool-down file is not a JSON object");
  }
  const state: CooldownState = {};
  for (const [owner, entry] of Object.entries(parsed as Record<string, unknown>)) {
    if (
      entry === null ||
      typeof entry !== "object" ||
      typeof (entry as CooldownEntry).until !== "number" ||
      typeof (entry as CooldownEntry).failures !== "number"
    ) {
      throw new Error(`cool-down file: invalid entry for ${owner}`);
    }
    const { until, failures, lastError } = entry as CooldownEntry;
    state[owner.toLowerCase()] = { until, failures, lastError: typeof lastError === "string" ? lastError : "" };
  }
  return state;
};

// ─── Lock: one run at a time ───────────────────────────────────────────────────────────────────────────────────

/** Content of LOCK_FILE: pid and start time (unix seconds) of the run that holds the lock. */
export type LockInfo = { pid: number; startedAt: number };

export const formatLock = (lock: LockInfo): string => `${JSON.stringify(lock)}\n`;

/** Lock from the file. Unreadable content gives `startedAt` = `fallbackStartedAt` (the file's mtime), so it has an age. */
export const parseLock = (text: string, fallbackStartedAt: number): LockInfo => {
  try {
    const parsed: unknown = JSON.parse(text);
    if (
      parsed !== null &&
      typeof parsed === "object" &&
      Number.isInteger((parsed as LockInfo).pid) &&
      Number.isFinite((parsed as LockInfo).startedAt)
    ) {
      return { pid: (parsed as LockInfo).pid, startedAt: (parsed as LockInfo).startedAt };
    }
  } catch {
    // garbage
  }
  const pid = Number(text.trim());
  return { pid: Number.isInteger(pid) ? pid : 0, startedAt: fallbackStartedAt };
};

/**
 * May an existing lock be removed? Checking only the pid is not enough: if a lock remains after a crash and the OS
 * later gives that pid to another process, every run would stop silently. Therefore:
 * - a lock older than `maxAgeSeconds` is always stale. That is safe because a run stops itself before that age
 *   (`lockWatchdogSeconds`);
 * - a younger lock is stale if the pid no longer exists (or never did);
 * - a lock with a start time in the future (clock changed) counts as young, so only the pid decides.
 */
export const lockIsStale = (
  lock: LockInfo,
  nowSeconds: number,
  maxAgeSeconds: number,
  isAlive: (pid: number) => boolean,
): boolean => {
  if (nowSeconds - lock.startedAt >= maxAgeSeconds) return true;
  return !(lock.pid > 0 && isAlive(lock.pid));
};

/** After how many seconds a run stops itself: 15 s before the lock expires, so two runs never run simultaneously. */
export const lockWatchdogSeconds = (maxAgeSeconds: number): number => Math.max(maxAgeSeconds - 15, 0);

// ─── RPC URL not in the log ────────────────────────────────────────────────────────────────────────────────────

/**
 * The RPC URL without whatever may contain an API key: only scheme and host. Path, query, fragment and credentials
 * become `/***` (Alchemy and Infura put the key in the path, other providers in the query). An invalid URL becomes `***`.
 */
export const maskRpcUrl = (url: string): string => {
  try {
    const u = new URL(url);
    const hidden = u.username !== "" || u.password !== "" || u.pathname !== "/" || u.search !== "" || u.hash !== "";
    return `${u.protocol}//${u.host}${hidden ? "/***" : ""}`;
  } catch {
    return "***";
  }
};

/**
 * Remove the RPC URL from a text (an error message from viem or Bun). viem puts `URL: …` in its messages and only
 * strips username and password from it, not a key in path or query.
 * - The whole URL, as given, as `URL` writes it and without credentials, becomes `maskRpcUrl(url)`;
 * - then every separate part that may be a key (path plus query, path, query, path segments, query parameter values,
 *   username and password, also URL-decoded) of at least 8 characters becomes `***`. Shorter parts ("v2", "/") stay:
 *   they are not a key and would mangle ordinary text.
 */
export const redactRpcUrl = (text: string, url: string): string => {
  if (url === "") return text;
  // In one pass, longest first: what has already been replaced is not replaced again.
  const replace = (input: string, secrets: readonly string[], by: string): string => {
    const list = [...new Set(secrets)].filter((s) => s.length > 0).sort((a, b) => b.length - a.length);
    if (list.length === 0) return input;
    const pattern = new RegExp(list.map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|"), "g");
    return input.replace(pattern, () => by);
  };
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return replace(text, [url], "***");
  }
  const bare = new URL(url);
  bare.username = "";
  bare.password = "";
  const fulls = [url, u.href, bare.href, bare.href.replace(/\/$/, ""), url.replace(/\/$/, "")];
  const masked = maskRpcUrl(url);
  const decode = (s: string): string => {
    try {
      return decodeURIComponent(s);
    } catch {
      return s;
    }
  };
  const parts = [
    `${u.pathname}${u.search}${u.hash}`,
    `${u.pathname}${u.search}`,
    u.pathname,
    u.search,
    u.hash,
    u.username,
    u.password,
    ...u.pathname.split("/"),
    ...[...u.searchParams.values()],
  ].flatMap((p) => [p, decode(p)]);
  return replace(
    replace(text, fulls, masked),
    parts.filter((p) => p.length >= 8),
    "***",
  );
};

// ─── Display ───────────────────────────────────────────────────────────────────────────────────────────────────

/** USDC base units (6 decimals) as "1234.56". */
export const formatUsdc = (amount: bigint): string => {
  const sign = amount < 0n ? "-" : "";
  const abs = amount < 0n ? -amount : amount;
  const cents = (abs + 5_000n) / 10_000n;
  return `${sign}${cents / 100n}.${(cents % 100n).toString().padStart(2, "0")}`;
};
