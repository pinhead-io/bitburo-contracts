/**
 * Bitburo keeper script for the Rebalancer.
 *
 * Runs the wallets whose owner appointed this keeper (`setMandate(targetBps, keeper)`). Anyone can run it for the
 * owners who appointed them, or for their own wallet; Bitburo is not needed. The script decides nothing about amounts
 * or direction: the contract decides whether, what and how much, and bounds the price with Chainlink. The script
 * chooses the moment and demands the price it just simulated.
 *
 * One run:
 * 1. Owners: the addresses in OWNERS_FILE, plus every owner that ever named this keeper in a `MandateSet` event
 *    (searched from FROM_BLOCK in ranges of LOG_RANGE_BLOCKS, for at most SEARCH_SECONDS; OWNERS_STATE_FILE remembers
 *    where the next run continues). That file belongs to one contract and one keeper: a run for another REBALANCER
 *    or keeper refuses it, because continuing from its position would miss the earlier events of the new pair.
 * 2. Two multicalls per PAGE_SIZE owners (Multicall3; viem splits a large one over several requests):
 *    `mandates(owner)` (still ours?) and `isDue(owner)`, both at the block where the search of step 1 ends. Owners
 *    that no longer name this keeper are forgotten; a new `MandateSet` event brings them back. A node that has not
 *    reached that block fails the read and the page is skipped this run: its older state would show an owner with a
 *    fresh mandate as one that left, and no later event would bring him back.
 * 3. Per due owner: simulate `execute(owner, 0)` with `eth_call`. It returns what the swap yields right now; the
 *    transaction then demands that amount minus TOLERANCE_BPS as `minAmountOut`. So a swap that someone pushes
 *    between the simulation and the transaction reverts instead of trading at the contract's wider Chainlink bound.
 * 4. Send `execute(owner, minAmountOut)` as a plain transaction from the keeper's own key and wait for the receipt.
 *    Send it straight to the sequencer: a relayer or bundler that wraps the call can trade around it.
 *
 * Failures: node errors, market and oracle conditions and a state that changed since `isDue` are skipped until the
 * next run; every other revert, one the keeper cannot decode and a transaction that ran out of GAS_LIMIT included,
 * puts the owner on a cool-down that doubles per failure (COOLDOWN_FILE). See `failureAction`.
 * One run at a time (LOCK_FILE); nothing is sent while an earlier transaction of this key is still pending.
 *
 * The contract allows one run per owner per day, so running this every 10 to 60 minutes is plenty.
 *
 * Usage:
 *   RPC_URL=https://mainnet.base.org REBALANCER=0x… KEEPER_PRIVATE_KEY=0x… FROM_BLOCK=<deploy block> bun run keeper.ts
 * Dry run: DRY_RUN=1 KEEPER_ADDRESS=0x… It needs no key, sends nothing and writes nothing: it reads OWNERS_STATE_FILE
 * and COOLDOWN_FILE but leaves both as they are, and it takes no lock, so it can run next to a real run. Because it
 * does not save how far it searched, every dry run searches again from the position in OWNERS_STATE_FILE (FROM_BLOCK
 * without that file).
 * Optional: OWNERS_FILE=./owners.txt  OWNERS_STATE_FILE=./keeper-owners.json  LOG_RANGE_BLOCKS=5000
 *           SEARCH_SECONDS=120  PAGE_SIZE=50  TOLERANCE_BPS=10  GAS_LIMIT=500000  TX_WAIT_SECONDS=120
 *           COOLDOWN_FILE=./keeper-cooldowns.json  COOLDOWN_SECONDS=3600  COOLDOWN_MAX_SECONDS=86400
 *           LOCK_FILE=./keeper.lock  LOCK_MAX_SECONDS=900
 */
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import {
  type Address,
  BaseError,
  ContractFunctionRevertedError,
  type Hex,
  createPublicClient,
  createWalletClient,
  getAddress,
  http,
  isAddress,
  parseAbi,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import { acquireLock } from "./lock";
import {
  type CooldownState,
  type Failure,
  type Mandate,
  type OwnersState,
  chunks,
  clearFailure,
  failureAction,
  formatOwnersState,
  formatUsdc,
  isCoolingDown,
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
  parseWholeNumber,
  pruneExpired,
  recordFailure,
  redactRpcUrl,
  withoutOwners,
} from "./selection";

const abi = parseAbi([
  "function mandates(address owner) view returns (uint16 targetBps, uint64 lastExecutedAt, address keeper)",
  "function isDue(address owner) view returns (bool due, int256 usdcDelta)",
  "function execute(address owner, uint256 minAmountOut) returns (uint256 swapOutput)",
  "function retired() view returns (bool)",
  "event MandateSet(address indexed owner, uint16 targetBps, address indexed keeper)",
  "error InvalidTarget()",
  "error Inactive()",
  "error NotOwnerOrKeeper()",
  "error NotDue()",
  "error NothingToDo()",
  "error SequencerDown()",
  "error StaleFeed()",
  "error InvalidFeedAnswer()",
  "error OutsidePriceBounds(uint256 received, uint256 expected)",
  "error ContractRetired()",
]);

// ─── Configuration ─────────────────────────────────────────────────────────────────────────────────────────────

const env = (name: string, fallback?: string): string => {
  const value = process.env[name] ?? fallback;
  if (value === undefined) throw new Error(`${name} is missing`);
  return value;
};
const positiveInt = (name: string, fallback: string): number => {
  const value = Number(env(name, fallback));
  if (!Number.isInteger(value) || value < 1) throw new Error(`${name} must be an integer >= 1`);
  return value;
};

const rpcUrl = env("RPC_URL", "https://mainnet.base.org");
const rebalancerInput = env("REBALANCER");
if (!isAddress(rebalancerInput)) throw new Error("REBALANCER is not a valid address");
const rebalancer = getAddress(rebalancerInput);
const dryRun = process.env.DRY_RUN === "1";
const ownersFile = process.env.OWNERS_FILE;
const ownersStateFile = env("OWNERS_STATE_FILE", "./keeper-owners.json");
const fromBlock = process.env.FROM_BLOCK === undefined ? undefined : parseWholeNumber("FROM_BLOCK", process.env.FROM_BLOCK);
const logRangeBlocks = BigInt(positiveInt("LOG_RANGE_BLOCKS", "5000"));
const searchSeconds = positiveInt("SEARCH_SECONDS", "120");
const pageSize = positiveInt("PAGE_SIZE", "50");
const toleranceBps = parseWholeNumber("TOLERANCE_BPS", env("TOLERANCE_BPS", "10"));
const gasLimit = BigInt(positiveInt("GAS_LIMIT", "500000"));
const txWaitSeconds = positiveInt("TX_WAIT_SECONDS", "120");
const cooldownFile = env("COOLDOWN_FILE", "./keeper-cooldowns.json");
const cooldownPolicy = {
  baseSeconds: positiveInt("COOLDOWN_SECONDS", "3600"),
  maxSeconds: positiveInt("COOLDOWN_MAX_SECONDS", "86400"),
};
const lockFile = env("LOCK_FILE", "./keeper.lock");
const lockMaxSeconds = positiveInt("LOCK_MAX_SECONDS", "900");
if (lockMaxSeconds < searchSeconds + txWaitSeconds + 60) {
  throw new Error("LOCK_MAX_SECONDS must be at least SEARCH_SECONDS + TX_WAIT_SECONDS + 60");
}
minAmountOut(0n, toleranceBps); // validates TOLERANCE_BPS before anything happens
/** An invalid file stops the run before anything happens. */
const listedOwners = ownersFile === undefined || ownersFile === "" ? [] : parseOwnersFile(readFileSync(ownersFile, "utf8"));
if (fromBlock === undefined && listedOwners.length === 0 && !existsSync(ownersStateFile)) {
  throw new Error("Nothing to serve: set FROM_BLOCK (search the MandateSet events) or OWNERS_FILE");
}

const account = dryRun ? undefined : privateKeyToAccount(env("KEEPER_PRIVATE_KEY") as Hex);
const keeperInput = account?.address ?? env("KEEPER_ADDRESS");
if (!isAddress(keeperInput)) throw new Error("KEEPER_ADDRESS is not a valid address");
const keeper = getAddress(keeperInput);

const nowSec = (): number => Math.floor(Date.now() / 1000);
const startSeconds = nowSec();

// ─── One run at a time ─────────────────────────────────────────────────────────────────────────────────────────

const pidAlive = (pid: number): boolean => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM: the process exists, but belongs to another user.
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
};
// A dry run sends nothing and writes no file, so it has nothing to guard: it takes no lock and leaves the lock file
// of a real run alone.
if (!dryRun) {
  if (
    !acquireLock(lockFile, {
      pid: process.pid,
      nowSeconds: startSeconds,
      maxAgeSeconds: lockMaxSeconds,
      isAlive: pidAlive,
      onStaleRemoved: (lock) =>
        console.warn(`stale lock removed (${lock ? `pid ${lock.pid}, ${startSeconds - lock.startedAt} s old` : "unreadable"})`),
    })
  ) {
    console.warn(`Another keeper run is still running (${lockFile}); this run stops.`);
    process.exit(0);
  }
  process.on("exit", () => {
    try {
      if (parseLock(readFileSync(lockFile, "utf8"))?.pid === process.pid) unlinkSync(lockFile);
    } catch {
      // already gone
    }
  });
}
/** Read under the lock and before any network work: a damaged file stops the run here, not after the search. */
let cooldowns: CooldownState = pruneExpired(
  existsSync(cooldownFile) ? parseCooldownState(readFileSync(cooldownFile, "utf8")) : {},
  nowSec(),
  cooldownPolicy.maxSeconds,
);
/** A dry run keeps its cool-downs to itself: written, they would hold the real keeper back from those owners. */
const saveCooldowns = (): void => {
  if (!dryRun) writeFileSync(cooldownFile, `${JSON.stringify(cooldowns, null, 2)}\n`);
};
// A run that hangs stops itself before its lock expires. `process.exit` skips the `finally` in `main`, so the
// cool-downs of this run are saved here: without the one for too little gas, every run would waste a transaction.
setTimeout(() => {
  console.error(`run exceeds ${lockWatchdogSeconds(lockMaxSeconds)} s (LOCK_MAX_SECONDS ${lockMaxSeconds}); stopped`);
  try {
    saveCooldowns();
  } finally {
    process.exit(1);
  }
}, lockWatchdogSeconds(lockMaxSeconds) * 1000).unref();

// ─── Chain access ──────────────────────────────────────────────────────────────────────────────────────────────

const publicClient = createPublicClient({ chain: base, transport: http(rpcUrl) });
const walletClient = account ? createWalletClient({ account, chain: base, transport: http(rpcUrl) }) : undefined;

const revertOf = (error: unknown): ContractFunctionRevertedError | undefined => {
  if (!(error instanceof BaseError)) return undefined;
  const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
  return reverted instanceof ContractFunctionRevertedError ? reverted : undefined;
};

/**
 * What failed. viem decodes a plain `revert("…")` as the built-in error `Error(string)`: the name says nothing, the
 * reason does. A revert with an error outside the ABI has no name and no reason.
 */
const failureOf = (error: unknown): Failure => {
  const reverted = revertOf(error);
  if (reverted === undefined) return { kind: "node" };
  const errorName = reverted.data?.errorName;
  if (errorName === undefined || errorName === "Error") return { kind: "revert", reason: reverted.reason };
  return { kind: "contract", errorName };
};

/** First line of an error, with the contract error if there is one. Never the RPC URL (it may hold an API key). */
const describeError = (error: unknown): string => {
  const reverted = revertOf(error);
  const text = (): string => {
    if (reverted?.data?.errorName) return `${reverted.data.errorName}(${(reverted.data.args ?? []).join(", ")})`;
    if (reverted?.reason) return reverted.reason;
    // An error outside the ABI: viem puts its selector on the second line of the message, and only the first is kept.
    if (reverted?.signature) return `unknown error ${reverted.signature}`;
    if (error instanceof BaseError) return error.shortMessage;
    return String((error as Error)?.message ?? error).split("\n")[0];
  };
  return redactRpcUrl(text(), rpcUrl);
};

// ─── 1. Owners ─────────────────────────────────────────────────────────────────────────────────────────────────

/** Owners that named this keeper, from the events up to `latest`. Continues where the previous run stopped. */
const findOwners = async (latest: bigint): Promise<OwnersState | undefined> => {
  let state: OwnersState;
  if (existsSync(ownersStateFile)) state = parseOwnersState(readFileSync(ownersStateFile, "utf8"), { rebalancer, keeper });
  else if (fromBlock !== undefined) state = { rebalancer, keeper, nextBlock: fromBlock, owners: [] };
  else return undefined;
  for (const range of logRanges(state.nextBlock, latest, logRangeBlocks)) {
    if (nowSec() - startSeconds >= searchSeconds) {
      console.warn(`search time (${searchSeconds} s) used up at block ${range.fromBlock}; the next run continues there`);
      break;
    }
    try {
      const logs = await publicClient.getLogs({
        address: rebalancer,
        event: abi[4],
        args: { keeper },
        fromBlock: range.fromBlock,
        toBlock: range.toBlock,
      });
      const found = logs.map((log) => log.args.owner).filter((owner): owner is Address => owner !== undefined);
      state = { ...state, nextBlock: range.toBlock + 1n, owners: mergeOwners(state.owners, found) };
    } catch (error) {
      console.warn(`reading events from block ${range.fromBlock} failed: ${describeError(error)}; the next run continues there`);
      break;
    }
  }
  if (!dryRun) writeFileSync(ownersStateFile, formatOwnersState(state));
  return state;
};

// ─── 2. Who is due ─────────────────────────────────────────────────────────────────────────────────────────────

type Due = { owner: Address; usdcDelta: bigint };

/**
 * Reads at `blockNumber`, the block the search ended at. `mandates` cannot revert, so its multicall throws when the
 * node fails, a node that has not reached that block included: the page is skipped, and nobody on it counts as gone.
 * @returns the due owners, and the owners whose mandate no longer names this keeper.
 */
const readDue = async (owners: readonly Address[], blockNumber: bigint): Promise<{ due: Due[]; gone: Address[] }> => {
  const due: Due[] = [];
  const gone: Address[] = [];
  for (const page of chunks(owners, pageSize)) {
    try {
      const mandates = await publicClient.multicall({
        allowFailure: false,
        blockNumber,
        contracts: page.map((owner) => ({ address: rebalancer, abi, functionName: "mandates", args: [owner] }) as const),
      });
      const dues = await publicClient.multicall({
        allowFailure: true,
        blockNumber,
        contracts: page.map((owner) => ({ address: rebalancer, abi, functionName: "isDue", args: [owner] }) as const),
      });
      page.forEach((owner, i) => {
        const dueResult = dues[i];
        const [targetBps, , appointed] = mandates[i];
        const mandate: Mandate = { targetBps, keeper: appointed };
        if (!mayRun(mandate, owner, keeper)) {
          gone.push(owner);
          return;
        }
        if (dueResult.status !== "success") {
          // `isDue` reverts like `execute` when the sequencer or the price feed fails.
          console.warn(`${owner}: isDue failed: ${describeError(dueResult.error)}`);
          return;
        }
        const [isDue, usdcDelta] = dueResult.result;
        if (isDue) due.push({ owner, usdcDelta });
      });
    } catch (error) {
      console.warn(`reading ${page.length} owners failed: ${describeError(error)}; skipped this run`);
    }
  }
  return { due, gone };
};

// ─── 3 and 4. Simulate, then send ──────────────────────────────────────────────────────────────────────────────

type Outcome = "executed" | "simulated" | "skipped" | "cooldown" | "stop";

const run = async ({ owner, usdcDelta }: Due): Promise<{ outcome: Outcome; detail: string }> => {
  const label = `${usdcDelta > 0n ? "buy" : "sell"} ${formatUsdc(usdcDelta > 0n ? usdcDelta : -usdcDelta)} USDC`;
  let simulatedOut: bigint;
  try {
    const simulation = await publicClient.simulateContract({
      address: rebalancer,
      abi,
      functionName: "execute",
      args: [owner, 0n],
      account: keeper,
    });
    simulatedOut = simulation.result;
  } catch (error) {
    const action = failureAction(failureOf(error));
    return { outcome: action === "skip" ? "skipped" : action, detail: `${label}: simulation: ${describeError(error)}` };
  }
  const demanded = minAmountOut(simulatedOut, toleranceBps);
  if (walletClient === undefined) return { outcome: "simulated", detail: `${label}: would demand at least ${demanded}` };

  const [latestNonce, pendingNonce] = await Promise.all([
    publicClient.getTransactionCount({ address: keeper, blockTag: "latest" }),
    publicClient.getTransactionCount({ address: keeper, blockTag: "pending" }),
  ]);
  if (ownTransactionPending(latestNonce, pendingNonce)) {
    return { outcome: "stop", detail: "an earlier transaction of this keeper is still pending; nothing sent" };
  }

  const hash = await walletClient.writeContract({
    address: rebalancer,
    abi,
    functionName: "execute",
    args: [owner, demanded],
    gas: gasLimit,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: txWaitSeconds * 1000 });
  if (receipt.status === "success") return { outcome: "executed", detail: `${label}: ${hash}` };

  // Reverted on chain. Ask the node why, on the state after that block: usually the price moved past `minAmountOut`.
  const resimulate = (gas?: bigint) =>
    publicClient.simulateContract({
      address: rebalancer,
      abi,
      functionName: "execute",
      args: [owner, demanded],
      account: keeper,
      blockNumber: receipt.blockNumber,
      gas,
    });
  try {
    await resimulate();
  } catch (error) {
    const action = failureAction(failureOf(error));
    return { outcome: action === "skip" ? "skipped" : action, detail: `${label}: ${hash} reverted: ${describeError(error)}` };
  }
  // It passes without a gas limit. If it fails with the limit of the transaction, the run needs more gas than
  // GAS_LIMIT. That does not go away by itself, and every attempt costs a transaction.
  try {
    await resimulate(gasLimit);
  } catch {
    return { outcome: "cooldown", detail: `${label}: ${hash} ran out of gas (GAS_LIMIT ${gasLimit}); raise GAS_LIMIT` };
  }
  return { outcome: "skipped", detail: `${label}: ${hash} reverted, a new simulation passes; next run` };
};

// ─── Main ──────────────────────────────────────────────────────────────────────────────────────────────────────

const main = async (): Promise<void> => {
  console.log(`keeper ${keeper} on ${rebalancer} via ${maskRpcUrl(rpcUrl)}${dryRun ? " (dry run)" : ""}`);
  if (await publicClient.readContract({ address: rebalancer, abi, functionName: "retired" })) {
    console.log("The contract has been retired; there is nothing left to run.");
    return;
  }

  // One block for the whole run: the search ends there, and the owners it found are read there.
  const latest = await publicClient.getBlockNumber();
  const found = await findOwners(latest);
  const owners = mergeOwners(listedOwners, found?.owners ?? []);
  const { due, gone } = await readDue(owners, latest);
  if (!dryRun && found !== undefined && gone.length > 0) {
    writeFileSync(ownersStateFile, formatOwnersState(withoutOwners(found, gone)));
  }
  console.log(`${owners.length} owners known, ${gone.length} no longer name this keeper, ${due.length} due`);

  const counts = { executed: 0, simulated: 0, skipped: 0, cooldown: 0 };
  try {
    for (const item of due) {
      if (isCoolingDown(cooldowns, item.owner, nowSec())) {
        console.log(`${item.owner}: cooling down after ${cooldowns[item.owner.toLowerCase()].failures} failures`);
        continue;
      }
      const { outcome, detail } = await run(item);
      console.log(`${item.owner}: ${outcome}: ${detail}`);
      if (outcome === "stop") break;
      counts[outcome]++;
      if (outcome === "executed") cooldowns = clearFailure(cooldowns, item.owner);
      if (outcome === "cooldown") cooldowns = recordFailure(cooldowns, item.owner, nowSec(), detail, cooldownPolicy);
    }
  } finally {
    saveCooldowns();
  }
  console.log(
    `Done: ${counts.executed} executed, ${counts.simulated} simulated, ${counts.skipped} skipped, ${counts.cooldown} put on cool-down.`,
  );
};

try {
  await main();
} catch (error) {
  console.error(`keeper run failed: ${describeError(error)}`);
  process.exitCode = 1;
}
