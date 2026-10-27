import { existsSync, readFileSync, utimesSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, test } from "vitest";

import { buildArgs } from "../src/commands/live.js";
import { clearStale, hostLockPath } from "../src/host-lock.js";
import { ExitCode } from "../src/protocol.js";
import { type FakeProcesses, errorEnvelope, fakeBridge, fakeProcesses, harness, makeProject, okEnvelope, tempDir, writeFile } from "./helpers.js";

const ENABLED = '\n[editor_plugins]\n\nenabled=PackedStringArray("res://addons/gdcli/plugin.cfg")\n';

function projectWithBridge(home: string): string {
  const project = makeProject(home, ENABLED);
  writeFile(join(project, "addons", "gdcli", "plugin.cfg"), 'version="0.0.1"\n');
  return project;
}

describe("gd eval", () => {
  test("sends the code to the bridge's eval command with the confirmation flag", async () => {
    const home = tempDir();
    const project = makeProject(home);
    const bridge = await fakeBridge({ home, project, onCommand: (name) => okEnvelope(name, { result: 42 }) });

    const { exitCode, envelope } = await harness({ homeDir: home, cwd: project }).json("eval", "return 6 * 7", "--yes");

    const call = bridge.requests.at(-1);
    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.data).toEqual({ result: 42 });
    expect(call?.url).toBe("/v1/commands/eval");
    expect(JSON.parse(call?.body ?? "{}")).toEqual({ args: { code: "return 6 * 7" }, confirm: true, dry_run: false });
  });

  test("reads the code from a file", async () => {
    const home = tempDir();
    const project = makeProject(home);
    writeFile(join(project, "snippet.gd"), "return scene.name\n");
    const bridge = await fakeBridge({ home, project });

    await harness({ homeDir: home, cwd: project }).json("eval", "--file", "snippet.gd");

    expect(JSON.parse(bridge.requests.at(-1)?.body ?? "{}")).toMatchObject({ args: { code: "return scene.name\n" } });
  });

  test("passes the bridge's refusal through with its exit code", async () => {
    const home = tempDir();
    const project = makeProject(home);
    await fakeBridge({ home, project, onCommand: (name) => errorEnvelope(name, 409, "EVAL_DISABLED") });

    const { exitCode, envelope } = await harness({ homeDir: home, cwd: project }).json("eval", "return 1");

    expect(exitCode).toBe(ExitCode.Precondition);
    expect(envelope.errors[0]?.code).toBe("EVAL_DISABLED");
  });

  test("needs exactly one source of code", async () => {
    const gd = harness({ cwd: makeProject(tempDir()) });

    expect((await gd.json("eval")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("eval", "a", "b")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("eval", "a", "--file", "x.gd")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("eval", "--file", "missing.gd")).envelope.errors[0]?.code).toBe("RESOURCE_NOT_FOUND");
  });
});

describe("gd host", () => {
  function hostHarness(home: string, project: string): { gd: ReturnType<typeof harness>; processes: FakeProcesses; godot: string } {
    const godot = writeFile(join(home, "godot-bin"), "");
    const processes = fakeProcesses();
    return { gd: harness({ homeDir: home, cwd: project, processes, env: { GODOT_BIN: godot } }), processes, godot };
  }

  test("starts a headless editor with its own ports and the host flag, then waits for it", async () => {
    const home = tempDir();
    const project = projectWithBridge(home);
    const { gd, processes, godot } = hostHarness(home, project);

    const { exitCode, envelope } = await gd.json("host", "start", "--wait", "0.2");

    const [started] = processes.detached;
    expect(started?.file).toBe(godot);
    expect(started?.args.slice(0, 4)).toEqual(["--headless", "--editor", "--path", project]);
    expect(started?.args.slice(-2)).toEqual(["--", "--gdcli-host"]);
    const lspPort = Number(started?.args[started.args.indexOf("--lsp-port") + 1]);
    const dapPort = Number(started?.args[started.args.indexOf("--dap-port") + 1]);
    expect(lspPort).toBeGreaterThan(1023);
    expect(dapPort).toBeGreaterThan(1023);
    expect(lspPort).not.toBe(dapPort);
    // Nothing answers in this test, so the wait runs out.
    expect(exitCode).toBe(ExitCode.Transient);
    expect(envelope.errors[0]?.code).toBe("TIMEOUT");
  });

  test("reports the editor that is already running instead of starting another", async () => {
    const home = tempDir();
    const project = projectWithBridge(home);
    await fakeBridge({ home, project });
    const { gd, processes } = hostHarness(home, project);

    const { exitCode, envelope } = await gd.json("host", "start");

    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.data).toMatchObject({ started: false });
    expect(processes.detached).toEqual([]);
  });

  test("waits for the editor another gd is starting instead of starting a second one", async () => {
    const home = tempDir();
    const project = projectWithBridge(home);
    const { gd, processes } = hostHarness(home, project);
    const lock = writeFile(hostLockPath(gd.context, project), JSON.stringify({ pid: 777 }));

    const { exitCode, envelope } = await gd.json("host", "start", "--wait", "0.2");

    expect(processes.detached).toEqual([]);
    expect(exitCode).toBe(ExitCode.Transient);
    expect(envelope.errors[0]?.code).toBe("TIMEOUT");
    // The lock belongs to the other gd and is left alone.
    expect(existsSync(lock)).toBe(true);
  });

  test("takes over the lock of a gd that is gone, and releases its own", async () => {
    const home = tempDir();
    const project = projectWithBridge(home);
    const godot = writeFile(join(home, "godot-bin"), "");
    const OTHER_GD = 777;
    const EDITOR = 4242;
    // The editor it starts dies too, so nothing is left to hold the lock.
    const processes = { ...fakeProcesses(), isAlive: (pid: number) => pid !== OTHER_GD && pid !== EDITOR };
    const gd = harness({ homeDir: home, cwd: project, processes, env: { GODOT_BIN: godot } });
    const lock = writeFile(hostLockPath(gd.context, project), JSON.stringify({ pid: OTHER_GD }));

    await gd.json("host", "start", "--wait", "0.2");

    expect(processes.detached).toHaveLength(1);
    expect(existsSync(lock)).toBe(false);
  });

  test("an editor still starting after the wait keeps the lock, so a second start waits for it", async () => {
    const home = tempDir();
    const project = projectWithBridge(home);
    const { gd, processes } = hostHarness(home, project);

    const first = await gd.json("host", "start", "--wait", "0.1");
    const second = await gd.json("host", "start", "--wait", "0.1");

    expect(first.envelope.errors[0]?.code).toBe("TIMEOUT");
    expect(second.envelope.errors[0]?.code).toBe("TIMEOUT");
    expect(processes.detached).toHaveLength(1);
    expect(JSON.parse(readFileSync(hostLockPath(gd.context, project), "utf8"))).toMatchObject({ editor: 4242 });
  });

  test("while waiting for another start, an editor that is still importing is waited out", async () => {
    const home = tempDir();
    const project = projectWithBridge(home);
    const { gd, processes } = hostHarness(home, project);
    writeFile(hostLockPath(gd.context, project), JSON.stringify({ pid: 777 }));

    const starting = gd.json("host", "start", "--wait", "1.5");
    await new Promise((done) => setTimeout(done, 300));
    await fakeBridge({ home, project, silent: true });
    const { envelope } = await starting;

    expect(processes.detached).toEqual([]);
    expect(envelope.errors[0]?.code).toBe("TIMEOUT");
  });

  test("a lock replaced after it was judged stale is put back, not removed", () => {
    const lock = writeFile(join(tempDir(), "x.lock"), JSON.stringify({ pid: 2, fresh: true }));

    clearStale(lock, 1, JSON.stringify({ pid: 777 }));
    const kept = readFileSync(lock, "utf8");
    clearStale(lock, 1, kept);

    expect(kept).toBe(JSON.stringify({ pid: 2, fresh: true }));
    expect(existsSync(lock)).toBe(false);
    expect(existsSync(`${lock}.1.stale`)).toBe(false);
  });

  test("on macOS, as on Windows, two spellings of a project share one lock", () => {
    const mac = harness({ homeDir: tempDir(), platform: "darwin" });
    const linux = harness({ homeDir: tempDir(), platform: "linux" });

    expect(hostLockPath(mac.context, "/Games/Demo")).toBe(hostLockPath(mac.context, "/games/demo"));
    expect(hostLockPath(linux.context, "/Games/Demo")).not.toBe(hostLockPath(linux.context, "/games/demo"));
  });

  test("an unreadable lock is believed only while it is fresh", async () => {
    const home = tempDir();
    const project = projectWithBridge(home);
    const { gd, processes } = hostHarness(home, project);
    const lock = writeFile(hostLockPath(gd.context, project), "");
    const LONG_AGO = new Date(Date.now() - 60_000);

    await gd.json("host", "start", "--wait", "0.1");
    const whileFresh = processes.detached.length;
    utimesSync(lock, LONG_AGO, LONG_AGO);
    await gd.json("host", "start", "--wait", "0.1");

    expect(whileFresh).toBe(0);
    expect(processes.detached).toHaveLength(1);
  });

  test("refuses to start without the bridge, and --dry-run starts nothing", async () => {
    const home = tempDir();
    const bare = makeProject(home);
    const first = hostHarness(home, bare);
    const refused = await first.gd.json("host", "start");

    const home2 = tempDir();
    const second = hostHarness(home2, projectWithBridge(home2));
    const planned = await second.gd.json("host", "start", "--dry-run");

    expect(refused.exitCode).toBe(ExitCode.Precondition);
    expect(refused.envelope.errors[0]?.code).toBe("BRIDGE_NOT_INSTALLED");
    expect(planned.envelope.data).toMatchObject({ dry_run: true });
    expect(first.processes.detached).toEqual([]);
    expect(second.processes.detached).toEqual([]);
  });

  test("stop asks the bridge to quit and passes on its refusal", async () => {
    const home = tempDir();
    const project = projectWithBridge(home);
    const bridge = await fakeBridge({ home, project, onCommand: (name) => okEnvelope(name, { quitting: true }) });
    const { gd } = hostHarness(home, project);

    const { exitCode, envelope } = await gd.json("host", "stop", "--wait", "0.2");

    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.data).toEqual({ quitting: true });
    // The stand-in never goes away, and gd says so instead of pretending.
    expect(envelope.warnings.at(-1)).toContain("still running");
    expect(bridge.requests.filter((request) => request.method === "POST").map((request) => request.url)).toEqual(["/v1/commands/host_quit"]);
  });

  test("gives up at once when the editor process is gone", async () => {
    const home = tempDir();
    const project = projectWithBridge(home);
    const godot = writeFile(join(home, "godot-bin"), "");
    const processes = { ...fakeProcesses(), isAlive: () => false };
    const gd = harness({ homeDir: home, cwd: project, processes, env: { GODOT_BIN: godot } });

    const { exitCode, envelope } = await gd.json("host", "start", "--wait", "60");

    expect(exitCode).toBe(ExitCode.CommandFailed);
    expect(envelope.errors[0]?.message).toContain("exited before");
  });

  test("rejects unknown actions and a bad wait", async () => {
    const gd = harness({ cwd: makeProject(tempDir()) });

    expect((await gd.json("host")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("host", "restart")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("host", "start", "--wait", "forever")).exitCode).toBe(ExitCode.Usage);
  });
});

describe("arguments without a declared type", () => {
  const descriptor = { name: "project_settings_set", params: { properties: { name: { type: "string" }, value: {} } } };
  const context = harness().context;

  test("are read as JSON when they are JSON, and as text otherwise", () => {
    expect(buildArgs(["--value", "1280"], descriptor, context)).toEqual({ value: 1280 });
    expect(buildArgs(["--value", "true"], descriptor, context)).toEqual({ value: true });
    expect(buildArgs(["--value", "[1, 2]"], descriptor, context)).toEqual({ value: [1, 2] });
    expect(buildArgs(["--value", "My Game"], descriptor, context)).toEqual({ value: "My Game" });
    expect(buildArgs(["--value", '"1280"'], descriptor, context)).toEqual({ value: "1280" });
  });

  test("declared strings are never reinterpreted", () => {
    expect(buildArgs(["--name", "123"], descriptor, context)).toEqual({ name: "123" });
    expect(buildArgs(["--name", "true"], descriptor, context)).toEqual({ name: "true" });
  });
});
