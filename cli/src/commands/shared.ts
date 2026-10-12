import { parseArgs, type ParseArgsConfig } from "node:util";

import type { CommandResult } from "../context.js";
import { type Envelope, type EnvelopeError, errorOf, failure } from "../envelope.js";
import { messageOf, sanitize } from "../text.js";

const JSON_INDENT = 2;

export function fail(command: string, error: EnvelopeError): CommandResult {
  return { envelope: failure(command, [error]), human: "" };
}

export function usage(command: string, message: string): CommandResult {
  return fail(command, errorOf("USAGE", message, `Run \`gd ${command} --help\` for usage.`));
}

/** Pretty JSON of the data, for commands without a dedicated text layout. */
export function dataAsText(envelope: Envelope): string {
  return `${sanitize(JSON.stringify(envelope.data, null, JSON_INDENT))}\n`;
}

type Options = NonNullable<ParseArgsConfig["options"]>;

export interface ParsedCommandArgs {
  readonly values: Readonly<Record<string, string | boolean | undefined>>;
  readonly positionals: readonly string[];
  /** Everything after a literal "--", passed through untouched. */
  readonly passthrough: readonly string[];
}

/** Strict parsing of one command's own options. Returns a message on bad input. */
export function parseCommandArgs(args: readonly string[], options: Options): ParsedCommandArgs | string {
  const separator = args.indexOf("--");
  const own = separator === -1 ? args : args.slice(0, separator);
  const passthrough = separator === -1 ? [] : args.slice(separator + 1);
  try {
    const { values, positionals } = parseArgs({ args: [...own], options, allowPositionals: true, strict: true });
    return { values: values as Record<string, string | boolean | undefined>, positionals, passthrough };
  } catch (error: unknown) {
    return messageOf(error);
  }
}

/** Parses "--seconds 5" style numbers; undefined when absent, an error text when malformed. */
export function numberOption(value: string | boolean | undefined, name: string, min: number, max: number): number | undefined | string {
  if (value === undefined) {
    return undefined;
  }
  const parsed = typeof value === "string" && /^\d+(\.\d+)?$/u.test(value) ? Number(value) : Number.NaN;
  if (Number.isNaN(parsed) || parsed < min || parsed > max) {
    return `--${name} must be a number between ${min} and ${max}.`;
  }
  return parsed;
}
