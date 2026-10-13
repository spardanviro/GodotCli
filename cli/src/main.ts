#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

import { readCliVersion, run } from "./cli.js";
import { createProcessRunner } from "./process-runner.js";

const processes = createProcessRunner(process.platform);
const EXIT_INTERRUPTED = 130;

// An agent's own timeout or Ctrl-C must not leave an export or a game running.
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    processes.stopAll();
    process.exit(EXIT_INTERRUPTED);
  });
}

process.exitCode = await run(process.argv.slice(2), {
  io: {
    stdout: (text) => process.stdout.write(text),
    stderr: (text) => process.stderr.write(text),
    env: process.env,
    readStdin: () => readFileSync(0, "utf8"),
  },
  cwd: process.cwd(),
  platform: process.platform,
  homeDir: homedir(),
  pid: process.pid,
  // Copied next to dist/ by the build (scripts/copy-addon.mjs).
  addonDir: fileURLToPath(new URL("../addon/", import.meta.url)),
  processes,
  readVersion: readCliVersion,
});
