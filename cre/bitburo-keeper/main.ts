import {
  CronCapability,
  EVMClient,
  LATEST_BLOCK_NUMBER,
  Runner,
  TxStatus,
  bytesToHex,
  encodeCallMsg,
  getNetwork,
  handler,
  prepareReportRequest,
  type Runtime,
} from "@chainlink/cre-sdk";
import { EVM_PB } from "@chainlink/cre-sdk/pb";
import {
  type Address,
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  isAddressEqual,
  parseAbi,
  parseAbiParameters,
  zeroAddress,
} from "viem";

/**
 * Bitburo keeper (Chainlink CRE).
 *
 * Elke run: (1) controleert of de Base-sequencer up is en de grace period voorbij is,
 * (2) controleert of de cbBTC/USD-feed vers is, (3) vraagt het Rebalancer-contract per pagina
 * dueOwners(offset, limit), met een startpunt dat per uur verschuift zodat elke due owner aan de
 * beurt komt, (4) leest per kandidaat isDue(owner) en simuleert execute(owner) om owners over te
 * slaan die te klein zijn (dust), te groot zijn voor het gasbudget van onReport, of toch zouden
 * reverten, (5) stuurt de overgebleven owners als ondertekend rapport naar Rebalancer.onReport via
 * de KeystoneForwarder en controleert of de receiver niet gerevert is.
 * De workflow beslist niets over bedragen of richting: het contract bepaalt zelf of en hoeveel er
 * gehandeld wordt. De workflow kiest alleen wie er in het rapport komt.
 */
export type Config = {
  schedule: string;
  chainSelectorName: string;
  rebalancerAddress: Address;
  sequencerFeedAddress: Address;
  sequencerGracePeriodSeconds: number;
  priceFeedAddress: Address;
  maxFeedAgeSeconds: number;
  ownersPageSize: number;
  maxOwnersPerReport: number;
  /** Aantal due owners waarvoor per run hooguit isDue() en een simulatie worden gedaan. */
  maxCandidatesPerRun: number;
  /** Ondergrens van |eurcDelta| in hele EURC; kleinere runs zijn niet de gas waard. */
  minRunEurc: number;
  /** Bovengrens van |eurcDelta| in hele EURC; grotere runs passen niet in EXECUTE_GAS en zijn voor het keeper-script. */
  maxRunEurc: number;
  /** Gasbudget dat onReport per owner geeft (EXECUTE_GAS in het contract); simulaties daarboven worden overgeslagen. */
  executeGasBudget: string;
  gasLimit: string;
};

export type SkippedOwner = {
  owner: Address;
  reason: string;
};

export type RunSummary = {
  /** Seconden sinds de sequencer voor het laatst van status wisselde. */
  sequencerUpSeconds: number;
  /** 0 als de run al bij de sequencer-controle is gestopt. */
  feedAgeSeconds: number;
  ownersChecked: number;
  /** Aantal due owners dat door de filters is gehaald (isDue + simulatie). */
  candidatesChecked: number;
  /** Owners in het rapport. */
  dueOwners: Address[];
  /** Due owners die niet in het rapport zijn gekomen, met reden. */
  skippedOwners: SkippedOwner[];
  /** Lege string als er niets geschreven is. */
  txHash: string;
  /** Lege string als de run een rapport heeft verstuurd. */
  skippedReason: string;
};

export const rebalancerAbi = parseAbi([
  "function ownerCount() view returns (uint256)",
  "function dueOwners(uint256 offset, uint256 limit) view returns (address[])",
  "function isDue(address owner) view returns (bool due, int256 eurcDelta)",
  "function execute(address owner, address rewardTo)",
]);

export const aggregatorAbi = parseAbi([
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
]);

const EURC_UNIT = 1_000_000n;

export const encodeOwnersReport = (owners: readonly Address[]): `0x${string}` =>
  encodeAbiParameters(parseAbiParameters("address[]"), [owners]);

export const isFeedFresh = (
  updatedAtSeconds: bigint,
  nowSeconds: bigint,
  maxAgeSeconds: number,
): boolean => nowSeconds - updatedAtSeconds <= BigInt(maxAgeSeconds);

/**
 * Chainlink L2 Sequencer Uptime-feed: answer 0 = up, 1 = down. Na een herstart moet de
 * grace period verstreken zijn (startedAt = moment van de laatste statuswissel), anders
 * kunnen prijsfeeds nog niet bijgewerkt zijn.
 */
export const isSequencerReady = (
  answer: bigint,
  startedAtSeconds: bigint,
  nowSeconds: bigint,
  gracePeriodSeconds: number,
): boolean => answer === 0n && nowSeconds - startedAtSeconds >= BigInt(gracePeriodSeconds);

/**
 * Startindex in de owner-lijst voor deze run. Het startpunt schuift elk uur `maxOwnersPerReport`
 * plaatsen op, zodat owners die achteraan staan ook aan de beurt komen als er meer due owners zijn
 * dan er in één rapport passen. `hourNumber` komt uit de DON-tijd en is dus op alle nodes gelijk.
 */
export const rotationStart = (hourNumber: bigint, maxOwnersPerReport: number, ownerCount: bigint): bigint => {
  if (ownerCount <= 0n) {
    return 0n;
  }
  return (hourNumber * BigInt(maxOwnersPerReport)) % ownerCount;
};

export type Page = { offset: bigint; limit: bigint };

/**
 * Pagina's (offset, limit) die vanaf `start` cyclisch de hele owner-lijst precies één keer bestrijken:
 * eerst van `start` tot het einde, dan van 0 tot `start`.
 */
export const rotatedPages = (start: bigint, ownerCount: bigint, pageSize: number): Page[] => {
  const size = BigInt(pageSize);
  const pages: Page[] = [];
  for (let offset = start; offset < ownerCount; offset += size) {
    pages.push({ offset, limit: size < ownerCount - offset ? size : ownerCount - offset });
  }
  for (let offset = 0n; offset < start; offset += size) {
    pages.push({ offset, limit: size < start - offset ? size : start - offset });
  }
  return pages;
};

/**
 * Reden om een due owner op grond van de run-omvang over te slaan, of null als de run meedoet.
 * Te klein: de fee (25 bps) dekt de gas niet en zulke owners kunnen de slots bezetten (dust).
 * Te groot: past niet in het gasbudget van onReport; het open keeper-script bedient die wel.
 */
export const runSizeSkipReason = (eurcDelta: bigint, minRunEurc: number, maxRunEurc: number): string | null => {
  const size = eurcDelta < 0n ? -eurcDelta : eurcDelta;
  if (size < BigInt(minRunEurc) * EURC_UNIT) {
    return `run te klein (${formatEurc(size)} EURC < ${minRunEurc} EURC)`;
  }
  if (size > BigInt(maxRunEurc) * EURC_UNIT) {
    return `run te groot voor onReport (${formatEurc(size)} EURC > ${maxRunEurc} EURC); laat aan keeper-script`;
  }
  return null;
};

const formatEurc = (baseUnits: bigint): string => {
  const whole = baseUnits / EURC_UNIT;
  const fraction = (baseUnits % EURC_UNIT).toString().padStart(6, "0").replace(/0+$/, "");
  return fraction === "" ? whole.toString() : `${whole}.${fraction}`;
};

const readContract = <TFunctionName extends string>(
  runtime: Runtime<Config>,
  evmClient: EVMClient,
  address: Address,
  abi: typeof rebalancerAbi | typeof aggregatorAbi,
  functionName: TFunctionName,
  args: readonly unknown[] = [],
) => {
  const result = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: zeroAddress,
        to: address,
        // biome-ignore lint/suspicious/noExplicitAny: viem's generic ABI typing is too strict for a shared helper
        data: encodeFunctionData({ abi, functionName, args } as any),
      }),
      // Laatste blok, niet het gefinaliseerde: dat loopt op Base tientallen minuten achter en zou elke
      // feed "te oud" maken. Het contract controleert de versheid zelf opnieuw bij uitvoering.
      blockNumber: LATEST_BLOCK_NUMBER,
    })
    .result();

  return decodeFunctionResult({
    abi,
    functionName,
    data: bytesToHex(result.data),
    // biome-ignore lint/suspicious/noExplicitAny: same reason as above
  } as any);
};

/**
 * Simuleert execute(owner, address(0)) via eth_estimateGas. Een revert (dust die op de route naar 0
 * afrondt, blacklist, te krappe slippage) of een gasverbruik boven EXECUTE_GAS betekent dat onReport
 * deze owner toch zou overslaan; dan is het rapportslot beter aan een ander besteed.
 * Geeft de reden om over te slaan terug, of null als de simulatie slaagt.
 */
const simulateExecute = (runtime: Runtime<Config>, evmClient: EVMClient, owner: Address): string | null => {
  const { config } = runtime;
  let gas: bigint;
  try {
    gas = evmClient
      .estimateGas(runtime, {
        msg: encodeCallMsg({
          from: zeroAddress,
          to: config.rebalancerAddress,
          data: encodeFunctionData({ abi: rebalancerAbi, functionName: "execute", args: [owner, zeroAddress] }),
        }),
      })
      .result().gas;
  } catch (error) {
    return `simulatie van execute mislukt: ${(error as Error).message.split("\n")[0]}`;
  }
  if (gas > BigInt(config.executeGasBudget)) {
    return `simulatie vraagt ${gas} gas > budget ${config.executeGasBudget}; laat aan keeper-script`;
  }
  return null;
};

export const onCronTrigger = (runtime: Runtime<Config>): RunSummary => {
  const { config } = runtime;
  const network = getNetwork({ chainFamily: "evm", chainSelectorName: config.chainSelectorName });
  if (!network) {
    throw new Error(`Onbekende chain-selector-naam: ${config.chainSelectorName}`);
  }
  const evmClient = new EVMClient(network.chainSelector.selector);

  const nowSeconds = BigInt(Math.floor(runtime.now().getTime() / 1000));
  const skipped = (skippedReason: string, partial: Partial<RunSummary> = {}): RunSummary => ({
    sequencerUpSeconds: 0,
    feedAgeSeconds: 0,
    ownersChecked: 0,
    candidatesChecked: 0,
    dueOwners: [],
    skippedOwners: [],
    txHash: "",
    ...partial,
    skippedReason,
  });

  // 1. Sequencer-controle: is de Base-sequencer down of net terug, dan zijn de prijsfeeds
  //    niet te vertrouwen; sla de run dan over.
  const [, sequencerAnswer, sequencerStartedAt] = readContract(
    runtime,
    evmClient,
    config.sequencerFeedAddress,
    aggregatorAbi,
    "latestRoundData",
  ) as readonly [bigint, bigint, bigint, bigint, bigint];
  const sequencerUpSeconds = Number(nowSeconds - sequencerStartedAt);
  runtime.log(`Sequencer uptime feed: answer=${sequencerAnswer.toString()} sinds=${sequencerUpSeconds}s`);

  if (!isSequencerReady(sequencerAnswer, sequencerStartedAt, nowSeconds, config.sequencerGracePeriodSeconds)) {
    const skippedReason =
      sequencerAnswer === 0n
        ? `sequencer net terug (${sequencerUpSeconds}s < grace period ${config.sequencerGracePeriodSeconds}s)`
        : `sequencer down (answer=${sequencerAnswer.toString()})`;
    runtime.log(`Overgeslagen: ${skippedReason}`);
    return skipped(skippedReason, { sequencerUpSeconds });
  }

  // 2. Feed-controle: als de koers oud is, revert het contract toch; sla de run dan over.
  const [, answer, , updatedAt] = readContract(
    runtime,
    evmClient,
    config.priceFeedAddress,
    aggregatorAbi,
    "latestRoundData",
  ) as readonly [bigint, bigint, bigint, bigint, bigint];
  const feedAgeSeconds = Number(nowSeconds - updatedAt);
  runtime.log(`cbBTC/USD feed: answer=${answer.toString()} age=${feedAgeSeconds}s`);

  if (!isFeedFresh(updatedAt, nowSeconds, config.maxFeedAgeSeconds)) {
    const skippedReason = `feed te oud (${feedAgeSeconds}s > ${config.maxFeedAgeSeconds}s)`;
    runtime.log(`Overgeslagen: ${skippedReason}`);
    return skipped(skippedReason, { sequencerUpSeconds, feedAgeSeconds });
  }

  // 3. Nog geen contract uitgerold: niets te doen.
  if (isAddressEqual(config.rebalancerAddress, zeroAddress)) {
    const skippedReason = "rebalancerAddress is het nuladres; contract nog niet uitgerold";
    runtime.log(`Overgeslagen: ${skippedReason}`);
    return skipped(skippedReason, { sequencerUpSeconds, feedAgeSeconds });
  }

  // 4. Per pagina dueOwners() vragen, cyclisch vanaf een startpunt dat per uur opschuift; het
  //    contract filtert zelf met dezelfde regels als isDue(). Elke kandidaat gaat daarna door
  //    isDue() (omvang van de run) en een simulatie van execute(). Stoppen zodra het rapport vol
  //    is of het kandidatenbudget op is: de rest komt in een volgende run aan de beurt.
  const ownerCount = readContract(
    runtime,
    evmClient,
    config.rebalancerAddress,
    rebalancerAbi,
    "ownerCount",
  ) as bigint;
  const ownersChecked = Number(ownerCount);
  const start = rotationStart(nowSeconds / 3600n, config.maxOwnersPerReport, ownerCount);
  runtime.log(`Owners: ${ownersChecked}, startindex deze run: ${start}`);

  const dueOwners: Address[] = [];
  const skippedOwners: SkippedOwner[] = [];
  let candidatesChecked = 0;
  const budgetLeft = (): boolean =>
    dueOwners.length < config.maxOwnersPerReport && candidatesChecked < config.maxCandidatesPerRun;

  for (const page of rotatedPages(start, ownerCount, config.ownersPageSize)) {
    if (!budgetLeft()) {
      break;
    }
    const candidates = readContract(
      runtime,
      evmClient,
      config.rebalancerAddress,
      rebalancerAbi,
      "dueOwners",
      [page.offset, page.limit],
    ) as readonly Address[];

    for (const owner of candidates) {
      if (!budgetLeft()) {
        break;
      }
      candidatesChecked += 1;

      const [due, eurcDelta] = readContract(
        runtime,
        evmClient,
        config.rebalancerAddress,
        rebalancerAbi,
        "isDue",
        [owner],
      ) as readonly [boolean, bigint];
      const reason = due
        ? (runSizeSkipReason(eurcDelta, config.minRunEurc, config.maxRunEurc) ?? simulateExecute(runtime, evmClient, owner))
        : "niet meer due";
      if (reason !== null) {
        runtime.log(`Overgeslagen ${owner}: ${reason}`);
        skippedOwners.push({ owner, reason });
        continue;
      }
      runtime.log(`In rapport ${owner}: ${eurcDelta > 0n ? "koop" : "verkoop"} ${formatEurc(eurcDelta < 0n ? -eurcDelta : eurcDelta)} EURC`);
      dueOwners.push(owner);
    }
  }
  runtime.log(`Kandidaten gecontroleerd: ${candidatesChecked}, in rapport: ${dueOwners.length}, overgeslagen: ${skippedOwners.length}`);

  if (dueOwners.length === 0) {
    const skippedReason = candidatesChecked === 0 ? "geen owner is due" : "geen owner over na filtering";
    runtime.log(`${skippedReason}; geen rapport verstuurd`);
    return skipped(skippedReason, { sequencerUpSeconds, feedAgeSeconds, ownersChecked, candidatesChecked, skippedOwners });
  }

  // 5. Rapport tekenen en naar Rebalancer.onReport sturen. De forwarder-transactie slaagt ook als
  //    onReport zelf revert (bijvoorbeeld door een verkeerde workflow-owner); dat meldt de SDK apart
  //    in receiverContractExecutionStatus, dus die controleren we ook.
  const signedReport = runtime.report(prepareReportRequest(encodeOwnersReport(dueOwners))).result();
  const txResult = evmClient
    .writeReport(runtime, {
      receiver: config.rebalancerAddress,
      report: signedReport,
      gasConfig: { gasLimit: config.gasLimit },
    })
    .result();

  if (txResult.txStatus !== TxStatus.SUCCESS) {
    throw new Error(`onReport mislukt: ${txResult.errorMessage || txResult.txStatus}`);
  }
  const txHash = bytesToHex(txResult.txHash ?? new Uint8Array(32));
  const receiverStatus = txResult.receiverContractExecutionStatus;
  runtime.log(
    `onReport verstuurd: tx=${txHash} owners=${dueOwners.length} receiverStatus=${
      receiverStatus === undefined ? "onbekend" : EVM_PB.ReceiverContractExecutionStatus[receiverStatus]
    }`,
  );
  if (receiverStatus === EVM_PB.ReceiverContractExecutionStatus.REVERTED) {
    throw new Error(`onReport is gerevert in het Rebalancer-contract (tx=${txHash}); geen enkele owner is uitgevoerd`);
  }

  return {
    sequencerUpSeconds,
    feedAgeSeconds,
    ownersChecked,
    candidatesChecked,
    dueOwners,
    skippedOwners,
    txHash,
    skippedReason: "",
  };
};

export const initWorkflow = (config: Config) => {
  const cron = new CronCapability();
  return [handler(cron.trigger({ schedule: config.schedule }), onCronTrigger)];
};

export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}
