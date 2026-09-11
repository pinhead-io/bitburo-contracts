import {
  CronCapability,
  EVMClient,
  LAST_FINALIZED_BLOCK_NUMBER,
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
 * Elke run: (1) controleert of de cbBTC/USD-feed vers is, (2) loopt alle owners van het
 * Rebalancer-contract af en vraagt per owner isDue(), (3) stuurt de lijst due owners als
 * ondertekend rapport naar Rebalancer.onReport via de KeystoneForwarder.
 * De workflow beslist niets: het contract bepaalt zelf of en hoeveel er gehandeld wordt.
 */
export type Config = {
  schedule: string;
  chainSelectorName: string;
  rebalancerAddress: Address;
  priceFeedAddress: Address;
  maxFeedAgeSeconds: number;
  ownersPageSize: number;
  maxOwnersPerReport: number;
  gasLimit: string;
};

export type RunSummary = {
  feedAgeSeconds: number;
  ownersChecked: number;
  dueOwners: Address[];
  /** Lege string als er niets geschreven is. */
  txHash: string;
  /** Lege string als de run een rapport heeft verstuurd. */
  skippedReason: string;
};

export const rebalancerAbi = parseAbi([
  "function owners(uint256 offset, uint256 limit) view returns (address[])",
  "function isDue(address owner) view returns (bool due, int256 eurcDelta)",
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
      blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
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

  // 1. Feed-controle: als de koers oud is, revert het contract toch; sla de run dan over.
  const [, answer, , updatedAt] = readContract(
    runtime,
    evmClient,
    config.priceFeedAddress,
    aggregatorAbi,
    "latestRoundData",
  ) as readonly [bigint, bigint, bigint, bigint, bigint];
  const nowSeconds = BigInt(Math.floor(runtime.now().getTime() / 1000));
  const feedAgeSeconds = Number(nowSeconds - updatedAt);
  runtime.log(`cbBTC/USD feed: answer=${answer.toString()} age=${feedAgeSeconds}s`);

  if (!isFeedFresh(updatedAt, nowSeconds, config.maxFeedAgeSeconds)) {
    const skippedReason = `feed te oud (${feedAgeSeconds}s > ${config.maxFeedAgeSeconds}s)`;
    runtime.log(`Overgeslagen: ${skippedReason}`);
    return { feedAgeSeconds, ownersChecked: 0, dueOwners: [], txHash: "", skippedReason };
  }

  // 2. Nog geen contract uitgerold: niets te doen.
  if (isAddressEqual(config.rebalancerAddress, zeroAddress)) {
    const skippedReason = "rebalancerAddress is het nuladres; contract nog niet uitgerold";
    runtime.log(`Overgeslagen: ${skippedReason}`);
    return { feedAgeSeconds, ownersChecked: 0, dueOwners: [], txHash: "", skippedReason };
  }

  // 3. Owners aflopen en isDue() vragen.
  const dueOwners: Address[] = [];
  let ownersChecked = 0;
  for (let offset = 0n; ; offset += BigInt(config.ownersPageSize)) {
    const page = readContract(
      runtime,
      evmClient,
      config.rebalancerAddress,
      rebalancerAbi,
      "owners",
      [offset, BigInt(config.ownersPageSize)],
    ) as readonly Address[];
    if (page.length === 0) {
      break;
    }
    for (const owner of page) {
      ownersChecked += 1;
      const [due] = readContract(
        runtime,
        evmClient,
        config.rebalancerAddress,
        rebalancerAbi,
        "isDue",
        [owner],
      ) as readonly [boolean, bigint];
      if (due && dueOwners.length < config.maxOwnersPerReport) {
        dueOwners.push(owner);
      }
    }
    if (page.length < config.ownersPageSize) {
      break;
    }
  }
  runtime.log(`Owners gecontroleerd: ${ownersChecked}, due: ${dueOwners.length}`);

  if (dueOwners.length === 0) {
    runtime.log("Geen owner is due; geen rapport verstuurd");
    return { feedAgeSeconds, ownersChecked, dueOwners, txHash: "", skippedReason: "geen owner is due" };
  }

  // 4. Rapport tekenen en naar Rebalancer.onReport sturen.
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

  return { feedAgeSeconds, ownersChecked, dueOwners, txHash, skippedReason: "" };
};

export const initWorkflow = (config: Config) => {
  const cron = new CronCapability();
  return [handler(cron.trigger({ schedule: config.schedule }), onCronTrigger)];
};

export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}
