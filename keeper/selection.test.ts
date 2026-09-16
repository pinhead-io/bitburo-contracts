import { describe, expect, test } from "bun:test";
import type { Address } from "viem";
import {
  CBBTC_UNIT,
  EURC_UNIT,
  type OwnerFunds,
  GWEI,
  OVERRIDE_PROBE_CODE,
  blockerTip,
  chunks,
  clearFailure,
  effectiveTip,
  failureAction,
  filterCandidates,
  isCandidate,
  formatEurc,
  formatGwei,
  isBlockWindowRevert,
  isCoolingDown,
  isTemporaryFailure,
  maxFeePerGas,
  maxRunValues,
  minRunBaseUnits,
  newOwners,
  nextAttemptBlock,
  nextBlockOverrides,
  nextSendBlock,
  onchainRevertVerdict,
  parseFeeState,
  startPriorityFee,
  nextPriorityFee,
  overridesApplied,
  parseCooldownState,
  parseGwei,
  pruneExpired,
  recordFailure,
  retryDeadline,
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

  test("a fractional minimum does not throw and rounds up", () => {
    expect(runSizeSkipReason(20_500_000n, 20.5)).toBeNull();
    expect(runSizeSkipReason(20_499_999n, 20.5)).toContain("te klein");
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

  test("a temporary revert is retried while the retry budget runs, then skipped without a cool-down (L-3)", () => {
    const deadline = retryDeadline(1_000, 540);
    expect(deadline).toBe(1_540);
    expect(failureAction("PoolTouchedThisBlock", 1_000, deadline)).toBe("retry");
    expect(failureAction({ errorName: "PoolTouchedThisBlock" }, 1_539, deadline)).toBe("retry");
    expect(failureAction("PoolTouchedThisBlock", 1_540, deadline)).toBe("skip");
    expect(failureAction("BlockMoveExceeded", 1_000, deadline)).toBe("retry");
    expect(failureAction("BlockMoveExceeded", 2_000, deadline)).toBe("skip");
    // Budget 0: nooit een nieuwe poging.
    expect(failureAction("BlockMoveExceeded", 1_000, retryDeadline(1_000, 0))).toBe("skip");
  });

  test("the budget is time, not a number of attempts: many blocked blocks keep retrying", () => {
    const deadline = retryDeadline(0, 540);
    // Elke 2 s een blok: 269 geblokkeerde blokken achter elkaar blijven "retry".
    for (let t = 0; t < 540; t += 2) {
      expect(failureAction("PoolTouchedThisBlock", t, deadline)).toBe("retry");
    }
  });

  test("every other revert is a real failure for the cool-down, also within the budget", () => {
    expect(failureAction("SpotDeviatesFromOracle", 0, 540)).toBe("fail");
    expect(failureAction("NotDue", 0, 540)).toBe("fail");
    expect(failureAction(undefined, 0, 540)).toBe("fail");
    expect(failureAction({ errorName: undefined, resimulationPassed: false }, 0, 540)).toBe("fail");
    expect(failureAction("SpotDeviatesFromOracle", 1_000, 540)).toBe("fail");
  });

  test("a node or network error is temporary and never a cool-down", () => {
    expect(isTemporaryFailure({ errorName: undefined, transient: true })).toBe(true);
    expect(failureAction({ errorName: undefined, transient: true }, 0, 540)).toBe("retry");
    expect(failureAction({ errorName: undefined, transient: true }, 540, 540)).toBe("skip");
  });

  test("an on-chain revert whose re-simulation passes is temporary (review I-1)", () => {
    expect(isTemporaryFailure({ errorName: undefined, resimulationPassed: true })).toBe(true);
    expect(failureAction({ errorName: undefined, resimulationPassed: true }, 0, 540)).toBe("retry");
    expect(failureAction({ errorName: undefined, resimulationPassed: true }, 540, 540)).toBe("skip");
    // Geeft de hersimulatie een echte fout, dan telt die.
    expect(isTemporaryFailure({ errorName: "SpotDeviatesFromOracle", resimulationPassed: false })).toBe(false);
  });
});

describe("on-chain revert verdict (L-3)", () => {
  test("re-simulation at block start passes: temporary, a blockade only if a pool was touched before us", () => {
    expect(onchainRevertVerdict({ kind: "passed" }, true)).toEqual({
      failure: { errorName: undefined, resimulationPassed: true },
      blockade: true,
    });
    // Bijvoorbeeld een andere keeper die dezelfde owner eerder in het blok uitvoerde, zonder pool-log vóór ons: geen
    // hogere tip, wel tijdelijk (geen cool-down).
    const noTouch = onchainRevertVerdict({ kind: "passed" }, false);
    expect(noTouch.blockade).toBe(false);
    expect(failureAction(noTouch.failure, 0, 540)).toBe("retry");
  });

  test("a real revert at block start is the real reason, even if a pool was touched", () => {
    const v = onchainRevertVerdict({ kind: "reverted", errorName: "SpotDeviatesFromOracle" }, true);
    expect(v.blockade).toBe(false);
    expect(failureAction(v.failure, 0, 540)).toBe("fail");
  });

  test("a block window revert at block start or a node error stays temporary", () => {
    expect(onchainRevertVerdict({ kind: "reverted", errorName: "BlockMoveExceeded" }, true).blockade).toBe(true);
    const err = onchainRevertVerdict({ kind: "error" }, false);
    expect(err.blockade).toBe(false);
    expect(failureAction(err.failure, 0, 540)).toBe("retry");
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

  test("reading the next block (L-3) needs one read per page", () => {
    expect(shouldReadPageAgain(0, 1, 4, true)).toBe(false);
    expect(shouldReadPageAgain(3, 1, 4, true)).toBe(false);
    expect(shouldReadPageAgain(0, 1, 4, false)).toBe(true);
  });
});

describe("next-block overrides (L-3)", () => {
  test("number + 1 and timestamp + 2 s on top of the latest block", () => {
    expect(nextBlockOverrides({ number: 51_401_377n, timestamp: 1_789_593_600n })).toEqual({
      number: 51_401_378n,
      time: 1_789_593_602n,
    });
  });

  test("the probe is creation code that returns timestamp and number", () => {
    // 42 TIMESTAMP, 6000 PUSH1 0, 52 MSTORE, 43 NUMBER, 6020 PUSH1 0x20, 52 MSTORE, 6040 PUSH1 0x40, 6000 PUSH1 0, f3 RETURN
    expect(OVERRIDE_PROBE_CODE).toBe("0x426000524360205260406000f3");
  });

  test("overrides count as applied only when exactly the overridden values come back", () => {
    const overrides = { number: 0x3104000n, time: 0x6aab1000n };
    const word = (v: bigint) => v.toString(16).padStart(64, "0");
    expect(overridesApplied(`0x${word(0x6aab1000n)}${word(0x3104000n)}`, overrides)).toBe(true);
    // Node negeert de override: de echte waarden.
    expect(overridesApplied(`0x${word(0x6aab0227n)}${word(0x3103fffn)}`, overrides)).toBe(false);
    // Alleen de tijd toegepast.
    expect(overridesApplied(`0x${word(0x6aab1000n)}${word(0x3103fffn)}`, overrides)).toBe(false);
    expect(overridesApplied("0x", overrides)).toBe(false);
    expect(overridesApplied(undefined, overrides)).toBe(false);
    expect(overridesApplied(`0x${word(0x6aab1000n)}`, overrides)).toBe(false);
  });
});

describe("priority fee (L-3)", () => {
  const policy = { base: parseGwei("0.05"), max: parseGwei("3") };

  test("parseGwei and formatGwei are exact", () => {
    expect(parseGwei("0.05")).toBe(50_000_000n);
    expect(parseGwei("3")).toBe(3n * GWEI);
    expect(parseGwei("0.000000001")).toBe(1n);
    expect(() => parseGwei("0.0000000001")).toThrow("geen geldig aantal gwei");
    expect(() => parseGwei("-1")).toThrow("geen geldig aantal gwei");
    expect(formatGwei(50_000_000n)).toBe("0.05");
    expect(formatGwei(3n * GWEI)).toBe("3");
  });

  test("without a known blocker tip the fee doubles and reaches the 3 gwei cap in 6 blockades", () => {
    const steps: string[] = [];
    let fee = policy.base;
    for (let i = 0; i < 8; i++) {
      fee = nextPriorityFee(fee, undefined, policy);
      steps.push(formatGwei(fee));
    }
    expect(steps).toEqual(["0.1", "0.2", "0.4", "0.8", "1.6", "3", "3", "3"]);
  });

  test("a known blocker tip is outbid by at least 10% when that is more than doubling", () => {
    // Aanraker op 1 gwei, keeper op 0,05: direct 1,1 gwei (+1 wei), niet 0,1.
    expect(nextPriorityFee(policy.base, GWEI, policy)).toBe(1_100_000_001n);
    // Aanraker lager dan het dubbele van de eigen tip: verdubbelen.
    expect(nextPriorityFee(parseGwei("0.4"), parseGwei("0.2"), policy)).toBe(parseGwei("0.8"));
    // Tip 0 van de aanraker (goedkoopste blokkade): toch verdubbelen.
    expect(nextPriorityFee(policy.base, 0n, policy)).toBe(parseGwei("0.1"));
    // Nooit boven het plafond, ook niet tegen een aanraker op 10 gwei.
    expect(nextPriorityFee(policy.base, 10n * GWEI, policy)).toBe(policy.max);
  });

  test("never below the base fee policy", () => {
    expect(nextPriorityFee(0n, undefined, policy)).toBe(policy.base);
  });

  test("maxFeePerGas is twice the base fee plus the tip", () => {
    // Base fee 0,005 gwei (minimum op Base) en tip 0,05 gwei.
    expect(maxFeePerGas(5_000_000n, 50_000_000n)).toBe(60_000_000n);
  });

  test("effective tip of an included transaction", () => {
    const baseFee = 5_000_000n;
    expect(effectiveTip({ maxPriorityFeePerGas: 1_000_000n, maxFeePerGas: 100_000_000n }, baseFee)).toBe(1_000_000n);
    // maxFeePerGas begrenst de tip.
    expect(effectiveTip({ maxPriorityFeePerGas: 1n * GWEI, maxFeePerGas: 6_000_000n }, baseFee)).toBe(1_000_000n);
    // Legacy: gasPrice - base fee.
    expect(effectiveTip({ gasPrice: 7_000_000n }, baseFee)).toBe(2_000_000n);
    expect(effectiveTip({ gasPrice: 5_000_000n }, baseFee)).toBe(0n);
  });

  test("blockerTip only counts pool transactions before our own in the block", () => {
    const txs = [
      { transactionIndex: 0, tip: 5n },
      { transactionIndex: 3, tip: 9n },
      { transactionIndex: 7, tip: 100n },
    ];
    expect(blockerTip(txs, 4)).toBe(9n);
    expect(blockerTip(txs, 0)).toBeUndefined();
    expect(blockerTip([], 10)).toBeUndefined();
  });

  test("the fee is kept between runs for FEE_HOLD_SECONDS after the last blockade", () => {
    const state = { priorityFeeWei: (2n * GWEI).toString(), lastBlockadeAt: 10_000 };
    expect(startPriorityFee(undefined, 10_000, policy, 3600)).toBe(policy.base);
    expect(startPriorityFee(state, 10_000 + 3599, policy, 3600)).toBe(2n * GWEI);
    expect(startPriorityFee(state, 10_000 + 3600, policy, 3600)).toBe(policy.base);
    // Buiten het beleid (bijvoorbeeld een lager plafond na een configwijziging): begrensd.
    expect(startPriorityFee({ ...state, priorityFeeWei: (10n * GWEI).toString() }, 10_000, policy, 3600)).toBe(policy.max);
    expect(startPriorityFee({ ...state, priorityFeeWei: "1" }, 10_000, policy, 3600)).toBe(policy.base);
  });

  test("parseFeeState accepts its own format and ignores garbage", () => {
    expect(parseFeeState('{"priorityFeeWei":"100000000","lastBlockadeAt":5}')).toEqual({ priorityFeeWei: "100000000", lastBlockadeAt: 5 });
    expect(parseFeeState("{}")).toBeUndefined();
    expect(parseFeeState('{"priorityFeeWei":"-1","lastBlockadeAt":5}')).toBeUndefined();
    expect(parseFeeState('{"priorityFeeWei":100,"lastBlockadeAt":5}')).toBeUndefined();
  });

  test("after a blockade the next send waits a random 1 to 59 blocks, 30 on average", () => {
    expect(nextSendBlock(1_000n, 30, 0)).toBe(1_001n);
    expect(nextSendBlock(1_000n, 30, 0.999_999)).toBe(1_059n);
    // Uniform over 59 blokken: het midden is 30.
    expect(nextSendBlock(1_000n, 30, 29 / 59)).toBe(1_030n);
    let sum = 0n;
    for (let i = 0; i < 59; i++) sum += nextSendBlock(0n, 30, i / 59);
    expect(sum / 59n).toBe(30n);
    // SEND_RETRY_BLOCKS = 1: altijd het volgende blok.
    expect(nextSendBlock(1_000n, 1, 0.7)).toBe(1_001n);
  });
});

describe("nextAttemptBlock", () => {
  test("waits for a block after the last own transaction and after the previous attempt", () => {
    expect(nextAttemptBlock(null, null, null)).toEqual({ target: null, throttled: false });
    expect(nextAttemptBlock(null, 100n, null)).toEqual({ target: 101n, throttled: false });
    expect(nextAttemptBlock(105n, 100n, null)).toEqual({ target: 106n, throttled: false });
    expect(nextAttemptBlock(99n, 100n, null)).toEqual({ target: 101n, throttled: false });
  });

  test("after a blockade not before the drawn send block (L-3)", () => {
    expect(nextAttemptBlock(105n, 100n, 130n)).toEqual({ target: 130n, throttled: true });
    expect(nextAttemptBlock(null, null, 130n)).toEqual({ target: 130n, throttled: true });
    // Throttle al voorbij: gewoon het volgende blok.
    expect(nextAttemptBlock(140n, 100n, 130n)).toEqual({ target: 141n, throttled: false });
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

describe("register spam filter (lead 9)", () => {
  const FLOOR = 20n * EURC_UNIT;
  // 100.000 EURC per cbBTC (EURC-basiseenheden per cbBTC, zoals quote()).
  const PRICE = 100_000n * EURC_UNIT;
  const empty: OwnerFunds = {
    owner: OWNER,
    active: true,
    eurcBalance: 0n,
    eurcAllowance: 0n,
    cbbtcBalance: 0n,
    cbbtcAllowance: 0n,
  };
  const max = 2n ** 256n - 1n;

  test("an empty or inactive registration is dropped", () => {
    expect(isCandidate(empty, PRICE, FLOOR)).toBe(false);
    expect(isCandidate({ ...empty, active: false, eurcBalance: 1_000n * EURC_UNIT, eurcAllowance: max }, PRICE, FLOOR)).toBe(false);
  });

  test("a balance without allowance, or an allowance without balance, is dropped", () => {
    expect(isCandidate({ ...empty, eurcBalance: 1_000n * EURC_UNIT }, PRICE, FLOOR)).toBe(false);
    expect(isCandidate({ ...empty, eurcAllowance: max, cbbtcAllowance: max }, PRICE, FLOOR)).toBe(false);
  });

  test("buy side: min(EURC balance, allowance) must reach the minimum run", () => {
    expect(isCandidate({ ...empty, eurcBalance: FLOOR, eurcAllowance: max }, PRICE, FLOOR)).toBe(true);
    expect(isCandidate({ ...empty, eurcBalance: FLOOR - 1n, eurcAllowance: max }, PRICE, FLOOR)).toBe(false);
    expect(isCandidate({ ...empty, eurcBalance: 1_000n * EURC_UNIT, eurcAllowance: FLOOR - 1n }, PRICE, FLOOR)).toBe(false);
    // 39,99 EURC is genoeg voor een run van 20 EURC: het contract kan die owner uitvoeren, dus hij blijft.
    expect(isCandidate({ ...empty, eurcBalance: 39_990_000n, eurcAllowance: max }, PRICE, FLOOR)).toBe(true);
  });

  test("sell side: min(cbBTC balance, allowance) valued at quote() must reach the minimum run, rounded down", () => {
    // 20 EURC bij 100.000 EURC per cbBTC = 20.000 sat.
    expect(isCandidate({ ...empty, cbbtcBalance: 20_000n, cbbtcAllowance: max }, PRICE, FLOOR)).toBe(true);
    expect(isCandidate({ ...empty, cbbtcBalance: 19_999n, cbbtcAllowance: max }, PRICE, FLOOR)).toBe(false);
    expect(isCandidate({ ...empty, cbbtcBalance: CBBTC_UNIT, cbbtcAllowance: 19_999n }, PRICE, FLOOR)).toBe(false);
    expect(maxRunValues({ ...empty, cbbtcBalance: 12_345n, cbbtcAllowance: max }, 123_456_789n).sell).toBe(15_240n);
  });

  test("either direction is enough", () => {
    expect(isCandidate({ ...empty, eurcBalance: FLOOR, eurcAllowance: 0n, cbbtcBalance: 20_000n, cbbtcAllowance: max }, PRICE, FLOOR)).toBe(true);
  });

  test("filterCandidates keeps the order and only the owners that can run", () => {
    const A = "0x1111111111111111111111111111111111111111" as Address;
    const B = "0x2222222222222222222222222222222222222222" as Address;
    const C = "0x3333333333333333333333333333333333333333" as Address;
    const rows = [
      { ...empty, owner: A, eurcBalance: 40n * EURC_UNIT, eurcAllowance: max },
      { ...empty, owner: B },
      { ...empty, owner: C, cbbtcBalance: CBBTC_UNIT, cbbtcAllowance: max },
    ];
    expect(filterCandidates(rows, PRICE, FLOOR)).toEqual([A, C]);
    // 10.000 lege spam-registraties laten geen enkele kandidaat over.
    expect(filterCandidates(Array.from({ length: 10_000 }, () => empty), PRICE, FLOOR)).toEqual([]);
  });

  test("the minimum is the larger of MIN_TRADE_FLOOR and MIN_RUN_EURC", () => {
    expect(minRunBaseUnits(FLOOR, 20)).toBe(FLOOR);
    expect(minRunBaseUnits(FLOOR, 5)).toBe(FLOOR);
    expect(minRunBaseUnits(FLOOR, 50)).toBe(50n * EURC_UNIT);
    expect(minRunBaseUnits(FLOOR, 20.5)).toBe(20_500_000n);
  });

  test("chunks splits without losing or reordering owners", () => {
    expect(chunks([1, 2, 3, 4, 5], 2)).toEqual([[1, 2], [3, 4], [5]]);
    expect(chunks([], 20)).toEqual([]);
  });
});
