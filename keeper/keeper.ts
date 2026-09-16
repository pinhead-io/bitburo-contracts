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
 *   MAX_PRIORITY_FEE_GWEI (standaard 3 gwei) en het plafond uit wat een run oplevert (`capFeePolicy`: tip × GAS_ESTIMATE
 *   ≤ TIP_REWARD_SHARE_BPS van de beloning + TIP_BUDGET_ETH). De verhoogde tip wordt bewaard in FEE_STATE_FILE en geldt
 *   zolang de laatste blokkade minder dan FEE_HOLD_SECONDS (standaard 3600) geleden is. Een revert telt alleen als
 *   blokkade als een hersimulatie op het begin van het blok slaagt (of op het blokvenster stuit) én een transactie vóór
 *   de eigen transactie een pool aanraakte (Swap, Mint of Burn) die zelf geen directe `execute` op de Rebalancer was.
 * - Concurrerende keepers (eindreview F-1): staat vóór de eigen gerevertte transactie een `Executed` voor dezelfde
 *   owner, dan is die owner bediend: geen blokkade, geen cool-down, geen hogere tip. Na een eigen transactie zonder
 *   blokkade, en aan het eind van een run zonder blokkade en zonder eigen transactie, halveert de tip tot de basis.
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
 * Eindreview F-2: met genoeg lege registraties kostte alleen dat lezen het hele retry-budget, elke run weer vanaf 0.
 * - Het zoeken heeft een eigen tijdsgrens, SEARCH_SECONDS (standaard 180) na de start, binnen het retry-budget: daarna
 *   blijft er tijd over voor isDue en execute.
 * - Het register wordt niet meer altijd vanaf 0 gelezen: de volgende run begint waar deze stopte (SCAN_STATE_FILE),
 *   en loopt na het eind door vanaf 0. Stopt een run met gevonden maar ongelezen kandidaten, dan begint de volgende
 *   bij de eerste daarvan.
 * - Een fout van de node bij een portie (owners, saldo en allowance, isDue) slaat alleen die portie over, met een log.
 * - OWNERS_FILE (optioneel): adressen die elke run eerst worden bediend, vóór het register.
 *
 * Grote correcties gaan in delen die 10 minuten na elkaar mogen. Draai dit script daarom elke 10 minuten.
 *
 * Gebruik:
 *   RPC_URL=https://mainnet.base.org REBALANCER=0x… KEEPER_PRIVATE_KEY=0x… bun run keeper.ts
 * Optioneel: REWARD_TO=0x…  PAGE_SIZE=20  DRY_RUN=1  MIN_RUN_EURC=20  BLOCK_RETRIES=3  BLOCK_WAIT_SECONDS=30
 *            RETRY_SECONDS=540  SEND_RETRY_BLOCKS=30  PRIORITY_FEE_GWEI=0.05  MAX_PRIORITY_FEE_GWEI=3
 *            GAS_LIMIT=1000000  FEE_STATE_FILE=./keeper-fee.json  FEE_HOLD_SECONDS=3600  LOCK_FILE=./keeper.lock
 *            LOCK_MAX_SECONDS=900  TX_WAIT_BLOCKS=15  TX_REPLACEMENTS=3
 *            GAS_ESTIMATE=500000  TIP_REWARD_SHARE_BPS=10000  TIP_BUDGET_ETH=0.0015
 *            FEED_ETH_USD=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
 *            SEARCH_SECONDS=180  SCAN_STATE_FILE=./keeper-scan.json  OWNERS_FILE=./owners.txt
 *            COOLDOWN_FILE=./keeper-cooldowns.json  COOLDOWN_SECONDS=3600  COOLDOWN_MAX_SECONDS=86400
 */
import { closeSync, existsSync, openSync, readFileSync, statSync, unlinkSync, writeFileSync } from "node:fs";
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
  formatEurc,
  formatGwei,
  formatLock,
  isBlockWindowRevert,
  isCoolingDown,
  isStuck,
  lockIsStale,
  lockWatchdogSeconds,
  maxFeePerGas,
  minRunBaseUnits,
  newOwners,
  nextAttemptBlock,
  nextScanOffset,
  nextBlockOverrides,
  nextSendBlock,
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
  replacementFees,
  retryDeadline,
  rewardToError,
  runSizeSkipReason,
  scanSegments,
  servedBefore,
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

/** `Executed` van de Rebalancer: welke owner in welk blok al bediend is (eindreview F-1). */
const executedEvent = parseAbi([
  "event Executed(address indexed owner, bool isBuy, uint256 amountIn, uint256 fee, uint256 reward, address rewardTo, uint256 amountOut, uint256 priceEurcPerBtc, uint256 totalValueEurc, uint256 fractionBps)",
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
if (!isAddress(rebalancer)) throw new Error("REBALANCER is geen geldig adres");
if (!Number.isFinite(minRunEurc) || minRunEurc < 0) throw new Error("MIN_RUN_EURC moet een getal >= 0 zijn");
if (!Number.isInteger(blockRetries) || blockRetries < 0) throw new Error("BLOCK_RETRIES moet een geheel getal >= 0 zijn");
if (!Number.isFinite(retrySeconds) || retrySeconds < 0) throw new Error("RETRY_SECONDS moet een getal >= 0 zijn");
if (!Number.isFinite(searchSeconds) || searchSeconds < 0 || searchSeconds > retrySeconds) {
  throw new Error("SEARCH_SECONDS moet een getal tussen 0 en RETRY_SECONDS zijn");
}
/** Eindreview F-2: adressen die elke run eerst worden bediend. Een ongeldig bestand stopt de run vóór er iets gebeurt. */
const priorityOwners: Address[] = ownersFile === undefined || ownersFile === "" ? [] : parseOwnersFile(readFileSync(ownersFile, "utf8"));
if (!Number.isInteger(sendRetryBlocks) || sendRetryBlocks < 1) throw new Error("SEND_RETRY_BLOCKS moet een geheel getal >= 1 zijn");
if (!Number.isInteger(txWaitBlocks) || txWaitBlocks < 1) throw new Error("TX_WAIT_BLOCKS moet een geheel getal >= 1 zijn");
if (!Number.isInteger(txReplacements) || txReplacements < 0) throw new Error("TX_REPLACEMENTS moet een geheel getal >= 0 zijn");
if (configuredFeePolicy.base > configuredFeePolicy.max) throw new Error("PRIORITY_FEE_GWEI mag niet boven MAX_PRIORITY_FEE_GWEI liggen");
if (gasEstimate <= 0n) throw new Error("GAS_ESTIMATE moet een geheel getal > 0 zijn");
if (tipRewardShareBps < 0n) throw new Error("TIP_REWARD_SHARE_BPS moet >= 0 zijn");
if (tipBudgetWei < 0n) throw new Error("TIP_BUDGET_ETH moet >= 0 zijn");
if (!isAddress(feedEthUsd)) throw new Error("FEED_ETH_USD is geen geldig adres");
if (!Number.isFinite(feeHoldSeconds) || feeHoldSeconds < 0) throw new Error("FEE_HOLD_SECONDS moet een getal >= 0 zijn");
if (!Number.isFinite(lockMaxSeconds) || lockMaxSeconds < retrySeconds + 60) {
  throw new Error("LOCK_MAX_SECONDS moet minstens RETRY_SECONDS + 60 zijn");
}

/**
 * Eén run tegelijk: twee runs zouden om dezelfde nonce en hetzelfde cool-down-bestand vechten. Het lock-bestand bevat
 * pid en starttijd (eindreview I-5). Een lock is verlopen als de pid niet meer bestaat, of als het ouder is dan
 * LOCK_MAX_SECONDS (standaard 900), ook als de pid inmiddels van een ander proces is. Dat laatste is veilig omdat deze
 * run zichzelf 15 s vóór die leeftijd stopt (watchdog hieronder).
 */
const lockStartedAt = Math.floor(Date.now() / 1000);
const pidAlive = (pid: number): boolean => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM: het proces bestaat, maar is van een andere gebruiker.
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
};
const acquireLock = (): boolean => {
  if (existsSync(lockFile)) {
    const lock = parseLock(readFileSync(lockFile, "utf8"), Math.floor(statSync(lockFile).mtimeMs / 1000));
    if (!lockIsStale(lock, lockStartedAt, lockMaxSeconds, pidAlive)) return false;
    console.warn(`verlopen lock opgeruimd (pid ${lock.pid}, ${lockStartedAt - lock.startedAt} s oud)`);
    unlinkSync(lockFile);
  }
  const fd = openSync(lockFile, "wx");
  writeFileSync(fd, formatLock({ pid: process.pid, startedAt: lockStartedAt }));
  closeSync(fd);
  return true;
};
if (!acquireLock()) {
  console.warn(`Een andere keeper-run loopt nog (${lockFile}); deze run stopt.`);
  process.exit(0);
}
process.on("exit", () => {
  try {
    if (parseLock(readFileSync(lockFile, "utf8"), 0).pid === process.pid) unlinkSync(lockFile);
  } catch {
    // al weg
  }
});
// Eindreview I-5: een run die blijft hangen, stopt zichzelf voordat zijn lock verloopt.
setTimeout(() => {
  console.error(`run loopt langer dan ${lockWatchdogSeconds(lockMaxSeconds)} s (LOCK_MAX_SECONDS ${lockMaxSeconds}); gestopt`);
  process.exit(1);
}, lockWatchdogSeconds(lockMaxSeconds) * 1000).unref();

const publicClient = createPublicClient({ chain: base, transport: http(rpcUrl) });
const account = dryRun ? undefined : privateKeyToAccount(env("KEEPER_PRIVATE_KEY") as Hex);
const rewardTo = (process.env.REWARD_TO ?? account?.address ?? "0x0000000000000000000000000000000000000000") as Address;
// Eindreview I-8: een ongeldige REWARD_TO liet elke simulatie falen met een encodefout, die als fout van de node gold;
// de keeper probeerde dan tot het budget op was, zonder duidelijke melding. Nu stopt de run meteen.
{
  const problem = rewardToError(rewardTo, rebalancer);
  if (problem !== null) throw new Error(problem);
}
const walletClient = account ? createWalletClient({ account, chain: base, transport: http(rpcUrl) }) : undefined;

const nowSec = () => Math.floor(Date.now() / 1000);
const startSeconds = nowSec();
const deadline = retryDeadline(startSeconds, retrySeconds);
/** Eindreview F-2: eigen tijdsgrens voor het zoeken in het register, gescheiden van het retry-budget. */
const searchDeadline = startSeconds + searchSeconds;

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

/**
 * Eindreview F-1: plafond van de tip uit wat een run oplevert (`capFeePolicy`). De beloning in wei volgt uit
 * KEEPER_REWARD_EURC en de Chainlink-koersen EURC/USD (de feed van het contract) en ETH/USD. Is een koers niet te lezen,
 * dan telt de beloning als 0 en geldt alleen TIP_BUDGET_ETH: liever te weinig bieden dan te veel.
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
    return eurcToWei(reward, eurcRound[1], ethRound[1]);
  } catch (error) {
    console.warn(`beloning in ETH niet te lezen (${describeError(error)}); tipplafond alleen uit TIP_BUDGET_ETH`);
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
  console.log(`tipplafond ${formatGwei(feePolicy.max)} gwei (tip × ${gasEstimate} gas ≤ beloning × ${tipRewardShareBps}/10000 + budget)`);
}
const initialFeeState = readFeeState();
let lastBlockadeAt = initialFeeState?.lastBlockadeAt ?? 0;
let priorityFee = startPriorityFee(initialFeeState, startSeconds, feePolicy, feeHoldSeconds);
const saveFeeState = () =>
  writeFileSync(feeStateFile, `${JSON.stringify({ priorityFeeWei: priorityFee.toString(), lastBlockadeAt }, null, 2)}\n`);
/** Een blokkade of een eigen transactie in deze run; zonder beide zakt de tip aan het eind van de run. */
let blockadeThisRun = false;
let sentThisRun = false;
/** Eindreview F-1: na een eigen transactie zonder blokkade zakt de tip (halveren, niet onder de basis). */
const lowerFee = () => {
  const next = decayPriorityFee(priorityFee, feePolicy);
  if (next === priorityFee) return;
  priorityFee = next;
  saveFeeState();
};

let pools: readonly Address[] | undefined;

/**
 * Transacties die vóór de eigen transactie in dat blok een van beide pools aanraakten (Swap, Mint of Burn), zonder directe
 * `execute`'s van andere keepers, en de hoogste tip daarvan; en of `owner` vóór ons al door een andere keeper is uitgevoerd
 * (`Executed`-log, eindreview F-1). Bij een leesfout: `touched` onbekend (false), geen tip en niet bediend; dan loopt de
 * fee niet op.
 */
const blockersOf = async (
  owner: Address,
  receipt: TransactionReceipt,
): Promise<{ touched: boolean; tip: bigint | undefined; served: boolean }> => {
  try {
    pools ??= [await read<Address>("POOL_EURC_USDC"), await read<Address>("POOL_USDC_CBBTC")];
    const [block, logs, executed] = await Promise.all([
      publicClient.getBlock({ blockHash: receipt.blockHash }),
      publicClient.getLogs({ address: [...pools], events: poolEvents, blockHash: receipt.blockHash }),
      publicClient.getLogs({ address: rebalancer, event: executedEvent[0], args: { owner }, blockHash: receipt.blockHash }),
    ]);
    const served = servedBefore(
      executed.map((log) => ({ owner: log.args.owner ?? ("0x" as Address), transactionIndex: log.transactionIndex ?? Infinity })),
      owner,
      receipt.transactionIndex,
    );
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
    console.warn(`aanrakers in blok ${receipt.blockNumber} niet te lezen: ${describeError(error)}`);
    return { touched: false, tip: undefined, served: false };
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

/**
 * Eindreview I-6: wacht tot een van `hashes` (dezelfde nonce: de transactie en haar vervangers) gemined is. undefined
 * als dat na TX_WAIT_BLOCKS blokken sinds `sentAtBlock` niet zo is. Een fout bij het lezen van een receipt telt als
 * "nog niet gemined". Maakt de chain BLOCK_WAIT_SECONDS lang geen blok, dan ook undefined.
 */
const waitMined = async (hashes: readonly Hex[], sentAtBlock: bigint): Promise<TransactionReceipt | undefined> => {
  let last = sentAtBlock;
  let lastChange = Date.now();
  for (;;) {
    for (const hash of hashes) {
      try {
        return await publicClient.getTransactionReceipt({ hash });
      } catch {
        // nog niet gemined, of een fout van de node: volgende poging
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
      const send = (fees: { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }) =>
        walletClient.writeContract({
          address: rebalancer,
          abi,
          functionName: "execute",
          args: [owner, rewardTo],
          gas: gasLimit,
          ...fees,
          nonce,
          // `chainId` staat niet in het type van writeContract, maar gaat via sendTransaction mee naar
          // prepareTransactionRequest; zonder probeert viem eerst eth_fillTransaction (viem 2.56.3).
          ...({ chainId: base.id } as unknown as Record<string, never>),
        });
      let fees = { maxPriorityFeePerGas: priorityFee, maxFeePerGas: maxFeePerGas(latest.baseFeePerGas ?? 0n, priorityFee) };
      const hashes: Hex[] = [await send(fees)];
      let sentAtBlock = latest.number;
      let receipt: TransactionReceipt | undefined;
      // Eindreview I-6: niet gemined binnen TX_WAIT_BLOCKS blokken (bijvoorbeeld een base fee die boven maxFeePerGas
      // steeg): vervangen met dezelfde nonce en hogere fees, hooguit TX_REPLACEMENTS keer. Lukt dat niet, dan stopt de
      // run duidelijk; een volgende send zou achter dezelfde nonce blijven hangen. Geen cool-down.
      for (let replacements = 0; ; replacements += 1) {
        receipt = await waitMined(hashes, sentAtBlock);
        if (receipt !== undefined) break;
        const block = await publicClient.getBlock();
        const next = replacements < txReplacements ? replacementFees(fees, block.baseFeePerGas ?? 0n, feePolicy.max) : null;
        if (next === null) {
          saveCooldowns();
          throw new Error(
            `transactie ${hashes.join(", ")} (nonce ${nonce}) voor ${owner} niet binnen ${txWaitBlocks} blokken gemined en niet meer te vervangen; run gestopt`,
          );
        }
        console.warn(
          `${owner}: transactie ${hashes.at(-1)} niet gemined na ${txWaitBlocks} blokken; vervangen (nonce ${nonce}, tip ${formatGwei(next.maxPriorityFeePerGas)} gwei, maxFee ${formatGwei(next.maxFeePerGas)} gwei)`,
        );
        fees = next;
        try {
          hashes.push(await send(fees));
        } catch (error) {
          // Bijvoorbeeld "nonce too low": de vorige is intussen gemined. De volgende ronde vindt die receipt.
          console.warn(`${owner}: vervangen mislukt (${describeError(error)})`);
        }
        sentAtBlock = block.number;
      }
      const hash = receipt.transactionHash;
      console.log(`${owner}: ${direction} ≈ ${eurc} EURC → ${receipt.status} ${hash} (tip ${formatGwei(fees.maxPriorityFeePerGas)} gwei)`);
      lastRunBlock = receipt.blockNumber;
      sentThisRun = true;
      if (receipt.status === "success") {
        cooldowns = clearFailure(cooldowns, owner);
        saveCooldowns();
        lowerFee();
        return { outcome: "executed", block: receipt.blockNumber };
      }
      // Gerevert na een geslaagde simulatie: de staat veranderde in de tussentijd. Hersimuleer op het begin van dat
      // blok voor de reden, en kijk wie vóór ons een pool aanraakte.
      failure = new Error(`transactie ${hash} is gerevert`);
      const [resimulation, blockers] = await Promise.all([resimulateAtBlockStart(owner, receipt), blockersOf(owner, receipt)]);
      const judged = onchainRevertVerdict(resimulation, blockers.touched, blockers.served);
      verdict = judged.failure;
      if (judged.failure.servedByOther) {
        // Eindreview F-1: een andere keeper voerde deze owner eerder in het blok uit. Bediend; geen cool-down, geen hogere tip.
        console.log(`${owner}: al uitgevoerd door een andere keeper in blok ${receipt.blockNumber}; geen cool-down, geen hogere tip`);
        lowerFee();
        return { outcome: "skipped", block: null };
      }
      if (resimulation.kind === "reverted") failure = new Error(`transactie ${hash} is gerevert (${resimulation.errorName ?? "revert"})`);
      if (judged.blockade) {
        // Blokkade: een andere transactie raakte vóór ons een pool aan. Hogere tip, en pas gemiddeld SEND_RETRY_BLOCKS later.
        sendFromBlock = nextSendBlock(receipt.blockNumber, sendRetryBlocks, Math.random());
        priorityFee = nextPriorityFee(priorityFee, blockers.tip, feePolicy);
        lastBlockadeAt = nowSec();
        blockadeThisRun = true;
        saveFeeState();
        console.warn(
          `${owner}: blokkade in blok ${receipt.blockNumber} (tip aanraker ${blockers.tip === undefined ? "onbekend" : `${formatGwei(blockers.tip)} gwei`}); volgende tip ${formatGwei(priorityFee)} gwei`,
        );
      } else {
        lowerFee();
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

/** Een kandidaat, met zijn plek in het register (null voor een adres uit OWNERS_FILE). */
type Candidate = { owner: Address; index: bigint | null };

/** Wat het filter nodig heeft: de tokens van het contract, de feedkoers en de ondergrens. */
type FilterContext = { eurcToken: Address; cbbtcToken: Address; price: bigint; minRun: bigint };

/**
 * Lead 9: welke van deze owners kunnen in minstens één richting een run halen (`filterCandidates`)? Eén multicall. Een
 * owner waarvan een lezing mislukt, blijft voorzichtigheidshalve kandidaat. Een fout van de node gooit; de aanroeper
 * slaat de portie dan over.
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
      console.warn(`${owner}: saldo of allowance niet te lezen; blijft kandidaat`);
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
 * Tokens, feedkoers en ondergrens voor het filter. undefined als de feedkoers revert: dan is volgens het contract niemand
 * due. Een fout van de node bij deze paar lezingen breekt de run af (er is dan nog niets gedaan).
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
    console.warn(`feedkoers niet te lezen (${describeError(error)}); niemand due`);
    return undefined;
  }
};

/**
 * Eindreview F-2: kandidaten uit het register, vanaf de opgeslagen offset (`scanSegments`) en binnen de zoektijd
 * (`SEARCH_SECONDS` na de start, los van het retry-budget). Een fout van de node bij een portie (`owners` of de
 * multicall) slaat alleen die portie over. Geeft ook terug tot waar het register gelezen is.
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
      console.warn(`Zoektijd (${searchSeconds} s) op na ${read_} van ${count} owners; de volgende run zoekt verder vanaf ${segment.offset}.`);
      return { candidates, scannedTo: segment.offset, read: read_, complete: false };
    }
    let page: readonly Address[];
    try {
      page = await read<readonly Address[]>("owners", [segment.offset, segment.limit]);
    } catch (error) {
      console.warn(`owners(${segment.offset}, ${segment.limit}) niet te lezen (${describeError(error)}); portie overgeslagen`);
      read_ += segment.limit;
      continue;
    }
    for (const [b, batch] of chunks(page, FUNDS_BATCH).entries()) {
      const firstIndex = segment.offset + BigInt(b * FUNDS_BATCH);
      let funded: Set<string>;
      try {
        funded = await fundedAmong(batch, ctx);
      } catch (error) {
        console.warn(`saldo en allowance van owners ${firstIndex}–${firstIndex + BigInt(batch.length) - 1n} niet te lezen (${describeError(error)}); portie overgeslagen`);
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
 * Welke van deze owners zijn nu due? `isDue` per owner in één multicall. `isDue` revert nooit, dus een mislukte call is
 * een fout van de node (viem vangt die met `allowFailure` ook af). Dan gooit dit; de aanroeper slaat de portie over.
 */
const dueAmong = async (owners: readonly Address[], at: At): Promise<Address[]> => {
  const results = await multicallResults(
    owners.map((owner) => ({ address: rebalancer, functionName: "isDue", args: [owner] })),
    at,
  );
  if (results.some((r) => r === undefined)) {
    throw new Error("isDue niet te lezen voor een portie kandidaten (fout van de node)");
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

// Audit lead 9 en eindreview F-2: eerst de adressen uit OWNERS_FILE, dan het register vanaf de opgeslagen offset, binnen
// de zoektijd. Alles off-chain gefilterd op actief, saldo en allowance (gebundeld met Multicall3), zodat lege
// spam-registraties de run niet ophouden. Alleen de kandidaten krijgen een isDue.
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
        // Eigen gebruikers niet stil laten vallen: bij een fout van de node gaan ze ongefilterd door naar isDue.
        console.warn(`saldo en allowance van OWNERS_FILE niet te lezen (${describeError(error)}); ongefilterd verder`);
        for (const owner of batch) candidates.push({ owner, index: null });
      }
    }
    console.log(`${priorityOwners.length} adressen uit OWNERS_FILE, ${candidates.length} kandidaten`);
  }
  const scan = await scanRegister(checked, scanStart, ctx, new Set(priorityOwners.map((o) => o.toLowerCase())));
  candidates.push(...scan.candidates);
  scannedTo = scan.scannedTo;
  console.log(
    `${checked} owners geregistreerd, ${scan.read} gelezen vanaf ${scanStart}${scan.complete ? " (hele register)" : ""}, ${candidates.length} kandidaten na het filter op saldo en allowance`,
  );
}

/** Eerste kandidaat uit het register die deze run niet meer gelezen is, als het retry-budget op raakt. */
let firstUnprocessed: bigint | null = null;
const batches = chunks(candidates, Number(pageSize));
for (const [index, batch] of batches.entries()) {
  if (nowSec() >= deadline) {
    const rest = batches.slice(index).flat();
    firstUnprocessed = rest.find((c) => c.index !== null)?.index ?? null;
    console.warn(
      `Retry-budget (${retrySeconds} s) op: ${rest.length} kandidaten niet meer gelezen; de volgende run begint in het register bij ${firstUnprocessed ?? scannedTo}.`,
    );
    break;
  }
  const owners = batch.map((c) => c.owner);
  let readBlock: bigint | null = null;
  for (let reads = 1; ; reads += 1) {
    // Elke lezing in een blok ná de laatste eigen run en ná de vorige lezing van deze portie.
    const after = readBlock !== null && (lastRunBlock === null || readBlock > lastRunBlock) ? readBlock : lastRunBlock;
    if (!(await waitForBlockAfter(after))) break;
    let fresh: Address[];
    try {
      const latest = await publicClient.getBlock();
      readBlock = latest.number;
      fresh = newOwners(await dueAmong(owners, atLatest(latest)), handled);
    } catch (error) {
      console.warn(`isDue voor ${owners.length} kandidaten niet te lezen (${describeError(error)}); portie overgeslagen`);
      break;
    }

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
if (ctx !== undefined) {
  const nextOffset = nextScanOffset(scannedTo, firstUnprocessed, checked);
  writeFileSync(scanStateFile, `${JSON.stringify({ nextOffset: nextOffset.toString() }, null, 2)}\n`);
}
// Eindreview F-1: een run zonder blokkade en zonder eigen transactie laat de tip ook zakken.
if (!blockadeThisRun && !sentThisRun && !dryRun) lowerFee();
console.log(`Klaar: ${checked} owners geregistreerd, ${executed} uitgevoerd, ${skipped} overgeslagen${dryRun ? " (dry-run)" : ""}.`);
