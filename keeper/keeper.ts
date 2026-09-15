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
 * Gebruik:
 *   RPC_URL=https://mainnet.base.org REBALANCER=0x… KEEPER_PRIVATE_KEY=0x… bun run keeper.ts
 * Optioneel: REWARD_TO=0x…  PAGE_SIZE=50  DRY_RUN=1  MIN_RUN_EURC=20
 *            COOLDOWN_FILE=./keeper-cooldowns.json  COOLDOWN_SECONDS=3600  COOLDOWN_MAX_SECONDS=86400
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { BaseError, ContractFunctionRevertedError, createPublicClient, createWalletClient, http, isAddress, parseAbi, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import {
  type CooldownState,
  clearFailure,
  cooldownUntil,
  formatEurc,
  isCoolingDown,
  parseCooldownState,
  pruneExpired,
  recordFailure,
  runSizeSkipReason,
} from "./selection";

const abi = parseAbi([
  "function ownerCount() view returns (uint256)",
  "function dueOwners(uint256 offset, uint256 limit) view returns (address[])",
  "function isDue(address owner) view returns (bool due, int256 eurcDelta)",
  "function execute(address owner, address rewardTo)",
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
const cooldownFile = env("COOLDOWN_FILE", "./keeper-cooldowns.json");
const cooldownPolicy = {
  baseSeconds: Number(env("COOLDOWN_SECONDS", "3600")),
  maxSeconds: Number(env("COOLDOWN_MAX_SECONDS", "86400")),
};
if (!isAddress(rebalancer)) throw new Error("REBALANCER is geen geldig adres");
if (!Number.isFinite(minRunEurc) || minRunEurc < 0) throw new Error("MIN_RUN_EURC moet een getal >= 0 zijn");

const publicClient = createPublicClient({ chain: base, transport: http(rpcUrl) });
const account = dryRun ? undefined : privateKeyToAccount(env("KEEPER_PRIVATE_KEY") as Hex);
const rewardTo = (process.env.REWARD_TO ?? account?.address ?? "0x0000000000000000000000000000000000000000") as Address;
const walletClient = account ? createWalletClient({ account, chain: base, transport: http(rpcUrl) }) : undefined;

const read = <T>(functionName: "ownerCount" | "dueOwners" | "isDue", args: readonly unknown[] = []) =>
  // biome-ignore lint/suspicious/noExplicitAny: viem's ABI-generics zijn te strikt voor een gedeelde helper
  publicClient.readContract({ address: rebalancer, abi, functionName, args } as any) as Promise<T>;

/** Eerste regel van een viem-fout, met de contract-error als die er is (bijvoorbeeld NotDue()). */
const describeError = (error: unknown): string => {
  if (error instanceof BaseError) {
    const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError && reverted.data?.errorName) {
      return `${reverted.data.errorName}(${(reverted.data.args ?? []).join(", ")})`;
    }
    return error.shortMessage;
  }
  return (error as Error).message.split("\n")[0];
};

let cooldowns: CooldownState = existsSync(cooldownFile) ? parseCooldownState(readFileSync(cooldownFile, "utf8")) : {};
const nowSeconds = Math.floor(Date.now() / 1000);
cooldowns = pruneExpired(cooldowns, nowSeconds);
const saveCooldowns = () => writeFileSync(cooldownFile, `${JSON.stringify(cooldowns, null, 2)}\n`);
const failed = (owner: Address, error: unknown) => {
  const message = describeError(error);
  cooldowns = recordFailure(cooldowns, owner, nowSeconds, message, cooldownPolicy);
  saveCooldowns();
  const entry = cooldowns[owner.toLowerCase()];
  console.error(`${owner}: ${message}; cool-down tot ${new Date(entry.until * 1000).toISOString()} (mislukking ${entry.failures})`);
};

const checked = await read<bigint>("ownerCount");
let executed = 0;
let skipped = 0;
for (let offset = 0n; offset < checked; offset += pageSize) {
  const page = await read<readonly Address[]>("dueOwners", [offset, pageSize]);

  for (const owner of page) {
    if (isCoolingDown(cooldowns, owner, nowSeconds)) {
      console.log(`${owner}: overgeslagen, cool-down tot ${new Date((cooldownUntil(cooldowns, owner) ?? 0) * 1000).toISOString()}`);
      skipped += 1;
      continue;
    }
    const [due, eurcDelta] = await read<readonly [boolean, bigint]>("isDue", [owner]);
    if (!due) {
      console.log(`${owner}: niet meer due`);
      skipped += 1;
      continue;
    }
    const direction = eurcDelta > 0n ? "koop" : "verkoop";
    const eurc = formatEurc(eurcDelta < 0n ? -eurcDelta : eurcDelta);
    const sizeReason = runSizeSkipReason(eurcDelta, minRunEurc);
    if (sizeReason !== null) {
      console.log(`${owner}: overgeslagen, ${sizeReason}`);
      skipped += 1;
      continue;
    }

    // Eerst simuleren: een owner die revert (dust dat op de route naar 0 afrondt, blacklist, te krappe
    // slippage) blijft in dueOwners staan en zou anders elke run ~160k gas kosten zonder beloning.
    let request: Parameters<NonNullable<typeof walletClient>["writeContract"]>[0];
    try {
      ({ request } = await publicClient.simulateContract({
        address: rebalancer,
        abi,
        functionName: "execute",
        args: [owner, rewardTo],
        account,
      }));
    } catch (error) {
      failed(owner, error);
      skipped += 1;
      continue;
    }

    if (dryRun || !walletClient) {
      console.log(`[dry-run] ${owner}: ${direction} ≈ ${eurc} EURC (simulatie ok)`);
      continue;
    }
    try {
      const hash = await walletClient.writeContract(request);
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      console.log(`${owner}: ${direction} ≈ ${eurc} EURC → ${receipt.status} ${hash}`);
      if (receipt.status === "success") {
        executed += 1;
        cooldowns = clearFailure(cooldowns, owner);
        saveCooldowns();
      } else {
        failed(owner, new Error(`transactie ${hash} is gerevert`));
      }
    } catch (error) {
      failed(owner, error);
    }
  }
}

saveCooldowns();
console.log(`Klaar: ${checked} owners gecontroleerd, ${executed} uitgevoerd, ${skipped} overgeslagen${dryRun ? " (dry-run)" : ""}.`);
