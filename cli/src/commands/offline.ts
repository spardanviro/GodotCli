import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";

import type { CommandHandler, CommandResult, Context, GlobalOptions } from "../context.js";
import { type EnvelopeError, errorOf, failureWithData, isEnvelopeError, success } from "../envelope.js";
import { type Godot, preferGuiBinary, projectHasBeenImported, requireGodot, runGodot } from "../godot.js";
import { type Diagnostic, countBySeverity, formatDiagnostic, parseGodotOutput } from "../output-parser.js";
import { findProject, toResPath } from "../project.js";
import { sanitize } from "../text.js";
import { fail, numberOption, parseCommandArgs, usage } from "./shared.js";

const DEFAULT_RUN_SECONDS = 10;
const MAX_RUN_SECONDS = 600;
const CHECK_TIMEOUT_MS = 60_000;
const EXEC_TIMEOUT_MS = 120_000;
const IMPORT_TIMEOUT_MS = 600_000;
const EXPORT_TIMEOUT_MS = 1_800_000;
const OUTPUT_TAIL_CHARS = 4000;
const MS_PER_SECOND = 1000;
const EXPORT_PRESETS_FILE = "export_presets.cfg";

interface Setup {
  readonly project: string;
  readonly godot: Godot;
}

async function setup(context: Context, globals: GlobalOptions): Promise<Setup | EnvelopeError> {
  const project = findProject(context, globals);
  if (typeof project !== "string") {
    return project;
  }
  const godot = await requireGodot(context, globals);
  return isEnvelopeError(godot) ? godot : { project, godot };
}

function tail(output: string): string {
  const cleaned = sanitize(output).trim();
  return cleaned.length > OUTPUT_TAIL_CHARS ? cleaned.slice(cleaned.length - OUTPUT_TAIL_CHARS) : cleaned;
}

function diagnosticsText(diagnostics: readonly Diagnostic[]): string {
  return diagnostics.map((diagnostic) => `${sanitize(formatDiagnostic(diagnostic))}\n`).join("");
}

interface Report {
  readonly diagnostics: readonly Diagnostic[];
  readonly error_count: number;
  readonly warning_count: number;
  readonly truncated: boolean;
}

function reportOf(output: string): Report {
  const parsed = parseGodotOutput(output);
  return {
    diagnostics: parsed.diagnostics,
    error_count: countBySeverity(parsed.diagnostics, "error"),
    warning_count: countBySeverity(parsed.diagnostics, "warning"),
    truncated: parsed.truncated,
  };
}

/** --dry-run for commands that start Godot: say what would be started, start nothing. */
function plan(command: string, ready: Setup, godotArgs: readonly string[]): CommandResult {
  const data = { dry_run: true, godot: ready.godot.bin, args: ["--path", ready.project, ...godotArgs] };
  return { envelope: success(command, data), human: `would run: ${[data.godot, ...data.args].join(" ")}\n` };
}

const NOT_IMPORTED_WARNING = "This project has not been imported yet (no .godot folder); errors about missing resources may be caused by that. Run `gd import` first.";

function importWarnings(project: string): readonly string[] {
  return projectHasBeenImported(project) ? [] : [NOT_IMPORTED_WARNING];
}

function spawnFailure(command: string, reason: string): CommandResult {
  return fail(command, errorOf("GODOT_NOT_FOUND", "Godot could not be started.", undefined, { reason }));
}

/**
 * `gd run [scene] [--seconds N] [--headless]`: starts the project, lets it run
 * for a while, stops it and reports the errors it printed. The engine exits
 * with status 0 even after script errors, so the output is what counts.
 */
export const runCommand: CommandHandler = async (context, globals, args) => {
  const parsed = parseCommandArgs(args, { seconds: { type: "string" }, headless: { type: "boolean", default: false } });
  if (typeof parsed === "string") {
    return usage("run", parsed);
  }
  const seconds = numberOption(parsed.values["seconds"], "seconds", 1, MAX_RUN_SECONDS);
  if (typeof seconds === "string" || parsed.positionals.length > 1) {
    return usage("run", typeof seconds === "string" ? seconds : "Give at most one scene.");
  }
  const ready = await setup(context, globals);
  if (isEnvelopeError(ready)) {
    return fail("run", ready);
  }
  const sceneInput = parsed.positionals[0];
  const scene = sceneInput === undefined ? undefined : toResPath(ready.project, context.cwd, sceneInput);
  if (isEnvelopeError(scene)) {
    return fail("run", scene);
  }

  const godotArgs = [...(parsed.values["headless"] === true ? ["--headless"] : []), ...(scene === undefined ? [] : [scene])];
  if (globals.dryRun) {
    return plan("run", ready, godotArgs);
  }
  const warnings = importWarnings(ready.project);
  const duration = (seconds ?? DEFAULT_RUN_SECONDS) * MS_PER_SECOND;
  const { result, output } = await runGodot(context, ready.godot, ready.project, godotArgs, duration);
  if (result.spawnError !== undefined) {
    return spawnFailure("run", result.spawnError);
  }

  const report = reportOf(output);
  const data = {
    scene: scene ?? null,
    // Reaching the time limit is the normal way for a game to end here.
    stopped_after_seconds: result.timedOut ? duration / MS_PER_SECOND : null,
    exit_code: result.code,
    ...report,
    output_tail: tail(output),
  };
  const summary = `${report.error_count} error(s), ${report.warning_count} warning(s)\n`;
  const human = `${diagnosticsText(report.diagnostics)}${summary}`;
  if (report.error_count > 0) {
    const error = errorOf("COMMAND_FAILED", "The project printed errors while running.", "See data.diagnostics for file, line and message.");
    return { envelope: { ...failureWithData("run", data, [error]), warnings }, human };
  }
  return { envelope: success("run", data, {}, warnings), human };
};

/** `gd check <script>...`: parse scripts for errors without running them. */
export const checkCommand: CommandHandler = async (context, globals, args) => {
  const parsed = parseCommandArgs(args, {});
  if (typeof parsed === "string" || parsed.positionals.length === 0) {
    return usage("check", typeof parsed === "string" ? parsed : "Give at least one script.");
  }
  const ready = await setup(context, globals);
  if (isEnvelopeError(ready)) {
    return fail("check", ready);
  }
  const scripts: string[] = [];
  for (const input of parsed.positionals) {
    const script = toResPath(ready.project, context.cwd, input);
    if (isEnvelopeError(script)) {
      return fail("check", script);
    }
    scripts.push(script);
  }

  if (globals.dryRun) {
    return plan("check", ready, ["--headless", "--check-only", "--script", ...scripts.slice(0, 1)]);
  }
  const results = [];
  for (const script of scripts) {
    const godotArgs = ["--headless", "--check-only", "--script", script];
    const { result, output } = await runGodot(context, ready.godot, ready.project, godotArgs, globals.timeoutMs ?? CHECK_TIMEOUT_MS);
    if (result.spawnError !== undefined) {
      return spawnFailure("check", result.spawnError);
    }
    if (result.timedOut) {
      return fail("check", errorOf("TIMEOUT", "Checking a script did not finish in time.", "Raise --timeout.", { script }));
    }
    const report = reportOf(output);
    // A non-zero status without a parsed error still means the script did not load.
    const ok = report.error_count === 0 && result.code === 0 && !result.timedOut;
    results.push({ script, ok, ...report, ...(ok || report.error_count > 0 ? {} : { output_tail: tail(output) }) });
  }

  const failed = results.filter((entry) => !entry.ok);
  const data = { scripts: results, failed: failed.length };
  const human = results
    .map((entry) => `${entry.ok ? "ok  " : "FAIL"} ${sanitize(entry.script)}\n${diagnosticsText(entry.diagnostics)}`)
    .join("");
  if (failed.length > 0) {
    const error = errorOf("COMMAND_FAILED", "One or more scripts have errors.", "See data.scripts[].diagnostics.");
    return { envelope: failureWithData("check", data, [error]), human };
  }
  return { envelope: success("check", data), human };
};

// "extends SceneTree", "class_name Tool extends MainLoop", or a script that
// extends another script by path, which only Godot can judge.
const MAIN_LOOP_PATTERN = /^\s*(?:class_name\s+\w+\s+)?extends\s+(?:SceneTree\b|MainLoop\b|["'])/mu;

/** `gd exec <script> [-- args]`: run a SceneTree or MainLoop script headless. */
export const execCommand: CommandHandler = async (context, globals, args) => {
  const parsed = parseCommandArgs(args, {});
  if (typeof parsed === "string" || parsed.positionals.length !== 1) {
    return usage("exec", typeof parsed === "string" ? parsed : "Give exactly one script.");
  }
  const ready = await setup(context, globals);
  if (isEnvelopeError(ready)) {
    return fail("exec", ready);
  }
  const script = toResPath(ready.project, context.cwd, parsed.positionals[0] ?? "");
  if (isEnvelopeError(script)) {
    return fail("exec", script);
  }
  const source = readFileSync(join(ready.project, script.slice("res://".length)), "utf8");
  if (!MAIN_LOOP_PATTERN.test(source)) {
    return fail(
      "exec",
      errorOf("PRECONDITION_FAILED", "The script must extend SceneTree or MainLoop.", "Godot only runs such scripts with --script.", { script }),
    );
  }

  // User arguments go after a literal "--", where the engine does not interpret them.
  const userArgs = parsed.passthrough.length === 0 ? [] : ["--", ...parsed.passthrough];
  if (globals.dryRun) {
    return plan("exec", ready, ["--headless", "--script", script, ...userArgs]);
  }
  const timeoutMs = globals.timeoutMs ?? EXEC_TIMEOUT_MS;
  const { result, output } = await runGodot(context, ready.godot, ready.project, ["--headless", "--script", script, ...userArgs], timeoutMs);
  if (result.spawnError !== undefined) {
    return spawnFailure("exec", result.spawnError);
  }
  const report = reportOf(output);
  const data = { script, exit_code: result.code, timed_out: result.timedOut, ...report, stdout: tail(result.stdout) };
  const human = `${sanitize(result.stdout)}${diagnosticsText(report.diagnostics)}`;
  if (result.timedOut) {
    return { envelope: failureWithData("exec", data, [errorOf("TIMEOUT", "The script did not finish in time.", "Raise --timeout, or make sure it calls quit().")]), human };
  }
  if (report.error_count > 0 || result.code !== 0) {
    return { envelope: failureWithData("exec", data, [errorOf("COMMAND_FAILED", "The script failed.", "See data.diagnostics and data.stdout.")]), human };
  }
  return { envelope: success("exec", data), human };
};

/** `gd import`: (re)import the project's resources without opening a window. */
export const importCommand: CommandHandler = async (context, globals, args) => {
  const parsed = parseCommandArgs(args, {});
  if (typeof parsed === "string" || parsed.positionals.length > 0) {
    return usage("import", typeof parsed === "string" ? parsed : "import takes no arguments.");
  }
  const ready = await setup(context, globals);
  if (isEnvelopeError(ready)) {
    return fail("import", ready);
  }
  if (globals.dryRun) {
    return plan("import", ready, ["--headless", "--import"]);
  }
  const timeoutMs = globals.timeoutMs ?? IMPORT_TIMEOUT_MS;
  const { result, output } = await runGodot(context, ready.godot, ready.project, ["--headless", "--import"], timeoutMs);
  if (result.spawnError !== undefined) {
    return spawnFailure("import", result.spawnError);
  }
  const report = reportOf(output);
  const data = { exit_code: result.code, ...report };
  const human = `${diagnosticsText(report.diagnostics)}import finished\n`;
  if (result.timedOut) {
    return { envelope: failureWithData("import", data, [errorOf("TIMEOUT", "The import did not finish in time.", "Raise --timeout.")]), human };
  }
  if (result.code !== 0) {
    return { envelope: failureWithData("import", data, [errorOf("COMMAND_FAILED", "The import failed.", "See data.diagnostics.")]), human };
  }
  return { envelope: success("import", data), human };
};

export function readPresetNames(project: string): readonly string[] {
  try {
    const text = readFileSync(join(project, EXPORT_PRESETS_FILE), "utf8");
    return [...text.matchAll(/^name="((?:[^"\\]|\\.)*)"\s*$/gmu)].map((match) => (match[1] ?? "").replace(/\\(.)/gu, "$1"));
  } catch {
    return [];
  }
}

/** `gd export <preset> <output> [--debug | --pack]`. */
export const exportCommand: CommandHandler = async (context, globals, args) => {
  const parsed = parseCommandArgs(args, { debug: { type: "boolean", default: false }, pack: { type: "boolean", default: false } });
  if (typeof parsed === "string" || parsed.positionals.length !== 2) {
    return usage("export", typeof parsed === "string" ? parsed : "Usage: gd export <preset> <output> [--debug | --pack]");
  }
  if (parsed.values["debug"] === true && parsed.values["pack"] === true) {
    return usage("export", "--debug and --pack cannot be combined.");
  }
  const ready = await setup(context, globals);
  if (isEnvelopeError(ready)) {
    return fail("export", ready);
  }
  const [preset = "", outputInput = ""] = parsed.positionals;
  const presets = readPresetNames(ready.project);
  // The name is matched against the project's own list, so it can never be an option.
  if (!presets.includes(preset)) {
    return fail(
      "export",
      errorOf("RESOURCE_NOT_FOUND", "No export preset with that name.", `Presets are defined in ${EXPORT_PRESETS_FILE} (Project > Export).`, {
        preset,
        available: presets,
      }),
    );
  }
  // Godot resolves a relative output against the project; make it explicit.
  const output = resolve(context.cwd, outputInput);
  if (existsSync(output) && !globals.yes) {
    return fail("export", errorOf("CONFIRMATION_REQUIRED", "The output file already exists.", "Pass --yes to overwrite it.", { output }));
  }
  // Writing elsewhere on the disk is allowed, but never by accident.
  const insideProject = relative(ready.project, output);
  if ((insideProject.startsWith("..") || isAbsolute(insideProject)) && !globals.yes) {
    return fail(
      "export",
      errorOf("CONFIRMATION_REQUIRED", "The output is outside the project folder.", "Pass --yes to write there.", { output }),
    );
  }
  if (globals.dryRun) {
    const text = sanitize(`would export "${preset}" to ${output}\n`);
    return { envelope: success("export", { preset, output, dry_run: true }), human: text };
  }
  mkdirSync(dirname(output), { recursive: true });

  const mode = parsed.values["pack"] === true ? "--export-pack" : parsed.values["debug"] === true ? "--export-debug" : "--export-release";
  const timeoutMs = globals.timeoutMs ?? EXPORT_TIMEOUT_MS;
  const run = await runGodot(context, ready.godot, ready.project, ["--headless", mode, preset, output], timeoutMs);
  if (run.result.spawnError !== undefined) {
    return spawnFailure("export", run.result.spawnError);
  }
  const report = reportOf(run.output);
  const data = { preset, output, exit_code: run.result.code, ...report };
  const human = `${diagnosticsText(report.diagnostics)}`;
  if (run.result.timedOut) {
    return { envelope: failureWithData("export", data, [errorOf("TIMEOUT", "The export did not finish in time.", "Raise --timeout.")]), human };
  }
  if (run.result.code !== 0 || !existsSync(output)) {
    const error = errorOf("COMMAND_FAILED", "The export failed.", "See data.diagnostics; export templates must be installed.");
    return { envelope: failureWithData("export", data, [error]), human };
  }
  return { envelope: success("export", data), human: `${human}exported to ${sanitize(output)}\n` };
};

/** `gd open [scene]`: start the editor on the project and return immediately. */
export const openCommand: CommandHandler = async (context, globals, args) => {
  const parsed = parseCommandArgs(args, {});
  if (typeof parsed === "string" || parsed.positionals.length > 1) {
    return usage("open", typeof parsed === "string" ? parsed : "Give at most one scene.");
  }
  const ready = await setup(context, globals);
  if (isEnvelopeError(ready)) {
    return fail("open", ready);
  }
  const sceneInput = parsed.positionals[0];
  const scene = sceneInput === undefined ? undefined : toResPath(ready.project, context.cwd, sceneInput);
  if (isEnvelopeError(scene)) {
    return fail("open", scene);
  }
  const editorArgs = ["--editor", "--path", ready.project, ...(scene === undefined ? [] : [scene])];
  if (globals.dryRun) {
    return plan("open", ready, editorArgs.slice(2));
  }
  const pid = context.processes.startDetached(preferGuiBinary(ready.godot.bin, context.platform), editorArgs, ready.project);
  if (pid === undefined) {
    return spawnFailure("open", "the process did not start");
  }
  const data = { pid, project: ready.project, scene: scene ?? null };
  return { envelope: success("open", data), human: "editor starting; `gd status` shows when it is ready\n" };
};
