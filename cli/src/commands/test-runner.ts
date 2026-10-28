import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

import type { CommandHandler, CommandResult } from "../context.js";
import { errorOf, failureWithData, isEnvelopeError, success } from "../envelope.js";
import { projectHasBeenImported, requireGodot, runGodot } from "../godot.js";
import { type TestCase, parseJUnit } from "../junit.js";
import { countBySeverity, parseGodotOutput } from "../output-parser.js";
import { findProject, toResPath } from "../project.js";
import { messageOf, sanitize } from "../text.js";
import { fail, parseCommandArgs, usage } from "./shared.js";

const TEST_TIMEOUT_MS = 600_000;
const MAX_LISTED_FAILURES = 50;
const OUTPUT_TAIL_CHARS = 4000;
const DEFAULT_FOLDERS = ["test", "tests"] as const;
const RES = "res://";

export type Framework = "gut" | "gdunit4";

/** The script each framework is started with, relative to the project. */
const ENTRY: Readonly<Record<Framework, string>> = {
  gut: "addons/gut/gut_cmdln.gd",
  gdunit4: "addons/gdUnit4/bin/GdUnitCmdTool.gd",
};
const GUT_CONFIG = ".gutconfig.json";
const GDUNIT_REPORT = "results.xml";
// GUT reads "-gdir=a,b": the value ends at a second "=" and splits at commas.
const GUT_VALUE_BREAKERS = /[=,]/u;

/** The test frameworks installed in a project. */
export function installedFrameworks(project: string): readonly Framework[] {
  return (Object.keys(ENTRY) as Framework[]).filter((framework) => existsSync(join(project, ENTRY[framework])));
}

interface Targets {
  readonly folders: readonly string[];
  readonly files: readonly string[];
}

/** What to run, as res:// paths: the ones given, else test/ or tests/. */
function targetsOf(project: string, cwd: string, given: readonly string[], framework: Framework): Targets | string {
  const folders: string[] = [];
  const files: string[] = [];
  const paths = given.length > 0 ? given : DEFAULT_FOLDERS.filter((folder) => existsSync(join(project, folder))).map((folder) => `${RES}${folder}`);
  for (const path of paths) {
    const resolved = toResPath(project, cwd, path, "file or folder");
    if (isEnvelopeError(resolved)) {
      return resolved.message;
    }
    if (framework === "gut" && GUT_VALUE_BREAKERS.test(resolved)) {
      return `GUT cannot be given a path with "=" or ",": ${resolved}. Rename it, or run its folder.`;
    }
    const onDisk = join(project, resolved.slice(RES.length));
    (statSync(onDisk).isDirectory() ? folders : files).push(resolved.replace(/\/$/u, ""));
  }
  return { folders, files };
}

function gutArgs(targets: Targets, select: string | undefined, report: string, useConfig: boolean): string[] {
  return [
    "--headless", "--script", `${RES}${ENTRY.gut}`, "-gexit", `-gjunit_xml_file=${report}`,
    ...(targets.folders.length > 0 ? [`-gdir=${targets.folders.join(",")}`, "-ginclude_subdirs"] : []),
    ...(targets.files.length > 0 ? [`-gtest=${targets.files.join(",")}`] : []),
    ...(select === undefined ? [] : [`-gunit_test_name=${select}`]),
    // The project's .gutconfig.json is read only when no paths were given: it can
    // name tests and filters of its own, which would run besides the ones asked for.
    ...(useConfig ? [] : ["-gconfig="]),
  ];
}

function gdunitArgs(targets: Targets, reportFolder: string): string[] {
  return [
    "--headless", "--script", `${RES}${ENTRY.gdunit4}`, "--ignoreHeadlessMode", "-c", "-rd", reportFolder, "-rc", "1",
    ...[...targets.folders, ...targets.files].flatMap((target) => ["-a", target]),
  ];
}

/** The newest results.xml under the folder gdUnit4 wrote its reports to. */
function findGdunitReport(folder: string): string | undefined {
  if (!existsSync(folder)) {
    return undefined;
  }
  const found: string[] = [];
  const walk = (current: string): void => {
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      const path = join(current, entry.name);
      if (entry.isDirectory()) {
        walk(path);
      } else if (entry.name === GDUNIT_REPORT) {
        found.push(path);
      }
    }
  };
  walk(folder);
  return found.sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)[0];
}

function failureLine(entry: TestCase): string {
  const message = entry.message === "" ? "" : `: ${entry.message.split("\n")[0] ?? ""}`;
  return sanitize(`FAIL ${entry.suite} > ${entry.name}${message}`);
}

function tail(output: string): string {
  const cleaned = sanitize(output).trim();
  return cleaned.length > OUTPUT_TAIL_CHARS ? cleaned.slice(cleaned.length - OUTPUT_TAIL_CHARS) : cleaned;
}

/**
 * `gd test [paths...] [--framework gut|gdunit4] [--select <text>] [--junit <file>]`:
 * runs the project's GUT or gdUnit4 tests headless and reports each failure.
 * The verdict comes from the JUnit report the framework writes, not from the
 * exit status, which differs between the two.
 */
export const testCommand: CommandHandler = async (context, globals, args) => {
  const parsed = parseCommandArgs(args, { framework: { type: "string" }, select: { type: "string" }, junit: { type: "string" } });
  if (typeof parsed === "string") {
    return usage("test", parsed);
  }
  const framework = parsed.values["framework"];
  if (framework !== undefined && framework !== "gut" && framework !== "gdunit4") {
    return usage("test", "--framework is gut or gdunit4.");
  }
  const select = typeof parsed.values["select"] === "string" ? parsed.values["select"] : undefined;
  const junit = typeof parsed.values["junit"] === "string" ? parsed.values["junit"] : undefined;
  const project = findProject(context, globals);
  if (isEnvelopeError(project)) {
    return fail("test", project);
  }

  const installed = installedFrameworks(project);
  const chosen = (framework as Framework | undefined) ?? (installed.length === 1 ? installed[0] : undefined);
  if (chosen === undefined || !installed.includes(chosen)) {
    const hint =
      installed.length > 1
        ? "Both GUT and gdUnit4 are installed: pick one with --framework."
        : "Install GUT (addons/gut) or gdUnit4 (addons/gdUnit4) from the Asset Library first; gd runs their tests, it does not install them.";
    return fail("test", errorOf("PRECONDITION_FAILED", chosen === undefined ? "No test framework to run." : `${chosen} is not installed in this project.`, hint, { installed }));
  }
  if (select !== undefined && chosen === "gdunit4") {
    return usage("test", "--select works with GUT; for gdUnit4 name the test suite's file instead.");
  }
  if (select !== undefined && (select === "" || GUT_VALUE_BREAKERS.test(select))) {
    return usage("test", '--select cannot be empty or contain "=" or ",".');
  }
  // GUT's own settings file decides what runs when no paths are given.
  const useGutConfig = chosen === "gut" && parsed.positionals.length === 0 && existsSync(join(project, GUT_CONFIG));
  const targets = useGutConfig ? { folders: [], files: [] } : targetsOf(project, context.cwd, parsed.positionals, chosen);
  if (typeof targets === "string") {
    return usage("test", targets);
  }
  if (!useGutConfig && targets.folders.length + targets.files.length === 0) {
    return fail("test", errorOf("PRECONDITION_FAILED", "There is no test/ or tests/ folder.", "Name the folders or files with the tests: gd test res://spec"));
  }

  const godot = await requireGodot(context, globals);
  if (isEnvelopeError(godot)) {
    return fail("test", godot);
  }
  if (globals.dryRun) {
    const placeholder = join(tmpdir(), "gdcli-test-XXXXXX");
    const planned = chosen === "gut" ? gutArgs(targets, select, join(placeholder, "junit.xml"), useGutConfig) : gdunitArgs(targets, placeholder);
    const data = { dry_run: true, framework: chosen, godot: godot.bin, args: ["--path", project, ...planned] };
    return { envelope: success("test", data), human: `would run: ${[data.godot, ...data.args].join(" ")}\n` };
  }
  const reportFolder = mkdtempSync(join(tmpdir(), "gdcli-test-"));
  const gutReport = join(reportFolder, "junit.xml");
  const godotArgs = chosen === "gut" ? gutArgs(targets, select, gutReport, useGutConfig) : gdunitArgs(targets, reportFolder);
  try {
    const { result, output } = await runGodot(context, godot, project, godotArgs, globals.timeoutMs ?? TEST_TIMEOUT_MS);
    if (result.spawnError !== undefined) {
      return fail("test", errorOf("GODOT_NOT_FOUND", "Godot could not be started.", undefined, { reason: result.spawnError }));
    }
    const reportFile = chosen === "gut" ? (existsSync(gutReport) ? gutReport : undefined) : findGdunitReport(reportFolder);
    return verdict({ chosen, project, junit, cwd: context.cwd, reportFile, code: result.code, timedOut: result.timedOut, output, stdout: result.stdout });
  } catch (error: unknown) {
    return fail("test", errorOf("COMMAND_FAILED", "The test report could not be read or saved.", "Check --junit names a file that can be written.", { reason: messageOf(error) }));
  } finally {
    try {
      // A game killed at the timeout may still hold the report open on Windows.
      rmSync(reportFolder, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
    } catch {
      // Left in the system's temporary folder, which is emptied in time.
    }
  }
};

interface Outcome {
  readonly chosen: Framework;
  readonly project: string;
  readonly junit: string | undefined;
  readonly cwd: string;
  readonly reportFile: string | undefined;
  readonly code: number | null;
  readonly timedOut: boolean;
  readonly output: string;
  readonly stdout: string;
}

function verdict(outcome: Outcome): CommandResult {
  const diagnostics = parseGodotOutput(outcome.output).diagnostics;
  const base = { framework: outcome.chosen, exit_code: outcome.code, timed_out: outcome.timedOut, error_count: countBySeverity(diagnostics, "error") };
  if (outcome.reportFile === undefined) {
    const data = { ...base, diagnostics, stdout: tail(outcome.stdout) };
    const hint = outcome.timedOut
      ? "Raise --timeout, or look for a test that waits forever."
      : projectHasBeenImported(outcome.project)
        ? "See data.stdout and data.diagnostics: the framework stopped before it wrote its report."
        : "The project has not been imported yet: run `gd import`, then try again.";
    return { envelope: failureWithData("test", data, [errorOf(outcome.timedOut ? "TIMEOUT" : "COMMAND_FAILED", "The tests did not produce a report.", hint)]), human: `${sanitize(outcome.stdout)}` };
  }
  const report = parseJUnit(readFileSync(outcome.reportFile, "utf8"));
  const saved = outcome.junit === undefined ? undefined : resolve(outcome.cwd, outcome.junit);
  if (saved !== undefined) {
    mkdirSync(dirname(saved), { recursive: true });
    copyFileSync(outcome.reportFile, saved);
  }
  const failures = report.cases.filter((entry) => entry.outcome === "failed");
  const data = {
    ...base,
    tests: report.tests,
    passed: report.passed,
    failed: report.failed,
    skipped: report.skipped,
    failures: failures.slice(0, MAX_LISTED_FAILURES).map((entry) => ({ suite: sanitize(entry.suite), test: sanitize(entry.name), message: sanitize(entry.message) })),
    ...(saved === undefined ? {} : { junit: saved }),
  };
  const summary = `${report.tests} tests: ${report.passed} passed, ${report.failed} failed, ${report.skipped} skipped\n`;
  const human = `${failures.map((entry) => `${failureLine(entry)}\n`).join("")}${summary}`;
  if (report.tests === 0) {
    return { envelope: failureWithData("test", data, [errorOf("PRECONDITION_FAILED", "No tests were found.", "Check the folders given, and that test files follow the framework's naming (test_*.gd for GUT, *_test.gd or extends GdUnitTestSuite for gdUnit4).")]), human };
  }
  if (report.failed > 0 || outcome.timedOut) {
    const message = outcome.timedOut ? "The tests did not finish in time." : `${report.failed} of ${report.tests} tests failed.`;
    return { envelope: failureWithData("test", data, [errorOf(outcome.timedOut ? "TIMEOUT" : "COMMAND_FAILED", message, "See data.failures.")]), human };
  }
  return { envelope: success("test", data), human };
}
