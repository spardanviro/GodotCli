#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

import { readCliVersion, run } from "./cli.js";
import { boundedLines } from "./line-reader.js";
import { MAX_LINE_CHARS } from "./mcp/server.js";
import { createProcessRunner } from "./process-runner.js";

const processes = createProcessRunner(process.platform);
const EXIT_INTERRUPTED = 130;
const CLEANUP_MS = 3000;
const cleanups: Array<() => Promise<void>> = [];

// An agent's own timeout or Ctrl-C must not leave an export, a game or a
// headless editor (gd mcp) running.
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, () => {
    processes.stopAll();
    const done = Promise.all(cleanups.map((cleanup) => cleanup().catch(() => undefined)));
    void Promise.race([done, new Promise((resolve) => setTimeout(resolve, CLEANUP_MS))]).then(() => process.exit(EXIT_INTERRUPTED));
  });
}

process.exitCode = await run(process.argv.slice(2), {
  io: {
    stdout: (text) => process.stdout.write(text),
    stderr: (text) => process.stderr.write(text),
    env: process.env,
    readStdin: () => readFileSync(0, "utf8"),
    // Bounded: one endless line from a client must not take all memory.
    readLines: () => boundedLines(process.stdin, MAX_LINE_CHARS),
  },
  cwd: process.cwd(),
  platform: process.platform,
  homeDir: homedir(),
  pid: process.pid,
  // Copied next to dist/ by the build (scripts/copy-addon.mjs).
  addonDir: fileURLToPath(new URL("../addon/", import.meta.url)),
  processes,
  readVersion: readCliVersion,
  launcher: [process.execPath, fileURLToPath(import.meta.url)],
  onInterrupt: (cleanup) => cleanups.push(cleanup),
});
