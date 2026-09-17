/**
 * Lock of the keeper script (LOCK_FILE): one run at a time. Separate from keeper.ts, with a swappable `fs`, so that the
 * order of two runs that start at the same time can be replayed in a test.
 */
import * as nodeFs from "node:fs";
import { type LockInfo, formatLock, lockIsStale, parseLock } from "./selection";

/** What the lock uses from the file system. */
export type LockFs = Pick<
  typeof nodeFs,
  "openSync" | "closeSync" | "writeFileSync" | "readFileSync" | "fstatSync" | "renameSync" | "linkSync" | "unlinkSync"
>;

export type LockOptions = {
  pid: number;
  nowSeconds: number;
  maxAgeSeconds: number;
  isAlive: (pid: number) => boolean;
  /** For tests; defaults to `node:fs`. */
  fs?: LockFs;
  /** Unique name for moving a stale lock aside; defaults to pid, attempt and a random number. */
  asideName?: (attempt: number) => string;
  /** After removing a stale lock (for the log). */
  onStaleRemoved?: (lock: LockInfo) => void;
};

const errno = (error: unknown): string | undefined => (error as NodeJS.ErrnoException).code;

/**
 * Take the lock, or return false if another run holds it (final review I-5, verification 579f763 K-3).
 *
 * Creation always uses `wx` (O_CREAT | O_EXCL): atomic, so of two runs exactly one succeeds. The problem was in
 * cleaning up a stale lock. Before: if it exists, read it, if it is stale, `unlink`, `open(wx)`. Between reading and
 * `unlink` another run could already have removed the same stale lock and created a new lock; the `unlink`
 * then removed that new lock and both runs ran.
 *
 * Now:
 * 1. read the existing lock through one file descriptor, so that content and inode (`dev`, `ino`) belong to one file;
 * 2. if it is stale, move it aside atomically with `rename` to a unique name. Of two runs that want to move the same
 *    file, one gets it; the other gets ENOENT and starts over;
 * 3. check that the moved file is the same file as the stale lock that was read (same inode and same
 *    content). If not, this run moved another run's new lock between 1 and 2: it is put back with
 *    `link` (`link` never overwrites; if an even newer lock exists in the meantime, that one stays) and
 *    this run stops;
 * 4. if it matches, create our own lock with `wx` and only then delete the moved file. As long as that file still
 *    exists, the file system cannot give its inode to a new lock, so step 3 cannot mistake a new lock for
 *    the old one.
 *
 * So a lock that is not the stale lock that was read is never removed. What remains: if a third run creates the lock
 * exactly between the `rename` and the `link` of step 3 (a few system calls), that run keeps the lock and
 * the run whose lock was moved keeps running. That requires three runs starting at the same time while a
 * stale lock exists. Even then the contract prevents double runs; it costs at most reverted attempts.
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
      if (errno(error) === "ENOENT") continue; // just removed by another run: try to create again
      throw error;
    }
    // Old format (only a pid): the age comes from the mtime (final review I-5).
    const mtime = Math.floor(Number(seen.mtimeMs) / 1000);
    const lock = parseLock(seen.text, mtime);
    // Empty: another run just created it with `wx` and is about to write pid and start time. Not stale, unless it is
    // as old as a stale lock (a crash between creating and writing).
    if (seen.text.trim() === "" && options.nowSeconds - mtime < options.maxAgeSeconds) return false;
    if (!lockIsStale(lock, options.nowSeconds, options.maxAgeSeconds, options.isAlive)) return false;

    const aside = asideName(attempt);
    try {
      fs.renameSync(path, aside);
    } catch (error) {
      if (errno(error) === "ENOENT") continue; // another run already moved it
      throw error;
    }
    const moved = readLock(fs, aside);
    if (moved.dev !== seen.dev || moved.ino !== seen.ino || moved.text !== seen.text) {
      // Not the stale lock but another run's new lock: put it back without overwriting anything.
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

/** `open(wx)`: true if the lock belongs to this run, false if the file already exists. */
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

/** Content and identity of one file, through a single file descriptor. */
const readLock = (fs: LockFs, path: string): LockFile => {
  const fd = fs.openSync(path, "r");
  try {
    const stat = fs.fstatSync(fd, { bigint: true });
    return { dev: stat.dev, ino: stat.ino, text: fs.readFileSync(fd, "utf8"), mtimeMs: stat.mtimeMs };
  } finally {
    fs.closeSync(fd);
  }
};
