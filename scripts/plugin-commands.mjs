// The command reference of the plugin's godot-cli skill is written from what a
// running bridge reports, so it cannot drift from the commands themselves.
// scripts/bridge-test.mjs compares the two on every run; to rewrite the file:
//   GDCLI_UPDATE_PLUGIN=1 GODOT_BIN=... node scripts/bridge-test.mjs

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const COMMANDS_FILE = fileURLToPath(new URL("../plugin/skills/godot-cli/references/commands.md", import.meta.url));

const GROUP_ORDER = ["editor", "scene", "node", "resource", "animation", "fs", "project", "edit", "game", "exec", "host"];
const REQUIREMENTS = {
  scene_open: "a scene open in the editor",
  playing: "the game running from the editor (editor_play)",
  not_playing: "the game not to be running",
};

/**
 * @typedef {{ type?: string, description?: string, default?: unknown, enum?: unknown[], minimum?: number, maximum?: number }} Parameter
 * @typedef {{ name: string, group?: string, summary?: string, risk?: string, undoable?: boolean, requires?: string[], returns?: string, custom?: boolean,
 *   params?: { properties?: Record<string, Parameter>, required?: string[] } }} Descriptor
 */

/**
 * @param {string} name
 * @param {Parameter} parameter
 * @param {boolean} required
 * @returns {string}
 */
function parameterLine(name, parameter, required) {
  const notes = [];
  if (required) {
    notes.push("required");
  }
  if (parameter.default !== undefined) {
    notes.push(`default ${JSON.stringify(parameter.default)}`);
  }
  if (Array.isArray(parameter.enum)) {
    notes.push(`one of ${parameter.enum.join(", ")}`);
  }
  if (parameter.minimum !== undefined || parameter.maximum !== undefined) {
    notes.push(`${parameter.minimum ?? ""}..${parameter.maximum ?? ""}`);
  }
  const description = parameter.description === undefined ? "" : ` ${parameter.description}`;
  return `- \`${name}\` (${[parameter.type ?? "any JSON value", ...notes].join(", ")})${description}`;
}

/**
 * @param {Descriptor} descriptor
 * @returns {string}
 */
function commandSection(descriptor) {
  const traits = [descriptor.risk ?? "write"];
  if (descriptor.undoable === true) {
    traits.push("one undo step");
  }
  const needs = (descriptor.requires ?? []).map((requirement) => REQUIREMENTS[requirement] ?? requirement);
  const properties = descriptor.params?.properties ?? {};
  const required = new Set(descriptor.params?.required ?? []);
  const names = Object.keys(properties).sort((left, right) => Number(required.has(right)) - Number(required.has(left)) || left.localeCompare(right));
  return [
    `### ${descriptor.name}`,
    "",
    `${descriptor.summary ?? ""} [${traits.join(", ")}]${needs.length > 0 ? ` Needs ${needs.join(" and ")}.` : ""}`,
    "",
    ...(names.length > 0 ? [...names.map((name) => parameterLine(name, properties[name] ?? {}, required.has(name))), ""] : ["No arguments.", ""]),
    `Returns: ${descriptor.returns ?? "nothing in particular"}`,
  ].join("\n");
}

/**
 * @param {readonly Descriptor[]} descriptors what GET /v1/commands lists
 * @returns {string} the reference file
 */
export function renderCommands(descriptors) {
  const builtIn = descriptors.filter((descriptor) => descriptor.custom !== true);
  const groups = [...new Set(builtIn.map((descriptor) => descriptor.group ?? "other"))].sort(
    (left, right) => (GROUP_ORDER.indexOf(left) + 1 || GROUP_ORDER.length + 1) - (GROUP_ORDER.indexOf(right) + 1 || GROUP_ORDER.length + 1) || left.localeCompare(right),
  );
  const sections = groups.map((group) =>
    [`## ${group}`, "", ...builtIn.filter((descriptor) => (descriptor.group ?? "other") === group).map((descriptor) => `${commandSection(descriptor)}\n`)].join("\n"),
  );
  return [
    "# Commands of the editor bridge",
    "",
    `The ${builtIn.length} commands a running editor answers, each run as \`gd command <name> --<argument> <value>\`. \`gd list --json\` prints the same`,
    "for the editor you are talking to, including commands the project adds itself. Search this file for the command you need; do not read it whole.",
    "",
    "After the summary, in brackets: the risk tier (`read`, `write`, `destructive`, `exec`) and whether the change is one step on the editor's undo stack.",
    "Argument values follow `values.md`. Generated from the bridge by `scripts/bridge-test.mjs`; do not edit by hand.",
    "",
    sections.join("\n"),
  ].join("\n");
}

/**
 * The commands and their argument names, read back from the reference file.
 * @returns {Map<string, Set<string>>}
 */
export function readCommands() {
  const commands = new Map();
  let current = null;
  for (const line of readFileSync(COMMANDS_FILE, "utf8").split(/\r?\n/u)) {
    const heading = /^### (\w+)$/u.exec(line);
    if (heading !== null) {
      current = new Set();
      commands.set(heading[1], current);
      continue;
    }
    const argument = /^- `(\w+)` \(/u.exec(line);
    if (argument !== null && current !== null) {
      current.add(argument[1]);
    }
  }
  return commands;
}
