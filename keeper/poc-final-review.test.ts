/**
 * Final review F-1 as a regression test. The PoC showed that a competing keeper that executes the same owner earlier
 * in the block drove the priority fee up to 3 gwei and kept it there for an hour. Input as in the fork PoC
 * `test_poc_F1_competingKeeperCountsAsBlockade`: our own transaction reverts with NotDue, the re-simulation at the
 * start of the block passes, and before our own transaction there are Swap logs of both pools from keeper A (a direct
 * `execute`) and an `Executed` log for the same owner.
 *
 * Correct behaviour: no blockade, no cool-down, the tip stays at the base and drops after a run without a blockade,
 * and a tip × gas above what the run yields plus the budget is not possible.
 */
import { expect, test } from "bun:test";
import type { Address, Hex } from "viem";
import {
  EXECUTE_SELECTOR,
  GWEI,
  blockerTip,
  blockingTransactions,
  capFeePolicy,
  decayPriorityFee,
  eurcToWei,
  failureAction,
  formatGwei,
  nextPriorityFee,
  onchainRevertVerdict,
  parseGwei,
  servedBefore,
  startPriorityFee,
} from "./selection";

const REBALANCER = "0x5555555555555555555555555555555555555555" as Address;
const OWNER = "0x7777777777777777777777777777777777777777" as Address;
const policy = { base: parseGwei("0.05"), max: parseGwei("3") };
const executeInput = `${EXECUTE_SELECTOR}${"00".repeat(64)}` as Hex;

/** Block from the PoC: keeper A (index 3) executes OWNER and swaps through both pools; keeper B (us) is at index 5. */
const ownIndex = 5;
const poolTxs = [{ transactionIndex: 3, to: REBALANCER, input: executeInput, tip: parseGwei("0.05") }];
const executedLogs = [{ owner: OWNER, transactionIndex: 3 }];

test("F-1: a competitor on the same owner is no blockade; the tip does not rise", () => {
  const blocking = blockingTransactions(poolTxs, ownIndex, REBALANCER);
  const verdict = onchainRevertVerdict({ kind: "passed" }, blocking.length > 0, servedBefore(executedLogs, OWNER, ownIndex));
  expect(verdict.blockade).toBe(false);
  expect(verdict.failure.servedByOther).toBe(true);
  expect(failureAction(verdict.failure, 0, 540)).toBe("skip");

  // Six lost races against a keeper with the same default tip: the tip stays at the base and drops after every race.
  let fee = policy.base;
  const steps: string[] = [formatGwei(fee)];
  for (let i = 0; i < 6; i++) {
    const v = onchainRevertVerdict({ kind: "passed" }, blocking.length > 0, true);
    fee = v.blockade ? nextPriorityFee(fee, blockerTip(blocking, ownIndex), policy) : decayPriorityFee(fee, policy);
    steps.push(formatGwei(fee));
  }
  console.log(`tip after 6 lost races: ${steps.join(" -> ")} gwei`);
  expect(fee).toBe(policy.base);
});

test("F-1: without Executed for the owner, another keeper with a direct execute does not count as a toucher", () => {
  // Keeper A executed a different owner; our owner therefore reverts on PoolTouchedThisBlock. No tip escalation against
  // a keeper, but a new attempt (temporary).
  const blocking = blockingTransactions(poolTxs, ownIndex, REBALANCER);
  expect(blocking).toEqual([]);
  const v = onchainRevertVerdict({ kind: "reverted", errorName: "PoolTouchedThisBlock" }, blocking.length > 0, false);
  expect(v.blockade).toBe(false);
  expect(failureAction(v.failure, 0, 540)).toBe("retry");
});

test("F-1: a real toucher makes the tip rise, but never above what the run yields plus the budget", () => {
  const attacker = { transactionIndex: 2, to: "0x9999999999999999999999999999999999999999" as Address, input: "0x12345678" as Hex, tip: parseGwei("3") };
  const blocking = blockingTransactions([...poolTxs, attacker], ownIndex, REBALANCER);
  expect(blocking).toEqual([attacker]);
  expect(onchainRevertVerdict({ kind: "passed" }, true, false).blockade).toBe(true);

  // Prices from the review (block 51,403,300): EURC/USD 1.146, ETH/USD 2,403.58. Reward 0.05 EURC, gas 500,000,
  // budget 0.0005 ETH per run.
  const rewardWei = eurcToWei(50_000n, 114_600_000n, 240_358_000_000n);
  const gasEstimate = 500_000n;
  const budgetWei = 500_000_000_000_000n;
  const capped = capFeePolicy(policy, { rewardWei, rewardShareBps: 10_000n, budgetWei, gasEstimate });
  let fee = policy.base;
  for (let i = 0; i < 10; i++) fee = nextPriorityFee(fee, blockerTip(blocking, ownIndex), capped);
  console.log(`tip cap: ${formatGwei(capped.max)} gwei; tip × gas ${Number(fee * gasEstimate) / 1e18} ETH ≤ ${Number(rewardWei + budgetWei) / 1e18} ETH`);
  expect(fee).toBe(capped.max);
  expect(fee * gasEstimate).toBeLessThanOrEqual(rewardWei + budgetWei);
  expect(fee).toBeLessThan(policy.max);

  // Stored and in the next run capped at the same cap, even if the file says 3 gwei.
  const state = { priorityFeeWei: (3n * GWEI).toString(), lastBlockadeAt: 1_000 };
  expect(startPriorityFee(state, 1_000 + 60, capped, 3_600)).toBe(capped.max);
  // A run without a blockade lowers it.
  expect(decayPriorityFee(capped.max, capped)).toBe(capped.max / 2n);
});
