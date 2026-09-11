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
 * dueOwners(offset, limit) (één call per pagina, het contract past dezelfde regels toe als isDue),
 * (4) stuurt de lijst due owners als ondertekend rapport naar Rebalancer.onReport via de
 * KeystoneForwarder.
 * De workflow beslist niets: het contract bepaalt zelf of en hoeveel er gehandeld wordt.
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
  gasLimit: string;
};

export type RunSummary = {
  /** Seconden sinds de sequencer voor het laatst van status wisselde. */
  sequencerUpSeconds: number;
  /** 0 als de run al bij de sequencer-controle is gestopt. */
  feedAgeSeconds: number;
  ownersChecked: number;
  dueOwners: Address[];
  /** Lege string als er niets geschreven is. */
  txHash: string;
  /** Lege string als de run een rapport heeft verstuurd. */
  skippedReason: string;
};

export const rebalancerAbi = parseAbi([
  "function ownerCount() view returns (uint256)",
  "function dueOwners(uint256 offset, uint256 limit) view returns (address[])",
]);

export const aggregatorAbi = parseAbi([
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
]);

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

export const onCronTrigger = (runtime: Runtime<Config>): RunSummary => {
  const { config } = runtime;
  const network = getNetwork({ chainFamily: "evm", chainSelectorName: config.chainSelectorName });
  if (!network) {
    throw new Error(`Onbekende chain-selector-naam: ${config.chainSelectorName}`);
  }
  const evmClient = new EVMClient(network.chainSelector.selector);

  const nowSeconds = BigInt(Math.floor(runtime.now().getTime() / 1000));

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
    return { sequencerUpSeconds, feedAgeSeconds: 0, ownersChecked: 0, dueOwners: [], txHash: "", skippedReason };
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
    return { sequencerUpSeconds, feedAgeSeconds, ownersChecked: 0, dueOwners: [], txHash: "", skippedReason };
  }

  // 3. Nog geen contract uitgerold: niets te doen.
  if (isAddressEqual(config.rebalancerAddress, zeroAddress)) {
    const skippedReason = "rebalancerAddress is het nuladres; contract nog niet uitgerold";
    runtime.log(`Overgeslagen: ${skippedReason}`);
    return { sequencerUpSeconds, feedAgeSeconds, ownersChecked: 0, dueOwners: [], txHash: "", skippedReason };
  }

  // 4. Per pagina dueOwners() vragen; het contract filtert zelf met dezelfde regels als isDue().
  //    Stoppen zodra het rapport vol is: de rest komt in een volgende run aan de beurt.
  const ownerCount = readContract(
    runtime,
    evmClient,
    config.rebalancerAddress,
    rebalancerAbi,
    "ownerCount",
  ) as bigint;
  const ownersChecked = Number(ownerCount);
  const dueOwners: Address[] = [];
  for (let offset = 0n; offset < ownerCount && dueOwners.length < config.maxOwnersPerReport; offset += BigInt(config.ownersPageSize)) {
    const page = readContract(
      runtime,
      evmClient,
      config.rebalancerAddress,
      rebalancerAbi,
      "dueOwners",
      [offset, BigInt(config.ownersPageSize)],
    ) as readonly Address[];
    for (const owner of page) {
      if (dueOwners.length < config.maxOwnersPerReport) {
        dueOwners.push(owner);
      }
    }
  }
  runtime.log(`Owners gecontroleerd: ${ownersChecked}, due: ${dueOwners.length}`);

  if (dueOwners.length === 0) {
    runtime.log("Geen owner is due; geen rapport verstuurd");
    return {
      sequencerUpSeconds,
      feedAgeSeconds,
      ownersChecked,
      dueOwners,
      txHash: "",
      skippedReason: "geen owner is due",
    };
  }

  // 5. Rapport tekenen en naar Rebalancer.onReport sturen.
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
  runtime.log(`onReport verstuurd: tx=${txHash} owners=${dueOwners.length}`);

  return { sequencerUpSeconds, feedAgeSeconds, ownersChecked, dueOwners, txHash, skippedReason: "" };
};

export const initWorkflow = (config: Config) => {
  const cron = new CronCapability();
  return [handler(cron.trigger({ schedule: config.schedule }), onCronTrigger)];
};

export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}
