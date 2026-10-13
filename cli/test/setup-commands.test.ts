import { existsSync, readFileSync, readdirSync, symlinkSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, test } from "vitest";

import { addGameHelper, enablePlugin, hasGameHelper, isPluginEnabled } from "../src/commands/bridge.js";
import { ExitCode } from "../src/protocol.js";
import { type Call, fakeBridge, fakeProcesses, harness, makeProject, tempDir, writeFile, writeLockFile } from "./helpers.js";

const ENABLED_LINE = 'enabled=PackedStringArray("res://addons/gdcli/plugin.cfg")';

function addonFixture(root: string, version = "1.2.3"): string {
  const addon = join(root, "bundled-addon");
  writeFile(join(addon, "plugin.cfg"), `[plugin]\n\nname="gdcli bridge"\nversion="${version}"\nscript="plugin.gd"\n`);
  writeFile(join(addon, "plugin.gd"), "@tool\nextends EditorPlugin\n");
  writeFile(join(addon, "core", "bridge.gd"), "extends RefCounted\n");
  return addon;
}

const HELPER_LINE = 'GdcliGame="*res://addons/gdcli/runtime/game_agent.gd"';

describe("enablePlugin", () => {
  test("adds the section when the project has none", () => {
    const result = enablePlugin('config_version=5\n\n[application]\n\nconfig/name="x"\n');

    expect(result).toBe(`config_version=5\n\n[application]\n\nconfig/name="x"\n\n[editor_plugins]\n\n${ENABLED_LINE}\n`);
    expect(isPluginEnabled(result)).toBe(true);
  });

  test("appends to an existing list and keeps the other plugins", () => {
    const before = '[editor_plugins]\n\nenabled=PackedStringArray("res://addons/other/plugin.cfg")\n\n[rendering]\n\nx=1\n';

    const result = enablePlugin(before);

    expect(result).toContain('enabled=PackedStringArray("res://addons/other/plugin.cfg", "res://addons/gdcli/plugin.cfg")');
    expect(result).toContain("[rendering]\n\nx=1\n");
  });

  test("fills an empty list and a section without the key", () => {
    expect(enablePlugin("[editor_plugins]\n\nenabled=PackedStringArray()\n")).toContain(ENABLED_LINE);
    expect(enablePlugin("[editor_plugins]\n\n[input]\n")).toBe(`[editor_plugins]\n\n${ENABLED_LINE}\n\n[input]\n`);
  });

  test("changes nothing when the plugin is already enabled", () => {
    const text = `[editor_plugins]\n\n${ENABLED_LINE}\n`;

    expect(enablePlugin(text)).toBe(text);
  });

  test("keeps Windows line endings", () => {
    const result = enablePlugin("config_version=5\r\n");

    expect(result).toBe(`config_version=5\r\n\r\n[editor_plugins]\r\n\r\n${ENABLED_LINE}\r\n`);
  });

  test("keeps Windows line endings when the section exists without the key", () => {
    const result = enablePlugin("[editor_plugins]\r\n\r\n[input]\r\n");

    expect(result).toBe(`[editor_plugins]\r\n\r\n${ENABLED_LINE}\r\n\r\n[input]\r\n`);
  });

  test("appends to an existing list in a file with Windows line endings", () => {
    const result = enablePlugin('[editor_plugins]\r\n\r\nenabled=PackedStringArray("res://addons/a/plugin.cfg")\r\n');

    expect(result).toBe('[editor_plugins]\r\n\r\nenabled=PackedStringArray("res://addons/a/plugin.cfg", "res://addons/gdcli/plugin.cfg")\r\n');
    expect(isPluginEnabled(result)).toBe(true);
  });

  test("is not fooled by the key in another section", () => {
    expect(isPluginEnabled(`[other]\n\n${ENABLED_LINE}\n`)).toBe(false);
  });
});

describe("addGameHelper", () => {
  test("adds the autoload section when the project has none", () => {
    const result = addGameHelper('config_version=5\n\n[application]\n\nconfig/name="x"\n');

    expect(result).toBe(`config_version=5\n\n[application]\n\nconfig/name="x"\n\n[autoload]\n\n${HELPER_LINE}\n`);
    expect(hasGameHelper(result)).toBe(true);
  });

  test("keeps the autoloads the project already has, and Windows line endings", () => {
    const result = addGameHelper('[autoload]\r\n\r\nGame="*res://game.gd"\r\n\r\n[rendering]\r\n');

    expect(result).toBe(`[autoload]\r\n\r\n${HELPER_LINE}\r\n\r\nGame="*res://game.gd"\r\n\r\n[rendering]\r\n`);
  });

  test("changes nothing when the helper is there, even with another script", () => {
    const text = '[autoload]\n\nGdcliGame="*res://elsewhere.gd"\n';

    expect(addGameHelper(text)).toBe(text);
  });

  test("is not fooled by the name in another section", () => {
    expect(hasGameHelper(`[other]\n\n${HELPER_LINE}\n`)).toBe(false);
  });
});

describe("gd bridge", () => {
  test("adds the game helper to a project that has only the plugin", async () => {
    const home = tempDir();
    const project = makeProject(home, `\n[editor_plugins]\n\n${ENABLED_LINE}\n`);
    const gd = harness({ homeDir: home, cwd: project, addonDir: addonFixture(home) });
    writeFile(join(project, "addons", "gdcli", "plugin.cfg"), 'version="1.2.3"\n');

    const { envelope } = await gd.json("bridge", "install");

    expect((envelope.data as { actions: string[] }).actions).toEqual(["add the GdcliGame autoload to project.godot"]);
    expect(hasGameHelper(readFileSync(join(project, "project.godot"), "utf8"))).toBe(true);
  });

  test("installs the addon and enables it with one command", async () => {
    const home = tempDir();
    const project = makeProject(home);
    const gd = harness({ homeDir: home, cwd: project, addonDir: addonFixture(home) });

    const { exitCode, envelope } = await gd.json("bridge", "install");

    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.data).toMatchObject({ installed_version: "1.2.3", enabled: true, editor_running: false });
    expect(readdirSync(join(project, "addons", "gdcli")).sort()).toEqual(["core", "plugin.cfg", "plugin.gd"]);
    expect(readFileSync(join(project, "project.godot"), "utf8")).toContain(ENABLED_LINE);
    expect(readFileSync(join(project, "project.godot"), "utf8")).toContain(HELPER_LINE);
    expect(envelope.data).toMatchObject({ game_helper: true });
    expect((await gd.json("bridge", "status")).exitCode).toBe(ExitCode.Success);
  });

  test("does nothing the second time", async () => {
    const home = tempDir();
    const project = makeProject(home);
    const gd = harness({ homeDir: home, cwd: project, addonDir: addonFixture(home) });
    await gd.json("bridge", "install");
    const before = readFileSync(join(project, "project.godot"), "utf8");

    const { envelope } = await gd.json("bridge", "install");

    expect(envelope.data).toMatchObject({ actions: [] });
    expect(readFileSync(join(project, "project.godot"), "utf8")).toBe(before);
  });

  test("--dry-run reports the plan without touching the project", async () => {
    const home = tempDir();
    const project = makeProject(home);
    const before = readFileSync(join(project, "project.godot"), "utf8");

    const { envelope } = await harness({ homeDir: home, cwd: project, addonDir: addonFixture(home) }).json("bridge", "install", "--dry-run");

    // Copy the addon, enable the plugin, register the game helper.
    expect((envelope.data as { actions: string[] }).actions).toHaveLength(3);
    expect(existsSync(join(project, "addons"))).toBe(false);
    expect(readFileSync(join(project, "project.godot"), "utf8")).toBe(before);
  });

  test("replaces another version only with --force", async () => {
    const home = tempDir();
    const project = makeProject(home);
    writeFile(join(project, "addons", "gdcli", "plugin.cfg"), 'version="0.0.9"\n');
    writeFile(join(project, "addons", "gdcli", "stale.gd"), "");
    const gd = harness({ homeDir: home, cwd: project, addonDir: addonFixture(home) });

    const refused = await gd.json("bridge", "install");
    const forced = await gd.json("bridge", "install", "--force");

    expect(refused.exitCode).toBe(ExitCode.CommandFailed);
    expect(refused.envelope.errors[0]).toMatchObject({ code: "ALREADY_EXISTS", details: { installed: "0.0.9", bundled: "1.2.3" } });
    expect(forced.envelope.data).toMatchObject({ installed_version: "1.2.3" });
    expect(existsSync(join(project, "addons", "gdcli", "stale.gd"))).toBe(false);
  });

  test("does not delete a folder at addons/gdcli that is not the bridge", async () => {
    const home = tempDir();
    const project = makeProject(home);
    const precious = writeFile(join(project, "addons", "gdcli", "my_own_work.gd"), "keep me");

    const { envelope } = await harness({ homeDir: home, cwd: project, addonDir: addonFixture(home) }).json("bridge", "install");

    expect(envelope.errors[0]?.code).toBe("ALREADY_EXISTS");
    expect(existsSync(precious)).toBe(true);
  });

  test("refuses to install through a link", async () => {
    const home = tempDir();
    const project = makeProject(home);
    const elsewhere = join(home, "elsewhere");
    const victim = writeFile(join(elsewhere, "gdcli", "important.txt"), "keep me");
    try {
      symlinkSync(elsewhere, join(project, "addons"), "junction");
    } catch {
      // No way to create a link here; nothing to test.
      return;
    }

    const { envelope } = await harness({ homeDir: home, cwd: project, addonDir: addonFixture(home) }).json("bridge", "install", "--force");

    expect(envelope.errors[0]?.code).toBe("PATH_NOT_ALLOWED");
    expect(existsSync(victim)).toBe(true);
  });

  test("warns when the editor is open on the project", async () => {
    const home = tempDir();
    const project = makeProject(home);
    writeLockFile(join(home, ".gdcli", "instances", "0123456789abcdef.json"), {
      instance_id: "0123456789abcdef",
      port: 5000,
      project_path: project.replaceAll("\\", "/"),
    });

    const { envelope } = await harness({ homeDir: home, cwd: project, addonDir: addonFixture(home) }).json("bridge", "install");

    expect(envelope.warnings[0]).toContain("restart it");
  });

  test("status fails with BRIDGE_NOT_INSTALLED, and a broken package is an internal error", async () => {
    const home = tempDir();
    const project = makeProject(home);
    const gd = harness({ homeDir: home, cwd: project });

    const status = await gd.json("bridge", "status");
    const install = await gd.json("bridge", "install");

    expect(status.exitCode).toBe(ExitCode.Precondition);
    expect(status.envelope.errors[0]?.code).toBe("BRIDGE_NOT_INSTALLED");
    expect(install.exitCode).toBe(ExitCode.Internal);
  });

  test("rejects unknown actions and options", async () => {
    const gd = harness({ cwd: makeProject(tempDir()) });

    expect((await gd.json("bridge")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("bridge", "remove")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("bridge", "install", "--hard")).exitCode).toBe(ExitCode.Usage);
    expect((await harness({ cwd: tempDir() }).json("bridge", "status")).envelope.errors[0]?.code).toBe("NO_PROJECT");
  });
});

describe("gd doctor", () => {
  test("lists what is missing and how to fix it, without failing", async () => {
    const home = tempDir();
    const project = makeProject(home);
    const gd = harness({ homeDir: home, cwd: project, env: { PATH: "" }, addonDir: addonFixture(home) });

    const { exitCode, envelope } = await gd.json("doctor");
    const text = await gd.text("doctor");

    const checks = (envelope.data as { checks: { name: string; ok: boolean; hint?: string }[] }).checks;
    expect(exitCode).toBe(ExitCode.Success);
    expect(checks.map((check) => [check.name, check.ok])).toEqual([
      ["gd", true],
      ["godot", false],
      ["project", true],
      ["bridge", false],
      ["editor", false],
    ]);
    expect(checks[3]?.hint).toContain("gd bridge install");
    expect(envelope.data).toMatchObject({ problems: 3 });
    expect(text.out).toContain("FAIL godot");
  });

  test("is clean when Godot, the bridge and a reachable editor are all there", async () => {
    const home = tempDir();
    const project = makeProject(home);
    const godot = writeFile(join(home, "godot-bin"), "");
    await fakeBridge({ home, project });
    const gd = harness({ homeDir: home, cwd: project, env: { GODOT_BIN: godot }, addonDir: addonFixture(home) });
    await gd.json("bridge", "install");

    const { envelope } = await gd.json("doctor");

    expect(envelope.data).toMatchObject({ problems: 0 });
  });

  test("reports a missing project", async () => {
    const { envelope } = await harness({ cwd: tempDir(), env: { PATH: "" } }).json("doctor");

    expect((envelope.data as { checks: { name: string; ok: boolean }[] }).checks.find((check) => check.name === "project")?.ok).toBe(false);
  });
});

describe("gd api", () => {
  const DUMP = {
    classes: [
      {
        name: "Node",
        brief_description: "Base class for all scene objects.",
        methods: [
          { name: "queue_free", description: "Queues this node to be deleted at the end of the current frame." },
          {
            name: "add_child",
            arguments: [
              { name: "node", type: "Node" },
              { name: "force_readable_name", type: "bool", default_value: "false" },
            ],
          },
          { name: "get_node_count", is_static: true, return_value: { type: "int" } },
        ],
        signals: [{ name: "child_entered_tree", arguments: [{ name: "node", type: "Node" }], description: "Emitted when a child enters." }],
        constants: [{ name: "NOTIFICATION_READY", value: 13 }],
        enums: [{ name: "ProcessMode", values: [{ name: "PROCESS_MODE_INHERIT", value: 0 }] }],
      },
      {
        name: "Node2D",
        inherits: "CanvasItem",
        brief_description: "A 2D game object.",
        properties: [{ name: "position", type: "Vector2", description: "Position, relative to the node's parent." }],
      },
    ],
  };

  function dumping(dump: unknown, documentedFlagFails = false): (call: Call) => { code?: number } {
    return (call) => {
      const withDocs = call.args.includes("--dump-extension-api-with-docs");
      if (withDocs && documentedFlagFails) {
        return { code: 139 };
      }
      if (withDocs || call.args.includes("--dump-extension-api")) {
        writeFile(join(call.options?.cwd ?? "", "extension_api.json"), JSON.stringify(dump));
      }
      return {};
    };
  }

  function apiHarness(respond: (call: Call) => { code?: number }): { gd: ReturnType<typeof harness>; processes: ReturnType<typeof fakeProcesses>; home: string } {
    const home = tempDir();
    const godot = writeFile(join(home, "godot-bin"), "");
    const processes = fakeProcesses(respond);
    return { gd: harness({ homeDir: home, processes, env: { GODOT_BIN: godot } }), processes, home };
  }

  test("describes a class by case-insensitive name and caches the dump per version", async () => {
    const { gd, processes, home } = apiHarness(dumping(DUMP));

    const first = await gd.json("api", "class", "node2d");
    await gd.json("api", "class", "Node");

    expect(first.envelope.data).toMatchObject({
      godot_version: "4.3.stable.official.77dcf97d8",
      name: "Node2D",
      inherits: "CanvasItem",
      properties: [{ name: "position", type: "Vector2" }],
    });
    expect(processes.calls.filter((call) => call.args.includes("--dump-extension-api-with-docs"))).toHaveLength(1);
    expect(readdirSync(join(home, ".gdcli", "cache"))).toEqual([expect.stringMatching(/^api-4\.3\.stable\.official\.77dcf97d8-[0-9a-f]{16}\.json$/u)]);
  });

  test("writes signatures with defaults, static and return types", async () => {
    const { gd } = apiHarness(dumping(DUMP));

    const { envelope } = await gd.json("api", "class", "Node");
    const text = await gd.text("api", "class", "Node");

    const methods = (envelope.data as { methods: { signature: string }[] }).methods.map((method) => method.signature);
    expect(methods).toEqual([
      "queue_free() -> void",
      "add_child(node: Node, force_readable_name: bool = false) -> void",
      "static get_node_count() -> int",
    ]);
    expect(text.out).toContain("child_entered_tree(node: Node)");
    expect(text.out).toContain("ProcessMode: PROCESS_MODE_INHERIT");
  });

  test("returns the full description of one member", async () => {
    const { gd } = apiHarness(dumping(DUMP));

    expect((await gd.json("api", "class", "Node", "--member", "queue_free")).envelope.data).toMatchObject({
      kind: "method",
      signature: "queue_free() -> void",
      description: "Queues this node to be deleted at the end of the current frame.",
    });
    expect((await gd.json("api", "class", "Node2D", "--member", "position")).envelope.data).toMatchObject({ kind: "property", type: "Vector2" });
    expect((await gd.json("api", "class", "Node", "--member", "child_entered_tree")).envelope.data).toMatchObject({ kind: "signal" });
    expect((await gd.json("api", "class", "Node2D", "--member", "queue_free")).envelope.errors[0]).toMatchObject({
      code: "RESOURCE_NOT_FOUND",
      details: { inherits: "CanvasItem" },
    });
  });

  test("does not reuse the cache of a different binary that claims the same version", async () => {
    const { gd, processes, home } = apiHarness(dumping(DUMP));
    await gd.json("api", "class", "Node");
    const other = writeFile(join(home, "another-godot"), "different program");

    await gd.json("api", "class", "Node", "--godot", other);

    expect(processes.calls.filter((call) => call.args.includes("--dump-extension-api-with-docs"))).toHaveLength(2);
    expect(readdirSync(join(home, ".gdcli", "cache"))).toHaveLength(2);
  });

  test("searches classes and members, best matches first", async () => {
    const { gd } = apiHarness(dumping(DUMP));

    const { envelope } = await gd.json("api", "search", "node");

    const names = (envelope.data as { results: { name: string }[] }).results.map((result) => result.name);
    expect(names[0]).toBe("Node");
    expect(names).toContain("Node2D");
    expect(names).toContain("Node.get_node_count");
  });

  test("falls back to the plain dump and says the descriptions are missing", async () => {
    const undocumented = { classes: [{ name: "Node", methods: [{ name: "queue_free" }] }] };
    const { gd } = apiHarness(dumping(undocumented, true));

    const { exitCode, envelope } = await gd.json("api", "class", "Node");

    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.warnings[0]).toContain("descriptions are missing");
  });

  test("reports an unknown class, a failed dump and bad usage", async () => {
    expect((await apiHarness(dumping(DUMP)).gd.json("api", "class", "Nope")).envelope.errors[0]?.code).toBe("RESOURCE_NOT_FOUND");
    expect((await apiHarness(() => ({ code: 1 })).gd.json("api", "class", "Node")).envelope.errors[0]?.code).toBe("COMMAND_FAILED");
    expect((await apiHarness(dumping(DUMP)).gd.json("api", "class")).exitCode).toBe(ExitCode.Usage);
    expect((await apiHarness(dumping(DUMP)).gd.json("api", "describe", "Node")).exitCode).toBe(ExitCode.Usage);
  });

  test("discards a corrupt cache file", async () => {
    const { gd, home } = apiHarness(dumping(DUMP));
    await gd.json("api", "class", "Node");
    const [cacheFile = ""] = readdirSync(join(home, ".gdcli", "cache"));
    writeFile(join(home, ".gdcli", "cache", cacheFile), "{truncated");

    const { envelope } = await gd.json("api", "class", "Node");

    expect(envelope.errors[0]?.code).toBe("COMMAND_FAILED");
    expect(readdirSync(join(home, ".gdcli", "cache"))).toEqual([]);
  });
});
