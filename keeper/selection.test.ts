import { describe, expect, test } from "bun:test";
import type { Address } from "viem";
import {
  EURC_UNIT,
  clearFailure,
  formatEurc,
  isCoolingDown,
  parseCooldownState,
  pruneExpired,
  recordFailure,
  runSizeSkipReason,
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
