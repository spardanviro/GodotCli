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

let stopping = false;
/** Stops what this gd started and runs the registered clean-ups, then exits. */
function shutDown(code: number): void {
  if (stopping) {
    return;
  }
  stopping = true;
  processes.stopAll();
  const done = Promise.all(cleanups.map((cleanup) => cleanup().catch(() => undefined)));
  void Promise.race([done, new Promise((resolve) => setTimeout(resolve, CLEANUP_MS))]).then(() => process.exit(code));
}

// An agent's own timeout or Ctrl-C must not leave an export, a game or a
// headless editor (gd mcp) running.
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, () => shutDown(EXIT_INTERRUPTED));
}
// The reader went away (an MCP client that closed its end): writing fails
// later with EPIPE as an 'error' event, which would end the process before
// any clean-up. Nobody is listening any more, so stop the same way.
process.stdout.on("error", (error: NodeJS.ErrnoException) => shutDown(error.code === "EPIPE" ? 0 : 1));

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
  onInterrupt: (cleanup) => {
    cleanups.push(cleanup);
    return () => {
      const at = cleanups.indexOf(cleanup);
      if (at !== -1) {
        cleanups.splice(at, 1);
      }
    };
  },
});
