/**
 * Lock van het keeper-script (LOCK_FILE): één run tegelijk. Los van keeper.ts, met een verwisselbaar `fs`, zodat de
 * volgorde van twee runs die tegelijk starten in een test na te spelen is.
 */
import * as nodeFs from "node:fs";
import { type LockInfo, formatLock, lockIsStale, parseLock } from "./selection";

/** Wat het lock van het bestandssysteem gebruikt. */
export type LockFs = Pick<
  typeof nodeFs,
  "openSync" | "closeSync" | "writeFileSync" | "readFileSync" | "fstatSync" | "renameSync" | "linkSync" | "unlinkSync"
>;

export type LockOptions = {
  pid: number;
  nowSeconds: number;
  maxAgeSeconds: number;
  isAlive: (pid: number) => boolean;
  /** Voor tests; standaard `node:fs`. */
  fs?: LockFs;
  /** Unieke naam voor het opzij zetten van een verlopen lock; standaard pid, poging en een willekeurig getal. */
  asideName?: (attempt: number) => string;
  /** Na het opruimen van een verlopen lock (voor de log). */
  onStaleRemoved?: (lock: LockInfo) => void;
};

const errno = (error: unknown): string | undefined => (error as NodeJS.ErrnoException).code;

/**
 * Neem het lock, of geef false als een andere run het heeft (eindreview I-5, verificatie 579f763 K-3).
 *
 * Aanmaken gaat altijd met `wx` (O_CREAT | O_EXCL): atomair, dus van twee runs lukt het er één. Het probleem zat in het
 * opruimen van een verlopen lock. Vroeger: bestaat het, lees het, is het verlopen, `unlink`, `open(wx)`. Tussen lezen en
 * `unlink` kon een andere run hetzelfde verlopen lock al opgeruimd en een nieuw lock gemaakt hebben; de `unlink`
 * verwijderde dan dat nieuwe lock en beide runs liepen.
 *
 * Nu:
 * 1. het bestaande lock lezen via één file descriptor, zodat inhoud en inode (`dev`, `ino`) bij hetzelfde bestand horen;
 * 2. is het verlopen, dan het atomair opzij zetten met `rename` naar een unieke naam. Van twee runs die hetzelfde bestand
 *    willen verplaatsen, krijgt er één het; de ander krijgt ENOENT en begint opnieuw;
 * 3. controleren dat het verplaatste bestand hetzelfde bestand is als het gelezen verlopen lock (zelfde inode én zelfde
 *    inhoud). Zo niet, dan heeft deze run tussen 1 en 2 het nieuwe lock van een andere run verplaatst: dat wordt met
 *    `link` teruggezet (`link` overschrijft nooit; bestaat er intussen een nog nieuwer lock, dan blijft dat staan) en
 *    deze run stopt;
 * 4. klopt het, dan het eigen lock met `wx` aanmaken en pas daarna het verplaatste bestand verwijderen. Zolang dat nog
 *    bestaat, kan het bestandssysteem zijn inode niet aan een nieuw lock geven, dus stap 3 kan een nieuw lock niet voor
 *    het oude aanzien.
 *
 * Er wordt dus nooit een lock verwijderd dat niet het gelezen verlopen lock is. Wat overblijft: valt precies tussen de
 * `rename` en de `link` van stap 3 (enkele systeemcalls) een derde run die het lock aanmaakt, dan houdt die het lock en
 * loopt de run waarvan het lock verplaatst werd nog door. Daarvoor moeten drie runs tegelijk starten terwijl er een
 * verlopen lock ligt. Ook dan voorkomt het contract dubbele runs; het kost hooguit gerevertte pogingen.
 */
export const acquireLock = (path: string, options: LockOptions): boolean => {
  const fs = options.fs ?? nodeFs;
  const asideName =
    options.asideName ?? ((attempt: number) => `${path}.stale-${options.pid}-${attempt}-${Math.random().toString(36).slice(2)}`);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const created = tryCreate(fs, path, options);
    if (created) return true;

    let seen: LockFile;
    try {
      seen = readLock(fs, path);
    } catch (error) {
      if (errno(error) === "ENOENT") continue; // net opgeruimd door een andere run: opnieuw proberen aan te maken
      throw error;
    }
    // Oud formaat (alleen een pid): de leeftijd komt uit de mtime (eindreview I-5).
    const mtime = Math.floor(Number(seen.mtimeMs) / 1000);
    const lock = parseLock(seen.text, mtime);
    // Leeg: een andere run heeft het net met `wx` aangemaakt en schrijft zo pid en starttijd. Niet verlopen, tenzij het
    // zo oud is als een verlopen lock (een crash tussen aanmaken en schrijven).
    if (seen.text.trim() === "" && options.nowSeconds - mtime < options.maxAgeSeconds) return false;
    if (!lockIsStale(lock, options.nowSeconds, options.maxAgeSeconds, options.isAlive)) return false;

    const aside = asideName(attempt);
    try {
      fs.renameSync(path, aside);
    } catch (error) {
      if (errno(error) === "ENOENT") continue; // een andere run verplaatste het al
      throw error;
    }
    const moved = readLock(fs, aside);
    if (moved.dev !== seen.dev || moved.ino !== seen.ino || moved.text !== seen.text) {
      // Niet het verlopen lock maar het nieuwe lock van een andere run: terugzetten zonder iets te overschrijven.
      try {
        fs.linkSync(aside, path);
      } catch (error) {
        if (errno(error) !== "EEXIST") throw error;
      }
      fs.unlinkSync(aside);
      return false;
    }
    try {
      const ok = tryCreate(fs, path, options);
      if (ok) options.onStaleRemoved?.(lock);
      return ok;
    } finally {
      fs.unlinkSync(aside);
    }
  }
  return false;
};

/** `open(wx)`: true als het lock van deze run is, false als het bestand al bestaat. */
const tryCreate = (fs: LockFs, path: string, options: LockOptions): boolean => {
  let fd: number;
  try {
    fd = fs.openSync(path, "wx");
  } catch (error) {
    if (errno(error) === "EEXIST") return false;
    throw error;
  }
  try {
    fs.writeFileSync(fd, formatLock({ pid: options.pid, startedAt: options.nowSeconds }));
  } finally {
    fs.closeSync(fd);
  }
  return true;
};

type LockFile = { dev: bigint; ino: bigint; text: string; mtimeMs: bigint };

/** Inhoud en identiteit van één bestand, via één file descriptor. */
const readLock = (fs: LockFs, path: string): LockFile => {
  const fd = fs.openSync(path, "r");
  try {
    const stat = fs.fstatSync(fd, { bigint: true });
    return { dev: stat.dev, ino: stat.ino, text: fs.readFileSync(fd, "utf8"), mtimeMs: stat.mtimeMs };
  } finally {
    fs.closeSync(fd);
  }
};
