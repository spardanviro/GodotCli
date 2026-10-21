#!/usr/bin/env node
// SessionStart hook: when the session starts in (or under) a Godot project,
// says so before the first turn, so the godot-cli skill is used even when the
// request never names Godot ("the coin adds 2 points instead of 1").
//
// It only adds a few lines of context; it reads no file other than looking
// for project.godot and the bridge's plugin.cfg.

import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const PROJECT_FILE = "project.godot";
const BRIDGE_MARKER = join("addons", "gdcli", "plugin.cfg");

/**
 * The nearest folder holding project.godot at or above `directory`, or null.
 * @param {string} directory
 * @returns {string | null}
 */
export function nearestProject(directory) {
  for (let current = resolve(directory); ; current = dirname(current)) {
    if (existsSync(join(current, PROJECT_FILE))) {
      return current;
    }
    if (dirname(current) === current) {
      return null;
    }
  }
}

/**
 * The context to add, or null outside a Godot project.
 * @param {unknown} event
 * @returns {{ hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: string } } | null}
 */
export function contextFor(event) {
  const input = /** @type {{ cwd?: unknown }} */ (typeof event === "object" && event !== null ? event : {});
  const cwd = typeof input.cwd === "string" && input.cwd !== "" ? input.cwd : process.cwd();
  const project = nearestProject(cwd);
  if (project === null) {
    return null;
  }
  const bridged = existsSync(join(project, BRIDGE_MARKER));
  const lines = [
    // No path: a folder name is text anyone could have chosen, and it would be read as part of these lines.
    "This session works in a Godot 4 project (there is a project.godot in the working folder or above it).",
    "Whatever the request says, it is about this game: load the godot-cli skill before reading or changing project files,",
    "and change scripts, scenes, resources and settings with the `gd` command line, which goes through the editor.",
    bridged
      ? "The gdcli bridge is installed; `gd status` shows whether an editor is running (`gd host start` starts a headless one)."
      : "The gdcli bridge is not installed in it yet: `gd bridge install` adds it.",
  ];
  return { hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: lines.join(" ") } };
}

async function main() {
  let text = "";
  for await (const chunk of process.stdin) {
    text += chunk;
  }
  let event = {};
  try {
    event = JSON.parse(text);
  } catch {
    // No event on standard input: the working directory decides.
  }
  const context = contextFor(event);
  if (context !== null) {
    process.stdout.write(`${JSON.stringify(context)}\n`);
  }
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(() => {
    // Only context: a failure here must not stop the session.
  });
}
