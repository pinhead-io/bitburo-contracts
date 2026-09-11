/**
 * Bitburo keeper-script. Iedereen mag dit draaien; Bitburo is niet nodig.
 *
 * Vraagt het Rebalancer-contract per pagina dueOwners(offset, limit) en roept execute(owner, rewardTo) aan
 * voor wie due is. isDue(owner) wordt alleen nog voor die owners gelezen, voor de richting en het bedrag in het
 * logbericht. De beloning (0,05 EURC per run) gaat naar REWARD_TO, standaard het eigen adres.
 * Het script beslist niets: het contract bepaalt of, wat en hoeveel.
 *
 * Gebruik:
 *   RPC_URL=https://mainnet.base.org REBALANCER=0x… KEEPER_PRIVATE_KEY=0x… bun run keeper.ts
 * Optioneel: REWARD_TO=0x…  PAGE_SIZE=50  DRY_RUN=1
 */
import { createPublicClient, createWalletClient, http, isAddress, parseAbi, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";

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
if (!isAddress(rebalancer)) throw new Error("REBALANCER is geen geldig adres");

const publicClient = createPublicClient({ chain: base, transport: http(rpcUrl) });
const account = dryRun ? undefined : privateKeyToAccount(env("KEEPER_PRIVATE_KEY") as Hex);
const rewardTo = (process.env.REWARD_TO ?? account?.address ?? "0x0000000000000000000000000000000000000000") as Address;
const walletClient = account ? createWalletClient({ account, chain: base, transport: http(rpcUrl) }) : undefined;

const read = <T>(functionName: "ownerCount" | "dueOwners" | "isDue", args: readonly unknown[] = []) =>
  // biome-ignore lint/suspicious/noExplicitAny: viem's ABI-generics zijn te strikt voor een gedeelde helper
  publicClient.readContract({ address: rebalancer, abi, functionName, args } as any) as Promise<T>;

const checked = await read<bigint>("ownerCount");
let executed = 0;
for (let offset = 0n; offset < checked; offset += pageSize) {
  const page = await read<readonly Address[]>("dueOwners", [offset, pageSize]);

  for (const owner of page) {
    const [, eurcDelta] = await read<readonly [boolean, bigint]>("isDue", [owner]);
    const direction = eurcDelta > 0n ? "koop" : "verkoop";
    const eurc = (eurcDelta < 0n ? -eurcDelta : eurcDelta) / 1_000_000n;
    if (dryRun || !walletClient) {
      console.log(`[dry-run] ${owner}: ${direction} ≈ ${eurc} EURC`);
      continue;
    }
    try {
      const hash = await walletClient.writeContract({ address: rebalancer, abi, functionName: "execute", args: [owner, rewardTo] });
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      console.log(`${owner}: ${direction} ≈ ${eurc} EURC → ${receipt.status} ${hash}`);
      if (receipt.status === "success") executed += 1;
    } catch (error) {
      console.error(`${owner}: execute mislukt: ${(error as Error).message.split("\n")[0]}`);
    }
  }
}

console.log(`Klaar: ${checked} owners gecontroleerd, ${executed} uitgevoerd${dryRun ? " (dry-run)" : ""}.`);
