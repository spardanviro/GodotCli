#!/usr/bin/env node
// The eval set: tasks given to an agent in a fresh project, checked afterwards
// on what is on disk and on how the game behaves. See evals/README.md.
//
//   GODOT_BIN=... node evals/run.mjs                    # replay the reference answers (no model)
//   GODOT_BIN=... node evals/run.mjs --agent claude     # a fresh Claude Code session per task
//
// Options: --filter <text> --repeat <n> --jobs <n> --out <file> --baseline <file>
//          --max-turns <n> --keep --plugin-dir <folder> --verbose
import { spawn, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const EVALS = dirname(fileURLToPath(import.meta.url));
const REPO = dirname(EVALS);
const GD = join(REPO, "cli", "dist", "main.js");
const INSPECT = join(EVALS, "inspect.gd");
const FIXTURES = join(EVALS, "fixtures");

const COMMAND_TIMEOUT_MS = 300_000;
const INSPECT_TIMEOUT_MS = 120_000;
/** Game checks are timing-sensitive under load: one more try before failing. */
const GAME_TRIES = 2;
const AGENT_TIMEOUT_MS = 30 * 60_000;
const DEFAULT_MAX_TURNS = 60;
const MAX_OUTPUT_BYTES = 64 * 1024 * 1024;
const DEFAULT_SCENE = "res://main.tscn";
const DEFAULT_ALLOWED_TOOLS = "Bash,PowerShell,Write,Edit,Read,Glob,Grep,Skill";

// ---------------------------------------------------------------------------
// Options

function parseOptions(argv) {
  const options = { agent: "replay", filter: "", repeat: 1, jobs: 0, out: "", baseline: "", maxTurns: DEFAULT_MAX_TURNS, keep: false, pluginDir: "", verbose: false };
  for (let index = 0; index < argv.length; index++) {
    const name = argv[index];
    const value = () => {
      index++;
      if (argv[index] === undefined) {
        throw new Error(`${name} needs a value`);
      }
      return argv[index];
    };
    switch (name) {
      case "--agent": options.agent = value(); break;
      case "--filter": options.filter = value(); break;
      case "--repeat": options.repeat = Number(value()); break;
      case "--jobs": options.jobs = Number(value()); break;
      case "--out": options.out = value(); break;
      case "--baseline": options.baseline = value(); break;
      case "--max-turns": options.maxTurns = Number(value()); break;
      case "--plugin-dir": options.pluginDir = value(); break;
      case "--keep": options.keep = true; break;
      case "--verbose": options.verbose = true; break;
      default: throw new Error(`unknown option ${name}`);
    }
  }
  if (!["replay", "idle", "claude"].includes(options.agent)) {
    throw new Error("--agent is replay, idle or claude");
  }
  options.jobs ||= options.agent === "claude" ? 1 : 2;
  return options;
}

// ---------------------------------------------------------------------------
// Tasks

function loadTasks(filter) {
  const tasks = [];
  for (const file of readdirSync(join(EVALS, "tasks")).filter((name) => name.endsWith(".json")).sort()) {
    for (const task of JSON.parse(readFileSync(join(EVALS, "tasks", file), "utf8"))) {
      if (task.id.includes(filter)) {
        tasks.push(task);
      }
    }
  }
  const ids = tasks.map((task) => task.id);
  const duplicate = ids.find((id, index) => ids.indexOf(id) !== index);
  if (duplicate !== undefined) {
    throw new Error(`task id ${duplicate} is used twice`);
  }
  return tasks;
}

const text = (value) => (Array.isArray(value) ? value.join("\n") : String(value));

function resPath(project, path) {
  if (!path.startsWith("res://") || path.includes("..")) {
    throw new Error(`not a res:// path: ${path}`);
  }
  return join(project, path.slice("res://".length));
}

// ---------------------------------------------------------------------------
// gd and Godot

function gd(env, project, argv) {
  const result = spawnSync(process.execPath, [GD, "--json", ...argv], { cwd: project, env, encoding: "utf8", timeout: COMMAND_TIMEOUT_MS, maxBuffer: MAX_OUTPUT_BYTES });
  try {
    return JSON.parse(result.stdout);
  } catch {
    return { success: false, errors: [{ code: "NO_ENVELOPE", message: (result.stderr || result.stdout || "").slice(0, 300) }] };
  }
}

function describeFailure(envelope) {
  const error = envelope.errors?.[0];
  return error === undefined ? "failed" : `${error.code}: ${error.message}`;
}

/** A folder with gd for the agent's shells: a POSIX script and a .cmd. */
function gdShim(root) {
  const bin = join(root, "bin");
  mkdirSync(bin, { recursive: true });
  writeFileSync(join(bin, "gd"), `#!/bin/sh\nexec "${process.execPath.replaceAll("\\", "/")}" "${GD.replaceAll("\\", "/")}" "$@"\n`, { mode: 0o755 });
  writeFileSync(join(bin, "gd.cmd"), `@"${process.execPath}" "${GD}" %*\r\n`);
  return bin;
}

// ---------------------------------------------------------------------------
// Agents

function replay(task, env, project) {
  const notes = [];
  for (const argv of task.reference ?? []) {
    const envelope = gd(env, project, argv);
    if (!envelope.success && !(task.reference_may_fail ?? []).includes(argv[1])) {
      notes.push(`${argv.slice(0, 2).join(" ")}: ${describeFailure(envelope)}`);
    }
  }
  return Promise.resolve({ notes, transcript: [], finalText: "", turns: task.reference?.length ?? 0, costUsd: 0 });
}

function claude(task, env, project, options) {
  const binary = process.env.CLAUDE_BIN || "claude";
  if (/\.(cmd|bat)$/iu.test(binary)) {
    return Promise.resolve({ notes: ["CLAUDE_BIN names a .cmd file, which cannot be started without a shell: give the claude executable itself"], transcript: [], finalText: "", turns: 0, costUsd: 0, infra: true });
  }
  const args = [
    "-p", text(task.prompt),
    "--output-format", "stream-json", "--verbose",
    "--max-turns", String(task.max_turns ?? options.maxTurns),
    "--permission-mode", "acceptEdits",
    "--allowedTools", process.env.EVAL_ALLOWED_TOOLS || DEFAULT_ALLOWED_TOOLS,
    ...(options.pluginDir === "" ? [] : ["--plugin-dir", options.pluginDir]),
  ];
  return new Promise((resolvePromise) => {
    const child = spawn(binary, args, { cwd: project, env, stdio: ["ignore", "pipe", "pipe"] });
    let buffer = "";
    let stderr = "";
    const transcript = [];
    let final = { turns: 0, costUsd: 0, finalText: "", isError: true };
    const timer = setTimeout(() => child.kill(), AGENT_TIMEOUT_MS);
    child.stdout.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        let event;
        try {
          event = JSON.parse(line);
        } catch {
          continue;
        }
        if (event.type === "assistant") {
          for (const block of event.message?.content ?? []) {
            if (block.type === "tool_use") {
              transcript.push({ tool: block.name, input: block.input });
            }
          }
        } else if (event.type === "result") {
          final = { turns: event.num_turns ?? 0, costUsd: event.total_cost_usd ?? 0, finalText: event.result ?? "", isError: event.is_error === true };
        }
      }
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      resolvePromise({ notes: [`could not start ${binary}: ${error.message}`], transcript, finalText: "", turns: 0, costUsd: 0, infra: true });
    });
    child.on("close", () => {
      clearTimeout(timer);
      if (buffer.trim() !== "") {
        child.stdout.emit("data", Buffer.from("\n"));
      }
      const notes = final.isError ? [`the session ended in an error${stderr === "" ? "" : `: ${stderr.slice(-300)}`}`] : [];
      resolvePromise({ notes, transcript, finalText: final.finalText, turns: final.turns, costUsd: final.costUsd });
    });
  });
}

// ---------------------------------------------------------------------------
// Checks

const ENGINE_CHECKS = new Set(["node", "node_missing", "node_count", "expression", "setting", "input_action", "script_compiles"]);

function engineChecks(task, project, root) {
  const indexed = task.checks.map((check, index) => ({ check, index })).filter(({ check }) => ENGINE_CHECKS.has(check.type));
  if (indexed.length === 0) {
    return new Map();
  }
  const input = join(root, "checks.json");
  const output = join(root, "verdicts.json");
  writeFileSync(input, JSON.stringify(task.checks));
  spawnSync(process.env.GODOT_BIN, ["--headless", "--path", project, "--script", INSPECT, "--", input, output], { encoding: "utf8", timeout: INSPECT_TIMEOUT_MS, maxBuffer: MAX_OUTPUT_BYTES });
  const verdicts = new Map();
  if (existsSync(output)) {
    for (const verdict of JSON.parse(readFileSync(output, "utf8"))) {
      verdicts.set(verdict.index, verdict.ok ? null : verdict.detail);
    }
  }
  for (const { index } of indexed) {
    if (!verdicts.has(index)) {
      verdicts.set(index, "the engine did not evaluate this check");
    }
  }
  return verdicts;
}

function gdFiles(project) {
  const found = [];
  const walk = (folder) => {
    for (const name of readdirSync(folder)) {
      const path = join(folder, name);
      if (name === ".godot" || name === ".git") {
        continue;
      }
      if (statSync(path).isDirectory()) {
        walk(path);
      } else if (/\.(gd|cs|tscn|tres|scn|res|cfg|gdshader)$/u.test(name)) {
        found.push(path);
      }
    }
  };
  walk(project);
  return found;
}

/** Whether a path a tool was given lands in the project. Relative paths are the session's, which runs in the project. */
function insideProject(project, path) {
  if (typeof path !== "string" || path === "") {
    return false;
  }
  // Git Bash writes /c/Users/... for C:\Users\...
  const native = process.platform === "win32" ? path.replace(/^\/([a-zA-Z])\//u, "$1:/") : path;
  const fold = (value) => (process.platform === "win32" ? value.toLowerCase() : value);
  const rel = relative(fold(resolve(project)), fold(resolve(project, native)));
  return rel === "" || (!isAbsolute(rel) && rel !== ".." && !rel.startsWith(`..${sep}`));
}

/** The commands of a shell line, split at ; & | and newlines, with cd and variable assignments in front removed. */
function shellParts(command) {
  return command
    .split(/[;&|\n]+/u)
    .map((part) => part.trim().replace(/^(?:(?:cd|Set-Location|pushd)\s+\S+|\$env:\w+\s*=\s*\S+|\w+=\S*)\s*/iu, "").trim())
    .filter((part) => part !== "");
}

/** gd itself, other than exec and eval (which run code that can write anything). */
function isPlainGd(part) {
  const words = part.split(/\s+/u);
  return /^(?:\.\/)?gd(?:\.cmd)?$/u.test(words[0] ?? "") && !["exec", "eval"].includes(words[1] ?? "");
}

function inputsText(transcript) {
  return transcript.map((entry) => `${entry.tool} ${JSON.stringify(entry.input)}`);
}

/** Checks done here: files, gd run, the transcript. Returns a failure text or null. */
function fileOrRunCheck(check, project, env, outcome, agent) {
  switch (check.type) {
    case "file_exists":
      return existsSync(resPath(project, check.file)) ? null : `missing file: ${check.file}`;
    case "file_missing":
      return existsSync(resPath(project, check.file)) ? `file exists: ${check.file}` : null;
    case "file_contains": {
      const path = resPath(project, check.file);
      if (!existsSync(path)) {
        return `missing file: ${check.file}`;
      }
      const content = readFileSync(path, "utf8");
      const any = check.any ?? [check.text];
      return any.some((needle) => content.includes(needle)) ? null : `${check.file} contains none of ${JSON.stringify(any)}`;
    }
    case "no_file_contains": {
      const pattern = new RegExp(check.pattern, "u");
      const hit = gdFiles(project).find((path) => !relative(project, path).replaceAll("\\", "/").startsWith("addons/gdcli/") && pattern.test(readFileSync(path, "utf8")));
      return hit === undefined ? null : `${relative(project, hit)} matches ${check.pattern}`;
    }
    case "runs_clean": {
      const envelope = gd(env, project, ["run", ...(check.scene === undefined ? [] : [check.scene]), "--headless", "--seconds", String(check.seconds ?? 3)]);
      if (!envelope.success) {
        return `gd run: ${describeFailure(envelope)}`;
      }
      return envelope.data?.error_count === 0 ? null : `gd run reported ${envelope.data?.error_count} errors: ${JSON.stringify(envelope.data?.diagnostics?.[0] ?? "").slice(0, 300)}`;
    }
    case "transcript_lacks": {
      if (agent !== "claude") {
        return null; // No session to read.
      }
      const pattern = new RegExp(check.pattern, "iu");
      const hit = inputsText(outcome.transcript).find((line) => pattern.test(line) && (check.tools === undefined || check.tools.some((tool) => line.startsWith(`${tool} `))));
      return hit === undefined ? null : `the session did: ${hit.slice(0, 300)}`;
    }
    case "no_workaround": {
      // After the editor refused, the content must not reach the project another way:
      // a file tool writing into the project, or a shell command other than gd.
      if (agent !== "claude") {
        return null;
      }
      const pattern = new RegExp(check.pattern, "iu");
      const hit = outcome.transcript.find((entry) => {
        const input = entry.input ?? {};
        if (["Write", "Edit", "MultiEdit", "NotebookEdit"].includes(entry.tool)) {
          return insideProject(project, input.file_path ?? input.notebook_path) && pattern.test(JSON.stringify(input));
        }
        if (["Bash", "PowerShell"].includes(entry.tool)) {
          const command = String(input.command ?? "");
          return pattern.test(command) && shellParts(command).some((part) => pattern.test(part) && !isPlainGd(part));
        }
        return false;
      });
      return hit === undefined ? null : `worked around the refusal: ${hit.tool} ${JSON.stringify(hit.input).slice(0, 300)}`;
    }
    case "final_mentions": {
      if (agent !== "claude") {
        return null;
      }
      const lower = outcome.finalText.toLowerCase();
      return check.any.some((word) => lower.includes(word.toLowerCase())) ? null : `the final answer mentions none of ${JSON.stringify(check.any)}`;
    }
    default:
      return `unknown check type ${check.type}`;
  }
}

function sleep(ms) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}

/** The first node of a class in the running game's tree, as a path game_node_get takes. */
function nodesOfClass(tree, className, prefix = "", found = []) {
  if (tree === null || typeof tree !== "object") {
    return found;
  }
  const path = prefix === "" ? tree.name : `${prefix}/${tree.name}`;
  if (tree.type === className || tree.class === className) {
    found.push({ name: String(tree.name), path: typeof tree.path === "string" ? tree.path : path }); // game_tree gives each node its path.
  }
  for (const child of tree.children ?? []) {
    nodesOfClass(child, className, path, found);
  }
  return found;
}

/** The node of a class to watch: one named like the player if there are several, else the first. */
function findInGame(tree, className) {
  const nodes = nodesOfClass(tree, className);
  return (nodes.find((node) => /player|hero|character/iu.test(node.name)) ?? nodes[0])?.path;
}

async function gameCheck(check, project, env) {
  let failure = null;
  for (let attempt = 0; attempt < GAME_TRIES; attempt++) {
    failure = await gameCheckOnce(check, project, env);
    if (failure === null) {
      return null;
    }
  }
  return failure;
}

async function gameCheckOnce(check, project, env) {
  const play = gd(env, project, ["command", "editor_play", ...(check.scene === undefined ? [] : ["--scene", check.scene])]);
  if (!play.success) {
    return `editor_play: ${describeFailure(play)}`;
  }
  try {
    await sleep((check.settle ?? 1.5) * 1000);
    const tree = gd(env, project, ["command", "game_tree"]);
    const node = findInGame(tree.data?.tree ?? tree.data, check.class);
    if (node === undefined) {
      return `no ${check.class} in the running game`;
    }
    const read = () => {
      const value = gd(env, project, ["command", "game_node_get", "--path", node, "--properties", '["global_position"]']).data?.properties?.global_position;
      return Array.isArray(value?.value) ? value.value : Array.isArray(value) ? value : undefined;
    };
    const min = check.min ?? 10;
    const seen = [];
    // The agent names the actions: try the likely names until one is bound.
    for (const action of check.actions_any ?? []) {
      const before = read();
      const input = gd(env, project, ["command", "game_input", "--action", action, "--hold", String(check.hold ?? 0.2)]);
      if (!input.success) {
        continue;
      }
      await sleep((check.after ?? 0.4) * 1000);
      const after = read();
      if (!Array.isArray(before) || !Array.isArray(after)) {
        return `could not read the position of ${node}`;
      }
      const [dx, dy] = [after[0] - before[0], after[1] - before[1]];
      const passed = { rises: dy < -min, moves_right: dx > min, moves_left: dx < -min }[check.expect];
      if (passed) {
        return null;
      }
      seen.push(`${action}: (${dx.toFixed(1)}, ${dy.toFixed(1)})`);
      await sleep((check.settle ?? 1.5) * 1000); // Let it land again before the next try.
    }
    return seen.length === 0
      ? `none of the actions ${JSON.stringify(check.actions_any)} exists in the game`
      : `${node} did not ${check.expect.replace("_", " ")}: ${seen.join(", ")}`;
  } finally {
    gd(env, project, ["command", "editor_stop"]);
  }
}

// ---------------------------------------------------------------------------
// One task

function setUp(task, env, project) {
  const made = gd(env, dirname(project), ["new", project, "--name", "Eval"]);
  if (!made.success) {
    return `gd new: ${describeFailure(made)}`;
  }
  for (const [path, content] of Object.entries(task.setup?.files ?? {})) {
    const target = resPath(project, path);
    mkdirSync(dirname(target), { recursive: true });
    if (typeof content === "object" && content !== null && !Array.isArray(content) && "fixture" in content) {
      copyFileSync(join(FIXTURES, content.fixture), target);
    } else {
      writeFileSync(target, text(content));
    }
  }
  const started = gd(env, project, ["host", "start"]);
  if (!started.success) {
    return `gd host start: ${describeFailure(started)}`;
  }
  const commands = task.setup?.empty === true ? [] : [
    ["command", "scene_new", "--path", DEFAULT_SCENE, "--root-type", task.setup?.root ?? "Node2D", "--root-name", "Main"],
    ["command", "project_settings_set", "--name", "application/run/main_scene", "--value", JSON.stringify(DEFAULT_SCENE), "--yes"],
  ];
  for (const argv of [...commands, ...(task.setup?.commands ?? []), ...(task.setup?.empty === true ? [] : [["command", "scene_save"]])]) {
    const envelope = gd(env, project, argv);
    if (!envelope.success) {
      return `setup ${argv.slice(0, 2).join(" ")}: ${describeFailure(envelope)}`;
    }
  }
  return null;
}

async function runTask(task, options, attempt) {
  const root = mkdtempSync(join(tmpdir(), `gdcli-eval-${task.id.replace(/[^a-z0-9]+/giu, "-")}-`));
  const project = join(root, "game");
  // Windows spells it Path; a second PATH key would leave which one wins to chance.
  const pathKey = Object.keys(process.env).find((key) => key.toUpperCase() === "PATH") ?? "PATH";
  const env = {
    ...process.env,
    GDCLI_HOME: join(root, "home"),
    GDCLI_FORMAT: "",
    [pathKey]: `${gdShim(root)}${process.platform === "win32" ? ";" : ":"}${process.env[pathKey] ?? ""}`,
  };
  running.set(root, { env, project });
  const started = Date.now();
  const result = { id: task.id, attempt, passed: false, infra: false, failures: [], notes: [], turns: 0, costUsd: 0, seconds: 0, root };
  try {
    const setupError = setUp(task, env, project);
    if (setupError !== null) {
      result.infra = true;
      result.failures.push(setupError);
      return result;
    }
    // idle does nothing at all: every task whose checks still pass would pass for any agent.
    const outcome =
      options.agent === "claude" ? await claude(task, env, project, options) : await replay(options.agent === "idle" ? { ...task, reference: [] } : task, env, project);
    result.notes.push(...outcome.notes);
    result.turns = outcome.turns;
    result.costUsd = outcome.costUsd;
    result.infra = outcome.infra === true;
    result.transcript = outcome.transcript;
    result.finalText = outcome.finalText;
    // Game checks need the editor; it may have been stopped by the agent.
    gd(env, project, ["host", "start"]);
    for (const check of task.checks.filter((entry) => entry.type === "game")) {
      const failure = await gameCheck(check, project, env);
      if (failure !== null) {
        result.failures.push(`game: ${failure}`);
      }
    }
    gd(env, project, ["host", "stop"]);
    const engine = engineChecks(task, project, root);
    task.checks.forEach((check, index) => {
      if (check.type === "game") {
        return;
      }
      const failure = ENGINE_CHECKS.has(check.type) ? engine.get(index) : fileOrRunCheck(check, project, env, outcome, options.agent);
      if (failure !== null && failure !== undefined) {
        result.failures.push(`${check.type}: ${failure}`);
      }
    });
    result.passed = result.failures.length === 0 && !result.infra;
    return result;
  } catch (error) {
    result.infra = true;
    result.failures.push(`harness: ${error.message}`);
    return result;
  } finally {
    gd(env, project, ["host", "stop"]);
    running.delete(root);
    result.seconds = Math.round((Date.now() - started) / 100) / 10;
    if (result.passed && !options.keep) {
      // Godot may still be letting go of the folder; a leftover in the temp folder does no harm.
      try {
        rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 500 });
      } catch {
        result.notes.push(`could not remove ${root}`);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Running and reporting

async function runAll(tasks, options) {
  const queue = [];
  for (const task of tasks) {
    for (let attempt = 0; attempt < options.repeat; attempt++) {
      queue.push({ task, attempt });
    }
  }
  const results = [];
  const worker = async () => {
    for (let next = queue.shift(); next !== undefined; next = queue.shift()) {
      const result = await runTask(next.task, options, next.attempt);
      results.push(result);
      process.stdout.write(`${result.passed ? "pass" : result.infra ? "INFRA" : "FAIL"}  ${result.id}${options.repeat > 1 ? ` #${result.attempt + 1}` : ""}  ${result.seconds}s\n`);
    }
  };
  await Promise.all(Array.from({ length: Math.max(1, options.jobs) }, worker));
  return results.sort((left, right) => left.id.localeCompare(right.id) || left.attempt - right.attempt);
}

function summarize(results) {
  const counted = results.filter((result) => !result.infra);
  const passed = counted.filter((result) => result.passed).length;
  return {
    runs: results.length,
    infra: results.length - counted.length,
    passed,
    rate: counted.length === 0 ? 0 : passed / counted.length,
    turns: counted.reduce((sum, result) => sum + result.turns, 0),
    costUsd: Math.round(counted.reduce((sum, result) => sum + result.costUsd, 0) * 100) / 100,
  };
}

function report(results, summary, options) {
  const lines = ["", "task                                   result  turns   cost    sec"];
  for (const result of results) {
    lines.push(`${result.id.padEnd(38)} ${(result.passed ? "pass" : result.infra ? "infra" : "FAIL").padEnd(6)} ${String(result.turns).padStart(6)} ${result.costUsd.toFixed(2).padStart(6)} ${String(result.seconds).padStart(6)}`);
    for (const failure of result.failures) {
      lines.push(`    - ${failure}`);
    }
    if (options.verbose || !result.passed) {
      for (const note of result.notes) {
        lines.push(`    . ${note}`);
      }
    }
    if (!result.passed) {
      lines.push(`    kept: ${result.root}`);
    }
  }
  lines.push("", `Passed ${summary.passed}/${summary.runs - summary.infra} (${Math.round(summary.rate * 100)}%)` + (summary.infra > 0 ? `, ${summary.infra} without a verdict` : "") + `; ${summary.turns} turns, $${summary.costUsd}`);
  process.stdout.write(`${lines.join("\n")}\n`);
}

function compare(results, baselineFile) {
  const baseline = JSON.parse(readFileSync(baselineFile, "utf8"));
  const before = new Map(baseline.results.map((result) => [result.id, result.passed]));
  const now = new Map();
  for (const result of results.filter((entry) => !entry.infra)) {
    now.set(result.id, (now.get(result.id) ?? true) && result.passed);
  }
  const broken = [...now].filter(([id, passed]) => before.get(id) === true && !passed).map(([id]) => id);
  const fixed = [...now].filter(([id, passed]) => before.get(id) === false && passed).map(([id]) => id);
  process.stdout.write(`\nAgainst ${baselineFile} (${Math.round(baseline.summary.rate * 100)}%): fixed ${fixed.length} ${JSON.stringify(fixed)}, broken ${broken.length} ${JSON.stringify(broken)}\n`);
  return broken.length;
}

/** Tasks in progress, so an interrupted run does not leave headless editors behind. */
const running = new Map();

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    for (const { env, project } of running.values()) {
      gd(env, project, ["host", "stop"]);
    }
    process.exit(130);
  });
}

async function main() {
  const options = parseOptions(process.argv.slice(2));
  if (!process.env.GODOT_BIN) {
    throw new Error("set GODOT_BIN to a Godot editor binary (the .console.exe on Windows)");
  }
  if (!existsSync(GD)) {
    throw new Error("cli/dist/main.js is missing: run npm run build first");
  }
  const tasks = loadTasks(options.filter);
  if (tasks.length === 0) {
    throw new Error("no task matches the filter");
  }
  process.stdout.write(`${tasks.length} tasks, agent ${options.agent}, ${options.repeat} run(s) each\n`);
  const results = await runAll(tasks, options);
  const summary = summarize(results);
  report(results, summary, options);
  if (options.out !== "") {
    const stripped = results.map(({ root: _root, ...rest }) => rest);
    writeFileSync(options.out, `${JSON.stringify({ agent: options.agent, date: new Date().toISOString(), summary, results: stripped }, null, 2)}\n`);
  }
  let broken = 0;
  if (options.baseline !== "") {
    broken = compare(results, options.baseline);
  }
  // Replay proves every task can pass; idle that none passes without work (the
  // refusal task excepted: doing nothing is not working around anything).
  // A live run fails only on regressions.
  const idleExpected = tasks.filter((task) => task.passes_idle === true).length;
  process.exitCode =
    options.agent === "replay" ? (summary.passed === summary.runs ? 0 : 1) : options.agent === "idle" ? (summary.passed === idleExpected * options.repeat ? 0 : 1) : broken > 0 ? 1 : 0;
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 2;
});
