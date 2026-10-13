// Checks the Claude plugin without an editor: the manifest and hook
// configuration parse, every skill has the front matter Claude Code reads,
// the files a skill points to exist, and every bridge command and argument a
// skill mentions is one the bridge has (as listed in the generated
// references/commands.md, which scripts/bridge-test.mjs keeps true).
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

import { readCommands } from "./plugin-commands.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const PLUGIN = join(ROOT, "plugin");
const SKILLS = join(PLUGIN, "skills");
const MAX_DESCRIPTION_LENGTH = 1024;
const MAX_SKILL_LINES = 500;
// Files written by scripts/import-knowledge.mjs: their text is not ours to check.
const IMPORTED = new Set(["gotchas.md", "api.md"]);
// Options of `gd` itself, which may follow any command.
const GLOBAL_FLAGS = new Set(["args", "args_file", "json", "format", "project", "godot", "instance", "timeout", "yes", "dry_run"]);
const COMMAND_PREFIXES = ["animation", "edit", "editor", "fs", "game", "host", "navigation", "node", "project", "resource", "scene", "sprite_frames", "tilemap", "tileset"];
const FILE_SUFFIX = "_file";

/** @type {string[]} */
const problems = [];

/**
 * @param {string} file
 * @param {string} message
 */
function problem(file, message) {
  problems.push(`${relative(ROOT, file).replaceAll("\\", "/")}: ${message}`);
}

/**
 * @param {string} file
 * @returns {unknown}
 */
function readJson(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch (error) {
    problem(file, `is not valid JSON (${error instanceof Error ? error.message : "unknown error"})`);
    return null;
  }
}

/**
 * @param {string} directory
 * @returns {string[]} Markdown files below it
 */
function markdownFiles(directory) {
  return readdirSync(directory).flatMap((name) => {
    const path = join(directory, name);
    if (statSync(path).isDirectory()) {
      return markdownFiles(path);
    }
    return name.endsWith(".md") ? [path] : [];
  });
}

/**
 * The `name` and `description` of a skill's front matter.
 * @param {string} text
 * @returns {{ name?: string, description?: string } | null}
 */
function frontMatter(text) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n/u.exec(text);
  if (match === null) {
    return null;
  }
  /** @type {Record<string, string>} */
  const fields = {};
  for (const line of (match[1] ?? "").split(/\r?\n/u)) {
    const field = /^(\w+):\s*(.*)$/u.exec(line);
    if (field !== null) {
      fields[field[1] ?? ""] = (field[2] ?? "").trim();
    }
  }
  return fields;
}

function checkManifest() {
  const manifest = /** @type {{ name?: unknown, version?: unknown, description?: unknown } | null} */ (readJson(join(PLUGIN, ".claude-plugin", "plugin.json")));
  if (manifest !== null && (typeof manifest.name !== "string" || typeof manifest.version !== "string" || typeof manifest.description !== "string")) {
    problem(join(PLUGIN, ".claude-plugin", "plugin.json"), "needs name, version and description");
  }

  const hooksFile = join(PLUGIN, "hooks", "hooks.json");
  const hooks = /** @type {{ hooks?: Record<string, { hooks?: { command?: string }[] }[]> } | null} */ (readJson(hooksFile));
  for (const group of Object.values(hooks?.hooks ?? {}).flat()) {
    for (const hook of group.hooks ?? []) {
      const script = /\$\{CLAUDE_PLUGIN_ROOT\}\/([^"\s]+)/u.exec(hook.command ?? "")?.[1];
      if (script === undefined || !existsSync(join(PLUGIN, script))) {
        problem(hooksFile, `a hook runs a file that is not in the plugin: ${hook.command ?? ""}`);
      }
    }
  }

  const marketplaceFile = join(ROOT, ".claude-plugin", "marketplace.json");
  const marketplace = /** @type {{ plugins?: { name?: string, source?: string }[] } | null} */ (readJson(marketplaceFile));
  for (const entry of marketplace?.plugins ?? []) {
    if (typeof entry.source !== "string" || !existsSync(join(ROOT, entry.source, ".claude-plugin", "plugin.json"))) {
      problem(marketplaceFile, `plugin "${entry.name ?? ""}" does not point at a plugin folder`);
    } else if (manifest !== null && entry.name !== manifest.name) {
      problem(marketplaceFile, `lists "${entry.name ?? ""}" but the plugin calls itself "${String(manifest.name)}"`);
    }
  }
}

/**
 * @param {string} skill folder name
 * @returns {void}
 */
function checkSkill(skill) {
  const file = join(SKILLS, skill, "SKILL.md");
  if (!existsSync(file)) {
    problem(join(SKILLS, skill), "has no SKILL.md");
    return;
  }
  const text = readFileSync(file, "utf8");
  const fields = frontMatter(text);
  if (fields === null) {
    problem(file, "does not start with front matter");
    return;
  }
  if (fields.name !== skill) {
    problem(file, `front matter name "${fields.name ?? ""}" is not the folder name`);
  }
  const length = fields.description?.length ?? 0;
  if (length === 0 || length > MAX_DESCRIPTION_LENGTH) {
    problem(file, `description must be 1 to ${MAX_DESCRIPTION_LENGTH} characters, is ${length}`);
  }
  if (text.split("\n").length > MAX_SKILL_LINES) {
    problem(file, `is longer than ${MAX_SKILL_LINES} lines; move detail into references/`);
  }
}

/**
 * Files under references/ that the text names must exist, in the same skill
 * or in the skill the sentence names.
 * @param {string} file
 * @param {string} text
 * @param {string} skill
 * @param {readonly string[]} skills
 */
function checkReferences(file, text, skill, skills) {
  for (const match of text.matchAll(/`(references\/[\w.-]+\.md)`/gu)) {
    const target = match[1] ?? "";
    if (!skills.some((candidate) => (candidate === skill || text.includes(`\`${candidate}\``)) && existsSync(join(SKILLS, candidate, target)))) {
      problem(file, `points to ${target}, which does not exist`);
    }
  }
}

/**
 * @param {string} file
 * @param {string} text
 * @param {Map<string, Set<string>>} commands
 * @param {readonly string[]} skills
 */
function checkCommands(file, text, commands, skills) {
  // A name that looks like a bridge command, wherever it stands in backticks or after `gd command`.
  const named = new RegExp(`(?:\`|gd command )((?:${COMMAND_PREFIXES.join("|")})_[a-z_]+)\\b`, "gu");
  for (const match of text.matchAll(named)) {
    const name = match[1] ?? "";
    if (!commands.has(name) && !skills.includes(name) && !name.endsWith("_")) {
      problem(file, `mentions \`${name}\`, which is not a command of the bridge`);
    }
  }

  // The flags of each call, up to the end of the (continued) line or the closing backtick.
  for (const match of text.matchAll(/gd command (\w+)((?:[^\n`]|\\\n)*)/gu)) {
    const known = commands.get(match[1] ?? "");
    if (known === undefined) {
      continue;
    }
    // Quoted values are JSON or text of the caller; flags are outside them.
    const outsideQuotes = (match[2] ?? "").replaceAll(/'[^']*'|"[^"]*"/gu, "");
    for (const flag of outsideQuotes.matchAll(/(?:^|\s)--([a-z][a-z-]*)/gu)) {
      const name = (flag[1] ?? "").replaceAll("-", "_");
      const fromFile = name.endsWith(FILE_SUFFIX) ? name.slice(0, -FILE_SUFFIX.length) : "";
      if (!known.has(name) && !known.has(fromFile) && !GLOBAL_FLAGS.has(name)) {
        problem(file, `\`gd command ${match[1] ?? ""}\` has no argument --${flag[1] ?? ""}`);
      }
    }
  }
}

function main() {
  checkManifest();
  const commands = readCommands();
  if (commands.size === 0) {
    problem(join(SKILLS, "godot-cli", "references", "commands.md"), "lists no commands");
  }
  const skills = readdirSync(SKILLS).filter((name) => statSync(join(SKILLS, name)).isDirectory());
  for (const skill of skills) {
    checkSkill(skill);
    for (const file of markdownFiles(join(SKILLS, skill))) {
      const name = file.split(/[\\/]/u).at(-1) ?? "";
      if (IMPORTED.has(name) || name === "commands.md") {
        continue;
      }
      const text = readFileSync(file, "utf8");
      // Multi-line JSON in single quotes would otherwise hide the rest of a call.
      checkReferences(file, text, skill, skills);
      checkCommands(file, text.replaceAll(/'\{[^']*\}'/gu, "'{}'"), commands, skills);
    }
  }

  if (problems.length > 0) {
    process.stderr.write(`plugin check failed:\n- ${problems.join("\n- ")}\n`);
    process.exit(1);
  }
  process.stdout.write(`plugin check passed: ${skills.length} skills, ${commands.size} commands\n`);
}

main();
