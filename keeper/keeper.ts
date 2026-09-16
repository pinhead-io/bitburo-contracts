/**
 * Bitburo keeper-script. Iedereen mag dit draaien; Bitburo is niet nodig.
 *
 * Leest het register van het Rebalancer-contract (owners), filtert het off-chain op actief, saldo en allowance, vraagt
 * voor de overgebleven kandidaten isDue(owner) in porties van PAGE_SIZE (één Multicall3 per portie), slaat runs onder
 * MIN_RUN_EURC over (de fee dekt de gas dan niet), simuleert execute(owner, rewardTo)
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
 * - Na een eigen transactie wacht het script op een nieuw blok voordat het de volgende owner of portie leest of
 *   simuleert.
 *
 * Runs tegenhouden (audit L-3): wie een pool in elk blok aanraakt (een burn van 1 liquiditeit kost ~92.630 gas), houdt
 * alle runs in dat blok tegen. Daartegen:
 * - Lezen en simuleren alsof het het volgende blok is: isDue en de simulatie van execute gaan als eth_call
 *   met blok-overrides (nummer + 1, timestamp + 2 s) op de state van het laatste blok. Een aanraking in het laatste
 *   blok is dan geen reden meer om niets te versturen. Eén keer per run controleert het script met een kleine probe
 *   of de node de overrides toepast; zo niet, dan valt het terug op het laatste blok (en leest het elke portie
 *   minstens twee keer, in opeenvolgende blokken, hooguit BLOCK_RETRIES + 1 keer) en logt het dat.
 * - Het hele retry-budget blijven proberen, niet een paar blokken: anders hoeft een aanvaller alleen een voorspelbaar
 *   venster af te dekken.
 * - Versturen met een expliciete priority fee (PRIORITY_FEE_GWEI, standaard 0,05 gwei), zodat de transactie in de
 *   Flashblock vóór een aanraker met een lagere tip staat. Revert een transactie on-chain door een tijdelijke oorzaak
 *   (een blokkade), dan verstuurt het script pas na een willekeurig aantal blokken opnieuw (gemiddeld
 *   SEND_RETRY_BLOCKS, zodat een aanvaller het moment niet kan voorspellen), met minstens het dubbele
 *   van de vorige tip en minstens 10% boven de hoogste tip van wie de pool eerder in dat blok aanraakte, tot
 *   MAX_PRIORITY_FEE_GWEI (standaard 3 gwei). De verhoogde tip wordt bewaard in FEE_STATE_FILE en geldt zolang de
 *   laatste blokkade minder dan FEE_HOLD_SECONDS (standaard 3600) geleden is. Een revert telt alleen als blokkade als
 *   een hersimulatie op het begin van het blok slaagt (of op het blokvenster stuit) én een transactie vóór de eigen
 *   transactie een pool aanraakte (Swap, Mint of Burn).
 * - Eén run tegelijk (LOCK_FILE), en de run leest na het retry-budget geen nieuwe kandidaten meer.
 *
 * Registratiespam (audit lead 9): iedereen kan zich registreren, ook zonder saldo, en het register krimpt nooit. Het
 * script leest daarom per 500 owners in één Multicall3 per 100 owners `params(owner).active` en saldo en allowance van
 * EURC en cbBTC, en houdt alleen owners over die in minstens één richting een run van max(MIN_TRADE_FLOOR,
 * MIN_RUN_EURC) kunnen halen: min(saldo, allowance) van EURC, of van cbBTC tegen quote(). Dat is een noodzakelijke
 * voorwaarde van het contract, dus er valt geen owner af die anders uitgevoerd zou worden. Wie het script wil
 * ophouden, moet per adres dat bedrag met allowance aanhouden. Het filter draait één keer per run; wie tijdens de run
 * stort, komt de volgende run aan de beurt.
 *
 * Grote correcties gaan in delen die 10 minuten na elkaar mogen. Draai dit script daarom elke 10 minuten.
 *
 * Gebruik:
 *   RPC_URL=https://mainnet.base.org REBALANCER=0x… KEEPER_PRIVATE_KEY=0x… bun run keeper.ts
 * Optioneel: REWARD_TO=0x…  PAGE_SIZE=20  DRY_RUN=1  MIN_RUN_EURC=20  BLOCK_RETRIES=3  BLOCK_WAIT_SECONDS=30
 *            RETRY_SECONDS=540  SEND_RETRY_BLOCKS=30  PRIORITY_FEE_GWEI=0.05  MAX_PRIORITY_FEE_GWEI=3
 *            GAS_LIMIT=1000000  FEE_STATE_FILE=./keeper-fee.json  FEE_HOLD_SECONDS=3600  LOCK_FILE=./keeper.lock
 *            COOLDOWN_FILE=./keeper-cooldowns.json  COOLDOWN_SECONDS=3600  COOLDOWN_MAX_SECONDS=86400
 */
import { closeSync, existsSync, openSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
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
  WaitForTransactionReceiptTimeoutError,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import {
  type BlockOverrides,
  type CooldownState,
  type FeeState,
  type Resimulation,
  type OwnerFunds,
  OVERRIDE_PROBE_CODE,
  blockerTip,
  chunks,
  clearFailure,
  cooldownUntil,
  effectiveTip,
  failureAction,
  filterCandidates,
  formatEurc,
  formatGwei,
  isBlockWindowRevert,
  isCoolingDown,
  maxFeePerGas,
  minRunBaseUnits,
  newOwners,
  nextAttemptBlock,
  nextBlockOverrides,
  nextSendBlock,
  onchainRevertVerdict,
  parseFeeState,
  nextPriorityFee,
  overridesApplied,
  parseCooldownState,
  parseGwei,
  pruneExpired,
  recordFailure,
  retryDeadline,
  runSizeSkipReason,
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

/** Pool-events die een observatie kunnen schrijven of de koers verschuiven (Uniswap v3). Collect en Flash tellen niet. */
const poolEvents = parseAbi([
  "event Swap(address indexed sender, address indexed recipient, int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick)",
  "event Mint(address sender, address indexed owner, int24 indexed tickLower, int24 indexed tickUpper, uint128 amount, uint256 amount0, uint256 amount1)",
  "event Burn(address indexed owner, int24 indexed tickLower, int24 indexed tickUpper, uint128 amount, uint256 amount0, uint256 amount1)",
]);

const env = (name: string, fallback?: string): string => {
  const value = process.env[name] ?? fallback;
  if (value === undefined) throw new Error(`${name} ontbreekt`);
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
const sendRetryBlocks = Number(env("SEND_RETRY_BLOCKS", "30"));
const gasLimit = BigInt(env("GAS_LIMIT", "1000000"));
const feePolicy = {
  base: parseGwei(env("PRIORITY_FEE_GWEI", "0.05")),
  max: parseGwei(env("MAX_PRIORITY_FEE_GWEI", "3")),
};
const cooldownFile = env("COOLDOWN_FILE", "./keeper-cooldowns.json");
const feeStateFile = env("FEE_STATE_FILE", "./keeper-fee.json");
const feeHoldSeconds = Number(env("FEE_HOLD_SECONDS", "3600"));
const lockFile = env("LOCK_FILE", "./keeper.lock");
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
if (!Number.isFinite(feeHoldSeconds) || feeHoldSeconds < 0) throw new Error("FEE_HOLD_SECONDS moet een getal >= 0 zijn");

/**
 * Eén run tegelijk: twee runs zouden om dezelfde nonce en hetzelfde cool-down-bestand vechten. Het lock-bestand bevat
 * de pid; een lock van een proces dat niet meer bestaat, wordt opgeruimd.
 */
const acquireLock = (): boolean => {
  if (existsSync(lockFile)) {
    const pid = Number(readFileSync(lockFile, "utf8").trim());
    let alive = false;
    try {
      if (Number.isInteger(pid) && pid > 0) {
        process.kill(pid, 0);
        alive = true;
      }
    } catch {
      alive = false;
    }
    if (alive) return false;
    unlinkSync(lockFile);
  }
  const fd = openSync(lockFile, "wx");
  writeFileSync(fd, `${process.pid}\n`);
  closeSync(fd);
  return true;
};
if (!acquireLock()) {
  console.warn(`Een andere keeper-run loopt nog (${lockFile}); deze run stopt.`);
  process.exit(0);
}
process.on("exit", () => {
  try {
    if (readFileSync(lockFile, "utf8").trim() === String(process.pid)) unlinkSync(lockFile);
  } catch {
    // al weg
  }
});

const publicClient = createPublicClient({ chain: base, transport: http(rpcUrl) });
const account = dryRun ? undefined : privateKeyToAccount(env("KEEPER_PRIVATE_KEY") as Hex);
const rewardTo = (process.env.REWARD_TO ?? account?.address ?? "0x0000000000000000000000000000000000000000") as Address;
const walletClient = account ? createWalletClient({ account, chain: base, transport: http(rpcUrl) }) : undefined;

const nowSec = () => Math.floor(Date.now() / 1000);
const startSeconds = nowSec();
const deadline = retryDeadline(startSeconds, retrySeconds);

/** Leest de node het volgende blok (blok-overrides)? Eén keer per run gecontroleerd met de probe. */
let readsNextBlock = false;

/**
 * Waarop een lezing draait. Altijd vastgepind op het gelezen blok (`blockNumber`): anders kan de node al een blok verder
 * zijn, en rekent hij met de overrides van het vorige blok op de staat van het nieuwe (dan telt een aanraking in dat
 * nieuwe blok weer mee).
 */
type At = { blockNumber?: bigint; blockOverrides?: BlockOverrides };
const atParams = (at: At) => ({
  ...(at.blockNumber === undefined ? {} : { blockNumber: at.blockNumber }),
  ...(at.blockOverrides === undefined ? {} : { blockOverrides: at.blockOverrides }),
});

/** Lezen op `latest`: vastgepind op dat blok, met de overrides van het volgende blok als de node die toepast. */
const atLatest = (latest: { number: bigint; timestamp: bigint }): At => ({
  blockNumber: latest.number,
  blockOverrides: overridesFor(latest),
});

/** Overrides voor het blok ná `latest`, of undefined bij de terugval op het laatste blok. */
const overridesFor = (latest: { number: bigint; timestamp: bigint }): BlockOverrides | undefined =>
  readsNextBlock ? nextBlockOverrides(latest) : undefined;

const read = <T>(
  functionName:
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
) =>
  publicClient.readContract({
    address: rebalancer,
    abi,
    functionName,
    args,
    ...atParams(at),
    // biome-ignore lint/suspicious/noExplicitAny: viem's ABI-generics zijn te strikt voor een gedeelde helper
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
/** Na een blokkade (eigen transactie on-chain gerevert door een tijdelijke oorzaak): vroegste blok voor een nieuwe send. */
let sendFromBlock: bigint | null = null;
/** Priority fee voor de volgende transactie; loopt op na een blokkade, tot MAX_PRIORITY_FEE_GWEI (`startPriorityFee`). */
const readFeeState = (): FeeState | undefined => {
  try {
    return existsSync(feeStateFile) ? parseFeeState(readFileSync(feeStateFile, "utf8")) : undefined;
  } catch {
    return undefined;
  }
};
let priorityFee = startPriorityFee(readFeeState(), startSeconds, feePolicy, feeHoldSeconds);
const saveFeeState = (blockadeAt: number) =>
  writeFileSync(feeStateFile, `${JSON.stringify({ priorityFeeWei: priorityFee.toString(), lastBlockadeAt: blockadeAt }, null, 2)}\n`);

let pools: readonly Address[] | undefined;

/**
 * Transacties die vóór de eigen transactie in dat blok een van beide pools aanraakten (Swap, Mint of Burn), en de
 * hoogste tip daarvan. Bij een leesfout: `touched` onbekend (false) en geen tip; dan loopt de fee niet op.
 */
const blockersOf = async (receipt: TransactionReceipt): Promise<{ touched: boolean; tip: bigint | undefined }> => {
  try {
    pools ??= [await read<Address>("POOL_EURC_USDC"), await read<Address>("POOL_USDC_CBBTC")];
    const [block, logs] = await Promise.all([
      publicClient.getBlock({ blockHash: receipt.blockHash }),
      publicClient.getLogs({ address: [...pools], events: poolEvents, blockHash: receipt.blockHash }),
    ]);
    const hashes = [
      ...new Set(logs.filter((log) => (log.transactionIndex ?? Infinity) < receipt.transactionIndex).map((log) => log.transactionHash)),
    ].filter((hash): hash is Hex => hash !== null);
    const txs = await Promise.all(hashes.map((hash) => publicClient.getTransaction({ hash })));
    const tip = blockerTip(
      txs.map((tx) => ({ transactionIndex: tx.transactionIndex ?? Infinity, tip: effectiveTip(tx, block.baseFeePerGas ?? 0n) })),
      receipt.transactionIndex,
    );
    return { touched: hashes.length > 0, tip };
  } catch (error) {
    console.warn(`aanrakers in blok ${receipt.blockNumber} niet te lezen: ${describeError(error)}`);
    return { touched: false, tip: undefined };
  }
};

/**
 * Hersimuleer een on-chain gerevert `execute` op de staat aan het begin van het blok van de transactie: het vorige blok,
 * met de overrides van het blok zelf. Zo tellen alleen transacties vóór de eigen transactie, niet een aanraking erna.
 * Zonder override-ondersteuning: op het blok zelf (dan kan een latere aanraking ook meetellen).
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

type Outcome = "executed" | "skipped" | "dry-run" | "retry";

/**
 * Eén poging voor een owner: lezen, simuleren en uitvoeren. "retry" = tijdelijk, opnieuw in een blok ná `block`.
 * `isRetry`: een herhaalde poging, begrensd door het retry-budget.
 */
const attemptOwner = async (owner: Address, retryAfterBlock: bigint | null, isRetry: boolean): Promise<{ outcome: Outcome; block: bigint | null }> => {
  // Na een blokkade pas gemiddeld SEND_RETRY_BLOCKS later opnieuw; simuleren zonder te mogen versturen heeft geen zin.
  const { target, throttled } = nextAttemptBlock(retryAfterBlock, lastRunBlock, dryRun ? null : sendFromBlock);
  if (!(await waitForBlock(target, isRetry || throttled ? deadline : undefined))) {
    console.log(`${owner}: overgeslagen, geen blok ${target} binnen het wachtbudget; geen cool-down`);
    return { outcome: "skipped", block: null };
  }

  const latest = await publicClient.getBlock();
  const at = atLatest(latest);
  const [due, eurcDelta] = await read<readonly [boolean, bigint]>("isDue", [owner], at);
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
  /** Oordeel over de fout, als die niet rechtstreeks uit `failure` volgt (on-chain revert). */
  let verdict: ReturnType<typeof onchainRevertVerdict>["failure"] | undefined;
  let simulated = false;
  try {
    await simulateExecute(owner, at);
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
      console.log(`[dry-run] ${owner}: ${direction} ≈ ${eurc} EURC (simulatie ok${at.blockOverrides ? ", volgend blok" : ""})`);
      return { outcome: "dry-run", block: null };
    }
    try {
      // Gas, beide fees, nonce en chainId expliciet: anders schat viem ze zelf. eth_estimateGas draait op het laatste
      // blok (waar een aanraking de schatting laat reverten), een fee-schatting overschrijft de gekozen tip, en zonder
      // nonce probeert viem eerst eth_fillTransaction. GAS_LIMIT 1.000.000 is de grens die
      // test_fork_buyAndSellGasCost bewaakt.
      const nonce = await publicClient.getTransactionCount({ address: walletClient.account.address, blockTag: "pending" });
      const hash = await walletClient.writeContract({
        address: rebalancer,
        abi,
        functionName: "execute",
        args: [owner, rewardTo],
        gas: gasLimit,
        maxPriorityFeePerGas: priorityFee,
        maxFeePerGas: maxFeePerGas(latest.baseFeePerGas ?? 0n, priorityFee),
        nonce,
        // `chainId` staat niet in het type van writeContract, maar gaat via sendTransaction mee naar
        // prepareTransactionRequest; zonder probeert viem eerst eth_fillTransaction (viem 2.56.3).
        ...({ chainId: base.id } as unknown as Record<string, never>),
      });
      let receipt: TransactionReceipt;
      try {
        receipt = await publicClient.waitForTransactionReceipt({ hash });
      } catch (error) {
        if (error instanceof WaitForTransactionReceiptTimeoutError) {
          // De transactie kan nog landen; een volgende send zou achter dezelfde nonce blijven hangen. Geen cool-down,
          // de run stopt.
          saveCooldowns();
          throw new Error(`transactie ${hash} voor ${owner} niet binnen de wachttijd opgenomen; run gestopt`);
        }
        throw error;
      }
      console.log(`${owner}: ${direction} ≈ ${eurc} EURC → ${receipt.status} ${hash} (tip ${formatGwei(priorityFee)} gwei)`);
      lastRunBlock = receipt.blockNumber;
      if (receipt.status === "success") {
        cooldowns = clearFailure(cooldowns, owner);
        saveCooldowns();
        return { outcome: "executed", block: receipt.blockNumber };
      }
      // Gerevert na een geslaagde simulatie: de staat veranderde in de tussentijd. Hersimuleer op het begin van dat
      // blok voor de reden, en kijk wie vóór ons een pool aanraakte.
      failure = new Error(`transactie ${hash} is gerevert`);
      const [resimulation, blockers] = await Promise.all([resimulateAtBlockStart(owner, receipt), blockersOf(receipt)]);
      const judged = onchainRevertVerdict(resimulation, blockers.touched);
      verdict = judged.failure;
      if (resimulation.kind === "reverted") failure = new Error(`transactie ${hash} is gerevert (${resimulation.errorName ?? "revert"})`);
      if (judged.blockade) {
        // Blokkade: een andere transactie raakte vóór ons een pool aan. Hogere tip, en pas gemiddeld SEND_RETRY_BLOCKS later.
        sendFromBlock = nextSendBlock(receipt.blockNumber, sendRetryBlocks, Math.random());
        priorityFee = nextPriorityFee(priorityFee, blockers.tip, feePolicy);
        saveFeeState(nowSec());
        console.warn(
          `${owner}: blokkade in blok ${receipt.blockNumber} (tip aanraker ${blockers.tip === undefined ? "onbekend" : `${formatGwei(blockers.tip)} gwei`}); volgende tip ${formatGwei(priorityFee)} gwei`,
        );
      }
    } catch (error) {
      if (error instanceof Error && error.message.includes("run gestopt")) throw error;
      failure = error;
    }
  }

  // Een fout van de node (geen revert van het contract) zegt niets over de owner: tijdelijk, geen cool-down.
  const judged = verdict ?? { errorName: errorNameOf(failure), transient: revertOf(failure) === undefined };
  const action = failureAction(judged, nowSec(), deadline);
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

/** Owners per `owners(offset, limit)`-lezing en per multicall voor saldo en allowance (5 calls per owner). */
const REGISTER_PAGE = 500n;
const FUNDS_BATCH = 100;

/** Multicall3 over losse contract-calls, één eth_call per portie; een mislukte call geeft undefined. */
const multicallResults = async (
  contracts: readonly { address: Address; functionName: string; args?: readonly unknown[] }[],
  at: At = {},
): Promise<unknown[]> => {
  const results = await publicClient.multicall({
    contracts: contracts.map((c) => ({ abi, ...c })),
    allowFailure: true,
    batchSize: 0,
    ...atParams(at),
    // biome-ignore lint/suspicious/noExplicitAny: gemengde functies in één multicall
  } as any);
  return (results as { status: string; result?: unknown }[]).map((r) => (r.status === "success" ? r.result : undefined));
};

/**
 * Lead 9: alle geregistreerde owners die in minstens één richting een run kunnen halen (`filterCandidates`). Een
 * owner waarvan een lezing mislukt, blijft voorzichtigheidshalve kandidaat. Geeft een lege lijst als de feedkoers niet
 * te lezen is: dan is volgens het contract niemand due.
 */
const findCandidates = async (): Promise<Address[]> => {
  const [eurcToken, cbbtcToken, floor] = await Promise.all([
    read<Address>("EURC"),
    read<Address>("CBBTC"),
    read<bigint>("MIN_TRADE_FLOOR"),
  ]);
  let price: bigint;
  try {
    price = await read<bigint>("quote");
  } catch (error) {
    // Alleen een revert van de feed (storing, verouderd) betekent "niemand due"; een RPC-fout breekt de run af.
    if (revertOf(error) === undefined) throw error;
    console.warn(`feedkoers niet te lezen (${describeError(error)}); niemand due`);
    return [];
  }
  const minRun = minRunBaseUnits(floor, minRunEurc);
  const found: Address[] = [];
  for (let offset = 0n; offset < checked; offset += REGISTER_PAGE) {
    const page = await read<readonly Address[]>("owners", [offset, REGISTER_PAGE]);
    for (const batch of chunks(page, FUNDS_BATCH)) {
      const results = await multicallResults(
        batch.flatMap((owner) => [
          { address: rebalancer, functionName: "params", args: [owner] },
          { address: eurcToken, functionName: "balanceOf", args: [owner] },
          { address: eurcToken, functionName: "allowance", args: [owner, rebalancer] },
          { address: cbbtcToken, functionName: "balanceOf", args: [owner] },
          { address: cbbtcToken, functionName: "allowance", args: [owner, rebalancer] },
        ]),
      );
      const rows: OwnerFunds[] = [];
      batch.forEach((owner, i) => {
        const [params, eurcBalance, eurcAllowance, cbbtcBalance, cbbtcAllowance] = results.slice(i * 5, i * 5 + 5);
        if ([params, eurcBalance, eurcAllowance, cbbtcBalance, cbbtcAllowance].some((r) => r === undefined)) {
          console.warn(`${owner}: saldo of allowance niet te lezen; blijft kandidaat`);
          found.push(owner);
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
      found.push(...filterCandidates(rows, price, minRun));
    }
  }
  return found;
};

/**
 * Welke van deze owners zijn nu due? `isDue` per owner in één multicall. `isDue` revert nooit, dus een mislukte call is
 * een fout van de node (viem vangt die met `allowFailure` ook af): dan breekt de run af in plaats van de owners stil
 * over te slaan.
 */
const dueAmong = async (owners: readonly Address[], at: At): Promise<Address[]> => {
  const results = await multicallResults(
    owners.map((owner) => ({ address: rebalancer, functionName: "isDue", args: [owner] })),
    at,
  );
  if (results.some((r) => r === undefined)) {
    throw new Error("isDue niet te lezen voor een portie kandidaten (fout van de node); run gestopt");
  }
  return owners.filter((_, i) => (results[i] as readonly [boolean, bigint])[0] === true);
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

// Audit lead 9: filter het register eerst off-chain op actief, saldo en allowance (gebundeld met Multicall3), zodat
// lege spam-registraties de run niet ophouden. Alleen de kandidaten krijgen een isDue.
const candidates = await findCandidates();
console.log(`${checked} owners geregistreerd, ${candidates.length} kandidaten na het filter op saldo en allowance`);

for (const [index, batch] of chunks(candidates, Number(pageSize)).entries()) {
  if (nowSec() >= deadline) {
    console.warn(`Retry-budget (${retrySeconds} s) op: ${candidates.length - index * Number(pageSize)} kandidaten niet meer gelezen; de volgende run gaat door.`);
    break;
  }
  let readBlock: bigint | null = null;
  for (let reads = 1; ; reads += 1) {
    // Elke lezing in een blok ná de laatste eigen run en ná de vorige lezing van deze portie.
    const after = readBlock !== null && (lastRunBlock === null || readBlock > lastRunBlock) ? readBlock : lastRunBlock;
    if (!(await waitForBlockAfter(after))) break;
    const latest = await publicClient.getBlock();
    readBlock = latest.number;
    const fresh = newOwners(await dueAmong(batch, atLatest(latest)), handled);

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
