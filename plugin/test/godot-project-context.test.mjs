import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, describe, test } from "node:test";
import { fileURLToPath } from "node:url";

import { contextFor, nearestProject } from "../hooks/godot-project-context.mjs";

const HOOK = join(dirname(fileURLToPath(import.meta.url)), "..", "hooks", "godot-project-context.mjs");
const folders = [];

after(() => {
  for (const folder of folders) {
    rmSync(folder, { recursive: true, force: true });
  }
});

function workspace({ bridge = true } = {}) {
  const root = mkdtempSync(join(tmpdir(), "gdcli-context-"));
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

describe("godot-project-context", () => {
  test("finds the project from its folder or one below it", () => {
    const { root, project } = workspace();

    assert.equal(nearestProject(project), project);
    assert.equal(nearestProject(join(project, "scripts")), project);
    assert.equal(nearestProject(root), null);
  });

  test("tells a session in a Godot project to use the godot-cli skill and gd", () => {
    const { project } = workspace();

    const context = contextFor({ hook_event_name: "SessionStart", cwd: join(project, "scripts") });

    assert.equal(context?.hookSpecificOutput.hookEventName, "SessionStart");
    assert.match(context?.hookSpecificOutput.additionalContext ?? "", /godot-cli skill/u);
    assert.match(context?.hookSpecificOutput.additionalContext ?? "", /bridge is installed/u);
  });

  test("names gd bridge install when the bridge is missing", () => {
    const { project } = workspace({ bridge: false });

    assert.match(contextFor({ cwd: project })?.hookSpecificOutput.additionalContext ?? "", /gd bridge install/u);
  });

  test("says nothing outside a Godot project", () => {
    const { root } = workspace();

    assert.equal(contextFor({ cwd: root }), null);
  });

  test("runs as a hook: JSON on standard output inside a project, nothing outside", () => {
    const { root, project } = workspace();
    const run = (cwd) => spawnSync(process.execPath, [HOOK], { input: JSON.stringify({ hook_event_name: "SessionStart", cwd }), encoding: "utf8" });

    const inside = run(project);
    const outside = run(root);

    assert.equal(inside.status, 0);
    assert.equal(JSON.parse(inside.stdout).hookSpecificOutput.hookEventName, "SessionStart");
    assert.equal(outside.status, 0);
    assert.equal(outside.stdout, "");
  });
});
