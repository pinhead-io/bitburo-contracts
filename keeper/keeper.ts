/**
 * Bitburo keeper script. Anyone may run this; Bitburo is not needed.
 *
 * Reads the register of the Rebalancer contract (owners), filters it off-chain on active, balance and allowance, asks
 * for the remaining candidates isDue(owner) in batches of PAGE_SIZE (one Multicall3 per batch), skips runs below
 * MIN_RUN_EURC (the fee does not cover the gas then), simulates execute(owner, rewardTo)
 * first with eth_call and only then calls it for real. An owner whose simulation or transaction fails
 * gets a cool-down (doubles per failure) in a small JSON file, so that an owner that structurally
 * reverts does not cost gas again every run. The reward (at most 0.05 EURC and at most half the fee per run) goes
 * to REWARD_TO, by default our own address. The script decides nothing about amounts or direction: the contract decides
 * whether, what and how much.
 *
 * Block check and block window (audit M-1, review PR #18): a run is not allowed if a pool already wrote an
 * oracle observation in the same block, and a pool may deviate only 6 bp from its starting price within one block.
 * - A revert with PoolTouchedThisBlock or BlockMoveExceeded is temporary: the script retries that owner in every new
 *   block, as long as the run's retry budget lasts (RETRY_SECONDS), and gives no cool-down. The same applies
 *   to a transaction that reverted on-chain while a new simulation on that block passes.
 * - After our own transaction the script waits for a new block before it reads or simulates the next owner or
 *   batch.
 *
 * Holding up runs (audit L-3): whoever touches a pool in every block (a burn of 1 liquidity costs ~92,630 gas) holds up
 * all runs in that block. Countermeasures:
 * - Read and simulate as if it were the next block: isDue and the simulation of execute go as eth_call
 *   with block overrides (number + 1, timestamp + 2 s) on the state of the latest block. A touch in the latest
 *   block is then no longer a reason to send nothing. Once per run the script checks with a small probe
 *   whether the node applies the overrides; if not, it falls back to the latest block (and reads every batch
 *   at least twice, in consecutive blocks, at most BLOCK_RETRIES + 1 times) and logs that.
 * - Keep trying for the whole retry budget, not a few blocks: otherwise an attacker only needs to cover a predictable
 *   window.
 * - Send with an explicit priority fee (PRIORITY_FEE_GWEI, default 0.05 gwei), so that the transaction is in the
 *   Flashblock ahead of a toucher with a lower tip. If a transaction reverts on-chain due to a temporary cause
 *   (a blockade), the script only sends again after a random number of blocks (on average
 *   SEND_RETRY_BLOCKS, so that an attacker cannot predict the moment), with at least double
 *   the previous tip and at least 10% above the highest tip of whoever touched the pool earlier in that block, up to
 *   MAX_PRIORITY_FEE_GWEI (default 3 gwei) and the cap `capFeePolicy`: tip × GAS_ESTIMATE ≤ TIP_REWARD_SHARE_BPS
 *   of the reward + TIP_BUDGET_ETH. With the defaults the budget sets that cap, not the reward (0.025
 *   EURC, half of KEEPER_REWARD_EURC, is ~0.8% of 0.0015 ETH): a run at 3 gwei costs ~0.0014 ETH. To bid only
 *   what a run yields, set TIP_BUDGET_ETH=0 (verification 579f763, K-4). The raised tip is stored in
 *   FEE_STATE_FILE and applies as long as the last blockade was less than FEE_HOLD_SECONDS (default 3600) ago. A
 *   revert only counts as a blockade if a re-simulation at the start of the block passes (or hits the block window)
 *   and a transaction before our own touched a pool (Swap, Mint or Burn) that was not itself a direct `execute`
 *   on the Rebalancer.
 *   A temporary revert without a blockade (e.g. due to a direct `execute` by someone else) does not raise the tip;
 *   from the second in a run the script waits 2, 4, … up to SEND_RETRY_BLOCKS blocks (verification 579f763, info a).
 * - Competing keepers (final review F-1): if an `Executed` for the same owner precedes our own reverted transaction
 *   (in that block, or in a block between the simulation and our own transaction: verification 579f763, K-2), that
 *   owner has been served: no blockade, no cool-down, no higher tip. After our own transaction without a
 *   blockade, and at the end of a run without a blockade and without our own transaction, the tip halves to the base.
 * - One run at a time (LOCK_FILE), and after the retry budget the run reads no new candidates.
 * - No new transaction while one of our own is still pending (nonce `pending` > `latest`), and only a transaction
 *   that in the worst case (all replacements) is done before the watchdog (verification 579f763, K-6).
 *
 * Registration spam (audit lead 9): anyone can register, also without a balance, and the register never shrinks. The
 * script therefore reads, per 500 owners, `params(owner).active` and balance and allowance of EURC and cbBTC in one
 * Multicall3 per 100 owners, and keeps only owners that can reach a run of max(MIN_TRADE_FLOOR,
 * MIN_RUN_EURC) in at least one direction: min(balance, allowance) of EURC, or of cbBTC at quote(). That is a necessary
 * condition of the contract, so no owner drops out that would otherwise be executed. Anyone who wants to hold up the
 * script must keep that amount with allowance per address. The filter runs once per run; anyone who deposits during
 * the run gets their turn in the next run.
 *
 * Final review F-2: with enough empty registrations, that reading alone took the whole retry budget, each run from 0.
 * - The search has its own time limit, SEARCH_SECONDS (default 180) after the start, within the retry budget: then
 *   there is time left for isDue and execute.
 * - The register is no longer always read from 0: the next run starts where this one stopped (SCAN_STATE_FILE),
 *   and continues from 0 after the end. If a run stops with candidates found but not read, the next one starts
 *   at the first of those.
 * - A node error on a batch (owners, balance and allowance, isDue) only skips that batch, with a log.
 * - OWNERS_FILE (optional): addresses that are served first every run, before the register.
 *
 * Large corrections go in parts that are allowed 10 minutes apart. So run this script every 10 minutes.
 *
 * Usage:
 *   RPC_URL=https://mainnet.base.org REBALANCER=0x… KEEPER_PRIVATE_KEY=0x… bun run keeper.ts
 * Optional: REWARD_TO=0x…  PAGE_SIZE=20  DRY_RUN=1  MIN_RUN_EURC=20  BLOCK_RETRIES=3  BLOCK_WAIT_SECONDS=30
 *            RETRY_SECONDS=540  SEND_RETRY_BLOCKS=30  PRIORITY_FEE_GWEI=0.05  MAX_PRIORITY_FEE_GWEI=3
 *            GAS_LIMIT=1000000  FEE_STATE_FILE=./keeper-fee.json  FEE_HOLD_SECONDS=3600  LOCK_FILE=./keeper.lock
 *            LOCK_MAX_SECONDS=900  TX_WAIT_BLOCKS=15  TX_REPLACEMENTS=3
 *            GAS_ESTIMATE=500000  TIP_REWARD_SHARE_BPS=10000  TIP_BUDGET_ETH=0.0015
 *            FEED_ETH_USD=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
 *            SEARCH_SECONDS=180  SCAN_STATE_FILE=./keeper-scan.json  OWNERS_FILE=./owners.txt
 *            COOLDOWN_FILE=./keeper-cooldowns.json  COOLDOWN_SECONDS=3600  COOLDOWN_MAX_SECONDS=86400
 */
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  http,
  isAddress,
  parseAbi,
  parseEther,
  type Address,
  type Hex,
  type TransactionReceipt,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import { acquireLock } from "./lock";
import {
  type BlockOverrides,
  type CooldownState,
  type FeeState,
  type Resimulation,
  type OwnerFunds,
  OVERRIDE_PROBE_CODE,
  blockerTip,
  blockingTransactions,
  capFeePolicy,
  chunks,
  clearFailure,
  cooldownUntil,
  decayPriorityFee,
  effectiveTip,
  eurcToWei,
  failureAction,
  filterCandidates,
  firstRegisterIndex,
  formatEurc,
  formatGwei,
  isBlockWindowRevert,
  isCoolingDown,
  isStuck,
  isTemporaryFailure,
  hasTimeToSend,
  ownTransactionPending,
  sendWorstCaseSeconds,
  lockWatchdogSeconds,
  maxFeePerGas,
  minRunBaseUnits,
  newOwners,
  nextAttemptBlock,
  nextScanOffset,
  nextBlockOverrides,
  nextSendBlock,
  quietRevertSendBlock,
  onchainRevertVerdict,
  parseFeeState,
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
  servedSince,
  shouldReadPageAgain,
  startPriorityFee,
} from "./selection";

const abi = parseAbi([
  "function ownerCount() view returns (uint256)",
  "function isDue(address owner) view returns (bool due, int256 eurcDelta)",
  "function execute(address owner, address rewardTo)",
  "function owners(uint256 offset, uint256 limit) view returns (address[])",
  "function params(address owner) view returns (bool active, uint16 targetBps, uint16 bandBps, uint16 maxCorrectionBps, uint64 minTradeEurc, uint32 interval, uint16 maxSlippageBps)",
  "function quote() view returns (uint256)",
  "function EURC() view returns (address)",
  "function CBBTC() view returns (address)",
  "function MIN_TRADE_FLOOR() view returns (uint64)",
  "function balanceOf(address account) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function POOL_EURC_USDC() view returns (address)",
  "function POOL_USDC_CBBTC() view returns (address)",
  "function KEEPER_REWARD_EURC() view returns (uint256)",
  "function FEED_EURC_USD() view returns (address)",
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
  // Custom errors, so that viem can decode the revert reason.
  "error BlockMoveExceeded(address pool)",
  "error PoolTouchedThisBlock(address pool)",
  "error ContractRetired()",
  "error Inactive()",
  "error InvalidFeedAnswer(address feed)",
  "error NoOutput()",
  "error NotDue()",
  "error NothingToDo()",
  "error SequencerDown()",
  "error SpotDeviatesFromOracle(uint256 spot, uint256 oracle)",
  "error StaleFeed(address feed)",
]);

/** Pool events that can write an observation or move the price (Uniswap v3). Collect and Flash do not count. */
const poolEvents = parseAbi([
  "event Swap(address indexed sender, address indexed recipient, int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick)",
  "event Mint(address sender, address indexed owner, int24 indexed tickLower, int24 indexed tickUpper, uint128 amount, uint256 amount0, uint256 amount1)",
  "event Burn(address indexed owner, int24 indexed tickLower, int24 indexed tickUpper, uint128 amount, uint256 amount0, uint256 amount1)",
]);

/** `Executed` of the Rebalancer: which owner has already been served in which block (final review F-1). */
const executedEvent = parseAbi([
  "event Executed(address indexed owner, bool isBuy, uint256 amountIn, uint256 fee, uint256 reward, address rewardTo, uint256 amountOut, uint256 priceEurcPerBtc, uint256 totalValueEurc, uint256 fractionBps)",
]);

const env = (name: string, fallback?: string): string => {
  const value = process.env[name] ?? fallback;
  if (value === undefined) throw new Error(`${name} is missing`);
  return value;
};

const rpcUrl = env("RPC_URL", "https://mainnet.base.org");
const rebalancer = env("REBALANCER") as Address;
const pageSize = BigInt(env("PAGE_SIZE", "20"));
const dryRun = process.env.DRY_RUN === "1";
const minRunEurc = Number(env("MIN_RUN_EURC", "20"));
const blockRetries = Number(env("BLOCK_RETRIES", "3"));
const blockWaitSeconds = Number(env("BLOCK_WAIT_SECONDS", "30"));
const retrySeconds = Number(env("RETRY_SECONDS", "540"));
const searchSeconds = Number(env("SEARCH_SECONDS", "180"));
const scanStateFile = env("SCAN_STATE_FILE", "./keeper-scan.json");
const ownersFile = process.env.OWNERS_FILE;
const sendRetryBlocks = Number(env("SEND_RETRY_BLOCKS", "30"));
const gasLimit = BigInt(env("GAS_LIMIT", "1000000"));
const txWaitBlocks = Number(env("TX_WAIT_BLOCKS", "15"));
const txReplacements = Number(env("TX_REPLACEMENTS", "3"));
const configuredFeePolicy = {
  base: parseGwei(env("PRIORITY_FEE_GWEI", "0.05")),
  max: parseGwei(env("MAX_PRIORITY_FEE_GWEI", "3")),
};
const gasEstimate = BigInt(env("GAS_ESTIMATE", "500000"));
const tipRewardShareBps = BigInt(env("TIP_REWARD_SHARE_BPS", "10000"));
const tipBudgetWei = parseEther(env("TIP_BUDGET_ETH", "0.0015"));
const feedEthUsd = env("FEED_ETH_USD", "0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70") as Address;
const cooldownFile = env("COOLDOWN_FILE", "./keeper-cooldowns.json");
const feeStateFile = env("FEE_STATE_FILE", "./keeper-fee.json");
const feeHoldSeconds = Number(env("FEE_HOLD_SECONDS", "3600"));
const lockFile = env("LOCK_FILE", "./keeper.lock");
const lockMaxSeconds = Number(env("LOCK_MAX_SECONDS", "900"));
const cooldownPolicy = {
  baseSeconds: Number(env("COOLDOWN_SECONDS", "3600")),
  maxSeconds: Number(env("COOLDOWN_MAX_SECONDS", "86400")),
};
if (!isAddress(rebalancer)) throw new Error("REBALANCER is not a valid address");
if (!Number.isFinite(minRunEurc) || minRunEurc < 0) throw new Error("MIN_RUN_EURC must be a number >= 0");
if (!Number.isInteger(blockRetries) || blockRetries < 0) throw new Error("BLOCK_RETRIES must be an integer >= 0");
if (!Number.isFinite(retrySeconds) || retrySeconds < 0) throw new Error("RETRY_SECONDS must be a number >= 0");
if (!Number.isFinite(searchSeconds) || searchSeconds < 0 || searchSeconds > retrySeconds) {
  throw new Error("SEARCH_SECONDS must be a number between 0 and RETRY_SECONDS");
}
/** Final review F-2: addresses that are served first every run. An invalid file stops the run before anything happens. */
const priorityOwners: Address[] = ownersFile === undefined || ownersFile === "" ? [] : parseOwnersFile(readFileSync(ownersFile, "utf8"));
if (!Number.isInteger(sendRetryBlocks) || sendRetryBlocks < 1) throw new Error("SEND_RETRY_BLOCKS must be an integer >= 1");
if (!Number.isInteger(txWaitBlocks) || txWaitBlocks < 1) throw new Error("TX_WAIT_BLOCKS must be an integer >= 1");
if (!Number.isInteger(txReplacements) || txReplacements < 0) throw new Error("TX_REPLACEMENTS must be an integer >= 0");
if (configuredFeePolicy.base > configuredFeePolicy.max) throw new Error("PRIORITY_FEE_GWEI must not be above MAX_PRIORITY_FEE_GWEI");
if (gasEstimate <= 0n) throw new Error("GAS_ESTIMATE must be an integer > 0");
if (tipRewardShareBps < 0n) throw new Error("TIP_REWARD_SHARE_BPS must be >= 0");
if (tipBudgetWei < 0n) throw new Error("TIP_BUDGET_ETH must be >= 0");
if (!isAddress(feedEthUsd)) throw new Error("FEED_ETH_USD is not a valid address");
if (!Number.isFinite(feeHoldSeconds) || feeHoldSeconds < 0) throw new Error("FEE_HOLD_SECONDS must be a number >= 0");
if (!Number.isFinite(lockMaxSeconds) || lockMaxSeconds < retrySeconds + 60) {
  throw new Error("LOCK_MAX_SECONDS must be at least RETRY_SECONDS + 60");
}

/**
 * One run at a time: two runs would fight over the same nonce and the same cool-down file. The lock file contains
 * pid and start time (final review I-5). A lock is stale if the pid no longer exists, or if it is older than
 * LOCK_MAX_SECONDS (default 900), even if the pid now belongs to another process. The latter is safe because this
 * run stops itself 15 s before that age (watchdog below).
 */
const lockStartedAt = Math.floor(Date.now() / 1000);
const pidAlive = (pid: number): boolean => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM: the process exists, but belongs to another user.
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
};
// Verification 579f763 (K-3): a stale lock is cleaned up atomically (`acquireLock` in lock.ts), so that two runs that
// start at the same time do not remove each other's new lock.
if (
  !acquireLock(lockFile, {
    pid: process.pid,
    nowSeconds: lockStartedAt,
    maxAgeSeconds: lockMaxSeconds,
    isAlive: pidAlive,
    onStaleRemoved: (lock) => console.warn(`stale lock removed (pid ${lock.pid}, ${lockStartedAt - lock.startedAt} s old)`),
  })
) {
  console.warn(`Another keeper run is still running (${lockFile}); this run stops.`);
  process.exit(0);
}
process.on("exit", () => {
  try {
    if (parseLock(readFileSync(lockFile, "utf8"), 0).pid === process.pid) unlinkSync(lockFile);
  } catch {
    // already gone
  }
});
// Final review I-5: a run that hangs stops itself before its lock expires.
setTimeout(() => {
  console.error(`run exceeds ${lockWatchdogSeconds(lockMaxSeconds)} s (LOCK_MAX_SECONDS ${lockMaxSeconds}); stopped`);
  process.exit(1);
}, lockWatchdogSeconds(lockMaxSeconds) * 1000).unref();

const publicClient = createPublicClient({ chain: base, transport: http(rpcUrl) });
const account = dryRun ? undefined : privateKeyToAccount(env("KEEPER_PRIVATE_KEY") as Hex);
const rewardTo = (process.env.REWARD_TO ?? account?.address ?? "0x0000000000000000000000000000000000000000") as Address;
// Final review I-8: an invalid REWARD_TO made every simulation fail with an encode error, which counted as node error;
// the keeper then kept trying until the budget was spent, without a clear message. Now the run stops right away.
{
  const problem = rewardToError(rewardTo, rebalancer);
  if (problem !== null) throw new Error(problem);
}
const walletClient = account ? createWalletClient({ account, chain: base, transport: http(rpcUrl) }) : undefined;

const nowSec = () => Math.floor(Date.now() / 1000);
const startSeconds = nowSec();
const deadline = retryDeadline(startSeconds, retrySeconds);
/** Final review F-2: own time limit for searching the register, separate from the retry budget. */
const searchDeadline = startSeconds + searchSeconds;

/** Does the node read the next block (block overrides)? Checked once per run with the probe. */
let readsNextBlock = false;

/**
 * What a read runs on. Always pinned to the block that was read (`blockNumber`): otherwise the node may already be one
 * block further, and it computes with the overrides of the previous block on the state of the new one (then a touch in
 * that new block counts again).
 */
type At = { blockNumber?: bigint; blockOverrides?: BlockOverrides };
const atParams = (at: At) => ({
  ...(at.blockNumber === undefined ? {} : { blockNumber: at.blockNumber }),
  ...(at.blockOverrides === undefined ? {} : { blockOverrides: at.blockOverrides }),
});

/** Reading at `latest`: pinned to that block, with the overrides of the next block if the node applies them. */
const atLatest = (latest: { number: bigint; timestamp: bigint }): At => ({
  blockNumber: latest.number,
  blockOverrides: overridesFor(latest),
});

/** Overrides for the block after `latest`, or undefined when falling back to the latest block. */
const overridesFor = (latest: { number: bigint; timestamp: bigint }): BlockOverrides | undefined =>
  readsNextBlock ? nextBlockOverrides(latest) : undefined;

const read = <T>(
  functionName:
    | "KEEPER_REWARD_EURC"
    | "FEED_EURC_USD"
    | "latestRoundData"
    | "ownerCount"
    | "owners"
    | "isDue"
    | "quote"
    | "EURC"
    | "CBBTC"
    | "MIN_TRADE_FLOOR"
    | "POOL_EURC_USDC"
    | "POOL_USDC_CBBTC",
  args: readonly unknown[] = [],
  at: At = {},
  address: Address = rebalancer,
) =>
  publicClient.readContract({
    address,
    abi,
    functionName,
    args,
    ...atParams(at),
    // biome-ignore lint/suspicious/noExplicitAny: viem's ABI generics are too strict for a shared helper
  } as any) as Promise<T>;

const simulateExecute = (owner: Address, at: At = {}) =>
  publicClient.simulateContract({
    address: rebalancer,
    abi,
    functionName: "execute",
    args: [owner, rewardTo],
    account,
    ...atParams(at),
  });

const revertOf = (error: unknown): ContractFunctionRevertedError | undefined => {
  if (!(error instanceof BaseError)) return undefined;
  const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
  return reverted instanceof ContractFunctionRevertedError ? reverted : undefined;
};

/** Name of the contract error (for example "BlockMoveExceeded"), if viem could decode it. */
const errorNameOf = (error: unknown): string | undefined => revertOf(error)?.data?.errorName;

/** First line of a viem error, with the contract error if there is one (for example NotDue()). */
const describeError = (error: unknown): string => {
  const reverted = revertOf(error);
  if (reverted?.data?.errorName) {
    return `${reverted.data.errorName}(${(reverted.data.args ?? []).join(", ")})`;
  }
  // Verification 579f763 (info b): never the RPC URL (with a possible API key) in the log.
  if (error instanceof BaseError) return redactRpcUrl(error.shortMessage, rpcUrl);
  return redactRpcUrl(String((error as Error)?.message ?? error).split("\n")[0], rpcUrl);
};

/**
 * Wait until the latest block is at least `target` (Base: ~2 s per block). Returns false if the chain
 * produces no new block for BLOCK_WAIT_SECONDS, or if `until` (unix seconds) has passed.
 */
const waitForBlock = async (target: bigint | null, until?: number): Promise<boolean> => {
  if (target === null) return true;
  let last = -1n;
  let lastChange = Date.now();
  for (;;) {
    const latest = await publicClient.getBlockNumber({ cacheTime: 0 });
    if (latest >= target) return true;
    if (latest !== last) {
      last = latest;
      lastChange = Date.now();
    }
    if (Date.now() - lastChange >= blockWaitSeconds * 1000) return false;
    if (until !== undefined && nowSec() >= until) return false;
    await Bun.sleep(1000);
  }
};

/** Wait until there is a block after `block`. */
const waitForBlockAfter = (block: bigint | null, until?: number): Promise<boolean> =>
  waitForBlock(block === null ? null : block + 1n, until);

/** Check once per run whether the node applies block overrides (probe that returns timestamp and block number). */
const probeOverrides = async (): Promise<boolean> => {
  try {
    const latest = await publicClient.getBlock();
    const overrides = nextBlockOverrides(latest);
    const { data } = await publicClient.call({ data: OVERRIDE_PROBE_CODE, blockOverrides: overrides });
    return overridesApplied(data, overrides);
  } catch (error) {
    console.warn(`probe for block overrides failed: ${describeError(error)}`);
    return false;
  }
};

let cooldowns: CooldownState = existsSync(cooldownFile) ? parseCooldownState(readFileSync(cooldownFile, "utf8")) : {};
const nowSeconds = startSeconds;
cooldowns = pruneExpired(cooldowns, nowSeconds);
const saveCooldowns = () => writeFileSync(cooldownFile, `${JSON.stringify(cooldowns, null, 2)}\n`);
const failed = (owner: Address, error: unknown) => {
  const message = describeError(error);
  cooldowns = recordFailure(cooldowns, owner, nowSeconds, message, cooldownPolicy);
  saveCooldowns();
  const entry = cooldowns[owner.toLowerCase()];
  console.error(`${owner}: ${message}; cool-down until ${new Date(entry.until * 1000).toISOString()} (failure ${entry.failures})`);
};

/** Block of the last own transaction in this keeper run; the next owner only in a later block. */
let lastRunBlock: bigint | null = null;
/** After a blockade (own transaction reverted on-chain due to a temporary cause): earliest block for a new send. */
let sendFromBlock: bigint | null = null;
/** Consecutive own reverts without a blockade in this run (`quietRevertSendBlock`); back to 0 after a successful run */
let quietReverts = 0;
/** Priority fee for the next transaction; rises after a blockade, up to MAX_PRIORITY_FEE_GWEI (`startPriorityFee`). */
const readFeeState = (): FeeState | undefined => {
  try {
    return existsSync(feeStateFile) ? parseFeeState(readFileSync(feeStateFile, "utf8")) : undefined;
  } catch {
    return undefined;
  }
};

/**
 * Final review F-1: cap of the tip from what a run yields (`capFeePolicy`). The reward in wei follows from
 * KEEPER_REWARD_EURC and the Chainlink prices EURC/USD (the contract's feed) and ETH/USD. If a price cannot be read,
 * the reward counts as 0 and only TIP_BUDGET_ETH applies: better to bid too little than too much.
 * The contract pays at most min(KEEPER_REWARD_EURC, fee / 2) (self-audit 2026-09-17, L-D). Every run has a fee
 * of at least KEEPER_REWARD_EURC (the fee of MIN_TRADE_FLOOR), so KEEPER_REWARD_EURC / 2 is what every run is certain
 * to yield.
 */
const readRewardWei = async (): Promise<bigint> => {
  if (/^0x0{40}$/i.test(rewardTo)) return 0n;
  try {
    const [reward, eurcFeed] = await Promise.all([read<bigint>("KEEPER_REWARD_EURC"), read<Address>("FEED_EURC_USD")]);
    type Round = readonly [bigint, bigint, bigint, bigint, bigint];
    const [eurcRound, ethRound] = await Promise.all([
      read<Round>("latestRoundData", [], {}, eurcFeed),
      read<Round>("latestRoundData", [], {}, feedEthUsd),
    ]);
    return eurcToWei(reward / 2n, eurcRound[1], ethRound[1]);
  } catch (error) {
    console.warn(`reward in ETH cannot be read (${describeError(error)}); tip cap only from TIP_BUDGET_ETH`);
    return 0n;
  }
};
const feePolicy = capFeePolicy(configuredFeePolicy, {
  rewardWei: await readRewardWei(),
  rewardShareBps: tipRewardShareBps,
  budgetWei: tipBudgetWei,
  gasEstimate,
});
if (feePolicy.max < configuredFeePolicy.max) {
  console.log(`tip cap ${formatGwei(feePolicy.max)} gwei (tip × ${gasEstimate} gas ≤ reward × ${tipRewardShareBps}/10000 + budget)`);
}
const initialFeeState = readFeeState();
let lastBlockadeAt = initialFeeState?.lastBlockadeAt ?? 0;
let priorityFee = startPriorityFee(initialFeeState, startSeconds, feePolicy, feeHoldSeconds);
const saveFeeState = () =>
  writeFileSync(feeStateFile, `${JSON.stringify({ priorityFeeWei: priorityFee.toString(), lastBlockadeAt }, null, 2)}\n`);
/** A blockade or an own transaction in this run; without either, the tip drops at the end of the run. */
let blockadeThisRun = false;
let sentThisRun = false;
/** Final review F-1: after an own transaction without a blockade the tip drops (halving, not below the base). */
const lowerFee = () => {
  const next = decayPriorityFee(priorityFee, feePolicy);
  if (next === priorityFee) return;
  priorityFee = next;
  saveFeeState();
};

let pools: readonly Address[] | undefined;

/**
 * Has `owner` already been executed by someone else after the simulation (at block `simulatedBlock`) and before our
 * own transaction? In the block of our own transaction (final review F-1) or in a block in between (verification
 * 579f763, K-2): `Executed` logs for that owner from `simulatedBlock` + 1 through the block of the receipt
 * (`servedSince`). On a read error: not served (the old behaviour).
 */
const servedByOther = async (owner: Address, simulatedBlock: bigint, receipt: TransactionReceipt): Promise<boolean> => {
  try {
    const executed = await publicClient.getLogs({
      address: rebalancer,
      event: executedEvent[0],
      args: { owner },
      fromBlock: simulatedBlock + 1n,
      toBlock: receipt.blockNumber,
    });
    return servedSince(
      executed.map((log) => ({
        owner: log.args.owner ?? ("0x" as Address),
        blockNumber: log.blockNumber ?? -1n,
        transactionIndex: log.transactionIndex ?? Infinity,
      })),
      owner,
      simulatedBlock,
      receipt,
    );
  } catch (error) {
    console.warn(`Executed logs for ${owner} in block ${simulatedBlock + 1n}–${receipt.blockNumber} unreadable: ${describeError(error)}`);
    return false;
  }
};

/**
 * Transactions that touched one of both pools before our own transaction in that block (Swap, Mint or Burn), without
 * direct `execute`s of other keepers, and the highest tip among them; and whether `owner` has already been executed by
 * someone else since the simulation (`servedByOther`). On a read error of the pool logs: `touched` unknown (false) and
 * no tip; then the fee does not rise.
 */
const blockersOf = async (
  owner: Address,
  simulatedBlock: bigint,
  receipt: TransactionReceipt,
): Promise<{ touched: boolean; tip: bigint | undefined; served: boolean }> => {
  const servedPromise = servedByOther(owner, simulatedBlock, receipt);
  try {
    pools ??= [await read<Address>("POOL_EURC_USDC"), await read<Address>("POOL_USDC_CBBTC")];
    const [block, logs, served] = await Promise.all([
      publicClient.getBlock({ blockHash: receipt.blockHash }),
      publicClient.getLogs({ address: [...pools], events: poolEvents, blockHash: receipt.blockHash }),
      servedPromise,
    ]);
    const hashes = [
      ...new Set(logs.filter((log) => (log.transactionIndex ?? Infinity) < receipt.transactionIndex).map((log) => log.transactionHash)),
    ].filter((hash): hash is Hex => hash !== null);
    const txs = await Promise.all(hashes.map((hash) => publicClient.getTransaction({ hash })));
    const blocking = blockingTransactions(
      txs.map((tx) => ({
        transactionIndex: tx.transactionIndex ?? Infinity,
        to: tx.to,
        input: tx.input,
        tip: effectiveTip(tx, block.baseFeePerGas ?? 0n),
      })),
      receipt.transactionIndex,
      rebalancer,
    );
    return { touched: blocking.length > 0, tip: blockerTip(blocking, receipt.transactionIndex), served };
  } catch (error) {
    console.warn(`touchers in block ${receipt.blockNumber} cannot be read: ${describeError(error)}`);
    return { touched: false, tip: undefined, served: await servedPromise };
  }
};

/**
 * Re-simulate an `execute` that reverted on-chain on the state at the start of the transaction's block: the previous
 * block, with the overrides of the block itself. So only transactions before our own count, not a touch after it.
 * Without override support: on the block itself (then a later touch can count as well).
 */
const resimulateAtBlockStart = async (owner: Address, receipt: TransactionReceipt): Promise<Resimulation> => {
  try {
    if (readsNextBlock) {
      const block = await publicClient.getBlock({ blockHash: receipt.blockHash });
      await simulateExecute(owner, {
        blockNumber: receipt.blockNumber - 1n,
        blockOverrides: { number: receipt.blockNumber, time: block.timestamp },
      });
    } else {
      await simulateExecute(owner, { blockNumber: receipt.blockNumber });
    }
    return { kind: "passed" };
  } catch (error) {
    return revertOf(error) === undefined ? { kind: "error" } : { kind: "reverted", errorName: errorNameOf(error) };
  }
};

/**
 * Final review I-6: wait until one of `hashes` (same nonce: the transaction and its replacements) is mined. undefined
 * if that is not the case after TX_WAIT_BLOCKS blocks since `sentAtBlock`. An error reading a receipt counts as
 * "not mined yet". If the chain produces no block for BLOCK_WAIT_SECONDS, also undefined.
 */
const waitMined = async (hashes: readonly Hex[], sentAtBlock: bigint): Promise<TransactionReceipt | undefined> => {
  let last = sentAtBlock;
  let lastChange = Date.now();
  for (;;) {
    for (const hash of hashes) {
      try {
        return await publicClient.getTransactionReceipt({ hash });
      } catch {
        // not mined yet, or a node error: next attempt
      }
    }
    const latest = await publicClient.getBlockNumber({ cacheTime: 0 }).catch(() => last);
    if (isStuck(sentAtBlock, latest, txWaitBlocks)) return undefined;
    if (latest !== last) {
      last = latest;
      lastChange = Date.now();
    }
    if (Date.now() - lastChange >= blockWaitSeconds * 1000) return undefined;
    await Bun.sleep(1000);
  }
};

type Outcome = "executed" | "skipped" | "dry-run" | "retry";

/**
 * One attempt for an owner: read, simulate and execute. "retry" = temporary, again in a block after `block`.
 * `isRetry`: a repeated attempt, bounded by the retry budget.
 */
const attemptOwner = async (owner: Address, retryAfterBlock: bigint | null, isRetry: boolean): Promise<{ outcome: Outcome; block: bigint | null }> => {
  // After a blockade only again SEND_RETRY_BLOCKS later on average; simulating without being allowed to send is futile.
  const { target, throttled } = nextAttemptBlock(retryAfterBlock, lastRunBlock, dryRun ? null : sendFromBlock);
  if (!(await waitForBlock(target, isRetry || throttled ? deadline : undefined))) {
    console.log(`${owner}: skipped, no block ${target} within the wait budget; no cool-down`);
    return { outcome: "skipped", block: null };
  }

  const latest = await publicClient.getBlock();
  const at = atLatest(latest);
  const [due, eurcDelta] = await read<readonly [boolean, bigint]>("isDue", [owner], at);
  const direction = eurcDelta > 0n ? "buy" : "sell";
  const eurc = formatEurc(eurcDelta < 0n ? -eurcDelta : eurcDelta);
  if (due) {
    const sizeReason = runSizeSkipReason(eurcDelta, minRunEurc);
    if (sizeReason !== null) {
      console.log(`${owner}: skipped, ${sizeReason}`);
      return { outcome: "skipped", block: null };
    }
  }

  // Simulate first: an owner that reverts (dust that rounds to 0 on the route, blacklist, too tight
  // slippage) stays in dueOwners and would otherwise cost ~160k gas every run without a reward. Also when isDue
  // says false: that can be a full block window, and only the simulation gives the reason.
  let failure: unknown;
  /** Verdict on the error, if it does not follow directly from `failure` (on-chain revert). */
  let verdict: ReturnType<typeof onchainRevertVerdict>["failure"] | undefined;
  let simulated = false;
  try {
    await simulateExecute(owner, at);
    simulated = true;
  } catch (error) {
    failure = error;
  }

  if (!due && !isBlockWindowRevert(errorNameOf(failure))) {
    console.log(`${owner}: no longer due${failure === undefined ? "" : ` (${describeError(failure)})`}`);
    return { outcome: "skipped", block: null };
  }

  if (simulated) {
    if (dryRun || !walletClient) {
      console.log(`[dry-run] ${owner}: ${direction} ≈ ${eurc} EURC (simulation ok${at.blockOverrides ? ", next block" : ""})`);
      return { outcome: "dry-run", block: null };
    }
    // Verification 579f763 (K-6): no transaction that the watchdog would cut off halfway.
    const needed = sendWorstCaseSeconds(txWaitBlocks, txReplacements, blockWaitSeconds);
    if (!hasTimeToSend(nowSec(), lockStartedAt + lockWatchdogSeconds(lockMaxSeconds), needed)) {
      console.log(`${owner}: skipped, too little time before the watchdog for a transaction (${needed} s needed); no cool-down`);
      return { outcome: "skipped", block: null };
    }
    try {
      // Verification 579f763 (K-6): if one of our own transactions is still pending (previous run stopped, or node error
      // during replacement), send nothing: temporary, again in a later block.
      const [minedNonce, pendingNonce] = await Promise.all([
        publicClient.getTransactionCount({ address: walletClient.account.address, blockTag: "latest" }),
        publicClient.getTransactionCount({ address: walletClient.account.address, blockTag: "pending" }),
      ]);
      if (ownTransactionPending(minedNonce, pendingNonce)) {
        throw new Error(`own transaction with nonce ${minedNonce} still pending (pending ${pendingNonce}); none sent`);
      }
      // Gas, both fees, nonce and chainId explicitly: otherwise viem estimates them itself. eth_estimateGas runs on the
      // latest block (where a touch makes the estimate revert), a fee estimate overwrites the chosen tip, and without
      // a nonce viem first tries eth_fillTransaction. GAS_LIMIT 1,000,000 is the limit that
      // test_fork_buyAndSellGasCost guards.
      const nonce = pendingNonce;
      const send = (fees: { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }) =>
        walletClient.writeContract({
          address: rebalancer,
          abi,
          functionName: "execute",
          args: [owner, rewardTo],
          gas: gasLimit,
          ...fees,
          nonce,
          // `chainId` is not in the type of writeContract, but is passed via sendTransaction to
          // prepareTransactionRequest; without it viem first tries eth_fillTransaction (viem 2.56.3).
          ...({ chainId: base.id } as unknown as Record<string, never>),
        });
      let fees = { maxPriorityFeePerGas: priorityFee, maxFeePerGas: maxFeePerGas(latest.baseFeePerGas ?? 0n, priorityFee) };
      const hashes: Hex[] = [await send(fees)];
      let sentAtBlock = latest.number;
      let receipt: TransactionReceipt | undefined;
      // Final review I-6: not mined within TX_WAIT_BLOCKS blocks (for example a base fee that rose above maxFeePerGas):
      // replace with the same nonce and higher fees, at most TX_REPLACEMENTS times. If that fails, the
      // run stops clearly; a next send would get stuck behind the same nonce. No cool-down.
      for (let replacements = 0; ; replacements += 1) {
        receipt = await waitMined(hashes, sentAtBlock);
        if (receipt !== undefined) break;
        const block = await publicClient.getBlock();
        const next = replacements < txReplacements ? replacementFees(fees, block.baseFeePerGas ?? 0n, feePolicy.max) : null;
        if (next === null) {
          saveCooldowns();
          throw new Error(
            `transaction ${hashes.join(", ")} (nonce ${nonce}) for ${owner} not mined within ${txWaitBlocks} blocks and no longer replaceable; run stopped`,
          );
        }
        console.warn(
          `${owner}: transaction ${hashes.at(-1)} not mined after ${txWaitBlocks} blocks; replacing (nonce ${nonce}, tip ${formatGwei(next.maxPriorityFeePerGas)} gwei, maxFee ${formatGwei(next.maxFeePerGas)} gwei)`,
        );
        fees = next;
        try {
          hashes.push(await send(fees));
        } catch (error) {
          // For example "nonce too low": the previous one was mined in the meantime. The next round finds that receipt.
          console.warn(`${owner}: replacement failed (${describeError(error)})`);
        }
        sentAtBlock = block.number;
      }
      const hash = receipt.transactionHash;
      console.log(`${owner}: ${direction} ≈ ${eurc} EURC → ${receipt.status} ${hash} (tip ${formatGwei(fees.maxPriorityFeePerGas)} gwei)`);
      lastRunBlock = receipt.blockNumber;
      sentThisRun = true;
      if (receipt.status === "success") {
        quietReverts = 0;
        cooldowns = clearFailure(cooldowns, owner);
        saveCooldowns();
        lowerFee();
        return { outcome: "executed", block: receipt.blockNumber };
      }
      // Reverted after a successful simulation: the state changed in the meantime. Re-simulate at the start of that
      // block for the reason, and look at who touched a pool before us.
      failure = new Error(`transaction ${hash} reverted`);
      const [resimulation, blockers] = await Promise.all([
        resimulateAtBlockStart(owner, receipt),
        blockersOf(owner, latest.number, receipt),
      ]);
      const judged = onchainRevertVerdict(resimulation, blockers.touched, blockers.served);
      verdict = judged.failure;
      if (judged.failure.servedByOther) {
        // Final review F-1 and K-2: another party executed this owner after our simulation, in this block or earlier.
        // Served; no cool-down, no higher tip.
        console.log(
          `${owner}: already executed by another (block ${latest.number + 1n}–${receipt.blockNumber}); no cool-down, no higher tip`,
        );
        lowerFee();
        return { outcome: "skipped", block: null };
      }
      if (resimulation.kind === "reverted") failure = new Error(`transaction ${hash} reverted (${resimulation.errorName ?? "revert"})`);
      if (judged.blockade) {
        // Blockade: another transaction touched a pool before us. Higher tip, and only SEND_RETRY_BLOCKS later on average.
        sendFromBlock = nextSendBlock(receipt.blockNumber, sendRetryBlocks, Math.random());
        priorityFee = nextPriorityFee(priorityFee, blockers.tip, feePolicy);
        lastBlockadeAt = nowSec();
        blockadeThisRun = true;
        saveFeeState();
        console.warn(
          `${owner}: blockade in block ${receipt.blockNumber} (toucher tip ${blockers.tip === undefined ? "unknown" : `${formatGwei(blockers.tip)} gwei`}); next tip ${formatGwei(priorityFee)} gwei`,
        );
      } else {
        lowerFee();
        if (isTemporaryFailure(judged.failure)) {
          // Verification 579f763 (info a): temporary without a blockade (e.g. a direct execute of another party). After the
          // first time do not send again every block, but wait 2, 4, … up to SEND_RETRY_BLOCKS blocks; the tip stays.
          quietReverts += 1;
          const from = quietRevertSendBlock(receipt.blockNumber, quietReverts, sendRetryBlocks);
          if (from !== null && (sendFromBlock === null || from > sendFromBlock)) {
            sendFromBlock = from;
            console.log(`${owner}: revert ${quietReverts} without blockade in this run; next transaction not before block ${from}`);
          }
        }
      }
    } catch (error) {
      if (error instanceof Error && error.message.includes("run stopped")) throw error;
      failure = error;
    }
  }

  // A node error (not a contract revert) says nothing about the owner: temporary, no cool-down.
  const judged = verdict ?? { errorName: errorNameOf(failure), transient: revertOf(failure) === undefined };
  const action = failureAction(judged, nowSec(), deadline);
  if (action === "fail") {
    failed(owner, failure);
    return { outcome: "skipped", block: null };
  }
  if (action === "skip") {
    console.log(`${owner}: ${describeError(failure)}, retry budget (${retrySeconds} s) spent; no cool-down`);
    return { outcome: "skipped", block: null };
  }
  console.log(`${owner}: ${describeError(failure)}; again in a following block`);
  return { outcome: "retry", block: lastRunBlock !== null && lastRunBlock > latest.number ? lastRunBlock : latest.number };
};

/** Owners per `owners(offset, limit)` read and per multicall for balance and allowance (5 calls per owner). */
const REGISTER_PAGE = 500n;
const FUNDS_BATCH = 100;

/** Multicall3 over separate contract calls, one eth_call per batch; a failed call gives undefined. */
const multicallResults = async (
  contracts: readonly { address: Address; functionName: string; args?: readonly unknown[] }[],
  at: At = {},
): Promise<unknown[]> => {
  const results = await publicClient.multicall({
    contracts: contracts.map((c) => ({ abi, ...c })),
    allowFailure: true,
    batchSize: 0,
    ...atParams(at),
    // biome-ignore lint/suspicious/noExplicitAny: mixed functions in one multicall
  } as any);
  return (results as { status: string; result?: unknown }[]).map((r) => (r.status === "success" ? r.result : undefined));
};

/** A candidate, with its position in the register (null for an address from OWNERS_FILE). */
type Candidate = { owner: Address; index: bigint | null };

/** What the filter needs: the contract's tokens, the feed price and the lower bound. */
type FilterContext = { eurcToken: Address; cbbtcToken: Address; price: bigint; minRun: bigint };

/**
 * Lead 9: which of these owners can reach a run in at least one direction (`filterCandidates`)? One multicall. An
 * owner for which a read fails stays a candidate as a precaution. A node error throws; the caller
 * then skips the batch.
 */
const fundedAmong = async (owners: readonly Address[], ctx: FilterContext): Promise<Set<string>> => {
  const results = await multicallResults(
    owners.flatMap((owner) => [
      { address: rebalancer, functionName: "params", args: [owner] },
      { address: ctx.eurcToken, functionName: "balanceOf", args: [owner] },
      { address: ctx.eurcToken, functionName: "allowance", args: [owner, rebalancer] },
      { address: ctx.cbbtcToken, functionName: "balanceOf", args: [owner] },
      { address: ctx.cbbtcToken, functionName: "allowance", args: [owner, rebalancer] },
    ]),
  );
  const keep = new Set<string>();
  const rows: OwnerFunds[] = [];
  owners.forEach((owner, i) => {
    const [params, eurcBalance, eurcAllowance, cbbtcBalance, cbbtcAllowance] = results.slice(i * 5, i * 5 + 5);
    if ([params, eurcBalance, eurcAllowance, cbbtcBalance, cbbtcAllowance].some((r) => r === undefined)) {
      console.warn(`${owner}: balance or allowance cannot be read; stays a candidate`);
      keep.add(owner.toLowerCase());
      return;
    }
    rows.push({
      owner,
      active: (params as readonly [boolean, ...unknown[]])[0],
      eurcBalance: eurcBalance as bigint,
      eurcAllowance: eurcAllowance as bigint,
      cbbtcBalance: cbbtcBalance as bigint,
      cbbtcAllowance: cbbtcAllowance as bigint,
    });
  });
  for (const owner of filterCandidates(rows, ctx.price, ctx.minRun)) keep.add(owner.toLowerCase());
  return keep;
};

/**
 * Tokens, feed price and lower bound for the filter. undefined if the feed price reverts: then, per the contract, nobody
 * is due. A node error on these few reads aborts the run (nothing has been done yet at that point).
 */
const filterContext = async (): Promise<FilterContext | undefined> => {
  const [eurcToken, cbbtcToken, floor] = await Promise.all([
    read<Address>("EURC"),
    read<Address>("CBBTC"),
    read<bigint>("MIN_TRADE_FLOOR"),
  ]);
  try {
    const price = await read<bigint>("quote");
    return { eurcToken, cbbtcToken, price, minRun: minRunBaseUnits(floor, minRunEurc) };
  } catch (error) {
    if (revertOf(error) === undefined) throw error;
    console.warn(`feed price cannot be read (${describeError(error)}); nobody due`);
    return undefined;
  }
};

/**
 * Final review F-2: candidates from the register, from the stored offset (`scanSegments`) and within the search time
 * (`SEARCH_SECONDS` after the start, separate from the retry budget). A node error on a batch (`owners` or the
 * multicall) only skips that batch. Also returns up to where the register has been read.
 */
const scanRegister = async (
  count: bigint,
  start: bigint,
  ctx: FilterContext,
  skip: ReadonlySet<string>,
): Promise<{ candidates: Candidate[]; scannedTo: bigint; read: bigint; complete: boolean }> => {
  const candidates: Candidate[] = [];
  let read_ = 0n;
  for (const segment of scanSegments(start, count, REGISTER_PAGE)) {
    if (nowSec() >= searchDeadline) {
      console.warn(`Search time (${searchSeconds} s) spent after ${read_} of ${count} owners; next run continues from ${segment.offset}.`);
      return { candidates, scannedTo: segment.offset, read: read_, complete: false };
    }
    let page: readonly Address[];
    try {
      page = await read<readonly Address[]>("owners", [segment.offset, segment.limit]);
    } catch (error) {
      console.warn(`owners(${segment.offset}, ${segment.limit}) cannot be read (${describeError(error)}); batch skipped`);
      read_ += segment.limit;
      continue;
    }
    for (const [b, batch] of chunks(page, FUNDS_BATCH).entries()) {
      const firstIndex = segment.offset + BigInt(b * FUNDS_BATCH);
      let funded: Set<string>;
      try {
        funded = await fundedAmong(batch, ctx);
      } catch (error) {
        console.warn(`balance and allowance of owners ${firstIndex}–${firstIndex + BigInt(batch.length) - 1n} cannot be read (${describeError(error)}); batch skipped`);
        continue;
      }
      batch.forEach((owner, i) => {
        if (funded.has(owner.toLowerCase()) && !skip.has(owner.toLowerCase())) {
          candidates.push({ owner, index: firstIndex + BigInt(i) });
        }
      });
    }
    read_ += segment.limit;
  }
  return { candidates, scannedTo: start, read: read_, complete: true };
};

/**
 * Which of these owners are due now? `isDue` per owner in one multicall. `isDue` never reverts, so a failed call is
 * a node error (viem also catches it with `allowFailure`). Then this throws; the caller skips the batch.
 */
const dueAmong = async (owners: readonly Address[], at: At): Promise<Address[]> => {
  const results = await multicallResults(
    owners.map((owner) => ({ address: rebalancer, functionName: "isDue", args: [owner] })),
    at,
  );
  if (results.some((r) => r === undefined)) {
    throw new Error("isDue cannot be read for a batch of candidates (node error)");
  }
  return owners.filter((_, i) => (results[i] as readonly [boolean, bigint])[0] === true);
};

// Verification 579f763 (info b): an error that is not caught anywhere else is not printed by Bun (then the
// full RPC URL with a possible API key is in the log), but here, without that URL.
/**
 * Verification 579f763 (info c): the scan progress (final review F-2) is also saved if the run stops on an error, in
 * `finally`. `scan` is set once the register has been read; `pending` are the candidates not yet (fully) read
 * so far: at the retry budget the rest, on an error the batch where it went wrong and everything after it.
 */
let scan: { count: bigint; scannedTo: bigint } | undefined;
let pending: readonly Candidate[] = [];
try {
  readsNextBlock = await probeOverrides();
  if (!readsNextBlock) {
    console.warn(
      "The node does not apply block overrides: falling back to the latest block. A touch of a pool in the latest block then makes owners appear not due (audit L-3).",
    );
  }

  const checked = await read<bigint>("ownerCount");
  let executed = 0;
  let skipped = 0;
  /** Owners already handled this run (executed, skipped or failed); these are not tried again. */
  const handled = new Set<string>();
  /** Owners with a temporary revert, retried in turn until the retry budget is spent. */
  const retryQueue: { owner: Address; block: bigint | null }[] = [];

  const count = (owner: Address, result: { outcome: Outcome; block: bigint | null }) => {
    if (result.outcome === "executed") executed += 1;
    if (result.outcome === "skipped") skipped += 1;
    if (result.outcome === "retry") retryQueue.push({ owner, block: result.block });
  };

  // Audit lead 9 and final review F-2: first the addresses from OWNERS_FILE, then the register from the stored offset,
  // within the search time. All filtered off-chain on active, balance and allowance (bundled with Multicall3), so empty
  // spam registrations do not hold up the run. Only the candidates get an isDue.
  const scanStart = nextScanOffset(parseScanState(existsSync(scanStateFile) ? readFileSync(scanStateFile, "utf8") : undefined), null, checked);
  const ctx = await filterContext();
  const candidates: Candidate[] = [];
  let scannedTo = scanStart;
  if (ctx !== undefined) {
    if (priorityOwners.length > 0) {
      for (const batch of chunks(priorityOwners, FUNDS_BATCH)) {
        try {
          const funded = await fundedAmong(batch, ctx);
          for (const owner of batch) if (funded.has(owner.toLowerCase())) candidates.push({ owner, index: null });
        } catch (error) {
          // Do not silently drop our own users: on a node error they go through unfiltered to isDue.
          console.warn(`balance and allowance of OWNERS_FILE unreadable (${describeError(error)}); going on unfiltered`);
          for (const owner of batch) candidates.push({ owner, index: null });
        }
      }
      console.log(`${priorityOwners.length} addresses from OWNERS_FILE, ${candidates.length} candidates`);
    }
    const found = await scanRegister(checked, scanStart, ctx, new Set(priorityOwners.map((o) => o.toLowerCase())));
    candidates.push(...found.candidates);
    scannedTo = found.scannedTo;
    scan = { count: checked, scannedTo };
    console.log(
      `${checked} owners registered, ${found.read} read from ${scanStart}${found.complete ? " (whole register)" : ""}, ${candidates.length} candidates after the balance and allowance filter`,
    );
  }

  const batches = chunks(candidates, Number(pageSize));
  for (const [index, batch] of batches.entries()) {
    pending = batches.slice(index).flat();
    if (nowSec() >= deadline) {
      console.warn(
        `Retry budget (${retrySeconds} s) spent: ${pending.length} candidates no longer read; the next run starts in the register at ${firstRegisterIndex(pending) ?? scannedTo}.`,
      );
      break;
    }
    const owners = batch.map((c) => c.owner);
    let readBlock: bigint | null = null;
    for (let reads = 1; ; reads += 1) {
      // Every read in a block after the last own run and after the previous read of this batch.
      const after = readBlock !== null && (lastRunBlock === null || readBlock > lastRunBlock) ? readBlock : lastRunBlock;
      if (!(await waitForBlockAfter(after))) break;
      let fresh: Address[];
      try {
        const latest = await publicClient.getBlock();
        readBlock = latest.number;
        fresh = newOwners(await dueAmong(owners, atLatest(latest)), handled);
      } catch (error) {
        console.warn(`isDue for ${owners.length} candidates cannot be read (${describeError(error)}); batch skipped`);
        break;
      }

      for (const owner of fresh) {
        handled.add(owner.toLowerCase());
        if (isCoolingDown(cooldowns, owner, nowSeconds)) {
          console.log(`${owner}: skipped, cool-down until ${new Date((cooldownUntil(cooldowns, owner) ?? 0) * 1000).toISOString()}`);
          skipped += 1;
          continue;
        }
        count(owner, await attemptOwner(owner, null, false));
      }
      if (!shouldReadPageAgain(fresh.length, reads, blockRetries + 1, readsNextBlock)) break;
    }
    pending = batches.slice(index + 1).flat();
  }

  // Temporarily blocked owners in turn, each in a new block, until they succeed or the retry budget is spent.
  while (retryQueue.length > 0) {
    const next = retryQueue.shift();
    if (next === undefined) break;
    count(next.owner, await attemptOwner(next.owner, next.block, true));
  }

  // Final review F-1: a run without a blockade and without our own transaction also lowers the tip.
  if (!blockadeThisRun && !sentThisRun && !dryRun) lowerFee();
  console.log(`Done: ${checked} owners registered, ${executed} executed, ${skipped} skipped${dryRun ? " (dry-run)" : ""}.`);
} catch (error) {
  const full = error instanceof Error ? (error.stack ?? error.message) : String(error);
  console.error(`run aborted: ${redactRpcUrl(full, rpcUrl)}`);
  process.exitCode = 1;
} finally {
  try {
    saveCooldowns();
    if (scan !== undefined) {
      const nextOffset = nextScanOffset(scan.scannedTo, firstRegisterIndex(pending), scan.count);
      writeFileSync(scanStateFile, `${JSON.stringify({ nextOffset: nextOffset.toString() }, null, 2)}\n`);
    }
  } catch (error) {
    console.error(`state cannot be saved: ${describeError(error)}`);
    process.exitCode = 1;
  }
}
