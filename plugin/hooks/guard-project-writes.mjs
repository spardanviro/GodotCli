#!/usr/bin/env node
// PreToolUse hook: stops Claude's own file tools from writing the files of a
// Godot project that decide what code the editor runs. Those go through
// `gd command fs_write_text`, where the bridge asks a person at the editor
// before a tool script, an addon or a project setting is written.
//
// It covers the file-writing tools only. A shell command can still write
// anywhere: this is a guard rail that keeps the approved route the easy one,
// not a sandbox. See plugin/README.md.

import { existsSync, realpathSync } from "node:fs";
import { basename, dirname, extname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const PROJECT_FILE = "project.godot";
const BRIDGE_MARKER = join("addons", "gdcli", "plugin.cfg");
const OVERRIDE_VARIABLE = "GDCLI_ALLOW_DIRECT_WRITES";

// Compared in lower case: the default Windows and macOS filesystems fold case.
const GUARDED_ROOT_FILES = new Set(["project.godot", "project.binary", "override.cfg", "export_presets.cfg"]);
const GUARDED_FOLDERS = new Set(["addons", "gdcli_commands", ".godot"]);
// Scripts, the scene and resource files that can carry a script inside, import
// settings (they can name a script to run on import), native libraries, C#
// sources and what a .NET build runs or reads by name (as the bridge's own
// sensitive paths: project and solution files, imported props and targets, a
// project's .user file, response files, package sources, the SDK version).
const GUARDED_EXTENSIONS = new Set([
  ".gd", ".cs", ".tscn", ".tres", ".escn", ".scn", ".res", ".import", ".gdextension",
  ".csproj", ".fsproj", ".vbproj", ".proj", ".sln", ".slnx", ".slnf", ".props", ".targets", ".user", ".rsp",
]);
// Read by name wherever they are: package sources and the SDK version for a
// .NET build, and what git itself acts on (a submodule URL, a filter command).
const GUARDED_NAMES = new Set(["nuget.config", "global.json", "dotnet-tools.json", ".gitmodules", ".gitattributes"]);
// A repository anywhere in the project: its hooks and config are run by git.
const GIT_FOLDER = ".git";

const REASON = [
  "This file belongs to a Godot project that is driven through gdcli, and it decides what code the editor runs.",
  "Scripts, scenes, resources, addons and project settings are changed through the editor, where a person can approve them.",
  "For a script or another text file: write the complete new content to a scratch file outside the project, then run",
  "`gd command fs_write_text --path res://<path> --text-file <scratch file>` (add `--overwrite true --yes` to replace an existing file).",
  "For nodes, scenes, resources, project settings and input actions use the commands made for them (`gd list`).",
  "Do not write the file another way, such as shell redirection or a script. If the editor refuses or a person declines, stop and tell the user.",
].join(" ");

/**
 * Every folder holding project.godot at or above `directory`, nearest first.
 * All of them count: a project file dropped into a subfolder must not hide
 * the project around it.
 * @param {string} directory
 * @returns {string[]}
 */
export function findProjectRoots(directory) {
  const roots = [];
  let current = directory;
  for (;;) {
    if (existsSync(join(current, PROJECT_FILE))) {
      roots.push(current);
    }
    const parent = dirname(current);
    if (parent === current) {
      return roots;
    }
    current = parent;
  }
}

/**
 * The path with every existing folder on the way resolved through links, so a
 * link inside the project does not hide where a write lands and a link into
 * the project does not hide that it lands there.
 * @param {string} path
 * @returns {string}
 */
function throughLinks(path) {
  const missing = [];
  let current = path;
  for (;;) {
    try {
      return join(realpathSync.native(current), ...missing.reverse());
    } catch {
      const parent = dirname(current);
      if (parent === current) {
        return path;
      }
      missing.push(basename(current));
      current = parent;
    }
  }
}

/**
 * Whether a path relative to the project root is one the editor acts on.
 * @param {string} relativePath
 * @returns {boolean}
 */
export function isGuardedRelativePath(relativePath) {
  const segments = relativePath.split(/[\\/]+/u).filter((segment) => segment !== "");
  if (segments.length === 0) {
    return false;
  }
  // On Windows a name ends at a colon (what follows is a stream of the same
  // file: "project.godot::$DATA" is project.godot) and trailing dots and
  // spaces are ignored: "player.gd." is player.gd.
  const folded = segments.map((segment) => (segment.toLowerCase().split(":")[0] ?? "").replace(/[. ]+$/u, ""));
  const name = folded.at(-1) ?? "";
  if (folded.length === 1 && GUARDED_ROOT_FILES.has(name)) {
    return true;
  }
  // The folder itself too: removing or moving addons/ removes everything in it.
  if (folded.length === 1 && GUARDED_FOLDERS.has(name)) {
    return true;
  }
  if (folded.includes(GIT_FOLDER)) {
    return true;
  }
  if (folded.length > 1 && GUARDED_FOLDERS.has(folded[0] ?? "")) {
    return true;
  }
  return GUARDED_EXTENSIONS.has(extname(name)) || GUARDED_NAMES.has(name);
}

/**
 * @param {string} filePath as given to the tool
 * @param {string} cwd
 * @returns {boolean} whether writing it directly is refused
 */
export function isGuardedWrite(filePath, cwd) {
  const absolute = isAbsolute(filePath) ? resolve(filePath) : resolve(cwd, filePath);
  for (const candidate of new Set([absolute, throughLinks(absolute)])) {
    for (const root of findProjectRoots(dirname(candidate))) {
      if (!existsSync(join(root, BRIDGE_MARKER))) {
        continue;
      }
      const inside = relative(root, candidate);
      if (inside !== "" && !inside.startsWith(`..${sep}`) && inside !== ".." && !isAbsolute(inside) && isGuardedRelativePath(inside)) {
        return true;
      }
    }
  }
  return false;
}

/**
 * @param {unknown} event the hook input
 * @param {Readonly<Record<string, string | undefined>>} environment
 * @returns {{ hookSpecificOutput: { hookEventName: string, permissionDecision: string, permissionDecisionReason: string } } | null}
 */
export function decide(event, environment) {
  if (environment[OVERRIDE_VARIABLE] === "1" || typeof event !== "object" || event === null) {
    return null;
  }
  const input = /** @type {{ tool_input?: unknown, cwd?: unknown }} */ (event);
  const toolInput = /** @type {Record<string, unknown>} */ (typeof input.tool_input === "object" && input.tool_input !== null ? input.tool_input : {});
  const cwd = typeof input.cwd === "string" && input.cwd !== "" ? input.cwd : process.cwd();
  const paths = [toolInput["file_path"], toolInput["notebook_path"]].filter((value) => typeof value === "string" && value !== "");
  if (!paths.some((path) => isGuardedWrite(/** @type {string} */ (path), cwd))) {
    return null;
  }
  return { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: REASON } };
}

async function main() {
  let text = "";
  for await (const chunk of process.stdin) {
    text += chunk;
  }
  let event;
  try {
    event = JSON.parse(text);
  } catch {
    // Not a hook event: nothing to decide.
    return;
  }
  const decision = decide(event, process.env);
  if (decision !== null) {
    process.stdout.write(`${JSON.stringify(decision)}\n`);
  }
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(() => {
    // A guard that cannot check refuses: exit status 2 blocks the tool call.
    process.stderr.write("gdcli: the project write guard failed to check this path. Use `gd command fs_write_text` for project files.\n");
    process.exitCode = 2;
  });
}
