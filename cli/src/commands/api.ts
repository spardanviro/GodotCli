import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, renameSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";

import type { CommandHandler, Context } from "../context.js";
import { type EnvelopeError, errorOf, isEnvelopeError, success } from "../envelope.js";
import { type Godot, requireGodot } from "../godot.js";
import { gdcliHome } from "../project.js";
import { sanitize } from "../text.js";
import { isWritableOnlyByUser, readPrivateFile } from "../trust.js";
import { fail, parseCommandArgs, usage } from "./shared.js";

const CACHE_DIR_NAME = "cache";
const DUMP_FILE = "extension_api.json";
const DUMP_TIMEOUT_MS = 180_000;
const MAX_SEARCH_RESULTS = 50;
const BRIEF_LENGTH = 160;
const OWNER_ONLY_DIR = 0o700;
const MAX_DUMP_BYTES = 128 * 1024 * 1024;
const KEY_LENGTH = 16;

interface ApiArgument {
  readonly name: string;
  readonly type: string;
  readonly default_value?: string;
}

interface ApiMethod {
  readonly name: string;
  readonly return_value?: { readonly type: string };
  readonly arguments?: readonly ApiArgument[];
  readonly is_static?: boolean;
  readonly is_virtual?: boolean;
  readonly description?: string;
}

interface ApiMember {
  readonly name: string;
  readonly type?: string;
  readonly value?: number;
  readonly description?: string;
  readonly arguments?: readonly ApiArgument[];
}

interface ApiClass {
  readonly name: string;
  readonly inherits?: string;
  readonly brief_description?: string;
  readonly description?: string;
  readonly methods?: readonly ApiMethod[];
  readonly properties?: readonly ApiMember[];
  readonly signals?: readonly ApiMember[];
  readonly constants?: readonly ApiMember[];
  readonly enums?: readonly { readonly name: string; readonly values: readonly ApiMember[] }[];
}

interface ApiDump {
  readonly classes: readonly ApiClass[];
}

interface LoadedApi {
  readonly api: ApiDump;
  readonly warnings: readonly string[];
}

const DUMP_FLAGS = ["--dump-extension-api-with-docs", "--dump-extension-api"] as const;
const UNDOCUMENTED_WARNING =
  "This Godot build could not export its documentation; names and signatures are complete, descriptions are missing.";

/**
 * The cache is keyed by the binary itself, not by the version it claims, so
 * a dump made by one program is never served as the API of another.
 */
function cachePath(context: Context, godot: Godot): string {
  const safeVersion = godot.version.text.replace(/[^A-Za-z0-9._-]/gu, "_");
  const real = realpathSync(godot.bin);
  const stats = statSync(real);
  const key = createHash("sha256").update(`${real}|${stats.size}|${stats.mtimeMs}`).digest("hex").slice(0, KEY_LENGTH);
  return join(gdcliHome(context), CACHE_DIR_NAME, `api-${safeVersion}-${key}.json`);
}

/**
 * The engine writes its API description into the working directory, so it is
 * dumped in a scratch folder and then moved into the per-version cache.
 */
async function loadApi(context: Context, godot: Godot): Promise<LoadedApi | EnvelopeError> {
  const cached = cachePath(context, godot);
  if (!existsSync(cached)) {
    const cacheDir = join(gdcliHome(context), CACHE_DIR_NAME);
    mkdirSync(cacheDir, { recursive: true, mode: OWNER_ONLY_DIR });
    // What is cached here is later shown to the agent as documentation.
    if (!isWritableOnlyByUser(cacheDir, context.platform)) {
      return errorOf("PRECONDITION_FAILED", "The gd cache folder can be changed by other users.", "Make it writable only by you.", {
        path: cacheDir,
      });
    }
    const scratch = mkdtempSync(join(cacheDir, "dump-"));
    const dumped = join(scratch, DUMP_FILE);
    try {
      // Some builds crash while collecting the documentation; the plain dump
      // still has every class, member and signature.
      let result;
      for (const flag of DUMP_FLAGS) {
        result = await context.processes.run(godot.bin, ["--headless", flag], { cwd: scratch, timeoutMs: DUMP_TIMEOUT_MS });
        if (existsSync(dumped)) {
          break;
        }
      }
      if (!existsSync(dumped)) {
        return errorOf("COMMAND_FAILED", "Godot did not produce its API description.", undefined, {
          exit_code: result?.code ?? null,
          ...(result?.spawnError === undefined ? {} : { reason: result.spawnError }),
        });
      }
      renameSync(dumped, cached);
    } finally {
      rmSync(scratch, { recursive: true, force: true });
    }
  }
  try {
    const content = readPrivateFile(cached, { platform: context.platform, maxBytes: MAX_DUMP_BYTES, secret: false });
    const api = JSON.parse(content ?? "") as ApiDump;
    const documented = api.classes.some((entry) => entry.brief_description !== undefined || entry.description !== undefined);
    return { api, warnings: documented ? [] : [UNDOCUMENTED_WARNING] };
  } catch {
    rmSync(cached, { force: true });
    return errorOf("COMMAND_FAILED", "The cached API description was unreadable and has been removed.", "Run the command again.");
  }
}

function signature(method: ApiMethod): string {
  const parameters = (method.arguments ?? [])
    .map((argument) => `${argument.name}: ${argument.type}${argument.default_value === undefined ? "" : ` = ${argument.default_value}`}`)
    .join(", ");
  const prefix = method.is_static === true ? "static " : "";
  return `${prefix}${method.name}(${parameters}) -> ${method.return_value?.type ?? "void"}`;
}

function brief(text: string | undefined): string {
  const firstLine = (text ?? "").trim().split("\n")[0] ?? "";
  return firstLine.length > BRIEF_LENGTH ? `${firstLine.slice(0, BRIEF_LENGTH)}...` : firstLine;
}

function describeClass(found: ApiClass): Record<string, unknown> {
  return {
    name: found.name,
    inherits: found.inherits ?? null,
    brief: found.brief_description ?? "",
    properties: (found.properties ?? []).map((property) => ({ name: property.name, type: property.type ?? "", brief: brief(property.description) })),
    methods: (found.methods ?? []).map((method) => ({ name: method.name, signature: signature(method), virtual: method.is_virtual === true, brief: brief(method.description) })),
    signals: (found.signals ?? []).map((signal) => ({
      name: signal.name,
      arguments: (signal.arguments ?? []).map((argument) => `${argument.name}: ${argument.type}`),
      brief: brief(signal.description),
    })),
    enums: (found.enums ?? []).map((entry) => ({ name: entry.name, values: entry.values.map((value) => value.name) })),
    constants: (found.constants ?? []).map((constant) => ({ name: constant.name, value: constant.value ?? null })),
  };
}

function describeMember(found: ApiClass, memberName: string): Record<string, unknown> | undefined {
  const method = found.methods?.find((entry) => entry.name === memberName);
  if (method !== undefined) {
    return { kind: "method", class: found.name, name: method.name, signature: signature(method), description: method.description ?? "" };
  }
  const property = found.properties?.find((entry) => entry.name === memberName);
  if (property !== undefined) {
    return { kind: "property", class: found.name, name: property.name, type: property.type ?? "", description: property.description ?? "" };
  }
  const signal = found.signals?.find((entry) => entry.name === memberName);
  if (signal !== undefined) {
    return {
      kind: "signal",
      class: found.name,
      name: signal.name,
      arguments: (signal.arguments ?? []).map((argument) => `${argument.name}: ${argument.type}`),
      description: signal.description ?? "",
    };
  }
  return undefined;
}

function classText(data: Record<string, unknown>): string {
  const rows = (key: string, render: (entry: Record<string, unknown>) => string): string => {
    const entries = data[key] as Record<string, unknown>[];
    return entries.length === 0 ? "" : `\n${key}:\n${entries.map((entry) => `  ${render(entry)}`).join("\n")}\n`;
  };
  const header = `${String(data["name"])}${data["inherits"] === null ? "" : ` < ${String(data["inherits"])}`}\n${String(data["brief"])}\n`;
  return sanitize(
    header +
      rows("properties", (entry) => `${String(entry["name"])}: ${String(entry["type"])}`) +
      rows("methods", (entry) => String(entry["signature"])) +
      rows("signals", (entry) => `${String(entry["name"])}(${(entry["arguments"] as string[]).join(", ")})`) +
      rows("enums", (entry) => `${String(entry["name"])}: ${(entry["values"] as string[]).join(", ")}`),
  );
}

function searchApi(api: ApiDump, query: string): readonly Record<string, string>[] {
  const needle = query.toLowerCase();
  const matches: Record<string, string>[] = [];
  for (const entry of api.classes) {
    if (entry.name.toLowerCase().includes(needle)) {
      matches.push({ kind: "class", name: entry.name, brief: brief(entry.brief_description) });
    }
    for (const method of entry.methods ?? []) {
      if (method.name.toLowerCase().includes(needle)) {
        matches.push({ kind: "method", name: `${entry.name}.${method.name}`, brief: signature(method) });
      }
    }
    for (const property of entry.properties ?? []) {
      if (property.name.toLowerCase().includes(needle)) {
        matches.push({ kind: "property", name: `${entry.name}.${property.name}`, brief: property.type ?? "" });
      }
    }
    for (const signal of entry.signals ?? []) {
      if (signal.name.toLowerCase().includes(needle)) {
        matches.push({ kind: "signal", name: `${entry.name}.${signal.name}`, brief: "" });
      }
    }
  }
  // Exact and prefix matches first, then shorter names.
  const rank = (name: string): number => {
    const last = (name.split(".").at(-1) ?? name).toLowerCase();
    return last === needle ? 0 : last.startsWith(needle) ? 1 : 2;
  };
  return matches.sort((a, b) => rank(a["name"] ?? "") - rank(b["name"] ?? "") || (a["name"] ?? "").length - (b["name"] ?? "").length);
}

/**
 * `gd api class <Name> [--member <name>]` and `gd api search <text>`.
 * Answers come from the installed engine itself, so they match its version.
 */
export const apiCommand: CommandHandler = async (context, globals, args) => {
  const parsed = parseCommandArgs(args, { member: { type: "string" } });
  if (typeof parsed === "string") {
    return usage("api", parsed);
  }
  const [action, subject] = parsed.positionals;
  if ((action !== "class" && action !== "search") || subject === undefined || parsed.positionals.length !== 2) {
    return usage("api", "Usage: gd api class <Name> [--member <name>] | gd api search <text>");
  }
  const godot = await requireGodot(context, globals);
  if (isEnvelopeError(godot)) {
    return fail("api", godot);
  }
  const loaded = await loadApi(context, godot);
  if (isEnvelopeError(loaded)) {
    return fail("api", loaded);
  }
  const { api, warnings } = loaded;

  if (action === "search") {
    const all = searchApi(api, subject);
    const results = all.slice(0, MAX_SEARCH_RESULTS);
    const data = { godot_version: godot.version.text, results, truncated: all.length > results.length };
    const text = results.map((entry) => `${(entry["kind"] ?? "").padEnd(8)} ${entry["name"] ?? ""}  ${entry["brief"] ?? ""}`).join("\n");
    return { envelope: success("api", data, {}, warnings), human: `${sanitize(text)}\n` };
  }

  const found = api.classes.find((entry) => entry.name.toLowerCase() === subject.toLowerCase());
  if (found === undefined) {
    return fail("api", errorOf("RESOURCE_NOT_FOUND", "No such class in this Godot version.", "Try `gd api search <text>`.", { class: subject }));
  }
  const memberName = parsed.values["member"];
  if (typeof memberName === "string") {
    const member = describeMember(found, memberName);
    if (member === undefined) {
      return fail(
        "api",
        errorOf("RESOURCE_NOT_FOUND", "The class has no such member of its own.", "Inherited members are documented on the parent class.", {
          class: found.name,
          member: memberName,
          inherits: found.inherits ?? null,
        }),
      );
    }
    return { envelope: success("api", { godot_version: godot.version.text, ...member }, {}, warnings), human: `${sanitize(JSON.stringify(member, null, 2))}\n` };
  }
  const data = describeClass(found);
  return { envelope: success("api", { godot_version: godot.version.text, ...data }, {}, warnings), human: classText(data) };
};
