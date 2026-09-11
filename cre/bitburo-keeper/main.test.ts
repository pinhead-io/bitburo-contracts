import { describe, expect } from "bun:test";
import { getNetwork } from "@chainlink/cre-sdk";
import { EvmMock, addContractMock, newTestRuntime, test } from "@chainlink/cre-sdk/test";
import { type Address, decodeAbiParameters, parseAbiParameters } from "viem";
import {
  type Config,
  aggregatorAbi,
  encodeOwnersReport,
  initWorkflow,
  isFeedFresh,
  isSequencerReady,
  onCronTrigger,
  rebalancerAbi,
} from "./main";

const REBALANCER = "0x1111111111111111111111111111111111111111" as Address;
const SEQUENCER_FEED = "0xBCF85224fc0756B9Fa45aA7892530B47e10b6433" as Address;
const FEED = "0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D" as Address;
const OWNER_A = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as Address;
const OWNER_B = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" as Address;
const NOW_MS = 1_800_000_000_000;

const baseConfig: Config = {
  schedule: "0 0 * * * *",
  chainSelectorName: "ethereum-mainnet-base-1",
  rebalancerAddress: REBALANCER,
  sequencerFeedAddress: SEQUENCER_FEED,
  sequencerGracePeriodSeconds: 3600,
  priceFeedAddress: FEED,
  maxFeedAgeSeconds: 1500,
  ownersPageSize: 50,
  maxOwnersPerReport: 20,
  gasLimit: "4000000",
};

const chainSelector = (): bigint => {
  const network = getNetwork({ chainFamily: "evm", chainSelectorName: baseConfig.chainSelectorName });
  if (!network) throw new Error("chain selector ontbreekt");
  return network.chainSelector.selector;
};

const NOW_SECONDS = BigInt(NOW_MS / 1000);

/** answer 0 = up, 1 = down; startedAt = moment van de laatste statuswissel. */
const mockSequencer = (evmMock: EvmMock, answer: bigint, startedAtSeconds: bigint) => {
  const sequencer = addContractMock(evmMock, { address: SEQUENCER_FEED, abi: aggregatorAbi });
  sequencer.latestRoundData = () => [1n, answer, startedAtSeconds, startedAtSeconds, 1n];
};

/** Prijsfeed met een sequencer die al ruim buiten de grace period up is. */
const mockFeed = (evmMock: EvmMock, updatedAtSeconds: bigint) => {
  mockSequencer(evmMock, 0n, NOW_SECONDS - 86_400n);
  const feed = addContractMock(evmMock, { address: FEED, abi: aggregatorAbi });
  feed.latestRoundData = () => [1n, 7_945_898_000_000n, updatedAtSeconds, updatedAtSeconds, 1n];
};

describe("pure helpers", () => {
  test("isSequencerReady requires answer 0 and an elapsed grace period", () => {
    expect(isSequencerReady(0n, 1000n, 4600n, 3600)).toBe(true);
    expect(isSequencerReady(0n, 1000n, 4599n, 3600)).toBe(false);
    expect(isSequencerReady(1n, 1000n, 4600n, 3600)).toBe(false);
  });

  test("encodeOwnersReport encodes an address[] the contract can abi.decode", () => {
    const encoded = encodeOwnersReport([OWNER_A, OWNER_B]);
    const [decoded] = decodeAbiParameters(parseAbiParameters("address[]"), encoded);
    expect(decoded.map((a) => a.toLowerCase())).toEqual([OWNER_A, OWNER_B]);
  });

  test("isFeedFresh respects the maximum age", () => {
    expect(isFeedFresh(1000n, 2500n, 1500)).toBe(true);
    expect(isFeedFresh(1000n, 2501n, 1500)).toBe(false);
  });
});

describe("onCronTrigger", () => {
  test("skips when the sequencer is down", () => {
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW_MS }, baseConfig);
    mockSequencer(EvmMock.testInstance(chainSelector()), 1n, NOW_SECONDS - 600n);

    const result = onCronTrigger(runtime);

    expect(result.skippedReason).toContain("sequencer down");
    expect(result.feedAgeSeconds).toBe(0);
    expect(result.txHash).toBe("");
  });

  test("skips when the sequencer came back within the grace period", () => {
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW_MS }, baseConfig);
    mockSequencer(EvmMock.testInstance(chainSelector()), 0n, NOW_SECONDS - 3599n);

    const result = onCronTrigger(runtime);

    expect(result.skippedReason).toContain("sequencer net terug");
    expect(result.sequencerUpSeconds).toBe(3599);
    expect(result.txHash).toBe("");
  });

  test("continues to the price feed check when the sequencer is up past the grace period", () => {
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW_MS }, baseConfig);
    const evmMock = EvmMock.testInstance(chainSelector());
    mockSequencer(evmMock, 0n, NOW_SECONDS - 3600n);
    const feed = addContractMock(evmMock, { address: FEED, abi: aggregatorAbi });
    feed.latestRoundData = () => [1n, 7_945_898_000_000n, NOW_SECONDS - 5000n, NOW_SECONDS - 5000n, 1n];

    const result = onCronTrigger(runtime);

    expect(result.sequencerUpSeconds).toBe(3600);
    expect(result.skippedReason).toContain("feed te oud");
  });

  test("skips when the price feed is stale", () => {
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW_MS }, baseConfig);
    mockFeed(EvmMock.testInstance(chainSelector()), BigInt(NOW_MS / 1000) - 5000n);

    const result = onCronTrigger(runtime);

    expect(result.skippedReason).toContain("feed te oud");
    expect(result.txHash).toBe("");
  });

  test("skips when the rebalancer address is the zero address", () => {
    const config = { ...baseConfig, rebalancerAddress: "0x0000000000000000000000000000000000000000" as Address };
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW_MS }, config);
    mockFeed(EvmMock.testInstance(chainSelector()), BigInt(NOW_MS / 1000) - 60n);

    const result = onCronTrigger(runtime);

    expect(result.skippedReason).toContain("nuladres");
    expect(result.ownersChecked).toBe(0);
  });

  test("reports only the owners that are due", () => {
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW_MS }, baseConfig);
    const evmMock = EvmMock.testInstance(chainSelector());
    mockFeed(evmMock, BigInt(NOW_MS / 1000) - 60n);

    const rebalancer = addContractMock(evmMock, { address: REBALANCER, abi: rebalancerAbi });
    rebalancer.owners = (offset) => ((offset as bigint) === 0n ? [OWNER_A, OWNER_B] : []);
    rebalancer.isDue = (owner) => [(owner as string).toLowerCase() === OWNER_B, 0n];
    let reported: Address[] = [];
    rebalancer.writeReport = (input) => {
      const payload = input.report.rawReport.slice(input.report.rawReport.length - 96);
      const hex = `0x${Array.from(payload, (b) => b.toString(16).padStart(2, "0")).join("")}` as const;
      [reported] = decodeAbiParameters(parseAbiParameters("address[]"), hex) as [Address[]];
      return { txStatus: "TX_STATUS_SUCCESS", txHash: new Uint8Array(32).fill(1) } as never;
    };

    const result = onCronTrigger(runtime);

    expect(result.ownersChecked).toBe(2);
    expect(result.dueOwners.map((a) => a.toLowerCase())).toEqual([OWNER_B]);
    expect(reported.map((a) => a.toLowerCase())).toEqual([OWNER_B]);
    expect(result.txHash).toBe(`0x${"01".repeat(32)}`);
  });

  test("does not write when no owner is due", () => {
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW_MS }, baseConfig);
    const evmMock = EvmMock.testInstance(chainSelector());
    mockFeed(evmMock, BigInt(NOW_MS / 1000) - 60n);
    const rebalancer = addContractMock(evmMock, { address: REBALANCER, abi: rebalancerAbi });
    rebalancer.owners = (offset) => ((offset as bigint) === 0n ? [OWNER_A] : []);
    rebalancer.isDue = () => [false, 0n];

    const result = onCronTrigger(runtime);

    expect(result.dueOwners).toEqual([]);
    expect(result.txHash).toBe("");
  });
});

describe("initWorkflow", () => {
  test("registers one cron handler with the configured schedule", () => {
    const handlers = initWorkflow(baseConfig);
    expect(handlers).toHaveLength(1);
    expect(handlers[0].trigger.config.schedule).toBe(baseConfig.schedule);
  });
});
