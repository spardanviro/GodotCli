import { existsSync, realpathSync, statSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

import type { Context, GlobalOptions } from "./context.js";
import { type EnvelopeError, errorOf } from "./envelope.js";

export const PROJECT_FILE = "project.godot";
export const PROJECT_ENV = "GDCLI_PROJECT";
export const HOME_ENV = "GDCLI_HOME";
export const HOME_DIR_NAME = ".gdcli";
const RES_PREFIX = "res://";

function hasProjectFile(directory: string): boolean {
  return existsSync(join(directory, PROJECT_FILE));
}

/** --project, then GDCLI_PROJECT, then the nearest project.godot above the working directory. */
export function findProject(context: Context, globals: GlobalOptions): string | EnvelopeError {
  const explicit = nonEmpty(globals.project) ?? nonEmpty(context.io.env[PROJECT_ENV]);
  if (explicit !== undefined) {
    const directory = resolve(context.cwd, explicit);
    const candidate = directory.endsWith(PROJECT_FILE) ? dirname(directory) : directory;
    return hasProjectFile(candidate)
      ? candidate
      : errorOf("NO_PROJECT", "The given project folder has no project.godot.", undefined, { path: candidate });
  }
  let directory = resolve(context.cwd);
  for (;;) {
    if (hasProjectFile(directory)) {
      return directory;
    }
    const parent = dirname(directory);
    if (parent === directory) {
      return errorOf(
        "NO_PROJECT",
        "No project.godot found in this folder or any parent.",
        "Run gd inside a Godot project or pass --project <path>.",
      );
    }
    directory = parent;
  }
}

export function nonEmpty(value: string | undefined): string | undefined {
  return value === undefined || value === "" ? undefined : value;
}

export function gdcliHome(context: Context): string {
  return nonEmpty(context.io.env[HOME_ENV]) ?? join(context.homeDir, HOME_DIR_NAME);
}

/** Path comparison as the filesystem would do it: separators unified, case folded on Windows. */
export function samePath(a: string, b: string, platform: NodeJS.Platform): boolean {
  const normalize = (value: string): string => {
    const unified = value.replaceAll("\\", "/").replace(/\/+$/u, "");
    return platform === "win32" ? unified.toLowerCase() : unified;
  };
  return normalize(a) === normalize(b);
}

/** For the result of path.relative(): true when it points out of the base folder. A file named "..foo" does not. */
export function leavesFolder(relativePath: string): boolean {
  return relativePath === ".." || relativePath.startsWith(`..${sep}`) || isAbsolute(relativePath);
}

const HIDDEN_ROOTS = [".godot", ".git"];
const RESERVED_DEVICE = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$/iu;

// Compared in lower case: the default Windows and macOS filesystems fold case.
function isHidden(segments: readonly string[]): boolean {
  return segments.some((segment) => HIDDEN_ROOTS.includes(segment.toLowerCase()));
}

/** Same rules as the bridge's path_policy.gd (docs/protocol.md section 4.4). */
function isPlainSegment(segment: string): boolean {
  if (segment === "" || segment.endsWith(".") || segment.endsWith(" ")) {
    return false;
  }
  // Alternate data streams, and NTFS short names such as GODOT~1 that alias a hidden folder.
  if (segment.includes(":") || /~\d/u.test(segment)) {
    return false;
  }
  return !RESERVED_DEVICE.test(segment);
}

function realOrSame(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
}

/**
 * Like samePath, but two spellings of one folder also match: the editor
 * reports the real location, while gd may have been reached through a link.
 */
export function sameLocation(a: string, b: string, platform: NodeJS.Platform): boolean {
  return samePath(a, b, platform) || samePath(realOrSame(a), realOrSame(b), platform);
}

function notAllowed(message: string, input: string): EnvelopeError {
  return errorOf("PATH_NOT_ALLOWED", message, "Use a res:// path or a path inside the project.", { path: input });
}

/**
 * Turns a user-supplied scene or script path into a res:// path, refusing
 * anything that could be read as an option or that leaves the project
 * (docs/protocol.md sections 1.3 and 4.4).
 */
export function toResPath(project: string, cwd: string, input: string, kind: "file" | "file or folder" = "file"): string | EnvelopeError {
  if (input === "" || input.startsWith("-")) {
    return notAllowed("A path cannot be empty or start with a dash.", input);
  }
  const absolute = input.startsWith(RES_PREFIX)
    ? resolve(project, input.slice(RES_PREFIX.length))
    : resolve(cwd, input);
  if (input.startsWith(RES_PREFIX) && isAbsolute(input.slice(RES_PREFIX.length))) {
    return notAllowed("A res:// path must be relative to the project.", input);
  }

  const inside = relative(project, absolute);
  if (inside === "" || leavesFolder(inside)) {
    return notAllowed("The path is outside the project.", input);
  }
  const segments = inside.split(sep);
  if (!segments.every(isPlainSegment)) {
    return notAllowed("The path contains a segment that is not allowed.", input);
  }
  if (isHidden(segments)) {
    return notAllowed("This location is not accessible.", input);
  }
  if (!existsSync(absolute) || (kind === "file" && !statSync(absolute).isFile())) {
    return errorOf("RESOURCE_NOT_FOUND", kind === "file" ? "The file does not exist." : "There is nothing at this path.", undefined, { path: input });
  }
  // A link inside the project may point anywhere, including at a hidden
  // folder; judge the place the path really leads to.
  const realInside = relative(realpathSync(project), realpathSync(absolute));
  if (leavesFolder(realInside) || isHidden(realInside.split(sep))) {
    return notAllowed("The path leaves the project or enters a hidden folder through a link.", input);
  }
  return `${RES_PREFIX}${segments.join("/")}`;
}
