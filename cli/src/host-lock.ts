import { createHash } from "node:crypto";
import { existsSync, linkSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

import type { Context } from "./context.js";
import { gdcliHome } from "./project.js";

export const HOST_LOCKS_DIR_NAME = "host-locks";
const NAME_HEX_DIGITS = 16;
const PRIVATE_DIR_MODE = 0o700;
const PRIVATE_FILE_MODE = 0o600;
/** A lock file is written right after it is created; an empty one this young is still being written. */
const WRITE_GRACE_MS = 5000;
const ATTEMPTS = 2;
const RENAME_ATTEMPTS = 5;
const RENAME_RETRY_MS = 20;

/** Where the lock of one project lives. Case is folded where the default filesystem folds it (Windows, macOS). */
export function hostLockPath(context: Context, project: string): string {
  const absolute = resolve(project).replaceAll("\\", "/");
  const key = context.platform === "win32" || context.platform === "darwin" ? absolute.toLowerCase() : absolute;
  const name = createHash("sha256").update(key).digest("hex").slice(0, NAME_HEX_DIGITS);
  return join(gdcliHome(context), HOST_LOCKS_DIR_NAME, `${name}.lock`);
}

function lockText(path: string): string | undefined {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return undefined;
  }
}

function lockField(path: string, field: "pid" | "editor"): number | undefined {
  try {
    const pid: unknown = (JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>)[field];
    return typeof pid === "number" && Number.isInteger(pid) && pid > 0 ? pid : undefined;
  } catch {
    return undefined;
  }
}

const ownerPid = (path: string): number | undefined => lockField(path, "pid");

/**
 * A lock is stale when the gd that took it is gone and so is the editor it
 * started (a gd that stopped waiting leaves the lock to the editor that is
 * still starting), or when it is older than any start may last.
 */
function isStale(context: Context, path: string, maxAgeMs: number): boolean {
  let ageMs: number;
  try {
    ageMs = Date.now() - statSync(path).mtimeMs;
  } catch {
    // It vanished between the failed create and now: the next attempt decides.
    return true;
  }
  if (ageMs > maxAgeMs) {
    return true;
  }
  const pid = ownerPid(path);
  if (pid === undefined) {
    return ageMs > WRITE_GRACE_MS;
  }
  const editor = lockField(path, "editor");
  return !context.processes.isAlive(pid) && (editor === undefined || !context.processes.isAlive(editor));
}

/**
 * Removes a stale lock. It is renamed aside first and looked at again: when
 * two gd notice the same stale lock, one may already have replaced it with
 * its own fresh lock, and what was moved aside is then put back. A third gd
 * creating a lock in the instant between can still win over the one put
 * back; that needs three starts of one project within microseconds.
 */
export function clearStale(path: string, pid: number, judged: string | undefined): void {
  const aside = `${path}.${pid}.stale`;
  try {
    renameSync(path, aside);
  } catch {
    return; // Another gd cleared it first; the next attempt competes for the lock.
  }
  if (lockText(aside) !== judged) {
    try {
      // A link, not a rename: it fails instead of replacing a lock made since.
      linkSync(aside, path);
    } catch (error: unknown) {
      // EEXIST: a third gd took the place; its lock stands. Otherwise the
      // filesystem has no hard links: a rename, while the place is free.
      if ((error as NodeJS.ErrnoException).code !== "EEXIST" && !existsSync(path)) {
        try {
          renameSync(aside, path);
          return;
        } catch {
          // Lost; the next start judges again.
        }
      }
    }
  }
  try {
    unlinkSync(aside);
  } catch {
    // Gone already.
  }
}

/** Windows refuses to replace a file another process is reading at that moment: tried again shortly. */
function renameOver(from: string, to: string): void {
  for (let attempt = 1; ; attempt += 1) {
    try {
      renameSync(from, to);
      return;
    } catch (error: unknown) {
      if (attempt >= RENAME_ATTEMPTS || (error as NodeJS.ErrnoException).code !== "EPERM") {
        throw error;
      }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, RENAME_RETRY_MS);
    }
  }
}

/** Notes in the lock this gd holds which editor it started. */
export function recordHostEditor(context: Context, project: string, pid: number, editor: number): void {
  const path = hostLockPath(context, project);
  if (ownerPid(path) !== pid) {
    return;
  }
  // Written aside and renamed over the lock, so no other gd reads it half written.
  const next = `${path}.${pid}.next`;
  try {
    writeFileSync(next, JSON.stringify({ pid, editor }), { mode: PRIVATE_FILE_MODE });
    renameOver(next, path);
  } catch {
    // The lock still names this gd; only the hand-over to the editor is lost.
    try {
      unlinkSync(next);
    } catch {
      // Never written.
    }
  }
}

/** Whether the lock names an editor that is still running. */
export function hostEditorAlive(context: Context, project: string): boolean {
  const editor = lockField(hostLockPath(context, project), "editor");
  return editor !== undefined && context.processes.isAlive(editor);
}

function release(path: string, pid: number): void {
  // Only the lock this gd wrote: if it was taken over as stale, it is not ours.
  if (ownerPid(path) !== pid) {
    return;
  }
  try {
    unlinkSync(path);
  } catch {
    // Already gone; nothing to release.
  }
}

/**
 * Makes `gd host start` for one project exclusive: two of them running at the
 * same moment would otherwise both find no editor and both start one.
 * Returns the function that releases the lock, or undefined when another gd
 * holds it.
 */
export function acquireHostLock(context: Context, project: string, pid: number, maxAgeMs: number): (() => void) | undefined {
  const path = hostLockPath(context, project);
  mkdirSync(join(gdcliHome(context), HOST_LOCKS_DIR_NAME), { recursive: true, mode: PRIVATE_DIR_MODE });
  for (let attempt = 0; attempt < ATTEMPTS; attempt += 1) {
    try {
      // "wx" fails when the file exists, which is what makes this a lock.
      writeFileSync(path, JSON.stringify({ pid }), { flag: "wx", mode: PRIVATE_FILE_MODE });
      return () => release(path, pid);
    } catch (error: unknown) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") {
        throw error;
      }
      const judged = lockText(path);
      if (!isStale(context, path, maxAgeMs)) {
        return undefined;
      }
      clearStale(path, pid, judged);
    }
  }
  return undefined;
}
