import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join, relative, resolve, sep } from "node:path";

import type { CommandHandler, CommandResult, Context, GlobalOptions, ProcessResult } from "../context.js";
import { errorOf, isEnvelopeError, success } from "../envelope.js";
import { findOnPath, requireGodot } from "../godot.js";
import { gdcliHome, nonEmpty } from "../project.js";
import { sanitize } from "../text.js";
import { fail, numberOption, parseCommandArgs, usage } from "./shared.js";

/**
 * `gd docs`: the Godot manual, searched and read from a copy on this machine.
 * `gd docs install` fetches the pages (text only) of the manual for the Godot
 * version in use from the godot-docs repository; `gd docs use` points at a
 * copy that is already here, the offline HTML download (its `_sources` folder
 * holds every page as text) or a checkout. Searching and reading never touch
 * the network.
 */

export const DOCS_ENV = "GDCLI_DOCS";
const DOCS_PATH_FILE = "docs-path";
// Where an HTML export keeps the text of its pages.
const SOURCES_DIR = "_sources";
const PAGE_SUFFIXES = [".rst.txt", ".rst"];
const CLASS_REFERENCE = "classes/";
const DEFAULT_LIMIT = 10;
const MAX_LIMIT = 50;
const DEFAULT_PAGE_CHARS = 20_000;
const MAX_PAGE_CHARS = 400_000;
const MIN_WORD_LENGTH = 2;
const MAX_SECTIONS_SHOWN = 5;
const TITLE_SCORE = 20;
const HEADING_SCORE = 8;
const MAX_BODY_SCORE = 10;
const MAX_PAGES = 20_000;
// The longest pages of the manual are a few hundred kilobytes; anything far
// beyond that is not a page of it.
const MAX_PAGE_BYTES = 2_000_000;
// Longer lines are not prose; they are left as they are and searched no further.
const MAX_LINE_LENGTH = 2000;
// A heading is a line of text, not indented, over a line of one repeated mark.
const UNDERLINE = /^([=\-~^"#*+])\1{2,}\s*$/u;

const HOW_TO_GET = "Run `gd docs install`: it downloads the manual for your Godot version from github.com/godotengine/godot-docs (text only, about 40 MB, needs git). A copy you already have is used with `gd docs use <folder>`.";

const DOCS_REPOSITORY = "https://github.com/godotengine/godot-docs.git";
const INSTALL_DIR = "docs";
const SOURCE_FILE = "gdcli-source.json";
const DEVELOPMENT_BRANCH = "master";
// A branch of the manual: a version such as 4.5, or the one in development.
const BRANCH_PATTERN = /^(\d+\.\d+|master)$/u;
const LIST_TIMEOUT_MS = 60_000;
const FETCH_TIMEOUT_MS = 600_000;
// Looked up on PATH as an absolute path: a bare "git" would be found in the
// working folder first on Windows, which is often an untrusted project.
const GIT_NAME = "git";
// The user's git configuration is not part of this download: no hooks from a
// template folder, no file watcher, no question about credentials for a public
// repository; links in the repository arrive as plain files.
const GIT_SETTINGS = ["core.hooksPath=/dev/null", "core.fsmonitor=false", "core.symlinks=false", "core.longpaths=true", "credential.interactive=never"].flatMap(
  (setting) => ["-c", setting],
);
const STALE_STAGING_MS = 3_600_000;
const REMOVE_RETRIES = 3;

interface Heading {
  readonly text: string;
  readonly line: number;
  readonly mark: string;
}

interface Page {
  readonly id: string;
  readonly file: string;
}

/** The folder that holds the pages, given what the user pointed at; undefined when it holds none. */
export function pagesRoot(folder: string): string | undefined {
  for (const candidate of [join(folder, SOURCES_DIR), folder]) {
    if (PAGE_SUFFIXES.some((suffix) => existsSync(join(candidate, `index${suffix}`)))) {
      return candidate;
    }
  }
  return undefined;
}

function configuredFolder(context: Context): string | undefined {
  const fromEnv = nonEmpty(context.io.env[DOCS_ENV]);
  if (fromEnv !== undefined) {
    return fromEnv;
  }
  try {
    return nonEmpty(readFileSync(join(gdcliHome(context), DOCS_PATH_FILE), "utf8").trim());
  } catch {
    return undefined;
  }
}

function listPages(root: string): Page[] {
  const pages: Page[] = [];
  const pending = [root];
  while (pending.length > 0 && pages.length < MAX_PAGES) {
    const directory = pending.pop() ?? root;
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) {
        pending.push(path);
        continue;
      }
      const suffix = PAGE_SUFFIXES.find((candidate) => entry.name.endsWith(candidate));
      // Links are neither files nor folders here, so nothing outside the root is ever read.
      if (entry.isFile() && suffix !== undefined && statSync(path).size <= MAX_PAGE_BYTES) {
        pages.push({ id: relative(root, path).split(sep).join("/").slice(0, -suffix.length), file: path });
      }
    }
  }
  return pages.sort((left, right) => left.id.localeCompare(right.id));
}

export function headingsOf(lines: readonly string[]): Heading[] {
  const headings: Heading[] = [];
  for (let index = 0; index + 1 < lines.length; index += 1) {
    const line = lines[index] ?? "";
    const text = line.trim();
    const mark = UNDERLINE.exec(lines[index + 1] ?? "")?.[1];
    // Indented text is inside a code block or a directive, whatever stands under it.
    const plain = text !== "" && line.length <= MAX_LINE_LENGTH && !/^\s/u.test(line) && !UNDERLINE.test(text) && !text.startsWith("..");
    if (mark !== undefined && plain) {
      headings.push({ text, line: index, mark });
    }
  }
  return headings;
}

/** Pictures say nothing in text; roles are reduced to the words a reader sees. */
export function readable(text: string): string {
  const lines = text.split(/\r?\n/u);
  const kept: string[] = [];
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index] ?? "";
    // The C# version of an example repeats the GDScript one beside it.
    if (/^\s*\.\. (figure|image|video)::|^\s*\.\. code-tab:: csharp/u.test(line)) {
      const indent = line.search(/\S/u);
      // The directive's options and caption are the indented lines below it.
      while (index + 1 < lines.length && ((lines[index + 1] ?? "").trim() === "" || (lines[index + 1] ?? "").search(/\S/u) > indent)) {
        index += 1;
      }
      continue;
    }
    kept.push(line.length > MAX_LINE_LENGTH ? line : line.replace(/:[a-z:]+:`([^`<]*?)\s*<[^`>]*>`/gu, "$1").replace(/:[a-z:]+:`([^`]*)`/gu, "$1"));
  }
  return kept.join("\n").replace(/\n{3,}/gu, "\n\n");
}

function wordsOf(query: string): string[] {
  return [...new Set(query.toLowerCase().split(/[^\p{L}\p{N}_]+/u).filter((word) => word.length >= MIN_WORD_LENGTH))];
}

interface Hit {
  readonly page: string;
  readonly title: string;
  readonly sections: string[];
  readonly score: number;
}

function scorePage(page: Page, words: readonly string[], everyWord: boolean): Hit | undefined {
  let text: string;
  try {
    text = readFileSync(page.file, "utf8");
  } catch {
    // One page that cannot be read does not end the search.
    return undefined;
  }
  const lower = text.toLowerCase();
  const found = words.filter((word) => lower.includes(word));
  if (found.length === 0 || (everyWord && found.length < words.length)) {
    return undefined;
  }
  const headings = headingsOf(text.split(/\r?\n/u));
  const title = headings[0]?.text ?? page.id;
  const sections = headings.slice(1).filter((heading) => found.some((word) => heading.text.toLowerCase().includes(word)));
  let score = 0;
  for (const word of found) {
    score += title.toLowerCase().includes(word) || page.id.toLowerCase().includes(word) ? TITLE_SCORE : 0;
    score += sections.some((heading) => heading.text.toLowerCase().includes(word)) ? HEADING_SCORE : 0;
    score += Math.min(lower.split(word).length - 1, MAX_BODY_SCORE);
  }
  return { page: sanitize(page.id), title: sanitize(title), sections: sections.slice(0, MAX_SECTIONS_SHOWN).map((heading) => sanitize(heading.text)), score };
}

function search(root: string, query: string, limit: number, withClasses: boolean): CommandResult {
  const words = wordsOf(query);
  if (words.length === 0) {
    return usage("docs", "Give at least one word to search for.");
  }
  const pages = listPages(root).filter((page) => withClasses || !page.id.startsWith(CLASS_REFERENCE));
  let hits = pages.flatMap((page) => scorePage(page, words, true) ?? []);
  // Nothing has every word: pages that have some of them are better than none.
  const partial = hits.length === 0 && words.length > 1;
  if (partial) {
    hits = pages.flatMap((page) => scorePage(page, words, false) ?? []);
  }
  hits.sort((left, right) => right.score - left.score || left.page.localeCompare(right.page));
  const shown = hits.slice(0, limit);
  const warnings = partial && shown.length > 0 ? ["No page has every word; these have some of them."] : [];
  const human =
    shown.length === 0
      ? "no page found\n"
      : `${shown.map((hit) => `${hit.page}  ${hit.title}${hit.sections.length > 0 ? `\n    ${hit.sections.join(" | ")}` : ""}`).join("\n")}\n`;
  return { envelope: success("docs", { query: words, pages: shown, total: hits.length, class_reference_searched: withClasses }, {}, warnings), human };
}

/** The lines of one section: from its heading to the next heading of the same or a higher level. */
function sectionLines(lines: readonly string[], headings: readonly Heading[], wanted: string): string[] | undefined {
  const lower = wanted.toLowerCase();
  const start = headings.find((heading) => heading.text.toLowerCase() === lower) ?? headings.find((heading) => heading.text.toLowerCase().includes(lower));
  if (start === undefined) {
    return undefined;
  }
  // Levels are told by the order in which their marks first appear.
  const marks = [...new Set(headings.map((heading) => heading.mark))];
  const level = marks.indexOf(start.mark);
  const next = headings.find((heading) => heading.line > start.line && marks.indexOf(heading.mark) <= level);
  return lines.slice(start.line, next?.line ?? lines.length);
}

function readPage(root: string, id: string, section: string | undefined, maxChars: number): CommandResult {
  const page = listPages(root).find((candidate) => candidate.id === id.replace(/\.html$|\.rst(\.txt)?$/u, "").replace(/^\/+/u, ""));
  if (page === undefined) {
    return fail("docs", errorOf("RESOURCE_NOT_FOUND", "The documentation has no such page.", "`gd docs search <words>` lists pages by what they are about.", { page: sanitize(id) }));
  }
  const lines = readFileSync(page.file, "utf8").split(/\r?\n/u);
  const headings = headingsOf(lines);
  const chosen = section === undefined ? lines : sectionLines(lines, headings, section);
  if (chosen === undefined) {
    return fail(
      "docs",
      errorOf("RESOURCE_NOT_FOUND", "The page has no such section.", "Leave --section out to read the whole page.", {
        page: sanitize(page.id),
        sections: headings.map((heading) => sanitize(heading.text)),
      }),
    );
  }
  const whole = sanitize(readable(chosen.join("\n")));
  const text = whole.slice(0, maxChars);
  const data = {
    page: sanitize(page.id),
    title: sanitize(headings[0]?.text ?? page.id),
    sections: headings.slice(1).map((heading) => sanitize(heading.text)),
    text,
    truncated: text.length < whole.length,
  };
  const warnings = data.truncated ? [`The page is longer than ${maxChars} characters; read a part of it with --section.`] : [];
  return { envelope: success("docs", data, {}, warnings), human: `${text}\n` };
}

function use(context: Context, folder: string, dryRun: boolean): CommandResult {
  const absolute = resolve(context.cwd, folder);
  const root = existsSync(absolute) && statSync(absolute).isDirectory() ? pagesRoot(absolute) : undefined;
  if (root === undefined) {
    return fail("docs", errorOf("RESOURCE_NOT_FOUND", "This folder does not hold the Godot documentation.", HOW_TO_GET, { folder: sanitize(absolute) }));
  }
  if (!dryRun) {
    mkdirSync(gdcliHome(context), { recursive: true });
    writeFileSync(join(gdcliHome(context), DOCS_PATH_FILE), `${absolute}\n`);
  }
  const pages = listPages(root).length;
  const warnings = nonEmpty(context.io.env[DOCS_ENV]) === undefined ? [] : [`${DOCS_ENV} is set and takes precedence over the folder remembered here.`];
  return {
    envelope: success("docs", { folder: sanitize(absolute), pages, ...(dryRun ? { dry_run: true } : {}) }, {}, warnings),
    human: `${dryRun ? "would use" : "using"} ${sanitize(absolute)} (${pages} pages)\n`,
  };
}

async function install(context: Context, globals: GlobalOptions, wanted: string | undefined): Promise<CommandResult> {
  const noGit = (details: Record<string, unknown>) =>
    fail("docs", errorOf("PRECONDITION_FAILED", "The manual could not be downloaded.", "It needs git and a connection to github.com. A copy you already have is used with `gd docs use <folder>`.", details));
  const git = (args: readonly string[], timeoutMs: number): Promise<ProcessResult> => {
    const gitPath = findOnPath(context, [GIT_NAME]);
    // Not on PATH is the same answer as git failing to start.
    return gitPath === undefined
      ? Promise.resolve({ code: null, stdout: "", stderr: "", timedOut: false, spawnError: "ENOENT" })
      : context.processes.run(gitPath, [...GIT_SETTINGS, ...args], { timeoutMs });
  };

  let own = wanted;
  if (own === undefined) {
    const godot = await requireGodot(context, globals);
    if (isEnvelopeError(godot)) {
      return fail("docs", { ...godot, hint: "Say which version of the manual you want: `gd docs install 4.5`." });
    }
    own = `${godot.version.major}.${godot.version.minor}`;
  }
  const installDir = join(gdcliHome(context), INSTALL_DIR);
  // A dry run does not go to the network, so it cannot know whether this version has a manual of its own yet.
  if (globals.dryRun) {
    return {
      envelope: success("docs", { dry_run: true, version: own, otherwise: wanted === undefined ? DEVELOPMENT_BRANCH : null, folder: join(installDir, own), from: DOCS_REPOSITORY }),
      human: `would download the ${own} manual to ${join(installDir, own)}\n`,
    };
  }

  const listed = await git(["ls-remote", "--heads", DOCS_REPOSITORY], LIST_TIMEOUT_MS);
  if (listed.spawnError !== undefined || listed.code !== 0) {
    return noGit({ step: "list versions", ...(listed.spawnError === undefined ? {} : { reason: "git was not found" }) });
  }
  const branches = [...listed.stdout.matchAll(/refs\/heads\/(\S+)/gu)].map((match) => match[1] ?? "").filter((name) => BRANCH_PATTERN.test(name));
  // A Godot newer than any published manual reads the one in development.
  const branch = wanted === undefined && !branches.includes(own) ? DEVELOPMENT_BRANCH : own;
  if (!branches.includes(branch)) {
    return fail("docs", errorOf("RESOURCE_NOT_FOUND", "There is no manual for this version.", "Versions are written like 4.5; master is the one in development.", { version: sanitize(branch), available: branches }));
  }
  const target = join(installDir, branch);
  // Fetched beside the place it goes, and moved there when it is complete.
  const staging = join(installDir, `.${branch}.${context.pid}.tmp`);
  const discard = (path: string): void => rmSync(path, { recursive: true, force: true, maxRetries: REMOVE_RETRIES });
  mkdirSync(installDir, { recursive: true });
  removeStaleStaging(installDir);
  discard(staging);
  try {
    // Only the pages: the pictures make up nearly all of the repository.
    const steps: readonly (readonly string[])[] = [
      ["clone", "--quiet", "--template=", "--depth", "1", "--filter=blob:none", "--no-checkout", "--single-branch", "--branch", branch, DOCS_REPOSITORY, staging],
      ["-C", staging, "sparse-checkout", "set", "--no-cone", "*.rst"],
      ["-C", staging, "checkout", "--quiet", branch],
    ];
    for (const step of steps) {
      const result = await git(step, FETCH_TIMEOUT_MS);
      if (result.spawnError !== undefined || result.code !== 0) {
        return noGit({ step: step.find((word) => ["clone", "sparse-checkout", "checkout"].includes(word)), ...(result.timedOut ? { reason: "timed out" } : {}) });
      }
    }
    discard(join(staging, ".git"));
    if (pagesRoot(staging) === undefined) {
      return noGit({ step: "check", reason: "the download holds no pages" });
    }
    writeFileSync(join(staging, SOURCE_FILE), `${JSON.stringify({ from: DOCS_REPOSITORY, version: branch, fetched: new Date().toISOString() })}\n`);
    // The earlier download steps aside first, and comes back if the new one cannot take its place.
    const previous = `${staging}.old`;
    const hadPrevious = existsSync(target);
    if (hadPrevious) {
      renameSync(target, previous);
    }
    try {
      renameSync(staging, target);
    } catch {
      if (hadPrevious) {
        renameSync(previous, target);
      }
      return noGit({ step: "put in place", reason: "the folder of the earlier download is in use" });
    }
    discard(previous);
  } finally {
    discard(staging);
  }
  writeFileSync(join(gdcliHome(context), DOCS_PATH_FILE), `${target}\n`);
  const pages = listPages(target).length;
  const warnings = nonEmpty(context.io.env[DOCS_ENV]) === undefined ? [] : [`${DOCS_ENV} is set and takes precedence over the manual installed here.`];
  return { envelope: success("docs", { version: branch, folder: target, pages, from: DOCS_REPOSITORY }, {}, warnings), human: `installed the ${branch} manual (${pages} pages) in ${target}\n` };
}

/** Downloads that were interrupted leave their folder behind; old ones are cleared away. */
function removeStaleStaging(installDir: string): void {
  for (const entry of readdirSync(installDir, { withFileTypes: true })) {
    const path = join(installDir, entry.name);
    try {
      if (entry.isDirectory() && /^\..+\.tmp(\.old)?$/u.test(entry.name) && Date.now() - statSync(path).mtimeMs > STALE_STAGING_MS) {
        rmSync(path, { recursive: true, force: true });
      }
    } catch {
      // Another run may be removing it at this moment.
    }
  }
}

/** Which manual a folder holds, when `gd docs install` put it there. */
function sourceOf(root: string): Record<string, unknown> {
  try {
    const source: unknown = JSON.parse(readFileSync(join(root, SOURCE_FILE), "utf8"));
    if (typeof source === "object" && source !== null && "version" in source && typeof source.version === "string") {
      return { version: sanitize(source.version) };
    }
  } catch {
    // A copy that was not installed by gd says nothing about its version.
  }
  return {};
}

const USAGE_TEXT = "Usage: gd docs search <words> [--limit N] [--classes] | gd docs page <page> [--section <heading>] [--max-chars N] | gd docs install [4.5] | gd docs use <folder> | gd docs where";

/** `gd docs search|page|use|where`. */
export const docsCommand: CommandHandler = async (context, globals, args) => {
  const parsed = parseCommandArgs(args, {
    limit: { type: "string" },
    classes: { type: "boolean", default: false },
    section: { type: "string" },
    "max-chars": { type: "string" },
  });
  if (typeof parsed === "string") {
    return usage("docs", parsed);
  }
  const [action, ...rest] = parsed.positionals;
  if (action === "use") {
    return Promise.resolve(rest.length === 1 ? use(context, rest[0] ?? "", globals.dryRun) : usage("docs", USAGE_TEXT));
  }
  if (action === "install") {
    const [version] = rest;
    if (rest.length > 1 || (version !== undefined && !BRANCH_PATTERN.test(version))) {
      return usage("docs", "Usage: gd docs install [<major.minor> | master]");
    }
    return install(context, globals, version);
  }
  if (action !== "search" && action !== "page" && action !== "where") {
    return usage("docs", USAGE_TEXT);
  }
  const configured = configuredFolder(context);
  const folder = configured === undefined ? undefined : sanitize(resolve(context.cwd, configured));
  const root = configured === undefined ? undefined : pagesRoot(resolve(context.cwd, configured));
  if (folder === undefined || root === undefined) {
    return fail("docs", errorOf("PRECONDITION_FAILED", "No copy of the Godot documentation is set up on this machine.", HOW_TO_GET, folder === undefined ? {} : { folder }));
  }
  if (action === "where") {
    const pages = listPages(root).length;
    const source = sourceOf(root);
    return { envelope: success("docs", { folder, pages, ...source }), human: `${folder} (${pages} pages${typeof source["version"] === "string" ? `, version ${source["version"]}` : ""})\n` };
  }
  if (action === "search") {
    const limit = numberOption(parsed.values["limit"], "limit", 1, MAX_LIMIT);
    if (typeof limit === "string") {
      return usage("docs", limit);
    }
    return search(root, rest.join(" "), Math.floor(limit ?? DEFAULT_LIMIT), parsed.values["classes"] === true);
  }
  const maxChars = numberOption(parsed.values["max-chars"], "max-chars", 1, MAX_PAGE_CHARS);
  const section = parsed.values["section"];
  if (typeof maxChars === "string" || rest.length !== 1) {
    return usage("docs", typeof maxChars === "string" ? maxChars : USAGE_TEXT);
  }
  return readPage(root, rest[0] ?? "", typeof section === "string" ? section : undefined, Math.floor(maxChars ?? DEFAULT_PAGE_CHARS));
};
