import { cpSync, existsSync, lstatSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import type { CommandHandler, CommandResult, Context, GlobalOptions } from "../context.js";
import { errorOf, success } from "../envelope.js";
import { readInstances } from "../instances.js";
import { PROJECT_FILE, findProject, gdcliHome, samePath } from "../project.js";
import { fail, parseCommandArgs, usage } from "./shared.js";

export const ADDON_RELATIVE_DIR = join("addons", "gdcli");
export const PLUGIN_CFG_RES = "res://addons/gdcli/plugin.cfg";
const PLUGIN_CFG = "plugin.cfg";
const SECTION_HEADER = "[editor_plugins]";

export function readPluginVersion(addonDir: string): string | undefined {
  try {
    return /^version="([^"]+)"/mu.exec(readFileSync(join(addonDir, PLUGIN_CFG), "utf8"))?.[1];
  } catch {
    return undefined;
  }
}

function quotedEntries(list: string): readonly string[] {
  return [...list.matchAll(/"((?:[^"\\]|\\.)*)"/gu)].map((match) => match[1] ?? "");
}

export function isPluginEnabled(projectText: string): boolean {
  const section = sectionRange(projectText);
  if (section === undefined) {
    return false;
  }
  const enabled = /^enabled=PackedStringArray\((.*)\)[ \t]*(?=\r?$)/mu.exec(projectText.slice(section.start, section.end));
  return enabled !== null && quotedEntries(enabled[1] ?? "").includes(PLUGIN_CFG_RES);
}

function sectionRange(text: string): { readonly start: number; readonly end: number } | undefined {
  // The header match stops before the line break, so `start` is at the end
  // of the header line for both LF and CRLF files.
  const header = /^\[editor_plugins\][ \t]*(?=\r?$)/mu.exec(text);
  if (header === null) {
    return undefined;
  }
  const start = header.index + header[0].length;
  const next = /^\[/mu.exec(text.slice(start));
  return { start, end: next === null ? text.length : start + next.index };
}

/**
 * Adds the bridge to the list of enabled editor plugins in project.godot,
 * leaving everything else in the file as it was.
 */
export function enablePlugin(projectText: string): string {
  if (isPluginEnabled(projectText)) {
    return projectText;
  }
  const eol = projectText.includes("\r\n") ? "\r\n" : "\n";
  const entry = `"${PLUGIN_CFG_RES}"`;
  const section = sectionRange(projectText);
  if (section === undefined) {
    const separator = projectText.endsWith(eol) || projectText === "" ? "" : eol;
    return `${projectText}${separator}${eol}${SECTION_HEADER}${eol}${eol}enabled=PackedStringArray(${entry})${eol}`;
  }
  const body = projectText.slice(section.start, section.end);
  const enabled = /^enabled=PackedStringArray\((.*)\)[ \t]*(?=\r?$)/mu.exec(body);
  if (enabled === null) {
    const insertion = `${eol}${eol}enabled=PackedStringArray(${entry})`;
    return `${projectText.slice(0, section.start)}${insertion}${body}${projectText.slice(section.end)}`;
  }
  const existing = (enabled[1] ?? "").trim();
  const list = existing === "" ? entry : `${existing}, ${entry}`;
  const line = `enabled=PackedStringArray(${list})`;
  const at = section.start + enabled.index;
  return `${projectText.slice(0, at)}${line}${projectText.slice(at + enabled[0].length)}`;
}

interface BridgeState {
  readonly project: string;
  readonly installed_version: string | null;
  readonly bundled_version: string | null;
  readonly enabled: boolean;
  readonly editor_running: boolean;
}

function inspect(context: Context, project: string): BridgeState {
  const projectText = readFileSync(join(project, PROJECT_FILE), "utf8");
  const running = readInstances(gdcliHome(context), context.platform).some((instance) =>
    samePath(instance.projectPath, project, context.platform),
  );
  return {
    project,
    installed_version: readPluginVersion(join(project, ADDON_RELATIVE_DIR)) ?? null,
    bundled_version: readPluginVersion(context.addonDir) ?? null,
    enabled: isPluginEnabled(projectText),
    editor_running: running,
  };
}

function isLink(path: string): boolean {
  try {
    return lstatSync(path).isSymbolicLink();
  } catch {
    return false;
  }
}

/**
 * The install deletes and writes below <project>/addons and rewrites
 * project.godot. If any of those is a link, the same operations would land
 * somewhere else on the disk.
 */
function linkInTheWay(project: string): string | undefined {
  return [join(project, "addons"), join(project, ADDON_RELATIVE_DIR), join(project, PROJECT_FILE)].find(isLink);
}

function install(context: Context, globals: GlobalOptions, project: string, force: boolean): CommandResult {
  const link = linkInTheWay(project);
  if (link !== undefined) {
    return fail("bridge", errorOf("PATH_NOT_ALLOWED", "The install location is a link.", "Replace the link with a real folder or file.", { path: link }));
  }
  const before = inspect(context, project);
  if (before.bundled_version === null) {
    return fail("bridge", errorOf("INTERNAL_ERROR", "This gd installation does not contain the bridge addon.", "Reinstall gd.", { looked_in: context.addonDir }));
  }
  const target = join(project, ADDON_RELATIVE_DIR);
  // A folder without a plugin.cfg is something else that happens to be there.
  if (before.installed_version === null && existsSync(target) && !force) {
    return fail(
      "bridge",
      errorOf("ALREADY_EXISTS", "addons/gdcli exists but is not the gd bridge.", "Pass --force to replace it.", { path: target }),
    );
  }
  const differs = before.installed_version !== null && before.installed_version !== before.bundled_version;
  if (differs && !force) {
    return fail(
      "bridge",
      errorOf("ALREADY_EXISTS", "A different version of the bridge is installed in this project.", "Pass --force to replace it.", {
        installed: before.installed_version,
        bundled: before.bundled_version,
      }),
    );
  }
  const copy = before.installed_version === null || force;
  const enable = !before.enabled;
  const actions = [...(copy ? [`copy the addon to ${target}`] : []), ...(enable ? [`enable it in ${PROJECT_FILE}`] : [])];
  if (globals.dryRun) {
    return { envelope: success("bridge", { ...before, dry_run: true, actions }), human: `${actions.join("\n") || "nothing to do"}\n` };
  }

  if (copy) {
    rmSync(target, { recursive: true, force: true });
    mkdirSync(join(project, "addons"), { recursive: true });
    cpSync(context.addonDir, target, { recursive: true });
  }
  if (enable) {
    // Written beside the original and renamed over it, so an interruption
    // cannot leave half a project file.
    const projectFile = join(project, PROJECT_FILE);
    const temporary = `${projectFile}.gdcli-tmp`;
    writeFileSync(temporary, enablePlugin(readFileSync(projectFile, "utf8")));
    renameSync(temporary, projectFile);
  }
  const after = inspect(context, project);
  const warnings =
    actions.length > 0 && after.editor_running
      ? ["The editor is open on this project: restart it (or toggle the plugin in Project Settings > Plugins) to load the bridge."]
      : [];
  const human = `${actions.length === 0 ? "bridge already installed and enabled" : actions.join("\n")}\n${warnings.join("\n")}${warnings.length > 0 ? "\n" : ""}`;
  return { envelope: success("bridge", { ...after, actions }, {}, warnings), human };
}

/** `gd bridge install [--force]` and `gd bridge status`. */
export const bridgeCommand: CommandHandler = async (context, globals, args) => {
  const parsed = parseCommandArgs(args, { force: { type: "boolean", default: false } });
  if (typeof parsed === "string") {
    return usage("bridge", parsed);
  }
  const [action] = parsed.positionals;
  if ((action !== "install" && action !== "status") || parsed.positionals.length !== 1) {
    return usage("bridge", "Usage: gd bridge install [--force] | gd bridge status");
  }
  const project = findProject(context, globals);
  if (typeof project !== "string") {
    return fail("bridge", project);
  }
  if (action === "install") {
    return Promise.resolve(install(context, globals, project, parsed.values["force"] === true));
  }
  const state = inspect(context, project);
  if (state.installed_version === null || !state.enabled || !existsSync(join(project, ADDON_RELATIVE_DIR))) {
    return fail("bridge", errorOf("BRIDGE_NOT_INSTALLED", "The bridge is not installed and enabled in this project.", "Run `gd bridge install`.", { ...state }));
  }
  return { envelope: success("bridge", state), human: `bridge ${state.installed_version} installed and enabled\n` };
};
