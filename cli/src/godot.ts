import { existsSync, realpathSync, statSync } from "node:fs";
import { delimiter, isAbsolute, join, relative, resolve } from "node:path";

import type { Context, GlobalOptions, ProcessResult } from "./context.js";
import { type EnvelopeError, errorOf } from "./envelope.js";
import { findProject, gdcliHome, leavesFolder, nonEmpty } from "./project.js";
import { isWritableOnlyByUser, readPrivateFile } from "./trust.js";

export const GODOT_ENV = "GODOT_BIN";
export const CONFIG_FILE = "config.json";
const PATH_NAMES = ["godot", "godot4"] as const;
const VERSION_TIMEOUT_MS = 30_000;
const MAX_CONFIG_BYTES = 65_536;
const VERSION_PATTERN = /^(?<major>\d+)\.(?<minor>\d+)(?:\.(?<patch>\d+))?\.(?<status>[a-z]+\d*)/u;

export interface GodotVersion {
  readonly major: number;
  readonly minor: number;
  readonly patch: number;
  readonly status: string;
  readonly text: string;
}

export const MIN_VERSION = { major: 4, minor: 3 } as const;

export interface UserConfig {
  readonly godotBin?: string;
  readonly allowOffline: boolean;
}

/** Read from the user's home only, never from the project (docs/protocol.md section 1.3). */
export function readUserConfig(context: Context): UserConfig {
  // The file names a program to run, so it must be one only this user could have written.
  const home = gdcliHome(context);
  const content = isWritableOnlyByUser(home, context.platform)
    ? readPrivateFile(join(home, CONFIG_FILE), { platform: context.platform, maxBytes: MAX_CONFIG_BYTES, secret: false })
    : undefined;
  try {
    const parsed: unknown = content === undefined ? null : JSON.parse(content);
    if (typeof parsed === "object" && parsed !== null) {
      const fields = parsed as Record<string, unknown>;
      const godotBin = typeof fields["godot_bin"] === "string" ? nonEmpty(fields["godot_bin"]) : undefined;
      return { allowOffline: fields["allow_offline"] !== false, ...(godotBin === undefined ? {} : { godotBin }) };
    }
  } catch {
    // Not JSON: defaults apply.
  }
  return { allowOffline: true };
}

function isFile(path: string): boolean {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

/**
 * The GUI build of Godot on Windows does not write to pipes; a console
 * wrapper with the same name is shipped next to it.
 */
export function preferConsoleBinary(path: string, platform: NodeJS.Platform): string {
  if (platform !== "win32" || !/\.exe$/iu.test(path) || /console\.exe$/iu.test(path)) {
    return path;
  }
  const base = path.replace(/\.exe$/iu, "");
  return [`${base}.console.exe`, `${base}_console.exe`].find(isFile) ?? path;
}

/**
 * Looks the name up in PATH by hand. The working directory and relative PATH
 * entries are skipped on purpose: the working directory is usually the
 * project, and a project must not be able to supply its own "godot".
 */
export function findOnPath(context: Context, names: readonly string[] = PATH_NAMES): string | undefined {
  const extensions = context.platform === "win32" ? [".exe", ""] : [""];
  const directories = (context.io.env["PATH"] ?? context.io.env["Path"] ?? "")
    .split(delimiter)
    .filter((entry) => entry !== "" && isAbsolute(entry));
  for (const directory of directories) {
    for (const name of names) {
      for (const extension of extensions) {
        const candidate = join(directory, `${name}${extension}`);
        // Batch files are not programs gd can start without a shell.
        if (isFile(candidate) && !/\.(bat|cmd)$/iu.test(candidate)) {
          return candidate;
        }
      }
    }
  }
  return undefined;
}

function isInsideProject(context: Context, globals: GlobalOptions, binary: string): boolean {
  const project = findProject(context, globals);
  if (typeof project !== "string") {
    return false;
  }
  try {
    const inside = relative(realpathSync(project), realpathSync(binary));
    return inside !== "" && !leavesFolder(inside);
  } catch {
    return true;
  }
}

/** --godot, then GODOT_BIN, then the user config, then PATH. */
export function locateGodot(context: Context, globals: GlobalOptions): string | EnvelopeError {
  const configured = globals.godot ?? nonEmpty(context.io.env[GODOT_ENV]) ?? readUserConfig(context).godotBin;
  if (configured !== undefined) {
    // A network path would make Windows authenticate to whoever serves it.
    if (configured.startsWith("\\\\") || configured.startsWith("//")) {
      return errorOf("GODOT_NOT_FOUND", "The Godot binary cannot be on a network path.", undefined, { path: configured });
    }
    // A bare name such as GODOT_BIN=godot4 means "the one on PATH", never a
    // file of that name in the working directory.
    const isBareName = !/[\\/]/u.test(configured);
    const absolute = isBareName ? findOnPath(context, [configured]) : resolve(context.cwd, configured);
    if (absolute === undefined || !isFile(absolute)) {
      return errorOf("GODOT_NOT_FOUND", "The configured Godot binary does not exist.", undefined, { path: absolute ?? configured });
    }
    if (isInsideProject(context, globals, absolute)) {
      return errorOf(
        "GODOT_NOT_FOUND",
        "The Godot binary cannot be a file inside the project.",
        "A project must not supply the program that gd runs. Install Godot outside the project.",
        { path: absolute },
      );
    }
    return preferConsoleBinary(absolute, context.platform);
  }
  const found = findOnPath(context);
  return found === undefined
    ? errorOf(
        "GODOT_NOT_FOUND",
        "No Godot editor binary was found.",
        `Pass --godot <path>, set ${GODOT_ENV}, or put godot on PATH.`,
      )
    : preferConsoleBinary(found, context.platform);
}

export function parseVersion(output: string): GodotVersion | undefined {
  const text = output.trim().split(/\r?\n/u).at(-1)?.trim() ?? "";
  const groups = VERSION_PATTERN.exec(text)?.groups;
  if (groups === undefined) {
    return undefined;
  }
  return {
    major: Number(groups["major"]),
    minor: Number(groups["minor"]),
    patch: Number(groups["patch"] ?? 0),
    status: groups["status"] ?? "",
    text,
  };
}

export function isSupported(version: GodotVersion): boolean {
  return version.major > MIN_VERSION.major || (version.major === MIN_VERSION.major && version.minor >= MIN_VERSION.minor);
}

export interface Godot {
  readonly bin: string;
  readonly version: GodotVersion;
}

/** Locates Godot and checks its version; unknown flags are silently ignored by the engine, so the version gate is ours. */
export async function requireGodot(context: Context, globals: GlobalOptions): Promise<Godot | EnvelopeError> {
  if (!readUserConfig(context).allowOffline) {
    return errorOf(
      "PRECONDITION_FAILED",
      "Commands that start Godot are turned off.",
      `Set allow_offline to true in ${join(gdcliHome(context), CONFIG_FILE)}.`,
    );
  }
  const bin = locateGodot(context, globals);
  if (typeof bin !== "string") {
    return bin;
  }
  const result = await context.processes.run(bin, ["--version"], { timeoutMs: VERSION_TIMEOUT_MS });
  const version = parseVersion(result.stdout);
  if (version === undefined) {
    return errorOf("GODOT_NOT_FOUND", "The binary did not report a Godot version.", "Point --godot at a Godot 4 editor binary.", {
      path: bin,
      ...(result.spawnError === undefined ? {} : { reason: result.spawnError }),
    });
  }
  if (!isSupported(version)) {
    return errorOf("UNSUPPORTED_GODOT_VERSION", "gd needs Godot 4.3 or newer.", undefined, { found: version.text });
  }
  return { bin, version };
}

export interface GodotRun {
  readonly result: ProcessResult;
  readonly output: string;
}

/** Runs Godot against a project. `args` must already be validated; nothing here is taken from a shell. */
export async function runGodot(
  context: Context,
  godot: Godot,
  project: string,
  args: readonly string[],
  timeoutMs: number,
): Promise<GodotRun> {
  const result = await context.processes.run(godot.bin, ["--path", project, ...args], { cwd: project, timeoutMs });
  return { result, output: `${result.stdout}\n${result.stderr}` };
}

/** The counterpart of preferConsoleBinary: for starting the editor, the wrapper would only add a console window. */
export function preferGuiBinary(path: string, platform: NodeJS.Platform): string {
  if (platform !== "win32") {
    return path;
  }
  const gui = path.replace(/[._]console\.exe$/iu, ".exe");
  return gui !== path && isFile(gui) ? gui : path;
}

export function projectHasBeenImported(project: string): boolean {
  return existsSync(join(project, ".godot"));
}
