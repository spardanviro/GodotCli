import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";

import { type Envelope, exitCodeOf, failure, success } from "./envelope.js";
import { type ErrorCode, type ExitCode, PROTOCOL_VERSION } from "./protocol.js";

export interface Io {
  readonly stdout: (text: string) => void;
  readonly stderr: (text: string) => void;
  readonly env: Readonly<Record<string, string | undefined>>;
}

const OUTPUT_FORMATS = ["human", "json"] as const;
type OutputFormat = (typeof OUTPUT_FORMATS)[number];

const FORMAT_ENV_VAR = "GDCLI_FORMAT";
const JSON_INDENT = 2;

const USAGE = `Usage: gd [options] <command>

Options:
  --format <human|json>  Output format (env: ${FORMAT_ENV_VAR})
  --json                 Shorthand for --format json
  -V, --version          Print the version and protocol number
  -h, --help             Show this help

No commands are implemented yet. See docs/roadmap.md.
`;

interface ParsedArgs {
  readonly help: boolean;
  readonly version: boolean;
  readonly json: boolean;
  readonly format: string | undefined;
  readonly positionals: readonly string[];
}

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

/** Replaceable in tests so the failure paths can be exercised. */
export interface Deps {
  readonly readVersion: () => string;
}

const DEFAULT_DEPS: Deps = { readVersion: readCliVersion };

function parse(argv: readonly string[]): ParsedArgs {
  const { values, positionals } = parseArgs({
    args: [...argv],
    allowPositionals: true,
    options: {
      help: { type: "boolean", short: "h", default: false },
      version: { type: "boolean", short: "V", default: false },
      json: { type: "boolean", default: false },
      format: { type: "string" },
    },
  });
  return {
    help: values.help,
    version: values.version,
    json: values.json,
    format: values.format,
    positionals,
  };
}

function isOutputFormat(value: string): value is OutputFormat {
  return (OUTPUT_FORMATS as readonly string[]).includes(value);
}

// A variable set to the empty string is how shells and CI "unset" it.
function formatFromEnv(io: Io): string | undefined {
  const value = io.env[FORMAT_ENV_VAR];
  return value === undefined || value === "" ? undefined : value;
}

// --format wins over --json, which wins over the environment variable.
function resolveFormat(args: ParsedArgs, io: Io): OutputFormat | Error {
  const requested = args.format ?? (args.json ? "json" : formatFromEnv(io)) ?? "human";
  return isOutputFormat(requested)
    ? requested
    : new Error(`Unknown output format "${requested}". Use one of: ${OUTPUT_FORMATS.join(", ")}.`);
}

function usageFailure(command: string, code: ErrorCode, message: string): Envelope {
  return failure(command, [{ code, message, hint: "Run `gd --help` for usage." }]);
}

function emit(envelope: Envelope, format: OutputFormat, humanText: string, io: Io): ExitCode {
  if (format === "json") {
    io.stdout(`${JSON.stringify(envelope, null, JSON_INDENT)}\n`);
  } else if (envelope.success) {
    io.stdout(humanText);
  } else {
    for (const error of envelope.errors) {
      io.stderr(`error[${error.code}]: ${error.message}\n`);
      if (error.hint !== undefined) {
        io.stderr(`hint: ${error.hint}\n`);
      }
    }
  }
  return exitCodeOf(envelope);
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

const FORMAT_OPTION = "--format";

// When the command line cannot be parsed or dispatch throws, the parsed options
// are unavailable, so read the format straight from argv. This keeps "failures
// also go to stdout as an envelope" true for every way of asking for JSON.
function fallbackFormat(argv: readonly string[], io: Io): OutputFormat {
  const explicit = argv.reduce<string | undefined>((found, arg, index) => {
    if (arg === FORMAT_OPTION) {
      return argv[index + 1];
    }
    return arg.startsWith(`${FORMAT_OPTION}=`) ? arg.slice(FORMAT_OPTION.length + 1) : found;
  }, undefined);
  const requested = explicit ?? (argv.includes("--json") ? "json" : formatFromEnv(io));
  return requested !== undefined && isOutputFormat(requested) ? requested : "human";
}

function dispatch(argv: readonly string[], io: Io, deps: Deps): ExitCode {
  let args: ParsedArgs;
  try {
    args = parse(argv);
  } catch (error: unknown) {
    const envelope = usageFailure("gd", "USAGE", messageOf(error));
    return emit(envelope, fallbackFormat(argv, io), "", io);
  }

  const format = resolveFormat(args, io);
  if (format instanceof Error) {
    return emit(usageFailure("gd", "USAGE", format.message), fallbackFormat(argv, io), "", io);
  }

  if (args.version) {
    const version = deps.readVersion();
    const envelope = success("version", { version, protocol: PROTOCOL_VERSION });
    return emit(envelope, format, `gd ${version} (protocol ${PROTOCOL_VERSION})\n`, io);
  }

  const command = args.positionals[0];
  if (args.help || command === undefined) {
    return emit(success("help", { usage: USAGE }), format, USAGE, io);
  }

  const unknown = usageFailure(command, "UNKNOWN_COMMAND", `Unknown command "${command}".`);
  return emit(unknown, format, "", io);
}

export function run(argv: readonly string[], io: Io, deps: Deps = DEFAULT_DEPS): ExitCode {
  try {
    return dispatch(argv, io, deps);
  } catch (error: unknown) {
    const envelope = failure("gd", [{ code: "INTERNAL_ERROR", message: messageOf(error) }]);
    return emit(envelope, fallbackFormat(argv, io), "", io);
  }
}
