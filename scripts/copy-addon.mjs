// Puts a copy of the bridge addon and of the plugin's skills inside the CLI
// package, so that `gd bridge install` and `gd skills install` can ship them,
// and the license next to them, since npm takes it from the package folder.
// Run as part of the CLI build.
import { cpSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

const COPIES = [
  ["../bridge/addons/gdcli/", "../cli/addon/", "bridge addon"],
  ["../plugin/skills/", "../cli/skills/", "plugin's skills"],
  ["../LICENSE", "../cli/LICENSE", "license"],
];

for (const [from, to, what] of COPIES) {
  const source = fileURLToPath(new URL(from, import.meta.url));
  const target = fileURLToPath(new URL(to, import.meta.url));
  rmSync(target, { recursive: true, force: true });
  cpSync(source, target, { recursive: true });
  process.stdout.write(`copied the ${what} to ${target}\n`);
}
