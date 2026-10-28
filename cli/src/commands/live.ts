import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { DEFAULT_TIMEOUT_MS, callCommand, fetchCommands, handshake, resolveInstance } from "../client.js";
import type { CommandHandler, CommandResult, Context, GlobalOptions } from "../context.js";
import { type Envelope, type EnvelopeError, errorOf, isEnvelopeError, success } from "../envelope.js";
import { type Instance, readInstances, removeStale } from "../instances.js";
import { findProject, gdcliHome, sameLocation } from "../project.js";
import { sanitize } from "../text.js";
import { dataAsText, fail, parseCommandArgs, usage } from "./shared.js";

interface Descriptor {
  readonly name: string;
  readonly group?: string;
  readonly summary?: string;
  readonly risk?: string;
  readonly params?: { readonly properties?: Readonly<Record<string, { readonly type?: string }>> };
}

function timeoutOf(globals: GlobalOptions): number {
  return globals.timeoutMs ?? DEFAULT_TIMEOUT_MS;
}

function withWarnings(envelope: Envelope, extra: readonly string[]): Envelope {
  return extra.length === 0 ? envelope : { ...envelope, warnings: [...extra, ...envelope.warnings] };
}

/** The token never appears in output. */
function publicView(instance: Instance, state: string): Record<string, unknown> {
  return {
    instance_id: instance.instanceId,
    state,
    project_name: instance.projectName,
    project_path: instance.projectPath,
    godot_version: instance.godotVersion,
    bridge_version: instance.bridgeVersion,
    port: instance.port,
    pid: instance.pid,
    headless: instance.headless,
    started_at: instance.startedAt,
  };
}

/** `gd status`: every editor gd can see; inside a project, only that project's. */
export const statusCommand: CommandHandler = async (context, globals) => {
  const project = findProject(context, globals);
  const scoped = typeof project === "string";
  // A project that was named (--project or GDCLI_PROJECT) and is not there is an error, not "every editor".
  if (!scoped && (globals.project !== undefined || (context.io.env["GDCLI_PROJECT"] ?? "") !== "")) {
    return fail("status", project);
  }
  const instances = readInstances(gdcliHome(context), context.platform).filter(
    (instance) =>
      (!scoped || sameLocation(instance.projectPath, project, context.platform)) &&
      (globals.instance === undefined || instance.instanceId === globals.instance),
  );
  const editors = [];
  for (const instance of instances) {
    const outcome = await handshake(instance);
    if (outcome.state === "gone") {
      // Shown this once: an editor that was killed left its lock file behind.
      removeStale(instance);
    }
    editors.push(publicView(instance, outcome.state === "protocol" ? "protocol_mismatch" : outcome.state));
  }

  const ready = editors.filter((editor) => editor["state"] === "ready");
  if (ready.length === 0) {
    return fail(
      "status",
      errorOf("NO_EDITOR", "No reachable editor with the gd bridge.", "Open the project in Godot (`gd open`), or run `gd doctor`.", {
        editors,
      }),
    );
  }
  const lines = editors.map(
    (editor) => `${String(editor["state"]).padEnd(8)} ${String(editor["project_name"])}  Godot ${String(editor["godot_version"])}  ${String(editor["project_path"])}  [${String(editor["instance_id"])}]`,
  );
  return { envelope: success("status", { editors }), human: `${sanitize(lines.join("\n"))}\n` };
};

function descriptorsOf(envelope: Envelope): readonly Descriptor[] {
  const commands = (envelope.data as { commands?: unknown } | null)?.commands;
  return Array.isArray(commands) ? (commands as Descriptor[]) : [];
}

/** `gd list`: the commands the connected editor exposes, with their argument schemas. */
export const listCommand: CommandHandler = async (context, globals) => {
  const resolved = await resolveInstance(context, globals);
  if (isEnvelopeError(resolved)) {
    return fail("list", resolved);
  }
  const envelope = withWarnings(await fetchCommands(resolved.instance, timeoutOf(globals)), resolved.warnings);
  const width = Math.max(0, ...descriptorsOf(envelope).map((descriptor) => descriptor.name.length));
  const lines = descriptorsOf(envelope).map(
    (descriptor) => `${descriptor.name.padEnd(width)}  ${(descriptor.risk ?? "").padEnd(11)}  ${descriptor.summary ?? ""}`,
  );
  return { envelope, human: envelope.success ? `${sanitize(lines.join("\n"))}\n` : "" };
};

const FILE_SUFFIX = "_file";
/** In place of a file name: read standard input. */
const STDIN = "-";

/** The text of a file named on the command line, or of standard input for "-". */
function readInput(context: Context, file: string): string {
  const text = file === STDIN ? context.io.readStdin() : readFileSync(resolve(context.cwd, file), "utf8");
  // Windows PowerShell 5.1 starts the files it writes with a byte order mark.
  return text.startsWith(BOM) ? text.slice(BOM.length) : text;
}

const BOM = "﻿";

/** An object or array argument that is not JSON is the caller's mistake, said here rather than as a type mismatch from the editor. */
function typedValue(raw: string, type: string | undefined, label: string): { readonly value: unknown } | string {
  if (type === "array" || type === "object") {
    try {
      JSON.parse(raw);
    } catch {
      return `${label} is not valid JSON (an ${type} is expected).`;
    }
  }
  return { value: coerce(raw, type) };
}

/** Standard input can be read once: a second "-" would silently be empty. */
function namesStdinTwice(tokens: readonly string[]): boolean {
  return tokens.filter((token, index) => token === STDIN && (tokens[index - 1] ?? "").endsWith("-file")).length + tokens.filter((token) => token.endsWith(`-file=${STDIN}`)).length > 1;
}

function coerce(raw: string, type: string | undefined): unknown {
  switch (type) {
    case "integer":
    case "number":
      return /^-?\d+(\.\d+)?$/u.test(raw) ? Number(raw) : raw;
    case "boolean":
      return raw === "true" ? true : raw === "false" ? false : raw;
    case "array":
    case "object":
      try {
        return JSON.parse(raw) as unknown;
      } catch {
        return raw;
      }
    case "string":
      return raw;
    default:
      // A parameter without a declared type takes any JSON value, e.g. the
      // value of project_settings_set; anything that is not JSON is a string.
      try {
        return JSON.parse(raw) as unknown;
      } catch {
        return raw;
      }
  }
}

// The parser's own message would quote the input, which may be project content.
function readJsonObject(source: string, label: string): Record<string, unknown> | string {
  try {
    const parsed: unknown = JSON.parse(source);
    if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>;
    }
    return `${label} must be a JSON object.`;
  } catch {
    return `${label} is not valid JSON.`;
  }
}

/**
 * Turns "--key value", "--key=value" and bare "--flag" into arguments, typed
 * by the command's schema. --args and --args-file supply a JSON object;
 * individual flags override its keys. --<name>-file reads the value of the
 * parameter <name> from a file: a script goes to the editor without having to
 * be quoted for the shell. A file named "-" is standard input.
 */
export function buildArgs(tokens: readonly string[], descriptor: Descriptor, context: Context): Record<string, unknown> | string {
  const types = descriptor.params?.properties ?? {};
  let base: Record<string, unknown> = {};
  const flags: Record<string, unknown> = {};
  if (namesStdinTwice(tokens)) {
    return "Standard input (-) can be given to one argument only.";
  }

  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index] ?? "";
    if (!token.startsWith("--") || token === "--") {
      return "Unexpected positional argument. Command arguments are written as --name value.";
    }
    const equals = token.indexOf("=");
    const name = (equals === -1 ? token.slice(2) : token.slice(2, equals)).replaceAll("-", "_");
    const next = tokens[index + 1];
    const hasInlineValue = equals !== -1;
    const takesNext = !hasInlineValue && next !== undefined && !next.startsWith("--");
    const raw = hasInlineValue ? token.slice(equals + 1) : takesNext ? next : undefined;
    if (takesNext) {
      index += 1;
    }

    if (name === "args" || name === "args_file") {
      if (raw === undefined) {
        return `--${name.replace("_", "-")} needs a value.`;
      }
      let source = raw;
      if (name === "args_file") {
        try {
          source = readInput(context, raw);
        } catch {
          return "Cannot read the file given to --args-file.";
        }
      }
      const parsed = readJsonObject(source, `--${name.replace("_", "-")}`);
      if (typeof parsed === "string") {
        return parsed;
      }
      base = { ...base, ...parsed };
      continue;
    }
    const fromFile = name.endsWith(FILE_SUFFIX) && types[name] === undefined ? name.slice(0, -FILE_SUFFIX.length) : "";
    if (Object.hasOwn(types, fromFile)) {
      if (raw === undefined) {
        return `--${fromFile.replaceAll("_", "-")}-file needs a value.`;
      }
      const label = `--${fromFile.replaceAll("_", "-")}-file`;
      let text: string;
      try {
        text = readInput(context, raw);
      } catch {
        return `Cannot read the file given to ${label}.`;
      }
      const typed = typedValue(text, types[fromFile]?.type, label);
      if (typeof typed === "string") {
        return typed;
      }
      flags[fromFile] = typed.value;
      continue;
    }
    if (raw === undefined) {
      flags[name] = true;
      continue;
    }
    const typed = typedValue(raw, types[name]?.type, `--${name.replaceAll("_", "-")}`);
    if (typeof typed === "string") {
      return typed;
    }
    flags[name] = typed.value;
  }
  return { ...base, ...flags };
}

async function runBridgeCommand(
  context: Context,
  globals: GlobalOptions,
  name: string,
  tokens: readonly string[],
): Promise<CommandResult> {
  const resolved = await resolveInstance(context, globals);
  if (isEnvelopeError(resolved)) {
    return fail(name, resolved);
  }
  const listing = await fetchCommands(resolved.instance, timeoutOf(globals));
  if (!listing.success) {
    return { envelope: listing, human: "" };
  }
  const descriptor = descriptorsOf(listing).find((entry) => entry.name === name);
  if (descriptor === undefined) {
    const unknown: EnvelopeError = errorOf("UNKNOWN_COMMAND", "The editor has no such command.", "Run `gd list` to see the commands.", {
      command: name,
    });
    return fail(name, unknown);
  }
  const args = buildArgs(tokens, descriptor, context);
  if (typeof args === "string") {
    return fail(name, errorOf("INVALID_ARGS", args, `Run \`gd list --json\` for the arguments of ${name}.`));
  }
  const envelope = await callCommand(resolved.instance, name, {
    args,
    confirm: globals.yes,
    dryRun: globals.dryRun,
    timeoutMs: timeoutOf(globals),
  });
  return { envelope: withWarnings(envelope, resolved.warnings), human: dataAsText(envelope) };
}

/** Calls one bridge command with arguments that are already an object. */
export async function invokeBridge(
  context: Context,
  globals: GlobalOptions,
  name: string,
  args: Readonly<Record<string, unknown>>,
): Promise<CommandResult> {
  const resolved = await resolveInstance(context, globals);
  if (isEnvelopeError(resolved)) {
    return fail(name, resolved);
  }
  const envelope = await callCommand(resolved.instance, name, {
    args,
    confirm: globals.yes,
    dryRun: globals.dryRun,
    timeoutMs: timeoutOf(globals),
  });
  return { envelope: withWarnings(envelope, resolved.warnings), human: dataAsText(envelope) };
}

/**
 * `gd eval <code>` or `gd eval --file <path>`: run GDScript in the editor.
 * The bridge refuses unless the user enabled it in the editor settings, and
 * in the standard access mode it also needs --yes.
 */
export const evalCommand: CommandHandler = async (context, globals, args) => {
  const parsed = parseCommandArgs(args, { file: { type: "string" } });
  if (typeof parsed === "string") {
    return usage("eval", parsed);
  }
  const file = parsed.values["file"];
  // After "--" the code may start with "-" (gd eval -- "-1 + 2").
  const pieces = [...parsed.positionals, ...parsed.passthrough];
  const inline = pieces[0];
  if ((typeof file === "string") === (inline !== undefined) || pieces.length > 1) {
    return usage("eval", "Give the code as one argument (after -- when it starts with -), or --file <path>.");
  }
  let code = inline ?? "";
  if (typeof file === "string") {
    try {
      code = readFileSync(resolve(context.cwd, file), "utf8").replace(/^\uFEFF/u, "");
    } catch {
      return fail("eval", errorOf("RESOURCE_NOT_FOUND", "The file given to --file could not be read.", undefined, { file }));
    }
  }
  return invokeBridge(context, globals, "eval", { code });
};

/** `gd command <name> [--arg value ...]`; without a name it lists the commands. */
export const commandCommand: CommandHandler = async (context, globals, args) => {
  const [name, ...tokens] = args;
  if (name === undefined) {
    return listCommand(context, globals, []);
  }
  if (!/^[a-z][a-z0-9_]*$/u.test(name)) {
    return usage("command", "Command names are lower case with underscores, e.g. scene_tree.");
  }
  return runBridgeCommand(context, globals, name, tokens);
};
