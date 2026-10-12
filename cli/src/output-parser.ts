import { sanitize } from "./text.js";

export type Severity = "error" | "warning";

/** One error or warning the engine printed. All text comes from the project: treat it as data. */
export interface Diagnostic {
  readonly severity: Severity;
  /** The engine's label, e.g. "SCRIPT ERROR". */
  readonly kind: string;
  readonly message: string;
  readonly file?: string;
  readonly line?: number;
  readonly function?: string;
}

export interface ParsedOutput {
  readonly diagnostics: readonly Diagnostic[];
  readonly truncated: boolean;
}

const MAX_DIAGNOSTICS = 200;
const MAX_MESSAGE_LENGTH = 2000;

// "ERROR: message", "SCRIPT ERROR: message", "USER WARNING: message", ...
const HEAD_PATTERN = /^(?<kind>(?:USER )?(?:SCRIPT )?ERROR|(?:USER )?WARNING): (?<message>.*)$/u;
// "   at: function (res://file.gd:12)"
const LOCATION_PATTERN = /^\s+at: (?<function>.*?) \((?<file>.+):(?<line>\d+)\)\s*$/u;
// "       [0] _ready (res://main.gd:8)" in the backtrace Godot 4.5+ prints
const SCRIPT_FRAME_PATTERN = /^\s+\[0\] (?<function>.*?) \((?<file>res:\/\/.+):(?<line>\d+)\)\s*$/u;
const LOOKAHEAD_LINES = 4;
// GDScript parse errors carry their own location: "res://file.gd:12 - Parse Error: ..."
const INLINE_LOCATION_PATTERN = /^(?<file>res:\/\/[^:]+):(?<line>\d+) - /u;

function clip(message: string): string {
  return message.length > MAX_MESSAGE_LENGTH ? `${message.slice(0, MAX_MESSAGE_LENGTH)} ...[truncated]` : message;
}

function withLocation(diagnostic: Diagnostic, following: readonly string[]): Diagnostic {
  // An error raised inside the engine (push_error, a failed built-in call) is
  // located in C++; the first script frame is what the user can act on.
  const frame = following.map((line) => SCRIPT_FRAME_PATTERN.exec(line)).find((match) => match !== null);
  const nextLine = following[0];
  const location = nextLine === undefined ? null : LOCATION_PATTERN.exec(nextLine);
  if (frame?.groups !== undefined && !(location?.groups?.["file"] ?? "").startsWith("res://")) {
    return {
      ...diagnostic,
      file: frame.groups["file"] ?? "",
      line: Number(frame.groups["line"]),
      function: frame.groups["function"] ?? "",
    };
  }
  if (location?.groups !== undefined) {
    return {
      ...diagnostic,
      file: location.groups["file"] ?? "",
      line: Number(location.groups["line"]),
      function: location.groups["function"] ?? "",
    };
  }
  const inline = INLINE_LOCATION_PATTERN.exec(diagnostic.message);
  if (inline?.groups !== undefined) {
    return { ...diagnostic, file: inline.groups["file"] ?? "", line: Number(inline.groups["line"]) };
  }
  return diagnostic;
}

// The lines that belong to the diagnostic at `index`: up to the next one.
function followingLines(lines: readonly string[], index: number): readonly string[] {
  const window = lines.slice(index + 1, index + 1 + LOOKAHEAD_LINES);
  const nextHead = window.findIndex((line) => HEAD_PATTERN.test(line));
  return nextHead === -1 ? window : window.slice(0, nextHead);
}

function keyOf(diagnostic: Diagnostic): string {
  return `${diagnostic.kind}|${diagnostic.message}|${diagnostic.file ?? ""}|${diagnostic.line ?? ""}`;
}

/** Extracts the engine's errors and warnings from what a Godot process printed. */
export function parseGodotOutput(output: string): ParsedOutput {
  const lines = sanitize(output).split(/\r?\n/u);
  const seen = new Set<string>();
  const diagnostics: Diagnostic[] = [];
  let truncated = false;

  lines.forEach((line, index) => {
    const head = HEAD_PATTERN.exec(line);
    if (head?.groups === undefined) {
      return;
    }
    const kind = head.groups["kind"] ?? "ERROR";
    const diagnostic = withLocation(
      { severity: kind.endsWith("WARNING") ? "warning" : "error", kind, message: clip(head.groups["message"] ?? "") },
      followingLines(lines, index),
    );
    const key = keyOf(diagnostic);
    if (seen.has(key)) {
      return;
    }
    seen.add(key);
    if (diagnostics.length >= MAX_DIAGNOSTICS) {
      truncated = true;
      return;
    }
    diagnostics.push(diagnostic);
  });
  return { diagnostics, truncated };
}

export function countBySeverity(diagnostics: readonly Diagnostic[], severity: Severity): number {
  return diagnostics.filter((diagnostic) => diagnostic.severity === severity).length;
}

export function formatDiagnostic(diagnostic: Diagnostic): string {
  const where = diagnostic.file === undefined ? "" : `${diagnostic.file}:${diagnostic.line ?? 0}: `;
  return `${where}${diagnostic.severity}: ${diagnostic.message}`;
}
