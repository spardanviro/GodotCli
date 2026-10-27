// End-to-end test of the built gd command against a real Godot editor binary.
// It is the acceptance test of roadmap phase 2: install the bridge into an
// empty project with one command and read the editor's state; run a scene
// without an editor and get its errors back in structured form.
// Usage: npm run build && GODOT_BIN=/path/to/godot node scripts/cli-e2e.mjs
// On Windows pass the *_console.exe binary.
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const GD = fileURLToPath(new URL("../cli/dist/main.js", import.meta.url));
const COMMAND_TIMEOUT_MS = 300_000;
const EDITOR_TIMEOUT_MS = 120_000;
const POLL_INTERVAL_MS = 500;
const MAX_OUTPUT_BYTES = 64 * 1024 * 1024;

const godot = process.env.GODOT_BIN;
if (godot === undefined || godot === "") {
  process.stderr.write("Set GODOT_BIN to a Godot editor binary.\n");
  process.exit(2);
}
if (!existsSync(GD)) {
  process.stderr.write("cli/dist/main.js is missing; run `npm run build` first.\n");
  process.exit(2);
}

const root = mkdtempSync(join(tmpdir(), "gdcli-e2e-"));
const project = join(root, "game");
const home = join(root, "home");
const env = { ...process.env, GDCLI_HOME: home, GODOT_BIN: godot, GDCLI_FORMAT: "" };

/** @type {string[]} */
const failures = [];
let checks = 0;

/**
 * @param {boolean} condition
 * @param {string} label
 * @param {unknown} [detail]
 */
function check(condition, label, detail) {
  checks += 1;
  if (!condition) {
    failures.push(detail === undefined ? label : `${label}: ${JSON.stringify(detail)?.slice(0, 1500)}`);
  }
}

/**
 * Runs gd with --json and returns the exit status and the parsed envelope.
 * @param {readonly string[]} args
 * @param {string} [cwd]
 */
function gd(args, cwd = project) {
  // --json goes first: anything after a literal "--" belongs to the script.
  const result = spawnSync(process.execPath, [GD, "--json", ...args], {
    cwd,
    env,
    encoding: "utf8",
    timeout: COMMAND_TIMEOUT_MS,
    maxBuffer: MAX_OUTPUT_BYTES,
  });
  let envelope = null;
  try {
    envelope = JSON.parse(result.stdout);
  } catch {
    // Reported by the caller's checks.
  }
  return { status: result.status, envelope, stdout: result.stdout, stderr: result.stderr };
}

/**
 * @param {readonly string[]} args
 */
function gdText(args) {
  return spawnSync(process.execPath, [GD, ...args], { cwd: project, env, encoding: "utf8", timeout: COMMAND_TIMEOUT_MS });
}

/** @param {number} ms */
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function writeProject() {
  mkdirSync(join(project, "scripts"), { recursive: true });
  mkdirSync(home, { recursive: true });
  writeFileSync(
    join(project, "project.godot"),
    'config_version=5\n\n[application]\n\nconfig/name="e2e game"\nrun/main_scene="res://main.tscn"\n' +
      // The game the editor starts gets --headless, so this runs without a display.
      '\n[editor]\n\nrun/main_run_args="--headless"\n',
  );
  writeFileSync(
    join(project, "calm.tscn"),
    '[gd_scene format=3]\n\n[node name="Calm" type="Node2D"]\n\n[node name="Ball" type="CharacterBody2D" parent="."]\nposition = Vector2(7, 9)\n',
  );
  writeFileSync(
    join(project, "main.tscn"),
    '[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Script" path="res://scripts/main.gd" id="1"]\n\n' +
      '[node name="Main" type="Node2D"]\nscript = ExtResource("1")\n\n[node name="Player" type="Node2D" parent="."]\n',
  );
  writeFileSync(
    join(project, "scripts", "main.gd"),
    'extends Node2D\n\n\nfunc _ready() -> void:\n\tprint("started")\n\tpush_warning("careful")\n\tvar missing: Node = null\n\tmissing.queue_free()\n',
  );
  writeFileSync(join(project, "scripts", "good.gd"), "extends Node\n\n\nfunc answer() -> int:\n\treturn 42\n");
  writeFileSync(join(project, "scripts", "bad.gd"), "extends Node\n\n\nfunc broken(:\n\tpass\n");
  writeFileSync(
    join(project, "scripts", "tool.gd"),
    'extends SceneTree\n\n\nfunc _init() -> void:\n\tprint("args=", OS.get_cmdline_user_args())\n\tquit()\n',
  );
  writeFileSync(join(root, "outside.gd"), "extends Node\n");
}

function offlineChecks() {
  const version = gdText(["--version"]);
  check(version.status === 0 && /^gd \d+\.\d+\.\d+ \(protocol 1\)/.test(version.stdout), "gd --version", version.stdout);

  const doctorBefore = gd(["doctor"]);
  const before = Object.fromEntries((doctorBefore.envelope?.data?.checks ?? []).map((entry) => [entry.name, entry.ok]));
  check(doctorBefore.status === 0 && before.godot === true && before.project === true, "doctor finds godot and the project", before);
  check(before.bridge === false && before.editor === false, "doctor reports the missing bridge", before);

  const statusBefore = gd(["status"]);
  check(statusBefore.status === 4 && statusBefore.envelope?.errors?.[0]?.code === "NO_EDITOR", "status without an editor", statusBefore.status);

  const noBridge = gd(["bridge", "status"]);
  check(noBridge.status === 4 && noBridge.envelope?.errors?.[0]?.code === "BRIDGE_NOT_INSTALLED", "bridge status before install", noBridge.status);

  const dryRun = gd(["bridge", "install", "--dry-run"]);
  check(dryRun.status === 0 && !existsSync(join(project, "addons")), "bridge install --dry-run changes nothing", dryRun.envelope?.data);

  // Acceptance, part one: one command installs and enables the bridge.
  const install = gd(["bridge", "install"]);
  check(install.status === 0 && install.envelope?.data?.enabled === true, "bridge install", install.envelope);
  check(existsSync(join(project, "addons", "gdcli", "plugin.gd")), "the addon files are in the project");
  const projectFile = readFileSync(join(project, "project.godot"), "utf8");
  check(projectFile.includes('enabled=PackedStringArray("res://addons/gdcli/plugin.cfg")'), "project.godot enables the plugin", projectFile);
  check(projectFile.includes('config/name="e2e game"'), "the rest of project.godot is untouched");
  const again = gd(["bridge", "install"]);
  check(again.status === 0 && again.envelope?.data?.actions?.length === 0, "installing twice is a no-op", again.envelope?.data);

  const imported = gd(["import"]);
  check(imported.status === 0 && imported.envelope?.success === true, "import", imported.envelope?.errors);

  const good = gd(["check", "scripts/good.gd"]);
  check(good.status === 0 && good.envelope?.data?.failed === 0, "check passes a correct script", good.envelope);

  const bad = gd(["check", "res://scripts/bad.gd", "scripts/good.gd"]);
  const badReport = bad.envelope?.data?.scripts?.[0];
  check(bad.status === 6 && bad.envelope?.success === false && bad.envelope?.data?.failed === 1, "check fails a broken script", bad.status);
  check(
    badReport?.diagnostics?.some((entry) => entry.file === "res://scripts/bad.gd" && entry.line === 4 && entry.severity === "error"),
    "check reports file and line",
    badReport,
  );
  check(bad.envelope?.data?.scripts?.[1]?.ok === true, "check still reports the good script");

  // Acceptance, part two: run a scene without an editor, get structured errors.
  const run = gd(["run", "--headless", "--seconds", "8"]);
  const diagnostics = run.envelope?.data?.diagnostics ?? [];
  check(run.status === 6 && run.envelope?.success === false, "run fails when the scene prints errors", run.status);
  check(
    diagnostics.some((entry) => entry.severity === "error" && entry.file === "res://scripts/main.gd" && entry.line === 8),
    "run locates the script error",
    diagnostics,
  );
  check(diagnostics.some((entry) => entry.severity === "warning" && /careful/.test(entry.message)), "run reports the warning", diagnostics);
  check(run.envelope?.data?.error_count >= 1 && run.envelope?.data?.warning_count >= 1, "run counts", run.envelope?.data);

  const execResult = gd(["exec", "scripts/tool.gd", "--", "--level", "3"]);
  check(execResult.status === 0 && /args=\["--level", "3"\]/.test(execResult.envelope?.data?.stdout ?? ""), "exec passes user arguments", execResult.envelope?.data);

  const notMainLoop = gd(["exec", "scripts/good.gd"]);
  check(notMainLoop.status === 4 && notMainLoop.envelope?.errors?.[0]?.code === "PRECONDITION_FAILED", "exec refuses other scripts", notMainLoop.status);

  for (const path of ["../outside.gd", "res://../outside.gd", "res://.godot/uid_cache.bin"]) {
    const escaped = gd(["check", path]);
    check(escaped.envelope?.errors?.[0]?.code === "PATH_NOT_ALLOWED", `check refuses ${path}`, escaped.envelope?.errors);
  }

  const noPreset = gd(["export", "Nope", "build/game.zip", "--pack"]);
  check(noPreset.status === 6 && noPreset.envelope?.errors?.[0]?.code === "RESOURCE_NOT_FOUND", "export refuses an unknown preset", noPreset.envelope?.errors);

  const api = gd(["api", "class", "node2d"]);
  check(api.status === 0 && api.envelope?.data?.name === "Node2D" && api.envelope?.data?.inherits === "CanvasItem", "api class", api.envelope?.errors);
  check(api.envelope?.data?.properties?.some((entry) => entry.name === "position" && entry.type === "Vector2"), "api class lists properties");
  const member = gd(["api", "class", "Node", "--member", "queue_free"]);
  check(member.envelope?.data?.kind === "method" && member.envelope?.data?.signature === "queue_free() -> void", "api member", member.envelope?.data);
  // A build that cannot export its documentation says so instead of failing.
  const documented = (member.envelope?.warnings ?? []).length === 0;
  check(!documented || member.envelope?.data?.description?.length > 0, "api member docs", member.envelope?.data);
  const search = gd(["api", "search", "move_and_slide"]);
  check(search.envelope?.data?.results?.[0]?.name === "CharacterBody2D.move_and_slide" || search.envelope?.data?.results?.[0]?.name === "CharacterBody3D.move_and_slide", "api search", search.envelope?.data?.results?.slice(0, 3));

  const unknown = gd(["frobnicate"]);
  check(unknown.status === 2 && unknown.envelope?.errors?.[0]?.code === "UNKNOWN_COMMAND", "unknown command", unknown.status);

  const outside = gd(["status"], root);
  check(outside.status === 4 && outside.envelope?.errors?.[0]?.code === "NO_EDITOR", "status outside a project", outside.envelope?.errors);
}

async function waitForEditor() {
  const deadline = Date.now() + EDITOR_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const status = gd(["status"]);
    if (status.status === 0 && status.envelope?.data?.editors?.[0]?.state === "ready") {
      return status;
    }
    await sleep(POLL_INTERVAL_MS);
  }
  throw new Error("the editor did not become reachable");
}

async function waitForScene() {
  const deadline = Date.now() + EDITOR_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const status = gd(["command", "editor_status"]);
    if (status.envelope?.data?.scene === "res://main.tscn") {
      return status;
    }
    await sleep(POLL_INTERVAL_MS);
  }
  throw new Error("the scene did not open in the editor");
}

async function liveChecks() {
  /** @type {string[]} */
  const log = [];
  const editor = spawn(godot, ["--headless", "--editor", "--path", project, "res://main.tscn"], { env, stdio: ["ignore", "pipe", "pipe"] });
  editor.stdout.on("data", (chunk) => log.push(String(chunk)));
  editor.stderr.on("data", (chunk) => log.push(String(chunk)));
  try {
    const status = await waitForEditor();
    const entry = status.envelope.data.editors[0];
    check(entry.project_name === "e2e game" && entry.headless === true, "status describes the editor", entry);
    check(!status.stdout.includes("token") && !/[0-9a-f]{64}/.test(status.stdout), "status never prints the token");

    const editorStatus = await waitForScene();
    check(editorStatus.envelope.meta?.scene === "res://main.tscn", "editor_status through gd", editorStatus.envelope.meta);

    const list = gd(["list"]);
    const names = (list.envelope?.data?.commands ?? []).map((command) => command.name);
    check(list.status === 0 && names.includes("scene_tree") && names.includes("node_create"), "list", names);

    const tree = gd(["command", "scene_tree", "--max-depth", "1"]);
    check(tree.status === 0 && tree.envelope?.data?.tree?.name === "Main", "command scene_tree", tree.envelope);
    check(tree.envelope?.data?.tree?.children?.[0]?.path === "Player", "scene_tree children");

    const node = gd(["command", "node_get", "--path", "Player", "--properties", '["position"]']);
    check(node.envelope?.data?.properties?.position?.$type === "Vector2", "command with a JSON array argument", node.envelope);

    const viaJson = gd(["cmd", "node_find", "--args", '{"type":"Node2D","limit":1}']);
    check(viaJson.envelope?.data?.nodes?.length === 1 && viaJson.envelope?.data?.truncated === true, "command with --args", viaJson.envelope);

    const missing = gd(["command", "node_get", "--path", "Ghost"]);
    check(missing.status === 6 && missing.envelope?.errors?.[0]?.code === "NODE_NOT_FOUND", "bridge errors keep their exit code", missing.status);

    const badArgs = gd(["command", "scene_tree", "--max-depth", "deep"]);
    check(badArgs.status === 2 && badArgs.envelope?.errors?.[0]?.code === "INVALID_ARGS", "invalid arguments", badArgs.status);

    const unknown = gd(["command", "no_such_command"]);
    check(unknown.status === 2 && unknown.envelope?.errors?.[0]?.code === "UNKNOWN_COMMAND", "unknown bridge command", unknown.status);

    const human = gdText(["command", "scene_list_open"]);
    check(human.status === 0 && human.stdout.includes("res://main.tscn"), "human output", human.stdout);

    await lookIntoTheRunningGame();

    const doctor = gd(["doctor"]);
    check(doctor.envelope?.data?.problems === 0, "doctor is clean with the editor running", doctor.envelope?.data);

    check(!/SCRIPT ERROR.*addons\/gdcli/s.test(log.join("")), "the bridge reported no script errors");
  } catch (error) {
    failures.push(`${error instanceof Error ? error.message : String(error)}\n--- editor output ---\n${log.join("").slice(-3000)}`);
  } finally {
    const exited = new Promise((resolve) => editor.once("exit", resolve));
    if (process.platform === "win32" && editor.pid !== undefined) {
      spawnSync("taskkill", ["/pid", String(editor.pid), "/T", "/F"], { stdio: "ignore" });
    } else {
      editor.kill();
    }
    await Promise.race([exited, sleep(5000)]);
  }
}

const GAME_START_TIMEOUT_MS = 60_000;

/**
 * `gd bridge install` registered the helper autoload, so a game started from
 * the editor can be inspected with nothing but gd.
 */
async function lookIntoTheRunningGame() {
  const projectFile = readFileSync(join(project, "project.godot"), "utf8");
  check(projectFile.includes('GdcliGame="*res://addons/gdcli/runtime/game_agent.gd"'), "bridge install registered the game helper", projectFile);

  const played = gd(["command", "editor_play", "--scene", "res://calm.tscn"]);
  check(played.status === 0, "editor_play", played.envelope);
  let tree = gd(["command", "game_tree", "--max-depth", "2"]);
  for (const deadline = Date.now() + GAME_START_TIMEOUT_MS; tree.status !== 0 && Date.now() < deadline; ) {
    await sleep(500);
    tree = gd(["command", "game_tree", "--max-depth", "2"]);
  }
  const top = tree.envelope?.data?.tree?.children?.map((child) => child.path) ?? [];
  check(tree.status === 0 && top.includes("Calm"), "game_tree through gd", tree.envelope);

  const moved = gd(["command", "game_node_set", "--path", "Calm/Ball", "--properties", '{"velocity":[3,4]}']);
  const ball = gd(["command", "game_node_get", "--path", "Calm/Ball", "--properties", '["position","velocity"]']);
  check(moved.status === 0, "game_node_set through gd", moved.envelope);
  check(JSON.stringify(ball.envelope?.data?.properties?.velocity?.value) === "[3,4]", "game_node_get through gd", ball.envelope);

  const stopped = gd(["command", "editor_stop"]);
  check(stopped.status === 0, "editor_stop", stopped.envelope);
  let status = gd(["command", "editor_status"]);
  for (const deadline = Date.now() + 10_000; status.envelope?.data?.playing !== false && Date.now() < deadline; ) {
    await sleep(200);
    status = gd(["command", "editor_status"]);
  }
  check(status.envelope?.data?.playing === false, "the game stopped", status.envelope?.data);
}

const ENEMY_SCRIPT = "extends CharacterBody2D\n\n\nfunc _ready() -> void:\n\tvar target: Node = null\n\ttarget.queue_free()\n";

/**
 * Acceptance test of roadmap phase 3: with nothing but gd, build a scene with
 * a script, undo a step, save, then run it and get the script's error back.
 * The editor is a headless host that gd starts and stops itself.
 */
async function buildSceneFromTheCommandLine() {
  let hostPid;
  try {
    const started = gd(["host", "start", "--wait", "120"]);
    hostPid = started.envelope?.data?.pid;
    check(started.status === 0 && started.envelope?.data?.started === true && started.envelope?.data?.headless === true, "host start", started.envelope);

    // The way the plugin's skills send a script: from a file outside the project.
    const draft = join(root, "enemy_draft.gd");
    writeFileSync(draft, ENEMY_SCRIPT);
    const script = gd(["command", "fs_write_text", "--path", "res://scripts/enemy.gd", "--text-file", draft]);
    check(script.status === 0 && script.envelope?.data?.created === true, "write a script from a file", script.envelope);
    const written = gd(["command", "fs_read_text", "--path", "res://scripts/enemy.gd"]);
    check(written.envelope?.data?.text === ENEMY_SCRIPT, "with the text of that file", written.envelope);

    const scene = gd(["command", "scene_new", "--path", "res://levels/level.tscn", "--root-type", "Node2D"]);
    check(scene.status === 0 && scene.envelope?.data?.scene === "res://levels/level.tscn", "create a scene", scene.envelope);

    const node = gd(["command", "node_create", "--type", "CharacterBody2D", "--name", "Enemy", "--properties", '{"position":[10,20]}']);
    check(node.status === 0 && node.envelope?.meta?.undo === "gdcli: node_create Enemy", "create a node", node.envelope);
    check(node.envelope?.meta?.scene === "res://levels/level.tscn", "the envelope names the scene that was changed", node.envelope?.meta);

    const attached = gd(["command", "node_attach_script", "--path", "Enemy", "--script", "res://scripts/enemy.gd"]);
    check(attached.status === 0, "attach the script", attached.envelope);

    gd(["command", "node_set", "--path", "Enemy", "--properties", '{"position":[99,99]}']);
    const undone = gd(["command", "edit_undo"]);
    const position = gd(["command", "node_get", "--path", "Enemy", "--properties", '["position"]']);
    check(undone.envelope?.data?.undone === "gdcli: node_set Enemy", "undo a step", undone.envelope);
    check(JSON.stringify(position.envelope?.data?.properties?.position?.value) === "[10,20]", "the undone change is gone", position.envelope?.data);

    const dryRun = gd(["command", "node_delete", "--path", "Enemy", "--dry-run"]);
    const stillThere = gd(["command", "node_get", "--path", "Enemy", "--properties", "[]"]);
    check(dryRun.envelope?.data?.dry_run === true && stillThere.status === 0, "--dry-run deletes nothing", dryRun.envelope);

    const saved = gd(["command", "scene_save"]);
    check(saved.status === 0 && existsSync(join(project, "levels", "level.tscn")), "save the scene", saved.envelope);

    const refused = gd(["command", "fs_delete", "--path", "res://scripts/good.gd"]);
    check(refused.status === 4 && refused.envelope?.errors?.[0]?.code === "CONFIRMATION_REQUIRED", "a destructive command asks first", refused.status);
    const confirmed = gd(["command", "fs_delete", "--path", "res://scripts/good.gd", "--yes"]);
    check(confirmed.status === 0 && !existsSync(join(project, "scripts", "good.gd")), "and runs with --yes", confirmed.envelope);

    const evaluated = gd(["eval", "return 1", "--yes"]);
    check(evaluated.status === 4 && evaluated.envelope?.errors?.[0]?.code === "EVAL_DISABLED", "eval is off unless enabled", evaluated.envelope?.errors);

    const stopped = gd(["host", "stop"]);
    check(stopped.status === 0 && stopped.envelope?.data?.quitting === true, "host stop", stopped.envelope);
    const deadline = Date.now() + 30_000;
    let gone = false;
    while (!gone && Date.now() < deadline) {
      await sleep(POLL_INTERVAL_MS);
      gone = gd(["status"]).envelope?.errors?.[0]?.code === "NO_EDITOR";
    }
    check(gone, "the host is gone after host stop");
    if (gone) {
      hostPid = undefined;
    }

    // The scene built above, run without any editor.
    const run = gd(["run", "levels/level.tscn", "--headless", "--seconds", "8"]);
    const diagnostics = run.envelope?.data?.diagnostics ?? [];
    check(run.status === 6, "the built scene runs and its error is reported", run.status);
    check(
      diagnostics.some((entry) => entry.severity === "error" && entry.file === "res://scripts/enemy.gd" && entry.line === 6),
      "the error points at the script line",
      diagnostics,
    );
  } catch (error) {
    failures.push(error instanceof Error ? error.message : String(error));
  } finally {
    if (hostPid !== undefined) {
      if (process.platform === "win32") {
        spawnSync("taskkill", ["/pid", String(hostPid), "/T", "/F"], { stdio: "ignore" });
      } else {
        try {
          process.kill(hostPid, "SIGKILL");
        } catch {
          // Already gone.
        }
      }
    }
  }
}

/**
 * Interrupted (Ctrl-C, a CI timeout): every editor this test started is
 * stopped before it exits. Each editor writes its pid into the test's own
 * GDCLI_HOME, so those files name them all, including gd host start's.
 */
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => {
    const folder = join(home, "instances");
    for (const name of existsSync(folder) ? readdirSync(folder) : []) {
      try {
        killTree(JSON.parse(readFileSync(join(folder, name), "utf8")).pid);
      } catch {
        // Not a lock file, or already gone.
      }
    }
    process.exit(130);
  });
}

/** @param {number | undefined} pid */
function killTree(pid) {
  if (pid === undefined) {
    return;
  }
  if (process.platform === "win32") {
    spawnSync("taskkill", ["/pid", String(pid), "/T", "/F"], { stdio: "ignore" });
    return;
  }
  try {
    process.kill(pid, "SIGKILL");
  } catch {
    // Already gone.
  }
}

/** @param {number} pid */
function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/**
 * An editor whose lock file is gone may still be exiting, holding the
 * project's files for a few seconds (on Windows they cannot be removed).
 * @param {readonly (number | undefined)[]} pids
 */
async function waitUntilExited(pids, ms = 30_000) {
  for (const deadline = Date.now() + ms; pids.some((pid) => pid !== undefined && isAlive(pid)) && Date.now() < deadline; ) {
    await sleep(POLL_INTERVAL_MS);
  }
}

/**
 * @param {readonly string[]} args
 * @param {(result: ReturnType<typeof gd>) => boolean} done
 */
async function waitFor(args, done, ms = EDITOR_TIMEOUT_MS) {
  let result = gd(args);
  for (const deadline = Date.now() + ms; !done(result) && Date.now() < deadline; ) {
    await sleep(POLL_INTERVAL_MS);
    result = gd(args);
  }
  return result;
}

/**
 * Several editors on one machine (roadmap phase 6): one per project, each
 * reached through its own project; then a second editor on the same project,
 * started the way a person would (no ports of gd's choosing), which makes gd
 * ask which one, and --instance answers.
 */
async function severalEditors() {
  const other = join(root, "other");
  mkdirSync(other, { recursive: true });
  writeFileSync(join(other, "project.godot"), 'config_version=5\n\n[application]\n\nconfig/name="other game"\n');
  const pids = [];
  /** Hosts that quit when asked: waited for, not killed. */
  const stopped = [];
  /** @type {import("node:child_process").ChildProcess | undefined} */
  let second;
  /** @type {number | undefined} */
  let secondPid;
  try {
    const installed = gd(["bridge", "install", "--project", other]);
    check(installed.status === 0, "bridge install in a second project", installed.envelope);
    for (const folder of [project, other]) {
      const started = gd(["host", "start", "--project", folder, "--wait", "120"]);
      pids.push(started.envelope?.data?.pid);
      check(started.status === 0 && started.envelope?.data?.started === true, `host start in ${folder}`, started.envelope);
    }

    const everywhere = gd(["status"], root);
    const ready = (everywhere.envelope?.data?.editors ?? []).filter((editor) => editor.state === "ready");
    check(ready.length === 2, "gd status outside a project lists both editors", everywhere.envelope);
    const first = gd(["command", "editor_status", "--project", project]);
    const third = gd(["command", "editor_status", "--project", other]);
    check(first.status === 0 && third.status === 0 && first.envelope?.meta?.instance_id !== third.envelope?.meta?.instance_id, "each project reaches its own editor", [first.envelope?.meta, third.envelope?.meta]);
    const again = gd(["host", "start", "--project", project]);
    check(again.status === 0 && again.envelope?.data?.started === false, "host start again finds the running one", again.envelope);

    // A second editor on the same project, as when someone opens it by hand.
    // With gd's environment, so its lock file lands in this test's GDCLI_HOME.
    second = spawn(godot, ["--headless", "--editor", "--path", project], { env, stdio: "ignore" });
    const ambiguous = await waitFor(["command", "editor_status", "--project", project], (result) => result.envelope?.errors?.[0]?.code === "MULTIPLE_EDITORS");
    const listed = ambiguous.envelope?.errors?.[0]?.details?.instances ?? [];
    check(ambiguous.envelope?.errors?.[0]?.code === "MULTIPLE_EDITORS" && listed.length === 2, "two editors on one project: gd asks which", ambiguous.envelope);
    // The editor's own process; on Windows the *_console.exe that was started is only its wrapper.
    const chosen = listed.find((editor) => !pids.includes(editor.pid));
    secondPid = chosen?.pid;
    const picked = gd(["command", "editor_status", "--project", project, "--instance", String(chosen?.instance_id)]);
    check(picked.status === 0 && picked.envelope?.meta?.instance_id === chosen?.instance_id, "--instance picks one", picked.envelope);

    killTree(secondPid);
    killTree(second.pid);
    stopped.push(secondPid, second.pid);
    second = undefined;
    secondPid = undefined;
    const single = await waitFor(["command", "editor_status", "--project", project], (result) => result.status === 0, 30_000);
    check(single.status === 0, "once it is gone, the project has one editor again", single.envelope);

    for (const folder of [project, other]) {
      const quit = gd(["host", "stop", "--project", folder]);
      check(quit.status === 0, `host stop in ${folder}`, quit.envelope);
    }
    const none = await waitFor(["status"], (result) => result.envelope?.errors?.[0]?.code === "NO_EDITOR", 30_000);
    check(none.envelope?.errors?.[0]?.code === "NO_EDITOR", "both hosts are gone", none.envelope);
    if (none.envelope?.errors?.[0]?.code === "NO_EDITOR") {
      stopped.push(...pids.splice(0));
    }
  } catch (error) {
    failures.push(error instanceof Error ? error.message : String(error));
  } finally {
    killTree(secondPid);
    killTree(second?.pid);
    pids.forEach(killTree);
    await waitUntilExited([secondPid, second?.pid, ...pids, ...stopped]);
  }
}

try {
  writeProject();
  offlineChecks();
  await liveChecks();
  await buildSceneFromTheCommandLine();
  await severalEditors();
} finally {
  // An editor that was just stopped may still hold files for a few seconds.
  try {
    rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 500 });
  } catch (error) {
    process.stderr.write(`could not remove ${root}: ${error instanceof Error ? error.message : String(error)}\n`);
  }
}

if (failures.length > 0) {
  // On GitHub, failures also become annotations, which can be read without
  // access to the full log.
  if (process.env.GITHUB_ACTIONS === "true") {
    for (const failure of failures) {
      const message = failure.slice(0, 3000).replaceAll("%", "%25").replaceAll("\r", "%0D").replaceAll("\n", "%0A");
      process.stdout.write(`::error title=cli end-to-end::${message}\n`);
    }
  }
  process.stderr.write(`cli end-to-end test failed (${failures.length} of ${checks} checks):\n- ${failures.join("\n- ")}\n`);
  process.exit(1);
}
process.stdout.write(`cli end-to-end test passed (${checks} checks)\n`);
