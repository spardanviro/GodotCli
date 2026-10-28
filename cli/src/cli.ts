import { readFileSync } from "node:fs";

import { sanitizeEnvelope } from "./clean-envelope.js";
import { apiCommand } from "./commands/api.js";
import { bridgeCommand } from "./commands/bridge.js";
import { docsCommand } from "./commands/docs.js";
import { doctorCommand } from "./commands/doctor.js";
import { hostCommand } from "./commands/host.js";
import { mcpCommand } from "./commands/mcp.js";
import { skillsCommand } from "./commands/skills.js";
import { commandCommand, evalCommand, listCommand, statusCommand } from "./commands/live.js";
import { newCommand } from "./commands/new.js";
import { checkCommand, execCommand, exportCommand, importCommand, openCommand, runCommand } from "./commands/offline.js";
import { testCommand } from "./commands/test-runner.js";
import type { CommandHandler, CommandResult, Context, GlobalOptions, Io, OutputFormat } from "./context.js";
import { type Envelope, errorOf, exitCodeOf, failure, success } from "./envelope.js";
import { nonEmpty } from "./project.js";
import { type ExitCode, PROTOCOL_VERSION } from "./protocol.js";
import { messageOf, sanitize } from "./text.js";

export type { Io } from "./context.js";

const OUTPUT_FORMATS: readonly OutputFormat[] = ["human", "json"];
const FORMAT_ENV_VAR = "GDCLI_FORMAT";
const JSON_INDENT = 2;
const MS_PER_SECOND = 1000;
const MAX_TIMEOUT_SECONDS = 3600;

const COMMANDS: Readonly<Record<string, CommandHandler>> = {
  status: statusCommand,
  list: listCommand,
  command: commandCommand,
  cmd: commandCommand,
  eval: evalCommand,
  host: hostCommand,
  doctor: doctorCommand,
  open: openCommand,
  run: runCommand,
  check: checkCommand,
  exec: execCommand,
  test: testCommand,
  import: importCommand,
  export: exportCommand,
  api: apiCommand,
  bridge: bridgeCommand,
  new: newCommand,
  docs: docsCommand,
  mcp: mcpCommand,
  skills: skillsCommand,
};

const USAGE = `Usage: gd <command> [options]

Running editor (needs the bridge addon, see "gd bridge install"):
  status                     Editors gd can reach
  list                       Commands the editor exposes, with their arguments
  command <name> [--arg v]   Run one of them, e.g. gd command node_create --type Sprite2D
                             --args <json> | --args-file <f> give all arguments; --<arg>-file <f>
                             reads one argument from a file ("-" is standard input)
  eval <code> | --file <f>   Run GDScript in the editor (off unless enabled there)
  host start | host stop     Run a headless editor as the host when none is open

Without an editor (starts the Godot binary):
  run [scene] [--seconds N] [--headless]   Run the project and report its errors
  check <script>...          Parse scripts for errors
  exec <script> [-- args]    Run a SceneTree/MainLoop script headless
  test [paths] [--framework gut|gdunit4] [--select <text>] [--junit <file>]
                             Run the project's GUT or gdUnit4 tests and report the failures
  import                     Import the project's resources
  export <preset> <output> [--debug|--pack]
  api class <Name> [--member m] | api search <text>
  open [scene]               Start the editor on the project

The manual (a copy of the Godot documentation on this machine):
  docs search <words> [--limit N] [--classes]
  docs page <page> [--section <heading>] [--max-chars <n>]
  docs install [4.5]         Download the manual for your Godot version (text only; needs git)
  docs use <folder> | docs where

For other agents (Model Context Protocol):
  mcp [--tools <groups>]     Serve the editor's commands and gd's own as MCP tools and resources on stdin/stdout
                             (--tools core,game,...: only those groups; see docs/protocol.md 6.8)
  mcp configure <client> [--dir <folder>] [--command gd] [--tools <groups>]
                             Add that server to claude, codex, cursor, vscode or gemini
                             (shows the change; writes it with --yes)
  skills list                The skills gd ships (the Claude plugin's), for other agents
  skills install codex | --dir <folder>   (codex: under $CODEX_HOME, default ~/.codex)
                             Copy them where the agent reads skills (with --yes)

Setup:
  new <folder> [--name N] [--renderer forward_plus|mobile|gl_compatibility] [--no-bridge]
                             Create a project, with the bridge in it
  bridge install [--force] | bridge status
  doctor                     Check the installation

Global options:
  --format <human|json>      Output format (env: ${FORMAT_ENV_VAR}); --json is shorthand
  --project <path>           Project folder (env: GDCLI_PROJECT); default: nearest project.godot
  --godot <path>             Godot editor binary (env: GODOT_BIN)
  --instance <id>            Pick an editor when several have the project open
  --timeout <seconds>        How long to wait for the editor, or for check/exec/test/import/export
                             (gd run uses its own --seconds)
  --yes                      Confirm overwriting or destructive actions
  --dry-run                  Report what would change without doing it
  -V, --version              Print the version and protocol number
  -h, --help                 Show this help

With --format json every command prints one envelope on stdout, on failure
too: {success, command, data, errors[{code, message, hint, details}], warnings, meta}.
Exit codes: 0 ok, 1 internal, 2 usage, 3 auth, 4 precondition, 5 retry later, 6 command failed.
`;

export function readCliVersion(): string {
  const raw = readFileSync(new URL("../package.json", import.meta.url), "utf8");
  const manifest: unknown = JSON.parse(raw);
  if (typeof manifest === "object" && manifest !== null && "version" in manifest) {
    const { version } = manifest;
    if (typeof version === "string") {
      return version;
    }
  }
  throw new Error("cli/package.json has no version field");
}

const VALUE_OPTIONS = ["--format", "--project", "--godot", "--instance", "--timeout"] as const;
type ValueOption = (typeof VALUE_OPTIONS)[number];

interface Split {
  readonly values: Partial<Record<ValueOption, string>>;
  readonly flags: ReadonlySet<string>;
  /** The command name and its own arguments, in order. */
  readonly rest: readonly string[];
  readonly error?: string;
}

function isValueOption(name: string): name is ValueOption {
  return (VALUE_OPTIONS as readonly string[]).includes(name);
}

const FLAG_ALIASES: Readonly<Record<string, string>> = {
  "--json": "json",
  "--yes": "yes",
  "-y": "yes",
  "--dry-run": "dry-run",
  "--help": "help",
  "-h": "help",
  "--version": "version",
  "-V": "version",
};

/**
 * Pulls the global options out of the command line wherever they appear and
 * leaves the rest for the command. Everything after a literal "--" is left
 * alone, so arguments meant for a script can look like options.
 */
export function splitGlobals(argv: readonly string[]): Split {
  const values: Partial<Record<ValueOption, string>> = {};
  const flags = new Set<string>();
  const rest: string[] = [];
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] ?? "";
    if (token === "--") {
      rest.push(...argv.slice(index));
      break;
    }
    const equals = token.indexOf("=");
    const name = equals === -1 ? token : token.slice(0, equals);
    if (isValueOption(name)) {
      const value = equals === -1 ? argv[index + 1] : token.slice(equals + 1);
      // "--timeout --json" is a missing value, not a timeout called "--json".
      if (value === undefined || (equals === -1 && value.startsWith("--"))) {
        return { values, flags, rest, error: `${name} needs a value.` };
      }
      values[name] = value;
      index += equals === -1 ? 1 : 0;
      continue;
    }
    // hasOwn: a token such as "constructor" must not match an inherited key.
    const flag = Object.hasOwn(FLAG_ALIASES, token) ? FLAG_ALIASES[token] : undefined;
    if (flag !== undefined) {
      flags.add(flag);
      continue;
    }
    rest.push(token);
  }
  return { values, flags, rest };
}

function isOutputFormat(value: string): value is OutputFormat {
  return (OUTPUT_FORMATS as readonly string[]).includes(value);
}

/** --format wins over --json, which wins over the environment variable. */
function resolveFormat(split: Split, io: Io): OutputFormat | Error {
  const requested = split.values["--format"] ?? (split.flags.has("json") ? "json" : nonEmpty(io.env[FORMAT_ENV_VAR])) ?? "human";
  return isOutputFormat(requested)
    ? requested
    : new Error(`Unknown output format "${requested}". Use one of: ${OUTPUT_FORMATS.join(", ")}.`);
}

/** Used when the requested format itself is unusable or dispatch threw. */
function fallbackFormat(split: Split, io: Io): OutputFormat {
  const candidates = [split.values["--format"], split.flags.has("json") ? "json" : undefined, nonEmpty(io.env[FORMAT_ENV_VAR])];
  return candidates.find((candidate): candidate is OutputFormat => candidate !== undefined && isOutputFormat(candidate)) ?? "human";
}

function resolveTimeout(raw: string | undefined): number | undefined | Error {
  if (raw === undefined) {
    return undefined;
  }
  const seconds = /^\d+(\.\d+)?$/u.test(raw) ? Number(raw) : Number.NaN;
  return Number.isNaN(seconds) || seconds <= 0 || seconds > MAX_TIMEOUT_SECONDS
    ? new Error(`--timeout must be a number of seconds between 0 and ${MAX_TIMEOUT_SECONDS}.`)
    : // A tiny value still means "wait a little", not "do not wait at all".
      Math.max(1, Math.round(seconds * MS_PER_SECOND));
}

function emit(result: CommandResult, format: OutputFormat, io: Io): ExitCode {
  const { envelope } = result;
  // Computed before anything is written: if the envelope is malformed this
  // throws, and the caller then prints the only envelope of this run.
  const exitCode = exitCodeOf(envelope);
  if (result.printed === true) {
    return exitCode;
  }
  if (format === "json") {
    io.stdout(`${JSON.stringify(sanitizeEnvelope(envelope), null, JSON_INDENT)}\n`);
    return exitCode;
  }
  if (result.human !== "") {
    io.stdout(sanitize(result.human));
  }
  for (const warning of envelope.warnings) {
    io.stderr(`warning: ${sanitize(warning)}\n`);
  }
  if (!envelope.success) {
    for (const error of envelope.errors) {
      io.stderr(`error[${sanitize(error.code)}]: ${sanitize(error.message)}\n`);
      if (error.details !== undefined) {
        io.stderr(`details: ${sanitize(JSON.stringify(error.details))}\n`);
      }
      if (error.hint !== undefined) {
        io.stderr(`hint: ${sanitize(error.hint)}\n`);
      }
    }
  }
  return exitCodeOf(envelope);
}

function usageFailure(command: string, message: string): CommandResult {
  return { envelope: failure(command, [errorOf("USAGE", message, "Run `gd --help` for usage.")]), human: "" };
}

function globalsOf(split: Split, format: OutputFormat, timeoutMs: number | undefined): GlobalOptions {
  const project = split.values["--project"];
  const godot = split.values["--godot"];
  const instance = split.values["--instance"];
  return {
    format,
    yes: split.flags.has("yes"),
    dryRun: split.flags.has("dry-run"),
    ...(project === undefined ? {} : { project }),
    ...(godot === undefined ? {} : { godot }),
    ...(instance === undefined ? {} : { instance }),
    ...(timeoutMs === undefined ? {} : { timeoutMs }),
  };
}

async function dispatch(split: Split, context: Context): Promise<{ result: CommandResult; format: OutputFormat }> {
  const format = resolveFormat(split, context.io);
  const safeFormat = format instanceof Error ? fallbackFormat(split, context.io) : format;
  if (split.error !== undefined) {
    return { result: usageFailure("gd", split.error), format: safeFormat };
  }
  if (format instanceof Error) {
    return { result: usageFailure("gd", format.message), format: safeFormat };
  }
  const timeoutMs = resolveTimeout(split.values["--timeout"]);
  if (timeoutMs instanceof Error) {
    return { result: usageFailure("gd", timeoutMs.message), format };
  }

  if (split.flags.has("version")) {
    const version = context.readVersion();
    const envelope: Envelope = success("version", { version, protocol: PROTOCOL_VERSION });
    return { result: { envelope, human: `gd ${version} (protocol ${PROTOCOL_VERSION})\n` }, format };
  }
  const [name, ...args] = split.rest;
  if (split.flags.has("help") || name === undefined) {
    return { result: { envelope: success("help", { usage: USAGE }), human: USAGE }, format };
  }
  const handler = Object.hasOwn(COMMANDS, name) ? COMMANDS[name] : undefined;
  if (handler === undefined) {
    const unknown = errorOf("UNKNOWN_COMMAND", `Unknown command "${sanitize(name)}".`, "Run `gd --help` for usage.");
    return { result: { envelope: failure(name, [unknown]), human: "" }, format };
  }
  return { result: await handler(context, globalsOf(split, format, timeoutMs), args), format };
}

export async function run(argv: readonly string[], context: Context): Promise<ExitCode> {
  const split = splitGlobals(argv);
  try {
    const { result, format } = await dispatch(split, context);
    return emit(result, format, context.io);
  } catch (error: unknown) {
    // The reason may contain paths; the message stays fixed text.
    const internal = errorOf("INTERNAL_ERROR", "gd hit an unexpected error.", "Please report it.", { reason: messageOf(error) });
    const envelope = failure("gd", [internal]);
    return emit({ envelope, human: "" }, fallbackFormat(split, context.io), context.io);
  }
}
