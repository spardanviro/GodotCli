// Adding one server table to a Codex config.toml without a TOML library: the
// file is read line by line, as far as needed to know which lines belong to
// the server's own table. Whatever this reader cannot place with certainty
// (the server written as dotted keys, an inline table, an array of tables)
// makes it refuse: a broken config.toml stops Codex from starting at all.

export interface TomlEntry {
  readonly command: string;
  readonly args: readonly string[];
}

const TABLE_ROOT = "mcp_servers";

type Quote = '"' | "'";

/** The line up to a comment, with strings taken into account. */
function withoutComment(line: string): string {
  let quote: Quote | undefined;
  for (let index = 0; index < line.length; index++) {
    const character = line[index];
    if (quote === '"' && character === "\\") {
      index++;
    } else if (quote !== undefined && character === quote) {
      quote = undefined;
    } else if (quote === undefined && (character === '"' || character === "'")) {
      quote = character;
    } else if (quote === undefined && character === "#") {
      return line.slice(0, index);
    }
  }
  return line;
}

/** `a . "b.c" . 'd'` -> ["a", "b.c", "d"]. */
function keyParts(key: string): string[] {
  const parts: string[] = [];
  let current = "";
  let quote: Quote | undefined;
  for (let index = 0; index < key.length; index++) {
    const character = key[index] ?? "";
    if (quote === '"' && character === "\\") {
      current += key[index + 1] ?? "";
      index++;
    } else if (quote !== undefined && character === quote) {
      quote = undefined;
    } else if (quote === undefined && (character === '"' || character === "'")) {
      quote = character;
    } else if (quote === undefined && character === ".") {
      parts.push(current.trim());
      current = "";
    } else {
      current += character;
    }
  }
  parts.push(current.trim());
  return parts;
}

/** Opening minus closing brackets and braces outside strings: > 0 while a value goes on to the next line. */
function openBrackets(text: string): number {
  let depth = 0;
  let quote: Quote | undefined;
  for (let index = 0; index < text.length; index++) {
    const character = text[index];
    if (quote === '"' && character === "\\") {
      index++;
    } else if (quote !== undefined && character === quote) {
      quote = undefined;
    } else if (quote === undefined && (character === '"' || character === "'")) {
      quote = character;
    } else if (quote === undefined && (character === "[" || character === "{")) {
      depth++;
    } else if (quote === undefined && (character === "]" || character === "}")) {
      depth--;
    }
  }
  return depth;
}

/** The multi-line string delimiter a line leaves open, if any. */
function openMultiline(text: string, open: string | undefined): string | undefined {
  let state = open;
  for (let index = 0; index < text.length; index++) {
    const three = text.slice(index, index + 3);
    if (state === undefined && (three === '"""' || three === "'''")) {
      state = three;
      index += 2;
    } else if (state !== undefined && three === state) {
      state = undefined;
      index += 2;
    }
  }
  return state;
}

function isServer(path: readonly string[], name: string): boolean {
  return path[0] === TABLE_ROOT && path[1] === name;
}

/** TOML has no way to write a code point that is half of a surrogate pair. */
const LONE_SURROGATE = /\p{Cs}/u;

/** A JSON string is a TOML basic string, except that TOML also wants DEL escaped. */
function tomlString(value: string): string {
  return JSON.stringify(value).replaceAll("\u007f", "\\u007F");
}

/**
 * The keys and sub-tables of the server's existing table other than command
 * and args: what writing the entry anew drops. Read line by line, for the
 * preview only (mergeToml decides what is safe to change).
 */
export function tomlKeysDropped(old: string, name: string): string[] {
  const dropped: string[] = [];
  let table: string[] = [];
  for (const line of old.split(/\r?\n/u)) {
    const code = withoutComment(line).trim();
    if (code.startsWith("[") && !code.startsWith("[[")) {
      table = keyParts(code.replace(/^\[/u, "").replace(/\]$/u, ""));
      if (table.length > 2 && isServer(table, name)) {
        dropped.push(`[${table.join(".")}]`);
      }
    } else if (table.length === 2 && isServer(table, name) && code.includes("=")) {
      const key = code.slice(0, code.indexOf("=")).trim().replace(/^["']|["']$/gu, "");
      if (key !== "command" && key !== "args") {
        dropped.push(key);
      }
    }
  }
  return dropped;
}

/**
 * Replaces (or adds) the [mcp_servers.<name>] table and its sub-tables, leaving
 * every other line as it was. Returns an Error when the server is already in
 * the file in a form that is not such a table.
 */
export function mergeToml(old: string, name: string, entry: TomlEntry): string | Error {
  if ([entry.command, ...entry.args].some((value) => LONE_SURROGATE.test(value))) {
    return new Error("A path in the entry holds a character TOML cannot write (half of a surrogate pair).");
  }
  const newline = old.includes("\r\n") ? "\r\n" : "\n";
  const lines = old === "" ? [] : old.split(/\r?\n/u);
  const kept: string[] = [];
  let table: string[] = [];
  let removing = false;
  let multiline: string | undefined;
  let depth = 0;
  for (const line of lines) {
    if (multiline !== undefined || depth > 0) {
      // Inside a value that started on an earlier line: it belongs where that line did.
      if (multiline === undefined) {
        depth += openBrackets(withoutComment(line));
      }
      multiline = openMultiline(line, multiline);
      if (!removing) {
        kept.push(line);
      }
      continue;
    }
    const code = withoutComment(line).trim();
    if (code.startsWith("[[")) {
      table = keyParts(code.replace(/^\[\[/u, "").replace(/\]\]$/u, ""));
      if (isServer(table, name)) {
        return new Error(`[[${TABLE_ROOT}.${name}]] is an array of tables, which Codex does not read as a server.`);
      }
      removing = false;
    } else if (code.startsWith("[")) {
      table = keyParts(code.replace(/^\[/u, "").replace(/\]$/u, ""));
      removing = isServer(table, name);
    } else if (code.includes("=") && !removing) {
      const equals = code.indexOf("=");
      const path = [...table, ...keyParts(code.slice(0, equals))];
      const value = code.slice(equals + 1);
      if (isServer(path, name) || (path.length === 1 && path[0] === TABLE_ROOT && value.includes(name))) {
        return new Error(`The ${name} server is already in the file as keys or an inline table, which gd does not rewrite.`);
      }
      depth = openBrackets(value);
      multiline = openMultiline(value, undefined);
    } else if (code.includes("=")) {
      depth = openBrackets(code.slice(code.indexOf("=") + 1));
      multiline = openMultiline(code.slice(code.indexOf("=") + 1), undefined);
    }
    if (!removing) {
      kept.push(line);
    }
  }
  if (multiline !== undefined || depth > 0) {
    return new Error("The file ends inside a value; it is not valid TOML.");
  }
  while (kept.length > 0 && (kept[kept.length - 1] ?? "").trim() === "") {
    kept.pop();
  }
  const own = [`[${TABLE_ROOT}.${name}]`, `command = ${tomlString(entry.command)}`, `args = [${entry.args.map(tomlString).join(", ")}]`];
  return `${[...kept, ...(kept.length > 0 ? [""] : []), ...own].join(newline)}${newline}`;
}
