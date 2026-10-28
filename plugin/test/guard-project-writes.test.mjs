import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { linkSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, describe, test } from "node:test";
import { fileURLToPath } from "node:url";

import { decide, findProjectRoots, isGuardedRelativePath, isGuardedWrite } from "../hooks/guard-project-writes.mjs";

const HOOK = join(dirname(fileURLToPath(import.meta.url)), "..", "hooks", "guard-project-writes.mjs");
const folders = [];

after(() => {
  for (const folder of folders) {
    rmSync(folder, { recursive: true, force: true });
  }
});

/** A folder with a Godot project in `game`, with or without the bridge. */
function workspace({ bridge = true } = {}) {
  const root = mkdtempSync(join(tmpdir(), "gdcli-guard-"));
  folders.push(root);
  const project = join(root, "game");
  mkdirSync(join(project, "scripts"), { recursive: true });
  writeFileSync(join(project, "project.godot"), "config_version=5\n");
  if (bridge) {
    mkdirSync(join(project, "addons", "gdcli"), { recursive: true });
    writeFileSync(join(project, "addons", "gdcli", "plugin.cfg"), "[plugin]\n");
  }
  return { root, project };
}

function writeEvent(filePath, cwd, tool = "Write") {
  return { hook_event_name: "PreToolUse", tool_name: tool, tool_input: { file_path: filePath, content: "x" }, cwd };
}

describe("isGuardedRelativePath", () => {
  test("guards Claude Code's settings and MCP servers of the folder", () => {
    for (const path of [".mcp.json", ".claude/settings.json", "sub/.claude/settings.local.json", ".claude"]) {
      assert.equal(isGuardedRelativePath(path), true, path);
    }
    assert.equal(isGuardedRelativePath("docs/claude.md"), false);
  });

  test("guards what a .NET build reads by name", () => {
    for (const path of ["Game.csproj.user", "Directory.Build.rsp", "NuGet.Config", "global.json", ".config/dotnet-tools.json", "Game.slnx"]) {
      assert.equal(isGuardedRelativePath(path), true, path);
    }
  });

  test("guards scripts, scenes and resources anywhere in the project", () => {
    for (const path of ["player.gd", "scripts/player.gd", "scenes/main.tscn", "data/item.tres", "a/b/c.SCN", "x.res", "bin/lib.gdextension", "Game.csproj", "models/crate.glb.import", "src/Player.cs"]) {
      assert.equal(isGuardedRelativePath(path), true, path);
    }
  });

  test("guards the files and folders the editor loads from", () => {
    for (const path of ["project.godot", "PROJECT.GODOT", "override.cfg", "export_presets.cfg", "addons/x/readme.md", "Addons/x.txt", "gdcli_commands/a.txt", ".godot/extension_list.cfg"]) {
      assert.equal(isGuardedRelativePath(path), true, path);
    }
  });

  test("leaves everything else alone", () => {
    for (const path of ["README.md", "notes/design.md", "art/player.png", "shaders/water.gdshader", "data/levels.json", "docs/project.godot", "tools/build.py", ""]) {
      assert.equal(isGuardedRelativePath(path), false, path);
    }
  });

  test("is not fooled by names Windows treats as the same file", () => {
    assert.equal(isGuardedRelativePath("scripts\\player.gd"), true);
    assert.equal(isGuardedRelativePath("scripts/player.gd."), true);
    assert.equal(isGuardedRelativePath("scripts/player.gd "), true);
    assert.equal(isGuardedRelativePath("scripts/player.gd:stream"), true);
    assert.equal(isGuardedRelativePath("project.godot."), true);
    assert.equal(isGuardedRelativePath("project.godot::$DATA"), true);
    assert.equal(isGuardedRelativePath("override.cfg:x"), true);
    assert.equal(isGuardedRelativePath("addons::$INDEX_ALLOCATION/x.txt"), true);
  });
});

describe("isGuardedWrite", () => {
  test("refuses a script of a project that has the bridge, by absolute or relative path", () => {
    const { project } = workspace();

    assert.equal(isGuardedWrite(join(project, "scripts", "player.gd"), project), true);
    assert.equal(isGuardedWrite("scripts/player.gd", project), true);
    assert.equal(isGuardedWrite("../project.godot", join(project, "scripts")), true);
    assert.equal(isGuardedWrite(join(project, "new_folder", "deep", "enemy.gd"), project), true);
  });

  test("allows other files of that project and files outside it", () => {
    const { root, project } = workspace();

    assert.equal(isGuardedWrite(join(project, "README.md"), project), false);
    assert.equal(isGuardedWrite(join(root, "scratch", "player.gd"), project), false);
    assert.equal(isGuardedWrite(join(tmpdir(), "draft-player.gd"), project), false);
  });

  test("is not hidden by a project file in a subfolder", () => {
    const { project } = workspace();
    mkdirSync(join(project, "sub"), { recursive: true });
    writeFileSync(join(project, "sub", "project.godot"), "config_version=5\n");

    assert.equal(isGuardedWrite(join(project, "sub", "sneaky.gd"), project), true);
    assert.equal(isGuardedWrite(join(project, "sub", "notes.md"), project), false);
  });

  test("leaves a project without the bridge alone", () => {
    const { project } = workspace({ bridge: false });

    assert.equal(isGuardedWrite(join(project, "scripts", "player.gd"), project), false);
    assert.equal(isGuardedWrite(join(project, "project.godot"), project), false);
  });

  test("sees through a link that points into the project", (context) => {
    const { root, project } = workspace();
    const link = join(root, "shortcut");
    try {
      symlinkSync(join(project, "scripts"), link, "junction");
    } catch {
      context.skip("links cannot be created here");
      return;
    }

    assert.equal(isGuardedWrite(join(link, "player.gd"), root), true);
  });
});

describe("gd's and the editor's settings", () => {
  test("the editor settings (access mode, eval) and gd's config.json are held wherever they are", () => {
    const { root } = workspace();
    const home = join(root, "gdcli-home");
    const before = process.env["GDCLI_HOME"];
    process.env["GDCLI_HOME"] = home;
    try {
      assert.equal(isGuardedWrite(join(root, "config", "godot", "editor_settings-4.5.tres"), root), true);
      assert.equal(isGuardedWrite(join(home, "config.json"), root), true);
      assert.equal(isGuardedWrite(join(root, "some", "config.json"), root), false, "another program's config.json");
    } finally {
      if (before === undefined) {
        delete process.env["GDCLI_HOME"];
      } else {
        process.env["GDCLI_HOME"] = before;
      }
    }
  });

  test("the sandbox example runs nothing that starts Godot outside the sandbox, and keeps those files read-only", () => {
    const example = JSON.parse(readFileSync(join(dirname(HOOK), "..", "sandbox-settings.example.json"), "utf8"));
    const excluded = example.sandbox.excludedCommands.join(" ");
    const denied = example.sandbox.filesystem.denyWrite;

    for (const starter of ["doctor", "api", "run", "check", "exec", "import", "export", "host"]) {
      assert.equal(excluded.includes(`gd ${starter}`), false, starter);
    }
    for (const file of ["~/.gdcli/config.json", "~/.gdcli/instances", "~/.config/godot/editor_settings-4.7.tres"]) {
      assert.equal(denied.includes(file), true, file);
    }
  });
});

describe("hard links", () => {
  test("a file with a second name is held wherever it is: it may be a project file", () => {
    const { root, project } = workspace();
    const inside = join(project, "scripts", "player.gd");
    writeFileSync(inside, "extends Node\n");
    const outside = join(root, "innocent.txt");
    linkSync(inside, outside);
    const plain = join(root, "plain.txt");
    writeFileSync(plain, "x");

    assert.equal(isGuardedWrite(outside, root), true, "the project's script under another name");
    assert.equal(isGuardedWrite(plain, root), false, "an ordinary file has one name");
    assert.equal(isGuardedWrite(join(root, "new.txt"), root), false, "a new file has none yet");
  });
});

describe("findProjectRoots", () => {
  test("finds the projects above a folder that may not exist yet, nearest first", () => {
    const { root, project } = workspace();
    mkdirSync(join(project, "sub"), { recursive: true });
    writeFileSync(join(project, "sub", "project.godot"), "config_version=5\n");

    assert.deepEqual(findProjectRoots(join(project, "scripts")), [project]);
    assert.deepEqual(findProjectRoots(join(project, "not", "there")), [project]);
    assert.deepEqual(findProjectRoots(join(project, "sub", "deeper")), [join(project, "sub"), project]);
    assert.equal(findProjectRoots(root).includes(project), false);
  });
});

describe("decide", () => {
  test("denies with a fixed reason that names the command to use instead", () => {
    const { project } = workspace();

    const decision = decide(writeEvent(join(project, "scripts", "player.gd"), project), {});

    assert.equal(decision?.hookSpecificOutput.permissionDecision, "deny");
    assert.match(decision?.hookSpecificOutput.permissionDecisionReason ?? "", /gd command fs_write_text --path res:\/\/<path> --text-file/u);
    assert.match(decision?.hookSpecificOutput.permissionDecisionReason ?? "", /--overwrite true --yes/u);
    assert.equal((decision?.hookSpecificOutput.permissionDecisionReason ?? "").includes(project), false);
  });

  test("covers every file-writing tool", () => {
    const { project } = workspace();
    const target = join(project, "scripts", "player.gd");

    assert.notEqual(decide(writeEvent(target, project, "Edit"), {}), null);
    assert.notEqual(decide(writeEvent(target, project, "MultiEdit"), {}), null);
    assert.notEqual(decide({ tool_name: "NotebookEdit", tool_input: { notebook_path: join(project, "addons", "x.ipynb") }, cwd: project }, {}), null);
  });

  test("says nothing about anything else", () => {
    const { project } = workspace();

    assert.equal(decide(writeEvent(join(project, "README.md"), project), {}), null);
    assert.equal(decide({ tool_name: "Write", tool_input: {}, cwd: project }, {}), null);
    assert.equal(decide({ tool_name: "Write" }, {}), null);
    assert.equal(decide(null, {}), null);
    assert.equal(decide("text", {}), null);
  });

  test("steps aside when the user has set the override variable", () => {
    const { project } = workspace();
    const event = writeEvent(join(project, "scripts", "player.gd"), project);

    assert.equal(decide(event, { GDCLI_ALLOW_DIRECT_WRITES: "1" }), null);
    assert.notEqual(decide(event, { GDCLI_ALLOW_DIRECT_WRITES: "0" }), null);
  });
});

describe("hooks.json", () => {
  test("runs the guard as one command line, which every Claude Code version understands", () => {
    const configuration = JSON.parse(readFileSync(join(dirname(HOOK), "hooks.json"), "utf8"));
    const [group, shell] = configuration.hooks.PreToolUse;

    assert.equal(group.matcher, "Write|Edit|MultiEdit|NotebookEdit");
    assert.deepEqual(Object.keys(group.hooks[0]).sort(), ["command", "onFailure", "timeout", "type"]);
    assert.equal(group.hooks[0].command, 'node "${CLAUDE_PLUGIN_ROOT}/hooks/guard-project-writes.mjs"');
    assert.equal(shell.matcher, "Bash|PowerShell");
    assert.equal(shell.hooks[0].command, 'node "${CLAUDE_PLUGIN_ROOT}/hooks/guard-shell-writes.mjs"');
  });
});

describe("the hook as a process", () => {
  function runHook(input) {
    const environment = { ...process.env };
    delete environment["GDCLI_ALLOW_DIRECT_WRITES"];
    return spawnSync(process.execPath, [HOOK], { input, encoding: "utf8", env: environment });
  }

  test("prints a deny decision for a guarded file and exits with 0", () => {
    const { project } = workspace();

    const result = runHook(JSON.stringify(writeEvent(join(project, "project.godot"), project)));

    assert.equal(result.status, 0);
    assert.equal(JSON.parse(result.stdout).hookSpecificOutput.permissionDecision, "deny");
  });

  test("prints nothing for a file it does not guard, or for input it does not understand", () => {
    const { project } = workspace();

    const allowed = runHook(JSON.stringify(writeEvent(join(project, "notes.md"), project)));
    const garbage = runHook("not json");

    assert.deepEqual([allowed.status, allowed.stdout], [0, ""]);
    assert.deepEqual([garbage.status, garbage.stdout], [0, ""]);
  });
});
