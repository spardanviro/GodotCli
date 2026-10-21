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
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
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
const GAME_START_TIMEOUT_MS = 30_000;
const GAME_POLL_MS = 1000;
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
      // Absolute: the session runs in the eval project, where a relative path finds nothing.
      case "--plugin-dir": options.pluginDir = resolve(value()); break;
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
      // Several filters, comma-separated: a task matching any of them.
      if (filter.split(",").some((part) => task.id.includes(part.trim()))) {
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

const NOT_RUNNING = /failed to authenticate|oauth session expired|please run \/login|invalid api key|usage limit|session limit|hit your .{0,20}limit|rate limit|credit balance is too low/iu;
// After this many sessions in a row that could not run, the rest are not started.
const MAX_INFRA_IN_A_ROW = 3;

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
      // A session that never got going (signed out, out of quota, no network) says nothing about the task.
      const said = `${stderr}\n${final.finalText}`;
      const infra = (final.isError && final.turns === 0 && transcript.length === 0) || NOT_RUNNING.test(said);
      resolvePromise({ notes, transcript, finalText: final.finalText, turns: final.turns, costUsd: final.costUsd, infra });
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

/**
 * The files a shell line plainly writes: redirections (> and >>), tee, and
 * PowerShell's -Path/-FilePath/-LiteralPath. Other ways of writing (cp,
 * an inline script) are not recognised, so a line that writes only those
 * names no target at all.
 */
function shellWriteTargets(command) {
  const targets = [];
  for (const match of command.matchAll(/(?:^|[^<>0-9&])>>?\s*(["']?)([^\s"'<>|;&]+)\1/gu)) {
    targets.push(match[2]);
  }
  for (const match of command.matchAll(/\btee\s+(?:-a\s+)?(["']?)([^\s"'<>|;&]+)\1/gu)) {
    targets.push(match[2]);
  }
  for (const match of command.matchAll(/-(?:Path|FilePath|LiteralPath)\s+(["']?)([^\s"'<>|;&]+)\1/giu)) {
    targets.push(match[2]);
  }
  return targets.filter((target) => target !== "/dev/null" && target.toLowerCase() !== "$null");
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
          if (!pattern.test(command) || !shellParts(command).some((part) => pattern.test(part) && !isPlainGd(part))) {
            return false;
          }
          // A draft written outside the project is what the skills ask for; anything
          // else with the content (a target in the project, or none recognised) counts.
          const targets = shellWriteTargets(command);
          return targets.length === 0 || targets.some((target) => insideProject(project, target.replace(/^~(?=\/)/u, homedir())));
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
    // A slow machine (CI) needs seconds before the game is up and talks to the
    // editor: ask for its tree until the node is there.
    let node;
    let lastAnswer = "";
    for (const started = Date.now(); node === undefined && Date.now() - started < GAME_START_TIMEOUT_MS; ) {
      await sleep(GAME_POLL_MS);
      const tree = gd(env, project, ["command", "game_tree"]);
      node = findInGame(tree.data?.tree ?? tree.data, check.class);
      lastAnswer = tree.success ? "the tree had none" : describeFailure(tree);
    }
    if (node === undefined) {
      return `no ${check.class} in the running game (${lastAnswer})`;
    }
    await sleep((check.settle ?? 1.5) * 1000); // Let it land before the first input.
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

/** Every node of the running game's tree, flattened: {name, type, path, groups}. */
function flatten(tree, found = []) {
  if (tree === null || typeof tree !== "object") {
    return found;
  }
  found.push({ name: String(tree.name), type: tree.type ?? tree.class, path: tree.path, groups: tree.groups ?? [] });
  for (const child of tree.children ?? []) {
    flatten(child, found);
  }
  return found;
}

/** Nodes matching {name}, {name_like} (a regex), {class} and {group}, all that are given. */
function matching(nodes, spec) {
  const pattern = spec.name_like === undefined ? undefined : new RegExp(spec.name_like, "iu");
  return nodes.filter(
    (node) =>
      (spec.name === undefined || node.name === spec.name) &&
      (pattern === undefined || pattern.test(node.name)) &&
      (spec.class === undefined || node.type === spec.class) &&
      (spec.group === undefined || node.groups.includes(spec.group)),
  );
}

/**
 * The first node a find step names: `spec` or a list of specs tried in order;
 * `text_like` (a regex) is matched against each candidate's text property.
 */
function firstFound(nodes, spec, env, project) {
  for (const one of Array.isArray(spec) ? spec : [spec]) {
    const pattern = one.text_like === undefined ? undefined : new RegExp(one.text_like, "iu");
    for (const node of matching(nodes, one)) {
      if (pattern === undefined) {
        return node;
      }
      const text = gd(env, project, ["command", "game_node_get", "--path", node.path, "--properties", '["text"]']).data?.properties?.text;
      if (typeof text === "string" && pattern.test(text)) {
        return node;
      }
    }
  }
  return undefined;
}

function gameTree(env, project) {
  const answer = gd(env, project, ["command", "game_tree", "--max-depth", "12"]);
  return answer.success ? answer.data : null;
}

/** A step's value: a literal, "$name" for a stored one, or [value, index] into a vector. */
function valueOf(raw, vars) {
  if (typeof raw === "string" && raw.startsWith("$")) {
    return vars[raw.slice(1)];
  }
  return raw;
}

/** The same with every "$name" inside arrays and objects replaced too. */
function filledIn(raw, vars) {
  if (Array.isArray(raw)) {
    return raw.map((entry) => filledIn(entry, vars));
  }
  if (raw !== null && typeof raw === "object") {
    return Object.fromEntries(Object.entries(raw).map(([key, entry]) => [key, filledIn(entry, vars)]));
  }
  return valueOf(raw, vars);
}

function holds(left, op, right) {
  // Nothing read (or not a number) never satisfies a comparison, not even !=.
  if (left === undefined || right === undefined || Number.isNaN(left) || Number.isNaN(right)) {
    return false;
  }
  switch (op) {
    case "==": return JSON.stringify(left) === JSON.stringify(right) || (typeof left === "number" && typeof right === "number" && Math.abs(left - right) < 1e-3);
    case "!=": return !holds(left, "==", right);
    case ">": return left > right;
    case ">=": return left >= right;
    case "<": return left < right;
    case "<=": return left <= right;
    default: return false;
  }
}

/**
 * A scripted look at the running game (check type "play"): the steps find
 * nodes, read, set and call them, press input actions, wait, restart the game,
 * and expect things of what they read. See evals/README.md.
 */
async function playCheck(check, project, env) {
  let failure = null;
  for (let attempt = 0; attempt < GAME_TRIES; attempt++) {
    failure = await playCheckOnce(check, project, env);
    if (failure === null) {
      return null;
    }
  }
  return failure;
}

async function startGame(check, project, env) {
  const play = gd(env, project, ["command", "editor_play", ...(check.scene === undefined ? [] : ["--scene", check.scene])]);
  if (!play.success) {
    return `editor_play: ${describeFailure(play)}`;
  }
  for (const started = Date.now(); Date.now() - started < GAME_START_TIMEOUT_MS; ) {
    await sleep(GAME_POLL_MS);
    const tree = gameTree(env, project);
    if (tree !== null && flatten(tree.tree).length > 1) {
      await sleep((check.settle ?? 1) * 1000);
      return null;
    }
  }
  return "the game did not start";
}

async function playCheckOnce(check, project, env) {
  const found = {};
  // $rand: a number of this run, so that what an earlier run left behind (user://) cannot pass for this one.
  const vars = { rand: 1000 + Math.floor(Math.random() * 9000) };
  const pathOf = (alias) => found[alias] ?? alias;
  try {
    const started = await startGame(check, project, env);
    if (started !== null) {
      return started;
    }
    for (const [index, step] of (check.steps ?? []).entries()) {
      const at = `step ${index + 1}`;
      if (step.wait !== undefined) {
        await sleep(step.wait * 1000);
      } else if (step.restart === true) {
        gd(env, project, ["command", "editor_stop"]);
        // The old game must be gone first, or its tree would pass for the new one's.
        for (const begun = Date.now(); gameTree(env, project) !== null && Date.now() - begun < GAME_START_TIMEOUT_MS; ) {
          await sleep(GAME_POLL_MS);
        }
        const again = await startGame(check, project, env);
        if (again !== null) {
          return `${at}: ${again}`;
        }
      } else if (step.find !== undefined) {
        let node;
        for (const begun = Date.now(); node === undefined && Date.now() - begun < (step.timeout ?? 10) * 1000; ) {
          const tree = gameTree(env, project);
          node = tree === null ? undefined : firstFound(flatten(tree.tree), step.find, env, project);
          if (node === undefined) {
            await sleep(GAME_POLL_MS);
          }
        }
        if (node === undefined) {
          return `${at}: no node like ${JSON.stringify(step.find)} in the running game`;
        }
        found[step.as] = node.path;
      } else if (step.get !== undefined) {
        const answer = gd(env, project, ["command", "game_node_get", "--path", pathOf(step.get), "--properties", JSON.stringify([step.property])]);
        const entry = answer.data?.properties?.[step.property];
        if (!answer.success || entry === undefined) {
          return `${at}: could not read ${step.property} of ${pathOf(step.get)} (${answer.success ? "no such property" : describeFailure(answer)})`;
        }
        const value = entry !== null && typeof entry === "object" && "value" in entry ? entry.value : entry;
        vars[step.as] = step.index === undefined ? value : value?.[step.index];
      } else if (step.distance !== undefined) {
        const points = step.distance.map((alias) => {
          const entry = gd(env, project, ["command", "game_node_get", "--path", pathOf(alias), "--properties", '["global_position"]']).data?.properties?.global_position;
          return entry?.value ?? entry;
        });
        if (!points.every(Array.isArray)) {
          return `${at}: could not read the positions of ${step.distance.join(" and ")}`;
        }
        vars[step.as] = Math.hypot(points[0][0] - points[1][0], points[0][1] - points[1][1]);
      } else if (step.set !== undefined) {
        const answer = gd(env, project, ["command", "game_node_set", "--path", pathOf(step.set), "--properties", JSON.stringify(filledIn(step.properties, vars))]);
        if (!answer.success) {
          return `${at}: game_node_set ${pathOf(step.set)}: ${describeFailure(answer)}`;
        }
      } else if (step.call !== undefined) {
        const answer = gd(env, project, ["command", "game_call", "--path", pathOf(step.call), "--method", step.method, "--arguments", JSON.stringify(filledIn(step.arguments ?? [], vars))]);
        if (!answer.success) {
          return `${at}: game_call ${pathOf(step.call)}.${step.method}: ${describeFailure(answer)}`;
        }
        if (step.as !== undefined) {
          const result = answer.data?.result;
          vars[step.as] = result !== null && typeof result === "object" && "value" in result ? result.value : result;
        }
      } else if (step.input !== undefined) {
        const answer = gd(env, project, ["command", "game_input", "--action", step.input, "--hold", String(step.hold ?? 0.1)]);
        if (!answer.success) {
          return `${at}: game_input ${step.input}: ${describeFailure(answer)}`;
        }
      } else if (step.release !== undefined) {
        const answer = gd(env, project, ["command", "game_input", "--action", step.release, "--pressed", "false"]);
        if (!answer.success) {
          return `${at}: game_input ${step.release} (release): ${describeFailure(answer)}`;
        }
      } else if (step.count !== undefined) {
        const tree = gameTree(env, project);
        vars[step.as] = tree === null ? -1 : matching(flatten(tree.tree), step.count).length;
      } else if (step.paused !== undefined) {
        vars[step.paused] = gameTree(env, project)?.paused;
      } else if (step.expect !== undefined) {
        const left = valueOf(step.expect.left, vars);
        const raw = valueOf(step.expect.right, vars);
        // A number on the right may be scaled and shifted: "$d1 < $d0 × 0.7", "$x3 < $x2 + 90".
        const right = typeof raw === "number" ? raw * (step.expect.scale ?? 1) + (step.expect.plus ?? 0) : raw;
        if (!holds(left, step.expect.op, right)) {
          const shown = `${step.expect.right}${step.expect.scale === undefined ? "" : ` × ${step.expect.scale}`}${step.expect.plus === undefined ? "" : ` + ${step.expect.plus}`}`;
          return `${at}: expected ${step.expect.left} ${step.expect.op} ${shown}, got ${JSON.stringify(left)} vs ${JSON.stringify(right)}${step.why === undefined ? "" : ` (${step.why})`}`;
        }
      } else {
        return `${at}: unknown step ${JSON.stringify(step)}`;
      }
    }
    return null;
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
  // A game started from the headless editor still opens a window, and on a
  // machine without a display (CI) it quits at once. The game checks run it headless.
  const headlessGame = gd(env, project, ["command", "project_settings_set", "--name", "editor/run/main_run_args", "--value", JSON.stringify("--headless"), "--yes"]);
  if (!headlessGame.success) {
    return `setup main_run_args: ${describeFailure(headlessGame)}`;
  }
  // Every project is called "Eval": without its own user:// folder, runs side by side would share save files.
  for (const [name, value] of [["application/config/use_custom_user_dir", true], ["application/config/custom_user_dir_name", `gdcli-eval/${basename(dirname(project))}`]]) {
    const set = gd(env, project, ["command", "project_settings_set", "--name", name, "--value", JSON.stringify(value), "--yes"]);
    if (!set.success) {
      return `setup ${name}: ${describeFailure(set)}`;
    }
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
    for (const check of task.checks.filter((entry) => entry.type === "game" || entry.type === "play")) {
      const failure = check.type === "game" ? await gameCheck(check, project, env) : await playCheck(check, project, env);
      if (failure !== null) {
        result.failures.push(`${check.type}: ${failure}`);
      }
    }
    gd(env, project, ["host", "stop"]);
    const engine = engineChecks(task, project, root);
    task.checks.forEach((check, index) => {
      if (check.type === "game" || check.type === "play") {
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
  let infraInARow = 0;
  const worker = async () => {
    for (let next = queue.shift(); next !== undefined; next = queue.shift()) {
      const result = await runTask(next.task, options, next.attempt);
      results.push(result);
      infraInARow = result.infra ? infraInARow + 1 : 0;
      if (options.agent === "claude" && infraInARow >= MAX_INFRA_IN_A_ROW && queue.length > 0) {
        process.stdout.write(`${infraInARow} sessions in a row could not run (${result.failures.concat(result.notes).join("; ").slice(0, 300)}); stopping, ${queue.length} left.\n`);
        queue.length = 0;
      }
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
  // Job logs need a login; annotations are readable by anyone through the API.
  if (process.env.GITHUB_ACTIONS === "true") {
    for (const result of results.filter((entry) => !entry.passed)) {
      const detail = [...result.failures, ...result.notes].join(" | ").replace(/[\r\n%]/gu, " ");
      process.stdout.write(`::error title=eval ${result.id}::${detail.slice(0, 900)}\n`);
    }
  }
}

// A task whose average turns or cost moved by more than this share is named.
const EFFORT_CHANGE = 0.3;

/** Per task: did every counted run pass, and the average turns and cost. */
function perTask(results) {
  const tasks = new Map();
  for (const result of results.filter((entry) => !entry.infra)) {
    const task = tasks.get(result.id) ?? { passed: true, turns: 0, cost: 0, runs: 0 };
    task.passed &&= result.passed;
    task.turns += result.turns;
    task.cost += result.costUsd;
    task.runs += 1;
    tasks.set(result.id, task);
  }
  for (const task of tasks.values()) {
    task.turns /= task.runs;
    task.cost /= task.runs;
  }
  return tasks;
}

/**
 * Against an earlier result file: which tasks now fail that passed (a non-zero
 * exit), which pass that failed, and, for a model run, where the average turns
 * or cost moved by more than EFFORT_CHANGE. With every task passing, the
 * effort is what still tells two versions of the skills apart.
 */
function compare(results, baselineFile) {
  const baseline = JSON.parse(readFileSync(baselineFile, "utf8"));
  const before = perTask(baseline.results);
  const now = perTask(results);
  const broken = [...now].filter(([id, task]) => before.get(id)?.passed === true && !task.passed).map(([id]) => id);
  const fixed = [...now].filter(([id, task]) => before.get(id)?.passed === false && task.passed).map(([id]) => id);
  process.stdout.write(`\nAgainst ${baselineFile} (${Math.round(baseline.summary.rate * 100)}%): fixed ${fixed.length} ${JSON.stringify(fixed)}, broken ${broken.length} ${JSON.stringify(broken)}\n`);
  const moved = [];
  for (const [id, task] of now) {
    const old = before.get(id);
    if (old === undefined || old.turns === 0 || task.turns === 0) {
      continue;
    }
    const turns = task.turns / old.turns - 1;
    const cost = old.cost > 0 ? task.cost / old.cost - 1 : 0;
    if (Math.abs(turns) > EFFORT_CHANGE || Math.abs(cost) > EFFORT_CHANGE) {
      const percent = (share) => `${share > 0 ? "+" : ""}${Math.round(share * 100)}%`;
      moved.push(`  ${id.padEnd(38)} turns ${old.turns.toFixed(1)} -> ${task.turns.toFixed(1)} (${percent(turns)}), cost $${old.cost.toFixed(2)} -> $${task.cost.toFixed(2)} (${percent(cost)})`);
    }
  }
  if (moved.length > 0) {
    process.stdout.write(`Effort moved by more than ${EFFORT_CHANGE * 100}%:\n${moved.join("\n")}\n`);
  }
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
  // A folder that is not a plugin would only mean sessions without it, scored as if with it.
  if (options.pluginDir !== "" && !existsSync(join(options.pluginDir, ".claude-plugin", "plugin.json"))) {
    throw new Error(`--plugin-dir ${options.pluginDir} has no .claude-plugin/plugin.json`);
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
