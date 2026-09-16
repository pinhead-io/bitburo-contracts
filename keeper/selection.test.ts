import { describe, expect, test } from "bun:test";
import type { Address } from "viem";
import {
  EURC_UNIT,
  clearFailure,
  failureAction,
  formatEurc,
  isBlockWindowRevert,
  isCoolingDown,
  isTemporaryFailure,
  mustWaitForNextBlock,
  newOwners,
  parseCooldownState,
  pruneExpired,
  recordFailure,
  runSizeSkipReason,
  shouldReadPageAgain,
} from "./selection";

const OWNER = "0xAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as Address;
const OTHER = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" as Address;
const policy = { baseSeconds: 3600, maxSeconds: 86_400 };

describe("runSizeSkipReason", () => {
  test("skips runs below the minimum in both directions", () => {
    expect(runSizeSkipReason(20n * EURC_UNIT, 20)).toBeNull();
    expect(runSizeSkipReason(-20n * EURC_UNIT, 20)).toBeNull();
    expect(runSizeSkipReason(19_999_999n, 20)).toBe("run te klein (19.999999 EURC < 20 EURC)");
    expect(runSizeSkipReason(-100n, 20)).toContain("te klein");
  });

  test("has no upper bound: the open keeper has no gas cap", () => {
    expect(runSizeSkipReason(1_000_000n * EURC_UNIT, 20)).toBeNull();
  });

  test("a minimum of 0 keeps everything", () => {
    expect(runSizeSkipReason(1n, 0)).toBeNull();
  });
});

describe("block window reverts", () => {
  test("only the block check and block window errors count as temporary", () => {
    expect(isBlockWindowRevert("PoolTouchedThisBlock")).toBe(true);
    expect(isBlockWindowRevert("BlockMoveExceeded")).toBe(true);
    // Bestaat niet meer in het contract sinds de blokcheck.
    expect(isBlockWindowRevert("BlockStartUnknown")).toBe(false);
    expect(isBlockWindowRevert("SpotDeviatesFromOracle")).toBe(false);
    expect(isBlockWindowRevert("NotDue")).toBe(false);
    expect(isBlockWindowRevert(undefined)).toBe(false);
  });

  test("a block check or block window revert is retried in a next block, then skipped without a cool-down", () => {
    expect(failureAction("PoolTouchedThisBlock", 0, 3)).toBe("retry");
    expect(failureAction({ errorName: "PoolTouchedThisBlock" }, 2, 3)).toBe("retry");
    expect(failureAction("PoolTouchedThisBlock", 3, 3)).toBe("skip");
    expect(failureAction("BlockMoveExceeded", 0, 3)).toBe("retry");
    expect(failureAction("BlockMoveExceeded", 3, 3)).toBe("skip");
    expect(failureAction("BlockMoveExceeded", 0, 0)).toBe("skip");
  });

  test("every other revert is a real failure for the cool-down", () => {
    expect(failureAction("SpotDeviatesFromOracle", 0, 3)).toBe("fail");
    expect(failureAction(undefined, 0, 3)).toBe("fail");
    expect(failureAction({ errorName: undefined, resimulationPassed: false }, 0, 3)).toBe("fail");
  });

  test("an on-chain revert whose re-simulation passes is temporary (review I-1)", () => {
    expect(isTemporaryFailure({ errorName: undefined, resimulationPassed: true })).toBe(true);
    expect(failureAction({ errorName: undefined, resimulationPassed: true }, 0, 3)).toBe("retry");
    expect(failureAction({ errorName: undefined, resimulationPassed: true }, 3, 3)).toBe("skip");
    // Geeft de hersimulatie een echte fout, dan telt die.
    expect(isTemporaryFailure({ errorName: "SpotDeviatesFromOracle", resimulationPassed: false })).toBe(false);
  });
});

describe("re-reading a dueOwners page (review I-1)", () => {
  const A = "0x1111111111111111111111111111111111111111" as Address;
  const B = "0x2222222222222222222222222222222222222222" as Address;

  test("newOwners drops owners already handled this run, case-insensitively", () => {
    const handled = new Set([A.toLowerCase()]);
    expect(newOwners([A, B], handled)).toEqual([B]);
    expect(newOwners([B.toUpperCase().replace("0X", "0x") as Address], new Set([B.toLowerCase()]))).toEqual([]);
    expect(newOwners([], handled)).toEqual([]);
  });

  test("a page is read at least twice, then only while a read still finds someone new", () => {
    // Eerste lezing leeg (bijvoorbeeld een pool aangeraakt in dat blok): toch een tweede lezing.
    expect(shouldReadPageAgain(0, 1, 4)).toBe(true);
    expect(shouldReadPageAgain(2, 1, 4)).toBe(true);
    expect(shouldReadPageAgain(0, 2, 4)).toBe(false);
    expect(shouldReadPageAgain(1, 2, 4)).toBe(true);
    expect(shouldReadPageAgain(1, 4, 4)).toBe(false);
  });

  test("with BLOCK_RETRIES = 0 a page is read once", () => {
    expect(shouldReadPageAgain(5, 1, 1)).toBe(false);
  });
});

describe("mustWaitForNextBlock", () => {
  test("waits while the latest block is the block of the last successful run", () => {
    expect(mustWaitForNextBlock(100n, null)).toBe(false);
    expect(mustWaitForNextBlock(100n, 100n)).toBe(true);
    expect(mustWaitForNextBlock(99n, 100n)).toBe(true);
    expect(mustWaitForNextBlock(101n, 100n)).toBe(false);
  });
});

describe("formatEurc", () => {
  test("prints base units as EURC without trailing zeros", () => {
    expect(formatEurc(0n)).toBe("0");
    expect(formatEurc(50_000n)).toBe("0.05");
    expect(formatEurc(1_234_500_000n)).toBe("1234.5");
  });
});

describe("cool-down", () => {
  test("a fresh owner is not cooling down", () => {
    expect(isCoolingDown({}, OWNER, 1000)).toBe(false);
  });

  test("recordFailure doubles the wait per consecutive failure, capped at maxSeconds", () => {
    let state = recordFailure({}, OWNER, 1000, "execution reverted: Too little received\nDetails", policy);
    expect(state[OWNER.toLowerCase()]).toEqual({ until: 4600, failures: 1, lastError: "execution reverted: Too little received" });
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
    expect(() => parseCooldownState("[]")).toThrow("geen JSON-object");
    expect(() => parseCooldownState('{"0xabc":{"until":"soon"}}')).toThrow("ongeldige regel");
  });
});
