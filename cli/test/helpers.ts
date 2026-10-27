import { createHmac } from "node:crypto";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { afterEach } from "vitest";

import { run } from "../src/cli.js";
import type { Context, ProcessResult, ProcessRunner, RunOptions } from "../src/context.js";
import type { Envelope } from "../src/envelope.js";
import type { ExitCode } from "../src/protocol.js";

const cleanups: (() => void | Promise<void>)[] = [];

afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) {
    await cleanup();
  }
});

/** A temporary folder removed after the test. */
export function tempDir(): string {
  const directory = mkdtempSync(join(tmpdir(), "gdcli-unit-"));
  cleanups.push(() => rmSync(directory, { recursive: true, force: true }));
  return directory;
}

export function writeFile(path: string, content: string): string {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content);
  return path;
}

export function makeProject(root: string, extraSettings = ""): string {
  const project = join(root, "game");
  writeFile(join(project, "project.godot"), `config_version=5\n\n[application]\n\nconfig/name="unit game"\n${extraSettings}`);
  return project;
}

export interface Call {
  readonly file: string;
  readonly args: readonly string[];
  readonly options?: RunOptions;
}

export interface FakeProcesses extends ProcessRunner {
  readonly calls: Call[];
  readonly detached: Call[];
}

export const VERSION_OUTPUT = "4.3.stable.official.77dcf97d8\n";

/**
 * Answers `--version` itself and hands every other invocation to `respond`.
 */
export function fakeProcesses(
  respond: (call: Call) => Partial<ProcessResult> = () => ({}),
  versionOutput = VERSION_OUTPUT,
): FakeProcesses {
  const calls: Call[] = [];
  const detached: Call[] = [];
  return {
    calls,
    detached,
    run(file, args, options) {
      const call = { file, args, options };
      calls.push(call);
      const base: ProcessResult = { code: 0, stdout: "", stderr: "", timedOut: false };
      const answer = args[0] === "--version" ? { stdout: versionOutput } : respond(call);
      return Promise.resolve({ ...base, ...answer });
    },
    startDetached(file, args, cwd) {
      detached.push({ file, args, options: { cwd, timeoutMs: 0 } });
      return 4242;
    },
    stopAll() {
      // Nothing is ever really started.
    },
    isAlive() {
      return true;
    },
  };
}

export interface Harness {
  readonly context: Context;
  readonly out: () => string;
  readonly err: () => string;
  /** Runs gd with --json and parses the envelope. */
  readonly json: (...argv: string[]) => Promise<{ exitCode: ExitCode; envelope: Envelope }>;
  readonly text: (...argv: string[]) => Promise<{ exitCode: ExitCode; out: string; err: string }>;
}

export interface HarnessOptions {
  readonly cwd?: string;
  readonly env?: Record<string, string | undefined>;
  readonly processes?: ProcessRunner;
  readonly homeDir?: string;
  readonly addonDir?: string;
  readonly platform?: NodeJS.Platform;
  readonly readVersion?: () => string;
  /** What gd reads when a file argument is "-". */
  readonly stdin?: string;
  /** What gd mcp reads, one message per line. */
  readonly stdinLines?: readonly string[];
  readonly launcher?: readonly string[];
  /** Receives what a command registers to run when gd is interrupted. */
  readonly onInterrupt?: (cleanup: () => Promise<void>) => void;
}

async function* linesOf(lines: readonly string[]): AsyncIterable<string> {
  for (const line of lines) {
    await Promise.resolve();
    yield line;
  }
}

export function harness(options: HarnessOptions = {}): Harness {
  const out: string[] = [];
  const err: string[] = [];
  const home = options.homeDir ?? tempDir();
  const context: Context = {
    io: {
      stdout: (chunk) => void out.push(chunk),
      stderr: (chunk) => void err.push(chunk),
      env: { GDCLI_HOME: join(home, ".gdcli"), ...options.env },
      readStdin: () => options.stdin ?? "",
      readLines: () => linesOf(options.stdinLines ?? []),
    },
    cwd: options.cwd ?? home,
    platform: options.platform ?? process.platform,
    homeDir: home,
    pid: process.pid,
    addonDir: options.addonDir ?? join(home, "no-addon"),
    processes: options.processes ?? fakeProcesses(),
    readVersion: options.readVersion ?? (() => "9.9.9"),
    ...(options.launcher === undefined ? {} : { launcher: options.launcher }),
    ...(options.onInterrupt === undefined
      ? {}
      : {
          onInterrupt: (cleanup: () => Promise<void>) => {
            options.onInterrupt?.(cleanup);
            return () => undefined;
          },
        }),
  };
  const reset = (): void => {
    out.length = 0;
    err.length = 0;
  };
  return {
    context,
    out: () => out.join(""),
    err: () => err.join(""),
    async json(...argv) {
      reset();
      const exitCode = await run(["--json", ...argv], context);
      return { exitCode, envelope: JSON.parse(out.join("")) as Envelope };
    },
    async text(...argv) {
      reset();
      const exitCode = await run(argv, context);
      return { exitCode, out: out.join(""), err: err.join("") };
    },
  };
}

export const FAKE_TOKEN = "ab".repeat(32);
export const FAKE_INSTANCE_ID = "0123456789abcdef";

export interface FakeBridgeOptions {
  readonly home: string;
  readonly project: string;
  readonly instanceId?: string;
  readonly protocol?: number;
  /** Token the server signs with; differs from the lock file's to play an impostor. */
  readonly signingToken?: string;
  readonly commands?: readonly Record<string, unknown>[];
  readonly onCommand?: (name: string, payload: Record<string, unknown>) => { status: number; envelope: Record<string, unknown> };
  /** Never answer, to simulate a busy editor. */
  readonly silent?: boolean;
  /** Answer the handshake and the listing but never a command call. */
  readonly hangOnCommand?: boolean;
  readonly writeLockFile?: boolean;
}

export interface FakeBridge {
  readonly port: number;
  readonly lockFile: string;
  readonly requests: { method: string; url: string; authorization: string | undefined; body: string }[];
}

function envelopeOf(command: string, data: unknown, warnings: readonly string[] = []): Record<string, unknown> {
  return { success: true, command, data, errors: [], warnings, meta: { protocol: 1 } };
}

/** A stand-in for the editor bridge: handshake, command list and command calls over real HTTP. */
export async function fakeBridge(options: FakeBridgeOptions): Promise<FakeBridge> {
  const instanceId = options.instanceId ?? FAKE_INSTANCE_ID;
  const requests: FakeBridge["requests"] = [];
  const server = http.createServer((request, response) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk: Buffer) => chunks.push(chunk));
    request.on("end", () => {
      const body = Buffer.concat(chunks).toString("utf8");
      const url = request.url ?? "";
      requests.push({ method: request.method ?? "", url, authorization: request.headers.authorization, body });
      if (options.silent === true) {
        return;
      }
      const send = (status: number, envelope: Record<string, unknown>): void => {
        response.writeHead(status, { "Content-Type": "application/json" });
        response.end(JSON.stringify(envelope));
      };
      if (url.startsWith("/v1/ping")) {
        const nonce = new URL(url, "http://x").searchParams.get("nonce") ?? "";
        const proof = createHmac("sha256", options.signingToken ?? FAKE_TOKEN).update(nonce + instanceId).digest("hex");
        send(200, envelopeOf("ping", { instance_id: instanceId, protocol: options.protocol ?? 1, bridge_version: "0.0.1", proof }, ["startup note"]));
      } else if (url === "/v1/commands") {
        send(200, envelopeOf("commands", { commands: options.commands ?? [] }));
      } else if (options.hangOnCommand !== true) {
        const name = url.slice("/v1/commands/".length);
        const answer = options.onCommand?.(name, JSON.parse(body) as Record<string, unknown>) ?? { status: 200, envelope: envelopeOf(name, {}) };
        send(answer.status, answer.envelope);
      }
    });
  });
  await new Promise<void>((resolvePromise) => server.listen(0, "127.0.0.1", resolvePromise));
  cleanups.push(
    () =>
      new Promise<void>((resolvePromise) => {
        server.closeAllConnections();
        server.close(() => resolvePromise());
      }),
  );
  const { port } = server.address() as AddressInfo;
  const lockFile = join(options.home, ".gdcli", "instances", `${instanceId}.json`);
  if (options.writeLockFile !== false) {
    writeLockFile(lockFile, { instance_id: instanceId, port, project_path: options.project.replaceAll("\\", "/") });
  }
  return { port, lockFile, requests };
}

export function writeLockFile(path: string, fields: Record<string, unknown>): void {
  writeFile(
    path,
    JSON.stringify({
      schema: 1,
      pid: 1234,
      host: "127.0.0.1",
      token: FAKE_TOKEN,
      protocol: 1,
      bridge_version: "0.0.1",
      godot_version: "4.3.0-stable",
      project_name: "unit game",
      headless: false,
      started_at: "2026-10-12T00:00:00Z",
      ...fields,
    }),
  );
  // The bridge writes these owner-only, and gd ignores anything looser.
  chmodSync(path, OWNER_ONLY);
}

const OWNER_ONLY = 0o600;

export function okEnvelope(command: string, data: unknown): { status: number; envelope: Record<string, unknown> } {
  return { status: 200, envelope: envelopeOf(command, data) };
}

export function errorEnvelope(command: string, status: number, code: string): { status: number; envelope: Record<string, unknown> } {
  return {
    status,
    envelope: { success: false, command, data: null, errors: [{ code, message: "nope" }], warnings: [], meta: { protocol: 1 } },
  };
}
