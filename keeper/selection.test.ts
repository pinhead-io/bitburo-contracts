import { describe, expect, test } from "bun:test";
import type { Address } from "viem";
import {
  CBBTC_UNIT,
  EURC_UNIT,
  type OwnerFunds,
  GWEI,
  OVERRIDE_PROBE_CODE,
  BPS,
  EXECUTE_SELECTOR,
  blockerTip,
  blockingTransactions,
  capFeePolicy,
  chunks,
  clearFailure,
  decayPriorityFee,
  effectiveTip,
  eurcToWei,
  failureAction,
  filterCandidates,
  firstRegisterIndex,
  isCandidate,
  isDirectExecute,
  formatEurc,
  formatGwei,
  formatLock,
  isBlockWindowRevert,
  isCoolingDown,
  isStuck,
  hasTimeToSend,
  ownTransactionPending,
  sendWorstCaseSeconds,
  isTemporaryFailure,
  lockIsStale,
  lockWatchdogSeconds,
  maxFeePerGas,
  maxRunValues,
  maskRpcUrl,
  minRunBaseUnits,
  newOwners,
  nextAttemptBlock,
  nextBlockOverrides,
  nextScanOffset,
  nextSendBlock,
  quietRevertSendBlock,
  onchainRevertVerdict,
  parseFeeState,
  startPriorityFee,
  nextPriorityFee,
  overridesApplied,
  parseCooldownState,
  parseGwei,
  parseLock,
  parseOwnersFile,
  parseScanState,
  pruneExpired,
  recordFailure,
  redactRpcUrl,
  replacementFees,
  retryDeadline,
  rewardToError,
  runSizeSkipReason,
  scanSegments,
  servedBefore,
  servedSince,
  shouldReadPageAgain,
} from "./selection";
import { encodeFunctionData, getAddress, parseAbi, toFunctionSelector } from "viem";

const OWNER = "0xAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as Address;
const OTHER = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" as Address;
const policy = { baseSeconds: 3600, maxSeconds: 86_400 };

describe("runSizeSkipReason", () => {
  test("skips runs below the minimum in both directions", () => {
    expect(runSizeSkipReason(20n * EURC_UNIT, 20)).toBeNull();
    expect(runSizeSkipReason(-20n * EURC_UNIT, 20)).toBeNull();
    expect(runSizeSkipReason(19_999_999n, 20)).toBe("run too small (19.999999 EURC < 20 EURC)");
    expect(runSizeSkipReason(-100n, 20)).toContain("too small");
  });

  test("has no upper bound: the open keeper has no gas cap", () => {
    expect(runSizeSkipReason(1_000_000n * EURC_UNIT, 20)).toBeNull();
  });

  test("a minimum of 0 keeps everything", () => {
    expect(runSizeSkipReason(1n, 0)).toBeNull();
  });

  test("a fractional minimum does not throw and rounds up", () => {
    expect(runSizeSkipReason(20_500_000n, 20.5)).toBeNull();
    expect(runSizeSkipReason(20_499_999n, 20.5)).toContain("too small");
  });
});

describe("block window reverts", () => {
  test("only the block check and block window errors count as temporary", () => {
    expect(isBlockWindowRevert("PoolTouchedThisBlock")).toBe(true);
    expect(isBlockWindowRevert("BlockMoveExceeded")).toBe(true);
    // No longer exists in the contract since the block check.
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
    // Budget 0: never a new attempt.
    expect(failureAction("BlockMoveExceeded", 1_000, retryDeadline(1_000, 0))).toBe("skip");
  });

  test("the budget is time, not a number of attempts: many blocked blocks keep retrying", () => {
    const deadline = retryDeadline(0, 540);
    // A block every 2 s: 269 blocked blocks in a row stay "retry".
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
    // If the re-simulation gives a real error, that one counts.
    expect(isTemporaryFailure({ errorName: "SpotDeviatesFromOracle", resimulationPassed: false })).toBe(false);
  });
});

describe("on-chain revert verdict (L-3)", () => {
  test("re-simulation at block start passes: temporary, a blockade only if a pool was touched before us", () => {
    expect(onchainRevertVerdict({ kind: "passed" }, true)).toEqual({
      failure: { errorName: undefined, resimulationPassed: true },
      blockade: true,
    });
    // For example a feed update earlier in the block, without a pool log of a toucher before us: no higher tip, but
    // temporary (no cool-down). Another keeper does leave Swap logs; those cases are below.
    const noTouch = onchainRevertVerdict({ kind: "passed" }, false);
    expect(noTouch.blockade).toBe(false);
    expect(failureAction(noTouch.failure, 0, 540)).toBe("retry");
  });

  test("an Executed log for the same owner before us: served by another keeper, no blockade, no retry, no cool-down (F-1)", () => {
    // Keeper A executed the owner earlier in the block: its swaps are pool logs before us (touched = true), and the
    // re-simulation at the start of the block passes. Still no blockade.
    const v = onchainRevertVerdict({ kind: "passed" }, true, true);
    expect(v.blockade).toBe(false);
    expect(v.failure.servedByOther).toBe(true);
    expect(failureAction(v.failure, 0, 540)).toBe("skip");
    expect(failureAction(v.failure, 1_000, 540)).toBe("skip");
    // Also when the re-simulation says something else: served takes precedence.
    expect(onchainRevertVerdict({ kind: "reverted", errorName: "SpotDeviatesFromOracle" }, true, true).failure.servedByOther).toBe(true);
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
    // First read empty (for example a pool touched in that block): still a second read.
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
    // Node ignores the override: the real values.
    expect(overridesApplied(`0x${word(0x6aab0227n)}${word(0x3103fffn)}`, overrides)).toBe(false);
    // Only the time applied.
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
    expect(() => parseGwei("0.0000000001")).toThrow("not a valid gwei amount");
    expect(() => parseGwei("-1")).toThrow("not a valid gwei amount");
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
    // Toucher at 1 gwei, keeper at 0.05: straight to 1.1 gwei (+1 wei), not 0.1.
    expect(nextPriorityFee(policy.base, GWEI, policy)).toBe(1_100_000_001n);
    // Toucher lower than double our own tip: double.
    expect(nextPriorityFee(parseGwei("0.4"), parseGwei("0.2"), policy)).toBe(parseGwei("0.8"));
    // Tip 0 from the toucher (cheapest blockade): still double.
    expect(nextPriorityFee(policy.base, 0n, policy)).toBe(parseGwei("0.1"));
    // Never above the cap, not even against a toucher at 10 gwei.
    expect(nextPriorityFee(policy.base, 10n * GWEI, policy)).toBe(policy.max);
  });

  test("never below the base fee policy", () => {
    expect(nextPriorityFee(0n, undefined, policy)).toBe(policy.base);
  });

  test("maxFeePerGas is twice the base fee plus the tip", () => {
    // Base fee 0.005 gwei (minimum on Base) and tip 0.05 gwei.
    expect(maxFeePerGas(5_000_000n, 50_000_000n)).toBe(60_000_000n);
  });

  test("effective tip of an included transaction", () => {
    const baseFee = 5_000_000n;
    expect(effectiveTip({ maxPriorityFeePerGas: 1_000_000n, maxFeePerGas: 100_000_000n }, baseFee)).toBe(1_000_000n);
    // maxFeePerGas caps the tip.
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
    // Outside the policy (for example a lower cap after a config change): capped.
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
    // Uniform over 59 blocks: the middle is 30.
    expect(nextSendBlock(1_000n, 30, 29 / 59)).toBe(1_030n);
    let sum = 0n;
    for (let i = 0; i < 59; i++) sum += nextSendBlock(0n, 30, i / 59);
    expect(sum / 59n).toBe(30n);
    // SEND_RETRY_BLOCKS = 1: always the next block.
    expect(nextSendBlock(1_000n, 1, 0.7)).toBe(1_001n);
  });
});

describe("competing keepers (final review F-1)", () => {
  const REBALANCER = "0x1234567890123456789012345678901234567890" as Address;
  const policy = { base: parseGwei("0.05"), max: parseGwei("3") };

  test("EXECUTE_SELECTOR is execute(address,address)", () => {
    expect(EXECUTE_SELECTOR as string).toBe(toFunctionSelector("function execute(address owner, address rewardTo)"));
  });

  test("a direct execute on the Rebalancer is not a blocker; a bundling contract or another call is", () => {
    const execInput = `${EXECUTE_SELECTOR}${"00".repeat(64)}` as `0x${string}`;
    expect(isDirectExecute({ to: REBALANCER, input: execInput }, REBALANCER)).toBe(true);
    expect(isDirectExecute({ to: REBALANCER.toUpperCase().replace("0X", "0x") as Address, input: execInput }, REBALANCER)).toBe(true);
    expect(isDirectExecute({ to: OTHER, input: execInput }, REBALANCER)).toBe(false);
    expect(isDirectExecute({ to: REBALANCER, input: "0xa9059cbb" }, REBALANCER)).toBe(false);
    expect(isDirectExecute({ to: null, input: execInput }, REBALANCER)).toBe(false);

    const txs = [
      { transactionIndex: 1, to: REBALANCER, input: execInput, tip: 3n * GWEI }, // other keeper
      { transactionIndex: 2, to: OTHER, input: "0x12345678" as `0x${string}`, tip: 7n }, // toucher
      { transactionIndex: 9, to: OTHER, input: "0x12345678" as `0x${string}`, tip: 100n }, // after us
    ];
    const blocking = blockingTransactions(txs, 5, REBALANCER);
    expect(blocking.map((tx) => tx.transactionIndex)).toEqual([2]);
    expect(blockerTip(blocking, 5)).toBe(7n);
    // Only another keeper before us: no toucher, so no blockade.
    expect(blockingTransactions(txs.slice(0, 1), 5, REBALANCER)).toEqual([]);
  });

  test("servedBefore only counts an Executed for the same owner before our transaction", () => {
    const logs = [
      { owner: OWNER, transactionIndex: 3 },
      { owner: OTHER, transactionIndex: 1 },
    ];
    expect(servedBefore(logs, OWNER, 4)).toBe(true);
    expect(servedBefore(logs, OWNER.toLowerCase() as Address, 4)).toBe(true);
    expect(servedBefore(logs, OWNER, 3)).toBe(false);
    expect(servedBefore(logs, OTHER, 0)).toBe(false);
    expect(servedBefore([], OWNER, 10)).toBe(false);
  });

  test("verification 579f763 (K-2): a competitor that served the owner one block earlier is no failure and no cool-down", () => {
    // The PoC: we simulate on block 99 (overrides for 100). Keeper A lands in block 100, our transaction in 101
    // (index 0) and reverts with NotDue. The resimulation on the start of 101 sees A's run too: NotDue.
    const simulated = 99n;
    const own = { blockNumber: 101n, transactionIndex: 0 };
    const logs = [{ owner: OWNER, blockNumber: 100n, transactionIndex: 7 }];
    const served = servedSince(logs, OWNER, simulated, own);
    expect(served).toBe(true);
    const verdict = onchainRevertVerdict({ kind: "reverted", errorName: "NotDue" }, false, served);
    expect(verdict.blockade).toBe(false);
    expect(verdict.failure.servedByOther).toBe(true);
    expect(failureAction(verdict.failure, 1_000, 1_540)).toBe("skip");
    // Without this rule (the old servedBefore on block 101 only) the same race was a failure with a cool-down.
    expect(onchainRevertVerdict({ kind: "reverted", errorName: "NotDue" }, false, servedBefore([], OWNER, 0)).failure.servedByOther).toBeUndefined();
  });

  test("servedSince counts only runs of the same owner after the simulated block and before our transaction", () => {
    const own = { blockNumber: 101n, transactionIndex: 4 };
    const at = (blockNumber: bigint, transactionIndex: number, owner: Address = OWNER) => [{ owner, blockNumber, transactionIndex }];
    expect(servedSince(at(101n, 3), OWNER, 99n, own)).toBe(true); // same block, before us (F-1)
    expect(servedSince(at(100n, 9), OWNER.toLowerCase() as Address, 99n, own)).toBe(true); // earlier block (K-2)
    expect(servedSince(at(101n, 4), OWNER, 99n, own)).toBe(false); // our own index
    expect(servedSince(at(101n, 5), OWNER, 99n, own)).toBe(false); // after us
    expect(servedSince(at(102n, 0), OWNER, 99n, own)).toBe(false); // later block
    expect(servedSince(at(99n, 0), OWNER, 99n, own)).toBe(false); // already in the simulated state
    expect(servedSince(at(100n, 0, OTHER), OWNER, 99n, own)).toBe(false); // other owner
    expect(servedSince([], OWNER, 99n, own)).toBe(false);
  });

  test("the tip halves after a run without blockade, down to the base, in 6 steps from 3 gwei", () => {
    const steps: string[] = [];
    let fee = policy.max;
    for (let i = 0; i < 7; i++) {
      fee = decayPriorityFee(fee, policy);
      steps.push(formatGwei(fee));
    }
    expect(steps).toEqual(["1.5", "0.75", "0.375", "0.1875", "0.09375", "0.05", "0.05"]);
    expect(decayPriorityFee(0n, policy)).toBe(policy.base);
  });

  test("eurcToWei converts with two 8-decimal Chainlink answers", () => {
    // 0.05 EURC, EURC/USD 1.146, ETH/USD 2,403.58: 0.05 × 1.146 / 2,403.58 ETH = 23,839,439,502,741 wei (rounded down).
    expect(eurcToWei(50_000n, 114_600_000n, 240_358_000_000n)).toBe(23_839_439_502_741n);
    expect(eurcToWei(50_000n, 0n, 240_358_000_000n)).toBe(0n);
    expect(eurcToWei(50_000n, 114_600_000n, -1n)).toBe(0n);
  });

  test("the tip cap: tip × gas never above the reward share plus the budget", () => {
    const rewardWei = eurcToWei(50_000n, 114_600_000n, 240_358_000_000n);
    const gasEstimate = 500_000n;
    // Only the reward (budget 0): 23,839,439,502,741 wei / 500,000 gas = 47,678,879 wei ≈ 0.048 gwei < base -> base.
    const rewardOnly = capFeePolicy(policy, { rewardWei, rewardShareBps: BPS, budgetWei: 0n, gasEstimate });
    expect(rewardOnly.max).toBe(policy.base);
    // Budget 0.0005 ETH: (23,839,439,502,741 + 5 × 10^14) / 500,000 = 1,047,678,879 wei ≈ 1.05 gwei.
    const withBudget = capFeePolicy(policy, { rewardWei, rewardShareBps: BPS, budgetWei: 500_000_000_000_000n, gasEstimate });
    expect(withBudget.max).toBe(1_047_678_879n);
    expect(withBudget.max * gasEstimate).toBeLessThanOrEqual(rewardWei + 500_000_000_000_000n);
    // Half of the reward: half of that share.
    expect(capFeePolicy(policy, { rewardWei, rewardShareBps: 5_000n, budgetWei: 500_000_000_000_000n, gasEstimate }).max).toBe(
      (rewardWei / 2n + 500_000_000_000_000n) / gasEstimate,
    );
    // A generous budget does not change the configured cap.
    expect(capFeePolicy(policy, { rewardWei, rewardShareBps: BPS, budgetWei: 10n ** 18n, gasEstimate }).max).toBe(policy.max);
    // Escalation stops at the cap, whatever the competitor bids.
    let fee = policy.base;
    for (let i = 0; i < 10; i++) fee = nextPriorityFee(fee, 3n * GWEI, withBudget);
    expect(fee).toBe(withBudget.max);
  });

  test("verification 579f763 (K-4): with the defaults the budget, not the reward, sets the cap", () => {
    const rewardWei = eurcToWei(50_000n, 114_600_000n, 240_358_000_000n);
    const gasEstimate = 500_000n;
    const defaults = capFeePolicy(policy, { rewardWei, rewardShareBps: BPS, budgetWei: 1_500_000_000_000_000n, gasEstimate });
    // (2.4e13 + 1.5e15) / 500,000 ≈ 3.05 gwei: above MAX_PRIORITY_FEE_GWEI, so the cap is 3 gwei.
    expect((rewardWei + 1_500_000_000_000_000n) / gasEstimate).toBeGreaterThan(policy.max);
    expect(defaults.max).toBe(policy.max);
    // The reward is ~1.6% of the budget; without a reward the cap stays the same.
    expect((rewardWei * 1_000n) / 1_500_000_000_000_000n).toBe(15n);
    expect(capFeePolicy(policy, { rewardWei: 0n, rewardShareBps: BPS, budgetWei: 1_500_000_000_000_000n, gasEstimate }).max).toBe(policy.max);
    // After one blockade with a high toucher tip the tip is at the cap right away.
    expect(nextPriorityFee(policy.base, 5n * GWEI, defaults)).toBe(defaults.max);
  });
});

describe("register scan rotation (final review F-2)", () => {
  const total = (segments: { offset: bigint; limit: bigint }[]) => segments.reduce((sum, s) => sum + s.limit, 0n);
  const indices = (segments: { offset: bigint; limit: bigint }[]) =>
    segments.flatMap((s) => Array.from({ length: Number(s.limit) }, (_, i) => s.offset + BigInt(i)));

  test("from offset 0 the register is read in order, in pages", () => {
    expect(scanSegments(0n, 1_200n, 500n)).toEqual([
      { offset: 0n, limit: 500n },
      { offset: 500n, limit: 500n },
      { offset: 1_000n, limit: 200n },
    ]);
  });

  test("from a stored offset: to the end, then from 0 up to the offset, every owner exactly once", () => {
    const segments = scanSegments(1_200n, 2_000n, 500n);
    expect(segments).toEqual([
      { offset: 1_200n, limit: 500n },
      { offset: 1_700n, limit: 300n },
      { offset: 0n, limit: 500n },
      { offset: 500n, limit: 500n },
      { offset: 1_000n, limit: 200n },
    ]);
    expect(total(segments)).toBe(2_000n);
    const seen = indices(segments);
    expect(new Set(seen).size).toBe(2_000);
    expect(seen[0]).toBe(1_200n);
  });

  test("an offset beyond the register wraps; an empty register or page gives nothing", () => {
    expect(scanSegments(2_500n, 2_000n, 500n)[0]).toEqual({ offset: 500n, limit: 500n });
    expect(scanSegments(0n, 0n, 500n)).toEqual([]);
    expect(scanSegments(5n, 10n, 0n)).toEqual([]);
  });

  test("the next run starts where this one stopped, or at the first candidate it did not read", () => {
    expect(nextScanOffset(12_500n, null, 20_001n)).toBe(12_500n);
    expect(nextScanOffset(12_500n, 3_000n, 20_001n)).toBe(3_000n);
    // Whole register read: scannedTo is the start again.
    expect(nextScanOffset(20_001n, null, 20_001n)).toBe(0n);
    expect(nextScanOffset(7n, null, 0n)).toBe(0n);
  });

  test("verification 579f763 (info c): after a crash the next run resumes at the first unread register candidate", () => {
    const owner = (i: number) => `0x${i.toString(16).padStart(40, "0")}` as Address;
    // Candidates: two from OWNERS_FILE (no position), then register positions 12,100, 12,340 and 12,410.
    const candidates = [
      { owner: owner(1), index: null },
      { owner: owner(2), index: null },
      { owner: owner(3), index: 12_100n },
      { owner: owner(4), index: 12_340n },
      { owner: owner(5), index: 12_410n },
    ];
    const batches = chunks(candidates, 2);
    // Error in the second batch: that batch and everything after it has not been read yet.
    const pending = batches.slice(1).flat();
    expect(firstRegisterIndex(pending)).toBe(12_100n);
    expect(nextScanOffset(12_500n, firstRegisterIndex(pending), 20_001n)).toBe(12_100n);
    // Error in the last batch.
    expect(firstRegisterIndex(batches.slice(2).flat())).toBe(12_410n);
    // Error after all batches (in the retry queue) or only OWNERS_FILE left: where the search stopped.
    expect(nextScanOffset(12_500n, firstRegisterIndex([]), 20_001n)).toBe(12_500n);
    expect(nextScanOffset(12_500n, firstRegisterIndex(candidates.slice(0, 2)), 20_001n)).toBe(12_500n);
  });

  test("with spam in front of a real owner, the rotation reaches him within ceil(count / per run) runs", () => {
    // 20,000 spam addresses at 0..19,999, the real owner at 20,000; 3,000 owners fit in the search time per run.
    const count = 20_001n;
    const perRun = 3_000n;
    let start = 0n;
    let runs = 0;
    for (; runs < 100; runs++) {
      const segments = scanSegments(start, count, 500n);
      let read = 0n;
      let stoppedAt = start;
      let found = false;
      for (const s of segments) {
        if (read >= perRun) {
          stoppedAt = s.offset;
          break;
        }
        if (20_000n >= s.offset && 20_000n < s.offset + s.limit) found = true;
        read += s.limit;
      }
      if (found) break;
      start = nextScanOffset(stoppedAt, null, count);
    }
    expect(runs + 1).toBeLessThanOrEqual(Math.ceil(20_001 / 3_000));
  });

  test("parseScanState reads its own format and falls back to 0", () => {
    expect(parseScanState('{"nextOffset":"12500"}')).toBe(12_500n);
    expect(parseScanState(undefined)).toBe(0n);
    expect(parseScanState("{}")).toBe(0n);
    expect(parseScanState('{"nextOffset":-1}')).toBe(0n);
    expect(parseScanState("not json")).toBe(0n);
  });

  test("parseOwnersFile: addresses separated by lines, spaces or commas, comments, deduplicated", () => {
    const text = `# own users\n${OWNER}\n${OTHER}, ${OWNER.toLowerCase()}  # duplicate\n\n`;
    expect(parseOwnersFile(text.replace(OWNER, getAddress(OWNER)))).toEqual([getAddress(OWNER), OTHER]);
    // Verification 579f763 (K-1): a wrong checksum does not get through; viem would make every read for that batch fail.
    expect(() => parseOwnersFile(OWNER)).toThrow("invalid checksum");
    expect(parseOwnersFile("")).toEqual([]);
    expect(() => parseOwnersFile("0x123")).toThrow("not a valid address");
  });
});

describe("RPC URL in logs (verification 579f763, info b)", () => {
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
    // Loose parts, e.g. an error body that repeats the key or a decoded query value.
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

describe("quietRevertSendBlock (verification 579f763, info a)", () => {
  test("the first revert without blockade retries in the next block; repeated ones wait 2, 4, 8, ... blocks, capped", () => {
    expect(quietRevertSendBlock(1_000n, 0, 30)).toBeNull();
    expect(quietRevertSendBlock(1_000n, 1, 30)).toBeNull();
    expect([2, 3, 4, 5, 6, 7, 50, 2_000].map((n) => quietRevertSendBlock(1_000n, n, 30))).toEqual([
      1_002n,
      1_004n,
      1_008n,
      1_016n,
      1_030n,
      1_030n,
      1_030n,
      1_030n,
    ]);
    expect(quietRevertSendBlock(1_000n, 3, 1)).toBe(1_001n);
  });

  test("a direct execute of another party is no blockade, and with the wait the keeper no longer sends every block", () => {
    // Every attempt reverts on-chain; the re-simulation passes and before us was only a direct execute (no toucher).
    const verdict = onchainRevertVerdict({ kind: "passed" }, false, false);
    expect(verdict.blockade).toBe(false);
    expect(isTemporaryFailure(verdict.failure)).toBe(true);
    // Simulate 300 blocks (~10 minutes): how many transactions does the keeper send?
    let sendFrom: bigint | null = null;
    let reverts = 0;
    let sent = 0;
    for (let block = 1n; block <= 300n; block += 1n) {
      if (sendFrom !== null && block < sendFrom) continue;
      sent += 1;
      reverts += 1;
      const from = quietRevertSendBlock(block, reverts, 30);
      if (from !== null && (sendFrom === null || from > sendFrom)) sendFrom = from;
    }
    // Before: 300 reverted transactions. Now in blocks 1, 2, 4, 12, 28 and then every 30 blocks from 44: 14.
    expect(sent).toBe(14);
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
    // Throttle already passed: just the next block.
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
    expect(() => parseCooldownState("[]")).toThrow("not a JSON object");
    expect(() => parseCooldownState('{"0xabc":{"until":"soon"}}')).toThrow("invalid entry");
  });
});

describe("register spam filter (lead 9)", () => {
  const FLOOR = 20n * EURC_UNIT;
  // 100,000 EURC per cbBTC (EURC base units per cbBTC, like quote()).
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
    // 39.99 EURC is enough for a run of 20 EURC: the contract can execute that owner, so he stays.
    expect(isCandidate({ ...empty, eurcBalance: 39_990_000n, eurcAllowance: max }, PRICE, FLOOR)).toBe(true);
  });

  test("sell side: min(cbBTC balance, allowance) valued at quote() must reach the minimum run, rounded down", () => {
    // 20 EURC at 100,000 EURC per cbBTC = 20,000 sat.
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
    // 10,000 empty spam registrations leave not a single candidate.
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

describe("lock (final review I-5)", () => {
  const alive = (pids: number[]) => (pid: number) => pids.includes(pid);

  test("the lock stores pid and start time and reads back; the old pid-only format gets the file time", () => {
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
    // Crash at 1,000; the OS later gives pid 100 to another process. Before, every run then stopped silently.
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

describe("stuck transaction (final review I-6)", () => {
  const max = parseGwei("3");

  test("a transaction is stuck after TX_WAIT_BLOCKS blocks without a receipt", () => {
    expect(isStuck(1_000n, 1_014n, 15)).toBe(false);
    expect(isStuck(1_000n, 1_015n, 15)).toBe(true);
  });

  test("a replacement raises tip and maxFeePerGas by more than the 10% a node requires", () => {
    const previous = { maxPriorityFeePerGas: parseGwei("0.05"), maxFeePerGas: parseGwei("0.06") };
    const next = replacementFees(previous, parseGwei("0.005"), max);
    expect(next).not.toBeNull();
    if (next === null) return;
    expect(next.maxPriorityFeePerGas * 10n).toBeGreaterThanOrEqual(previous.maxPriorityFeePerGas * 11n);
    expect(next.maxFeePerGas * 10n).toBeGreaterThanOrEqual(previous.maxFeePerGas * 11n);
    expect(next.maxPriorityFeePerGas).toBe(56_250_001n);
  });

  test("a risen base fee lifts maxFeePerGas to at least twice the base fee plus the tip", () => {
    // Base fee from 0.005 to 0.5 gwei: the old maxFee of 0.06 gwei is far too low.
    const next = replacementFees({ maxPriorityFeePerGas: parseGwei("0.05"), maxFeePerGas: parseGwei("0.06") }, parseGwei("0.5"), max);
    expect(next?.maxFeePerGas).toBe(parseGwei("1") + 56_250_001n);
  });

  test("no replacement above the tip cap: the run stops clearly", () => {
    expect(replacementFees({ maxPriorityFeePerGas: max, maxFeePerGas: max * 2n }, parseGwei("0.005"), max)).toBeNull();
    expect(replacementFees({ maxPriorityFeePerGas: parseGwei("2.7"), maxFeePerGas: max * 2n }, 0n, max)).toBeNull();
  });

  test("verification 579f763 (K-6): with an own transaction still pending nothing new is sent, and that is temporary", () => {
    expect(ownTransactionPending(41, 41)).toBe(false);
    expect(ownTransactionPending(41, 42)).toBe(true); // the previous run left nonce 41 pending
    // keeper.ts then throws a plain Error (no contract revert): temporary, retried in a later block, no cool-down.
    expect(failureAction({ errorName: undefined, transient: true }, 0, 540)).toBe("retry");
  });

  test("verification 579f763 (K-6): a transaction is only sent if it fits before the watchdog", () => {
    // Default: 4 sends × (15 blocks × 2 s + 30 s) + 30 s.
    expect(sendWorstCaseSeconds(15, 3, 30)).toBe(270);
    const start = 1_000;
    const watchdogAt = start + lockWatchdogSeconds(900); // 1,885
    // Up to the end of the retry budget (540 s) a whole transaction fits with the defaults.
    expect(hasTimeToSend(start + 540, watchdogAt, 270)).toBe(true);
    expect(hasTimeToSend(start + 615, watchdogAt, 270)).toBe(true);
    expect(hasTimeToSend(start + 616, watchdogAt, 270)).toBe(false);
    // The minimal configuration LOCK_MAX_SECONDS = RETRY_SECONDS + 60: right before the end of the budget, no longer.
    expect(hasTimeToSend(start + 530, start + lockWatchdogSeconds(600), 270)).toBe(false);
  });
});

describe("REWARD_TO (final review I-8)", () => {
  const REBALANCER = "0x68B1D87F95878fE05B998F19b66F4baba5De1aed";

  test("a valid address, also the zero address (no reward), passes", () => {
    expect(rewardToError(getAddress(OWNER), REBALANCER)).toBeNull();
    expect(rewardToError(OWNER.toLowerCase(), REBALANCER)).toBeNull();
    expect(rewardToError("0x0000000000000000000000000000000000000000", REBALANCER)).toBeNull();
  });

  test("an invalid address is refused with a clear message", () => {
    expect(rewardToError("0x123", REBALANCER)).toBe("REWARD_TO is not a valid address: 0x123");
    expect(rewardToError("", REBALANCER)).toContain("not a valid address");
    expect(rewardToError("my-wallet.eth", REBALANCER)).toContain("not a valid address");
  });

  test("verification 579f763 (K-1): a wrong checksum is refused, and every address that passes, viem can encode", () => {
    const bad = "0xAbCdEf0000000000000000000000000000000001"; // mixed case, wrong checksum (the PoC)
    expect(rewardToError(bad, REBALANCER)).toContain("invalid checksum");
    expect(rewardToError(OWNER, REBALANCER)).toContain("invalid checksum");
    const encode = (rewardTo: string) =>
      encodeFunctionData({
        abi: parseAbi(["function execute(address owner, address rewardTo)"]),
        functionName: "execute",
        args: ["0x0000000000000000000000000000000000000003", rewardTo as Address],
      });
    expect(() => encode(bad)).toThrow("is invalid");
    const accepted = [bad.toLowerCase(), getAddress(bad), getAddress(OWNER), OWNER.toLowerCase(), "0x0000000000000000000000000000000000000000"];
    for (const good of accepted) {
      expect(rewardToError(good, REBALANCER)).toBeNull();
      expect(() => encode(good)).not.toThrow();
    }
  });

  test("the Rebalancer itself is refused, whatever the case", () => {
    expect(rewardToError(REBALANCER, REBALANCER)).toContain("Rebalancer contract itself");
    expect(rewardToError(REBALANCER.toLowerCase(), REBALANCER)).toContain("Rebalancer contract itself");
  });
});
