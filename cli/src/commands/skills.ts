import { cpSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

import type { CommandHandler, CommandResult, Context, GlobalOptions } from "../context.js";
import { errorOf, success } from "../envelope.js";
import { nonEmpty } from "../project.js";
import { messageOf } from "../text.js";
import { linkOnTheWay } from "./mcp.js";
import { fail, parseCommandArgs, usage } from "./shared.js";

/** Left in every skill folder gd installs: a folder without it is someone else's and is never replaced. */
export const SKILL_MARKER = ".gdcli-skill";

/** The skills shipped with this package (copied from plugin/skills by the build). */
function shippedSkills(context: Context): { readonly folder: string; readonly names: readonly string[] } {
  const folder = join(dirname(context.addonDir.replace(/[\\/]+$/u, "")), "skills");
  const names = existsSync(folder)
    ? readdirSync(folder).filter((name) => /^[a-z0-9-]+$/u.test(name) && existsSync(join(folder, name, "SKILL.md"))).sort()
    : [];
  return { folder, names };
}

/** Where an agent looks for skills. */
function targetFolder(context: Context, agent: string | undefined, dir: string | undefined): string | undefined {
  if (dir !== undefined) {
    return resolve(context.cwd, dir);
  }
  if (agent === "codex") {
    return join(nonEmpty(context.io.env["CODEX_HOME"]) ?? join(context.homeDir, ".codex"), "skills");
  }
  return undefined;
}

type State = "new" | "update" | "foreign";

function lstatOrUndefined(path: string): ReturnType<typeof lstatSync> | undefined {
  try {
    return lstatSync(path);
  } catch {
    return undefined;
  }
}

/** Whatever is at the path, a dangling link included, is someone else's unless it is a folder gd marked. */
function stateOf(path: string): State {
  const entry = lstatOrUndefined(path);
  if (entry === undefined) {
    return "new";
  }
  return entry.isDirectory() && lstatOrUndefined(join(path, SKILL_MARKER))?.isFile() === true ? "update" : "foreign";
}

/**
 * Copies a skill next to its place, marked, and only then swaps it in: a copy
 * that fails half way leaves the old one (or nothing) behind, never an
 * unmarked folder that later runs would take for someone else's.
 */
function replaceSkill(source: string, target: string, version: string): void {
  const staging = `${target}.gdcli-new`;
  rmSync(staging, { recursive: true, force: true });
  try {
    cpSync(source, staging, { recursive: true });
    writeFileSync(join(staging, SKILL_MARKER), `${version}\n`);
    // Looked at again right before: only a folder gd marked, or nothing, is replaced.
    if (stateOf(target) === "foreign") {
      throw new Error("the folder changed while installing");
    }
    rmSync(target, { recursive: true, force: true });
    renameSync(staging, target);
  } catch (error: unknown) {
    rmSync(staging, { recursive: true, force: true });
    throw error;
  }
}

async function install(context: Context, globals: GlobalOptions, args: readonly string[]): Promise<CommandResult> {
  const parsed = parseCommandArgs(args, { dir: { type: "string" } });
  if (typeof parsed === "string") {
    return usage("skills", parsed);
  }
  const agent = parsed.positionals[0];
  const dir = parsed.values["dir"];
  const folder = targetFolder(context, agent, typeof dir === "string" ? dir : undefined);
  if (folder === undefined || parsed.positionals.length > 1 || (agent !== undefined && agent !== "codex")) {
    return usage("skills", "Give codex, or --dir <folder> for an agent that reads SKILL.md folders from elsewhere.");
  }
  const shipped = shippedSkills(context);
  if (shipped.names.length === 0) {
    return fail("skills", errorOf("PRECONDITION_FAILED", "This gd has no skills to install.", "Build the package (npm run build) or reinstall gd."));
  }
  const link = linkOnTheWay(folder, agent === "codex" && dir === undefined ? context.homeDir : dirname(folder));
  if (link !== undefined) {
    return fail("skills", errorOf("PRECONDITION_FAILED", "The skills folder, or a folder on the way to it, is a symbolic link; gd does not write through links.", undefined, { folder, link }));
  }
  const version = context.readVersion();
  const plan = shipped.names.map((name) => ({ name, path: join(folder, name), state: stateOf(join(folder, name)) }));
  const foreign = plan.filter((entry) => entry.state === "foreign").map((entry) => entry.name);
  const data = { folder, version, skills: plan.map(({ name, state }) => ({ name, state })), skipped: foreign, written: false };
  const lines = plan.map((entry) => `  ${entry.name}  ${entry.state === "foreign" ? "(left alone: a skill of this name is not gd's)" : entry.state}`);
  // --dry-run looks, whatever else is given: --yes with it still writes nothing.
  if (!globals.yes || globals.dryRun) {
    return {
      envelope: success("skills", data, {}, [globals.dryRun ? "Nothing was written: --dry-run." : "Nothing was written: add --yes."]),
      human: `Would install into ${folder}:\n${lines.join("\n")}\n\nRun again with --yes to install them.\n`,
    };
  }
  try {
    mkdirSync(folder, { recursive: true });
    for (const entry of plan.filter((item) => item.state !== "foreign")) {
      replaceSkill(join(shipped.folder, entry.name), entry.path, version);
    }
  } catch (error: unknown) {
    return fail("skills", errorOf("COMMAND_FAILED", "The skills could not be copied.", undefined, { folder, reason: messageOf(error) }));
  }
  const note = foreign.length > 0 ? ` Left alone, because a skill of that name is not gd's: ${foreign.join(", ")}.` : "";
  return {
    envelope: success("skills", { ...data, written: true }, {}, foreign.length > 0 ? [`Not replaced: ${foreign.join(", ")}.`] : []),
    human: `Installed ${plan.length - foreign.length} skills into ${folder}.${note} Start a new session of the agent to pick them up.\n`,
  };
}

function list(context: Context): CommandResult {
  const shipped = shippedSkills(context);
  const described = shipped.names.map((name) => {
    const head = readFileSync(join(shipped.folder, name, "SKILL.md"), "utf8").split(/\r?\n/u);
    const description = head.find((line) => line.startsWith("description:"))?.slice("description:".length).trim() ?? "";
    return { name, description };
  });
  return {
    envelope: success("skills", { skills: described }),
    human: `${described.map((skill) => `${skill.name}\n  ${skill.description}`).join("\n")}\n`,
  };
}

/**
 * `gd skills list`: the skills this gd ships (the Claude plugin's).
 * `gd skills install codex | --dir <folder>`: copy them where another agent
 * reads skills (shown first; written with --yes). The tools themselves reach
 * such an agent through `gd mcp`, or its shell.
 */
export const skillsCommand: CommandHandler = async (context, globals, args) => {
  const [action, ...rest] = args;
  if (action === "list" && rest.length === 0) {
    return list(context);
  }
  if (action === "install") {
    return install(context, globals, rest);
  }
  return usage("skills", "Use gd skills list, or gd skills install codex | --dir <folder>.");
};
