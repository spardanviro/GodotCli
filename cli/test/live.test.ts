import { spawnSync } from "node:child_process";
import { chmodSync, existsSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, test } from "vitest";

import { handshake } from "../src/client.js";
import { buildArgs } from "../src/commands/live.js";
import { readInstanceFile, readInstances } from "../src/instances.js";
import { ExitCode } from "../src/protocol.js";
import { FAKE_INSTANCE_ID, FAKE_TOKEN, errorEnvelope, fakeBridge, harness, makeProject, okEnvelope, tempDir, writeFile, writeLockFile } from "./helpers.js";

const COMMANDS = [
  {
    name: "scene_tree",
    risk: "read",
    summary: "Node tree",
    params: { type: "object", properties: { path: { type: "string" }, max_depth: { type: "integer" }, deep: { type: "boolean" }, names: { type: "array" } } },
  },
  { name: "node_delete", risk: "write", summary: "Delete a node" },
];

function setup(): { home: string; project: string } {
  const home = tempDir();
  return { home, project: makeProject(home) };
}

describe("instance files", () => {
  test("reads a well-formed file", () => {
    const home = tempDir();
    const path = join(home, "instances", `${FAKE_INSTANCE_ID}.json`);
    writeLockFile(path, { instance_id: FAKE_INSTANCE_ID, port: 5000, project_path: "C:/game" });

    const instance = readInstanceFile(path, `${FAKE_INSTANCE_ID}.json`, "win32");

    expect(instance).toMatchObject({ instanceId: FAKE_INSTANCE_ID, port: 5000, token: FAKE_TOKEN, projectPath: "C:/game", headless: false });
  });

  test.each([
    ["an id that does not match the file name", { instance_id: "f".repeat(16), port: 5000 }],
    ["a malformed id", { instance_id: "../../etc", port: 5000 }],
    ["a privileged port", { instance_id: FAKE_INSTANCE_ID, port: 80 }],
    ["a port that is not an integer", { instance_id: FAKE_INSTANCE_ID, port: "5000" }],
    ["a short token", { instance_id: FAKE_INSTANCE_ID, port: 5000, token: "abc" }],
  ])("ignores a file with %s", (_label, fields) => {
    const home = tempDir();
    const path = join(home, "instances", `${FAKE_INSTANCE_ID}.json`);
    writeLockFile(path, fields);

    expect(readInstanceFile(path, `${FAKE_INSTANCE_ID}.json`, "win32")).toBeUndefined();
  });

  test.skipIf(process.platform === "win32")("ignores a file that other users can read", () => {
    const home = tempDir();
    const path = join(home, "instances", `${FAKE_INSTANCE_ID}.json`);
    writeLockFile(path, { instance_id: FAKE_INSTANCE_ID, port: 5000 });
    chmodSync(path, 0o644);

    expect(readInstanceFile(path, `${FAKE_INSTANCE_ID}.json`, process.platform)).toBeUndefined();
  });

  test("ignores files that are not JSON objects and folders that do not exist", () => {
    const home = tempDir();
    writeFile(join(home, "instances", `${FAKE_INSTANCE_ID}.json`), "not json");
    writeFile(join(home, "instances", "aaaaaaaaaaaaaaaa.json"), "[1]");
    writeFile(join(home, "instances", "notes.txt"), "x");

    expect(readInstances(home, "win32")).toEqual([]);
    expect(readInstances(join(home, "missing"), "win32")).toEqual([]);
  });
});

describe("handshake", () => {
  test("accepts a bridge that proves it holds the token, without sending the token", async () => {
    const { home, project } = setup();
    const bridge = await fakeBridge({ home, project });
    const [instance] = readInstances(join(home, ".gdcli"), process.platform);

    const outcome = await handshake(instance!);

    expect(outcome).toEqual({ state: "ready", warnings: ["startup note"] });
    expect(bridge.requests[0]?.authorization).toBeUndefined();
    expect(bridge.requests[0]?.url).toMatch(/^\/v1\/ping\?nonce=[0-9a-f]{32}$/u);
  });

  test("rejects a process that answers without knowing the token", async () => {
    const { home, project } = setup();
    await fakeBridge({ home, project, signingToken: "cd".repeat(32) });
    const [instance] = readInstances(join(home, ".gdcli"), process.platform);

    expect(await handshake(instance!)).toEqual({ state: "impostor" });
  });

  test("reports a newer protocol, a silent editor and a closed port", async () => {
    const { home, project } = setup();
    await fakeBridge({ home, project, protocol: 99 });
    const [newer] = readInstances(join(home, ".gdcli"), process.platform);
    expect(await handshake(newer!)).toEqual({ state: "protocol", protocol: 99 });

    const second = setup();
    await fakeBridge({ home: second.home, project: second.project, silent: true });
    const [silent] = readInstances(join(second.home, ".gdcli"), process.platform);
    expect(await handshake(silent!, 200)).toEqual({ state: "busy" });

    expect(await handshake({ ...silent!, port: 1 }, 500)).toEqual({ state: "gone" });
  });
});

describe("gd status", () => {
  test("lists the reachable editor of the current project and never prints the token", async () => {
    const { home, project } = setup();
    await fakeBridge({ home, project });
    const gd = harness({ homeDir: home, cwd: project });

    const { exitCode, envelope } = await gd.json("status");

    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.data).toMatchObject({ editors: [{ instance_id: FAKE_INSTANCE_ID, state: "ready", project_name: "unit game" }] });
    expect(gd.out()).not.toContain(FAKE_TOKEN);
    const text = await gd.text("status");
    expect(text.out).toContain("ready");
  });

  test("fails with NO_EDITOR when nothing is running", async () => {
    const { home, project } = setup();

    const { exitCode, envelope } = await harness({ homeDir: home, cwd: project }).json("status");

    expect(exitCode).toBe(ExitCode.Precondition);
    expect(envelope.errors[0]?.code).toBe("NO_EDITOR");
  });

  test("fails with NO_PROJECT for an explicit folder without a project", async () => {
    const home = tempDir();

    const { envelope } = await harness({ homeDir: home }).json("status", "--project", join(home, "nowhere"));

    expect(envelope.errors[0]?.code).toBe("NO_PROJECT");
  });

  test("shows an impostor as unreachable instead of ready", async () => {
    const { home, project } = setup();
    await fakeBridge({ home, project, signingToken: "cd".repeat(32) });

    const { exitCode, envelope } = await harness({ homeDir: home, cwd: project }).json("status");

    expect(exitCode).toBe(ExitCode.Precondition);
    expect(envelope.errors[0]?.details).toMatchObject({ editors: [{ state: "impostor" }] });
  });
});

/** The id of a process that has already ended. */
function exitedPid(): number {
  const pid = spawnSync(process.execPath, ["-e", ""]).pid;
  if (pid === undefined) {
    throw new Error("could not start a process");
  }
  return pid;
}

describe("finding the editor", () => {
  test("removes the lock file of an editor that is gone", async () => {
    const { home, project } = setup();
    const lockFile = join(home, ".gdcli", "instances", `${FAKE_INSTANCE_ID}.json`);
    writeLockFile(lockFile, { instance_id: FAKE_INSTANCE_ID, pid: exitedPid(), port: 1024, project_path: project.replaceAll("\\", "/") });

    const { envelope } = await harness({ homeDir: home, cwd: project }).json("list");

    expect(envelope.errors[0]?.code).toBe("NO_EDITOR");
    expect(existsSync(lockFile)).toBe(false);
  });

  test("gd status also removes it, after showing it once as gone", async () => {
    const { home, project } = setup();
    const lockFile = join(home, ".gdcli", "instances", `${FAKE_INSTANCE_ID}.json`);
    writeLockFile(lockFile, { instance_id: FAKE_INSTANCE_ID, pid: exitedPid(), port: 1024, project_path: project.replaceAll("\\", "/") });

    const { envelope } = await harness({ homeDir: home, cwd: project }).json("status");

    expect(envelope.errors[0]?.details).toMatchObject({ editors: [{ state: "gone" }] });
    expect(existsSync(lockFile)).toBe(false);
  });

  test("keeps the lock file while the editor's process still runs", async () => {
    const { home, project } = setup();
    const lockFile = join(home, ".gdcli", "instances", `${FAKE_INSTANCE_ID}.json`);
    writeLockFile(lockFile, { instance_id: FAKE_INSTANCE_ID, pid: process.pid, port: 1024, project_path: project.replaceAll("\\", "/") });

    await harness({ homeDir: home, cwd: project }).json("status");

    expect(existsSync(lockFile)).toBe(true);
  });

  test("keeps the lock file when the editor is merely slow", async () => {
    const { home, project } = setup();
    const bridge = await fakeBridge({ home, project, silent: true });

    const { envelope } = await harness({ homeDir: home, cwd: project }).json("list");

    expect(envelope.errors[0]?.code).toBe("EDITOR_BUSY");
    expect(existsSync(bridge.lockFile)).toBe(true);
  }, 15_000);

  test("asks which editor when two have the project open, and honours --instance", async () => {
    const { home, project } = setup();
    await fakeBridge({ home, project, commands: COMMANDS });
    await fakeBridge({ home, project, instanceId: "fedcba9876543210", commands: COMMANDS });
    const gd = harness({ homeDir: home, cwd: project });

    const ambiguous = await gd.json("list");
    const chosen = await gd.json("list", "--instance", "fedcba9876543210");

    expect(ambiguous.exitCode).toBe(ExitCode.Precondition);
    expect(ambiguous.envelope.errors[0]?.code).toBe("MULTIPLE_EDITORS");
    expect(chosen.exitCode).toBe(ExitCode.Success);
  });

  test("explains a protocol mismatch and a busy editor", async () => {
    const newer = setup();
    await fakeBridge({ home: newer.home, project: newer.project, protocol: 99 });
    const mismatch = await harness({ homeDir: newer.home, cwd: newer.project }).json("list");
    expect(mismatch.envelope.errors[0]).toMatchObject({ code: "PROTOCOL_MISMATCH", hint: "Upgrade gd." });

    const older = setup();
    await fakeBridge({ home: older.home, project: older.project, protocol: 0 });
    const outdated = await harness({ homeDir: older.home, cwd: older.project }).json("list");
    expect(outdated.envelope.errors[0]?.hint).toContain("gd bridge install --force");
  });

  test("ignores editors of other projects", async () => {
    const { home, project } = setup();
    await fakeBridge({ home, project: join(home, "another-game") });

    const { envelope } = await harness({ homeDir: home, cwd: project }).json("list");

    expect(envelope.errors[0]?.code).toBe("NO_EDITOR");
  });
});

describe("gd list", () => {
  test("returns the bridge's command list and the handshake warnings", async () => {
    const { home, project } = setup();
    await fakeBridge({ home, project, commands: COMMANDS });
    const gd = harness({ homeDir: home, cwd: project });

    const { exitCode, envelope } = await gd.json("list");
    const text = await gd.text("list");

    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.data).toEqual({ commands: COMMANDS });
    expect(envelope.warnings).toEqual(["startup note"]);
    expect(text.out).toContain("scene_tree");
    expect(text.err).toContain("warning: startup note");
  });
});

describe("gd command", () => {
  test("sends typed arguments with the token and passes the reply through", async () => {
    const { home, project } = setup();
    const bridge = await fakeBridge({ home, project, commands: COMMANDS, onCommand: (name) => okEnvelope(name, { tree: { name: "Main" } }) });
    const gd = harness({ homeDir: home, cwd: project });

    const { exitCode, envelope } = await gd.json("command", "scene_tree", "--path", "Player", "--max-depth", "2", "--deep", "--names=[\"a\"]");

    const call = bridge.requests.at(-1);
    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.data).toEqual({ tree: { name: "Main" } });
    expect(call?.url).toBe("/v1/commands/scene_tree");
    expect(call?.authorization).toBe(`Bearer ${FAKE_TOKEN}`);
    expect(JSON.parse(call?.body ?? "{}")).toEqual({
      args: { path: "Player", max_depth: 2, deep: true, names: ["a"] },
      confirm: false,
      dry_run: false,
    });
  });

  test("forwards --yes and --dry-run", async () => {
    const { home, project } = setup();
    const bridge = await fakeBridge({ home, project, commands: COMMANDS });

    await harness({ homeDir: home, cwd: project }).json("cmd", "node_delete", "--yes", "--dry-run");

    expect(JSON.parse(bridge.requests.at(-1)?.body ?? "{}")).toMatchObject({ confirm: true, dry_run: true });
  });

  test("keeps the bridge's error code and maps it to the exit code", async () => {
    const { home, project } = setup();
    await fakeBridge({ home, project, commands: COMMANDS, onCommand: (name) => errorEnvelope(name, 422, "NODE_NOT_FOUND") });

    const { exitCode, envelope } = await harness({ homeDir: home, cwd: project }).json("command", "scene_tree");

    expect(exitCode).toBe(ExitCode.CommandFailed);
    expect(envelope.errors[0]?.code).toBe("NODE_NOT_FOUND");
  });

  test("rejects unknown and malformed command names before calling the bridge", async () => {
    const { home, project } = setup();
    const bridge = await fakeBridge({ home, project, commands: COMMANDS });
    const gd = harness({ homeDir: home, cwd: project });

    const unknown = await gd.json("command", "nope");
    const malformed = await gd.json("command", "Scene-Tree");

    expect(unknown.envelope.errors[0]?.code).toBe("UNKNOWN_COMMAND");
    expect(malformed.exitCode).toBe(ExitCode.Usage);
    expect(bridge.requests.some((request) => request.method === "POST")).toBe(false);
  });

  test("lists the commands when no name is given", async () => {
    const { home, project } = setup();
    await fakeBridge({ home, project, commands: COMMANDS });

    const { envelope } = await harness({ homeDir: home, cwd: project }).json("command");

    expect(envelope.data).toEqual({ commands: COMMANDS });
  });

  test("cleans invisible characters out of JSON output but leaves read file text alone", async () => {
    const { home, project } = setup();
    const hidden = String.fromCodePoint(0x202e);
    const commands = [...COMMANDS, { name: "fs_read_text", risk: "read", summary: "" }];
    await fakeBridge({ home, project, commands, onCommand: (name) => okEnvelope(name, { text: `a${hidden}b`, label: `c${hidden}d` }) });
    const gd = harness({ homeDir: home, cwd: project });

    const tree = await gd.json("command", "scene_tree");
    const file = await gd.json("command", "fs_read_text");

    expect(tree.envelope.data).toEqual({ text: "ab", label: "cd" });
    expect(file.envelope.data).toEqual({ text: `a${hidden}b`, label: "cd" });
  });

  test("turns a reply without an errors array into one internal error", async () => {
    const { home, project } = setup();
    await fakeBridge({ home, project, commands: COMMANDS, onCommand: () => ({ status: 500, envelope: { success: false } }) });
    const gd = harness({ homeDir: home, cwd: project });

    const { exitCode, envelope } = await gd.json("command", "scene_tree");

    expect(exitCode).toBe(ExitCode.Internal);
    expect(envelope.errors[0]?.code).toBe("INTERNAL_ERROR");
    expect(gd.out().match(/"success"/gu)).toHaveLength(1);
  });

  test("reports a timeout as retryable", async () => {
    const { home, project } = setup();
    await fakeBridge({ home, project, commands: COMMANDS, hangOnCommand: true });

    const { exitCode, envelope } = await harness({ homeDir: home, cwd: project }).json("command", "scene_tree", "--timeout", "0.3");

    expect(exitCode).toBe(ExitCode.Transient);
    expect(envelope.errors[0]?.code).toBe("TIMEOUT");
  });
});

describe("buildArgs", () => {
  const descriptor = COMMANDS[0]!;
  const context = harness().context;

  test("merges --args with individual flags, flags winning", () => {
    expect(buildArgs(["--args", '{"path":"A","max_depth":1}', "--path", "B"], descriptor, context)).toEqual({ path: "B", max_depth: 1 });
  });

  test("reads --args-file relative to the working directory", () => {
    const directory = tempDir();
    writeFile(join(directory, "args.json"), '{"path":"FromFile"}');

    expect(buildArgs(["--args-file", "args.json"], descriptor, { ...context, cwd: directory })).toEqual({ path: "FromFile" });
    expect(buildArgs(["--args-file", "missing.json"], descriptor, { ...context, cwd: directory })).toContain("Cannot read the file");
  });

  test("reads the value of a parameter from a file given as --<name>-file", () => {
    const directory = tempDir();
    const script = `extends Node\n\nvar title := "it's"\n`;
    writeFile(join(directory, "player.gd"), script);
    writeFile(join(directory, "names.json"), '["A", "B"]');
    const here = { ...context, cwd: directory };

    expect(buildArgs(["--path-file", "player.gd"], descriptor, here)).toEqual({ path: script });
    expect(buildArgs(["--names-file=names.json"], descriptor, here)).toEqual({ names: ["A", "B"] });
    expect(buildArgs(["--path-file", "missing.gd"], descriptor, here)).toContain("Cannot read the file given to --path-file");
    expect(buildArgs(["--path-file"], descriptor, here)).toContain("needs a value");
    expect(buildArgs(["--unknown-file", "player.gd"], descriptor, here)).toEqual({ unknown_file: "player.gd" });
  });

  test("reads standard input for a file named -", () => {
    const script = "extends Node\n";
    const piped = harness({ stdin: script }).context;
    const pipedArgs = harness({ stdin: '{"path":"FromStdin"}' }).context;

    expect(buildArgs(["--path-file", "-"], descriptor, piped)).toEqual({ path: script });
    expect(buildArgs(["--args-file", "-", "--max-depth", "2"], descriptor, pipedArgs)).toEqual({ path: "FromStdin", max_depth: 2 });
    expect(buildArgs(["--args-file", "-", "--path-file=-"], descriptor, pipedArgs)).toContain("one argument only");
  });

  test("leaves values it cannot convert for the bridge to reject", () => {
    expect(buildArgs(["--max-depth", "deep", "--deep", "maybe", "--names", "[oops"], descriptor, context)).toEqual({
      max_depth: "deep",
      deep: "maybe",
      names: "[oops",
    });
  });

  test("converts booleans and negative numbers", () => {
    expect(buildArgs(["--deep=false", "--max-depth=-1"], descriptor, context)).toEqual({ deep: false, max_depth: -1 });
  });

  test("explains malformed input", () => {
    expect(buildArgs(["stray"], descriptor, context)).toContain("Unexpected positional argument");
    expect(buildArgs(["--args", "[1]"], descriptor, context)).toContain("must be a JSON object");
    expect(buildArgs(["--args", "{oops"], descriptor, context)).toContain("not valid JSON");
    expect(buildArgs(["--args"], descriptor, context)).toContain("needs a value");
  });
});
