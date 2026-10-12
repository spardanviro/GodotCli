import { type Stats, closeSync, constants, fstatSync, lstatSync, openSync, readFileSync } from "node:fs";

const GROUP_AND_OTHER_WRITE = 0o022;
const GROUP_AND_OTHER = 0o077;

function ownedByCurrentUser(stats: Stats): boolean {
  return typeof process.getuid !== "function" || stats.uid === process.getuid();
}

/**
 * True when only the current user can change what is at `path`. Used for the
 * folders and files under ~/.gdcli that gd acts on: its configuration names a
 * program to run, and its cache is shown to the agent.
 * Windows has no mode bits; there the user profile's access control applies.
 */
export function isWritableOnlyByUser(path: string, platform: NodeJS.Platform): boolean {
  let stats;
  try {
    stats = lstatSync(path);
  } catch {
    return false;
  }
  if (stats.isSymbolicLink()) {
    return false;
  }
  return platform === "win32" || (ownedByCurrentUser(stats) && (stats.mode & GROUP_AND_OTHER_WRITE) === 0);
}

export interface PrivateFileOptions {
  readonly platform: NodeJS.Platform;
  readonly maxBytes: number;
  /** Also refuse files that others can read, as for a file holding a token. */
  readonly secret: boolean;
}

/**
 * Reads a file after checking, on the same open handle, that it is a regular
 * file of acceptable size that belongs to the current user. Checking the
 * handle rather than the path leaves no gap in which the file can be swapped.
 */
export function readPrivateFile(path: string, options: PrivateFileOptions): string | undefined {
  // Where O_NOFOLLOW is missing this check stands in for it.
  try {
    if (lstatSync(path).isSymbolicLink()) {
      return undefined;
    }
  } catch {
    return undefined;
  }
  let descriptor: number;
  try {
    // O_NOFOLLOW is not available on Windows, where it is simply 0.
    descriptor = openSync(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  } catch {
    return undefined;
  }
  try {
    const stats = fstatSync(descriptor);
    if (!stats.isFile() || stats.size > options.maxBytes) {
      return undefined;
    }
    if (options.platform !== "win32") {
      const forbidden = options.secret ? GROUP_AND_OTHER : GROUP_AND_OTHER_WRITE;
      if (!ownedByCurrentUser(stats) || (stats.mode & forbidden) !== 0) {
        return undefined;
      }
    }
    return readFileSync(descriptor, "utf8");
  } catch {
    return undefined;
  } finally {
    closeSync(descriptor);
  }
}
