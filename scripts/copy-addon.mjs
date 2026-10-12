// Puts a copy of the bridge addon inside the CLI package so that
// `gd bridge install` can ship it. Run as part of the CLI build.
import { cpSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

const source = fileURLToPath(new URL("../bridge/addons/gdcli/", import.meta.url));
const target = fileURLToPath(new URL("../cli/addon/", import.meta.url));

rmSync(target, { recursive: true, force: true });
cpSync(source, target, { recursive: true });
process.stdout.write(`copied bridge addon to ${target}\n`);
