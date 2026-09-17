import { describe, expect, test } from "bun:test";
import { type Address, getAddress } from "viem";
import {
  type Mandate,
  chunks,
  clearFailure,
  failureAction,
  formatLock,
  formatOwnersState,
  formatUsdc,
  isCoolingDown,
  lockIsStale,
  lockWatchdogSeconds,
  logRanges,
  maskRpcUrl,
  mayRun,
  mergeOwners,
  minAmountOut,
  ownTransactionPending,
  parseCooldownState,
  parseLock,
  parseOwnersFile,
  parseOwnersState,
  withoutOwners,
  pruneExpired,
  recordFailure,
  redactRpcUrl,
} from "./selection";

const OWNER = "0xAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as Address;
const OTHER = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" as Address;
const KEEPER = "0xcccccccccccccccccccccccccccccccccccccccc" as Address;
const ZERO = "0x0000000000000000000000000000000000000000" as Address;
const policy = { baseSeconds: 3600, maxSeconds: 86_400 };

describe("which owners", () => {
  const mandate = (targetBps: number, keeper: Address): Mandate => ({ targetBps, lastExecutedAt: 0n, unfinished: false, keeper });

  test("mayRun follows the contract: the owner or the keeper the owner appointed, and only with a mandate", () => {
    expect(mayRun(mandate(8000, KEEPER), OWNER, KEEPER)).toBe(true);
    expect(mayRun(mandate(8000, KEEPER.toUpperCase().replace("0X", "0x") as Address), OWNER, KEEPER)).toBe(true);
    expect(mayRun(mandate(8000, OTHER), OWNER, KEEPER)).toBe(false); // the owner replaced this keeper
    expect(mayRun(mandate(8000, ZERO), OWNER, KEEPER)).toBe(false); // owner-only mandate
    expect(mayRun(mandate(8000, ZERO), OWNER, OWNER)).toBe(true); // running your own wallet
    expect(mayRun(mandate(0, KEEPER), OWNER, KEEPER)).toBe(false); // stopped
  });

  test("parseOwnersFile: addresses separated by lines, spaces or commas, comments, deduplicated", () => {
    const text = `# own users\n${OWNER}\n${OTHER}, ${OWNER.toLowerCase()}  # duplicate\n\n`;
    expect(parseOwnersFile(text.replace(OWNER, getAddress(OWNER)))).toEqual([getAddress(OWNER), OTHER]);
    // A wrong checksum does not get through; viem would make every read for that page fail.
    expect(() => parseOwnersFile(OWNER)).toThrow("invalid checksum");
    expect(parseOwnersFile("")).toEqual([]);
    expect(() => parseOwnersFile("0x123")).toThrow("not a valid address");
  });

  test("mergeOwners keeps the order and every address once, regardless of case", () => {
    expect(mergeOwners([OTHER], [getAddress(OWNER), OTHER], [OWNER.toLowerCase() as Address])).toEqual([
      OTHER,
      getAddress(OWNER),
    ]);
    expect(mergeOwners()).toEqual([]);
  });

  test("chunks", () => {
    expect(chunks([1, 2, 3, 4, 5], 2)).toEqual([[1, 2], [3, 4], [5]]);
    expect(chunks([], 2)).toEqual([]);
  });
});

describe("finding owners in the events", () => {
  test("logRanges covers every block exactly once, in ranges of at most `step`", () => {
    expect(logRanges(10n, 25n, 10n)).toEqual([
      { fromBlock: 10n, toBlock: 19n },
      { fromBlock: 20n, toBlock: 25n },
    ]);
    expect(logRanges(10n, 10n, 5000n)).toEqual([{ fromBlock: 10n, toBlock: 10n }]);
    expect(logRanges(11n, 10n, 5000n)).toEqual([]); // nothing new since the previous run
    expect(() => logRanges(0n, 10n, 0n)).toThrow("at least 1 block");
  });

  test("the state file round-trips; without a file the search starts at FROM_BLOCK", () => {
    const state = { nextBlock: 51_500_000n, owners: [getAddress(OWNER), OTHER] };
    expect(parseOwnersState(formatOwnersState(state), 1n)).toEqual(state);
    expect(parseOwnersState(undefined, 51_400_000n)).toEqual({ nextBlock: 51_400_000n, owners: [] });
  });

  test("owners that no longer name this keeper are forgotten; the search position stays", () => {
    const state = { nextBlock: 51_500_000n, owners: [getAddress(OWNER), OTHER] };
    expect(withoutOwners(state, [OWNER.toLowerCase() as Address])).toEqual({ nextBlock: 51_500_000n, owners: [OTHER] });
    expect(withoutOwners(state, [])).toEqual(state);
  });

  test("a damaged state file is an error, never a silent search from block 0", () => {
    expect(() => parseOwnersState("null", 1n)).toThrow("not a JSON object");
    expect(() => parseOwnersState('{"nextBlock":12,"owners":[]}', 1n)).toThrow("invalid nextBlock");
    expect(() => parseOwnersState('{"nextBlock":"-1","owners":[]}', 1n)).toThrow("invalid nextBlock");
    expect(() => parseOwnersState('{"nextBlock":"12","owners":["0x123"]}', 1n)).toThrow("invalid owners");
    expect(() => parseOwnersState("not json", 1n)).toThrow();
  });
});

describe("the price the keeper demands", () => {
  test("minAmountOut is the simulated output minus the tolerance, rounded down", () => {
    expect(minAmountOut(1_306_569n, 10n)).toBe(1_305_262n); // 10 bps below 0.01306569 cbBTC
    expect(minAmountOut(1_000_000n, 0n)).toBe(1_000_000n);
    expect(minAmountOut(0n, 10n)).toBe(0n);
    expect(minAmountOut(999n, 10_000n)).toBe(0n);
  });

  test("a tolerance outside 0-10000 bps is a configuration error", () => {
    expect(() => minAmountOut(1n, -1n)).toThrow("between 0 and 10000");
    expect(() => minAmountOut(1n, 10_001n)).toThrow("between 0 and 10000");
  });
});

describe("what to do after a failure", () => {
  test("market and oracle conditions are skipped until the next run, without a cool-down", () => {
    for (const errorName of ["OutsidePriceBounds", "StaleFeed", "SequencerDown", "InvalidFeedAnswer"]) {
      expect(failureAction({ errorName })).toBe("skip");
    }
    expect(failureAction({ reason: "Too little received" })).toBe("skip");
  });

  test("a state that changed since isDue is skipped: someone else ran it, the band, a replaced keeper", () => {
    for (const errorName of ["NotDue", "NothingToDo", "Inactive", "NotOwnerOrKeeper"]) {
      expect(failureAction({ errorName })).toBe("skip");
    }
  });

  test("a retired contract stops the run", () => {
    expect(failureAction({ errorName: "ContractRetired" })).toBe("stop");
  });

  test("a revert that will not go away by itself gets a cool-down", () => {
    expect(failureAction({ reason: "Blacklistable: account is blacklisted" })).toBe("cooldown");
    expect(failureAction({ reason: "Pausable: paused" })).toBe("cooldown");
    expect(failureAction({ errorName: "SafeERC20FailedOperation" })).toBe("cooldown");
    expect(failureAction({ errorName: "SomethingNew" })).toBe("cooldown");
  });

  test("a node error is not the owner's fault", () => {
    expect(failureAction({})).toBe("skip");
  });

  test("with an own transaction still pending nothing new is sent", () => {
    expect(ownTransactionPending(41, 41)).toBe(false);
    expect(ownTransactionPending(41, 42)).toBe(true);
  });
});

describe("cool-down", () => {
  test("a fresh owner is not cooling down", () => {
    expect(isCoolingDown({}, OWNER, 1000)).toBe(false);
  });

  test("recordFailure doubles the wait per consecutive failure, capped at maxSeconds", () => {
    let state = recordFailure({}, OWNER, 1000, "Pausable: paused\nDetails", policy);
    expect(state[OWNER.toLowerCase()]).toEqual({ until: 4600, failures: 1, lastError: "Pausable: paused" });
    expect(isCoolingDown(state, OWNER, 4599)).toBe(true);
    expect(isCoolingDown(state, OWNER, 4600)).toBe(false);

    state = recordFailure(state, OWNER, 5000, "again", policy);
    expect(state[OWNER.toLowerCase()].until).toBe(5000 + 7200);
    state = recordFailure(state, OWNER, 6000, "again", policy);
    expect(state[OWNER.toLowerCase()].until).toBe(6000 + 14_400);
    for (let i = 0; i < 10; i++) state = recordFailure(state, OWNER, 7000, "again", policy);
    expect(state[OWNER.toLowerCase()].until).toBe(7000 + 86_400);
    expect(state[OWNER.toLowerCase()].failures).toBe(13);
  });

  test("keys are case-insensitive and other owners are untouched", () => {
    const state = recordFailure({}, OWNER, 1000, "x", policy);
    expect(isCoolingDown(state, OWNER.toLowerCase() as Address, 1001)).toBe(true);
    expect(isCoolingDown(state, OTHER, 1001)).toBe(false);
  });

  test("clearFailure removes the entry after a success", () => {
    const state = recordFailure({}, OWNER, 1000, "x", policy);
    expect(clearFailure(state, OWNER)).toEqual({});
    expect(clearFailure({}, OWNER)).toEqual({});
  });

  test("pruneExpired drops entries whose cool-down has passed", () => {
    let state = recordFailure({}, OWNER, 1000, "x", policy);
    state = recordFailure(state, OTHER, 10_000, "y", policy);
    expect(Object.keys(pruneExpired(state, 5000))).toEqual([OTHER.toLowerCase()]);
  });

  test("parseCooldownState accepts its own output and rejects garbage", () => {
    const state = recordFailure({}, OWNER, 1000, "x", policy);
    expect(parseCooldownState(JSON.stringify(state))).toEqual(state);
    expect(parseCooldownState("{}")).toEqual({});
    expect(() => parseCooldownState("[]")).toThrow("not a JSON object");
    expect(() => parseCooldownState('{"0xabc":{"until":"soon"}}')).toThrow("invalid entry");
  });
});

describe("lock", () => {
  const alive = (pids: number[]) => (pid: number) => pids.includes(pid);

  test("the lock stores pid and start time and reads back; unreadable content gets the file time", () => {
    const lock = { pid: 4242, startedAt: 1_789_600_000 };
    expect(parseLock(formatLock(lock), 0)).toEqual(lock);
    expect(parseLock("4242\n", 1_789_500_000)).toEqual({ pid: 4242, startedAt: 1_789_500_000 });
    expect(parseLock("garbage", 7)).toEqual({ pid: 0, startedAt: 7 });
  });

  test("a young lock of a live pid holds; of a dead pid it is stale", () => {
    const lock = { pid: 100, startedAt: 1_000 };
    expect(lockIsStale(lock, 1_100, 900, alive([100]))).toBe(false);
    expect(lockIsStale(lock, 1_100, 900, alive([]))).toBe(true);
    expect(lockIsStale({ pid: 0, startedAt: 1_000 }, 1_100, 900, alive([0]))).toBe(true);
  });

  test("a reused pid: a lock older than the max age is stale even if the pid is alive", () => {
    const lock = { pid: 100, startedAt: 1_000 };
    expect(lockIsStale(lock, 1_899, 900, alive([100]))).toBe(false);
    expect(lockIsStale(lock, 1_900, 900, alive([100]))).toBe(true);
  });

  test("a start time in the future (clock changed) leaves the decision to the pid", () => {
    expect(lockIsStale({ pid: 100, startedAt: 5_000 }, 1_000, 900, alive([100]))).toBe(false);
    expect(lockIsStale({ pid: 100, startedAt: 5_000 }, 1_000, 900, alive([]))).toBe(true);
  });

  test("the run stops itself before its lock expires", () => {
    expect(lockWatchdogSeconds(900)).toBe(885);
    expect(lockWatchdogSeconds(10)).toBe(0);
  });
});

describe("RPC URL in logs", () => {
  const alchemy = "https://base-mainnet.g.alchemy.com/v2/not-a-real-key-111";
  const query = "https://rpc.example.org/base?apikey=not-a-real-key-000";
  const creds = "https://keeper:not-a-real-password@node.example.org:8545/";

  test("maskRpcUrl keeps only scheme and host", () => {
    expect(maskRpcUrl(alchemy)).toBe("https://base-mainnet.g.alchemy.com/***");
    expect(maskRpcUrl(query)).toBe("https://rpc.example.org/***");
    expect(maskRpcUrl(creds)).toBe("https://node.example.org:8545/***");
    expect(maskRpcUrl("https://mainnet.base.org")).toBe("https://mainnet.base.org");
    expect(maskRpcUrl("not a url")).toBe("***");
  });

  test("a viem error message loses the key in path, query and credentials, in every form", () => {
    const viemLike = (url: string) => `HTTP request failed.\n\nStatus: 401\nURL: ${url}\nRequest body: {"method":"eth_call"}`;
    expect(redactRpcUrl(viemLike(alchemy), alchemy)).toBe(viemLike("https://base-mainnet.g.alchemy.com/***"));
    expect(redactRpcUrl(viemLike(query), query)).toBe(viemLike("https://rpc.example.org/***"));
    // viem's getUrl strips the credentials but keeps the rest.
    expect(redactRpcUrl(viemLike("https://node.example.org:8545/"), creds)).toBe(viemLike("https://node.example.org:8545/***"));
    const loose = redactRpcUrl("invalid key not-a-real-key-111 for /v2/not-a-real-key-111", alchemy);
    expect(loose).not.toContain("not-a-real-key-111");
    expect(redactRpcUrl("password not-a-real-password rejected", creds)).toBe("password *** rejected");
    for (const url of [alchemy, query, creds]) {
      const secret = new URL(url);
      const out = redactRpcUrl(`${url} ${url.replace(/\/$/, "")} ${secret.href}`, url);
      for (const part of [secret.pathname.slice(1), secret.searchParams.get("apikey") ?? "", secret.password]) {
        if (part.length >= 8) expect(out).not.toContain(part);
      }
    }
  });

  test("short and ordinary text is left alone", () => {
    expect(redactRpcUrl("HTTP request failed.", alchemy)).toBe("HTTP request failed.");
    expect(redactRpcUrl("v2 / base", alchemy)).toBe("v2 / base");
    expect(redactRpcUrl("URL: https://mainnet.base.org", "https://mainnet.base.org")).toBe("URL: https://mainnet.base.org");
    expect(redactRpcUrl("text", "")).toBe("text");
  });
});

describe("formatUsdc", () => {
  test("base units to two decimals, rounded", () => {
    expect(formatUsdc(1_000_000_000n)).toBe("1000.00");
    expect(formatUsdc(99_975_000n)).toBe("99.98");
    expect(formatUsdc(4_999n)).toBe("0.00");
    expect(formatUsdc(-20_000_000n)).toBe("-20.00");
  });
});
