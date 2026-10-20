import { readdirSync, unlinkSync } from "node:fs";
import { join } from "node:path";

import { isWritableOnlyByUser, readPrivateFile } from "./trust.js";

export const INSTANCES_DIR_NAME = "instances";
const INSTANCE_ID_PATTERN = /^[0-9a-f]{16}$/u;
const TOKEN_PATTERN = /^[0-9a-f]{64}$/u;
const MIN_PORT = 1024;
const MAX_PORT = 65535;
const MAX_FILE_BYTES = 16_384;

/** A running editor as described by its lock file (docs/protocol.md section 2). */
export interface Instance {
  readonly instanceId: string;
  readonly port: number;
  readonly token: string;
  readonly pid: number;
  readonly protocol: number;
  readonly bridgeVersion: string;
  readonly godotVersion: string;
  readonly projectPath: string;
  readonly projectName: string;
  readonly headless: boolean;
  readonly startedAt: string;
  readonly filePath: string;
}

function text(value: unknown): string {
  return typeof value === "string" ? value : "";
}

/** Returns undefined for anything that does not look like a file this user's bridge wrote. */
export function readInstanceFile(filePath: string, fileName: string, platform: NodeJS.Platform): Instance | undefined {
  const content = readPrivateFile(filePath, { platform, maxBytes: MAX_FILE_BYTES, secret: true });
  if (content === undefined) {
    return undefined;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(content);
  } catch {
    return undefined;
  }
  if (typeof parsed !== "object" || parsed === null) {
    return undefined;
  }
  const fields = parsed as Record<string, unknown>;
  const instanceId = text(fields["instance_id"]);
  const token = text(fields["token"]);
  const port = fields["port"];
  const validPort = typeof port === "number" && Number.isInteger(port) && port >= MIN_PORT && port <= MAX_PORT;
  if (!INSTANCE_ID_PATTERN.test(instanceId) || fileName !== `${instanceId}.json` || !TOKEN_PATTERN.test(token) || !validPort) {
    return undefined;
  }
  return {
    instanceId,
    port,
    token,
    pid: typeof fields["pid"] === "number" ? fields["pid"] : 0,
    protocol: typeof fields["protocol"] === "number" ? fields["protocol"] : 0,
    bridgeVersion: text(fields["bridge_version"]),
    godotVersion: text(fields["godot_version"]),
    projectPath: text(fields["project_path"]),
    projectName: text(fields["project_name"]),
    headless: fields["headless"] === true,
    startedAt: text(fields["started_at"]),
    filePath,
  };
}

export function readInstances(home: string, platform: NodeJS.Platform): readonly Instance[] {
  const directory = join(home, INSTANCES_DIR_NAME);
  // If someone else could add files here, they could announce an "editor" of
  // their own and receive the commands meant for the real one.
  if (!isWritableOnlyByUser(directory, platform)) {
    return [];
  }
  let names: string[];
  try {
    names = readdirSync(directory);
  } catch {
    return [];
  }
  return names
    .filter((name) => name.endsWith(".json"))
    .map((name) => readInstanceFile(join(directory, name), name, platform))
    .filter((instance): instance is Instance => instance !== undefined);
}

function isRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error: unknown) {
    // EPERM: there is such a process, it is only not ours to signal.
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

/**
 * Removes the lock file of an editor that is gone. Only files that passed
 * validation get here. While its process still runs the file stays: a refused
 * connection can be brief (the editor restarting its listener), and a file
 * kept by mistake is only ignored, whereas one removed by mistake hides a
 * live editor until it writes the file again.
 */
export function removeStale(instance: Instance): void {
  if (isRunning(instance.pid)) {
    return;
  }
  try {
    unlinkSync(instance.filePath);
  } catch {
    // Someone else removed it first; nothing to do.
  }
}
