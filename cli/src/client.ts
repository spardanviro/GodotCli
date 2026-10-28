import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { join } from "node:path";

import { CHANGED_BRIDGE_WARNING, addonDiffersFromBundled } from "./addon-digest.js";
import type { Context, GlobalOptions } from "./context.js";
import { type Envelope, type EnvelopeError, errorOf, failure } from "./envelope.js";
import { TransportError, httpRequest } from "./http.js";
import { type Instance, readInstances, removeStale } from "./instances.js";
import { findProject, gdcliHome, sameLocation } from "./project.js";
import { PROTOCOL_VERSION } from "./protocol.js";

/** Longer than the bridge waits for a person to answer a question in the editor (50 s). */
export const DEFAULT_TIMEOUT_MS = 60_000;
const HANDSHAKE_TIMEOUT_MS = 3_000;
const NONCE_BYTES = 16;
const MIN_PROTOCOL = 1;
const MAX_PROTOCOL = PROTOCOL_VERSION;

export type HandshakeOutcome =
  | { readonly state: "ready"; readonly warnings: readonly string[] }
  | { readonly state: "gone" | "busy" | "impostor" | "unreachable" }
  | { readonly state: "protocol"; readonly protocol: number };

function parseEnvelope(body: string): Envelope | undefined {
  try {
    const parsed: unknown = JSON.parse(body);
    const candidate = parsed as Partial<Envelope> | null;
    if (
      typeof candidate === "object" &&
      candidate !== null &&
      typeof candidate.success === "boolean" &&
      Array.isArray(candidate.errors) &&
      Array.isArray(candidate.warnings)
    ) {
      return candidate as Envelope;
    }
  } catch {
    // Not JSON: treated like any other answer that is not from the bridge.
  }
  return undefined;
}

/**
 * Proves that whoever listens on the port holds the token, before the token
 * is sent anywhere (docs/protocol.md section 2.1).
 */
export async function handshake(instance: Instance, timeoutMs = HANDSHAKE_TIMEOUT_MS): Promise<HandshakeOutcome> {
  const nonce = randomBytes(NONCE_BYTES).toString("hex");
  let body: string;
  try {
    body = (await httpRequest({ port: instance.port, method: "GET", path: `/v1/ping?nonce=${nonce}`, timeoutMs })).body;
  } catch (error: unknown) {
    if (error instanceof TransportError && error.kind === "timeout") {
      return { state: "busy" };
    }
    // Only a refused connection proves that nothing listens there any more.
    return { state: error instanceof TransportError && error.kind === "refused" ? "gone" : "unreachable" };
  }

  const envelope = parseEnvelope(body);
  const data = envelope?.data as { proof?: unknown; instance_id?: unknown; protocol?: unknown } | null | undefined;
  const expected = createHmac("sha256", instance.token).update(nonce + instance.instanceId).digest();
  const given = typeof data?.proof === "string" && /^[0-9a-f]{64}$/u.test(data.proof) ? Buffer.from(data.proof, "hex") : undefined;
  if (given === undefined || !timingSafeEqual(given, expected) || data?.instance_id !== instance.instanceId) {
    return { state: "impostor" };
  }
  const protocol = typeof data.protocol === "number" ? data.protocol : 0;
  if (protocol < MIN_PROTOCOL || protocol > MAX_PROTOCOL) {
    return { state: "protocol", protocol };
  }
  return { state: "ready", warnings: envelope?.warnings ?? [] };
}

export interface ResolvedInstance {
  readonly instance: Instance;
  readonly warnings: readonly string[];
}

function describe(instance: Instance): Record<string, unknown> {
  return { instance_id: instance.instanceId, pid: instance.pid, headless: instance.headless, started_at: instance.startedAt };
}

/** Finds the one reachable editor for the current project. */
export async function resolveInstance(context: Context, globals: GlobalOptions): Promise<ResolvedInstance | EnvelopeError> {
  const project = findProject(context, globals);
  if (typeof project !== "string") {
    return project;
  }
  const candidates = readInstances(gdcliHome(context), context.platform)
    .filter((instance) => sameLocation(instance.projectPath, project, context.platform))
    .filter((instance) => globals.instance === undefined || instance.instanceId === globals.instance);

  const ready: ResolvedInstance[] = [];
  let busy = false;
  let mismatch: number | undefined;
  for (const instance of candidates) {
    const outcome = await handshake(instance);
    if (outcome.state === "ready") {
      ready.push({ instance, warnings: outcome.warnings });
    } else if (outcome.state === "gone") {
      removeStale(instance);
    } else if (outcome.state === "busy") {
      busy = true;
    } else if (outcome.state === "protocol") {
      mismatch = outcome.protocol;
    }
  }

  if (ready.length > 1) {
    return errorOf("MULTIPLE_EDITORS", "More than one editor has this project open.", "Pick one with --instance <id>.", {
      instances: ready.map((entry) => describe(entry.instance)),
    });
  }
  const only = ready[0];
  if (only !== undefined) {
    // Every answer of a bridge that is not gd's own code carries the warning, the model's included.
    return addonDiffersFromBundled(context.addonDir, join(project, "addons", "gdcli"))
      ? { ...only, warnings: [CHANGED_BRIDGE_WARNING, ...only.warnings] }
      : only;
  }
  if (mismatch !== undefined) {
    const bridgeIsNewer = mismatch > MAX_PROTOCOL;
    return errorOf(
      "PROTOCOL_MISMATCH",
      "The bridge in the editor speaks a different protocol version than this gd.",
      bridgeIsNewer ? "Upgrade gd." : "Run `gd bridge install --force` and restart the editor.",
      { bridge_protocol: mismatch, supported: [MIN_PROTOCOL, MAX_PROTOCOL] },
    );
  }
  if (busy) {
    return errorOf("EDITOR_BUSY", "The editor is running but did not answer.", "It may be importing; try again shortly.");
  }
  return errorOf(
    "NO_EDITOR",
    "No running editor with the gd bridge was found for this project.",
    "Open the project in Godot (`gd open`), or start a headless editor (`gd host start`; one stops by itself after 30 minutes without commands). If an editor is open, check `gd doctor`.",
    { project },
  );
}

/**
 * A command that was sent and not answered may still be carried out: the
 * bridge finishes a change whose caller went away (protocol 4.3). Retrying
 * a change blindly would make it twice (two nodes), so the answer says so.
 */
function transportFailure(command: string, error: unknown, sent: boolean): Envelope {
  const unknownOutcome = sent ? { may_have_applied: true } : undefined;
  if (error instanceof TransportError && error.kind === "timeout") {
    return failure(command, [
      errorOf(
        "TIMEOUT",
        "The editor did not answer in time.",
        sent ? "It may still carry the command out: look at the result (e.g. scene_tree) before repeating a change, or raise --timeout." : "Retry, or raise --timeout.",
        unknownOutcome,
      ),
    ]);
  }
  return failure(command, [
    errorOf(
      "NO_EDITOR",
      "The connection to the editor was lost.",
      sent ? "Check that the editor is still running, and look at the result before repeating a change: it may have been carried out." : "Check that the editor is still running.",
      unknownOutcome,
    ),
  ]);
}

async function send(
  command: string,
  instance: Instance,
  method: "GET" | "POST",
  path: string,
  payload: unknown,
  timeoutMs: number,
): Promise<Envelope> {
  const headers: Record<string, string> = { Authorization: `Bearer ${instance.token}` };
  if (method === "POST") {
    headers["Content-Type"] = "application/json";
  }
  try {
    const response = await httpRequest({
      port: instance.port,
      method,
      path,
      headers,
      timeoutMs,
      ...(method === "POST" ? { body: JSON.stringify(payload) } : {}),
    });
    return (
      parseEnvelope(response.body) ??
      failure(command, [errorOf("INTERNAL_ERROR", "The bridge sent a reply that is not an envelope.", undefined, { status: response.status })])
    );
  } catch (error: unknown) {
    // A refused connection reached nothing; anything else may have reached the editor.
    const sent = method === "POST" && !(error instanceof TransportError && error.kind === "refused");
    return transportFailure(command, error, sent);
  }
}

export function fetchCommands(instance: Instance, timeoutMs: number): Promise<Envelope> {
  return send("commands", instance, "GET", "/v1/commands", undefined, timeoutMs);
}

export interface CallOptions {
  readonly args: Readonly<Record<string, unknown>>;
  readonly confirm: boolean;
  readonly dryRun: boolean;
  readonly timeoutMs: number;
}

export function callCommand(instance: Instance, name: string, options: CallOptions): Promise<Envelope> {
  const payload = { args: options.args, confirm: options.confirm, dry_run: options.dryRun };
  return send(name, instance, "POST", `/v1/commands/${name}`, payload, options.timeoutMs);
}
