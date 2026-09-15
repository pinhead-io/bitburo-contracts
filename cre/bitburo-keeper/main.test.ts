import { describe, expect } from "bun:test";
import { bytesToHex, getNetwork } from "@chainlink/cre-sdk";
import { EvmMock, addContractMock, newTestRuntime, test } from "@chainlink/cre-sdk/test";
import { type Address, decodeAbiParameters, decodeFunctionData, parseAbiParameters } from "viem";
import {
  type Config,
  aggregatorAbi,
  encodeOwnersReport,
  initWorkflow,
  isFeedFresh,
  isSequencerReady,
  onCronTrigger,
  rebalancerAbi,
  rotatedPages,
  rotationStart,
  runSizeSkipReason,
} from "./main";

const REBALANCER = "0x1111111111111111111111111111111111111111" as Address;
const SEQUENCER_FEED = "0xBCF85224fc0756B9Fa45aA7892530B47e10b6433" as Address;
const FEED = "0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D" as Address;
const OWNER_A = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as Address;
const OWNER_B = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" as Address;
const NOW_MS = 1_800_000_000_000;
const EURC = 1_000_000n;

const baseConfig: Config = {
  schedule: "0 0 * * * *",
  chainSelectorName: "ethereum-mainnet-base-1",
  rebalancerAddress: REBALANCER,
  sequencerFeedAddress: SEQUENCER_FEED,
  sequencerGracePeriodSeconds: 3600,
  priceFeedAddress: FEED,
  maxFeedAgeSeconds: 1500,
  ownersPageSize: 50,
  maxOwnersPerReport: 5,
  maxCandidatesPerRun: 25,
  minRunEurc: 20,
  maxRunEurc: 8000,
  executeGasBudget: "700000",
  gasLimit: "4000000",
};

const chainSelector = (): bigint => {
  const network = getNetwork({ chainFamily: "evm", chainSelectorName: baseConfig.chainSelectorName });
  if (!network) throw new Error("chain selector ontbreekt");
  return network.chainSelector.selector;
};

const NOW_SECONDS = BigInt(NOW_MS / 1000);
/** Uurnummer dat bij NOW_MS hoort; de rotatie is daarvan afgeleid. */
const HOUR = NOW_SECONDS / 3600n;

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

/**
 * Het rapport eindigt op abi.encode(address[]): offset-woord 0x20, lengte n, dan n adressen. Zoek
 * vanaf het einde het kleinste n waarvoor die twee kopwoorden kloppen en decodeer dat stuk.
 */
const decodeReportedOwners = (rawReport: Uint8Array): Address[] => {
  for (let n = 0; n * 32 + 64 <= rawReport.length; n++) {
    const hex = bytesToHex(rawReport.slice(rawReport.length - (n + 2) * 32));
    if (BigInt(`0x${hex.slice(2, 66)}`) === 32n && BigInt(`0x${hex.slice(66, 130)}`) === BigInt(n)) {
      const [owners] = decodeAbiParameters(parseAbiParameters("address[]"), hex) as [Address[]];
      return owners.map((a) => a.toLowerCase() as Address);
    }
  }
  throw new Error("rapport bevat geen address[]");
};

type RebalancerMockOptions = {
  owners: readonly Address[];
  /** eurcDelta per owner (basiseenheden); owners die ontbreken zijn niet due. */
  deltas: Record<string, bigint>;
  /** Gasschatting per owner; een string laat de simulatie reverten met die boodschap. */
  gas?: Record<string, bigint | string>;
};

/**
 * Rebalancer-mock: dueOwners levert de owners uit `deltas` in lijstvolgorde binnen de pagina,
 * isDue geeft de delta terug, estimateGas geeft de schatting of gooit een fout.
 */
const mockRebalancer = (evmMock: EvmMock, { owners, deltas, gas = {} }: RebalancerMockOptions) => {
  const calls = { dueOwnersPages: [] as [bigint, bigint][], isDue: [] as Address[], estimateGas: [] as Address[], reported: [] as Address[] };
  const rebalancer = addContractMock(evmMock, { address: REBALANCER, abi: rebalancerAbi });
  rebalancer.ownerCount = () => BigInt(owners.length);
  rebalancer.dueOwners = (offset, limit) => {
    calls.dueOwnersPages.push([offset as bigint, limit as bigint]);
    return owners.slice(Number(offset), Number(offset) + Number(limit)).filter((owner) => deltas[owner] !== undefined);
  };
  rebalancer.isDue = (owner) => {
    const address = (owner as string).toLowerCase() as Address;
    calls.isDue.push(address);
    const delta = deltas[address];
    return delta === undefined ? [false, 0n] : [true, delta];
  };
  evmMock.estimateGas = (input) => {
    const { args } = decodeFunctionData({ abi: rebalancerAbi, data: bytesToHex(input.msg?.data ?? new Uint8Array()) });
    const owner = (args?.[0] as string).toLowerCase() as Address;
    calls.estimateGas.push(owner);
    const estimate = gas[owner] ?? 450_000n;
    if (typeof estimate === "string") throw new Error(estimate);
    return { gas: estimate.toString() };
  };
  rebalancer.writeReport = (input) => {
    calls.reported = decodeReportedOwners(input.report.rawReport);
    return { txStatus: "TX_STATUS_SUCCESS", receiverContractExecutionStatus: "RECEIVER_CONTRACT_EXECUTION_STATUS_SUCCESS", txHash: new Uint8Array(32).fill(1) } as never;
  };
  return { rebalancer, calls };
};

const lower = (addresses: readonly Address[]) => addresses.map((a) => a.toLowerCase());

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

  test("rotationStart advances maxOwnersPerReport places per hour and wraps around", () => {
    expect(rotationStart(0n, 5, 12n)).toBe(0n);
    expect(rotationStart(1n, 5, 12n)).toBe(5n);
    expect(rotationStart(2n, 5, 12n)).toBe(10n);
    expect(rotationStart(3n, 5, 12n)).toBe(3n);
    expect(rotationStart(7n, 5, 0n)).toBe(0n);
  });

  test("rotationStart gives every owner a turn within ceil(ownerCount / maxOwnersPerReport) hours", () => {
    const ownerCount = 12n;
    const seen = new Set<bigint>();
    for (let hour = 100n; hour < 103n; hour++) {
      const start = rotationStart(hour, 5, ownerCount);
      for (let i = 0n; i < 5n; i++) seen.add((start + i) % ownerCount);
    }
    expect(seen.size).toBe(12);
  });

  test("rotatedPages covers the whole list exactly once starting at the rotation point", () => {
    expect(rotatedPages(0n, 6n, 2)).toEqual([
      { offset: 0n, limit: 2n },
      { offset: 2n, limit: 2n },
      { offset: 4n, limit: 2n },
    ]);
    expect(rotatedPages(3n, 6n, 2)).toEqual([
      { offset: 3n, limit: 2n },
      { offset: 5n, limit: 1n },
      { offset: 0n, limit: 2n },
      { offset: 2n, limit: 1n },
    ]);
    expect(rotatedPages(0n, 0n, 50)).toEqual([]);
    expect(rotatedPages(1n, 3n, 50)).toEqual([
      { offset: 1n, limit: 2n },
      { offset: 0n, limit: 1n },
    ]);
  });

  test("runSizeSkipReason skips dust and oversized runs in both directions", () => {
    expect(runSizeSkipReason(20n * EURC, 20, 8000)).toBeNull();
    expect(runSizeSkipReason(-20n * EURC, 20, 8000)).toBeNull();
    expect(runSizeSkipReason(8000n * EURC, 20, 8000)).toBeNull();
    expect(runSizeSkipReason(19_999_999n, 20, 8000)).toContain("te klein");
    expect(runSizeSkipReason(-100n, 20, 8000)).toContain("te klein");
    expect(runSizeSkipReason(8000n * EURC + 1n, 20, 8000)).toContain("te groot");
    expect(runSizeSkipReason(-9000n * EURC, 20, 8000)).toContain("keeper-script");
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
    mockFeed(EvmMock.testInstance(chainSelector()), NOW_SECONDS - 5000n);

    const result = onCronTrigger(runtime);

    expect(result.skippedReason).toContain("feed te oud");
    expect(result.txHash).toBe("");
  });

  test("skips when the rebalancer address is the zero address", () => {
    const config = { ...baseConfig, rebalancerAddress: "0x0000000000000000000000000000000000000000" as Address };
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW_MS }, config);
    mockFeed(EvmMock.testInstance(chainSelector()), NOW_SECONDS - 60n);

    const result = onCronTrigger(runtime);

    expect(result.skippedReason).toContain("nuladres");
    expect(result.ownersChecked).toBe(0);
  });

  test("reports only the owners that are due, after isDue and a simulation", () => {
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW_MS }, baseConfig);
    const evmMock = EvmMock.testInstance(chainSelector());
    mockFeed(evmMock, NOW_SECONDS - 60n);
    const { calls } = mockRebalancer(evmMock, { owners: [OWNER_A, OWNER_B], deltas: { [OWNER_B]: 100n * EURC } });

    const result = onCronTrigger(runtime);

    expect(result.ownersChecked).toBe(2);
    expect(result.candidatesChecked).toBe(1);
    expect(lower(result.dueOwners)).toEqual([OWNER_B]);
    expect(result.skippedOwners).toEqual([]);
    expect(calls.isDue).toEqual([OWNER_B]);
    expect(calls.estimateGas).toEqual([OWNER_B]);
    expect(calls.reported).toEqual([OWNER_B]);
    expect(result.txHash).toBe(`0x${"01".repeat(32)}`);
  });

  test("does not write when no owner is due", () => {
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW_MS }, baseConfig);
    const evmMock = EvmMock.testInstance(chainSelector());
    mockFeed(evmMock, NOW_SECONDS - 60n);
    const { calls } = mockRebalancer(evmMock, { owners: [OWNER_A], deltas: {} });

    const result = onCronTrigger(runtime);

    expect(result.ownersChecked).toBe(1);
    expect(result.dueOwners).toEqual([]);
    expect(result.skippedReason).toBe("geen owner is due");
    expect(result.txHash).toBe("");
    expect(calls.reported).toEqual([]);
  });

  test("skips dust owners and oversized runs on |eurcDelta| and keeps the rest", () => {
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW_MS }, baseConfig);
    const evmMock = EvmMock.testInstance(chainSelector());
    mockFeed(evmMock, NOW_SECONDS - 60n);
    const owners = Array.from({ length: 4 }, (_, i) => `0x${(i + 1).toString(16).padStart(40, "0")}` as Address);
    const { calls } = mockRebalancer(evmMock, {
      owners,
      deltas: { [owners[0]]: 100n, [owners[1]]: -9000n * EURC, [owners[2]]: -50n * EURC, [owners[3]]: 20n * EURC },
    });

    const result = onCronTrigger(runtime);

    expect(result.candidatesChecked).toBe(4);
    expect(lower(result.dueOwners)).toEqual([owners[2], owners[3]]);
    expect(result.skippedOwners.map((s) => [s.owner.toLowerCase(), s.reason])).toEqual([
      [owners[0], expect.stringContaining("te klein")],
      [owners[1], expect.stringContaining("te groot")],
    ]);
    // Dust en te grote runs worden niet meer gesimuleerd: dat scheelt calls.
    expect(calls.estimateGas).toEqual([owners[2], owners[3]]);
    expect(calls.reported).toEqual([owners[2], owners[3]]);
    expect(runtime.getLogs().some((line) => line.includes(`Overgeslagen ${owners[1]}`) && line.includes("keeper-script"))).toBe(true);
  });

  test("skips owners whose execute simulation reverts or exceeds the gas budget", () => {
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW_MS }, baseConfig);
    const evmMock = EvmMock.testInstance(chainSelector());
    mockFeed(evmMock, NOW_SECONDS - 60n);
    const owners = Array.from({ length: 3 }, (_, i) => `0x${(i + 1).toString(16).padStart(40, "0")}` as Address);
    const { calls } = mockRebalancer(evmMock, {
      owners,
      deltas: { [owners[0]]: 100n * EURC, [owners[1]]: 100n * EURC, [owners[2]]: 100n * EURC },
      gas: { [owners[0]]: "execution reverted: Too little received", [owners[1]]: 700_001n },
    });

    const result = onCronTrigger(runtime);

    expect(lower(result.dueOwners)).toEqual([owners[2]]);
    expect(result.skippedOwners).toHaveLength(2);
    expect(result.skippedOwners.map((s) => s.reason)).toEqual(
      expect.arrayContaining([
        expect.stringContaining("simulatie van execute mislukt: execution reverted: Too little received"),
        expect.stringContaining("700001 gas > budget 700000"),
      ]),
    );
    expect(calls.reported).toEqual([owners[2]]);
  });

  test("skips an owner that is no longer due at isDue time", () => {
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW_MS }, baseConfig);
    const evmMock = EvmMock.testInstance(chainSelector());
    mockFeed(evmMock, NOW_SECONDS - 60n);
    const { rebalancer, calls } = mockRebalancer(evmMock, { owners: [OWNER_A], deltas: { [OWNER_A]: 100n * EURC } });
    rebalancer.isDue = () => [false, 0n];

    const result = onCronTrigger(runtime);

    expect(result.dueOwners).toEqual([]);
    expect(result.skippedOwners.map((s) => [s.owner.toLowerCase(), s.reason])).toEqual([[OWNER_A, "niet meer due"]]);
    expect(result.skippedReason).toBe("geen owner over na filtering");
    expect(calls.estimateGas).toEqual([]);
    expect(calls.reported).toEqual([]);
  });

  test("does not write an empty report when every due owner is filtered out", () => {
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW_MS }, baseConfig);
    const evmMock = EvmMock.testInstance(chainSelector());
    mockFeed(evmMock, NOW_SECONDS - 60n);
    const { calls } = mockRebalancer(evmMock, { owners: [OWNER_A, OWNER_B], deltas: { [OWNER_A]: 1n, [OWNER_B]: -1n } });

    const result = onCronTrigger(runtime);

    expect(result.candidatesChecked).toBe(2);
    expect(result.skippedOwners).toHaveLength(2);
    expect(result.skippedReason).toBe("geen owner over na filtering");
    expect(result.txHash).toBe("");
    expect(calls.reported).toEqual([]);
  });

  test("stops evaluating after maxCandidatesPerRun", () => {
    // maxOwnersPerReport 3 op 3 owners: startindex (uur × 3) mod 3 = 0, dus owner 1 en 2 komen eerst.
    const config = { ...baseConfig, maxCandidatesPerRun: 2, maxOwnersPerReport: 3 };
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW_MS }, config);
    const evmMock = EvmMock.testInstance(chainSelector());
    mockFeed(evmMock, NOW_SECONDS - 60n);
    const owners = Array.from({ length: 3 }, (_, i) => `0x${(i + 1).toString(16).padStart(40, "0")}` as Address);
    const { calls } = mockRebalancer(evmMock, { owners, deltas: { [owners[0]]: 1n, [owners[1]]: 1n, [owners[2]]: 100n * EURC } });

    const result = onCronTrigger(runtime);

    expect(result.candidatesChecked).toBe(2);
    expect(calls.isDue).toHaveLength(2);
    expect(result.dueOwners).toEqual([]);
    expect(result.skippedReason).toBe("geen owner over na filtering");
  });

  test("rotates the start index per hour, pages cyclically and caps the report at maxOwnersPerReport", () => {
    const config = { ...baseConfig, ownersPageSize: 2, maxOwnersPerReport: 3 };
    const hourMs = Number((HOUR + 1n) * 3600n) * 1000;
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => hourMs }, config);
    const evmMock = EvmMock.testInstance(chainSelector());
    mockFeed(evmMock, BigInt(hourMs / 1000) - 60n);
    const owners = Array.from({ length: 6 }, (_, i) => `0x${(i + 1).toString(16).padStart(40, "0")}` as Address);
    const deltas = Object.fromEntries(owners.map((owner) => [owner, 100n * EURC]));
    const { calls } = mockRebalancer(evmMock, { owners, deltas });

    const result = onCronTrigger(runtime);

    // (uur + 1) × 3 mod 6 = 3 voor dit uurnummer: de run begint bij owner 4, niet bij owner 1.
    expect(rotationStart(HOUR + 1n, 3, 6n)).toBe(3n);
    expect(result.ownersChecked).toBe(6);
    expect(lower(result.dueOwners)).toEqual([owners[3], owners[4], owners[5]]);
    // Na de tweede pagina is het rapport vol; de pagina's vanaf 0 worden niet meer opgevraagd.
    expect(calls.dueOwnersPages).toEqual([
      [3n, 2n],
      [5n, 1n],
    ]);
    expect(calls.reported).toEqual([owners[3], owners[4], owners[5]]);
    expect(result.txHash).toBe(`0x${"01".repeat(32)}`);
  });

  test("every due owner gets a turn over consecutive hours even when dust owners come first", () => {
    const config = { ...baseConfig, maxOwnersPerReport: 2, minRunEurc: 0 };
    const owners = Array.from({ length: 6 }, (_, i) => `0x${(i + 1).toString(16).padStart(40, "0")}` as Address);
    const deltas = Object.fromEntries(owners.map((owner) => [owner, 100n * EURC]));
    const served = new Set<string>();

    for (let hour = 0n; hour < 3n; hour++) {
      const hourMs = Number((HOUR + hour) * 3600n) * 1000;
      const runtime = newTestRuntime<Config>(null, { timeProvider: () => hourMs }, config);
      const evmMock = EvmMock.testInstance(chainSelector());
      mockFeed(evmMock, BigInt(hourMs / 1000) - 60n);
      mockRebalancer(evmMock, { owners, deltas });
      for (const owner of onCronTrigger(runtime).dueOwners) served.add(owner.toLowerCase());
    }

    expect(served.size).toBe(6);
  });

  test("throws when the receiver contract reverted although the forwarder transaction succeeded", () => {
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW_MS }, baseConfig);
    const evmMock = EvmMock.testInstance(chainSelector());
    mockFeed(evmMock, NOW_SECONDS - 60n);
    const { rebalancer } = mockRebalancer(evmMock, { owners: [OWNER_A], deltas: { [OWNER_A]: 100n * EURC } });
    rebalancer.writeReport = () =>
      ({
        txStatus: "TX_STATUS_SUCCESS",
        receiverContractExecutionStatus: "RECEIVER_CONTRACT_EXECUTION_STATUS_REVERTED",
        txHash: new Uint8Array(32).fill(3),
      }) as never;

    expect(() => onCronTrigger(runtime)).toThrow(/gerevert in het Rebalancer-contract.*0x0303/);
    expect(runtime.getLogs().some((line) => line.includes("receiverStatus=REVERTED"))).toBe(true);
  });

  test("throws when the forwarder transaction itself failed", () => {
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW_MS }, baseConfig);
    const evmMock = EvmMock.testInstance(chainSelector());
    mockFeed(evmMock, NOW_SECONDS - 60n);
    const { rebalancer } = mockRebalancer(evmMock, { owners: [OWNER_A], deltas: { [OWNER_A]: 100n * EURC } });
    rebalancer.writeReport = () => ({ txStatus: "TX_STATUS_REVERTED", errorMessage: "out of gas" }) as never;

    expect(() => onCronTrigger(runtime)).toThrow("onReport mislukt: out of gas");
  });
});

describe("initWorkflow", () => {
  test("registers one cron handler with the configured schedule", () => {
    const handlers = initWorkflow(baseConfig);
    expect(handlers).toHaveLength(1);
    expect(handlers[0].trigger.config.schedule).toBe(baseConfig.schedule);
  });
});
