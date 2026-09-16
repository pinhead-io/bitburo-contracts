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
 * - Een revert met PoolTouchedThisBlock of BlockMoveExceeded is tijdelijk: het script probeert die owner opnieuw in
 *   een volgend blok (tot BLOCK_RETRIES keer) en geeft geen cool-down. Dat geldt ook voor een transactie die on-chain
 *   revertte terwijl een nieuwe simulatie op dat blok slaagt.
 * - Na een geslaagde run wacht het script op een nieuw blok voordat het de volgende owner of pagina leest of
 *   simuleert; in hetzelfde blok is de pool meestal aangeraakt en zou een eth_call dat onterecht als "niet due" melden.
 * - dueOwners is een momentopname. Het script leest elke pagina daarom minstens twee keer, in opeenvolgende blokken,
 *   en behandelt owners die er dan pas in staan, tot een lezing niemand nieuw oplevert (hooguit BLOCK_RETRIES + 1
 *   lezingen).
 * Grote correcties gaan in delen die 10 minuten na elkaar mogen. Draai dit script daarom elke 10 minuten.
 *
 * Gebruik:
 *   RPC_URL=https://mainnet.base.org REBALANCER=0x… KEEPER_PRIVATE_KEY=0x… bun run keeper.ts
 * Optioneel: REWARD_TO=0x…  PAGE_SIZE=50  DRY_RUN=1  MIN_RUN_EURC=20  BLOCK_RETRIES=3  BLOCK_WAIT_SECONDS=30
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
  failureAction,
  formatEurc,
  isBlockWindowRevert,
  isCoolingDown,
  mustWaitForNextBlock,
  newOwners,
  parseCooldownState,
  pruneExpired,
  recordFailure,
  runSizeSkipReason,
  shouldReadPageAgain,
} from "./selection";

const abi = parseAbi([
  "function ownerCount() view returns (uint256)",
  "function dueOwners(uint256 offset, uint256 limit) view returns (address[])",
  "function isDue(address owner) view returns (bool due, int256 eurcDelta)",
  "function execute(address owner, address rewardTo)",
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
const cooldownFile = env("COOLDOWN_FILE", "./keeper-cooldowns.json");
const cooldownPolicy = {
  baseSeconds: Number(env("COOLDOWN_SECONDS", "3600")),
  maxSeconds: Number(env("COOLDOWN_MAX_SECONDS", "86400")),
};
if (!isAddress(rebalancer)) throw new Error("REBALANCER is geen geldig adres");
if (!Number.isFinite(minRunEurc) || minRunEurc < 0) throw new Error("MIN_RUN_EURC moet een getal >= 0 zijn");
if (!Number.isInteger(blockRetries) || blockRetries < 0) throw new Error("BLOCK_RETRIES moet een geheel getal >= 0 zijn");

const publicClient = createPublicClient({ chain: base, transport: http(rpcUrl) });
const account = dryRun ? undefined : privateKeyToAccount(env("KEEPER_PRIVATE_KEY") as Hex);
const rewardTo = (process.env.REWARD_TO ?? account?.address ?? "0x0000000000000000000000000000000000000000") as Address;
const walletClient = account ? createWalletClient({ account, chain: base, transport: http(rpcUrl) }) : undefined;

const read = <T>(functionName: "ownerCount" | "dueOwners" | "isDue", args: readonly unknown[] = []) =>
  // biome-ignore lint/suspicious/noExplicitAny: viem's ABI-generics zijn te strikt voor een gedeelde helper
  publicClient.readContract({ address: rebalancer, abi, functionName, args } as any) as Promise<T>;

const simulateExecute = (owner: Address, blockNumber?: bigint) =>
  publicClient.simulateContract({
    address: rebalancer,
    abi,
    functionName: "execute",
    args: [owner, rewardTo],
    account,
    ...(blockNumber === undefined ? {} : { blockNumber }),
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

/** Wacht tot er een blok ná `block` is (Base: ~2 s per blok), hooguit BLOCK_WAIT_SECONDS. */
const waitForBlockAfter = async (block: bigint | null): Promise<boolean> => {
  const deadline = Date.now() + blockWaitSeconds * 1000;
  for (;;) {
    if (!mustWaitForNextBlock(await publicClient.getBlockNumber({ cacheTime: 0 }), block)) return true;
    if (Date.now() >= deadline) return false;
    await Bun.sleep(1000);
  }
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

/** Blok van de laatste geslaagde run in deze keeper-run; de volgende owner pas in een later blok. */
let lastRunBlock: bigint | null = null;

type Outcome = "executed" | "skipped" | "dry-run";

/** Eén owner: lezen, simuleren en uitvoeren, met nieuwe pogingen in een volgend blok bij een vol blokvenster. */
const handleOwner = async (owner: Address): Promise<Outcome> => {
  let retryAfterBlock: bigint | null = null;
  for (let attempt = 0; ; attempt += 1) {
    const waitAfter = retryAfterBlock ?? lastRunBlock;
    if (!(await waitForBlockAfter(waitAfter))) {
      console.log(`${owner}: overgeslagen, geen nieuw blok binnen ${blockWaitSeconds} s`);
      return "skipped";
    }
    const block = await publicClient.getBlockNumber({ cacheTime: 0 });
    const [due, eurcDelta] = await read<readonly [boolean, bigint]>("isDue", [owner]);
    const direction = eurcDelta > 0n ? "koop" : "verkoop";
    const eurc = formatEurc(eurcDelta < 0n ? -eurcDelta : eurcDelta);
    if (due) {
      const sizeReason = runSizeSkipReason(eurcDelta, minRunEurc);
      if (sizeReason !== null) {
        console.log(`${owner}: overgeslagen, ${sizeReason}`);
        return "skipped";
      }
    }

    // Eerst simuleren: een owner die revert (dust dat op de route naar 0 afrondt, blacklist, te krappe
    // slippage) blijft in dueOwners staan en zou anders elke run ~160k gas kosten zonder beloning. Ook als isDue
    // false zegt: dat kan een vol blokvenster zijn, en alleen de simulatie geeft de reden.
    let request: Awaited<ReturnType<typeof simulateExecute>>["request"] | undefined;
    let failure: unknown;
    let resimulationPassed = false;
    try {
      ({ request } = await simulateExecute(owner));
    } catch (error) {
      failure = error;
    }

    if (!due && !isBlockWindowRevert(errorNameOf(failure))) {
      console.log(`${owner}: niet meer due${failure === undefined ? "" : ` (${describeError(failure)})`}`);
      return "skipped";
    }

    if (failure === undefined && request !== undefined) {
      if (dryRun || !walletClient) {
        console.log(`[dry-run] ${owner}: ${direction} ≈ ${eurc} EURC (simulatie ok)`);
        return "dry-run";
      }
      try {
        const hash = await walletClient.writeContract(request);
        const receipt = await publicClient.waitForTransactionReceipt({ hash });
        console.log(`${owner}: ${direction} ≈ ${eurc} EURC → ${receipt.status} ${hash}`);
        lastRunBlock = receipt.blockNumber;
        if (receipt.status === "success") {
          cooldowns = clearFailure(cooldowns, owner);
          saveCooldowns();
          return "executed";
        }
        // Gerevert na een geslaagde simulatie: de staat veranderde in de tussentijd. Simuleer op het blok van de
        // transactie opnieuw voor de reden (bijvoorbeeld een swap van iemand anders die het venster vulde).
        failure = new Error(`transactie ${hash} is gerevert`);
        try {
          await simulateExecute(owner, receipt.blockNumber);
          // Slaagt nu wel: de revert kwam door een tijdelijke stand eerder in dat blok, niet door de owner.
          resimulationPassed = true;
        } catch (error) {
          if (errorNameOf(error) !== undefined) failure = error;
        }
      } catch (error) {
        failure = error;
      }
    }

    const action = failureAction({ errorName: errorNameOf(failure), resimulationPassed }, attempt, blockRetries);
    if (action === "fail") {
      failed(owner, failure);
      return "skipped";
    }
    if (action === "skip") {
      console.log(`${owner}: ${describeError(failure)} na ${blockRetries} nieuwe pogingen; geen cool-down`);
      return "skipped";
    }
    console.log(`${owner}: ${describeError(failure)}; opnieuw in een volgend blok (poging ${attempt + 2})`);
    retryAfterBlock = lastRunBlock !== null && lastRunBlock > block ? lastRunBlock : block;
  }
};

const checked = await read<bigint>("ownerCount");
let executed = 0;
let skipped = 0;
/** Owners die deze run al behandeld zijn (uitgevoerd, overgeslagen of mislukt); die worden niet opnieuw geprobeerd. */
const handled = new Set<string>();
for (let offset = 0n; offset < checked; offset += pageSize) {
  let readBlock: bigint | null = null;
  for (let reads = 1; ; reads += 1) {
    // Elke lezing in een blok ná de laatste eigen run en ná de vorige lezing van deze pagina.
    const after = readBlock !== null && (lastRunBlock === null || readBlock > lastRunBlock) ? readBlock : lastRunBlock;
    if (!(await waitForBlockAfter(after))) break;
    readBlock = await publicClient.getBlockNumber({ cacheTime: 0 });
    const fresh = newOwners(await read<readonly Address[]>("dueOwners", [offset, pageSize]), handled);

    for (const owner of fresh) {
      handled.add(owner.toLowerCase());
      if (isCoolingDown(cooldowns, owner, nowSeconds)) {
        console.log(`${owner}: overgeslagen, cool-down tot ${new Date((cooldownUntil(cooldowns, owner) ?? 0) * 1000).toISOString()}`);
        skipped += 1;
        continue;
      }
      const outcome = await handleOwner(owner);
      if (outcome === "executed") executed += 1;
      if (outcome === "skipped") skipped += 1;
    }
    if (!shouldReadPageAgain(fresh.length, reads, blockRetries + 1)) break;
  }
}

saveCooldowns();
console.log(`Klaar: ${checked} owners gecontroleerd, ${executed} uitgevoerd, ${skipped} overgeslagen${dryRun ? " (dry-run)" : ""}.`);
