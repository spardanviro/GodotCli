// Opens bridge/ in a headless editor and checks that the addon loads cleanly.
// Usage: GODOT_BIN=/path/to/godot node scripts/bridge-smoke.mjs
//    or: node scripts/bridge-smoke.mjs --godot /path/to/godot
// On Windows pass the *_console.exe binary; the GUI one does not write to pipes.
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const STEP_TIMEOUT_MS = 180_000;
// The default of 1 MiB turns a chatty import into a spurious ENOBUFS failure.
const MAX_OUTPUT_BYTES = 64 * 1024 * 1024;
const LOADED_LINE = /^gdcli bridge \S+ loaded \(protocol \d+\)/m;
// Editor builds print unrelated ERROR lines in headless mode on some versions,
// so only script failures and anything naming the addon count.
const FAILURE_LINE = /^(SCRIPT ERROR|.*Parse Error|.*res:\/\/addons\/gdcli\/.*(ERROR|error)|ERROR:.*addons\/gdcli)/m;

const projectDir = fileURLToPath(new URL("../bridge/", import.meta.url));

/**
 * @param {string} godot
 * @param {readonly string[]} args
 * @returns {{ output: string, status: number | null, error: Error | undefined }}
 */
function runGodot(godot, args) {
  const result = spawnSync(godot, ["--headless", "--path", projectDir, ...args], {
    encoding: "utf8",
    timeout: STEP_TIMEOUT_MS,
    maxBuffer: MAX_OUTPUT_BYTES,
  });
  return {
    output: `${result.stdout ?? ""}${result.stderr ?? ""}`,
    status: result.status,
    error: result.error,
  };
}

/**
 * @param {string} message
 * @param {string} output
 * @returns {never}
 */
function fail(message, output) {
  process.stderr.write(`bridge smoke test failed: ${message}\n--- godot output ---\n${output}\n`);
  process.exit(1);
}

function main() {
  const { values } = parseArgs({ options: { godot: { type: "string" } } });
  const godot = values.godot ?? process.env.GODOT_BIN;
  if (godot === undefined || godot === "") {
    process.stderr.write("Set GODOT_BIN or pass --godot <path to a Godot editor binary>.\n");
    process.exit(2);
  }

  const version = spawnSync(godot, ["--version"], { encoding: "utf8", timeout: STEP_TIMEOUT_MS });
  if (version.error !== undefined) {
    fail(`cannot run ${godot}: ${version.error.message}`, "");
  }
  if (version.status !== 0) {
    fail(`${godot} --version exited with status ${version.status}`, version.stderr ?? "");
  }
  process.stdout.write(`godot ${version.stdout.trim()}\n`);

  // First open of a project has to import before the editor is usable.
  const imported = runGodot(godot, ["--import"]);
  if (imported.error !== undefined) {
    fail(`--import did not finish: ${imported.error.message}`, imported.output);
  }
  if (imported.status !== 0) {
    fail(`--import exited with status ${imported.status}`, imported.output);
  }

  const loaded = runGodot(godot, ["--editor", "--quit"]);
  if (loaded.error !== undefined) {
    fail(`editor did not finish: ${loaded.error.message}`, loaded.output);
  }
  if (loaded.status !== 0) {
    fail(`editor exited with status ${loaded.status}`, loaded.output);
  }
  if (!LOADED_LINE.test(loaded.output)) {
    fail("the addon did not report that it loaded", loaded.output);
  }
  if (FAILURE_LINE.test(loaded.output)) {
    fail("the editor reported a script error", loaded.output);
  }
  process.stdout.write(`${LOADED_LINE.exec(loaded.output)?.[0]}\nbridge smoke test passed\n`);
}

main();
