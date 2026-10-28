import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, test } from "vitest";

import { parseJUnit } from "../src/junit.js";
import { ExitCode } from "../src/protocol.js";
import { type Call, type FakeProcesses, fakeProcesses, harness, makeProject, tempDir, writeFile } from "./helpers.js";

const GUT_ENTRY = "res://addons/gut/gut_cmdln.gd";
const GDUNIT_ENTRY = "res://addons/gdUnit4/bin/GdUnitCmdTool.gd";

const ONE_FAILURE = `<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="GutTests" failures="1" tests="3">
  <testsuite name="res://test/test_player.gd" tests="3" failures="1" skipped="1">
    <testcase name="test_jumps" assertions="1" classname="res://test/test_player.gd" time="0.01"></testcase>
    <testcase name="test_lands" assertions="1" classname="res://test/test_player.gd" time="0.01">
      <failure message="failed">[Failed]:  [1] expected to equal [2] &lt;at line 12&gt;</failure>
    </testcase>
    <testcase name="test_later" classname="res://test/test_player.gd"><skipped message="pending"/></testcase>
  </testsuite>
</testsuites>
`;
const ALL_PASS = `<testsuites><testsuite name="res://test/test_player.gd"><testcase name="test_jumps"/><testcase name="test_lands"/></testsuite></testsuites>`;

interface Fixture {
  readonly project: string;
  readonly processes: FakeProcesses;
  readonly gd: ReturnType<typeof harness>;
}

/** A project with the given frameworks and a test/ folder; `report` is what the framework writes. */
function fixture(frameworks: readonly ("gut" | "gdunit4")[], report: string | undefined, result: { code?: number; stdout?: string; timedOut?: boolean } = {}): Fixture {
  const home = tempDir();
  const project = makeProject(home);
  mkdirSync(join(project, ".godot"), { recursive: true });
  writeFile(join(project, "test", "test_player.gd"), "extends GutTest\n");
  if (frameworks.includes("gut")) {
    writeFile(join(project, "addons", "gut", "gut_cmdln.gd"), "extends SceneTree\n");
  }
  if (frameworks.includes("gdunit4")) {
    writeFile(join(project, "addons", "gdUnit4", "bin", "GdUnitCmdTool.gd"), "extends SceneTree\n");
  }
  const godot = writeFile(join(home, "bin", "godot-bin"), "");
  const processes = fakeProcesses((call) => {
    if (report !== undefined) {
      writeReport(call, report);
    }
    return { code: result.code ?? 0, stdout: result.stdout ?? "", timedOut: result.timedOut ?? false };
  });
  return { project, processes, gd: harness({ homeDir: home, cwd: project, processes, env: { GODOT_BIN: godot } }) };
}

/** Where each framework is told to put its report. */
function writeReport(call: Call, report: string): void {
  const gut = call.args.find((arg) => arg.startsWith("-gjunit_xml_file="));
  if (gut !== undefined) {
    writeFileSync(gut.slice("-gjunit_xml_file=".length), report);
    return;
  }
  const folder = call.args[call.args.indexOf("-rd") + 1];
  if (folder !== undefined) {
    mkdirSync(join(folder, "report_1"), { recursive: true });
    writeFileSync(join(folder, "report_1", "results.xml"), report);
  }
}

function lastArgs(processes: FakeProcesses): readonly string[] {
  return processes.calls.at(-1)?.args ?? [];
}

describe("parseJUnit", () => {
  test("counts each outcome and keeps why a test failed", () => {
    const report = parseJUnit(ONE_FAILURE);

    expect([report.tests, report.passed, report.failed, report.skipped]).toEqual([3, 1, 1, 1]);
    expect(report.cases[1]).toMatchObject({ suite: "res://test/test_player.gd", name: "test_lands", outcome: "failed" });
    expect(report.cases[1]?.message).toContain("expected to equal [2] <at line 12>");
  });

  test("reads errors, CDATA and the suite of a case without a classname", () => {
    const report = parseJUnit(`<testsuites><testsuite name="PlayerTest" tests="1"><testcase name="test_a"><error message="crash" type="ERROR"><![CDATA[at line 3 & more]]></error></testcase></testsuite></testsuites>`);

    expect(report.cases).toEqual([{ suite: "PlayerTest", name: "test_a", outcome: "failed", message: "crash\nat line 3 & more" }]);
  });

  test("leaves CDATA as written and survives a character reference out of range", () => {
    const report = parseJUnit(`<testsuite name="S"><testcase name="t"><failure message="bad &#xFFFFFFFF;"><![CDATA[a &lt; b]]></failure></testcase></testsuite>`);

    expect(report.cases[0]?.message).toBe("bad &#xFFFFFFFF;\na &lt; b");
  });
});

describe("gd test", () => {
  test("runs GUT on test/ and reports the failed test", async () => {
    const { gd, processes } = fixture(["gut"], ONE_FAILURE);

    const { exitCode, envelope } = await gd.json("test");

    const args = lastArgs(processes);
    expect(args).toEqual(expect.arrayContaining(["--headless", "--script", GUT_ENTRY, "-gexit", "-gdir=res://test", "-ginclude_subdirs", "-gconfig="]));
    expect(exitCode).toBe(ExitCode.CommandFailed);
    expect(envelope.errors[0]?.message).toBe("1 of 3 tests failed.");
    expect(envelope.data).toMatchObject({ framework: "gut", tests: 3, passed: 1, failed: 1, skipped: 1, failures: [{ test: "test_lands" }] });
  });

  test("passes when every test passes, and keeps the report where asked", async () => {
    const { gd, project } = fixture(["gut"], ALL_PASS);

    const { exitCode, envelope } = await gd.json("test", "test/test_player.gd", "--select", "jump", "--junit", "out/report.xml");

    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.data).toMatchObject({ tests: 2, failed: 0 });
    expect(readFileSync(join(project, "out", "report.xml"), "utf8")).toBe(ALL_PASS);
  });

  test("names a single file with -gtest and a test with -gunit_test_name", async () => {
    const { gd, processes } = fixture(["gut"], ALL_PASS);

    await gd.json("test", "res://test/test_player.gd", "--select", "jump");

    expect(lastArgs(processes)).toEqual(expect.arrayContaining(["-gtest=res://test/test_player.gd", "-gunit_test_name=jump"]));
    expect(lastArgs(processes).some((arg) => arg.startsWith("-gdir="))).toBe(false);
  });

  test("leaves the folders to GUT's own settings file when it has one, unless paths are given", async () => {
    const { gd, processes, project } = fixture(["gut"], ALL_PASS);
    writeFile(join(project, ".gutconfig.json"), '{"dirs": ["res://spec"]}');

    await gd.json("test");
    expect(lastArgs(processes).some((arg) => arg.startsWith("-gdir=") || arg === "-gconfig=")).toBe(false);

    await gd.json("test", "res://test");
    expect(lastArgs(processes)).toEqual(expect.arrayContaining(["-gdir=res://test", "-gconfig="]));
  });

  test("refuses what GUT would cut short: an = or a comma", async () => {
    const { gd, project } = fixture(["gut"], ALL_PASS);
    writeFile(join(project, "test", "a,b", "test_x.gd"), "extends GutTest\n");

    expect((await gd.json("test", "--select", "a=b")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("test", "--select", "")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("test", "res://test/a,b")).exitCode).toBe(ExitCode.Usage);
  });

  test("reports a --junit file that cannot be written", async () => {
    const { gd, project } = fixture(["gut"], ALL_PASS);
    writeFile(join(project, "blocker"), "a file, not a folder");

    const { exitCode, envelope } = await gd.json("test", "--junit", "blocker/report.xml");

    expect([exitCode, envelope.errors[0]?.message]).toEqual([ExitCode.CommandFailed, "The test report could not be read or saved."]);
  });

  test("runs gdUnit4 headless with its report in a folder of its own", async () => {
    const { gd, processes } = fixture(["gdunit4"], ONE_FAILURE);

    const { exitCode, envelope } = await gd.json("test");

    const args = lastArgs(processes);
    expect(args).toEqual(expect.arrayContaining(["--script", GDUNIT_ENTRY, "--ignoreHeadlessMode", "-c", "-a", "res://test"]));
    expect(existsSync(args[args.indexOf("-rd") + 1] ?? "")).toBe(false);
    expect(exitCode).toBe(ExitCode.CommandFailed);
    expect(envelope.data).toMatchObject({ framework: "gdunit4", failed: 1 });
  });

  test("says what is missing before it starts anything", async () => {
    const none = fixture([], undefined);
    const nothing = await none.gd.json("test");
    expect([nothing.exitCode, nothing.envelope.errors[0]?.code]).toEqual([ExitCode.Precondition, "PRECONDITION_FAILED"]);
    expect(nothing.envelope.errors[0]?.hint).toContain("Asset Library");

    const both = fixture(["gut", "gdunit4"], undefined);
    expect((await both.gd.json("test")).envelope.errors[0]?.hint).toContain("--framework");
    expect((await both.gd.json("test", "--framework", "gdunit4", "--select", "x")).exitCode).toBe(ExitCode.Usage);
    expect((await both.gd.json("test", "--framework", "jest")).exitCode).toBe(ExitCode.Usage);
    expect((await both.gd.json("test", "--framework", "gut", "res://nowhere")).exitCode).toBe(ExitCode.Usage);
    expect(none.processes.calls.length + both.processes.calls.filter((call) => call.args[0] !== "--version").length).toBe(0);
  });

  test("fails without a report, and with no tests found", async () => {
    const silent = fixture(["gut"], undefined, { code: 0, stdout: "something went wrong\n" });
    const noReport = await silent.gd.json("test");
    expect([noReport.exitCode, noReport.envelope.errors[0]?.message]).toEqual([ExitCode.CommandFailed, "The tests did not produce a report."]);

    const empty = fixture(["gut"], "<testsuites></testsuites>");
    expect((await empty.gd.json("test")).envelope.errors[0]?.message).toBe("No tests were found.");
  });

  test("--dry-run shows the command and starts no test", async () => {
    const { gd, processes } = fixture(["gut"], ALL_PASS);

    const { exitCode, envelope } = await gd.json("test", "--dry-run");

    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.data).toMatchObject({ dry_run: true, framework: "gut" });
    expect(processes.calls.every((call) => call.args[0] === "--version")).toBe(true);
  });
});
