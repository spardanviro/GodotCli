import { existsSync, mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";

import type { CommandHandler } from "../context.js";
import { errorOf, success } from "../envelope.js";
import { PROJECT_FILE } from "../project.js";
import { installBridge } from "./bridge.js";
import { fail, parseCommandArgs, usage } from "./shared.js";

/**
 * `gd new <folder> [--name <name>] [--renderer <r>] [--no-bridge]`: a new,
 * empty Godot project with the bridge in it, ready for `gd open`.
 */

const RENDERERS: ReadonlyMap<string, string> = new Map([
  ["forward_plus", "forward_plus"],
  ["mobile", "mobile"],
  ["gl_compatibility", "gl_compatibility"],
  ["compatibility", "gl_compatibility"],
]);
const DEFAULT_RENDERER = "forward_plus";
const MAX_NAME_LENGTH = 100;
const GITIGNORE = "# Godot 4+ specific ignores\n.godot/\n/android/\n";
const GITATTRIBUTES = "# Normalize EOL for all files that Git considers text files.\n* text=auto eol=lf\n";

/** project.godot as the project manager would write it, less what the editor adds when it first saves. */
export function projectFileText(name: string, renderer: string): string {
  const escaped = name.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
  const lines = [
    "; Engine configuration file.",
    "; It's best edited using the editor UI and not directly,",
    "; since the parameters that go here are not all obvious.",
    "",
    "config_version=5",
    "",
    "[application]",
    "",
    `config/name="${escaped}"`,
  ];
  // Forward+ is what the engine uses when nothing is said.
  if (renderer !== DEFAULT_RENDERER) {
    lines.push("", "[rendering]", "", `renderer/rendering_method="${renderer}"`);
    // On phones the engine would otherwise pick the mobile renderer by itself.
    if (renderer === "gl_compatibility") {
      lines.push(`renderer/rendering_method.mobile="${renderer}"`);
    }
  }
  return `${lines.join("\n")}\n`;
}

export const newCommand: CommandHandler = async (context, globals, args) => {
  const parsed = parseCommandArgs(args, {
    name: { type: "string" },
    renderer: { type: "string", default: DEFAULT_RENDERER },
    "no-bridge": { type: "boolean", default: false },
  });
  if (typeof parsed === "string") {
    return usage("new", parsed);
  }
  const [folder] = parsed.positionals;
  if (folder === undefined || parsed.positionals.length !== 1) {
    return usage("new", "Usage: gd new <folder> [--name <name>] [--renderer forward_plus|mobile|gl_compatibility] [--no-bridge]");
  }
  const renderer = RENDERERS.get(String(parsed.values["renderer"]));
  if (renderer === undefined) {
    return usage("new", "--renderer is forward_plus (desktop), mobile, or gl_compatibility (web and old hardware).");
  }
  const target = resolve(context.cwd, folder);
  const given = parsed.values["name"];
  const name = (typeof given === "string" ? given : basename(target)).trim();
  if (name === "" || name.length > MAX_NAME_LENGTH || /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/u.test(name)) {
    return usage("new", `The project name is 1 to ${MAX_NAME_LENGTH} characters on one line.`);
  }
  if (existsSync(target) && (!statSync(target).isDirectory() || readdirSync(target).length > 0)) {
    return fail(
      "new",
      errorOf("ALREADY_EXISTS", "The folder exists and is not empty.", "Choose another folder; an existing project is opened with `gd open`.", { folder: target }),
    );
  }
  const withBridge = parsed.values["no-bridge"] !== true;
  const files = [PROJECT_FILE, ".gitignore", ".gitattributes"];
  if (globals.dryRun) {
    return {
      envelope: success("new", { dry_run: true, project: target, name, renderer, files, bridge: withBridge }),
      human: `would create ${target} (${files.join(", ")})${withBridge ? " and install the bridge" : ""}\n`,
    };
  }

  const existed = existsSync(target);
  const written: string[] = [];
  try {
    mkdirSync(target, { recursive: true });
    for (const [file, text] of [[PROJECT_FILE, projectFileText(name, renderer)], [".gitignore", GITIGNORE], [".gitattributes", GITATTRIBUTES]] as const) {
      // "wx": the folder was empty a moment ago; never write over what appeared since.
      writeFileSync(join(target, file), text, { flag: "wx" });
      written.push(file);
    }
  } catch {
    // Half a project would make the next attempt fail on a folder that is not empty.
    for (const file of written) {
      rmSync(join(target, file), { force: true });
    }
    if (!existed) {
      rmSync(target, { recursive: true, force: true });
    }
    return fail("new", errorOf("COMMAND_FAILED", "The project files could not be written.", "Check that the folder can be created and written to.", { folder: target }));
  }
  let bridge = false;
  const warnings: string[] = [];
  if (withBridge) {
    const installed = installBridge(context, { ...globals, dryRun: false }, target, false);
    bridge = installed.envelope.success;
    if (!bridge) {
      warnings.push("The project was created, but the bridge could not be installed: run `gd bridge install` in it.");
    }
  }
  const next = [`gd open --project "${target}"`, "gd doctor"];
  return {
    envelope: success("new", { project: target, name, renderer, files, bridge, next }, {}, warnings),
    human: `created ${target}\n${bridge ? "bridge installed\n" : ""}next: ${next.join("; ")}\n`,
  };
};
