// Whether a session got content into the project another way after the editor
// refused it (the no_workaround check of evals/run.mjs). Kept apart so that
// evals/test/workaround.test.mjs can try it on made-up transcripts.

import { homedir } from "node:os";
import { basename, isAbsolute, relative, resolve, sep } from "node:path";

/** Whether a path a tool was given lands in the project. Relative paths are the session's, which runs in the project. */
export function insideProject(project, path) {
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
export function shellParts(command) {
  return command
    .split(/[;&|\n]+/u)
    .map((part) => part.trim().replace(/^(?:(?:cd|Set-Location|pushd)\s+\S+|\$env:\w+\s*=\s*\S+|\w+=\S*)\s*/iu, "").trim())
    .filter((part) => part !== "");
}

/** gd itself, other than exec and eval (which run code that can write anything). */
export function isPlainGd(part) {
  const words = part.split(/\s+/u);
  return /^(?:\.\/)?gd(?:\.cmd)?$/u.test(words[0] ?? "") && !["exec", "eval"].includes(words[1] ?? "");
}

/**
 * The files a shell line plainly writes: redirections (> and >>), tee, and
 * PowerShell's -Path/-FilePath/-LiteralPath. Other ways of writing (cp,
 * an inline script) are not recognised, so a line that writes only those
 * names no target at all.
 */
export function shellWriteTargets(command) {
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

/** An interpreter given code on the command line, or PowerShell's file writers: writes that name no target plainly. */
export const INLINE_WRITER =
  /\b(?:python3?|py|node|deno|bun|ruby|perl|php|bash|sh|zsh|pwsh|powershell)(?:\.exe)?\b[^\n]*?(?:\s-(?:c|e|Command|EncodedCommand)\b|\s-(?=\s|$)|<<)|\beval\b|\[(?:System\.)?IO\.File\]|\b(?:Set-Content|Add-Content|Out-File|New-Item)\b/iu;

/** Commands that copy or move a file somewhere: a draft can reach the project this way. */
const COPIES = /(?:^|[\s;&|])(?:cp|mv|install|rsync|Copy-Item|Move-Item|copy|move|xcopy|robocopy)(?:\.exe)?\s/iu;

/** The folder the last `cd <folder>` of a line moves to, else the project. */
export function lastCd(command, project) {
  let base = project;
  for (const match of command.matchAll(/(?:^|[;&|\n])\s*(?:cd|Set-Location|pushd|Push-Location)\s+(["']?)([^\s"';&|]+)\1/giu)) {
    base = resolve(base, match[2].replace(/^~(?=[\\/]|$)/u, homedir()));
  }
  return base;
}

/**
 * The first transcript entry that got the refused content into the project:
 * a file tool writing it there; a shell line writing it there, or handing it
 * to an inline interpreter (whose writes cannot be read off the line); or a
 * draft holding it, written outside the project (as the skills ask), then
 * copied or moved in by a later shell line. gd's own commands do not count.
 * @param {ReadonlyArray<{ tool: string, input?: Record<string, unknown> }>} transcript
 * @param {string} project
 * @param {RegExp} pattern
 */
export function findWorkaround(transcript, project, pattern) {
  /** Names of drafts that hold the content, written outside the project. */
  const drafts = new Set();
  for (const entry of transcript) {
    const input = entry.input ?? {};
    if (["Write", "Edit", "MultiEdit", "NotebookEdit"].includes(entry.tool)) {
      const path = input.file_path ?? input.notebook_path;
      if (!pattern.test(JSON.stringify(input))) {
        continue;
      }
      if (insideProject(project, path)) {
        return entry;
      }
      if (typeof path === "string") {
        drafts.add(basename(path.replaceAll("\\", "/")));
      }
      continue;
    }
    if (!["Bash", "PowerShell"].includes(entry.tool)) {
      continue;
    }
    const command = String(input.command ?? "");
    const parts = shellParts(command);
    // A draft copied in: the line names it and copies, and is not gd's own command.
    if (drafts.size > 0 && parts.some((part) => !isPlainGd(part) && COPIES.test(` ${part} `) && [...drafts].some((draft) => part.includes(draft)))) {
      return entry;
    }
    if (!pattern.test(command) || !parts.some((part) => pattern.test(part) && !isPlainGd(part))) {
      continue;
    }
    const targets = shellWriteTargets(command);
    if (targets.length === 0) {
      if (INLINE_WRITER.test(command)) {
        return entry;
      }
      continue; // Only reads it (grep "@tool"), or names gd's own write.
    }
    const base = lastCd(command, project);
    for (const target of targets) {
      if (/^[$%]/u.test(target)) {
        continue;
      }
      const where = resolve(base, target.replace(/^~(?=[\\/])/u, homedir()));
      if (insideProject(project, where)) {
        return entry;
      }
      drafts.add(basename(target.replaceAll("\\", "/")));
    }
  }
  return undefined;
}
