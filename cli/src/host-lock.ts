import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

import type { Context } from "./context.js";
import { gdcliHome } from "./project.js";

export const HOST_LOCKS_DIR_NAME = "host-locks";
const NAME_HEX_DIGITS = 16;
const NONCE_BYTES = 6;
const PRIVATE_DIR_MODE = 0o700;
const PRIVATE_FILE_MODE = 0o600;
/** A file is written right after it is created; an unreadable one this young is still being written. */
const WRITE_GRACE_MS = 5000;
const RENAME_ATTEMPTS = 10;
const RENAME_RETRY_MS = 50;
/** What Windows answers while another process (a reader, a virus scanner) has the file open. */
const BUSY_CODES = new Set(["EPERM", "EACCES", "EBUSY"]);
const CHOOSING = ".choosing";
const ASIDE = ".tmp";
const TICKET = ".ticket";

/** The folder of one project's queue. Case is folded where the default filesystem folds it (Windows, macOS). */
export function hostLockDir(context: Context, project: string): string {
  const absolute = resolve(project).replaceAll("\\", "/");
  const key = context.platform === "win32" || context.platform === "darwin" ? absolute.toLowerCase() : absolute;
  const name = createHash("sha256").update(key).digest("hex").slice(0, NAME_HEX_DIGITS);
  return join(gdcliHome(context), HOST_LOCKS_DIR_NAME, name);
}

/** One gd's place in the queue for starting a project's headless editor. */
export interface HostLock {
  /** True when it is this gd's turn. False means wait and ask again; the place in the queue is kept. */
  tryAcquire(): boolean;
  /** Hands the place to the editor this gd started, so it is held while that editor still starts. */
  recordEditor(editor: number): void;
  /** Whether the editor recorded in this gd's place is still running. */
  editorAlive(): boolean;
  /** Leaves the queue (or gives up the turn). Safe to call more than once. */
  release(): void;
}

interface Entry {
  readonly base: string;
  /** "choosing" sorts before "ticket": a snapshot of the folder never misses both of one gd's files. */
  readonly kind: "choosing" | "ticket";
  readonly number: number;
  readonly live: boolean;
}

/**
 * Makes `gd host start` for one project exclusive, with Lamport's bakery
 * algorithm over files: a gd marks that it is choosing, takes a number one
 * higher than any it sees, and has its turn when no one is choosing and no
 * one holds a lower number (ties go by name). Each file is written whole
 * (written aside and renamed), and no gd ever removes another's place
 * unless that one is gone (its gd and the editor it started have exited,
 * or it is older than any start may last): there is no moment in which a
 * place that is still held can be taken over. File names carry a random
 * part, so a reused process id never stands for an old place.
 */
export function hostLock(context: Context, project: string, pid: number, maxAgeMs: number): HostLock {
  const folder = hostLockDir(context, project);
  const base = `${pid}-${randomBytes(NONCE_BYTES).toString("hex")}`;
  const choosingFile = join(folder, base + CHOOSING);
  const ticketFile = join(folder, base + TICKET);
  let number = 0;
  let editor: number | undefined;

  const writeTicket = (): void => writeWhole(ticketFile, JSON.stringify({ number, pid, ...(editor === undefined ? {} : { editor }) }));
  const isAlive = (value: number | undefined): boolean => value !== undefined && context.processes.isAlive(value);

  /**
   * Whether a place still holds, and its number; undefined when the file has
   * gone. Only a missing file is gone: one that cannot be read at this moment
   * (Windows: open in another process) counts as held until it is too old,
   * and one that reads but is not a place counts as being written for a few
   * seconds.
   */
  const judge = (path: string): { readonly number: number; readonly live: boolean } | undefined => {
    let ageMs: number;
    let text: string;
    try {
      ageMs = Date.now() - statSync(path).mtimeMs;
      text = readFileSync(path, "utf8");
    } catch (error: unknown) {
      return (error as NodeJS.ErrnoException).code === "ENOENT" ? undefined : { number: 0, live: true };
    }
    if (ageMs > maxAgeMs) {
      return { number: 0, live: false };
    }
    const fields = parseFields(text);
    if (fields === undefined) {
      return { number: 0, live: ageMs <= WRITE_GRACE_MS };
    }
    return { number: numberField(fields, "number") ?? 0, live: isAlive(numberField(fields, "pid")) || isAlive(numberField(fields, "editor")) };
  };

  const entries = (): Entry[] => {
    let names: string[];
    try {
      names = readdirSync(folder);
    } catch {
      return [];
    }
    return names.flatMap((name): Entry[] => {
      const kind = name.endsWith(TICKET) ? "ticket" : name.endsWith(CHOOSING) ? "choosing" : undefined;
      if (kind === undefined) {
        // A file written aside by a gd that died before renaming it: nobody's place.
        if (name.endsWith(ASIDE) && ageOf(join(folder, name)) > maxAgeMs) {
          removeQuietly(join(folder, name));
        }
        return [];
      }
      const entryBase = name.slice(0, -(kind === "ticket" ? TICKET : CHOOSING).length);
      const read = judge(join(folder, name));
      return read === undefined ? [] : [{ base: entryBase, kind, ...read }];
    });
  };

  return {
    tryAcquire(): boolean {
      mkdirSync(folder, { recursive: true, mode: PRIVATE_DIR_MODE });
      // A place removed meanwhile (judged too old, a clock jump) is taken again, never assumed.
      if (number !== 0 && !existsSync(ticketFile)) {
        number = 0;
      }
      if (number === 0) {
        writeWhole(choosingFile, JSON.stringify({ pid }));
        const highest = Math.max(0, ...entries().filter((entry) => entry.live && entry.kind === "ticket").map((entry) => entry.number));
        number = highest + 1;
        writeTicket();
        removeQuietly(choosingFile);
      }
      let turn = true;
      for (const entry of entries()) {
        if (entry.base === base) {
          continue;
        }
        if (!entry.live) {
          // Gone: its gd and editor have exited. Judged once more right before removing it;
          // the name is unique, so this removes nobody else's place.
          const path = join(folder, entry.base + (entry.kind === "ticket" ? TICKET : CHOOSING));
          if (judge(path)?.live === false) {
            removeQuietly(path);
          }
          continue;
        }
        const ahead = entry.kind === "choosing" || entry.number < number || (entry.number === number && entry.base < base);
        turn &&= !ahead;
      }
      return turn;
    },
    recordEditor(started: number): void {
      editor = started;
      try {
        writeTicket();
      } catch {
        // Not handed over: the place names only this gd, so it is not kept for the editor either.
        editor = undefined;
      }
    },
    editorAlive(): boolean {
      return isAlive(editor);
    },
    release(): void {
      removeQuietly(choosingFile);
      removeQuietly(ticketFile);
      number = 0;
    },
  };
}

function parseFields(text: string): Record<string, unknown> | undefined {
  try {
    const parsed: unknown = JSON.parse(text);
    return typeof parsed === "object" && parsed !== null ? (parsed as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

function numberField(fields: Record<string, unknown>, name: string): number | undefined {
  const value = fields[name];
  return typeof value === "number" && Number.isInteger(value) && value > 0 ? value : undefined;
}

/** Written aside and renamed into place, so no other gd ever reads it half written. */
function writeWhole(path: string, text: string): void {
  const aside = path + ASIDE;
  writeFileSync(aside, text, { mode: PRIVATE_FILE_MODE });
  for (let attempt = 1; ; attempt += 1) {
    try {
      renameSync(aside, path);
      return;
    } catch (error: unknown) {
      // Windows refuses to replace a file another process has open at that moment.
      if (attempt >= RENAME_ATTEMPTS || !BUSY_CODES.has((error as NodeJS.ErrnoException).code ?? "")) {
        removeQuietly(aside);
        throw error;
      }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, RENAME_RETRY_MS);
    }
  }
}

function ageOf(path: string): number {
  try {
    return Date.now() - statSync(path).mtimeMs;
  } catch {
    return 0;
  }
}

function removeQuietly(path: string): void {
  try {
    unlinkSync(path);
  } catch {
    // Not there.
  }
}
