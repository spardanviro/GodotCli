#!/usr/bin/env node
// What only a game with a window shows: that the positions game_ui reports are
// the ones a click lands on (through the window's stretch, and through a
// SubViewport shown by a container), and that screenshots are saved. The other
// tests run headless. On Linux CI this runs under xvfb with software OpenGL.
//
//   GODOT_BIN=/path/to/godot node scripts/windowed-test.mjs

import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const GD = fileURLToPath(new URL("../cli/dist/main.js", import.meta.url));
const GODOT = process.env["GODOT_BIN"];
const EDITOR_TIMEOUT_MS = 120_000;
const GAME_TIMEOUT_MS = 60_000;
const PNG = [0x89, 0x50, 0x4e, 0x47];

if (GODOT === undefined || GODOT === "") {
  process.stderr.write("Set GODOT_BIN to a Godot 4.3+ editor binary.\n");
  process.exit(2);
}

const root = mkdtempSync(join(tmpdir(), "gdcli-windowed-"));
const project = join(root, "game");
const home = join(root, "home");
const env = { ...process.env, GDCLI_HOME: home, GODOT_BIN: GODOT };
const failures = [];
let checks = 0;

function check(ok, label, detail) {
  checks += 1;
  if (!ok) {
    failures.push(`${label}: ${JSON.stringify(detail)}`);
  }
}

function gd(args) {
  const result = spawnSync(process.execPath, [GD, "--json", ...args], { cwd: project, env, encoding: "utf8", timeout: 120_000 });
  try {
    return JSON.parse(result.stdout);
  } catch {
    return { success: false, raw: `${result.stdout}\n${result.stderr}` };
  }
}

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

async function until(ask, done, ms) {
  let reply = ask();
  for (const deadline = Date.now() + ms; !done(reply) && Date.now() < deadline; ) {
    await sleep(1000);
    reply = ask();
  }
  return reply;
}

function isPng(path) {
  return existsSync(path) && PNG.every((byte, index) => readFileSync(path)[index] === byte);
}

// 640x360 drawn into a 960x540 window (stretch 1.5), a plain button, and a
// button inside a SubViewport that its container shows twice as large.
function writeProject() {
  mkdirSync(project, { recursive: true });
  mkdirSync(home, { recursive: true });
  writeFileSync(
    join(project, "project.godot"),
    [
      "config_version=5",
      "",
      "[application]",
      "",
      'config/name="windowed"',
      'run/main_scene="res://main.tscn"',
      "",
      "[display]",
      "",
      "window/size/viewport_width=640",
      "window/size/viewport_height=360",
      "window/size/window_width_override=960",
      "window/size/window_height_override=540",
      'window/stretch/mode="canvas_items"',
      "",
      "[rendering]",
      "",
      'renderer/rendering_method="gl_compatibility"',
      'renderer/rendering_method.mobile="gl_compatibility"',
      "",
    ].join("\n"),
  );
  writeFileSync(
    join(project, "main.gd"),
    "extends Control\n\nvar plain := 0\nvar inner := 0\n\n\nfunc _on_plain_pressed() -> void:\n\tplain += 1\n\n\nfunc _on_inner_pressed() -> void:\n\tinner += 1\n",
  );
  writeFileSync(
    join(project, "main.tscn"),
    `[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://main.gd" id="1"]

[node name="Main" type="Control"]
layout_mode = 3
offset_right = 640.0
offset_bottom = 360.0
script = ExtResource("1")

[node name="Plain" type="Button" parent="."]
layout_mode = 0
offset_left = 40.0
offset_top = 40.0
offset_right = 200.0
offset_bottom = 90.0
text = "Plain"

[node name="Frame" type="SubViewportContainer" parent="."]
layout_mode = 0
offset_left = 300.0
offset_top = 150.0
offset_right = 500.0
offset_bottom = 250.0
stretch = true
stretch_shrink = 2

[node name="View" type="SubViewport" parent="Frame"]
handle_input_locally = false
size = Vector2i(100, 50)
render_target_update_mode = 4

[node name="Inner" type="Button" parent="Frame/View"]
offset_left = 10.0
offset_top = 10.0
offset_right = 90.0
offset_bottom = 40.0
text = "In"

[connection signal="pressed" from="Plain" to="." method="_on_plain_pressed"]
[connection signal="pressed" from="Frame/View/Inner" to="." method="_on_inner_pressed"]
`,
  );
}

async function main() {
  writeProject();
  check(gd(["import"]).success, "import");
  check(gd(["bridge", "install", "--yes"]).success, "bridge install");
  const extra = process.platform === "linux" ? ["--rendering-driver", "opengl3"] : [];
  const editor = spawn(GODOT, ["--editor", "--path", project, ...extra, "main.tscn"], { env, stdio: ["ignore", "pipe", "pipe"] });
  const log = [];
  editor.stdout.on("data", (chunk) => log.push(String(chunk)));
  editor.stderr.on("data", (chunk) => log.push(String(chunk)));
  try {
    const status = await until(() => gd(["command", "editor_status"]), (reply) => reply.success === true, EDITOR_TIMEOUT_MS);
    check(status.success && status.data?.headless === false, "an editor with a window", status.data ?? status);
    const editorShot = gd(["command", "editor_screenshot"]);
    check(editorShot.success && isPng(editorShot.data?.path), "editor_screenshot saves a PNG", editorShot.data ?? editorShot.errors);

    check(gd(["command", "editor_play"]).success, "editor_play");
    const ui = await until(() => gd(["command", "game_ui"]), (reply) => (reply.data?.elements ?? []).some((element) => element.path.endsWith("Inner")), GAME_TIMEOUT_MS);
    const elements = ui.data?.elements ?? [];
    const plain = elements.find((element) => element.path.endsWith("Plain"));
    const inner = elements.find((element) => element.path.endsWith("Inner"));
    check(plain !== undefined && inner !== undefined, "game_ui lists both buttons", elements);
    if (plain !== undefined && inner !== undefined) {
      // The plain button is 160 wide in the viewport; the inner one 80 wide in a viewport shown 2x, so 160
      // (heights grow to the font's minimum, so widths are what is compared).
      const scale = plain.rect[2] / 160;
      check(Math.abs(inner.rect[2] - 160 * scale) < 1, "the inner button's size goes through the container's scale", { plain, inner, scale });
      const clicks = gd(["command", "game_input_events", "--events", JSON.stringify([
        { mouse_button: "left", position: plain.center, hold: 0.1 },
        { wait: 0.3 },
        { mouse_button: "left", position: inner.center, hold: 0.1 },
        { wait: 0.3 },
        // Beside each button: these must not count.
        { mouse_button: "left", position: [plain.rect[0] + plain.rect[2] + 30, plain.center[1]] },
        { wait: 0.2 },
        { mouse_button: "left", position: [inner.rect[0] - 30, inner.center[1]] },
      ])]);
      check(clicks.success, "game_input_events", clicks.errors);
      const counts = await until(
        () => gd(["command", "game_node_get", "--path", "Main", "--properties", '["plain", "inner"]']),
        (reply) => reply.data?.properties?.inner === 1 && reply.data?.properties?.plain === 1,
        10_000,
      );
      await sleep(1500);
      const settled = gd(["command", "game_node_get", "--path", "Main", "--properties", '["plain", "inner"]']).data?.properties;
      check(counts.data?.properties?.plain === 1 && counts.data?.properties?.inner === 1, "a click at each center lands on its button", counts.data?.properties);
      check(settled?.plain === 1 && settled?.inner === 1, "clicks beside the buttons land on neither", settled);
    }
    const gameShot = gd(["command", "game_screenshot"]);
    check(gameShot.success && isPng(gameShot.data?.path), "game_screenshot saves a PNG that is still there", gameShot.data ?? gameShot.errors);
    const again = gd(["command", "game_screenshot"]);
    check(isPng(gameShot.data?.path) && isPng(again.data?.path) && again.data?.path !== gameShot.data?.path, "a second picture keeps the first", [gameShot.data, again.data]);
    check(gd(["command", "editor_stop"]).success, "editor_stop");
  } catch (error) {
    failures.push(`${error instanceof Error ? error.message : String(error)}`);
  } finally {
    editor.kill();
    await sleep(1000);
    rmSync(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 500 });
  }
  if (failures.length > 0) {
    process.stdout.write(`windowed test failed (${failures.length} of ${checks} checks):\n${failures.map((failure) => `- ${failure}`).join("\n")}\n--- editor output ---\n${log.join("").slice(-6000)}\n`);
    process.exit(1);
  }
  process.stdout.write(`windowed test passed (${checks} checks)\n`);
}

await main();
