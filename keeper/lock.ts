/**
 * Lock of the keeper script (LOCK_FILE): one run at a time.
 *
 * The lock is a file with the pid and start time of the run that holds it. It is created with `wx`
 * (O_CREAT | O_EXCL), which is atomic: of two runs that find no lock, exactly one gets it.
 *
 * A lock that a crashed run left behind is stale. A stale lock is removed and the lock is created once more. The
 * check and the removal are separate steps, so this is not airtight: when two runs start within a few system calls of
 * each other while a stale lock exists, the second can remove the lock the first has just created, and then both run.
 * That is accepted, because the contract refuses a second run for an owner within a day: the cost is a failed send,
 * not a double trade. Without a stale lock, or with runs that start one after the other, it cannot happen.
 */
import { closeSync, openSync, readFileSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { type LockInfo, formatLock, lockIsStale, parseLock } from "./selection";

export type LockOptions = {
  pid: number;
  nowSeconds: number;
  maxAgeSeconds: number;
  isAlive: (pid: number) => boolean;
  /** Right after a stale lock was removed, for the log; `undefined` if its content was not a lock. */
  onStaleRemoved?: (lock: LockInfo | undefined) => void;
};

const errno = (error: unknown): string | undefined => (error as NodeJS.ErrnoException).code;

/**
 * Take the lock, or return false if another run holds it.
 *
 * Content that is not a lock (empty included: another run may be between creating the file and writing to it) has no
 * pid and no start time, so it counts as held until the file itself is `maxAgeSeconds` old, and as stale after that.
 */
export const acquireLock = (path: string, options: LockOptions): boolean => {
  if (create(path, options)) return true;
  try {
    const lock = parseLock(readFileSync(path, "utf8"));
    const stale = lock
      ? lockIsStale(lock, options.nowSeconds, options.maxAgeSeconds, options.isAlive)
      : options.nowSeconds - Math.floor(statSync(path).mtimeMs / 1000) >= options.maxAgeSeconds;
    if (!stale) return false;
    unlinkSync(path);
    options.onStaleRemoved?.(lock);
  } catch (error) {
    // The file is gone: its run just finished, or another run removed the same stale lock.
    if (errno(error) !== "ENOENT") throw error;
  }
  return create(path, options);
};

/** `open(wx)`: true if the lock belongs to this run, false if the file already exists. */
const create = (path: string, options: LockOptions): boolean => {
  let fd: number;
  try {
    fd = openSync(path, "wx");
  } catch (error) {
    if (errno(error) === "EEXIST") return false;
    throw error;
  }
  try {
    writeFileSync(fd, formatLock({ pid: options.pid, startedAt: options.nowSeconds }));
  } finally {
    closeSync(fd);
  }
  return true;
};
