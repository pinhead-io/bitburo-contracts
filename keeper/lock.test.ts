/**
 * The keeper script's lock on a real file system (temporary directory), with the clock the script itself uses: the
 * lock files get their file time from the system, so "now" is the system time too, and an old lock is a run that
 * starts later.
 *
 * Not covered here: two runs that start within a few system calls of each other while a stale lock exists can both
 * run. The lock accepts that, because the contract refuses a second run for an owner within a day, so the cost is a
 * failed send, not a double trade.
 */
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { acquireLock } from "./lock";
import { type LockInfo, formatLock, parseLock } from "./selection";

let dir: string;
let path: string;

beforeEach(() => {
  dir = fs.mkdtempSync(join(tmpdir(), "keeper-lock-"));
  path = join(dir, "keeper.lock");
});

afterEach(() => {
  fs.rmSync(dir, { recursive: true, force: true });
});

const NOW = Math.floor(Date.now() / 1000);
const MAX_AGE = 900;
/** A run that starts after the lock written at NOW has expired. */
const LATER = NOW + MAX_AGE + 60;
const options = (pid: number, extra: Partial<Parameters<typeof acquireLock>[1]> = {}) => ({
  pid,
  nowSeconds: NOW,
  maxAgeSeconds: MAX_AGE,
  isAlive: (p: number) => p === 1 || p === 2, // the runs in this test are alive; pid 99 (the crash) is not
  ...extra,
});
const content = () => fs.readFileSync(path, "utf8");
const holder = () => parseLock(content())?.pid;
const files = () => fs.readdirSync(dir);

describe("lock", () => {
  test("no lock: taken, with pid and start time", () => {
    expect(acquireLock(path, options(1))).toBe(true);
    expect(parseLock(content())).toEqual({ pid: 1, startedAt: NOW });
  });

  test("a live young lock holds and stays untouched", () => {
    fs.writeFileSync(path, formatLock({ pid: 2, startedAt: NOW - 10 }));
    expect(acquireLock(path, options(1))).toBe(false);
    expect(holder()).toBe(2);
  });

  test("the lock of a dead pid is removed and taken", () => {
    fs.writeFileSync(path, formatLock({ pid: 99, startedAt: NOW - 10 }));
    const removed: (LockInfo | undefined)[] = [];
    expect(acquireLock(path, options(1, { onStaleRemoved: (lock) => removed.push(lock) }))).toBe(true);
    expect(holder()).toBe(1);
    expect(removed).toEqual([{ pid: 99, startedAt: NOW - 10 }]);
    expect(files()).toEqual(["keeper.lock"]);
  });

  test("a lock older than the max age is removed and taken, even if its pid is alive", () => {
    fs.writeFileSync(path, formatLock({ pid: 2, startedAt: NOW }));
    expect(acquireLock(path, options(1, { nowSeconds: LATER }))).toBe(true);
    expect(parseLock(content())).toEqual({ pid: 1, startedAt: LATER });
    expect(files()).toEqual(["keeper.lock"]);
  });

  // Content that is not a lock, empty included (another run may be between creating the file and writing to it).
  for (const [name, text] of [
    ["unreadable", "garbage"],
    ["empty", ""],
  ] as const) {
    test(`an ${name} young lock holds and stays untouched`, () => {
      fs.writeFileSync(path, text);
      expect(acquireLock(path, options(1))).toBe(false);
      expect(content()).toBe(text);
    });

    test(`an ${name} lock as old as the max age is removed and taken`, () => {
      fs.writeFileSync(path, text);
      const removed: (LockInfo | undefined)[] = [];
      expect(acquireLock(path, options(1, { nowSeconds: LATER, onStaleRemoved: (lock) => removed.push(lock) }))).toBe(true);
      expect(holder()).toBe(1);
      expect(removed).toEqual([undefined]);
      expect(files()).toEqual(["keeper.lock"]);
    });
  }

  test("another run takes the lock right after the stale one is removed: this run stops and leaves that lock", () => {
    fs.writeFileSync(path, formatLock({ pid: 99, startedAt: NOW - 10 }));
    let other: boolean | undefined;
    expect(acquireLock(path, options(1, { onStaleRemoved: () => (other = acquireLock(path, options(2))) }))).toBe(false);
    expect(other).toBe(true);
    expect(holder()).toBe(2);
    expect(files()).toEqual(["keeper.lock"]);
  });
});
