#!/usr/bin/env node
// PreToolUse hook for the shell tools: refuses the ordinary ways of writing,
// from a shell command, the project files that guard-project-writes.mjs keeps
// the file tools away from: redirection into one, cp/mv/rm/tee/sed -i and
// their PowerShell and cmd counterparts, a one-line script that opens one
// for writing.
//
// It reads the command as text and cannot know what it will really do. A
// command built to get past it will get past it: variables, a script file,
// a tool that is not listed. What it does is take away the easy path, so that
// a write to these files is something done on purpose and against the
// instructions, not by habit. The hard limit is the sandbox of Claude Code
// (plugin/README.md).

import { homedir, tmpdir } from "node:os";
import { basename, isAbsolute, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

import { isGuardedWrite } from "./guard-project-writes.mjs";

const OVERRIDE_VARIABLE = "GDCLI_ALLOW_DIRECT_WRITES";

const REASON = [
  "This command would write a file of a Godot project that is driven through gdcli, one that decides what code the editor runs.",
  "Such files are changed through the editor, where a person can approve them:",
  "`gd command fs_write_text --path res://<path> --text-file <scratch file>` for text (add `--overwrite true --yes` to replace a file),",
  "`gd command fs_move` and `gd command fs_delete` to move or delete, and the node, scene and resource commands for the rest (`gd list`).",
  "Copying a project file out to a scratch folder and reading files are fine.",
  "Do not look for another way to write the file. If the editor refuses or a person declines, stop and tell the user.",
].join(" ");

// Words that only lead up to the command.
const WRAPPERS = new Set(["sudo", "env", "command", "builtin", "exec", "time", "nohup", "rtk", "proxy", "xargs", "do", "then", "else", "elif", "if", "while", "until", "!"]);
// Every path argument is written or removed.
const WRITES_ALL = new Set([
  "rm", "tee", "touch", "truncate", "shred", "unlink", "rmdir", "del", "erase", "rd",
  "remove-item", "ri", "add-content", "ac", "new-item", "ni", "clear-content", "clc",
]);
// The first path argument is the file written; what follows is its content.
const WRITES_FIRST = new Set(["set-content", "sc", "out-file"]);
// The last path argument is where the result lands.
const COPIES = new Set(["cp", "copy", "xcopy", "copy-item", "cpi", "install", "ln", "rsync", "mklink"]);
// As a copy, and the sources are gone afterwards.
const MOVES = new Set(["mv", "move", "move-item", "mi", "ren", "rename", "rename-item", "rni"]);
// Commands of cmd.exe, whose options start with a slash.
const SLASH_SWITCHES = new Set(["copy", "xcopy", "robocopy", "move", "del", "erase", "rd", "ren", "rename", "mklink"]);
// Edit files where they are when told to.
const IN_PLACE = new Map([
  ["sed", /^(-[a-zA-Z]*i|--in-place)/u],
  ["gsed", /^(-[a-zA-Z]*i|--in-place)/u],
  ["perl", /^-[a-zA-Z]*i/u],
]);
const GIT_WRITES = new Set(["checkout", "restore", "rm", "mv", "clean", "apply", "stash"]);
const SHELLS = new Set(["bash", "sh", "zsh", "dash", "pwsh", "powershell", "cmd"]);
const INTERPRETERS = new Set(["python", "python3", "py", "node", "deno", "bun", "perl", "ruby", "php"]);
const INLINE_CODE_FLAG = /^(-[a-z]*[ce]|-command|-encodedcommand|\/c|--eval|-r|-p)$/iu;
const DESTINATION_FLAGS = new Set(["-destination", "-t", "--target-directory"]);
const CHANGES_DIRECTORY = new Set(["cd", "pushd", "set-location", "sl", "chdir", "push-location"]);
// PowerShell switches: parameters that take no value, so the word after them is not theirs.
const POWERSHELL_SWITCHES = new Set(["-force", "-nonewline", "-append", "-noclobber", "-confirm", "-whatif", "-passthru", "-asbytestream", "-usetransaction", "-verbose", "-debug", "-recurse", "-raw"]);
// What a guarded file looks like inside code, where its path cannot be resolved.
const GUARDED_IN_TEXT = /\.(?:gd|tscn|tres|escn|scn|res|cs|import|gdextension|csproj|fsproj|vbproj|proj|sln|slnx|slnf|props|targets|rsp)\b|\.csproj\.user\b|project\.godot|override\.cfg|export_presets\.cfg|nuget\.config|global\.json|dotnet-tools\.json|\.gitmodules|\.gitattributes|(?:^|[\\/"'\s])(?:addons|gdcli_commands|\.godot|\.git)[\\/]/iu;
// Calls that write (write_text(, os.remove(, fs.copyFileSync(), PowerShell's
// writing cmdlets, and redirections inside code: the word "write" in a string is not one.
const WRITES_IN_TEXT = /\bopen\s*\([^)]{0,300},\s*["'][wax+]|["']\s*>|\b\w*(?:write|unlink|rename|remove|copy|move|truncate|touch|rmtree)\w*\s*\(|shutil\.|Set-Content|Add-Content|Out-File|New-Item|Copy-Item|Move-Item|Remove-Item/iu;
// Code longer than this is judged by its beginning.
const MAX_CODE_LENGTH = 20000;

/**
 * @typedef {{ words: string[], redirects: string[] }} Segment
 * @typedef {{ head: string, body: string }} Heredoc
 */

/**
 * Takes the bodies of here-documents out of a command, so that what follows
 * them is read as commands again.
 * @param {string} command
 * @returns {{ command: string, heredocs: Heredoc[] }}
 */
export function splitHeredocs(command) {
  const lines = command.split("\n");
  /** @type {string[]} */
  const kept = [];
  /** @type {Heredoc[]} */
  const heredocs = [];
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index] ?? "";
    // "<<<" is a here-string, with its text on the same line.
    const markers = [...line.matchAll(/(?<!<)<<(-?)\s*(['"]?)([A-Za-z_]\w*)\2(?!<)/gu)];
    if (markers.length === 0) {
      kept.push(line);
      continue;
    }
    const head = markers.reduce((text, marker) => text.replace(marker[0], " "), line);
    kept.push(head);
    for (const marker of markers) {
      const body = [];
      index += 1;
      while (index < lines.length && (marker[1] === "-" ? (lines[index] ?? "").trim() : lines[index]) !== marker[3]) {
        body.push(lines[index] ?? "");
        index += 1;
      }
      heredocs.push({ head, body: body.join("\n") });
    }
  }
  return { command: kept.join("\n"), heredocs };
}

/**
 * Splits a command line into simple commands, with the targets of output
 * redirection set apart. Quotes group; nothing is expanded.
 * @param {string} command
 * @returns {Segment[]}
 */
export function parse(command) {
  /** @type {Segment[]} */
  const segments = [];
  /** @type {Segment} */
  let segment = { words: [], redirects: [] };
  let word = "";
  let hasWord = false;
  let redirectNext = false;
  let quote = "";

  const endWord = () => {
    if (hasWord) {
      (redirectNext ? segment.redirects : segment.words).push(word);
      redirectNext = false;
    }
    word = "";
    hasWord = false;
  };
  const endSegment = () => {
    endWord();
    if (segment.words.length > 0 || segment.redirects.length > 0) {
      segments.push(segment);
    }
    segment = { words: [], redirects: [] };
    redirectNext = false;
  };

  for (let index = 0; index < command.length; index += 1) {
    const character = command[index] ?? "";
    const next = command[index + 1] ?? "";
    if (quote !== "") {
      if (character === quote) {
        quote = "";
      } else if (character === "\\" && quote === '"' && '"\\$`'.includes(next) && next !== "") {
        index += 1;
        word += next;
      } else {
        word += character;
      }
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
      hasWord = true;
    } else if (character === "\\" && next === "\n") {
      index += 1;
    } else if (character === "\\" && /["' ;&|<>()$`]/u.test(next)) {
      // An escaped character is itself, and starts nothing. A backslash
      // before anything else is left alone: it separates folders on Windows.
      index += 1;
      word += next;
      hasWord = true;
    } else if (character === "$" && next === "{" && /^\$\{[^}$`;|&\n()]*\}/u.test(command.slice(index))) {
      // ${NAME} or ${NAME:-word}: one word. One that holds a command ($(...), ;, |)
      // is left to the ordinary splitting, which sees that command.
      const close = command.indexOf("}", index);
      word += command.slice(index, close + 1);
      hasWord = true;
      index = close;
    } else if (";\n|(){}".includes(character)) {
      endSegment();
    } else if (character === "&" && next === ">") {
      endWord();
    } else if (character === "&") {
      endSegment();
    } else if (character === ">") {
      // A file descriptor in front ("2>") is not a word of the command.
      if (/^\d+$/u.test(word)) {
        word = "";
        hasWord = false;
      }
      endWord();
      // ">>" appends, ">|" overwrites although told not to.
      if (next === ">" || next === "|") {
        index += 1;
      }
      // ">&2" names a descriptor, not a file.
      if (command[index + 1] === "&" && /\d/u.test(command[index + 2] ?? "")) {
        index += 1;
        while (/\d/u.test(command[index + 1] ?? "")) {
          index += 1;
        }
      } else {
        if (command[index + 1] === "&") {
          index += 1;
        }
        redirectNext = true;
      }
    } else if (/\s/u.test(character)) {
      endWord();
    } else {
      word += character;
      hasWord = true;
    }
  }
  endSegment();
  return segments;
}

/** The command name as written, without folder, extension or case. */
function verbOf(word) {
  return basename(word.replaceAll("\\", "/")).toLowerCase().replace(/\.(exe|cmd|bat|ps1)$/u, "");
}

/**
 * A path as written for Windows, readable on any system: a command meant for
 * PowerShell or cmd is judged the same wherever this runs.
 */
function slashed(word) {
  return word.replaceAll("\\", "/");
}

const HOME_PREFIX = /^(?:~|\$HOME|\$\{HOME\}|\$USERPROFILE|\$\{USERPROFILE\}|\$env:USERPROFILE|\$env:HOME|%USERPROFILE%|\$env:HOMEDRIVE\$env:HOMEPATH|%HOMEDRIVE%%HOMEPATH%|\$env:HOMEPATH|%HOMEPATH%)(?=[\\/]|$)/iu;
const TEMP_PREFIX = /^(?:\$TMPDIR|\$\{TMPDIR\}|\$TEMP|\$\{TEMP\}|\$TMP|\$\{TMP\}|\$env:TEMP|\$env:TMP|%TEMP%|%TMP%)(?=[\\/]|$)/iu;
const CWD_PREFIX = /^(?:\$PWD|\$\{PWD\}|\$pwd)(?=[\\/]|$)/iu;

/**
 * A word as the path it names, or null when it cannot be read as one: the
 * home folder however a shell spells it, and on Windows Git Bash's /c/... for
 * C:/... (Node would read it as C:\c\...). Other variables are not guessed at.
 */
function asPath(word, cwd = process.cwd()) {
  if (word === "" || word.startsWith("-") || word.includes("://")) {
    return null;
  }
  let path = slashed(word)
    .replace(HOME_PREFIX, () => slashed(homedir()))
    .replace(TEMP_PREFIX, () => slashed(tmpdir()))
    .replace(CWD_PREFIX, () => slashed(cwd));
  if (process.platform === "win32") {
    // Git Bash /c/..., WSL /mnt/c/..., Cygwin /cygdrive/c/...: all C:/...
    path = path.replace(/^(?:\/mnt|\/cygdrive)?\/([a-zA-Z])(?=\/|$)/u, (_whole, drive) => `${drive.toUpperCase()}:`);
  }
  return /[$`%]/u.test(path) ? null : path;
}

/**
 * A path built from a variable this cannot resolve ($GAME/scripts/player.gd)
 * is taken as guarded when it names a guarded file: when unsure, it holds.
 */
function namesGuardedUnresolved(word) {
  return /[$`%]/u.test(word) && GUARDED_IN_TEXT.test(slashed(word));
}

/** Whether a word can be read as a path at all. */
function isPathLike(word) {
  return asPath(word) !== null;
}

/** Whether inline code names a guarded file and something that writes. */
function codeWrites(code) {
  const text = code.slice(0, MAX_CODE_LENGTH);
  return GUARDED_IN_TEXT.test(text) && WRITES_IN_TEXT.test(text);
}

/**
 * The command of a segment without what leads up to it.
 * @param {readonly string[]} words
 * @returns {string[]}
 */
function withoutWrappers(words) {
  let rest = [...words];
  for (;;) {
    const first = rest[0];
    if (first === undefined) {
      return rest;
    }
    if (/^\w+=/u.test(first)) {
      rest = rest.slice(1);
    } else if (WRAPPERS.has(verbOf(first))) {
      // The options of a wrapper are not the command either.
      rest = rest.slice(1);
      while ((rest[0] ?? "").startsWith("-")) {
        rest = rest.slice(1);
      }
    } else {
      return rest;
    }
  }
}

/**
 * @param {Segment} segment
 * @param {string} cwd
 * @returns {boolean}
 */
function segmentWrites(segment, cwd) {
  const guarded = (word) => {
    const path = asPath(word, cwd);
    return path === null ? namesGuardedUnresolved(word) : isGuardedWrite(path, cwd);
  };
  if (segment.redirects.some(guarded)) {
    return true;
  }
  const [first, ...all] = withoutWrappers(segment.words);
  if (first === undefined) {
    return false;
  }
  const verb = verbOf(first);
  const rest = SLASH_SWITCHES.has(verb) ? all.filter((word) => !/^\/[A-Za-z]+(:\S*)?$/u.test(word)) : all;
  const paths = rest.filter(isPathLike);

  if (WRITES_ALL.has(verb)) {
    return paths.some(guarded);
  }
  if (WRITES_FIRST.has(verb)) {
    const named = rest.findIndex((word) => /^-(path|filepath|literalpath)$/iu.test(word));
    // Otherwise the first word that is not a parameter's value (-Encoding utf8, -Value 'x').
    let target = named === -1 ? undefined : rest[named + 1];
    for (let index = 0; target === undefined && index < rest.length; index += 1) {
      const word = rest[index] ?? "";
      if (word.startsWith("-")) {
        index += POWERSHELL_SWITCHES.has(word.toLowerCase().split(":")[0] ?? "") || word.includes(":") ? 0 : 1;
      } else {
        target = word;
      }
    }
    return target !== undefined && guarded(target);
  }
  if (COPIES.has(verb) || MOVES.has(verb) || verb === "robocopy") {
    if (MOVES.has(verb) && paths.some(guarded)) {
      return true;
    }
    const flagged = rest.findIndex((word) => DESTINATION_FLAGS.has(word.toLowerCase().split("=")[0] ?? ""));
    const positional = rest.filter((word) => !word.startsWith("-"));
    let destination = verb === "robocopy" ? positional[1] : positional.at(-1);
    if (flagged !== -1) {
      const flag = rest[flagged] ?? "";
      destination = flag.includes("=") ? flag.slice(flag.indexOf("=") + 1) : rest[flagged + 1];
    }
    // A destination that cannot be read as a path is not guessed at.
    if (destination === undefined || !isPathLike(destination)) {
      return false;
    }
    // Into a folder, the files keep their names.
    return [destination, ...paths.filter((path) => path !== destination).map((path) => join(slashed(destination), basename(slashed(path))))].some(guarded);
  }
  if (IN_PLACE.has(verb) && rest.some((word) => IN_PLACE.get(verb)?.test(word))) {
    return paths.some(guarded);
  }
  if (verb === "dd") {
    return rest.some((word) => word.startsWith("of=") && guarded(word.slice(3)));
  }
  if (verb === "find") {
    return findWrites(rest, cwd, segment.words.join(" "));
  }
  if (verb === "git") {
    return gitWrites(rest, cwd);
  }
  if (SHELLS.has(verb) || INTERPRETERS.has(verb)) {
    const flag = rest.findIndex((word) => INLINE_CODE_FLAG.test(word));
    if (flag === -1 || rest[flag + 1] === undefined) {
      return false;
    }
    // Unquoted, the command line is the rest of the words.
    const code = rest.slice(flag + 1).join(" ");
    // A shell given a command line is read like the command line itself.
    return SHELLS.has(verb) ? commandWrites(code, cwd) : codeWrites(code);
  }
  return false;
}

/** `find ... -delete` or `-exec rm` below a folder of a guarded project. */
function findWrites(rest, cwd, text) {
  const exec = rest.findIndex((word) => word === "-exec" || word === "-execdir");
  const removes = rest.includes("-delete") || (exec !== -1 && (WRITES_ALL.has(verbOf(rest[exec + 1] ?? "")) || MOVES.has(verbOf(rest[exec + 1] ?? ""))));
  if (!removes) {
    return false;
  }
  const firstTest = rest.findIndex((word) => word.startsWith("-"));
  const roots = rest.slice(0, firstTest === -1 ? rest.length : firstTest).filter(isPathLike);
  const insideProject = (roots.length === 0 ? ["."] : roots).some((root) => isGuardedWrite(join(slashed(root), "x.gd"), cwd));
  // With a name filter, only when the filter is for guarded files.
  const filtered = rest.some((word) => /^-i?(name|path|regex)$/u.test(word));
  return insideProject && (!filtered || GUARDED_IN_TEXT.test(text));
}

/** A git subcommand that rewrites files of the working tree named on the line. */
function gitWrites(rest, cwd) {
  let directory = cwd;
  const words = [];
  for (let index = 0; index < rest.length; index += 1) {
    const word = rest[index] ?? "";
    if (word === "-C" && rest[index + 1] !== undefined) {
      index += 1;
      if (isPathLike(rest[index] ?? "")) {
        directory = resolve(directory, asPath(rest[index] ?? "") ?? "");
      }
    } else {
      words.push(word);
    }
  }
  const subcommand = words.find((word) => !word.startsWith("-"));
  // restore --staged alone changes the index, not the files.
  if (subcommand === "restore" && words.some((word) => word === "--staged" || word === "-S") && !words.some((word) => word === "--worktree" || word === "-W")) {
    return false;
  }
  return subcommand !== undefined && GIT_WRITES.has(subcommand) && words.some((word) => isPathLike(word) && isGuardedWrite(asPath(word) ?? "", directory));
}

/**
 * @param {string} command
 * @param {string} cwd
 * @returns {boolean} whether the command looks like it writes a guarded file
 */
export function commandWrites(command, cwd) {
  const split = splitHeredocs(command);
  // A script fed to an interpreter on standard input is code, not commands.
  for (const heredoc of split.heredocs) {
    const feeds = parse(heredoc.head).flatMap((segment) => withoutWrappers(segment.words).slice(0, 1).map(verbOf));
    if (feeds.some((verb) => INTERPRETERS.has(verb)) && codeWrites(heredoc.body)) {
      return true;
    }
    if (feeds.some((verb) => SHELLS.has(verb)) && commandWrites(heredoc.body, cwd)) {
      return true;
    }
  }
  let current = cwd;
  for (const segment of parse(split.command)) {
    if (segmentWrites(segment, current)) {
      return true;
    }
    const [first, target] = segment.words;
    const where = target === undefined ? null : asPath(target, current);
    if (first !== undefined && CHANGES_DIRECTORY.has(verbOf(first)) && where !== null) {
      current = isAbsolute(where) ? resolve(where) : resolve(current, where);
    }
  }
  return false;
}

/**
 * @param {unknown} event the hook input
 * @param {Readonly<Record<string, string | undefined>>} environment
 * @returns {{ hookSpecificOutput: { hookEventName: string, permissionDecision: string, permissionDecisionReason: string } } | null}
 */
export function decide(event, environment) {
  if (environment[OVERRIDE_VARIABLE] === "1" || typeof event !== "object" || event === null) {
    return null;
  }
  const input = /** @type {{ tool_input?: unknown, cwd?: unknown }} */ (event);
  const toolInput = /** @type {Record<string, unknown>} */ (typeof input.tool_input === "object" && input.tool_input !== null ? input.tool_input : {});
  const command = toolInput["command"];
  const cwd = typeof input.cwd === "string" && input.cwd !== "" ? input.cwd : process.cwd();
  if (typeof command !== "string" || !commandWrites(command, cwd)) {
    return null;
  }
  return { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: REASON } };
}

async function main() {
  let text = "";
  for await (const chunk of process.stdin) {
    text += chunk;
  }
  let event;
  try {
    event = JSON.parse(text);
  } catch {
    process.stderr.write("gdcli: the shell write guard got input it could not read and let the command run unchecked.\n");
    return;
  }
  let decision = null;
  try {
    decision = decide(event, process.env);
  } catch (error) {
    // A command this cannot make sense of is not held up: it is a guard
    // against habit, and the file tools' guard does not depend on it.
    process.stderr.write(
      `gdcli: the shell write guard could not read this command and let it run unchecked (${error instanceof Error ? error.message : "unknown error"}).\n`,
    );
    return;
  }
  if (decision !== null) {
    process.stdout.write(`${JSON.stringify(decision)}\n`);
  }
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main();
}
