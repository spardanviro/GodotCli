import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { DEFAULT_TIMEOUT_MS, callCommand, fetchCommands, handshake, resolveInstance } from "../client.js";
import type { CommandHandler, CommandResult, Context, GlobalOptions } from "../context.js";
import { type Envelope, type EnvelopeError, errorOf, isEnvelopeError, success } from "../envelope.js";
import { type Instance, readInstances } from "../instances.js";
import { findProject, gdcliHome, samePath } from "../project.js";
import { sanitize } from "../text.js";
import { dataAsText, fail, usage } from "./shared.js";

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
  if (!scoped && globals.project !== undefined) {
    return fail("status", project);
  }
  const instances = readInstances(gdcliHome(context), context.platform).filter(
    (instance) => !scoped || samePath(instance.projectPath, project, context.platform),
  );
  const editors = [];
  for (const instance of instances) {
    const outcome = await handshake(instance);
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
  return { envelope, human: `${sanitize(lines.join("\n"))}\n` };
};

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
    default:
      return raw;
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
 * individual flags override its keys.
 */
export function buildArgs(tokens: readonly string[], descriptor: Descriptor, context: Context): Record<string, unknown> | string {
  const types = descriptor.params?.properties ?? {};
  let base: Record<string, unknown> = {};
  const flags: Record<string, unknown> = {};

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
          source = readFileSync(resolve(context.cwd, raw), "utf8");
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
    flags[name] = raw === undefined ? true : coerce(raw, types[name]?.type);
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
