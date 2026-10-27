import { apiCommand } from "../commands/api.js";
import { docsCommand } from "../commands/docs.js";
import { doctorCommand } from "../commands/doctor.js";
import { hostCommand } from "../commands/host.js";
import { statusCommand } from "../commands/live.js";
import { checkCommand, runCommand } from "../commands/offline.js";
import type { CommandHandler } from "../context.js";
import type { Descriptor, Parameter } from "./descriptor.js";

/** An MCP tool as tools/list returns it. */
export interface McpTool {
  readonly name: string;
  readonly description: string;
  readonly inputSchema: {
    readonly type: "object";
    readonly properties: Readonly<Record<string, unknown>>;
    readonly required?: readonly string[];
  };
  readonly annotations: {
    readonly readOnlyHint: boolean;
    readonly destructiveHint: boolean;
    readonly idempotentHint: boolean;
    readonly openWorldHint: boolean;
  };
}

/** Request options every modifying bridge command takes besides its own arguments. */
export const CONFIRM_ARG = "confirm";
export const DRY_RUN_ARG = "dry_run";

const REQUIREMENTS: Readonly<Record<string, string>> = {
  scene_open: "a scene open in the editor",
  playing: "the game running from the editor (editor_play)",
  not_playing: "the game not to be running",
};

function modifies(descriptor: Descriptor): boolean {
  return (descriptor.risk ?? "write") !== "read";
}

function descriptionOf(descriptor: Descriptor): string {
  const traits = [descriptor.risk ?? "write", ...(descriptor.undoable === true ? ["one undo step"] : [])];
  const needs = (descriptor.requires ?? []).map((requirement) => REQUIREMENTS[requirement] ?? requirement);
  return [
    `${descriptor.summary ?? ""} [${traits.join(", ")}]`,
    needs.length > 0 ? `Needs ${needs.join(" and ")}.` : "",
    descriptor.returns === undefined ? "" : `Returns: ${descriptor.returns}`,
    descriptor.custom === true ? "Added by this project (gdcli_commands/)." : "",
    "Needs a running editor with the gdcli bridge.",
  ]
    .filter((part) => part !== "")
    .join(" ");
}

/**
 * A bridge command as an MCP tool, under the same name. A command that changes
 * something also takes `confirm` (destructive changes are refused without it;
 * it is a speed bump, not a person's approval, which the editor asks for
 * itself) and `dry_run` (report what would change, change nothing).
 */
export function toolOf(descriptor: Descriptor): McpTool {
  const properties: Record<string, Parameter | Record<string, unknown>> = { ...(descriptor.params?.properties ?? {}) };
  if (modifies(descriptor)) {
    properties[CONFIRM_ARG] ??= { type: "boolean", description: "Confirm a destructive change; without it the editor answers CONFIRMATION_REQUIRED with what would be affected." };
    properties[DRY_RUN_ARG] ??= { type: "boolean", description: "Report what would change without changing anything." };
  }
  const required = descriptor.params?.required ?? [];
  const risk = descriptor.risk ?? "write";
  return {
    name: descriptor.name,
    description: descriptionOf(descriptor),
    inputSchema: { type: "object", properties, ...(required.length > 0 ? { required } : {}) },
    // exec (eval) runs any code in the editor: as dangerous as it gets.
    annotations: { readOnlyHint: risk === "read", destructiveHint: risk === "destructive" || risk === "exec", idempotentHint: risk === "read", openWorldHint: false },
  };
}

/** A gd command offered as a tool: its schema, and how its arguments become a command line. */
export interface OfflineTool {
  readonly tool: McpTool;
  readonly handler: CommandHandler;
  /** The command's own arguments, as `gd <command>` would get them; an error text on bad input. */
  readonly argv: (args: Readonly<Record<string, unknown>>) => readonly string[] | string;
}

function offline(
  name: string,
  description: string,
  properties: Readonly<Record<string, unknown>>,
  required: readonly string[],
  effect: Effect,
  handler: CommandHandler,
  argv: OfflineTool["argv"],
): OfflineTool {
  return {
    tool: {
      name,
      description,
      inputSchema: { type: "object", properties, ...(required.length > 0 ? { required } : {}) },
      annotations: ANNOTATIONS[effect],
    },
    handler,
    argv: guarded(argv),
  };
}

/**
 * What a tool does, as a client's approval rules read it. A tool that runs the
 * project's code (a game run, a script compile that runs static initializers,
 * a headless editor that runs tool scripts) is never marked read-only: a
 * client that waves read-only tools through would run any code a script holds.
 */
type Effect = "reads" | "changes" | "runs-project-code";

const ANNOTATIONS: Readonly<Record<Effect, { readonly readOnlyHint: boolean; readonly destructiveHint: boolean; readonly idempotentHint: boolean; readonly openWorldHint: boolean }>> = {
  reads: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  changes: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  "runs-project-code": { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
};

class WrongType extends Error {}

function text(args: Readonly<Record<string, unknown>>, key: string): string | undefined {
  const value = args[key];
  if (value !== undefined && typeof value !== "string") {
    throw new WrongType(`${key} must be a string.`);
  }
  return value === "" ? undefined : value;
}

function count(args: Readonly<Record<string, unknown>>, key: string): string | undefined {
  const value = args[key];
  if (value !== undefined && (typeof value !== "number" || !Number.isFinite(value))) {
    throw new WrongType(`${key} must be a number.`);
  }
  return value === undefined ? undefined : String(value);
}

/** Turns a type error of one argument into the error text the tool answers with. */
function guarded(argv: OfflineTool["argv"]): OfflineTool["argv"] {
  return (args) => {
    try {
      return argv(args);
    } catch (error: unknown) {
      if (error instanceof WrongType) {
        return error.message;
      }
      throw error;
    }
  };
}

/** A value that would read as an option, or end the options, is not passed on. */
function plain(value: string | undefined, what: string): string | undefined {
  return value !== undefined && value.startsWith("-") ? `${what} cannot start with "-".` : undefined;
}

/**
 * gd commands that work without the editor, or tell whether one is there.
 * `gd exec` is left out on purpose: it runs any GDScript outside the bridge,
 * and a client that only has these tools must not get a way to run code that
 * the editor's approval does not see (protocol.md section 4.3).
 */
export const OFFLINE_TOOLS: readonly OfflineTool[] = [
  offline("gd_status", "The editors with the gdcli bridge that have this project open. Use it to see whether the editor tools will work.", {}, [], "reads", statusCommand, () => []),
  offline(
    "gd_run",
    "Run the project (or one scene) in a separate Godot process for some seconds and report the errors and warnings it printed, with file and line. Runs the project's code. Saves nothing; the editor's unsaved changes are not seen.",
    {
      scene: { type: "string", description: "res:// path of a scene; default: the main scene" },
      seconds: { type: "number", description: "How long to let it run, in seconds, at least 1 (default 10)", minimum: 1, maximum: 600 },
      headless: { type: "boolean", description: "No window (default true)" },
    },
    [],
    "runs-project-code",
    runCommand,
    (args) => {
      const scene = text(args, "scene");
      const problem = plain(scene, "scene");
      if (problem !== undefined) {
        return problem;
      }
      const seconds = count(args, "seconds");
      return [...(scene === undefined ? [] : [scene]), ...(seconds === undefined ? [] : ["--seconds", seconds]), ...(args["headless"] === false ? [] : ["--headless"])];
    },
  ),
  offline(
    "gd_check",
    "Compile GDScript files and report their errors. Loading a script runs its static variable initializers and loads what it preloads, as the game would.",
    { scripts: { type: "array", items: { type: "string" }, description: "res:// paths or paths in the project" } },
    ["scripts"],
    "runs-project-code",
    checkCommand,
    (args) => {
      const scripts = Array.isArray(args["scripts"]) ? args["scripts"].filter((entry): entry is string => typeof entry === "string" && entry !== "") : [];
      if (scripts.length === 0) {
        return "Give at least one script.";
      }
      return scripts.find((script) => script.startsWith("-")) === undefined ? scripts : 'A script path cannot start with "-".';
    },
  ),
  offline(
    "gd_api_class",
    "What a Godot class offers in the installed version: properties, methods, signals, constants, with their descriptions.",
    { name: { type: "string", description: "Class name, e.g. CharacterBody2D" }, member: { type: "string", description: "Only this member" } },
    ["name"],
    "reads",
    apiCommand,
    (args) => {
      const name = text(args, "name");
      const member = text(args, "member");
      const problem = plain(name, "name") ?? plain(member, "member");
      if (name === undefined || problem !== undefined) {
        return problem ?? "Give a class name.";
      }
      return ["class", name, ...(member === undefined ? [] : ["--member", member])];
    },
  ),
  offline(
    "gd_api_search",
    "Find Godot classes and members whose names contain some text.",
    { text: { type: "string" } },
    ["text"],
    "reads",
    apiCommand,
    (args) => {
      const query = text(args, "text");
      return query === undefined ? "Give the text to search for." : plain(query, "text") ?? ["search", query];
    },
  ),
  offline(
    "gd_docs_search",
    "Search the Godot manual (tutorials, best practices, troubleshooting) for pages about some words. Needs a copy of the manual on this machine (`gd docs install`).",
    {
      words: { type: "string", description: "What to look for" },
      limit: { type: "number", minimum: 1, maximum: 50 },
      classes: { type: "boolean", description: "Include the class reference pages" },
    },
    ["words"],
    "reads",
    docsCommand,
    (args) => {
      const words = text(args, "words");
      if (words === undefined) {
        return "Give the words to search for.";
      }
      const list = words.split(/\s+/u).filter((word) => word !== "");
      if (list.some((word) => word.startsWith("-"))) {
        return 'A search word cannot start with "-".';
      }
      const limit = count(args, "limit");
      return ["search", ...(limit === undefined ? [] : ["--limit", limit]), ...(args["classes"] === true ? ["--classes"] : []), ...list];
    },
  ),
  offline(
    "gd_docs_page",
    "Read one page of the Godot manual, or one section of it.",
    { page: { type: "string", description: "Page id from gd_docs_search" }, section: { type: "string", description: "Heading of the section to read" } },
    ["page"],
    "reads",
    docsCommand,
    (args) => {
      const page = text(args, "page");
      const section = text(args, "section");
      const problem = plain(page, "page") ?? plain(section, "section");
      if (page === undefined || problem !== undefined) {
        return problem ?? "Give a page.";
      }
      return ["page", page, ...(section === undefined ? [] : ["--section", section])];
    },
  ),
  offline(
    "gd_host_start",
    "Start a headless editor with the bridge for this project, for when no editor is open. The editor tools then work against it; changes need scene_save to reach disk.",
    {},
    [],
    "runs-project-code",
    hostCommand,
    () => ["start"],
  ),
  offline("gd_host_stop", "Stop the headless editor started with gd_host_start.", {}, [], "changes", hostCommand, () => ["stop"]),
  offline("gd_doctor", "Check the installation: Godot binary, project, bridge addon, reachable editor.", {}, [], "reads", doctorCommand, () => []),
];
