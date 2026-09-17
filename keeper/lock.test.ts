/**
 * Verification 579f763 (K-3): the keeper script's lock on a real file system (temporary directory), with the order
 * of two or three runs that start at the same time replayed through an `fs` that lets the other run go before a step.
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
  isAlive: (p: number) => p === 1 || p === 2 || p === 3, // the runs in this test are alive; pid 99 (the crash) is not
  ...extra,
});
const holder = () => parseLock(fs.readFileSync(path, "utf8"), 0).pid;
const leftovers = () => fs.readdirSync(dir).filter((name) => name !== "keeper.lock");

/** `fs` that runs `before` once, right before the first call of `step` (the other run). */
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
    // B has read the stale lock; before its cleanup step (rename) A removes the same lock and takes the lock. B
    // then moves A's lock, sees from inode and content that it is not the stale lock, and puts it back.
    const b = acquireLock(path, options(2, { fs: interleave("renameSync", () => (a = acquireLock(path, options(1)))) }));
    expect(a).toBe(true);
    expect(b).toBe(false);
    expect(holder()).toBe(1); // A's lock is back in place
    expect(leftovers()).toEqual([]);
    // And B cannot take it afterwards either: A is alive.
    expect(acquireLock(path, options(2))).toBe(false);
  });

  test("the old code in the same order: B's unlink removed A's new lock and both ran", () => {
    // For comparison the previous implementation (keeper.ts before K-3), with the same order.
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
    expect(b).toBe(true); // both runs think they hold the lock
  });

  test("both saw the stale lock and A moved it aside first: B's rename finds nothing, B retries and takes the free lock", () => {
    fs.writeFileSync(path, formatLock({ pid: 99, startedAt: NOW - 10 }));
    // A has just moved the stale lock aside (rename), but has not created its own lock yet.
    const b = acquireLock(path, options(2, { fs: interleave("renameSync", () => fs.renameSync(path, join(dir, "a-aside"))) }));
    expect(b).toBe(true);
    expect(holder()).toBe(2);
    fs.unlinkSync(join(dir, "a-aside"));
    expect(leftovers()).toEqual([]);
  });

  test("B moved A's new lock: it is put back with link, and a newer lock is never overwritten", () => {
    fs.writeFileSync(path, formatLock({ pid: 99, startedAt: NOW - 10 }));
    let c: boolean | undefined;
    // A takes the lock before B's rename (so B moves A's lock), and C tries right before the link.
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
    // C fell into the gap between rename and link: C keeps the lock, B's link does not overwrite it (EEXIST).
    expect(c).toBe(true);
    expect(holder()).toBe(3);
    expect(leftovers()).toEqual([]);
  });

  test("A moved the stale lock aside but B takes the free lock before A creates its own: A stops and leaves B's lock", () => {
    fs.writeFileSync(path, formatLock({ pid: 99, startedAt: NOW - 10 }));
    let b: boolean | undefined;
    // openSync of A: 1 = wx (exists), 2 = read, 3 = read the file moved aside, 4 = own lock (wx). B before 4.
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
