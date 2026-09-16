/**
 * Bitburo keeper-script. Iedereen mag dit draaien; Bitburo is niet nodig.
 *
 * Vraagt het Rebalancer-contract per pagina dueOwners(offset, limit), leest isDue(owner) voor de richting en
 * het bedrag, slaat runs onder MIN_RUN_EURC over (de fee dekt de gas dan niet), simuleert execute(owner, rewardTo)
 * eerst met eth_call en roept het daarna pas echt aan. Een owner waarvan de simulatie of de transactie mislukt
 * krijgt een cool-down (verdubbelt per mislukking) in een klein JSON-bestand, zodat een owner die structureel
 * revert niet elke run opnieuw gas kost. De beloning (0,05 EURC per run) gaat naar REWARD_TO, standaard het
 * eigen adres. Het script beslist niets over bedragen of richting: het contract bepaalt of, wat en hoeveel.
 *
 * Blokcheck en blokvenster (audit M-1, review PR #18): een run mag niet als een pool in hetzelfde blok al een
 * oracle-observatie schreef, en een pool mag binnen één blok maar 6 bp van zijn beginkoers afwijken.
 * - Een revert met PoolTouchedThisBlock of BlockMoveExceeded is tijdelijk: het script probeert die owner in elk nieuw
 *   blok opnieuw, zolang het retry-budget van de run loopt (RETRY_SECONDS), en geeft geen cool-down. Dat geldt ook
 *   voor een transactie die on-chain revertte terwijl een nieuwe simulatie op dat blok slaagt.
 * - Na een geslaagde run wacht het script op een nieuw blok voordat het de volgende owner of pagina leest of
 *   simuleert.
 *
 * Runs tegenhouden (audit L-3): wie een pool in elk blok aanraakt (een burn van 1 liquiditeit kost ~92.630 gas), houdt
 * alle runs in dat blok tegen. Daartegen:
 * - Lezen en simuleren alsof het het volgende blok is: isDue, dueOwners en de simulatie van execute gaan als eth_call
 *   met blok-overrides (nummer + 1, timestamp + 2 s) op de state van het laatste blok. Een aanraking in het laatste
 *   blok is dan geen reden meer om niets te versturen. Eén keer per run controleert het script met een kleine probe
 *   of de node de overrides toepast; zo niet, dan valt het terug op het laatste blok (en leest het elke pagina
 *   minstens twee keer, in opeenvolgende blokken, hooguit BLOCK_RETRIES + 1 keer) en logt het dat.
 * - Het hele retry-budget blijven proberen, niet een paar blokken: anders hoeft een aanvaller alleen een voorspelbaar
 *   venster af te dekken.
 * - Versturen met een expliciete priority fee (PRIORITY_FEE_GWEI, standaard 0,05 gwei), zodat de transactie in de
 *   Flashblock vóór een aanraker met een lagere tip staat. Revert een transactie on-chain door een tijdelijke oorzaak
 *   (een blokkade), dan verstuurt het script pas SEND_RETRY_BLOCKS blokken later opnieuw, met minstens het dubbele
 *   van de vorige tip en minstens 10% boven de hoogste tip van wie de pool eerder in dat blok aanraakte, tot
 *   MAX_PRIORITY_FEE_GWEI (standaard 3 gwei). De verhoogde tip geldt voor de rest van deze run.
 * Grote correcties gaan in delen die 10 minuten na elkaar mogen. Draai dit script daarom elke 10 minuten.
 *
 * Gebruik:
 *   RPC_URL=https://mainnet.base.org REBALANCER=0x… KEEPER_PRIVATE_KEY=0x… bun run keeper.ts
 * Optioneel: REWARD_TO=0x…  PAGE_SIZE=50  DRY_RUN=1  MIN_RUN_EURC=20  BLOCK_RETRIES=3  BLOCK_WAIT_SECONDS=30
 *            RETRY_SECONDS=540  SEND_RETRY_BLOCKS=30  PRIORITY_FEE_GWEI=0.05  MAX_PRIORITY_FEE_GWEI=3
 *            GAS_LIMIT=1000000  COOLDOWN_FILE=./keeper-cooldowns.json  COOLDOWN_SECONDS=3600
 *            COOLDOWN_MAX_SECONDS=86400
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  http,
  isAddress,
  parseAbi,
  type Address,
  type Hex,
  type TransactionReceipt,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import {
  type BlockOverrides,
  type CooldownState,
  OVERRIDE_PROBE_CODE,
  blockerTip,
  clearFailure,
  cooldownUntil,
  effectiveTip,
  failureAction,
  firstSendBlock,
  formatEurc,
  formatGwei,
  isBlockWindowRevert,
  isCoolingDown,
  maxFeePerGas,
  newOwners,
  nextAttemptBlock,
  nextBlockOverrides,
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

const abi = parseAbi([
  "function ownerCount() view returns (uint256)",
  "function dueOwners(uint256 offset, uint256 limit) view returns (address[])",
  "function isDue(address owner) view returns (bool due, int256 eurcDelta)",
  "function execute(address owner, address rewardTo)",
  "function POOL_EURC_USDC() view returns (address)",
  "function POOL_USDC_CBBTC() view returns (address)",
  // Custom errors, zodat viem de revert-reden kan decoderen.
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

const env = (name: string, fallback?: string): string => {
  const value = process.env[name] ?? fallback;
  if (value === undefined) throw new Error(`${name} ontbreekt`);
  return value;
};

const rpcUrl = env("RPC_URL", "https://mainnet.base.org");
const rebalancer = env("REBALANCER") as Address;
const pageSize = BigInt(env("PAGE_SIZE", "50"));
const dryRun = process.env.DRY_RUN === "1";
const minRunEurc = Number(env("MIN_RUN_EURC", "20"));
const blockRetries = Number(env("BLOCK_RETRIES", "3"));
const blockWaitSeconds = Number(env("BLOCK_WAIT_SECONDS", "30"));
const retrySeconds = Number(env("RETRY_SECONDS", "540"));
const sendRetryBlocks = Number(env("SEND_RETRY_BLOCKS", "30"));
const gasLimit = BigInt(env("GAS_LIMIT", "1000000"));
const feePolicy = {
  base: parseGwei(env("PRIORITY_FEE_GWEI", "0.05")),
  max: parseGwei(env("MAX_PRIORITY_FEE_GWEI", "3")),
};
const cooldownFile = env("COOLDOWN_FILE", "./keeper-cooldowns.json");
const cooldownPolicy = {
  baseSeconds: Number(env("COOLDOWN_SECONDS", "3600")),
  maxSeconds: Number(env("COOLDOWN_MAX_SECONDS", "86400")),
};
if (!isAddress(rebalancer)) throw new Error("REBALANCER is geen geldig adres");
if (!Number.isFinite(minRunEurc) || minRunEurc < 0) throw new Error("MIN_RUN_EURC moet een getal >= 0 zijn");
if (!Number.isInteger(blockRetries) || blockRetries < 0) throw new Error("BLOCK_RETRIES moet een geheel getal >= 0 zijn");
if (!Number.isFinite(retrySeconds) || retrySeconds < 0) throw new Error("RETRY_SECONDS moet een getal >= 0 zijn");
if (!Number.isInteger(sendRetryBlocks) || sendRetryBlocks < 1) throw new Error("SEND_RETRY_BLOCKS moet een geheel getal >= 1 zijn");
if (feePolicy.base > feePolicy.max) throw new Error("PRIORITY_FEE_GWEI mag niet boven MAX_PRIORITY_FEE_GWEI liggen");

const publicClient = createPublicClient({ chain: base, transport: http(rpcUrl) });
const account = dryRun ? undefined : privateKeyToAccount(env("KEEPER_PRIVATE_KEY") as Hex);
const rewardTo = (process.env.REWARD_TO ?? account?.address ?? "0x0000000000000000000000000000000000000000") as Address;
const walletClient = account ? createWalletClient({ account, chain: base, transport: http(rpcUrl) }) : undefined;

const nowSec = () => Math.floor(Date.now() / 1000);
const startSeconds = nowSec();
const deadline = retryDeadline(startSeconds, retrySeconds);

/** Leest de node het volgende blok (blok-overrides)? Eén keer per run gecontroleerd met de probe. */
let readsNextBlock = false;

/** Overrides voor het blok ná `latest`, of undefined bij de terugval op het laatste blok. */
const overridesFor = (latest: { number: bigint; timestamp: bigint }): BlockOverrides | undefined =>
  readsNextBlock ? nextBlockOverrides(latest) : undefined;

const read = <T>(
  functionName: "ownerCount" | "dueOwners" | "isDue" | "POOL_EURC_USDC" | "POOL_USDC_CBBTC",
  args: readonly unknown[] = [],
  blockOverrides?: BlockOverrides,
) =>
  publicClient.readContract({
    address: rebalancer,
    abi,
    functionName,
    args,
    ...(blockOverrides === undefined ? {} : { blockOverrides }),
    // biome-ignore lint/suspicious/noExplicitAny: viem's ABI-generics zijn te strikt voor een gedeelde helper
  } as any) as Promise<T>;

const simulateExecute = (owner: Address, at: { blockNumber?: bigint; blockOverrides?: BlockOverrides } = {}) =>
  publicClient.simulateContract({
    address: rebalancer,
    abi,
    functionName: "execute",
    args: [owner, rewardTo],
    account,
    ...(at.blockNumber === undefined ? {} : { blockNumber: at.blockNumber }),
    ...(at.blockOverrides === undefined ? {} : { blockOverrides: at.blockOverrides }),
  });

const revertOf = (error: unknown): ContractFunctionRevertedError | undefined => {
  if (!(error instanceof BaseError)) return undefined;
  const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
  return reverted instanceof ContractFunctionRevertedError ? reverted : undefined;
};

/** Naam van de contract-error (bijvoorbeeld "BlockMoveExceeded"), als viem die kon decoderen. */
const errorNameOf = (error: unknown): string | undefined => revertOf(error)?.data?.errorName;

/** Eerste regel van een viem-fout, met de contract-error als die er is (bijvoorbeeld NotDue()). */
const describeError = (error: unknown): string => {
  const reverted = revertOf(error);
  if (reverted?.data?.errorName) {
    return `${reverted.data.errorName}(${(reverted.data.args ?? []).join(", ")})`;
  }
  if (error instanceof BaseError) return error.shortMessage;
  return (error as Error).message.split("\n")[0];
};

/**
 * Wacht tot het laatste blok minstens `target` is (Base: ~2 s per blok). Geeft false als de chain
 * BLOCK_WAIT_SECONDS lang geen nieuw blok maakt, of als `until` (unix-seconden) verstreken is.
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

/** Wacht tot er een blok ná `block` is. */
const waitForBlockAfter = (block: bigint | null, until?: number): Promise<boolean> =>
  waitForBlock(block === null ? null : block + 1n, until);

/** Controleer één keer per run of de node blok-overrides toepast (probe die timestamp en bloknummer teruggeeft). */
const probeOverrides = async (): Promise<boolean> => {
  try {
    const latest = await publicClient.getBlock();
    const overrides = nextBlockOverrides(latest);
    const { data } = await publicClient.call({ data: OVERRIDE_PROBE_CODE, blockOverrides: overrides });
    return overridesApplied(data, overrides);
  } catch (error) {
    console.warn(`probe voor blok-overrides mislukt: ${describeError(error)}`);
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
  console.error(`${owner}: ${message}; cool-down tot ${new Date(entry.until * 1000).toISOString()} (mislukking ${entry.failures})`);
};

/** Blok van de laatste eigen transactie in deze keeper-run; de volgende owner pas in een later blok. */
let lastRunBlock: bigint | null = null;
/** Blok van de laatste blokkade (eigen transactie on-chain gerevert door een tijdelijke oorzaak). */
let lastBlockadeBlock: bigint | null = null;
/** Priority fee voor de volgende transactie; loopt op na een blokkade, tot MAX_PRIORITY_FEE_GWEI. */
let priorityFee = feePolicy.base;

let pools: readonly Address[] | undefined;

/**
 * Hoogste tip van de transacties die vóór de eigen transactie in dat blok een van beide pools aanraakten (logs van de
 * pool). Best effort: bij een leesfout undefined, en dan verdubbelt alleen de eigen tip.
 */
const blockerTipOf = async (receipt: TransactionReceipt): Promise<bigint | undefined> => {
  try {
    pools ??= [await read<Address>("POOL_EURC_USDC"), await read<Address>("POOL_USDC_CBBTC")];
    const [block, logs] = await Promise.all([
      publicClient.getBlock({ blockHash: receipt.blockHash }),
      publicClient.getLogs({ address: [...pools], blockHash: receipt.blockHash }),
    ]);
    const hashes = [
      ...new Set(logs.filter((log) => (log.transactionIndex ?? Infinity) < receipt.transactionIndex).map((log) => log.transactionHash)),
    ].filter((hash): hash is Hex => hash !== null);
    const txs = await Promise.all(hashes.map((hash) => publicClient.getTransaction({ hash })));
    return blockerTip(
      txs.map((tx) => ({ transactionIndex: tx.transactionIndex ?? Infinity, tip: effectiveTip(tx, block.baseFeePerGas ?? 0n) })),
      receipt.transactionIndex,
    );
  } catch (error) {
    console.warn(`tip van de aanraker niet te lezen: ${describeError(error)}`);
    return undefined;
  }
};

type Outcome = "executed" | "skipped" | "dry-run" | "retry";

/**
 * Eén poging voor een owner: lezen, simuleren en uitvoeren. "retry" = tijdelijk, opnieuw in een blok ná `block`.
 * `isRetry`: een herhaalde poging, begrensd door het retry-budget.
 */
const attemptOwner = async (owner: Address, retryAfterBlock: bigint | null, isRetry: boolean): Promise<{ outcome: Outcome; block: bigint | null }> => {
  // Na een blokkade pas SEND_RETRY_BLOCKS later opnieuw; simuleren zonder te mogen versturen heeft geen zin.
  const { target, throttled } = nextAttemptBlock(retryAfterBlock, lastRunBlock, dryRun ? null : firstSendBlock(lastBlockadeBlock, sendRetryBlocks));
  if (!(await waitForBlock(target, isRetry || throttled ? deadline : undefined))) {
    console.log(`${owner}: overgeslagen, geen blok ${target} binnen het wachtbudget; geen cool-down`);
    return { outcome: "skipped", block: null };
  }

  const latest = await publicClient.getBlock();
  const blockOverrides = overridesFor(latest);
  const [due, eurcDelta] = await read<readonly [boolean, bigint]>("isDue", [owner], blockOverrides);
  const direction = eurcDelta > 0n ? "koop" : "verkoop";
  const eurc = formatEurc(eurcDelta < 0n ? -eurcDelta : eurcDelta);
  if (due) {
    const sizeReason = runSizeSkipReason(eurcDelta, minRunEurc);
    if (sizeReason !== null) {
      console.log(`${owner}: overgeslagen, ${sizeReason}`);
      return { outcome: "skipped", block: null };
    }
  }

  // Eerst simuleren: een owner die revert (dust dat op de route naar 0 afrondt, blacklist, te krappe
  // slippage) blijft in dueOwners staan en zou anders elke run ~160k gas kosten zonder beloning. Ook als isDue
  // false zegt: dat kan een vol blokvenster zijn, en alleen de simulatie geeft de reden.
  let failure: unknown;
  let simulated = false;
  let resimulationPassed = false;
  try {
    await simulateExecute(owner, { blockOverrides });
    simulated = true;
  } catch (error) {
    failure = error;
  }

  if (!due && !isBlockWindowRevert(errorNameOf(failure))) {
    console.log(`${owner}: niet meer due${failure === undefined ? "" : ` (${describeError(failure)})`}`);
    return { outcome: "skipped", block: null };
  }

  if (simulated) {
    if (dryRun || !walletClient) {
      console.log(`[dry-run] ${owner}: ${direction} ≈ ${eurc} EURC (simulatie ok${blockOverrides ? ", volgend blok" : ""})`);
      return { outcome: "dry-run", block: null };
    }
    try {
      // Gas en beide fees expliciet: anders schat viem ze zelf, en eth_estimateGas draait op het laatste blok (waar
      // een aanraking de schatting laat reverten) en zou de gekozen tip overschrijven. GAS_LIMIT 1.000.000 is de
      // grens die test_fork_buyAndSellGasCost bewaakt.
      const hash = await walletClient.writeContract({
        address: rebalancer,
        abi,
        functionName: "execute",
        args: [owner, rewardTo],
        gas: gasLimit,
        maxPriorityFeePerGas: priorityFee,
        maxFeePerGas: maxFeePerGas(latest.baseFeePerGas ?? 0n, priorityFee),
      });
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      console.log(`${owner}: ${direction} ≈ ${eurc} EURC → ${receipt.status} ${hash} (tip ${formatGwei(priorityFee)} gwei)`);
      lastRunBlock = receipt.blockNumber;
      if (receipt.status === "success") {
        cooldowns = clearFailure(cooldowns, owner);
        saveCooldowns();
        return { outcome: "executed", block: receipt.blockNumber };
      }
      // Gerevert na een geslaagde simulatie: de staat veranderde in de tussentijd. Simuleer op het blok van de
      // transactie opnieuw voor de reden (bijvoorbeeld iemand die eerder in het blok de pool aanraakte).
      failure = new Error(`transactie ${hash} is gerevert`);
      try {
        await simulateExecute(owner, { blockNumber: receipt.blockNumber });
        // Slaagt nu wel: de revert kwam door een tijdelijke stand eerder in dat blok, niet door de owner.
        resimulationPassed = true;
      } catch (error) {
        if (errorNameOf(error) !== undefined) failure = error;
      }
      if (resimulationPassed || isBlockWindowRevert(errorNameOf(failure))) {
        // Blokkade: een andere transactie stond vóór ons in het blok. Hogere tip, en pas SEND_RETRY_BLOCKS later.
        lastBlockadeBlock = receipt.blockNumber;
        const tip = await blockerTipOf(receipt);
        priorityFee = nextPriorityFee(priorityFee, tip, feePolicy);
        console.warn(
          `${owner}: blokkade in blok ${receipt.blockNumber} (${describeError(failure)}; tip aanraker ${tip === undefined ? "onbekend" : `${formatGwei(tip)} gwei`}); volgende tip ${formatGwei(priorityFee)} gwei`,
        );
      }
    } catch (error) {
      failure = error;
    }
  }

  const action = failureAction({ errorName: errorNameOf(failure), resimulationPassed }, nowSec(), deadline);
  if (action === "fail") {
    failed(owner, failure);
    return { outcome: "skipped", block: null };
  }
  if (action === "skip") {
    console.log(`${owner}: ${describeError(failure)}, retry-budget (${retrySeconds} s) op; geen cool-down`);
    return { outcome: "skipped", block: null };
  }
  console.log(`${owner}: ${describeError(failure)}; opnieuw in een volgend blok`);
  return { outcome: "retry", block: lastRunBlock !== null && lastRunBlock > latest.number ? lastRunBlock : latest.number };
};

readsNextBlock = await probeOverrides();
if (!readsNextBlock) {
  console.warn(
    "De node past blok-overrides niet toe: terugval op het laatste blok. Een aanraking van een pool in het laatste blok laat owners dan niet due lijken (audit L-3).",
  );
}

const checked = await read<bigint>("ownerCount");
let executed = 0;
let skipped = 0;
/** Owners die deze run al behandeld zijn (uitgevoerd, overgeslagen of mislukt); die worden niet opnieuw geprobeerd. */
const handled = new Set<string>();
/** Owners met een tijdelijke revert, om de beurt opnieuw geprobeerd tot het retry-budget op is. */
const retryQueue: { owner: Address; block: bigint | null }[] = [];

const count = (owner: Address, result: { outcome: Outcome; block: bigint | null }) => {
  if (result.outcome === "executed") executed += 1;
  if (result.outcome === "skipped") skipped += 1;
  if (result.outcome === "retry") retryQueue.push({ owner, block: result.block });
};

for (let offset = 0n; offset < checked; offset += pageSize) {
  let readBlock: bigint | null = null;
  for (let reads = 1; ; reads += 1) {
    // Elke lezing in een blok ná de laatste eigen run en ná de vorige lezing van deze pagina.
    const after = readBlock !== null && (lastRunBlock === null || readBlock > lastRunBlock) ? readBlock : lastRunBlock;
    if (!(await waitForBlockAfter(after))) break;
    const latest = await publicClient.getBlock();
    readBlock = latest.number;
    const fresh = newOwners(await read<readonly Address[]>("dueOwners", [offset, pageSize], overridesFor(latest)), handled);

    for (const owner of fresh) {
      handled.add(owner.toLowerCase());
      if (isCoolingDown(cooldowns, owner, nowSeconds)) {
        console.log(`${owner}: overgeslagen, cool-down tot ${new Date((cooldownUntil(cooldowns, owner) ?? 0) * 1000).toISOString()}`);
        skipped += 1;
        continue;
      }
      count(owner, await attemptOwner(owner, null, false));
    }
    if (!shouldReadPageAgain(fresh.length, reads, blockRetries + 1, readsNextBlock)) break;
  }
}

// Tijdelijk geblokkeerde owners om de beurt, elk in een nieuw blok, tot ze lukken of het retry-budget op is.
while (retryQueue.length > 0) {
  const next = retryQueue.shift();
  if (next === undefined) break;
  count(next.owner, await attemptOwner(next.owner, next.block, true));
}

saveCooldowns();
console.log(`Klaar: ${checked} owners gecontroleerd, ${executed} uitgevoerd, ${skipped} overgeslagen${dryRun ? " (dry-run)" : ""}.`);
