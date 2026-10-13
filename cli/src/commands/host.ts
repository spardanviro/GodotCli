import { readFileSync } from "node:fs";
import net from "node:net";
import { join } from "node:path";

import { resolveInstance } from "../client.js";
import type { CommandHandler, CommandResult, Context, GlobalOptions } from "../context.js";
import { errorOf, isEnvelopeError, success } from "../envelope.js";
import { requireGodot } from "../godot.js";
import { acquireHostLock } from "../host-lock.js";
import { PROJECT_FILE, findProject } from "../project.js";
import { ADDON_RELATIVE_DIR, isPluginEnabled, readPluginVersion } from "./bridge.js";
import { invokeBridge } from "./live.js";
import { fail, numberOption, parseCommandArgs, usage } from "./shared.js";

export const HOST_FLAG = "--gdcli-host";
const DEFAULT_WAIT_SECONDS = 120;
const DEFAULT_STOP_WAIT_SECONDS = 15;
const MAX_WAIT_SECONDS = 600;
/** How much longer than the longest wait a start lock is believed. */
const LOCK_MARGIN_SECONDS = 60;
const POLL_INTERVAL_MS = 500;
const MS_PER_SECOND = 1000;

function listen(): Promise<net.Server> {
  return new Promise((resolvePromise, reject) => {
    const probe = net.createServer();
    probe.once("error", reject);
    probe.listen(0, "127.0.0.1", () => resolvePromise(probe));
  });
}

function portOf(server: net.Server): number {
  const address = server.address();
  return typeof address === "object" && address !== null ? address.port : 0;
}

/**
 * Two ports that were free a moment ago; the editor binds them right after.
 * Both probes are open at the same time, so the two ports differ.
 */
async function twoFreePorts(): Promise<readonly [number, number]> {
  const first = await listen();
  const second = await listen();
  const ports = [portOf(first), portOf(second)] as const;
  await Promise.all([first, second].map((probe) => new Promise((done) => probe.close(done))));
  return ports;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}

function describe(instance: { instanceId: string; pid: number; headless: boolean }, started: boolean): Record<string, unknown> {
  return { instance_id: instance.instanceId, pid: instance.pid, headless: instance.headless, started };
}

type HostStart = { readonly godot: string; readonly args: readonly string[] } | CommandResult;

function isResult(value: HostStart): value is CommandResult {
  return "envelope" in value;
}

/** Everything that can be decided before anything is started. */
async function planStart(context: Context, globals: GlobalOptions, project: string): Promise<HostStart> {
  // Without the bridge the editor would start and never become reachable.
  const installed = readPluginVersion(join(project, ADDON_RELATIVE_DIR)) !== undefined;
  if (!installed || !isPluginEnabled(readFileSync(join(project, PROJECT_FILE), "utf8"))) {
    return fail("host", errorOf("BRIDGE_NOT_INSTALLED", "The bridge is not installed and enabled in this project.", "Run `gd bridge install` first."));
  }
  const godot = await requireGodot(context, globals);
  if (isEnvelopeError(godot)) {
    return fail("host", godot);
  }
  // Its own language-server and debug-adapter ports, so a second editor on
  // this machine does not fight the first one over the defaults.
  const [lspPort, dapPort] = await twoFreePorts();
  const args = ["--headless", "--editor", "--path", project, "--lsp-port", String(lspPort), "--dap-port", String(dapPort), "--", HOST_FLAG];
  return { godot: godot.bin, args };
}

const TIMED_OUT = errorOf(
  "TIMEOUT",
  "The headless editor did not become reachable in time.",
  "It may still be importing; check `gd status` shortly, or raise --wait.",
);

/** Waits until the editor this gd started answers. */
async function waitForHost(context: Context, globals: GlobalOptions, deadline: number, pid: number): Promise<CommandResult> {
  for (;;) {
    const found = await resolveInstance(context, globals);
    if (!isEnvelopeError(found)) {
      return { envelope: success("host", describe(found.instance, true)), human: "headless editor is ready\n" };
    }
    // Waiting only makes sense while the answer is "not there yet".
    if (found.code !== "NO_EDITOR" && found.code !== "EDITOR_BUSY") {
      return fail("host", found);
    }
    if (!context.processes.isAlive(pid)) {
      return fail(
        "host",
        errorOf("COMMAND_FAILED", "The headless editor exited before it became reachable.", "Run `gd import` and `gd doctor` to see why."),
      );
    }
    if (Date.now() >= deadline) {
      return fail("host", TIMED_OUT);
    }
    await sleep(Math.min(POLL_INTERVAL_MS, Math.max(deadline - Date.now(), 1)));
  }
}

async function findRunning(context: Context, globals: GlobalOptions): Promise<CommandResult | undefined> {
  const already = await resolveInstance(context, globals);
  if (!isEnvelopeError(already)) {
    return { envelope: success("host", describe(already.instance, false)), human: "an editor is already running for this project\n" };
  }
  return already.code === "NO_EDITOR" ? undefined : fail("host", already);
}

interface Launch {
  readonly project: string;
  readonly godot: string;
  readonly args: readonly string[];
  readonly deadline: number;
}

/** With the start lock held: start the editor unless another gd just did. */
async function launch(context: Context, globals: GlobalOptions, plan: Launch): Promise<CommandResult> {
  const startedMeanwhile = await findRunning(context, globals);
  if (startedMeanwhile !== undefined) {
    return startedMeanwhile;
  }
  const pid = context.processes.startDetached(plan.godot, plan.args, plan.project);
  if (pid === undefined) {
    return fail("host", errorOf("GODOT_NOT_FOUND", "Godot could not be started.", undefined, { path: plan.godot }));
  }
  return waitForHost(context, globals, plan.deadline, pid);
}

async function start(context: Context, globals: GlobalOptions, waitMs: number): Promise<CommandResult> {
  const project = findProject(context, globals);
  if (typeof project !== "string") {
    return fail("host", project);
  }
  const running = await findRunning(context, globals);
  if (running !== undefined) {
    return running;
  }
  const plan = await planStart(context, globals, project);
  if (isResult(plan)) {
    return plan;
  }
  if (globals.dryRun) {
    const data = { dry_run: true, godot: plan.godot, args: plan.args };
    return { envelope: success("host", data), human: `would run: ${[plan.godot, ...plan.args].join(" ")}\n` };
  }

  const deadline = Date.now() + waitMs;
  const maxLockAgeMs = (MAX_WAIT_SECONDS + LOCK_MARGIN_SECONDS) * MS_PER_SECOND;
  for (;;) {
    const release = acquireHostLock(context, project, context.pid, maxLockAgeMs);
    if (release !== undefined) {
      try {
        return await launch(context, globals, { project, godot: plan.godot, args: plan.args, deadline });
      } finally {
        release();
      }
    }
    // Another gd is starting the host. When it is done (or gone) the lock
    // becomes free; taking it then shows the editor it started.
    if (Date.now() >= deadline) {
      return fail("host", TIMED_OUT);
    }
    await sleep(Math.min(POLL_INTERVAL_MS, Math.max(deadline - Date.now(), 1)));
  }
}

/**
 * Asks the host to quit and waits until it is really gone, so that a
 * `host start` right afterwards does not mistake it for a running editor.
 */
async function stop(context: Context, globals: GlobalOptions, waitMs: number): Promise<CommandResult> {
  const result = await invokeBridge(context, globals, "host_quit", {});
  if (!result.envelope.success || globals.dryRun) {
    return result;
  }
  const deadline = Date.now() + waitMs;
  while (Date.now() < deadline) {
    const found = await resolveInstance(context, globals);
    if (isEnvelopeError(found) && found.code === "NO_EDITOR") {
      return result;
    }
    await sleep(Math.min(POLL_INTERVAL_MS, Math.max(deadline - Date.now(), 1)));
  }
  const warning = "The host accepted the request but was still running when gd stopped waiting.";
  return { ...result, envelope: { ...result.envelope, warnings: [...result.envelope.warnings, warning] } };
}

/**
 * `gd host start [--wait seconds]`: when no editor is open, run a headless one
 * so that the live commands work, e.g. in CI or on a machine without a
 * display. It quits by itself after a period without requests.
 * `gd host stop`: quit it. Only an editor started this way can be stopped.
 */
export const hostCommand: CommandHandler = async (context, globals, args) => {
  const parsed = parseCommandArgs(args, { wait: { type: "string" } });
  if (typeof parsed === "string") {
    return usage("host", parsed);
  }
  const [action] = parsed.positionals;
  const wait = numberOption(parsed.values["wait"], "wait", 0, MAX_WAIT_SECONDS);
  if ((action !== "start" && action !== "stop") || parsed.positionals.length !== 1 || typeof wait === "string") {
    return usage("host", typeof wait === "string" ? wait : "Usage: gd host start [--wait seconds] | gd host stop");
  }
  if (action === "stop") {
    return stop(context, globals, (wait ?? DEFAULT_STOP_WAIT_SECONDS) * MS_PER_SECOND);
  }
  return start(context, globals, (wait ?? DEFAULT_WAIT_SECONDS) * MS_PER_SECOND);
};
