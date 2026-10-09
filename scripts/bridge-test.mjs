// Tests the bridge addon against a real Godot editor binary:
//   1. unit suites in bridge/tests/unit (no editor needed)
//   2. end to end: start a headless editor, find it through its instance file,
//      do the handshake and exercise the HTTP API.
// Usage: GODOT_BIN=/path/to/godot node scripts/bridge-test.mjs
//    or: node scripts/bridge-test.mjs --godot /path/to/godot
// On Windows pass the *_console.exe binary; the GUI one does not write to pipes.
import { spawn, spawnSync } from "node:child_process";
import { createHmac, randomBytes } from "node:crypto";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import http from "node:http";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

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
 */
function command(instance, name, args = {}) {
  return request(instance.port, {
    method: "POST",
    path: `/v1/commands/${name}`,
    headers: { Authorization: `Bearer ${instance.token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ args }),
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

/** @param {Record<string, any>} instance */
async function checkCommands(instance) {
  const listing = await request(instance.port, {
    path: "/v1/commands",
    headers: { Authorization: `Bearer ${instance.token}` },
  });
  const names = (listing.body?.data?.commands ?? []).map((entry) => entry.name);
  const expectedNames = [
    "editor_selection", "editor_status", "fs_list", "fs_read_text", "node_find", "node_get",
    "project_input_map", "project_settings_get", "scene_list_open", "scene_tree",
  ];
  check(JSON.stringify(names) === JSON.stringify(expectedNames), "command list", names);
  check(
    (listing.body?.data?.commands ?? []).every((entry) => entry.risk === "read" && entry.params?.type === "object"),
    "every phase 1 command is read-only and has a params schema",
  );

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
    const output = log.join("");
    check(!/SCRIPT ERROR|Parse Error/.test(output), "the editor reported no script errors");
    check(!output.includes(instance.token), "the token never reaches the editor log");
  } catch (error) {
    failures.push(`${error instanceof Error ? error.message : String(error)}\n--- editor output ---\n${log.join("")}`);
  } finally {
    await stop(child);
    rmSync(home, { recursive: true, force: true });
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
  process.stdout.write(`${summary?.[0] ?? "unit suites did not report a result"}\n`);

  await endToEnd(godot);

  if (failures.length > 0) {
    process.stderr.write(`bridge tests failed (${failures.length} of ${checks} checks):\n- ${failures.join("\n- ")}\n`);
    process.exit(1);
  }
  process.stdout.write(`bridge tests passed (${checks} checks)\n`);
}

await main();
