// Tests the bridge addon against a real Godot editor binary:
//   1. unit suites in bridge/tests/unit (no editor needed)
//   2. end to end: start a headless editor, find it through its instance file,
//      do the handshake and exercise the HTTP API.
// Usage: GODOT_BIN=/path/to/godot node scripts/bridge-test.mjs
//    or: node scripts/bridge-test.mjs --godot /path/to/godot
// On Windows pass the *_console.exe binary; the GUI one does not write to pipes.
import { spawn, spawnSync } from "node:child_process";
import { createHmac, randomBytes } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

import { COMMANDS_FILE, renderCommands } from "./plugin-commands.mjs";

const STEP_TIMEOUT_MS = 180_000;
const STARTUP_TIMEOUT_MS = 120_000;
const SCENE_TIMEOUT_MS = 60_000;
const REQUEST_TIMEOUT_MS = 10_000;
const POLL_INTERVAL_MS = 200;
// The default of 1 MiB turns a chatty import into a spurious ENOBUFS failure.
const MAX_OUTPUT_BYTES = 64 * 1024 * 1024;
const LOOPBACK = "127.0.0.1";
const FIXTURE_SCENE = "res://tests/fixtures/main.tscn";

const projectDir = fileURLToPath(new URL("../bridge/", import.meta.url));

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
    failures.push(detail === undefined ? label : `${label}: ${JSON.stringify(detail)}`);
  }
}

/** @param {number} ms */
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * @param {string} godot
 * @param {readonly string[]} args
 */
function runGodot(godot, args) {
  const result = spawnSync(godot, ["--headless", "--path", projectDir, ...args], {
    encoding: "utf8",
    timeout: STEP_TIMEOUT_MS,
    maxBuffer: MAX_OUTPUT_BYTES,
  });
  if (result.error !== undefined) {
    throw new Error(`godot ${args.join(" ")} did not finish: ${result.error.message}`);
  }
  return { output: `${result.stdout ?? ""}${result.stderr ?? ""}`, status: result.status };
}

/**
 * @typedef {{ status: number, headers: http.IncomingHttpHeaders, body: any, raw: string }} Response
 * @param {number} port
 * @param {{ method?: string, path: string, headers?: Record<string, string>, body?: string }} options
 * @returns {Promise<Response>}
 */
function request(port, { method = "GET", path, headers = {}, body }) {
  return new Promise((resolve, reject) => {
    const allHeaders = { ...headers };
    if (body !== undefined) {
      allHeaders["Content-Length"] = String(Buffer.byteLength(body));
    }
    const req = http.request(
      { host: LOOPBACK, port, method, path, headers: allHeaders, agent: false, timeout: REQUEST_TIMEOUT_MS },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => {
          const raw = Buffer.concat(chunks).toString("utf8");
          let parsed = null;
          try {
            parsed = JSON.parse(raw);
          } catch {
            // Left as null; the caller's checks will report it.
          }
          resolve({ status: res.statusCode ?? 0, headers: res.headers, body: parsed, raw });
        });
      },
    );
    req.on("timeout", () => req.destroy(new Error(`request to ${path} timed out`)));
    req.on("error", reject);
    req.end(body);
  });
}

/**
 * Sends bytes exactly as given, for requests node:http refuses to produce.
 * @param {number} port
 * @param {string} text
 * @returns {Promise<string>}
 */
function rawRequest(port, text) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host: LOOPBACK, port });
    const chunks = [];
    socket.setTimeout(REQUEST_TIMEOUT_MS, () => socket.destroy(new Error("raw request timed out")));
    socket.on("connect", () => socket.write(text));
    socket.on("data", (chunk) => chunks.push(chunk));
    socket.on("close", () => resolve(Buffer.concat(chunks).toString("utf8")));
    socket.on("error", reject);
  });
}

/**
 * @param {string} home
 * @returns {Promise<Record<string, any>>}
 */
async function waitForInstanceFile(home, child) {
  const directory = join(home, "instances");
  const deadline = Date.now() + STARTUP_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`the editor exited early with status ${child.exitCode}`);
    }
    let names = [];
    try {
      names = readdirSync(directory).filter((name) => name.endsWith(".json"));
    } catch {
      // The directory appears when the bridge starts.
    }
    if (names.length > 0) {
      return { ...JSON.parse(readFileSync(join(directory, names[0]), "utf8")), fileName: names[0] };
    }
    await sleep(POLL_INTERVAL_MS);
  }
  throw new Error("the bridge did not write its instance file in time");
}

/** @param {Record<string, any>} instance */
function checkInstanceFile(instance) {
  check(/^[0-9a-f]{16}$/.test(instance.instance_id), "instance_id is 16 hex digits", instance.instance_id);
  check(instance.fileName === `${instance.instance_id}.json`, "file name matches instance_id", instance.fileName);
  check(/^[0-9a-f]{64}$/.test(instance.token), "token is 64 hex digits");
  check(Number.isInteger(instance.port) && instance.port >= 1024 && instance.port <= 65535, "port range", instance.port);
  check(instance.schema === 1 && instance.protocol === 1, "schema and protocol", [instance.schema, instance.protocol]);
  check(instance.host === LOOPBACK, "host", instance.host);
  check(instance.headless === true, "headless flag", instance.headless);
  check(/^\d+\.\d+\.\d+-\w+$/.test(instance.godot_version), "godot_version format", instance.godot_version);
  check(typeof instance.project_path === "string" && instance.project_path.endsWith("bridge"), "project_path", instance.project_path);
  check(Number.isInteger(instance.pid) && instance.pid > 0, "pid", instance.pid);
}

/**
 * The client side of docs/protocol.md section 2.1.
 * @param {Record<string, any>} instance
 */
async function checkHandshake(instance) {
  const nonce = randomBytes(16).toString("hex");
  const ping = await request(instance.port, { path: `/v1/ping?nonce=${nonce}` });
  const expected = createHmac("sha256", instance.token).update(nonce + instance.instance_id).digest("hex");
  check(ping.status === 200, "ping status", ping.status);
  check(ping.body?.data?.proof === expected, "ping proof matches HMAC of the token");
  check(ping.body?.data?.instance_id === instance.instance_id, "ping instance_id");
  check(!ping.raw.includes(instance.token), "ping never contains the token");
  check(ping.headers["access-control-allow-origin"] === undefined, "no CORS header");

  const badNonce = await request(instance.port, { path: "/v1/ping?nonce=xyz" });
  check(badNonce.status === 400, "malformed nonce is rejected", badNonce.status);
}

/**
 * @param {Record<string, any>} instance
 * @param {string} name
 * @param {Record<string, unknown>} [args]
 * @param {{ confirm?: boolean, dry_run?: boolean }} [options]
 */
function command(instance, name, args = {}, options = {}) {
  return request(instance.port, {
    method: "POST",
    path: `/v1/commands/${name}`,
    headers: { Authorization: `Bearer ${instance.token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ args, ...options }),
  });
}

/** @param {Record<string, any>} instance */
async function checkRequestGuards(instance) {
  const { port, token } = instance;
  const auth = { Authorization: `Bearer ${token}` };

  const noToken = await request(port, { path: "/v1/commands" });
  check(noToken.status === 401 && noToken.body?.errors?.[0]?.code === "AUTH_FAILED", "no token", noToken.status);

  const wrongToken = await request(port, { path: "/v1/commands", headers: { Authorization: "Bearer nope" } });
  check(wrongToken.status === 401, "wrong token", wrongToken.status);

  const browser = await request(port, { path: "/v1/commands", headers: { ...auth, Origin: "https://example.com" } });
  check(browser.status === 403 && browser.body?.errors?.[0]?.code === "FORBIDDEN_ORIGIN", "Origin header", browser.status);

  const fetchSite = await request(port, { path: "/v1/ping?nonce=00", headers: { "Sec-Fetch-Site": "cross-site" } });
  check(fetchSite.status === 403, "Sec-Fetch-Site header", fetchSite.status);

  const rebinding = await request(port, { path: "/v1/commands", headers: { ...auth, Host: `attacker.example:${port}` } });
  check(rebinding.status === 403, "foreign Host header", rebinding.status);

  const wrongType = await request(port, {
    method: "POST",
    path: "/v1/commands/editor_status",
    headers: { ...auth, "Content-Type": "text/plain" },
    body: "{}",
  });
  check(wrongType.status === 415, "wrong Content-Type", wrongType.status);

  const host = `Host: ${LOOPBACK}:${port}\r\nAuthorization: Bearer ${token}\r\n`;
  const chunked = await rawRequest(
    port,
    `POST /v1/commands/editor_status HTTP/1.1\r\n${host}Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n`,
  );
  check(chunked.startsWith("HTTP/1.1 400"), "Transfer-Encoding is rejected", chunked.slice(0, 20));

  const options = await rawRequest(port, `OPTIONS /v1/commands HTTP/1.1\r\n${host}\r\n`);
  check(options.startsWith("HTTP/1.1 400"), "OPTIONS is rejected", options.slice(0, 20));

  const garbage = await rawRequest(port, "\x00\x01\x02 not http\r\n\r\n");
  check(garbage.startsWith("HTTP/1.1 400"), "garbage is rejected", garbage.slice(0, 20));

  // A body is announced but the request is refused on the head alone.
  const unauthenticatedPost = await rawRequest(
    port,
    `POST /v1/commands/editor_status HTTP/1.1\r\nHost: ${LOOPBACK}:${port}\r\nContent-Type: application/json\r\nContent-Length: 1000\r\n\r\n`,
  );
  check(unauthenticatedPost.startsWith("HTTP/1.1 401"), "unauthenticated POST is refused before the body", unauthenticatedPost.slice(0, 20));

  // The token exemption of the handshake covers GET only.
  const pingPost = await rawRequest(
    port,
    `POST /v1/ping HTTP/1.1\r\nHost: ${LOOPBACK}:${port}\r\nContent-Type: application/json\r\nContent-Length: 1000\r\n\r\n`,
  );
  check(pingPost.startsWith("HTTP/1.1 401"), "POST /v1/ping without a token is refused", pingPost.slice(0, 20));

  // Refused on the announced size while the client is still sending; the
  // response must arrive instead of a connection reset.
  const oversized = await rawRequest(
    port,
    `POST /v1/commands/editor_status HTTP/1.1\r\n${host}Content-Type: application/json\r\nContent-Length: 5000000\r\n\r\n${"x".repeat(200_000)}`,
  );
  check(oversized.startsWith("HTTP/1.1 413"), "oversized body gets a 413", oversized.slice(0, 20));

  // A body of a few megabytes has to get through within the request deadline
  // even though the editor is polled only a few times per second when idle.
  const large = await request(port, {
    method: "POST",
    path: "/v1/commands/editor_status",
    headers: { ...auth, "Content-Type": "application/json" },
    body: JSON.stringify({ args: { padding: "x".repeat(3_000_000) } }),
  });
  check(large.status === 400 && large.body?.errors?.[0]?.code === "INVALID_ARGS", "3 MB body is read and answered", large.status);

  // Fill every connection slot with a socket that never sends a request.
  // Opened one poll apart: the listen backlog itself is small.
  const slots = [];
  for (let index = 0; index < 8; index += 1) {
    slots.push(await openIdleSocket(port));
    await sleep(POLL_INTERVAL_MS);
  }
  const crowded = await request(port, { path: "/v1/commands", headers: auth });
  check(crowded.status === 200, "idle connections do not keep a real request out", crowded.status);
  for (const socket of slots) {
    socket.destroy();
  }
}

/**
 * @param {number} port
 * @returns {Promise<net.Socket>}
 */
function openIdleSocket(port) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host: LOOPBACK, port }, () => resolve(socket));
    socket.on("error", reject);
  });
}

/** @param {Record<string, any>} instance */
async function waitForScene(instance) {
  const deadline = Date.now() + SCENE_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const status = await command(instance, "editor_status");
    if (status.body?.data?.scene === FIXTURE_SCENE) {
      return status;
    }
    await sleep(POLL_INTERVAL_MS);
  }
  throw new Error("the fixture scene did not open in the editor");
}

/**
 * The plugin's command reference is what the bridge reports, rendered.
 * @param {Record<string, any>[]} descriptors
 */
function checkPluginReference(descriptors) {
  const rendered = renderCommands(descriptors);
  if (process.env.GDCLI_UPDATE_PLUGIN === "1") {
    writeFileSync(COMMANDS_FILE, rendered);
    process.stdout.write(`wrote ${COMMANDS_FILE}\n`);
  }
  const committed = existsSync(COMMANDS_FILE) ? readFileSync(COMMANDS_FILE, "utf8").replaceAll("\r\n", "\n") : "";
  check(
    committed === rendered,
    "the plugin's command reference matches the bridge",
    "run the bridge tests once with GDCLI_UPDATE_PLUGIN=1 and commit plugin/skills/godot-cli/references/commands.md",
  );
}

/** @param {Record<string, any>} instance */
async function checkCommands(instance) {
  const listing = await request(instance.port, {
    path: "/v1/commands",
    headers: { Authorization: `Bearer ${instance.token}` },
  });
  const names = (listing.body?.data?.commands ?? []).map((entry) => entry.name);
  const readOnly = [
    "editor_errors", "editor_selection", "editor_status", "fs_list", "fs_read_text", "node_find",
    "node_get", "project_input_map", "project_settings_get", "scene_list_open", "scene_tree",
  ];
  const byName = Object.fromEntries((listing.body?.data?.commands ?? []).map((entry) => [entry.name, entry]));
  check(JSON.stringify(names) === JSON.stringify([...names].sort()), "command list is sorted", names);
  check(readOnly.every((name) => byName[name]?.risk === "read"), "read-only commands", names);
  check(
    ["node_create", "node_set", "node_delete", "scene_new", "scene_save", "fs_write_text", "edit_undo"].every((name) => byName[name]?.risk === "write"),
    "modifying commands are in the write tier",
  );
  check(
    ["fs_delete", "fs_move", "project_settings_set", "project_input_map_set"].every((name) => byName[name]?.risk === "destructive"),
    "destructive commands",
  );
  check(byName.eval?.risk === "exec", "eval is in the exec tier");
  check(Object.values(byName).every((entry) => entry.params?.type === "object"), "every command has a params schema");
  // A project command that calls itself read-only is still treated as a write.
  check(byName.project_echo?.risk === "write" && byName.project_echo?.custom === true, "custom command tier", byName.project_echo);

  checkPluginReference(listing.body?.data?.commands ?? []);

  const status = await waitForScene(instance);
  check(status.body.success === true && status.body.meta.scene === FIXTURE_SCENE, "editor_status envelope", status.body.meta);
  check(status.body.data.headless === true && status.body.data.playing === false, "editor_status state", status.body.data);
  check(status.body.data.open_scenes.includes(FIXTURE_SCENE), "open scenes", status.body.data.open_scenes);

  // The acceptance test of phase 1: the scene tree over plain HTTP.
  const tree = await command(instance, "scene_tree");
  const root = tree.body?.data?.tree;
  check(tree.status === 200 && root?.name === "Main" && root?.type === "Node2D", "scene_tree root", root);
  check(JSON.stringify(root?.children?.map((child) => child.path)) === '["Player","World"]', "scene_tree children", root?.children);
  check(root?.children?.[0]?.children?.[0]?.path === "Player/Sprite2D", "scene_tree grandchild");
  check(JSON.stringify(root?.children?.[1]?.groups) === '["level"]', "scene_tree groups", root?.children?.[1]?.groups);

  const player = await command(instance, "node_get", { path: "Player", properties: ["position"] });
  check(
    JSON.stringify(player.body?.data?.properties?.position) === '{"$type":"Vector2","value":[10,20]}',
    "node_get tagged value",
    player.body?.data?.properties,
  );
  const sprite = await command(instance, "node_get", { path: "Player/Sprite2D", properties: ["modulate"] });
  check(sprite.body?.data?.properties?.modulate?.value === "#ff8000ff", "node_get color", sprite.body?.data?.properties);

  const missing = await command(instance, "node_get", { path: "Nope" });
  check(missing.status === 422 && missing.body?.errors?.[0]?.code === "NODE_NOT_FOUND", "missing node", missing.status);
  check(missing.body?.errors?.[0]?.details?.path === "Nope", "missing node details");

  const found = await command(instance, "node_find", { type: "Sprite2D" });
  check(found.body?.data?.nodes?.[0]?.path === "Player/Sprite2D", "node_find", found.body?.data);

  const scenes = await command(instance, "scene_list_open");
  check(scenes.body?.data?.current === FIXTURE_SCENE, "scene_list_open", scenes.body?.data);

  const selection = await command(instance, "editor_selection");
  check(Array.isArray(selection.body?.data?.nodes), "editor_selection", selection.body);

  const files = await command(instance, "fs_list", { path: "res://tests/fixtures" });
  const paths = (files.body?.data?.entries ?? []).map((entry) => entry.path);
  check(paths.includes(FIXTURE_SCENE) && paths.includes("res://tests/fixtures/notes.txt"), "fs_list", paths);

  const rootListing = await command(instance, "fs_list", { recursive: true, pattern: "*.cfg" });
  const rootPaths = (rootListing.body?.data?.entries ?? []).map((entry) => entry.path);
  check(rootPaths.includes("res://addons/gdcli/plugin.cfg"), "fs_list recursive pattern", rootPaths);
  check(rootPaths.every((path) => !path.startsWith("res://.godot")), "fs_list hides .godot", rootPaths);

  const text = await command(instance, "fs_read_text", { path: "res://tests/fixtures/notes.txt" });
  check(text.body?.data?.text?.trim() === "fixture text for fs_read_text", "fs_read_text", text.body?.data);

  for (const path of ["res://.godot/uid_cache.bin", "res://../secret.txt", "user://x", "C:/Windows/win.ini"]) {
    const denied = await command(instance, "fs_read_text", { path });
    check(denied.body?.errors?.[0]?.code === "PATH_NOT_ALLOWED", `fs_read_text refuses ${path}`, denied.body?.errors);
  }

  const setting = await command(instance, "project_settings_get", { name: "application/config/name" });
  check(setting.body?.data?.value === "gdcli bridge dev", "project_settings_get", setting.body?.data);

  const inputMap = await command(instance, "project_input_map");
  check(Array.isArray(inputMap.body?.data?.actions), "project_input_map", inputMap.body);

  const unknown = await command(instance, "no_such_command");
  check(unknown.status === 404 && unknown.body?.errors?.[0]?.code === "UNKNOWN_COMMAND", "unknown command", unknown.status);

  const badArgs = await command(instance, "scene_tree", { max_depth: "deep" });
  check(badArgs.status === 400 && badArgs.body?.errors?.[0]?.code === "INVALID_ARGS", "invalid args", badArgs.status);
}

const TMP_DIR = "res://tests/tmp";
const BOSS_SCRIPT = "extends CharacterBody2D\n\n\nfunc _on_boss_entered() -> void:\n\tpass\n";

/**
 * Changes made through the real editor: its undo stack, its scene tabs, its
 * file system. Everything written goes to bridge/tests/tmp, removed afterwards.
 * @param {Record<string, any>} instance
 */
async function checkEdits(instance) {
  const treePaths = async () => {
    const tree = await command(instance, "scene_tree");
    /** @type {string[]} */
    const paths = [];
    const walk = (node) => {
      paths.push(node.path);
      (node.children ?? []).forEach(walk);
    };
    walk(tree.body.data.tree);
    return paths;
  };

  const planned = await command(instance, "node_create", { parent: "World", type: "Node2D", name: "Planned" }, { dry_run: true });
  check(planned.body?.data?.dry_run === true && !(await treePaths()).includes("World/Planned"), "dry run creates nothing", planned.body);

  const created = await command(instance, "node_create", { parent: "World", type: "CharacterBody2D", name: "Enemy", properties: { position: [3, 4] } });
  check(created.status === 200 && created.body?.data?.path === "World/Enemy", "node_create", created.body);
  check(created.body?.meta?.undo === "gdcli: node_create Enemy", "the undo step is named in meta", created.body?.meta);
  check((await treePaths()).includes("World/Enemy"), "the new node is in the tree");

  const set = await command(instance, "node_set", { path: "World/Enemy", properties: { position: { x: 30, y: 40 }, modulate: "#00ff00" } });
  const after = await command(instance, "node_get", { path: "World/Enemy", properties: ["position", "modulate"] });
  check(set.status === 200 && JSON.stringify(after.body?.data?.properties?.position?.value) === "[30,40]", "node_set", after.body?.data);
  check(after.body?.data?.properties?.modulate?.value === "#00ff00ff", "node_set converts a colour", after.body?.data);

  const badValue = await command(instance, "node_set", { path: "World/Enemy", properties: { position: "far" } });
  check(badValue.status === 422 && badValue.body?.errors?.[0]?.code === "TYPE_MISMATCH", "node_set rejects a bad value", badValue.status);

  // The editor's own undo history is what these go through.
  const undone = await command(instance, "edit_undo");
  const reverted = await command(instance, "node_get", { path: "World/Enemy", properties: ["position"] });
  check(undone.body?.data?.undone === "gdcli: node_set Enemy", "edit_undo names the step", undone.body);
  check(JSON.stringify(reverted.body?.data?.properties?.position?.value) === "[3,4]", "edit_undo restores the value", reverted.body?.data);
  const redone = await command(instance, "edit_redo");
  check(redone.body?.data?.redone === "gdcli: node_set Enemy", "edit_redo", redone.body);

  await command(instance, "node_rename", { path: "World/Enemy", name: "Boss" });
  await command(instance, "node_move", { path: "World/Boss", parent: "." });
  const copy = await command(instance, "node_duplicate", { path: "Boss", name: "Boss2" });
  await command(instance, "node_add_to_group", { path: "Boss", group: "bosses" });
  const connected = await command(instance, "node_connect_signal", { path: "Boss", signal: "tree_entered", target: ".", method: "_on_boss_entered" });
  check(copy.body?.data?.path === "Boss2" && connected.status === 200, "rename, move, duplicate, group, connect", [copy.body, connected.body]);
  const found = await command(instance, "node_find", { group: "bosses" });
  check(found.body?.data?.nodes?.[0]?.path === "Boss", "the group is set", found.body?.data);

  const deleted = await command(instance, "node_delete", { path: "Boss2" });
  check(deleted.status === 200 && !(await treePaths()).includes("Boss2"), "node_delete", deleted.body);
  await command(instance, "edit_undo");
  check((await treePaths()).includes("Boss2"), "undoing a delete brings the node back");

  // A script written, attached, and a new scene saved to disk.
  const script = `${TMP_DIR}/e2e_boss.gd`;
  const written = await command(instance, "fs_write_text", { path: script, text: BOSS_SCRIPT });
  check(written.status === 200 && written.body?.data?.created === true, "fs_write_text", written.body);
  const again = await command(instance, "fs_write_text", { path: script, text: "x" });
  check(again.body?.errors?.[0]?.code === "ALREADY_EXISTS", "fs_write_text does not replace silently", again.body?.errors);
  const overwrite = await command(instance, "fs_write_text", { path: script, text: "x", overwrite: true });
  check(overwrite.status === 409 && overwrite.body?.errors?.[0]?.code === "CONFIRMATION_REQUIRED", "overwriting needs confirmation", overwrite.status);

  const scene = `${TMP_DIR}/e2e_level.tscn`;
  const made = await command(instance, "scene_new", { path: scene, root_type: "Node2D" });
  check(made.status === 200 && made.body?.data?.root?.name === "E2eLevel", "scene_new", made.body);
  const status = await command(instance, "editor_status");
  check(status.body?.data?.scene === scene, "the new scene is the edited one", status.body?.data?.scene);
  await command(instance, "node_create", { type: "CharacterBody2D", name: "Boss" });
  const attached = await command(instance, "node_attach_script", { path: "Boss", script });
  check(attached.status === 200, "node_attach_script", attached.body);
  const instanced = await command(instance, "node_instantiate_scene", { scene: FIXTURE_SCENE, name: "Level" });
  check(instanced.status === 200 && instanced.body?.data?.path === "Level", "node_instantiate_scene", instanced.body);
  const resource = await command(instance, "resource_create", { path: `${TMP_DIR}/e2e_box.tres`, type: "RectangleShape2D", properties: { size: [16, 8] } });
  check(resource.status === 200, "resource_create", resource.body);
  const saved = await command(instance, "scene_save");
  const onDisk = await command(instance, "fs_read_text", { path: scene });
  const text = onDisk.body?.data?.text ?? "";
  check(saved.status === 200 && /\[node name="Boss" type="CharacterBody2D" parent="\."/.test(text), "scene_save writes the node", text);
  check(text.includes("e2e_boss.gd") && text.includes("instance=ExtResource"), "the saved scene has the script and the instance", text);
  const box = await command(instance, "fs_read_text", { path: `${TMP_DIR}/e2e_box.tres` });
  check(box.body?.data?.text?.includes("Vector2(16, 8)"), "the resource file has its property", box.body);

  const back = await command(instance, "scene_open", { path: FIXTURE_SCENE });
  check(back.status === 200 && back.body?.meta?.scene === FIXTURE_SCENE, "scene_open", back.body);

  // Destructive commands need an explicit yes.
  const refused = await command(instance, "fs_delete", { path: script });
  check(refused.status === 409 && refused.body?.errors?.[0]?.code === "CONFIRMATION_REQUIRED", "fs_delete needs confirmation", refused.status);
  const moved = await command(instance, "fs_move", { from: `${TMP_DIR}/e2e_box.tres`, to: `${TMP_DIR}/moved/e2e_box.tres` }, { confirm: true });
  check(moved.status === 200, "fs_move", moved.body);
  await checkMoveUpdatesReferences(instance, scene, script);
  await checkLayoutMoveAndAnimation(instance);
  await checkContentCommands(instance);
  await checkFolderMove(instance);

  const removed = await command(instance, "fs_delete", { path: `${TMP_DIR}/moved/e2e_box.tres` }, { confirm: true });
  const gone = await command(instance, "fs_read_text", { path: `${TMP_DIR}/moved/e2e_box.tres` });
  check(removed.status === 200 && gone.body?.errors?.[0]?.code === "RESOURCE_NOT_FOUND", "fs_delete", [removed.body, gone.body?.errors]);
  const settingPlan = await command(instance, "project_settings_set", { name: "application/config/name", value: "x" }, { dry_run: true });
  check(settingPlan.body?.data?.dry_run === true, "a destructive dry run needs no confirmation", settingPlan.body);
  const setting = await command(instance, "project_settings_set", { name: "application/config/name", value: "x" });
  check(setting.status === 409, "project_settings_set needs confirmation", setting.status);
  const toolScript = await command(instance, "fs_write_text", { path: `${TMP_DIR}/e2e_tool.gd`, text: "@tool\nextends Node\n" });
  // A tool script runs inside the editor, so a person has to allow it; the
  // caller's own confirmation does not count, and a headless editor has nobody.
  check(toolScript.status === 409 && toolScript.body?.errors?.[0]?.code === "NOT_APPROVED", "writing a tool script needs a person", toolScript.body);
  const confirmedTool = await command(instance, "fs_write_text", { path: `${TMP_DIR}/e2e_tool.gd`, text: "@tool\nextends Node\n" }, { confirm: true });
  check(confirmedTool.body?.errors?.[0]?.code === "NOT_APPROVED", "confirm from the caller does not replace the person", confirmedTool.body);
  const autoload = await command(instance, "project_settings_set", { name: "autoload/E2e", value: "*res://tests/fixtures/empty_script.gd" }, { confirm: true });
  check(autoload.body?.errors?.[0]?.code === "NOT_APPROVED", "so does adding an autoload", autoload.body);
  const toolPlan = await command(instance, "fs_write_text", { path: `${TMP_DIR}/e2e_tool.gd`, text: "@tool\nextends Node\n" }, { dry_run: true });
  check(toolPlan.body?.data?.dry_run === true, "a dry run of it needs nobody", toolPlan.body);

  const evalDisabled = await command(instance, "eval", { code: "return 1" }, { confirm: true });
  check(evalDisabled.status === 409 && evalDisabled.body?.errors?.[0]?.code === "EVAL_DISABLED", "eval is off by default", evalDisabled.body?.errors);

  const custom = await command(instance, "project_echo", { text: "hi" });
  check(custom.body?.data?.echo === "hi" && custom.body?.data?.root === "Main", "project-defined command", custom.body);

  const notHost = await command(instance, "host_quit");
  check(notHost.body?.errors?.[0]?.code === "PRECONDITION_FAILED", "host_quit refuses an editor gd did not start", notHost.body?.errors);

  const screenshot = await command(instance, "editor_screenshot");
  check(screenshot.body?.errors?.[0]?.code === "PRECONDITION_FAILED", "no screenshot from a headless editor", screenshot.body?.errors);

  const [major, minor] = instance.godot_version.split(".").map(Number);
  const errors = await command(instance, "editor_errors");
  if (major > 4 || minor >= 5) {
    check(Array.isArray(errors.body?.data?.entries), "editor_errors on 4.5+", errors.body);
  } else {
    check(errors.body?.errors?.[0]?.code === "UNSUPPORTED_GODOT_VERSION", "editor_errors before 4.5", errors.body?.errors);
  }
}

/**
 * Moving a script rewrites the files that name it: another script, and a scene
 * that is open in a tab (saved first, loaded again afterwards).
 * @param {Instance} instance
 * @param {string} scene an open scene whose root has `script` attached
 * @param {string} script
 */
async function checkMoveUpdatesReferences(instance, scene, script) {
  const user = `${TMP_DIR}/e2e_user.gd`;
  const target = `${TMP_DIR}/scripts/e2e_boss.gd`;
  await command(instance, "fs_write_text", { path: user, text: `extends Node\n\nconst Boss = preload("${script}")\n` });

  const plan = await command(instance, "fs_move", { from: script, to: target }, { dry_run: true });
  const planned = plan.body?.data?.would?.references;
  check(planned?.files?.includes(user) && planned?.files?.includes(scene), "the dry run lists the files that refer to the script", planned);
  check(planned?.open_scenes_saved_and_reloaded?.includes(scene), "and the open scene among them", planned);

  const moved = await command(instance, "fs_move", { from: script, to: target }, { confirm: true });
  const updated = moved.body?.data?.references_updated;
  check(moved.status === 200 && updated?.files?.includes(user), "fs_move updates references", moved.body);
  check(updated?.reloaded_scenes?.includes(scene), "the open scene was loaded again", updated);
  check(moved.body?.meta?.scene === FIXTURE_SCENE, "the edited scene is the same as before", moved.body?.meta);

  const userText = await command(instance, "fs_read_text", { path: user });
  const sceneText = await command(instance, "fs_read_text", { path: scene });
  check(userText.body?.data?.text?.includes(`preload("${target}")`), "the script names the new path", userText.body?.data);
  check(sceneText.body?.data?.text?.includes(`path="${target}"`) && !sceneText.body?.data?.text?.includes(`path="${script}"`), "so does the scene", sceneText.body?.data);

  // With update_references off nothing else is touched. The reference here is
  // a comment, so that the script still compiles afterwards.
  const noted = `${TMP_DIR}/e2e_noted.gd`;
  const note = `${TMP_DIR}/e2e_note.gd`;
  await command(instance, "fs_write_text", { path: noted, text: "extends Node\n" });
  await command(instance, "fs_write_text", { path: note, text: `extends Node\n# see ${noted}\n` });
  const kept = await command(instance, "fs_move", { from: noted, to: `${TMP_DIR}/e2e_noted_moved.gd`, update_references: false }, { confirm: true });
  const stale = await command(instance, "fs_read_text", { path: note });
  check(kept.status === 200 && stale.body?.data?.text?.includes(`# see ${noted}\n`), "update_references=false leaves other files alone", kept.body);
}

const GAME_START_TIMEOUT_MS = 60_000;

/**
 * Runs the fixture scene from the editor and looks into the running game.
 * The project passes --headless to the game, so this works without a display.
 * @param {Instance} instance
 */
async function checkGame(instance) {
  const idle = await command(instance, "game_tree");
  check(idle.status === 409 && idle.body?.errors?.[0]?.code === "PRECONDITION_FAILED", "game commands need a running game", idle.body);

  const played = await command(instance, "editor_play", { scene: FIXTURE_SCENE });
  check(played.status === 200, "editor_play", played.body);
  let tree = await command(instance, "game_tree", { max_depth: 3 });
  for (const deadline = Date.now() + GAME_START_TIMEOUT_MS; tree.status !== 200 && Date.now() < deadline; ) {
    await sleep(500);
    tree = await command(instance, "game_tree", { max_depth: 3 });
  }
  const top = tree.body?.data?.tree?.children?.map((child) => child.path) ?? [];
  check(tree.status === 200 && top.includes("Main") && top.includes("GdcliGame"), "game_tree shows the running game", tree.body);
  check(tree.body?.data?.current_scene?.file === FIXTURE_SCENE, "the current scene is named", tree.body?.data?.current_scene);

  const set = await command(instance, "game_node_set", { path: "Main/Player", properties: { position: [50, 60], velocity: [1, 2] } });
  const got = await command(instance, "game_node_get", { path: "Main/Player", properties: ["position", "velocity"] });
  check(set.status === 200, "game_node_set", set.body);
  check(JSON.stringify(got.body?.data?.properties?.position?.value) === "[50,60]", "game_node_get reads the live value", got.body);
  check(JSON.stringify(got.body?.data?.properties?.velocity?.value) === "[1,2]", "including a property the inspector hides", got.body);
  const edited = await command(instance, "node_get", { path: "Player", properties: ["position"] });
  check(JSON.stringify(edited.body?.data?.properties?.position?.value) === "[10,20]", "the edited scene is untouched", edited.body);

  const missing = await command(instance, "game_node_get", { path: "Main/Nope" });
  check(missing.status === 422 && missing.body?.errors?.[0]?.code === "NODE_NOT_FOUND", "a node the game does not have", missing.body);
  const input = await command(instance, "game_input", { action: "ui_accept", hold: 0.1 });
  check(input.status === 200 && input.body?.data?.pressed === true, "game_input", input.body);
  const picture = await command(instance, "game_screenshot");
  check(picture.body?.errors?.[0]?.code === "PRECONDITION_FAILED", "no screenshot from a game without a window", picture.body);

  const stopped = await command(instance, "editor_stop");
  check(stopped.status === 200, "editor_stop", stopped.body);
  let status = await command(instance, "editor_status");
  for (const deadline = Date.now() + 10_000; status.body?.data?.playing !== false && Date.now() < deadline; ) {
    await sleep(200);
    status = await command(instance, "editor_status");
  }
  check(status.body?.data?.playing === false, "the game stopped", status.body?.data);
}

/**
 * Things a model gets wrong without help: a Control's anchors, a node that
 * jumps when it changes parent, and animations, which had no command.
 * Runs on the fixture scene, which is the edited one here.
 * @param {Instance} instance
 */
async function checkLayoutMoveAndAnimation(instance) {
  await command(instance, "node_create", { type: "Control", name: "Hud", properties: { size: "Vector2(300, 200)" } });
  const fill = await command(instance, "node_create", { type: "ColorRect", parent: "Hud", name: "Fill", properties: { anchors_preset: 15 } });
  const anchors = await command(instance, "node_get", { path: "Hud/Fill", properties: ["layout_mode", "anchors_preset", "size"] });
  check(fill.status === 200 && anchors.body?.data?.properties?.layout_mode === 1, "node_create switches a Control to anchors for a preset", anchors.body);
  check(anchors.body?.data?.properties?.anchors_preset === 15, "and the preset takes effect", anchors.body?.data);
  const hud = await command(instance, "node_get", { path: "Hud", properties: ["size"] });
  check(JSON.stringify(hud.body?.data?.properties?.size?.value) === "[300,200]", "a value written as in a script is accepted", hud.body);

  // What a model writes without being told otherwise: the constant's name for
  // an enumeration, degrees for a rotation, a property that only exists once
  // another one of the same call is set.
  const overlay = await command(instance, "node_create", {
    type: "ColorRect",
    parent: "Hud",
    name: "Overlay",
    properties: { anchors_preset: "PRESET_FULL_RECT", mouse_filter: "MOUSE_FILTER_IGNORE" },
  });
  const overlayValues = await command(instance, "node_get", { path: "Hud/Overlay", properties: ["mouse_filter", "anchor_right", "offset_left"] });
  check(overlay.status === 200 && overlayValues.body?.data?.properties?.mouse_filter === 2, "an enumeration takes the name of its constant", overlay.body);
  check(overlayValues.body?.data?.properties?.anchor_right === 1, "for the anchors preset too", overlayValues.body);
  check(overlayValues.body?.data?.properties?.offset_left === 0, "node_get reads a property the inspector hides, by name", overlayValues.body);
  const crate = await command(instance, "node_create", {
    type: "MeshInstance3D",
    name: "Crate",
    properties: {
      mesh: { $new: "BoxMesh" },
      "surface_material_override/0": { $new: "StandardMaterial3D", properties: { albedo_color: "#b5651d", transparency: "TRANSPARENCY_ALPHA" } },
      rotation_degrees: [0, 90, 0],
    },
  });
  const crateValues = await command(instance, "node_get", { path: "Crate", properties: ["surface_material_override/0", "rotation"] });
  check(crate.status === 200 && crateValues.body?.data?.properties?.["surface_material_override/0"]?.class === "StandardMaterial3D", "node_create reaches a property that an earlier one brings into being", crate.body);
  check(Math.abs((crateValues.body?.data?.properties?.rotation?.value?.[1] ?? 0) - Math.PI / 2) < 1e-4, "and takes a rotation in degrees", crateValues.body);
  const badEnum = await command(instance, "node_set", { path: "Hud/Overlay", properties: { mouse_filter: "PRESET_FULL_RECT" } });
  check(badEnum.status === 422 && badEnum.body?.errors?.[0]?.code === "TYPE_MISMATCH", "a constant of another enumeration is refused", badEnum.body);

  await command(instance, "node_create", { type: "Node2D", name: "Carrier", properties: { position: [100, 0] } });
  await command(instance, "node_create", { type: "Node2D", parent: "Carrier", name: "Cargo", properties: { position: [10, 5] } });
  const moved = await command(instance, "node_move", { path: "Carrier/Cargo", parent: "." });
  const cargo = await command(instance, "node_get", { path: "Cargo", properties: ["position"] });
  check(moved.status === 200 && JSON.stringify(cargo.body?.data?.properties?.position?.value) === "[110,5]", "node_move keeps the node where it is on screen", cargo.body);

  await command(instance, "node_create", { type: "AnimationPlayer", name: "Anim" });
  const animation = {
    player: "Anim",
    name: "slide",
    length: 1,
    loop: "pingpong",
    autoplay: true,
    tracks: [{ node: "Cargo", property: "position", keys: [{ time: 0, value: [110, 5] }, { time: 1, value: "Vector2(300, 5)" }] }],
  };
  const created = await command(instance, "animation_create", animation);
  check(created.status === 200 && created.body?.meta?.undo === "gdcli: animation_create slide", "animation_create", created.body);
  const listed = await command(instance, "animation_list", { player: "Anim" });
  const slide = listed.body?.data?.animations?.[0];
  check(slide?.name === "slide" && slide?.loop === "pingpong" && slide?.tracks?.[0] === "Cargo:position", "animation_list shows it", listed.body);
  check(listed.body?.data?.autoplay === "slide", "with autoplay set", listed.body?.data);
  await command(instance, "edit_undo");
  const afterUndo = await command(instance, "animation_list", { player: "Anim" });
  check(afterUndo.body?.data?.animations?.length === 0 && afterUndo.body?.data?.autoplay === "", "undo removes the animation", afterUndo.body);

  const broken = await command(instance, "fs_write_text", { path: `${TMP_DIR}/e2e_broken.gd`, text: 'extends Node\n\nvar speed: int = "fast"\n' });
  check(broken.status === 200 && broken.body?.data?.check?.compiles === false, "a script that does not compile is written and reported", broken.body);
  check(broken.body?.warnings?.some((warning) => warning.includes("does not compile")), "with a warning", broken.body?.warnings);
  const fine = await command(instance, "fs_write_text", { path: `${TMP_DIR}/e2e_fine.gd`, text: "extends Node\n\nvar speed := 3\n" });
  check(fine.body?.data?.check?.compiles === true, "a script that compiles is reported as such", fine.body);
  await command(instance, "fs_write_text", { path: `${TMP_DIR}/e2e_broken.gd`, text: "extends Node\n", overwrite: true }, { confirm: true });
}

const ATLAS = "res://tests/fixtures/tiles.png";

/**
 * What used to need code run in the editor: a tile map, frame animations, an
 * animation state machine, a baked navigation mesh.
 * Runs on the fixture scene, which is the edited one here.
 * @param {Instance} instance
 */
async function checkContentCommands(instance) {
  await command(instance, "node_create", { type: "TileMapLayer", name: "Tiles" });
  const atlas = await command(instance, "tileset_add_atlas", { layer: "Tiles", texture: ATLAS, collision: true });
  check(atlas.status === 200 && atlas.body?.data?.tiles === 8 && atlas.body?.meta?.undo === "gdcli: tileset_add_atlas Tiles", "tileset_add_atlas", atlas.body);
  const painted = await command(instance, "tilemap_set_cells", { layer: "Tiles", rect: [0, 4, 6, 1], source: atlas.body?.data?.source, atlas: [1, 0] });
  check(painted.status === 200 && painted.body?.data?.cells === 6, "tilemap_set_cells paints a rectangle", painted.body);
  const tiles = await command(instance, "tilemap_get", { layer: "Tiles" });
  check(tiles.body?.data?.cell_count === 6 && tiles.body?.data?.sources?.[0]?.columns === 4, "tilemap_get reads it back", tiles.body);
  await command(instance, "edit_undo");
  const unpainted = await command(instance, "tilemap_get", { layer: "Tiles" });
  check(unpainted.body?.data?.cell_count === 0 && unpainted.body?.data?.sources?.length === 1, "undo takes the cells away and leaves the tile set", unpainted.body);
  const noTile = await command(instance, "tilemap_set_cells", { layer: "Tiles", cells: [[0, 0]], atlas: [9, 9] });
  check(noTile.status === 400 && noTile.body?.errors?.[0]?.code === "INVALID_ARGS", "a tile the atlas does not have is refused", noTile.body);

  await command(instance, "node_create", { type: "AnimatedSprite2D", name: "Runner" });
  const frames = await command(instance, "sprite_frames_create", {
    node: "Runner",
    autoplay: "run",
    animations: [{ name: "run", sheet: ATLAS, hframes: 4, vframes: 2, frames: [0, 1, 2, 3], fps: 8 }],
  });
  check(frames.status === 200 && frames.body?.data?.animations?.[0]?.frames === 4, "sprite_frames_create cuts a sheet", frames.body);
  const runner = await command(instance, "node_get", { path: "Runner", properties: ["animation", "autoplay"] });
  check(runner.body?.data?.properties?.autoplay === "run", "and sets what plays first", runner.body);

  await command(instance, "node_create", { type: "AnimationPlayer", name: "Moves" });
  const still = { player: "Moves", name: "still", length: 1, tracks: [{ node: "Runner", property: "position", keys: [{ time: 0, value: [0, 0] }] }] };
  await command(instance, "animation_create", still);
  const leaving = await command(instance, "animation_create", {
    player: "Moves",
    name: "leave",
    length: 1,
    tracks: [
      { node: "Runner", property: "position", keys: [{ time: 0, value: [0, 0] }, { time: 1, value: [200, 0] }] },
      { node: "Runner", method: "hide", keys: [{ time: 1 }] },
    ],
  });
  check(leaving.status === 200 && leaving.body?.data?.tracks?.[1] === "Runner:hide()", "animation_create adds a method track", leaving.body);
  await command(instance, "node_create", { type: "AnimationTree", name: "Brain" });
  const machine = await command(instance, "animation_state_machine_create", {
    tree: "Brain",
    player: "Moves",
    states: [{ name: "Still", animation: "still" }, { name: "Leave", animation: "leave" }],
    transitions: [{ from: "Still", to: "Leave", condition: "leaving", xfade: 0.2 }, { from: "Leave", to: "Still", switch: "at_end", auto: true }],
  });
  check(machine.status === 200 && machine.body?.data?.transitions === 2, "animation_state_machine_create", machine.body);
  check(machine.body?.data?.parameters?.includes("parameters/conditions/leaving"), "and names what code sets", machine.body?.data);
  const brain = await command(instance, "node_get", { path: "Brain", properties: ["tree_root", "active"] });
  check(brain.body?.data?.properties?.tree_root?.class === "AnimationNodeStateMachine" && brain.body?.data?.properties?.active === true, "the tree has the machine and is active", brain.body);

  await command(instance, "node_create", { type: "NavigationRegion2D", name: "Walkable" });
  const baked = await command(instance, "navigation_bake", { region: "Walkable", outline: [[0, 0], [400, 0], [400, 300], [0, 300]] });
  check(baked.status === 200 && baked.body?.data?.kind === "2d" && baked.body?.data?.polygons >= 1, "navigation_bake bakes a 2D region inside its outline", baked.body);
  await command(instance, "node_create", { type: "NavigationRegion3D", name: "Walkable3D" });
  const baked3d = await command(instance, "navigation_bake", { region: "Walkable3D" });
  check(baked3d.status === 200 && baked3d.body?.data?.kind === "3d", "and a 3D region, which gets a mesh when it has none", baked3d.body);

  // Shapes and terrains of tiles, on a layer whose atlas is cut small enough to hold a 3 by 3 block.
  const slope = await command(instance, "tileset_set_collision", { layer: "Tiles", tiles: [[1, 0]], shape: "slope_right" });
  check(slope.status === 200 && slope.body?.data?.tiles === 1 && slope.body?.meta?.undo === "gdcli: tileset_set_collision Tiles", "tileset_set_collision shapes a slope", slope.body);
  const platform = await command(instance, "tileset_set_collision", { layer: "Tiles", tiles: [[2, 0]], polygon: [[0, 0], [1, 0], [1, 0.25], [0, 0.25]], one_way: true });
  check(platform.status === 200 && platform.body?.data?.shape === "polygon", "and a one-way platform from a polygon", platform.body);
  await command(instance, "node_create", { type: "TileMapLayer", name: "Grass" });
  await command(instance, "tileset_add_atlas", { layer: "Grass", texture: ATLAS, tile_size: [8, 8] });
  const terrain = await command(instance, "tileset_set_terrain", { layer: "Grass", terrain: "grass", block: [0, 0] });
  check(terrain.status === 200 && terrain.body?.data?.tiles === 9 && terrain.body?.data?.mode === "sides", "tileset_set_terrain turns a 3 by 3 block into a terrain", terrain.body);
  const lawn = await command(instance, "tilemap_set_cells", { layer: "Grass", rect: [0, 0, 5, 4], terrain: "grass" });
  const lawnCells = await command(instance, "tilemap_get", { layer: "Grass" });
  const tileAt = (x, y) => JSON.stringify(lawnCells.body?.data?.cells?.find((cell) => cell.x === x && cell.y === y)?.atlas);
  check(lawn.status === 200 && lawn.body?.data?.cells === 20, "tilemap_set_cells paints with a terrain", lawn.body);
  check(tileAt(0, 0) === "[0,0]" && tileAt(4, 3) === "[2,2]" && tileAt(2, 1) === "[1,1]", "and the engine picks corners, edges and centre", lawnCells.body?.data?.cells?.slice(0, 6));
  await command(instance, "edit_undo");
  const mown = await command(instance, "tilemap_get", { layer: "Grass" });
  check(mown.body?.data?.cell_count === 0, "undo takes the terrain painting away", mown.body);

  const blend = await command(instance, "animation_blend_space_create", {
    tree: "Brain",
    player: "Moves",
    points: [{ animation: "still", position: 0 }, { animation: "leave", position: 1 }],
  });
  check(blend.status === 200 && blend.body?.data?.kind === "1d" && blend.body?.data?.parameters?.[0] === "parameters/blend_position", "animation_blend_space_create", blend.body);
  await command(instance, "node_create", { type: "AudioStreamPlayer", name: "Sfx" });
  const sound = await command(instance, "animation_create", {
    player: "Moves",
    name: "beep",
    length: 1,
    tracks: [{ node: "Sfx", audio: true, keys: [{ time: 0.25, stream: "res://tests/fixtures/beep.wav" }] }],
  });
  check(sound.status === 200 && sound.body?.data?.tracks?.[0] === "Sfx (audio)", "animation_create adds an audio track", sound.body);
  const notSound = await command(instance, "animation_create", {
    player: "Moves",
    name: "silent",
    length: 1,
    tracks: [{ node: "Sfx", audio: true, keys: [{ time: 0, stream: FIXTURE_SCENE }] }],
  });
  check(notSound.status === 400 && notSound.body?.errors?.[0]?.code === "INVALID_ARGS", "a resource file is not accepted as a sound", notSound.body);

  // C#: code the editor runs after a build is for a person to allow.
  const tool = await command(instance, "fs_write_text", { path: `${TMP_DIR}/Hud.cs`, text: "[Tool]\npublic partial class Hud : Godot.Control {}\n" });
  check(tool.status === 409 && tool.body?.errors?.[0]?.code === "NOT_APPROVED", "a C# tool class needs a person, and a headless editor has none", tool.body);
}

const TICKER_SCENE = "res://tests/fixtures/ticker.tscn";
const TICKER_SCRIPT = "res://tests/fixtures/ticker.gd";
const TICK_LINE = 14;
// Errors the tests cause on purpose: a method that fails in the running game,
// and scripts with a type error given to the compile check.
// Also what the editor says about the scratch scripts the tests write, break
// and move around: on some versions (seen on 4.4) its own rescan compiles one
// of them at a moment when the file it preloads has just been moved. The
// check is for errors in the bridge's own scripts.
const DELIBERATE_ERRORS = [
  /SCRIPT ERROR: Cannot call method 'queue_free' on a null value\./g,
  /SCRIPT ERROR: Parse Error: Cannot assign a value of type[^\n]*/g,
  /SCRIPT ERROR: [^\n]*\n\s+at: [^\n]*res:\/\/tests\/tmp\/[^\n]*/g,
];

/** @param {string} output */
function withoutDeliberateErrors(output) {
  return DELIBERATE_ERRORS.reduce((text, pattern) => text.replaceAll(pattern, ""), output);
}

/**
 * Asks until `done(reply)` holds or the time is up.
 * @param {() => Promise<any>} ask
 * @param {(reply: any) => boolean} done
 */
async function until(ask, done, timeoutMs = 15_000) {
  let reply = await ask();
  for (const deadline = Date.now() + timeoutMs; !done(reply) && Date.now() < deadline; ) {
    await sleep(300);
    reply = await ask();
  }
  return reply;
}

/**
 * Calls a method, reads the game's errors, halts it at a breakpoint, reads the
 * stack and the locals there, steps, and lets it run on.
 * @param {Instance} instance
 */
async function checkGameDebugging(instance) {
  await command(instance, "editor_play", { scene: TICKER_SCENE });
  const started = await until(() => command(instance, "game_tree", { max_depth: 1 }), (reply) => reply.status === 200, GAME_START_TIMEOUT_MS);
  check(started.status === 200, "the ticker scene runs", started.body);

  const printed = await until(() => command(instance, "game_output"), (reply) => reply.body?.data?.lines?.some((line) => line.text === "ticker ready") === true);
  check(printed.body?.data?.lines?.some((line) => line.text === "ticker ready" && line.kind === "print"), "game_output has what the game printed", printed.body);

  const sum = await command(instance, "game_call", { path: "Ticker", method: "add", arguments: [2, 3] });
  check(sum.status === 200 && sum.body?.data?.result === 5, "game_call returns the result", sum.body);
  const badCall = await command(instance, "game_call", { path: "Ticker", method: "no_such_method" });
  check(badCall.status === 400 && badCall.body?.errors?.[0]?.code === "INVALID_ARGS", "game_call rejects an unknown method", badCall.body);

  const running = await command(instance, "game_debug");
  check(running.status === 200 && running.body?.data?.stopped === false, "game_debug while running", running.body);
  const locked = await command(instance, "game_locals");
  check(locked.body?.errors?.[0]?.code === "PRECONDITION_FAILED", "no locals while the game runs", locked.body);

  const set = await command(instance, "game_breakpoint", { path: TICKER_SCRIPT, line: TICK_LINE });
  check(set.status === 200, "game_breakpoint", set.body);
  const halted = await until(() => command(instance, "game_debug"), (reply) => reply.body?.data?.stopped === true && reply.body?.data?.stack?.length > 0);
  const top = halted.body?.data?.stack?.[0];
  check(top?.file === TICKER_SCRIPT && top?.line === TICK_LINE && top?.function === "_tick", "the game halts at the breakpoint", halted.body);
  check(halted.body?.data?.stack?.[1]?.function === "_process", "the caller is on the stack", halted.body?.data?.stack);

  // Asked at once, while the editor's own request for frame 0 may be under way.
  const callerLocals = await command(instance, "game_locals", { frame: 1 });
  check(callerLocals.status === 200 && "_delta" in (callerLocals.body?.data?.locals ?? {}) && !("doubled" in callerLocals.body.data.locals), "game_locals of the caller's frame is not mixed up with frame 0", callerLocals.body);
  const locals = await command(instance, "game_locals", { frame: 0 });
  const count = locals.body?.data?.locals?.count;
  check(locals.status === 200 && Number.isInteger(count) && locals.body?.data?.locals?.doubled === count * 2, "game_locals reads the frame", locals.body);
  check(locals.body?.data?.members?.ticks === count, "and the members of the object", locals.body?.data?.members);
  const live = await command(instance, "game_node_get", { path: "Ticker", properties: ["ticks"] });
  check(live.body?.data?.properties?.ticks === count, "the halted game still answers game_node_get", live.body);

  await command(instance, "game_breakpoint", { path: TICKER_SCRIPT, line: TICK_LINE, enabled: false });
  const out = await command(instance, "game_step", { mode: "out" });
  check(
    out.status === 200 && out.body?.data?.stopped === true && out.body?.data?.stack?.[0]?.function === "_process",
    "game_step out returns to the caller on every engine version",
    out.body,
  );
  const over = await command(instance, "game_step", { mode: "over" });
  const overTop = over.body?.data?.stack?.[0];
  check(over.status === 200 && over.body?.data?.stopped === true && !(overTop?.function === "_tick" && overTop?.line === TICK_LINE), "game_step over moves on and halts again", over.body);

  const resumed = await command(instance, "game_continue");
  check(resumed.status === 200, "game_continue", resumed.body);
  const again = await until(() => command(instance, "game_debug"), (reply) => reply.body?.data?.stopped === false);
  check(again.body?.data?.stopped === false, "the game runs on", again.body);

  const paused = await command(instance, "game_pause");
  check(paused.status === 200 && paused.body?.data?.stopped === true, "game_pause halts it at the next line", paused.body);
  await command(instance, "game_continue");
  await until(() => command(instance, "game_debug"), (reply) => reply.body?.data?.stopped === false);

  // A script error halts a game that runs from the editor, in the middle of
  // the call that caused it.
  const crashed = await command(instance, "game_call", { path: "Ticker", method: "crash" });
  check(crashed.body?.errors?.[0]?.code === "PRECONDITION_FAILED", "a call that hits a script error reports the halt", crashed.body);
  const wreck = await until(() => command(instance, "game_debug"), (reply) => reply.body?.data?.stack?.length > 0);
  check(wreck.body?.data?.stopped === true && /null/i.test(wreck.body?.data?.reason ?? ""), "game_debug gives the error as the reason", wreck.body);
  check(wreck.body?.data?.stack?.[0]?.function === "crash", "and the line that failed", wreck.body?.data?.stack);
  const crashReport = await until(() => command(instance, "game_errors"), (reply) => reply.body?.data?.entries?.some((entry) => /null/i.test(entry.message)) === true);
  const crash = crashReport.body?.data?.entries?.find((entry) => /null/i.test(entry.message));
  check(crash?.severity === "error" && crash?.stack?.[0]?.function === "crash", "the script error is in game_errors on every engine version", crashReport.body);
  await command(instance, "game_continue");
  await until(() => command(instance, "game_debug"), (reply) => reply.body?.data?.stopped === false);

  // Errors come last: an editor build with other tooling may react to them.
  await command(instance, "game_call", { path: "Ticker", method: "complain" });
  const isComplaint = (entry) => entry?.message === "ticker complains on purpose";
  const errors = await until(() => command(instance, "game_errors"), (reply) => reply.body?.data?.entries?.some(isComplaint) === true);
  const complaint = errors.body?.data?.entries?.find(isComplaint);
  check(complaint?.severity === "error" && complaint?.message === "ticker complains on purpose", "game_errors has what the game reported", errors.body);
  check(complaint?.stack?.[0]?.file === TICKER_SCRIPT && complaint?.stack?.[0]?.function === "complain", "with the script stack", complaint);

  await command(instance, "editor_stop");
  const stopped = await until(() => command(instance, "editor_status"), (reply) => reply.body?.data?.playing === false);
  check(stopped.body?.data?.playing === false, "the ticker stopped", stopped.body?.data);
}

/**
 * Moving a folder moves what is in it and rewrites the references to it, in
 * the files inside as well as outside.
 * @param {Instance} instance
 */
async function checkFolderMove(instance) {
  const inside = `${TMP_DIR}/pack/inner.gd`;
  const sibling = `${TMP_DIR}/pack/sibling.gd`;
  const outside = `${TMP_DIR}/e2e_pack_user.gd`;
  await command(instance, "fs_write_text", { path: inside, text: "extends Node\n" });
  await command(instance, "fs_write_text", { path: sibling, text: `extends Node\n\nconst Inner = preload("${inside}")\n` });
  await command(instance, "fs_write_text", { path: outside, text: `extends Node\n\n# uses ${inside}\nconst DIR := "${TMP_DIR}/pack/"\n` });

  const into = await command(instance, "fs_move", { from: `${TMP_DIR}/pack`, to: `${TMP_DIR}/pack/deeper` }, { confirm: true });
  check(into.body?.errors?.[0]?.code === "INVALID_ARGS", "a folder cannot move into itself", into.body);
  const addons = await command(instance, "fs_move", { from: "res://addons", to: "res://plugins" }, { confirm: true });
  check(addons.body?.errors?.[0]?.code === "PATH_NOT_ALLOWED", "the folder holding the bridge cannot be moved", addons.body);

  const target = `${TMP_DIR}/packs/renamed`;
  const moved = await command(instance, "fs_move", { from: `${TMP_DIR}/pack`, to: target }, { confirm: true });
  check(moved.status === 200, "fs_move moves a folder", moved.body);
  const siblingText = await command(instance, "fs_read_text", { path: `${target}/sibling.gd` });
  const outsideText = await command(instance, "fs_read_text", { path: outside });
  check(siblingText.body?.data?.text?.includes(`preload("${target}/inner.gd")`), "a file inside the folder is rewritten where it is now", siblingText.body);
  check(
    outsideText.body?.data?.text?.includes(`# uses ${target}/inner.gd`) && outsideText.body?.data?.text?.includes(`"${target}/"`),
    "a comment and a path prefix outside the folder are rewritten",
    outsideText.body,
  );
}

/** @param {import("node:child_process").ChildProcess} child */
async function stop(child) {
  if (child.exitCode !== null) {
    return;
  }
  const exited = new Promise((resolve) => child.once("exit", resolve));
  child.kill();
  await Promise.race([exited, sleep(5000)]);
  if (child.exitCode === null) {
    child.kill("SIGKILL");
    await exited;
  }
}

/** @param {string} godot */
async function endToEnd(godot) {
  const home = mkdtempSync(join(tmpdir(), "gdcli-test-"));
  /** @type {string[]} */
  const log = [];
  const child = spawn(godot, ["--headless", "--editor", "--path", projectDir, FIXTURE_SCENE], {
    env: { ...process.env, GDCLI_HOME: home },
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.on("data", (chunk) => log.push(String(chunk)));
  child.stderr.on("data", (chunk) => log.push(String(chunk)));
  try {
    const instance = await waitForInstanceFile(home, child);
    checkInstanceFile(instance);
    await checkHandshake(instance);
    await checkRequestGuards(instance);
    await checkCommands(instance);
    // Before the edits: running the project saves scenes with unsaved changes.
    await checkGame(instance);
    await checkGameDebugging(instance);
    await checkEdits(instance);
    const output = log.join("");
    // The game shares the editor's output on some platforms, and one test
    // makes the game fail on purpose.
    const ownErrors = withoutDeliberateErrors(output);
    check(!/SCRIPT ERROR|Parse Error/.test(ownErrors), "the editor reported no script errors", ownErrors.match(/.*(SCRIPT ERROR|Parse Error)[^]{0,400}/)?.[0]);
    check(!output.includes(instance.token), "the token never reaches the editor log");
  } catch (error) {
    failures.push(`${error instanceof Error ? error.message : String(error)}\n--- editor output ---\n${log.join("")}`);
  } finally {
    await stop(child);
    rmSync(home, { recursive: true, force: true });
    rmSync(join(projectDir, "tests", "tmp"), { recursive: true, force: true, maxRetries: 5, retryDelay: 300 });
  }
}

async function main() {
  const { values } = parseArgs({ options: { godot: { type: "string" } } });
  const godot = values.godot ?? process.env.GODOT_BIN;
  if (godot === undefined || godot === "") {
    process.stderr.write("Set GODOT_BIN or pass --godot <path to a Godot editor binary>.\n");
    process.exit(2);
  }

  const version = spawnSync(godot, ["--version"], { encoding: "utf8", timeout: STEP_TIMEOUT_MS });
  if (version.error !== undefined || version.status !== 0) {
    process.stderr.write(`cannot run ${godot}: ${version.error?.message ?? `status ${version.status}`}\n`);
    process.exit(2);
  }
  process.stdout.write(`godot ${version.stdout.trim()}\n`);

  // First open of a project has to import before scripts and scenes load.
  const imported = runGodot(godot, ["--import"]);
  check(imported.status === 0, "godot --import exits cleanly", imported.output.slice(-2000));

  const unit = runGodot(godot, ["--script", "res://tests/run_tests.gd"]);
  const summary = /gdcli unit tests: (\d+) run, (\d+) failed/.exec(unit.output);
  check(unit.status === 0 && summary !== null && summary[2] === "0", "unit suites pass", unit.output.slice(-4000));
  // A script error ends a test early without failing it.
  check(!/SCRIPT ERROR|Parse Error/.test(withoutDeliberateErrors(unit.output)), "unit suites ran without script errors", unit.output.slice(-4000));
  process.stdout.write(`${summary?.[0] ?? "unit suites did not report a result"}\n`);

  await endToEnd(godot);

  if (failures.length > 0) {
  // On GitHub, failures also become annotations, which can be read without
  // access to the full log.
  if (process.env.GITHUB_ACTIONS === "true") {
    for (const failure of failures) {
      const message = failure.slice(0, 3000).replaceAll("%", "%25").replaceAll("\r", "%0D").replaceAll("\n", "%0A");
      process.stdout.write(`::error title=bridge tests::${message}\n`);
    }
  }
    process.stderr.write(`bridge tests failed (${failures.length} of ${checks} checks):\n- ${failures.join("\n- ")}\n`);
    process.exit(1);
  }
  process.stdout.write(`bridge tests passed (${checks} checks)\n`);
}

await main();
