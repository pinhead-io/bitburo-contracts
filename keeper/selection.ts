/**
 * Selection logic of the keeper script, separate from RPC and file system so that it can be tested.
 */
import { type Address, type Hex, isAddress } from "viem";

export const EURC_UNIT = 1_000_000n;

/** Reason to skip a due owner based on the run size, or null if the run takes part. */
export const runSizeSkipReason = (eurcDelta: bigint, minRunEurc: number): string | null => {
  const size = eurcDelta < 0n ? -eurcDelta : eurcDelta;
  if (size < BigInt(Math.ceil(minRunEurc * Number(EURC_UNIT)))) {
    return `run too small (${formatEurc(size)} EURC < ${minRunEurc} EURC)`;
  }
  return null;
};

/**
 * Reverts of the block check and the block window (audit M-1, review PR #18). These are temporary, so they do not
 * count as a failure for the cool-down; in a following block it usually does succeed:
 * - PoolTouchedThisBlock(address pool), selector 0x817a53db: a pool already wrote an oracle observation in this block
 *   (a swap that changed the tick, or a mint or burn in range), by someone else or by an earlier run.
 *   An `eth_call` on the latest block also sees this if something happened in the pool in that very block.
 * - BlockMoveExceeded(address pool), selector 0x66356d6d: too little room or liquidity in the window, or the run
 *   hit the window edge.
 */
export const BLOCK_WINDOW_ERRORS: readonly string[] = ["PoolTouchedThisBlock", "BlockMoveExceeded"];

export const isBlockWindowRevert = (errorName: string | undefined): boolean =>
  errorName !== undefined && BLOCK_WINDOW_ERRORS.includes(errorName);

/**
 * What a failure is: the name of the contract error (if it could be decoded), and whether it was a transaction that
 * reverted on-chain while a new simulation on that transaction's block passes. The latter points to a
 * temporary state before the transaction in the same block (for example a swap that filled the window), not to an
 * owner that reverts structurally.
 */
export type Failure = {
  errorName: string | undefined;
  resimulationPassed?: boolean;
  /**
   * Not a contract revert but an error of the node or the network (429, timeout, "header not found"). Says nothing
   * about the owner, so no cool-down.
   */
  transient?: boolean;
  /**
   * Final review F-1: the owner was already executed by another keeper in the same block before our own transaction (an
   * `Executed` log for that owner with a lower `transactionIndex`). No blockade and no failure: the owner has been
   * served. No new attempt, no cool-down, no higher tip.
   */
  servedByOther?: boolean;
};

export const isTemporaryFailure = (failure: Failure): boolean =>
  isBlockWindowRevert(failure.errorName) || failure.resimulationPassed === true || failure.transient === true;

/**
 * Outcome of the re-simulation after our own transaction reverted on-chain: on the state at the start of that block
 * (previous block, with the overrides of the block itself), so that only transactions before our own transaction can
 * make the difference and not what came after.
 */
export type Resimulation = { kind: "passed" } | { kind: "reverted"; errorName: string | undefined } | { kind: "error" };

/**
 * Verdict on an on-chain revert:
 * - if an `Executed` for the same owner precedes our own transaction (`servedBefore`), another keeper did the
 *   run: served, no blockade, no cool-down (final review F-1). This takes precedence over everything, because every
 *   `execute` swaps through both pools and logs a Swap there; without this rule every lost race looked like a blockade;
 * - the re-simulation passes: something earlier in the block made the transaction revert; temporary;
 * - the re-simulation reverts with a block window error, or the node returned an error: temporary;
 * - the re-simulation reverts with another error: that error is the real reason (cool-down);
 * - `blockade`: temporary and a transaction before our own touched a pool (Swap, Mint or Burn) and was itself not a
 *   direct `execute` on the Rebalancer (`blockingTransactions`). Only then does the priority fee rise; an earlier
 *   feed update or another keeper that executed an owner is no reason to bid more.
 */
export const onchainRevertVerdict = (
  resimulation: Resimulation,
  touchedBefore: boolean,
  servedBefore = false,
): { failure: Failure; blockade: boolean } => {
  if (servedBefore) {
    return { failure: { errorName: undefined, servedByOther: true }, blockade: false };
  }
  const failure: Failure =
    resimulation.kind === "passed"
      ? { errorName: undefined, resimulationPassed: true }
      : resimulation.kind === "error"
        ? { errorName: undefined, transient: true }
        : { errorName: resimulation.errorName };
  return { failure, blockade: touchedBefore && isTemporaryFailure(failure) };
};

/**
 * What to do after a failed simulation or transaction for an owner (audit L-3):
 * - "retry": temporary (block check, block window or an on-chain revert that passes when simulated again), try
 *   again in a following block, as long as the retry budget of this keeper run lasts (`nowSeconds < retryDeadline`);
 * - "skip": the budget is spent and it is still temporary; record nothing, the next keeper run tries again;
 * - "fail": a real failure, which counts for the cool-down.
 * An owner that another keeper already executed in the same block (`servedByOther`) is always "skip".
 *
 * The budget is a time and not a number of attempts: an attacker who touches a pool every block then has to keep
 * that up for the whole budget, not just a few predictable blocks.
 */
export const failureAction = (
  failure: Failure | string | undefined,
  nowSeconds: number,
  retryDeadline: number,
): "retry" | "skip" | "fail" => {
  const f: Failure = typeof failure === "object" ? failure : { errorName: failure };
  if (f.servedByOther === true) {
    return "skip";
  }
  if (!isTemporaryFailure(f)) {
    return "fail";
  }
  return nowSeconds < retryDeadline ? "retry" : "skip";
};

/**
 * End of the retry budget of a keeper run: `RETRY_SECONDS` after the start. Default 540 s, the advice to run every
 * 10 minutes minus one minute of margin, so that the run is done before the next one starts.
 */
export const retryDeadline = (startSeconds: number, retrySeconds: number): number => startSeconds + retrySeconds;

/**
 * Review I-1: a read of `isDue` (per batch of candidates) is a snapshot. An owner that did not seem due at that
 * moment because a pool had already been touched in that block (by someone else, or by our own run) would otherwise
 * miss out until the next cron. The keeper therefore reads a batch at least twice, each time in a later block, and
 * handles only owners it did not have yet in this run. After the second read it only continues while a read still
 * yields someone new, and never beyond `maxReads` reads.
 *
 * If the keeper reads with the overrides of the next block (`nextBlockOverrides`), it sees no touch from the
 * latest block and one read is enough; the double read only applies when falling back to the latest block.
 */
export const newOwners = (page: readonly Address[], handled: ReadonlySet<string>): Address[] =>
  page.filter((owner) => !handled.has(owner.toLowerCase()));

export const shouldReadPageAgain = (
  newInLastRead: number,
  reads: number,
  maxReads: number,
  readsNextBlock = false,
): boolean => !readsNextBlock && reads < maxReads && (reads < 2 || newInLastRead > 0);

// ─── Audit L-3: reading as if it were the next block ─────────────────────────────────────────────────────────────

/** Time between two blocks on Base. */
export const BASE_BLOCK_SECONDS = 2n;

export type BlockOverrides = { number: bigint; time: bigint };

/**
 * Overrides with which an `eth_call` on the state of the latest block runs as if it were the next block. The
 * contract compares a pool's last observation with `block.timestamp`; in the next block a touch from the latest
 * block is therefore no longer a touch. Without this the keeper sees a touch in the latest block as "not due" and
 * sends nothing, and an attacker does not even need to be ahead of the keeper in the block (L-3).
 */
export const nextBlockOverrides = (latest: { number: bigint; timestamp: bigint }): BlockOverrides => ({
  number: latest.number + 1n,
  time: latest.timestamp + BASE_BLOCK_SECONDS,
});

/**
 * Creation code that returns `block.timestamp` and `block.number` (TIMESTAMP PUSH1 0 MSTORE NUMBER PUSH1 0x20 MSTORE
 * PUSH1 0x40 PUSH1 0 RETURN). As an `eth_call` without `to` the keeper has the node execute this with the overrides, to
 * check that the node applies them. Same probe as the app keeper.
 */
export const OVERRIDE_PROBE_CODE = "0x426000524360205260406000f3" as const;

/**
 * Does the node apply the overrides? Only if exactly the overridden timestamp and the overridden block number
 * come back: a node that ignores an unknown override returns no error but the real values.
 */
export const overridesApplied = (returnData: string | undefined, overrides: BlockOverrides): boolean => {
  if (returnData === undefined || !/^0x[0-9a-fA-F]{128}$/.test(returnData)) {
    return false;
  }
  const time = BigInt(`0x${returnData.slice(2, 66)}`);
  const number = BigInt(`0x${returnData.slice(66, 130)}`);
  return time === overrides.time && number === overrides.number;
};

// ─── Audit L-3: priority fee ────────────────────────────────────────────────────────────────────────────────────

export const GWEI = 1_000_000_000n;

/** wei → gwei as text, without trailing zeros ("0.05"). */
export const formatGwei = (wei: bigint): string => {
  const fraction = (wei % GWEI).toString().padStart(9, "0").replace(/0+$/, "");
  return fraction === "" ? `${wei / GWEI}` : `${wei / GWEI}.${fraction}`;
};

/** "0.05" gwei → wei, without a float's rounding errors. */
export const parseGwei = (value: string): bigint => {
  const match = /^(\d+)(?:\.(\d{1,9}))?$/.exec(value.trim());
  if (match === null) {
    throw new Error(`not a valid gwei amount: ${value}`);
  }
  return BigInt(match[1]) * GWEI + BigInt((match[2] ?? "").padEnd(9, "0"));
};

export type FeePolicy = {
  /** Priority fee without a blockade (PRIORITY_FEE_GWEI, default 0.05 gwei). */
  base: bigint;
  /** Cap (MAX_PRIORITY_FEE_GWEI, default 3 gwei). */
  max: bigint;
};

/**
 * Priority fee after a blockade: our own transaction that reverted on-chain due to a temporary cause, i.e. because an
 * other transaction earlier in the same block touched a pool or filled the window.
 *
 * Base orders by priority fee within a Flashblock; whoever is ahead of the toucher runs. The step:
 * - at least a doubling. From 0.05 to the cap of 3 gwei that is 6 steps (0.1 – 0.2 – 0.4 – 0.8 – 1.6 –
 *   3). With on average one send per `SEND_RETRY_BLOCKS` (default 30 blocks ≈ 1 minute) the keeper is
 *   at the cap within ~6 minutes, so within one 10-minute run; with a step of +25% that is 19 attempts and
 *   it loses two runs. At the same time it pays at most double the tip that was needed.
 * - if the toucher's tip is known (`blockerTip`), then straight to 10% above it if that is more: one attempt instead
 *   of a series of doublings, and a margin against an attacker who keeps raising his tip a little.
 * - never above `max`. At 3 gwei blocking costs the attacker ~1,050 EURC per hour (92,630 gas per block × 1,800
 *   blocks, measured gas; L-3 measurements), vs ~15 EURC/hour for the keeper (one reverted attempt of ~40k gas/minute).
 */
export const nextPriorityFee = (current: bigint, blockerTip: bigint | undefined, policy: FeePolicy): bigint => {
  let next = current * 2n;
  if (blockerTip !== undefined) {
    const outbid = (blockerTip * 11n + 9n) / 10n + 1n;
    if (outbid > next) next = outbid;
  }
  if (next < policy.base) next = policy.base;
  return next > policy.max ? policy.max : next;
};

/** Stored priority fee between keeper runs (`FEE_STATE_FILE`). */
export type FeeState = { priorityFeeWei: string; lastBlockadeAt: number };

/**
 * Priority fee at the start of a run. Without memory every run would start at the base and again need ~6 blockades
 * to reach the cap; the attacker then mostly pays low tips. So the keeper holds on to the tip
 * as long as the last blockade was less than `holdSeconds` (FEE_HOLD_SECONDS, default 3600) ago, and starts
 * at the base again after that. Without an attack this costs at most one hour of runs at the raised tip.
 */
export const startPriorityFee = (
  state: FeeState | undefined,
  nowSeconds: number,
  policy: FeePolicy,
  holdSeconds: number,
): bigint => {
  if (state === undefined || nowSeconds - state.lastBlockadeAt >= holdSeconds) {
    return policy.base;
  }
  const fee = BigInt(state.priorityFeeWei);
  if (fee < policy.base) return policy.base;
  return fee > policy.max ? policy.max : fee;
};

export const parseFeeState = (json: string): FeeState | undefined => {
  const parsed: unknown = JSON.parse(json);
  if (
    parsed === null ||
    typeof parsed !== "object" ||
    typeof (parsed as FeeState).priorityFeeWei !== "string" ||
    !/^\d+$/.test((parsed as FeeState).priorityFeeWei) ||
    typeof (parsed as FeeState).lastBlockadeAt !== "number"
  ) {
    return undefined;
  }
  return { priorityFeeWei: (parsed as FeeState).priorityFeeWei, lastBlockadeAt: (parsed as FeeState).lastBlockadeAt };
};

/**
 * `maxFeePerGas` for a chosen priority fee: twice the base fee of the latest block plus the tip. The transaction
 * pays the actual base fee plus the tip; the doubling is room for a rising base fee until inclusion.
 * Both fees are passed explicitly, otherwise viem estimates both itself and the chosen tip disappears.
 */
export const maxFeePerGas = (baseFeePerGas: bigint, priorityFee: bigint): bigint => baseFeePerGas * 2n + priorityFee;

/** Actual tip of an included transaction: min(maxPriorityFeePerGas, maxFeePerGas − base fee), or gasPrice − base fee. */
export const effectiveTip = (
  tx: { maxPriorityFeePerGas?: bigint; maxFeePerGas?: bigint; gasPrice?: bigint },
  baseFeePerGas: bigint,
): bigint => {
  if (tx.maxPriorityFeePerGas !== undefined && tx.maxFeePerGas !== undefined) {
    const headroom = tx.maxFeePerGas - baseFeePerGas;
    return tx.maxPriorityFeePerGas < headroom ? tx.maxPriorityFeePerGas : headroom;
  }
  const price = tx.gasPrice ?? baseFeePerGas;
  return price > baseFeePerGas ? price - baseFeePerGas : 0n;
};

/**
 * Highest tip of the transactions that touched a pool before our own transaction in the block (a log of one of
 * both pools, with a lower `transactionIndex`). `undefined` if there is none.
 */
export const blockerTip = (
  poolTxs: readonly { transactionIndex: number; tip: bigint }[],
  ownIndex: number,
): bigint | undefined =>
  poolTxs
    .filter((tx) => tx.transactionIndex < ownIndex)
    .reduce<bigint | undefined>((max, tx) => (max === undefined || tx.tip > max ? tx.tip : max), undefined);

/** Selector of `execute(address,address)` on the Rebalancer. */
export const EXECUTE_SELECTOR = "0xd80aea15" as const;

/**
 * Final review F-1: is this transaction a direct `execute` on the Rebalancer? Such a transaction swaps through both
 * pools and so leaves Swap logs, but it is another keeper serving an owner, not an attacker touching the pool. A
 * contract that bundles a touch and an `execute` is not a direct call and does count as a toucher.
 */
export const isDirectExecute = (tx: { to?: Address | null; input?: Hex }, rebalancer: Address): boolean =>
  tx.to != null &&
  tx.to.toLowerCase() === rebalancer.toLowerCase() &&
  tx.input !== undefined &&
  tx.input.slice(0, 10).toLowerCase() === EXECUTE_SELECTOR;

/**
 * Transactions before our own transaction that touched a pool (a pool log with a lower `transactionIndex`), without
 * direct `execute`s on the Rebalancer (`isDirectExecute`). Only those count for a blockade and for `blockerTip`.
 */
export const blockingTransactions = <T extends { transactionIndex: number; to?: Address | null; input?: Hex }>(
  poolTxs: readonly T[],
  ownIndex: number,
  rebalancer: Address,
): T[] => poolTxs.filter((tx) => tx.transactionIndex < ownIndex && !isDirectExecute(tx, rebalancer));

/**
 * Final review F-1: is there an `Executed` log for `owner` before our own transaction (`ownIndex`)? Then another
 * keeper already served that owner in this block.
 */
export const servedBefore = (
  executedLogs: readonly { owner: Address; transactionIndex: number }[],
  owner: Address,
  ownIndex: number,
): boolean =>
  executedLogs.some((log) => log.transactionIndex < ownIndex && log.owner.toLowerCase() === owner.toLowerCase());

/**
 * Verification 579f763 (K-2): has `owner` already been executed by someone else after the simulation and before our
 * own transaction, also in an earlier block than ours? `servedBefore` only looked at the block of our own transaction.
 * If keeper A lands in block N and we in N+1, our transaction reverts with `NotDue` and the re-simulation at the start
 * of N+1 also sees A's run. That is not a failure of the owner but a lost race; without this rule the owner got
 * a cool-down, which doubled with every lost race up to 24 hours.
 *
 * `executedLogs`: `Executed` logs for this owner from the block after `simulatedBlock` (the block whose state the
 * simulation read; the simulation had already seen a run in that block itself) up to and including the block of our
 * own transaction. Counted: a log in an earlier block, or in the same block with a lower `transactionIndex`.
 */
export const servedSince = (
  executedLogs: readonly { owner: Address; blockNumber: bigint; transactionIndex: number }[],
  owner: Address,
  simulatedBlock: bigint,
  own: { blockNumber: bigint; transactionIndex: number },
): boolean =>
  executedLogs.some(
    (log) =>
      log.owner.toLowerCase() === owner.toLowerCase() &&
      log.blockNumber > simulatedBlock &&
      (log.blockNumber < own.blockNumber || (log.blockNumber === own.blockNumber && log.transactionIndex < own.transactionIndex)),
  );

/**
 * Final review F-1: the tip drops again. After our own transaction that was not a blockade (succeeded, or served by
 * another), and at the end of a run without a blockade and without our own transaction, the tip halves, not below the
 * base. From the cap of 3 gwei to 0.05 gwei that is 6 steps: with one run per 10 minutes without competition at most
 * one hour, and faster as soon as runs succeed. Halving (and not straight to the base) keeps an attacker who pauses
 * briefly from getting it cheap: he has to let a series of blocks pass before the tip is low again.
 */
export const decayPriorityFee = (current: bigint, policy: FeePolicy): bigint => {
  const next = current / 2n;
  if (next < policy.base) return policy.base;
  return next > policy.max ? policy.max : next;
};

export const BPS = 10_000n;

/**
 * Conversion from EURC base units (6 decimals) to wei, with two Chainlink prices of 8 decimals (EURC/USD and
 * ETH/USD): wei = eurc × 10^12 × EURC/USD ÷ ETH/USD. 0 for an invalid price.
 */
export const eurcToWei = (eurcBaseUnits: bigint, eurcUsd: bigint, ethUsd: bigint): bigint =>
  eurcUsd <= 0n || ethUsd <= 0n ? 0n : (eurcBaseUnits * 10n ** 12n * eurcUsd) / ethUsd;

/**
 * Final review F-1: cap of the tip from what a run yields. Per successful run the keeper pays tip × gas to the
 * sequencer and receives the reward (`rewardWei`, KEEPER_REWARD_EURC in wei; 0 without REWARD_TO). So the tip may
 * not be higher than
 *
 *   tip × gasEstimate ≤ rewardShareBps / 10,000 × rewardWei + budgetWei
 *
 * - `rewardShareBps` (TIP_REWARD_SHARE_BPS): which share of the reward the keeper wants to spend on tip;
 * - `budgetWei` (TIP_BUDGET_ETH, default 0.0015 ETH): what it wants to pay per run on top of the reward to break a
 *   blockade (L-3). The default keeps the 3 gwei cap reachable (3 gwei × 500,000 gas = 0.0015 ETH), on which the L-3
 *   criterion of ≥ 1,000 EURC per hour for the attacker rests. At 0 there is no increase above what the reward covers,
 *   and an attacker who touches every block only needs to bid more than that;
 * - `gasEstimate` (GAS_ESTIMATE): gas of a successful run, not the GAS_LIMIT: the tip is paid over the gas used
 *   (measured 475,267 for a buy at block 51,403,300). A reverted attempt uses less.
 *
 * Verification 579f763 (K-4): with the defaults it is mainly TIP_BUDGET_ETH that sets the cap, not the reward. The
 * reward of 0.05 EURC is ~2.4e13 wei (EURC 1.146 USD, ETH 2,403.58 USD), the budget 1.5e15 wei: together ≈ 3.05 gwei,
 * so the cap is the 3 gwei of MAX_PRIORITY_FEE_GWEI. A successful run at the cap costs ~0.0014 ETH for 0.05
 * EURC reward. This is deliberate (L-3: the keeper must be able to outbid a toucher), but to pay only what a run
 * yields, set TIP_BUDGET_ETH=0. After one blockade with a high tip from the toucher (`blockerTip`) the tip jumps
 * straight to the cap.
 *
 * This way competition between keepers can never drive the tip above what the keeper wants to pay per run, not even if
 * it would rise to the cap of MAX_PRIORITY_FEE_GWEI. The cap is never lower than the base tip: that one is still
 * needed to send.
 */
export const capFeePolicy = (
  policy: FeePolicy,
  input: { rewardWei: bigint; rewardShareBps: bigint; budgetWei: bigint; gasEstimate: bigint },
): FeePolicy => {
  if (input.gasEstimate <= 0n) return policy;
  const cap = ((input.rewardWei * input.rewardShareBps) / BPS + input.budgetWei) / input.gasEstimate;
  const max = cap < policy.max ? cap : policy.max;
  return { base: policy.base, max: max < policy.base ? policy.base : max };
};

/**
 * After a blockade the keeper only sends again after a random number of blocks, on average `sendRetryBlocks`
 * (uniform 1 to 2 × `sendRetryBlocks` − 1; simulating is allowed every block). Two reasons:
 * - a reverted attempt costs ~40k gas; on average one per ~30 blocks (≈ 1 minute) keeps the keeper's costs
 *   under attack around 1/69 of those of the attacker, who has to touch every block (L-3 measurements);
 * - random, because the reverted transaction is on-chain: with a fixed wait the attacker knows exactly in
 *   which block the next attempt comes and only needs to pay a high tip there. Now he has to do that in every block
 *   of the whole range.
 * `random` in [0, 1), for example `Math.random()`; drawn once per blockade.
 */
export const nextSendBlock = (blockadeBlock: bigint, sendRetryBlocks: number, random: number): bigint => {
  const span = 2 * sendRetryBlocks - 1;
  const offset = Math.min(Math.floor(random * span), span - 1);
  return blockadeBlock + 1n + BigInt(Math.max(offset, 0));
};

/**
 * Verification 579f763 (info a, K-5): our own transaction that reverted on-chain due to a temporary cause without a
 * blockade, e.g. a direct `execute` by another party earlier in the block (which deliberately is not a blockade, see
 * `blockingTransactions`). No wait applied to that: the keeper sent again every block, with a reverted
 * attempt of ~40k gas per block until the retry budget was spent.
 *
 * Now: the first such revert in a run gets no wait yet (that is usually chance), every following one does. From
 * `revertBlock` the keeper waits 2, 4, 8, … blocks (2^(n−1) at the n-th consecutive revert), at most `maxBlocks`
 * (SEND_RETRY_BLOCKS, default 30). The tip does not go up. Returns the earliest block for a new send, or null.
 */
export const quietRevertSendBlock = (revertBlock: bigint, consecutiveReverts: number, maxBlocks: number): bigint | null => {
  if (consecutiveReverts < 2) return null;
  return revertBlock + BigInt(Math.min(2 ** (consecutiveReverts - 1), maxBlocks));
};

// ─── Audit lead 9: register spam ───────────────────────────────────────────────────────────────────────────────

export const CBBTC_UNIT = 100_000_000n;

/** What the keeper reads of a registered owner to filter up front (one multicall per batch). */
export type OwnerFunds = {
  owner: Address;
  active: boolean;
  eurcBalance: bigint;
  eurcAllowance: bigint;
  cbbtcBalance: bigint;
  cbbtcAllowance: bigint;
};

const min = (a: bigint, b: bigint): bigint => (a < b ? a : b);

/**
 * Largest run the contract can ever do for this owner, per direction, in EURC base units. `_plan` caps
 * the input at min(balance, allowance) of the input token: EURC when buying, cbBTC at the feed price when selling
 * (`quote()`, rounded down like `Math.mulDiv`), and the run must be at least MIN_TRADE_FLOOR.
 */
export const maxRunValues = (funds: OwnerFunds, priceEurcPerBtc: bigint): { buy: bigint; sell: bigint } => ({
  buy: min(funds.eurcBalance, funds.eurcAllowance),
  sell: (min(funds.cbbtcBalance, funds.cbbtcAllowance) * priceEurcPerBtc) / CBBTC_UNIT,
});

/**
 * Lead 9: filter the register off-chain before `isDue`. An owner remains if it is active and in at least one
 * direction can reach a run of `minRun` (min(balance, allowance) of the input token). That is a necessary
 * condition of the contract (`value >= min(run, minTradeEurc)` with run and minTradeEurc both ≥ MIN_TRADE_FLOOR),
 * so with `minRun` = max(MIN_TRADE_FLOOR, MIN_RUN_EURC) no owner drops out that the keeper would otherwise execute. An
 * empty or allowance-less spam registration does drop out: anyone who wants to hold up the keeper must keep at least
 * that value with allowance per address.
 */
export const isCandidate = (funds: OwnerFunds, priceEurcPerBtc: bigint, minRun: bigint): boolean => {
  if (!funds.active) {
    return false;
  }
  const { buy, sell } = maxRunValues(funds, priceEurcPerBtc);
  return buy >= minRun || sell >= minRun;
};

export const filterCandidates = (rows: readonly OwnerFunds[], priceEurcPerBtc: bigint, minRun: bigint): Address[] =>
  rows.filter((row) => isCandidate(row, priceEurcPerBtc, minRun)).map((row) => row.owner);

/** Lower bound for the filter: the larger of MIN_TRADE_FLOOR (contract) and MIN_RUN_EURC (keeper), in base units. */
export const minRunBaseUnits = (minTradeFloor: bigint, minRunEurc: number): bigint => {
  const keeper = BigInt(Math.ceil(minRunEurc * Number(EURC_UNIT)));
  return keeper > minTradeFloor ? keeper : minTradeFloor;
};

// ─── Final review F-2: register spam does not stall the keeper ──────────────────────────────────────────────────

/** One `owners(offset, limit)` read. */
export type ScanSegment = { offset: bigint; limit: bigint };

/**
 * Final review F-2: the order in which a run reads the register. Not always from 0: from `start` (the stored
 * offset, modulo `count`) to the end, and then from 0 to `start`, in batches of at most `page`. Together exactly one
 * pass over the whole register. A run that runs out of search time stops somewhere in this list; the next starts there.
 * So spam in front of a real owner no longer keeps that owner out of view every run: after at most ⌈count / owners
 * per run⌉ runs every position has had its turn once.
 */
export const scanSegments = (start: bigint, count: bigint, page: bigint): ScanSegment[] => {
  if (count <= 0n || page <= 0n) return [];
  const from = ((start % count) + count) % count;
  const out: ScanSegment[] = [];
  const push = (lo: bigint, hi: bigint) => {
    for (let offset = lo; offset < hi; offset += page) {
      out.push({ offset, limit: hi - offset < page ? hi - offset : page });
    }
  };
  push(from, count);
  push(0n, from);
  return out;
};

/** Stored start position for the next run (`SCAN_STATE_FILE`). */
export type ScanState = { nextOffset: string };

/** Offset from the file; 0 for a missing or invalid file. */
export const parseScanState = (json: string | undefined): bigint => {
  if (json === undefined) return 0n;
  try {
    const parsed: unknown = JSON.parse(json);
    const value = (parsed as ScanState | null)?.nextOffset;
    return typeof value === "string" && /^\d+$/.test(value) ? BigInt(value) : 0n;
  } catch {
    return 0n;
  }
};

/**
 * Where the next run starts:
 * - if the run stopped with candidates it found but did not read anymore (retry budget spent), at the first
 *   of those in the register (`firstUnprocessed`), so that they do not wait a whole round;
 * - otherwise where the search stopped (`scannedTo`); if the run read the whole register, that is the start again.
 */
export const nextScanOffset = (scannedTo: bigint, firstUnprocessed: bigint | null, count: bigint): bigint => {
  if (count <= 0n) return 0n;
  const next = firstUnprocessed ?? scannedTo;
  return ((next % count) + count) % count;
};

/**
 * Register position of the first candidate that has not been read yet (addresses from OWNERS_FILE have no position), or
 * null. For `nextScanOffset`, when the retry budget runs out and on an error (verification 579f763, info c).
 */
export const firstRegisterIndex = (pending: readonly { index: bigint | null }[]): bigint | null =>
  pending.find((c) => c.index !== null)?.index ?? null;

/**
 * Final review F-2: `OWNERS_FILE`, addresses that are served first every run (as the app keeper serves its own users
 * first), before the register. Separated by whitespace or commas; `#` starts a comment until the end of the line.
 * An invalid address is an error (better not to start than silently skip one of our own users); duplicate addresses
 * count once, regardless of case.
 */
export const parseOwnersFile = (text: string): Address[] => {
  const seen = new Set<string>();
  const out: Address[] = [];
  for (const line of text.split(/\r?\n/)) {
    for (const token of line.replace(/#.*$/, "").split(/[\s,]+/)) {
      if (token === "") continue;
      if (!isAddress(token, { strict: false })) throw new Error(`OWNERS_FILE: not a valid address: ${token}`);
      // Verification 579f763 (K-1): viem encodes addresses strictly; a bad checksum gave an encode error on each read.
      if (!isAddress(token)) throw new Error(`OWNERS_FILE: invalid checksum (EIP-55): ${token}`);
      if (seen.has(token.toLowerCase())) continue;
      seen.add(token.toLowerCase());
      out.push(token as Address);
    }
  }
  return out;
};

export const chunks = <T>(items: readonly T[], size: number): T[][] => {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
};

/**
 * Earliest block for the next attempt for an owner:
 * - after the previous attempt for that owner (`retryAfterBlock`) and after our last transaction (`lastRunBlock`). A
 *   run that changes a pool's tick touches that pool for the rest of the block; so read and simulate the next
 *   owner (and the next page) only in a later block;
 * - after a blockade not before `sendFrom` (`nextSendBlock`); `throttled` says that this bound decides.
 * `target` null: do not wait.
 */
export const nextAttemptBlock = (
  retryAfterBlock: bigint | null,
  lastRunBlock: bigint | null,
  sendFrom: bigint | null,
): { target: bigint | null; throttled: boolean } => {
  const after = retryAfterBlock !== null && (lastRunBlock === null || retryAfterBlock > lastRunBlock) ? retryAfterBlock : lastRunBlock;
  const target = after === null ? null : after + 1n;
  if (sendFrom !== null && (target === null || sendFrom > target)) {
    return { target: sendFrom, throttled: true };
  }
  return { target, throttled: false };
};

export const formatEurc = (baseUnits: bigint): string => {
  const whole = baseUnits / EURC_UNIT;
  const fraction = (baseUnits % EURC_UNIT).toString().padStart(6, "0").replace(/0+$/, "");
  return fraction === "" ? whole.toString() : `${whole}.${fraction}`;
};

/**
 * Cool-down per owner after a failed execute. The contract does not remember failures (lastExecutedAt
 * is only set on success), so an owner that reverts structurally stays due; without memory
 * every run would cost gas again. The wait doubles per consecutive failure up to `max`.
 * Temporary failures do not count (see `failureAction`).
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

/** Drop expired cool-downs so that the file does not keep growing. */
export const pruneExpired = (state: CooldownState, nowSeconds: number): CooldownState =>
  Object.fromEntries(Object.entries(state).filter(([, entry]) => nowSeconds < entry.until));

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

// ─── Final review I-5: lock robust against a reused PID ────────────────────────────────────────────────────────

/** Content of LOCK_FILE: pid and start time (unix seconds) of the run that holds the lock. */
export type LockInfo = { pid: number; startedAt: number };

export const formatLock = (lock: LockInfo): string => `${JSON.stringify(lock)}\n`;

/**
 * Lock from the file. The old format (only a pid) and unreadable content give `startedAt` = `fallbackStartedAt`
 * (the file's mtime), so that such a lock also has an age.
 */
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
    // old format or garbage
  }
  const pid = Number(text.trim());
  return { pid: Number.isInteger(pid) ? pid : 0, startedAt: fallbackStartedAt };
};

/**
 * Final review I-5: may an existing lock be removed? Checking only a pid is not enough: if a lock remains after a crash
 * and the OS later gives that pid to another process, every run stops silently. Therefore:
 * - a lock older than `maxAgeSeconds` is always stale, whatever the pid does. That is safe because a run stops itself
 *   before that age (`lockWatchdogSeconds`): a lock of that age can no longer belong to a live run;
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

// ─── Final review I-6: a transaction that gets stuck ───────────────────────────────────────────────────────────

export type TxFees = { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint };

/**
 * Final review I-6: fees for a replacement transaction with the same nonce, or null if that is not possible within the
 * policy (then the run stops clearly). A node only accepts a replacement if tip and maxFeePerGas are at least 10%
 * higher (geth `txpool.pricebump`, default 10; op-geth uses the same txpool); the script takes 12.5% (+1 wei) margin.
 * `maxFeePerGas` is also at least 2 × the current base fee + tip, because a transaction usually gets stuck when the
 * base fee rose above the old `maxFeePerGas`. No replacement above the tip cap (`maxTip`).
 */
export const replacementFees = (previous: TxFees, baseFeePerGas: bigint, maxTip: bigint): TxFees | null => {
  const bump = (v: bigint) => (v * 9n + 7n) / 8n + 1n;
  const tip = bump(previous.maxPriorityFeePerGas);
  if (tip > maxTip) return null;
  const floor = baseFeePerGas * 2n + tip;
  const fee = bump(previous.maxFeePerGas);
  return { maxPriorityFeePerGas: tip, maxFeePerGas: fee > floor ? fee : floor };
};

/**
 * Verification 579f763 (K-6): is one of our own transactions still pending? Yes if the node knows more transactions
 * with `pending` than have been mined (`latest`). That happens after a run that stopped because a transaction could
 * not be replaced, or after a node error during replacement. A new transaction would then get stuck behind that nonce
 * (or with nonce+1 revert later with NotDue), so the keeper sends nothing and tries again in a later block.
 */
export const ownTransactionPending = (latestNonce: number, pendingNonce: number): boolean => pendingNonce > latestNonce;

/** Time after the last receipt for re-simulation, logs and saving. */
export const SEND_AFTER_SECONDS = 30;

/**
 * Verification 579f763 (K-6): how long a transaction takes in the worst case, if no block fails: every
 * send (the first plus TX_REPLACEMENTS replacements) waits TX_WAIT_BLOCKS blocks of 2 s plus at most
 * BLOCK_WAIT_SECONDS without a new block, and then `SEND_AFTER_SECONDS`. With the defaults 4 × (30 + 30) + 30 =
 * 270 s.
 */
export const sendWorstCaseSeconds = (txWaitBlocks: number, txReplacements: number, blockWaitSeconds: number): number =>
  (txReplacements + 1) * (txWaitBlocks * Number(BASE_BLOCK_SECONDS) + blockWaitSeconds) + SEND_AFTER_SECONDS;

/**
 * Verification 579f763 (K-6): may the keeper still send a transaction? The watchdog (`lockWatchdogSeconds`) stops the run
 * hard; if that happens in the middle of a transaction, it is left without replacement and without a verdict. An owner
 * whose turn comes just before the end of the retry budget could otherwise run until well after that budget. Only
 * send if the whole transaction fits before the watchdog; else skip without a cool-down (the next run picks it up).
 */
export const hasTimeToSend = (nowSeconds: number, watchdogAtSeconds: number, neededSeconds: number): boolean =>
  nowSeconds + neededSeconds <= watchdogAtSeconds;

/** Must the transaction be replaced? Yes if it has not been mined `waitBlocks` blocks after the send block. */
export const isStuck = (sentAtBlock: bigint, latestBlock: bigint, waitBlocks: number): boolean =>
  latestBlock >= sentAtBlock + BigInt(waitBlocks);


// ─── Verification 579f763 (info b): RPC URL not in the log ───────────────────────────────────────────────────────

/**
 * The RPC URL without whatever may contain an API key: only scheme and host. Path, query, fragment and credentials become
 * `/***` (Alchemy and Infura put the key in the path, other providers in the query). An invalid URL becomes `***`.
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
 * strips username and password from it (`getUrl`, viem 2.56.3 errors/utils.ts), not a key in path or query.
 * - The whole URL, as given, as `URL` writes it and without credentials, becomes `maskRpcUrl(url)`;
 * - then every separate part that may be a key (path plus query, path, query, path segments, query parameter values,
 *   username and password, also URL-decoded) of at least 8 characters becomes `***`. Shorter parts ("v2", "/")
 *   stay: they are not a key and would mangle ordinary text.
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

// ─── Final review I-8: REWARD_TO ───────────────────────────────────────────────────────────────────────────────

/**
 * Final review I-8: REWARD_TO must be a valid address and not the Rebalancer itself (the contract would then replace
 * the reward with address(0), so the whole fee to the treasury, and that is almost certainly a configuration error).
 * address(0) is allowed: deliberately no reward. Returns the error message, or null if it is fine.
 *
 * Verification 579f763 (K-1): strict, like viem when encoding. An address with uppercase letters needs a valid EIP-55
 * checksum; all lowercase is also allowed. Do not normalize silently: a wrong checksum usually points to a
 * typo, and then the reward would go to a wrong address. Before, such an address passed the check and made
 * every simulation fail with an encode error, which counted as a node error (I-8 again).
 */
export const rewardToError = (value: string, rebalancer: string): string | null => {
  if (!isAddress(value, { strict: false })) return `REWARD_TO is not a valid address: ${value}`;
  if (!isAddress(value)) {
    return `REWARD_TO has an invalid checksum (EIP-55): ${value}; check the address, or write it in lowercase`;
  }
  if (value.toLowerCase() === rebalancer.toLowerCase()) return "REWARD_TO must not be the Rebalancer contract itself";
  return null;
};
