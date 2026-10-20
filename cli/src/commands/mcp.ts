import { closeSync, existsSync, lstatSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

import type { CommandHandler, CommandResult, Context, GlobalOptions } from "../context.js";
import { errorOf, isEnvelopeError, success } from "../envelope.js";
import { serveMcp } from "../mcp/server.js";
import { findProject, nonEmpty } from "../project.js";
import { mergeToml } from "./mcp-toml.js";
import { fail, parseCommandArgs, usage } from "./shared.js";

export const SERVER_NAME = "gdcli";
const JSON_INDENT = 2;
/** A new user-level file holds other servers' keys too: only its owner reads it. */
const OWNER_ONLY = 0o600;
const NEW_FILE = 0o644;
const MODE_BITS = 0o777;

export interface ServerEntry {
  readonly command: string;
  readonly args: readonly string[];
}

/** Where each client keeps its MCP servers, and in what shape. */
interface ClientFormat {
  readonly file: (folder: string, context: Context) => string;
  readonly userScope: boolean;
  /** The file's new text, given its old one (empty when absent); an error if it cannot be changed safely. */
  readonly write: (old: string, entry: ServerEntry) => string | Error;
  /** The entry as it appears in the file, for the preview. */
  readonly shown: (entry: ServerEntry) => string;
  readonly note: string;
}

function mergeJson(old: string, key: string, value: unknown): string | Error {
  let root: unknown = {};
  if (old.trim() !== "") {
    try {
      root = JSON.parse(old);
    } catch {
      return new Error("The existing file is not valid JSON; fix or remove it first.");
    }
  }
  if (typeof root !== "object" || root === null || Array.isArray(root)) {
    return new Error("The existing file does not hold a JSON object.");
  }
  const servers = (root as Record<string, unknown>)[key];
  if (servers !== undefined && (typeof servers !== "object" || servers === null || Array.isArray(servers))) {
    return new Error(`"${key}" in the existing file is not an object.`);
  }
  const merged = { ...(root as Record<string, unknown>), [key]: { ...(servers as Record<string, unknown> | undefined), [SERVER_NAME]: value } };
  return `${JSON.stringify(merged, null, JSON_INDENT)}\n`;
}

const stdio = (entry: ServerEntry): Record<string, unknown> => ({ command: entry.command, args: entry.args });

function jsonClient(file: (folder: string) => string, key: string, value: (entry: ServerEntry) => unknown, note: string): ClientFormat {
  return {
    file,
    userScope: false,
    write: (old, entry) => mergeJson(old, key, value(entry)),
    shown: (entry) => JSON.stringify({ [key]: { [SERVER_NAME]: value(entry) } }, null, JSON_INDENT),
    note,
  };
}

const NOT_SHARED = "The entry holds this machine's paths: keep the file out of version control, or write it with --command gd.";

const CLIENTS: Readonly<Record<string, ClientFormat>> = {
  claude: jsonClient((folder) => join(folder, ".mcp.json"), "mcpServers", (entry) => ({ type: "stdio", ...stdio(entry) }), `Claude Code asks once before it uses a server from .mcp.json. ${NOT_SHARED}`),
  cursor: jsonClient((folder) => join(folder, ".cursor", "mcp.json"), "mcpServers", stdio, `Enable the server in Cursor's MCP settings if it is not picked up. ${NOT_SHARED}`),
  vscode: jsonClient((folder) => join(folder, ".vscode", "mcp.json"), "servers", (entry) => ({ type: "stdio", ...stdio(entry) }), `VS Code starts it from the Chat view (agent mode). ${NOT_SHARED}`),
  gemini: jsonClient((folder) => join(folder, ".gemini", "settings.json"), "mcpServers", stdio, `Gemini CLI reads it at start. ${NOT_SHARED}`),
  codex: {
    file: (_folder, context) => join(nonEmpty(context.io.env["CODEX_HOME"]) ?? join(context.homeDir, ".codex"), "config.toml"),
    userScope: true,
    write: (old, entry) => mergeToml(old, SERVER_NAME, entry),
    shown: (entry) => mergeToml("", SERVER_NAME, entry) as string,
    note: "Codex reads it at start; the server is there for every project, so it names this one with --project.",
  },
};

export const MCP_CLIENTS = Object.keys(CLIENTS);

/**
 * How the client starts this server. By default the very gd this is (its node
 * and script), so it works whether or not gd is on the PATH the client sees;
 * --command gd writes the bare name instead, for a file shared with others.
 */
function entryFor(context: Context, project: string, bareName: boolean): ServerEntry {
  const own = ["mcp", "--project", project];
  if (bareName || context.launcher === undefined || context.launcher.length === 0) {
    return { command: "gd", args: own };
  }
  const [command, ...rest] = context.launcher;
  return { command: command ?? "gd", args: [...rest, ...own] };
}

/** The first symbolic link on the way to the file (its folders included), if any. */
export function linkOnTheWay(file: string, stopAt: string): string | undefined {
  for (let path = file; path.length > stopAt.length && path !== dirname(path); path = dirname(path)) {
    try {
      if (lstatSync(path).isSymbolicLink()) {
        return path;
      }
    } catch {
      // Not there yet: nothing to follow.
    }
  }
  return undefined;
}

/**
 * Written next to the file and moved over it. The partial file is created
 * exclusively (a link planted under its name is not followed), and the old
 * file's permissions are kept.
 */
function writeAtomically(path: string, text: string, mode: number): void {
  mkdirSync(dirname(path), { recursive: true });
  const partial = `${path}.gdcli-partial`;
  try {
    lstatSync(partial);
    unlinkSync(partial); // A leftover, or a link planted under its name: removed itself, never what it points at.
  } catch {
    // None there.
  }
  const handle = openSync(partial, "wx", mode);
  try {
    writeSync(handle, text);
  } finally {
    closeSync(handle);
  }
  try {
    renameSync(partial, path);
  } catch (error: unknown) {
    unlinkSync(partial);
    throw error;
  }
}

async function configure(context: Context, globals: GlobalOptions, args: readonly string[]): Promise<CommandResult> {
  const parsed = parseCommandArgs(args, { dir: { type: "string" }, command: { type: "string" } });
  if (typeof parsed === "string") {
    return usage("mcp", parsed);
  }
  const client = parsed.positionals[0];
  if (client === undefined || !Object.hasOwn(CLIENTS, client) || parsed.positionals.length > 1) {
    return usage("mcp", `Name one client: ${MCP_CLIENTS.join(", ")}.`);
  }
  const format = CLIENTS[client] as ClientFormat;
  const bare = parsed.values["command"];
  if (bare !== undefined && bare !== "gd") {
    return usage("mcp", "--command takes only gd (write the bare command name instead of this gd's path).");
  }
  if (bare === "gd" && context.platform === "win32") {
    // A client would need cmd to start gd.cmd, and cmd looks in the project folder before PATH.
    return usage("mcp", "--command gd is not offered on Windows: leave it out to write this gd's own path.");
  }
  const project = findProject(context, globals);
  if (isEnvelopeError(project)) {
    return fail("mcp", project);
  }
  const dir = parsed.values["dir"];
  const folder = typeof dir === "string" ? resolve(context.cwd, dir) : project;
  const file = format.file(folder, context);
  const link = linkOnTheWay(file, format.userScope ? context.homeDir : folder);
  if (link !== undefined) {
    return fail("mcp", errorOf("PRECONDITION_FAILED", "The configuration file, or a folder on the way to it, is a symbolic link; gd does not write through links.", undefined, { link }));
  }
  const entry = entryFor(context, project, bare === "gd");
  let old = "";
  let mode = format.userScope ? OWNER_ONLY : NEW_FILE;
  if (existsSync(file)) {
    try {
      old = readFileSync(file, "utf8");
      mode = lstatSync(file).mode & MODE_BITS;
    } catch {
      return fail("mcp", errorOf("COMMAND_FAILED", "The client's configuration file could not be read.", undefined, { file }));
    }
  }
  const text = format.write(old, entry);
  if (text instanceof Error) {
    return fail("mcp", errorOf("PRECONDITION_FAILED", text.message, "Change the file by hand, or move it aside and run this again.", { file }));
  }
  // Only gd's own entry is shown: the rest of the file may hold other servers' keys.
  const shown = format.shown(entry);
  const data = { client, file, scope: format.userScope ? "user" : "project", server: { name: SERVER_NAME, ...entry }, entry: shown, written: false, note: format.note };
  if (!globals.yes) {
    const preview = `Would add to ${file}:\n\n${shown}\n\nRun again with --yes to write it. ${format.note}\n`;
    return { envelope: success("mcp", data, {}, ["Nothing was written: add --yes."]), human: preview };
  }
  try {
    writeAtomically(file, text, mode);
  } catch {
    return fail("mcp", errorOf("COMMAND_FAILED", "The client's configuration file could not be written.", undefined, { file }));
  }
  return { envelope: success("mcp", { ...data, written: true }), human: `Wrote ${file}. ${format.note}\n` };
}

/**
 * `gd mcp`: serve the tools over standard input and output until the client
 * closes them. `gd mcp configure <client> [--dir <folder>] [--command gd]`:
 * add this server to a client's configuration (shown first; written with --yes).
 */
export const mcpCommand: CommandHandler = async (context, globals, args) => {
  if (args[0] === "configure") {
    return configure(context, globals, args.slice(1));
  }
  if (args.length > 0) {
    return usage("mcp", 'gd mcp takes no arguments (or "configure <client>").');
  }
  const lines = context.io.readLines;
  if (lines === undefined) {
    return fail("mcp", errorOf("INTERNAL_ERROR", "Standard input cannot be read line by line here."));
  }
  await serveMcp({ context, globals, lines: lines() });
  // Standard output belongs to the protocol: nothing is printed after it.
  return { envelope: success("mcp", { served: true }), human: "", printed: true };
};
