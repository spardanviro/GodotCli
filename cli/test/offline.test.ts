import { existsSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, test } from "vitest";

import { readPresetNames } from "../src/commands/offline.js";
import { findOnPath, isSupported, locateGodot, parseVersion, preferConsoleBinary, preferGuiBinary, readUserConfig } from "../src/godot.js";
import { formatDiagnostic, parseGodotOutput } from "../src/output-parser.js";
import { ExitCode } from "../src/protocol.js";
import { type Call, FAKE_INSTANCE_ID, type FakeProcesses, fakeProcesses, harness, makeProject, tempDir, writeFile, writeLockFile } from "./helpers.js";

const RUN_OUTPUT = `Godot Engine v4.7.stable.official
started
WARNING: careful
   at: VariantUtilityFunctions::push_warning (core/variant/variant_utility.cpp:1033)
   GDScript backtrace (most recent call first):
       [0] _ready (res://scripts/main.gd:6)
SCRIPT ERROR: Cannot call method 'queue_free' on a null value.
   at: _ready (res://scripts/main.gd:8)
   GDScript backtrace (most recent call first):
       [0] _ready (res://scripts/main.gd:8)
SCRIPT ERROR: Cannot call method 'queue_free' on a null value.
   at: _ready (res://scripts/main.gd:8)
ERROR: Condition "!is_inside_tree()" is true.
   at: get_global_transform (scene/2d/node_2d.cpp:300)
`;

const PARSE_ERROR_OUTPUT = `SCRIPT ERROR: Parse Error: Expected parameter name.
   at: GDScript::reload (res://scripts/bad.gd:4)
ERROR: Failed to load script "res://scripts/bad.gd" with error "Parse error".
   at: ResourceFormatLoaderGDScript::load (modules/gdscript/gdscript_resource_format.cpp:46)
`;

interface Fixture {
  readonly project: string;
  readonly godot: string;
  readonly processes: FakeProcesses;
  readonly gd: ReturnType<typeof harness>;
}

function fixture(respond: (call: Call) => Partial<{ code: number | null; stdout: string; stderr: string; timedOut: boolean; spawnError: string }> = () => ({}), versionOutput?: string): Fixture {
  const home = tempDir();
  const project = makeProject(home);
  writeFile(join(project, "main.tscn"), "");
  writeFile(join(project, "scripts", "good.gd"), "extends Node\n");
  writeFile(join(project, "scripts", "bad.gd"), "extends Node\nfunc broken(:\n");
  writeFile(join(project, "scripts", "tool.gd"), "# a tool\nextends SceneTree\n");
  const godot = writeFile(join(home, "bin", "godot-bin"), "");
  const processes = fakeProcesses(respond, versionOutput);
  return { project, godot, processes, gd: harness({ homeDir: home, cwd: project, processes, env: { GODOT_BIN: godot } }) };
}

function lastCall(processes: FakeProcesses): Call {
  return processes.calls.at(-1)!;
}

describe("parseGodotOutput", () => {
  test("extracts errors and warnings with the script location", () => {
    const { diagnostics, truncated } = parseGodotOutput(RUN_OUTPUT);

    expect(truncated).toBe(false);
    expect(diagnostics).toEqual([
      { severity: "warning", kind: "WARNING", message: "careful", file: "res://scripts/main.gd", line: 6, function: "_ready" },
      {
        severity: "error",
        kind: "SCRIPT ERROR",
        message: "Cannot call method 'queue_free' on a null value.",
        file: "res://scripts/main.gd",
        line: 8,
        function: "_ready",
      },
      {
        severity: "error",
        kind: "ERROR",
        message: 'Condition "!is_inside_tree()" is true.',
        file: "scene/2d/node_2d.cpp",
        line: 300,
        function: "get_global_transform",
      },
    ]);
  });

  test("does not borrow the location of the next diagnostic", () => {
    const { diagnostics } = parseGodotOutput("ERROR: first\nERROR: second\n   at: f (res://b.gd:2)\n");

    expect(diagnostics[0]).toEqual({ severity: "error", kind: "ERROR", message: "first" });
    expect(diagnostics[1]).toMatchObject({ message: "second", file: "res://b.gd", line: 2 });
  });

  test("handles user-raised kinds, inline locations, colour codes and CRLF", () => {
    const escape = String.fromCodePoint(0x1b);
    const output = `${escape}[31mUSER SCRIPT ERROR: boom${escape}[0m\r\nUSER WARNING: hmm\r\nERROR: res://x.gd:3 - Parse Error: bad\r\n`;

    const { diagnostics } = parseGodotOutput(output);

    expect(diagnostics.map((entry) => [entry.kind, entry.severity])).toEqual([
      ["USER SCRIPT ERROR", "error"],
      ["USER WARNING", "warning"],
      ["ERROR", "error"],
    ]);
    expect(diagnostics[2]).toMatchObject({ file: "res://x.gd", line: 3 });
  });

  test("caps the number of diagnostics and the length of a message", () => {
    const many = Array.from({ length: 250 }, (_, index) => `ERROR: number ${index}`).join("\n");

    const parsed = parseGodotOutput(`${many}\nERROR: ${"x".repeat(5000)}`);

    expect(parsed.diagnostics).toHaveLength(200);
    expect(parsed.truncated).toBe(true);
    expect(parseGodotOutput(`ERROR: ${"x".repeat(5000)}`).diagnostics[0]?.message.length).toBeLessThan(2100);
  });

  test("formats a diagnostic for people", () => {
    expect(formatDiagnostic({ severity: "error", kind: "ERROR", message: "boom", file: "res://a.gd", line: 3 })).toBe("res://a.gd:3: error: boom");
    expect(formatDiagnostic({ severity: "warning", kind: "WARNING", message: "hmm" })).toBe("warning: hmm");
  });
});

describe("finding Godot", () => {
  test("parses version strings", () => {
    expect(parseVersion("4.3.stable.official.77dcf97d8\n")).toMatchObject({ major: 4, minor: 3, patch: 0, status: "stable" });
    expect(parseVersion("some warning\n4.4.1.rc2.mono.custom_build\n")).toMatchObject({ major: 4, minor: 4, patch: 1, status: "rc2" });
    expect(parseVersion("not a version")).toBeUndefined();
    expect(isSupported(parseVersion("4.2.2.stable")!)).toBe(false);
    expect(isSupported(parseVersion("5.0.dev")!)).toBe(true);
  });

  test("skips the working directory and relative PATH entries", () => {
    const root = tempDir();
    const cwd = join(root, "project");
    writeFile(join(cwd, "godot"), "");
    writeFile(join(cwd, "godot.exe"), "");
    const real = writeFile(join(root, "tools", process.platform === "win32" ? "godot4.exe" : "godot4"), "");
    const delimiter = process.platform === "win32" ? ";" : ":";
    const context = harness({ cwd, env: { PATH: [".", "", "relative/bin", join(root, "tools")].join(delimiter) } }).context;

    expect(findOnPath(context)).toBe(real);
    expect(findOnPath(harness({ cwd, env: { PATH: [".", ""].join(delimiter) } }).context)).toBeUndefined();
  });

  test("uses --godot, then GODOT_BIN, then the user config", () => {
    const home = tempDir();
    const fromFlag = writeFile(join(home, "flag-godot"), "");
    const fromEnv = writeFile(join(home, "env-godot"), "");
    const fromConfig = writeFile(join(home, "config-godot"), "");
    writeFile(join(home, ".gdcli", "config.json"), JSON.stringify({ godot_bin: fromConfig }));
    const globals = { format: "human", yes: false, dryRun: false } as const;

    expect(locateGodot(harness({ homeDir: home, env: { GODOT_BIN: fromEnv, PATH: "" } }).context, { ...globals, godot: fromFlag })).toBe(fromFlag);
    expect(locateGodot(harness({ homeDir: home, env: { GODOT_BIN: fromEnv, PATH: "" } }).context, globals)).toBe(fromEnv);
    expect(locateGodot(harness({ homeDir: home, env: { PATH: "" } }).context, globals)).toBe(fromConfig);
    expect(locateGodot(harness({ homeDir: home, env: { PATH: "" } }).context, { ...globals, godot: join(home, "missing") })).toMatchObject({
      code: "GODOT_NOT_FOUND",
    });
    expect(locateGodot(harness({ env: { PATH: "" } }).context, globals)).toMatchObject({ code: "GODOT_NOT_FOUND" });
  });

  test("looks a bare name up on PATH and never in the working directory", () => {
    const root = tempDir();
    const cwd = join(root, "project");
    writeFile(join(cwd, "godot4"), "");
    writeFile(join(cwd, "godot4.exe"), "");
    const real = writeFile(join(root, "tools", process.platform === "win32" ? "godot4.exe" : "godot4"), "");
    const globals = { format: "human", yes: false, dryRun: false } as const;

    expect(locateGodot(harness({ cwd, env: { GODOT_BIN: "godot4", PATH: join(root, "tools") } }).context, globals)).toBe(real);
    expect(locateGodot(harness({ cwd, env: { GODOT_BIN: "godot4", PATH: "" } }).context, globals)).toMatchObject({ code: "GODOT_NOT_FOUND" });
  });

  test("refuses a binary inside the project and one on a network path", () => {
    const root = tempDir();
    const project = makeProject(root);
    const planted = writeFile(join(project, "tools", "godot-bin"), "");
    const globals = { format: "human", yes: false, dryRun: false } as const;
    const context = harness({ cwd: project, env: { PATH: "" } }).context;

    expect(locateGodot(context, { ...globals, godot: planted })).toMatchObject({ code: "GODOT_NOT_FOUND", message: expect.stringContaining("inside the project") });
    expect(locateGodot(context, { ...globals, godot: "//server/share/godot.exe" })).toMatchObject({ message: expect.stringContaining("network path") });
  });

  test("uses the GUI binary to open the editor on Windows", () => {
    const root = tempDir();
    const gui = writeFile(join(root, "Godot_v4.3.exe"), "");
    const wrapper = writeFile(join(root, "Godot_v4.3_console.exe"), "");

    expect(preferGuiBinary(wrapper, "win32")).toBe(gui);
    expect(preferGuiBinary(wrapper, "linux")).toBe(wrapper);
    expect(preferGuiBinary(join(root, "only_console.exe"), "win32")).toBe(join(root, "only_console.exe"));
  });

  test("prefers the console wrapper next to a Windows GUI binary", () => {
    const root = tempDir();
    const gui = writeFile(join(root, "Godot_v4.3.exe"), "");
    const wrapper = writeFile(join(root, "Godot_v4.3_console.exe"), "");

    expect(preferConsoleBinary(gui, "win32")).toBe(wrapper);
    expect(preferConsoleBinary(wrapper, "win32")).toBe(wrapper);
    expect(preferConsoleBinary(gui, "linux")).toBe(gui);
    expect(preferConsoleBinary(join(root, "lonely.exe"), "win32")).toBe(join(root, "lonely.exe"));
  });

  test("reads only well-formed user configuration", () => {
    const home = tempDir();
    writeFile(join(home, ".gdcli", "config.json"), "{broken");

    expect(readUserConfig(harness({ homeDir: home }).context)).toEqual({ allowOffline: true });
  });
});

describe("offline preconditions", () => {
  test("refuses a Godot that is too old", async () => {
    const { gd } = fixture(undefined, "4.2.2.stable.official\n");

    const { exitCode, envelope } = await gd.json("import");

    expect(exitCode).toBe(ExitCode.Precondition);
    expect(envelope.errors[0]?.code).toBe("UNSUPPORTED_GODOT_VERSION");
  });

  test("refuses a binary that is not Godot", async () => {
    const { gd } = fixture(undefined, "hello\n");

    expect((await gd.json("import")).envelope.errors[0]?.code).toBe("GODOT_NOT_FOUND");
  });

  test("honours allow_offline=false from the user config", async () => {
    const home = tempDir();
    const project = makeProject(home);
    writeFile(join(home, ".gdcli", "config.json"), JSON.stringify({ allow_offline: false }));

    const { exitCode, envelope } = await harness({ homeDir: home, cwd: project }).json("import");

    expect(exitCode).toBe(ExitCode.Precondition);
    expect(envelope.errors[0]?.code).toBe("PRECONDITION_FAILED");
  });

  test("--dry-run starts nothing and says what it would start", async () => {
    const { gd, processes, project } = fixture();

    const planned = [
      await gd.json("run", "main.tscn", "--headless", "--dry-run"),
      await gd.json("check", "scripts/good.gd", "--dry-run"),
      await gd.json("exec", "scripts/tool.gd", "--dry-run"),
      await gd.json("import", "--dry-run"),
      await gd.json("open", "--dry-run"),
    ];

    expect(planned.map((entry) => entry.exitCode)).toEqual([0, 0, 0, 0, 0]);
    expect(planned[0]?.envelope.data).toMatchObject({ dry_run: true, args: ["--path", project, "--headless", "res://main.tscn"] });
    expect(processes.calls.every((call) => call.args[0] === "--version")).toBe(true);
    expect(processes.detached).toEqual([]);
  });

  test("needs a project", async () => {
    const { envelope } = await harness({ cwd: tempDir() }).json("run");

    expect(envelope.errors[0]?.code).toBe("NO_PROJECT");
  });
});

describe("gd run", () => {
  test("says that unsaved editor changes are not part of the run when an editor has the project open", async () => {
    const { gd, project } = fixture();
    const quiet = await gd.json("run");
    writeLockFile(join(gd.context.homeDir, ".gdcli", "instances", `${FAKE_INSTANCE_ID}.json`), {
      instance_id: FAKE_INSTANCE_ID,
      port: 50123,
      project_path: project,
    });

    const { exitCode, envelope } = await gd.json("run");

    expect(quiet.envelope.warnings.some((warning) => warning.includes("An editor has this project open"))).toBe(false);
    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.warnings.some((warning) => warning.includes("save the scene first"))).toBe(true);
  });

  test("fails with the parsed errors when the scene prints errors", async () => {
    const { gd, processes, project, godot } = fixture(() => ({ stdout: RUN_OUTPUT, timedOut: true, code: null }));

    const { exitCode, envelope } = await gd.json("run", "main.tscn", "--headless", "--seconds", "3");

    const call = lastCall(processes);
    expect(call.file).toBe(godot);
    expect(call.args).toEqual(["--path", project, "--headless", "res://main.tscn"]);
    expect(call.options).toMatchObject({ cwd: project, timeoutMs: 3000 });
    expect(exitCode).toBe(ExitCode.CommandFailed);
    expect(envelope.success).toBe(false);
    expect(envelope.data).toMatchObject({ scene: "res://main.tscn", stopped_after_seconds: 3, error_count: 2, warning_count: 1 });
  });

  test("succeeds when only warnings were printed, with the default duration", async () => {
    const { gd, processes, project } = fixture(() => ({ stdout: "WARNING: just this\n" }));

    const { exitCode, envelope } = await gd.json("run");
    const text = await gd.text("run");

    expect(lastCall(processes).args).toEqual(["--path", project]);
    expect(lastCall(processes).options?.timeoutMs).toBe(10_000);
    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.data).toMatchObject({ scene: null, stopped_after_seconds: null, exit_code: 0, error_count: 0, warning_count: 1 });
    expect(text.out).toContain("warning: just this");
    expect(text.out).toContain("0 error(s), 1 warning(s)");
  });

  test("warns when the project was never imported", async () => {
    const { gd, project } = fixture();

    const fresh = await gd.json("run");
    writeFile(join(project, ".godot", "uid_cache.bin"), "");
    const imported = await gd.json("run");

    expect(fresh.envelope.warnings[0]).toContain("gd import");
    expect(imported.envelope.warnings).toEqual([]);
  });

  test("still finds errors after an unterminated escape sequence in the output", async () => {
    const escape = String.fromCodePoint(0x1b);
    const { gd } = fixture(() => ({ stdout: `${escape}]0;title never closed\nSCRIPT ERROR: boom\n   at: f (res://a.gd:1)\n` }));

    const { envelope } = await gd.json("run");

    expect(envelope.data).toMatchObject({ error_count: 1 });
  });

  test("rejects bad options and paths without starting the game", async () => {
    const { gd, processes } = fixture();

    expect((await gd.json("run", "--seconds", "0")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("run", "--fast")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("run", "a.tscn", "b.tscn")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("run", "../elsewhere.tscn")).envelope.errors[0]?.code).toBe("PATH_NOT_ALLOWED");
    expect(processes.calls.every((call) => call.args[0] === "--version")).toBe(true);
  });

  test("reports a binary that cannot be started", async () => {
    const { gd } = fixture(() => ({ code: null, spawnError: "EACCES" }));

    expect((await gd.json("run")).envelope.errors[0]).toMatchObject({ code: "GODOT_NOT_FOUND", details: { reason: "EACCES" } });
  });
});

describe("gd check", () => {
  test("checks each script and fails when one has errors", async () => {
    const { gd, processes, project } = fixture((call) => (call.args.includes("res://scripts/bad.gd") ? { code: 1, stderr: PARSE_ERROR_OUTPUT } : {}));

    const { exitCode, envelope } = await gd.json("check", "scripts/good.gd", "res://scripts/bad.gd");

    expect(processes.calls[1]?.args).toEqual(["--path", project, "--headless", "--check-only", "--script", "res://scripts/good.gd"]);
    expect(exitCode).toBe(ExitCode.CommandFailed);
    expect(envelope.data).toMatchObject({
      failed: 1,
      scripts: [
        { script: "res://scripts/good.gd", ok: true },
        { script: "res://scripts/bad.gd", ok: false, diagnostics: [{ file: "res://scripts/bad.gd", line: 4 }, {}] },
      ],
    });
  });

  test("passes clean scripts and prints one line each", async () => {
    const { gd } = fixture();

    const text = await gd.text("check", "scripts/good.gd");

    expect(text.exitCode).toBe(ExitCode.Success);
    expect(text.out).toBe("ok   res://scripts/good.gd\n");
  });

  test("treats a non-zero status without a parsed error as a failure and shows the output", async () => {
    const { gd } = fixture(() => ({ code: 1, stdout: "something odd" }));

    const { envelope } = await gd.json("check", "scripts/good.gd");

    expect(envelope.data).toMatchObject({ scripts: [{ ok: false, output_tail: "something odd" }] });
  });

  test("reports a check that hangs as a timeout", async () => {
    const { gd } = fixture(() => ({ code: null, timedOut: true }));

    const { exitCode, envelope } = await gd.json("check", "scripts/good.gd");

    expect(exitCode).toBe(ExitCode.Transient);
    expect(envelope.errors[0]?.code).toBe("TIMEOUT");
  });

  test("needs at least one script and validates every path first", async () => {
    const { gd, processes } = fixture();

    expect((await gd.json("check")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("check", "scripts/good.gd", "scripts/missing.gd")).envelope.errors[0]?.code).toBe("RESOURCE_NOT_FOUND");
    expect(processes.calls.some((call) => call.args.includes("--check-only"))).toBe(false);
  });
});

describe("gd exec", () => {
  test("runs a SceneTree script and puts user arguments after --", async () => {
    const { gd, processes, project } = fixture(() => ({ stdout: "done\n" }));

    const { exitCode, envelope } = await gd.json("exec", "scripts/tool.gd", "--", "--level", "3");

    expect(lastCall(processes).args).toEqual(["--path", project, "--headless", "--script", "res://scripts/tool.gd", "--", "--level", "3"]);
    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.data).toMatchObject({ script: "res://scripts/tool.gd", exit_code: 0, stdout: "done" });
  });

  test("accepts class_name on the extends line and scripts extending another script", async () => {
    const { gd, project } = fixture();
    writeFile(join(project, "scripts", "named.gd"), "class_name Tool extends MainLoop\n");
    writeFile(join(project, "scripts", "derived.gd"), 'extends "res://scripts/tool.gd"\n');

    expect((await gd.json("exec", "scripts/named.gd")).exitCode).toBe(ExitCode.Success);
    expect((await gd.json("exec", "scripts/derived.gd")).exitCode).toBe(ExitCode.Success);
  });

  test("refuses scripts Godot would not run this way", async () => {
    const { gd } = fixture();

    const { exitCode, envelope } = await gd.json("exec", "scripts/good.gd");

    expect(exitCode).toBe(ExitCode.Precondition);
    expect(envelope.errors[0]?.code).toBe("PRECONDITION_FAILED");
  });

  test("reports failure, timeout and usage errors", async () => {
    const failing = fixture(() => ({ code: 1, stderr: "SCRIPT ERROR: boom\n" }));
    expect((await failing.gd.json("exec", "scripts/tool.gd")).exitCode).toBe(ExitCode.CommandFailed);

    const slow = fixture(() => ({ code: null, timedOut: true }));
    const timedOut = await slow.gd.json("exec", "scripts/tool.gd", "--timeout", "2");
    expect(timedOut.exitCode).toBe(ExitCode.Transient);
    expect(lastCall(slow.processes).options?.timeoutMs).toBe(2000);

    expect((await failing.gd.json("exec")).exitCode).toBe(ExitCode.Usage);
  });
});

describe("gd import", () => {
  test("runs a headless import", async () => {
    const { gd, processes, project } = fixture();

    const { exitCode } = await gd.json("import");

    expect(lastCall(processes).args).toEqual(["--path", project, "--headless", "--import"]);
    expect(exitCode).toBe(ExitCode.Success);
  });

  test("reports failure, timeout and stray arguments", async () => {
    expect((await fixture(() => ({ code: 1 })).gd.json("import")).exitCode).toBe(ExitCode.CommandFailed);
    expect((await fixture(() => ({ code: null, timedOut: true })).gd.json("import")).exitCode).toBe(ExitCode.Transient);
    expect((await fixture().gd.json("import", "everything")).exitCode).toBe(ExitCode.Usage);
  });
});

describe("gd export", () => {
  const PRESETS = '[preset.0]\n\nname="Windows Desktop"\nplatform="Windows Desktop"\n\n[preset.1]\n\nname="Web"\n';

  test("unescapes quotes and backslashes in preset names", () => {
    const { project } = fixture();
    writeFile(join(project, "export_presets.cfg"), 'name="My \\"Game\\" \\\\ Demo"\n');

    expect(readPresetNames(project)).toEqual(['My "Game" \\ Demo']);
  });

  test("asks before writing outside the project", async () => {
    const { gd, project } = fixture();
    writeFile(join(project, "export_presets.cfg"), PRESETS);

    const { exitCode, envelope } = await gd.json("export", "Web", "../elsewhere/game.zip", "--pack");

    expect(exitCode).toBe(ExitCode.Precondition);
    expect(envelope.errors[0]).toMatchObject({ code: "CONFIRMATION_REQUIRED", message: expect.stringContaining("outside the project") });
    expect(existsSync(join(project, "..", "elsewhere"))).toBe(false);
  });

  test("reads preset names from the project", () => {
    const { project } = fixture();
    writeFile(join(project, "export_presets.cfg"), PRESETS);

    expect(readPresetNames(project)).toEqual(["Windows Desktop", "Web"]);
    expect(readPresetNames(join(project, "missing"))).toEqual([]);
  });

  test("exports with an absolute output path and creates its folder", async () => {
    const built = fixture((call) => {
      writeFile(call.args.at(-1)!, "pck");
      return {};
    });
    writeFile(join(built.project, "export_presets.cfg"), PRESETS);

    const { exitCode, envelope } = await built.gd.json("export", "Web", "build/web/game.zip", "--pack");

    const output = join(built.project, "build", "web", "game.zip");
    expect(lastCall(built.processes).args).toEqual(["--path", built.project, "--headless", "--export-pack", "Web", output]);
    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.data).toMatchObject({ preset: "Web", output });
  });

  test("only accepts a preset the project defines", async () => {
    const { gd, project, processes } = fixture();
    writeFile(join(project, "export_presets.cfg"), PRESETS);

    const { envelope } = await gd.json("export", "--export-debug", "out.zip");
    const unknown = await gd.json("export", "Linux", "out.zip");

    expect(envelope.errors[0]?.code).toBe("USAGE");
    expect(unknown.envelope.errors[0]).toMatchObject({ code: "RESOURCE_NOT_FOUND", details: { available: ["Windows Desktop", "Web"] } });
    expect(processes.calls.every((call) => call.args[0] === "--version")).toBe(true);
  });

  test("asks before overwriting, and --dry-run exports nothing", async () => {
    const { gd, project, processes } = fixture();
    writeFile(join(project, "export_presets.cfg"), PRESETS);
    writeFile(join(project, "old.zip"), "old");

    const refused = await gd.json("export", "Web", "old.zip");
    const dryRun = await gd.json("export", "Web", "new/game.zip", "--dry-run");

    expect(refused.exitCode).toBe(ExitCode.Precondition);
    expect(refused.envelope.errors[0]?.code).toBe("CONFIRMATION_REQUIRED");
    expect(dryRun.envelope.data).toMatchObject({ dry_run: true });
    expect(existsSync(join(project, "new"))).toBe(false);
    expect(processes.calls.every((call) => call.args[0] === "--version")).toBe(true);
  });

  test("chooses the export mode and reports a failed export", async () => {
    const { gd, project, processes } = fixture(() => ({ code: 1, stderr: "ERROR: No export template found.\n" }));
    writeFile(join(project, "export_presets.cfg"), PRESETS);

    const release = await gd.json("export", "Web", "a.zip");
    expect(lastCall(processes).args).toContain("--export-release");
    await gd.json("export", "Web", "b.zip", "--debug");
    expect(lastCall(processes).args).toContain("--export-debug");

    expect(release.exitCode).toBe(ExitCode.CommandFailed);
    expect(release.envelope.data).toMatchObject({ error_count: 1 });
    expect((await gd.json("export", "Web", "c.zip", "--debug", "--pack")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("export", "Web")).exitCode).toBe(ExitCode.Usage);
  });
});

describe("gd open", () => {
  test("starts the editor detached and returns at once", async () => {
    const { gd, processes, project, godot } = fixture();

    const { exitCode, envelope } = await gd.json("open", "main.tscn");

    expect(processes.detached).toEqual([{ file: godot, args: ["--editor", "--path", project, "res://main.tscn"], options: { cwd: project, timeoutMs: 0 } }]);
    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.data).toMatchObject({ pid: 4242, scene: "res://main.tscn" });
  });

  test("rejects more than one scene", async () => {
    expect((await fixture().gd.json("open", "a.tscn", "b.tscn")).exitCode).toBe(ExitCode.Usage);
  });
});
