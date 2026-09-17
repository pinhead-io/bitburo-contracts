/**
 * Verificatie 579f763 (K-3): het lock van het keeper-script op een echt bestandssysteem (tijdelijke map), met de volgorde
 * van twee of drie runs die tegelijk starten nagespeeld via een `fs` die vóór een stap de andere run laat lopen.
 */
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type LockFs, acquireLock } from "./lock";
import { formatLock, parseLock } from "./selection";

let dir: string;
let path: string;

beforeEach(() => {
  dir = fs.mkdtempSync(join(tmpdir(), "keeper-lock-"));
  path = join(dir, "keeper.lock");
});

afterEach(() => {
  fs.rmSync(dir, { recursive: true, force: true });
});

const NOW = 10_000;
const MAX_AGE = 900;
const options = (pid: number, extra: Partial<Parameters<typeof acquireLock>[1]> = {}) => ({
  pid,
  nowSeconds: NOW,
  maxAgeSeconds: MAX_AGE,
  isAlive: (p: number) => p === 1 || p === 2 || p === 3, // de runs in deze test leven; pid 99 (de crash) niet
  ...extra,
});
const holder = () => parseLock(fs.readFileSync(path, "utf8"), 0).pid;
const leftovers = () => fs.readdirSync(dir).filter((name) => name !== "keeper.lock");

/** `fs` dat vlak vóór de eerste aanroep van `step` eenmalig `before` uitvoert (de andere run). */
const interleave = (step: keyof LockFs, before: () => void): LockFs => {
  let done = false;
  return new Proxy(fs, {
    get(target, prop) {
      const real = Reflect.get(target, prop) as (...args: unknown[]) => unknown;
      if (prop !== step) return real;
      return (...args: unknown[]) => {
        if (!done) {
          done = true;
          before();
        }
        return real(...args);
      };
    },
  }) as LockFs;
};

describe("lock (verification 579f763, K-3)", () => {
  test("no lock: taken, with pid and start time", () => {
    expect(acquireLock(path, options(1))).toBe(true);
    expect(parseLock(fs.readFileSync(path, "utf8"), 0)).toEqual({ pid: 1, startedAt: NOW });
  });

  test("a live young lock holds and stays untouched", () => {
    fs.writeFileSync(path, formatLock({ pid: 2, startedAt: NOW - 10 }));
    expect(acquireLock(path, options(1))).toBe(false);
    expect(holder()).toBe(2);
    expect(leftovers()).toEqual([]);
  });

  test("a stale lock (dead pid, or older than the max age) is removed and taken, without leftovers", () => {
    fs.writeFileSync(path, formatLock({ pid: 99, startedAt: NOW - 10 }));
    const removed: number[] = [];
    expect(acquireLock(path, options(1, { onStaleRemoved: (lock) => removed.push(lock.pid) }))).toBe(true);
    expect(holder()).toBe(1);
    expect(removed).toEqual([99]);
    expect(leftovers()).toEqual([]);

    fs.writeFileSync(path, formatLock({ pid: 2, startedAt: NOW - MAX_AGE }));
    expect(acquireLock(path, options(3))).toBe(true);
    expect(holder()).toBe(3);
  });

  test("an empty lock that another run just created is not stale", () => {
    fs.writeFileSync(path, "");
    expect(acquireLock(path, options(1))).toBe(false);
    expect(fs.readFileSync(path, "utf8")).toBe("");
  });

  test("the K-3 race: B read the stale lock, A cleaned it up and took the lock; B must not remove A's lock", () => {
    fs.writeFileSync(path, formatLock({ pid: 99, startedAt: NOW - 10 }));
    let a: boolean | undefined;
    // B heeft het verlopen lock gelezen; vóór zijn opruimstap (rename) ruimt A hetzelfde lock op en neemt het lock. B
    // verplaatst dan het lock van A, ziet aan inode en inhoud dat het niet het verlopen lock is, en zet het terug.
    const b = acquireLock(path, options(2, { fs: interleave("renameSync", () => (a = acquireLock(path, options(1)))) }));
    expect(a).toBe(true);
    expect(b).toBe(false);
    expect(holder()).toBe(1); // het lock van A staat er weer
    expect(leftovers()).toEqual([]);
    // En B kan het daarna niet alsnog nemen: A leeft.
    expect(acquireLock(path, options(2))).toBe(false);
  });

  test("the old code in the same order: B's unlink removed A's new lock and both ran", () => {
    // Ter vergelijking de vorige implementatie (keeper.ts vóór K-3), met dezelfde volgorde.
    const oldAcquire = (pid: number, beforeUnlink: () => void = () => {}): boolean => {
      if (fs.existsSync(path)) {
        const lock = parseLock(fs.readFileSync(path, "utf8"), 0);
        if (lock.pid === 1 || lock.pid === 2) return false;
        beforeUnlink();
        fs.unlinkSync(path);
      }
      const fd = fs.openSync(path, "wx");
      fs.writeFileSync(fd, formatLock({ pid, startedAt: NOW }));
      fs.closeSync(fd);
      return true;
    };
    fs.writeFileSync(path, formatLock({ pid: 99, startedAt: NOW - 10 }));
    let a: boolean | undefined;
    const b = oldAcquire(2, () => (a = oldAcquire(1)));
    expect(a).toBe(true);
    expect(b).toBe(true); // beide runs denken dat ze het lock hebben
  });

  test("both saw the stale lock and A moved it aside first: B's rename finds nothing, B retries and takes the free lock", () => {
    fs.writeFileSync(path, formatLock({ pid: 99, startedAt: NOW - 10 }));
    // A heeft het verlopen lock net opzij gezet (rename), maar nog geen eigen lock gemaakt.
    const b = acquireLock(path, options(2, { fs: interleave("renameSync", () => fs.renameSync(path, join(dir, "a-aside"))) }));
    expect(b).toBe(true);
    expect(holder()).toBe(2);
    fs.unlinkSync(join(dir, "a-aside"));
    expect(leftovers()).toEqual([]);
  });

  test("B moved A's new lock: it is put back with link, and a newer lock is never overwritten", () => {
    fs.writeFileSync(path, formatLock({ pid: 99, startedAt: NOW - 10 }));
    let c: boolean | undefined;
    // A neemt het lock vóór de rename van B (B verplaatst dus het lock van A), en C probeert het vlak vóór de link.
    const fsB = interleave("renameSync", () => acquireLock(path, options(1)));
    const fsBC = new Proxy(fsB, {
      get(target, prop) {
        const real = Reflect.get(target, prop) as (...args: unknown[]) => unknown;
        if (prop !== "linkSync") return real;
        return (...args: unknown[]) => {
          c = acquireLock(path, options(3));
          return real(...args);
        };
      },
    }) as LockFs;
    const b = acquireLock(path, options(2, { fs: fsBC }));
    expect(b).toBe(false);
    // C viel in het gat tussen rename en link: C houdt het lock, de link van B overschrijft het niet (EEXIST).
    expect(c).toBe(true);
    expect(holder()).toBe(3);
    expect(leftovers()).toEqual([]);
  });

  test("A moved the stale lock aside but B takes the free lock before A creates its own: A stops and leaves B's lock", () => {
    fs.writeFileSync(path, formatLock({ pid: 99, startedAt: NOW - 10 }));
    let b: boolean | undefined;
    // openSync van A: 1 = wx (bestaat), 2 = lezen, 3 = het opzij gezette bestand lezen, 4 = eigen lock (wx). B vóór 4.
    let calls = 0;
    const fsA = new Proxy(fs, {
      get(target, prop) {
        const real = Reflect.get(target, prop) as (...args: unknown[]) => unknown;
        if (prop !== "openSync") return real;
        return (...args: unknown[]) => {
          calls += 1;
          if (calls === 4) b = acquireLock(path, options(2));
          return real(...args);
        };
      },
    }) as LockFs;
    const a = acquireLock(path, options(1, { fs: fsA }));
    expect(b).toBe(true);
    expect(a).toBe(false);
    expect(holder()).toBe(2);
    expect(leftovers()).toEqual([]);
  });
});
