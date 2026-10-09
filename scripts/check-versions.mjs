// Fails when the three packages disagree on the release version or the
// protocol number. They ship together, so the numbers must match.
import { readFileSync } from "node:fs";

const root = new URL("../", import.meta.url);

/**
 * @param {string} relativePath
 * @returns {string}
 */
function read(relativePath) {
  return readFileSync(new URL(relativePath, root), "utf8");
}

/**
 * @param {string} relativePath
 * @param {RegExp} pattern
 * @returns {string}
 */
function extract(relativePath, pattern) {
  const match = pattern.exec(read(relativePath));
  if (match?.[1] === undefined) {
    throw new Error(`${relativePath}: no match for ${pattern}`);
  }
  return match[1];
}

/**
 * @param {string} label
 * @param {Readonly<Record<string, string>>} found
 * @returns {string[]}
 */
function disagreements(label, found) {
  const distinct = new Set(Object.values(found));
  if (distinct.size <= 1) {
    return [];
  }
  const lines = Object.entries(found).map(([file, value]) => `  ${file}: ${value}`);
  return [`${label} mismatch:`, ...lines];
}

function main() {
  const versions = {
    "cli/package.json": JSON.parse(read("cli/package.json")).version,
    "plugin/.claude-plugin/plugin.json": JSON.parse(read("plugin/.claude-plugin/plugin.json")).version,
    "bridge/addons/gdcli/plugin.cfg": extract("bridge/addons/gdcli/plugin.cfg", /^version="([^"]+)"/m),
    "bridge/addons/gdcli/plugin.gd": extract(
      "bridge/addons/gdcli/plugin.gd",
      /^const BRIDGE_VERSION := "([^"]+)"/m,
    ),
  };
  const protocols = {
    "cli/src/protocol.ts": extract("cli/src/protocol.ts", /^export const PROTOCOL_VERSION = (\d+);/m),
    "bridge/addons/gdcli/plugin.gd": extract("bridge/addons/gdcli/plugin.gd", /^const PROTOCOL := (\d+)/m),
    "docs/protocol.md": extract("docs/protocol.md", /^# gdcli 协议（protocol (\d+)/m),
  };

  const problems = [...disagreements("version", versions), ...disagreements("protocol", protocols)];
  if (problems.length > 0) {
    process.stderr.write(`${problems.join("\n")}\n`);
    process.exitCode = 1;
    return;
  }
  process.stdout.write(
    `versions agree: ${versions["cli/package.json"]}, protocol ${protocols["cli/src/protocol.ts"]}\n`,
  );
}

main();
