// What C# code runs inside a .NET Godot editor, and what of it the bridge
// stops (docs/protocol.md section 4.3). Needs the .NET build of Godot
// (GODOT_BIN) and the .NET SDK; CI runs it in the bridge job's dotnet entry.
//
// Part one writes probe scripts straight to disk, builds them, opens them in
// a headless editor and records which ones ran there: a [Tool] class, a
// [ModuleInitializer], an ordinary class's constructor and field initializer,
// and a static constructor. Part two asks the bridge to write C# and checks
// which writes wait for a person.
//
// Usage: npm run build && GODOT_BIN=/path/to/godot_mono node scripts/dotnet-probe.mjs
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const GD = fileURLToPath(new URL("../cli/dist/main.js", import.meta.url));
const COMMAND_TIMEOUT_MS = 600_000;
const SETTLE_MS = 8000;

const godot = process.env.GODOT_BIN;
if (godot === undefined || godot === "") {
  process.stderr.write("Set GODOT_BIN to a .NET Godot editor binary.\n");
  process.exit(2);
}

const root = mkdtempSync(join(tmpdir(), "gdcli-dotnet-"));
const project = join(root, "probe");
const marks = join(root, "marks");
const env = { ...process.env, GDCLI_HOME: join(root, "home"), GODOT_BIN: godot, GDCLI_PROBE_DIR: marks, GDCLI_FORMAT: "" };

const failures = [];
const facts = [];
function check(condition, label, detail) {
  if (!condition) {
    failures.push(detail === undefined ? label : `${label}: ${JSON.stringify(detail)?.slice(0, 1500)}`);
  }
}

function gd(args) {
  const result = spawnSync(process.execPath, [GD, "--json", ...args], { cwd: project, env, encoding: "utf8", timeout: COMMAND_TIMEOUT_MS });
  let envelope = null;
  try {
    envelope = JSON.parse(result.stdout);
  } catch {
    // Reported by the caller's checks.
  }
  return { status: result.status, envelope, stderr: result.stderr };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** "4.7.stable.mono.official.abc" -> "4.7.0", the Godot.NET.Sdk version that goes with it. */
function sdkVersion() {
  const shown = spawnSync(godot, ["--version"], { encoding: "utf8" }).stdout.trim().split(/\r?\n/u).at(-1) ?? "";
  const [major, minor, third] = shown.split(".");
  const patch = /^\d+$/u.test(third ?? "") ? third : "0";
  return `${major}.${minor}.${patch}`;
}

const PROBE = `using System;
using System.IO;

public static class Probe
{
\t// Records that the named probe ran, and in which process.
\tpublic static void Mark(string name)
\t{
\t\tvar dir = Environment.GetEnvironmentVariable("GDCLI_PROBE_DIR");
\t\tif (string.IsNullOrEmpty(dir)) return;
\t\tDirectory.CreateDirectory(dir);
\t\tvar editor = "?";
\t\ttry { editor = Godot.Engine.IsEditorHint().ToString(); } catch (Exception) { }
\t\tFile.AppendAllText(Path.Combine(dir, name), "editor=" + editor + " args=" + string.Join(" ", Environment.GetCommandLineArgs()) + "\\n");
\t}
}
`;

const SCRIPTS = {
  "Probe.cs": PROBE,
  "ToolProbe.cs": "using Godot;\n\n[Tool]\npublic partial class ToolProbe : Node\n{\n\tpublic override void _Ready() => Probe.Mark(\"tool\");\n}\n",
  "InitProbe.cs": "using System.Runtime.CompilerServices;\n\ninternal static class InitProbe\n{\n\t[ModuleInitializer]\n\tinternal static void Init() => Probe.Mark(\"module\");\n}\n",
  "CtorProbe.cs": "using Godot;\n\npublic partial class CtorProbe : Node\n{\n\t[Export] public int Speed = Field();\n\n\tpublic CtorProbe() => Probe.Mark(\"ctor\");\n\n\tstatic int Field()\n\t{\n\t\tProbe.Mark(\"field\");\n\t\treturn 3;\n\t}\n\n\tpublic override void _Ready() => Probe.Mark(\"ready\");\n}\n",
  "StaticProbe.cs": "using Godot;\n\npublic partial class StaticProbe : Node\n{\n\tstatic StaticProbe() => Probe.Mark(\"static\");\n}\n",
};

const SCENE = `[gd_scene load_steps=4 format=3]

[ext_resource type="Script" path="res://ToolProbe.cs" id="1"]
[ext_resource type="Script" path="res://CtorProbe.cs" id="2"]
[ext_resource type="Script" path="res://StaticProbe.cs" id="3"]

[node name="Main" type="Node"]

[node name="Tool" type="Node" parent="."]
script = ExtResource("1")

[node name="Ctor" type="Node" parent="."]
script = ExtResource("2")

[node name="Static" type="Node" parent="."]
script = ExtResource("3")
`;

function writeProject() {
  mkdirSync(project, { recursive: true });
  const version = sdkVersion();
  writeFileSync(
    join(project, "project.godot"),
    `config_version=5\n\n[application]\n\nconfig/name="probe"\nrun/main_scene="res://main.tscn"\nconfig/features=PackedStringArray("${version.split(".").slice(0, 2).join(".")}", "C#")\n\n[dotnet]\n\nproject/assembly_name="probe"\n\n[editor]\n\nrun/main_run_args="--headless"\n`,
  );
  writeFileSync(
    join(project, "probe.csproj"),
    `<Project Sdk="Godot.NET.Sdk/${version}">\n  <PropertyGroup>\n    <TargetFramework>net8.0</TargetFramework>\n    <EnableDynamicLoading>true</EnableDynamicLoading>\n  </PropertyGroup>\n</Project>\n`,
  );
  for (const [name, text] of Object.entries(SCRIPTS)) {
    writeFileSync(join(project, name), text);
  }
  writeFileSync(join(project, "main.tscn"), SCENE);
  return version;
}

function readMarks() {
  if (!existsSync(marks)) {
    return {};
  }
  return Object.fromEntries(readdirSync(marks).map((name) => [name, readFileSync(join(marks, name), "utf8").trim().split("\n")]));
}

const BRIDGE_CASES = [
  // Every C# file waits: the field initializer of an ordinary class runs in the editor too.
  ["an ordinary class", "public partial class Plain : Godot.Node\n{\n\tpublic int Speed = 3;\n}\n", true],
  ["[Tool]", "[Tool]\npublic partial class Hud : Godot.Control { }\n", true],
  ["[Godot.Tool] with spaces", "[ Godot.Tool ]\npublic partial class Hud2 : Godot.Control { }\n", true],
  ["[ToolAttribute]", "[ToolAttribute]\npublic partial class Hud3 : Godot.Control { }\n", true],
  ["[ModuleInitializer]", "static class Init\n{\n\t[System.Runtime.CompilerServices.ModuleInitializer]\n\tinternal static void Run() { }\n}\n", true],
  ["a \\u escape", "[\\u0054ool]\npublic partial class Hud4 : Godot.Control { }\n", true],
];

let hostStarted = false;
try {
  const version = writeProject();
  facts.push(`Godot.NET.Sdk ${version}`);
  const installed = gd(["bridge", "install"]);
  check(installed.status === 0, "bridge install", installed.envelope);

  const built = spawnSync("dotnet", ["build", "probe.csproj", "-nologo", "-v", "q"], { cwd: project, encoding: "utf8", timeout: COMMAND_TIMEOUT_MS });
  check(built.status === 0, "dotnet build of the probes", `${built.stdout}\n${built.stderr}`.slice(-3000));

  // Part one: the editor alone, no game.
  const started = gd(["host", "start", "--wait", "240"]);
  hostStarted = started.status === 0;
  check(hostStarted, "host start in a .NET project", started.envelope ?? started.stderr);
  const opened = gd(["command", "scene_open", "--path", "res://main.tscn"]);
  check(opened.status === 0, "open the probe scene in the editor", opened.envelope);
  await sleep(SETTLE_MS);
  const ranInEditor = readMarks();
  facts.push(`ran in the editor: ${JSON.stringify(Object.keys(ranInEditor).sort())}`);
  for (const [name, lines] of Object.entries(ranInEditor)) {
    facts.push(`  ${name}: ${lines[0]}`);
  }
  // The rule's premise: [Tool] and [ModuleInitializer] code runs in the editor.
  check("tool" in ranInEditor, "a [Tool] class runs in the editor", ranInEditor);
  check("module" in ranInEditor, "a [ModuleInitializer] runs when the editor loads the assembly", ranInEditor);
  check(!("ready" in ranInEditor), "an ordinary class's _Ready does not run in the editor", ranInEditor);
  // Why the bridge holds back every C# file, not only the marked ones. If this
  // stops holding, the rule in core/edit.gd could be narrowed again.
  check("field" in ranInEditor, "an ordinary class's field initializer runs in the editor", ranInEditor);

  // Part two: C# written through the bridge.
  for (const [label, text, asks] of BRIDGE_CASES) {
    const name = `Bridge${BRIDGE_CASES.findIndex((entry) => entry[0] === label)}.cs`;
    const result = gd(["command", "fs_write_text", "--path", `res://${name}`, "--text", text]);
    const code = result.envelope?.errors?.[0]?.code ?? "";
    if (asks) {
      check(code === "NOT_APPROVED" && !existsSync(join(project, name)), `the bridge waits for a person: ${label}`, result.envelope);
    } else {
      check(result.status === 0 && existsSync(join(project, name)), `the bridge writes ${label}`, result.envelope);
    }
  }
} catch (error) {
  failures.push(error instanceof Error ? error.stack ?? error.message : String(error));
} finally {
  if (hostStarted) {
    gd(["host", "stop"]);
    await sleep(3000);
  }
  try {
    rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 500 });
  } catch {
    // An editor still exiting; the runner's temporary folder goes anyway.
  }
}

process.stdout.write(`${facts.join("\n")}\n`);
if (failures.length > 0) {
  if (process.env.GITHUB_ACTIONS === "true") {
    for (const failure of failures) {
      process.stdout.write(`::error title=dotnet probe::${failure.slice(0, 3000).replaceAll("%", "%25").replaceAll("\r", "%0D").replaceAll("\n", "%0A")}\n`);
    }
    process.stdout.write(`::notice title=dotnet probe facts::${facts.join(" | ").replaceAll("%", "%25").replaceAll("\n", " ")}\n`);
  }
  process.stderr.write(`dotnet probe failed (${failures.length}):\n- ${failures.join("\n- ")}\n`);
  process.exit(1);
}
if (process.env.GITHUB_ACTIONS === "true") {
  process.stdout.write(`::notice title=dotnet probe facts::${facts.join(" | ").replaceAll("%", "%25").replaceAll("\n", " ")}\n`);
}
process.stdout.write("dotnet probe passed\n");
