/**
 * Eindreview F-1 als regressietest. De PoC liet zien dat een concurrerende keeper die dezelfde owner eerder in het blok
 * uitvoert, de priority fee opdreef tot 3 gwei en daar een uur hield. Invoer zoals de fork-PoC
 * `test_poc_F1_competingKeeperCountsAsBlockade`: de eigen transactie revert met NotDue, de hersimulatie op het begin van
 * het blok slaagt, en vóór de eigen transactie staan Swap-logs van beide pools van keeper A (een directe `execute`) en
 * een `Executed`-log voor dezelfde owner.
 *
 * Juist gedrag: geen blokkade, geen cool-down, de tip blijft op de basis en zakt na een run zonder blokkade, en een tip
 * × gas boven wat de run oplevert plus het budget is niet mogelijk.
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

/** Het blok uit de PoC: keeper A (index 3) voert OWNER uit en swapt door beide pools; keeper B (wij) staat op index 5. */
const ownIndex = 5;
const poolTxs = [{ transactionIndex: 3, to: REBALANCER, input: executeInput, tip: parseGwei("0.05") }];
const executedLogs = [{ owner: OWNER, transactionIndex: 3 }];

test("F-1: een concurrent op dezelfde owner is geen blokkade; de tip loopt niet op", () => {
  const blocking = blockingTransactions(poolTxs, ownIndex, REBALANCER);
  const verdict = onchainRevertVerdict({ kind: "passed" }, blocking.length > 0, servedBefore(executedLogs, OWNER, ownIndex));
  expect(verdict.blockade).toBe(false);
  expect(verdict.failure.servedByOther).toBe(true);
  expect(failureAction(verdict.failure, 0, 540)).toBe("skip");

  // Zes verloren races tegen een keeper met dezelfde standaardtip: de tip blijft op de basis en zakt na elke race.
  let fee = policy.base;
  const steps: string[] = [formatGwei(fee)];
  for (let i = 0; i < 6; i++) {
    const v = onchainRevertVerdict({ kind: "passed" }, blocking.length > 0, true);
    fee = v.blockade ? nextPriorityFee(fee, blockerTip(blocking, ownIndex), policy) : decayPriorityFee(fee, policy);
    steps.push(formatGwei(fee));
  }
  console.log(`tip na 6 verloren races: ${steps.join(" -> ")} gwei`);
  expect(fee).toBe(policy.base);
});

test("F-1: zonder Executed voor de owner telt een andere keeper met een directe execute niet als aanraker", () => {
  // Keeper A voerde een andere owner uit; onze owner revert daardoor op PoolTouchedThisBlock. Geen tip-escalatie tegen
  // een keeper, wel een nieuwe poging (tijdelijk).
  const blocking = blockingTransactions(poolTxs, ownIndex, REBALANCER);
  expect(blocking).toEqual([]);
  const v = onchainRevertVerdict({ kind: "reverted", errorName: "PoolTouchedThisBlock" }, blocking.length > 0, false);
  expect(v.blockade).toBe(false);
  expect(failureAction(v.failure, 0, 540)).toBe("retry");
});

test("F-1: een echte aanraker laat de tip oplopen, maar nooit boven wat de run oplevert plus het budget", () => {
  const attacker = { transactionIndex: 2, to: "0x9999999999999999999999999999999999999999" as Address, input: "0x12345678" as Hex, tip: parseGwei("3") };
  const blocking = blockingTransactions([...poolTxs, attacker], ownIndex, REBALANCER);
  expect(blocking).toEqual([attacker]);
  expect(onchainRevertVerdict({ kind: "passed" }, true, false).blockade).toBe(true);

  // Koersen uit de review (blok 51.403.300): EURC/USD 1,146, ETH/USD 2.403,58. Beloning 0,05 EURC, gas 500.000,
  // budget 0,0005 ETH per run.
  const rewardWei = eurcToWei(50_000n, 114_600_000n, 240_358_000_000n);
  const gasEstimate = 500_000n;
  const budgetWei = 500_000_000_000_000n;
  const capped = capFeePolicy(policy, { rewardWei, rewardShareBps: 10_000n, budgetWei, gasEstimate });
  let fee = policy.base;
  for (let i = 0; i < 10; i++) fee = nextPriorityFee(fee, blockerTip(blocking, ownIndex), capped);
  console.log(`tipplafond: ${formatGwei(capped.max)} gwei; tip × gas ${Number(fee * gasEstimate) / 1e18} ETH ≤ ${Number(rewardWei + budgetWei) / 1e18} ETH`);
  expect(fee).toBe(capped.max);
  expect(fee * gasEstimate).toBeLessThanOrEqual(rewardWei + budgetWei);
  expect(fee).toBeLessThan(policy.max);

  // Opgeslagen en in de volgende run begrensd op hetzelfde plafond, ook als het bestand 3 gwei zegt.
  const state = { priorityFeeWei: (3n * GWEI).toString(), lastBlockadeAt: 1_000 };
  expect(startPriorityFee(state, 1_000 + 60, capped, 3_600)).toBe(capped.max);
  // Een run zonder blokkade laat hem zakken.
  expect(decayPriorityFee(capped.max, capped)).toBe(capped.max / 2n);
});
