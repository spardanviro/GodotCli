// Packs the CLI as npm would publish it, installs the tarball into an empty
// prefix, and checks that what a user gets works: both commands, the bridge
// and the skills that ship inside it, and gd mcp. No Godot needed.
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const cliDir = join(root, "cli");
const isWindows = process.platform === "win32";
const version = JSON.parse(readFileSync(join(cliDir, "package.json"), "utf8")).version;
const MCP_TIMEOUT_MS = 20_000;
const MIN_TOOLS = 60;

const failures = [];
function check(condition, what) {
  process.stdout.write(`${condition ? "ok  " : "FAIL"} ${what}\n`);
  if (!condition) {
    failures.push(what);
  }
}

/**
 * npm and the installed commands are .cmd files on Windows, which only a
 * shell can start: there the whole line goes to it as one string, each part
 * argument quoted (they are this script's own words and temporary paths).
 */
function commandLine(command, args) {
  // A quoted bare name ("npm") makes npm.cmd look for itself in the working directory.
  const name = /[\\/]/u.test(command) ? `"${command}"` : command;
  return isWindows ? [[name, ...args.map((part) => `"${part}"`)].join(" "), []] : [command, args];
}

function run(command, args, options = {}) {
  const [file, rest] = commandLine(command, args);
  const result = spawnSync(file, rest, { encoding: "utf8", shell: isWindows, ...options });
  if (result.error !== undefined) {
    throw result.error;
  }
  return result;
}

const work = mkdtempSync(join(tmpdir(), "gdcli-package-"));
try {
  // 1. The tarball, built the way npm publish builds it (prepack).
  const packed = run("npm", ["pack", "--json", "--pack-destination", work], { cwd: cliDir });
  check(packed.status === 0, "npm pack");
  // prepack's build prints first; the report is the JSON array that starts the last such line.
  const report = JSON.parse(packed.stdout.slice(packed.stdout.lastIndexOf("\n[") + 1))[0];
  const files = new Set(report.files.map((file) => file.path));
  for (const file of ["LICENSE", "README.md", "package.json", "dist/main.js", "addon/plugin.cfg", "skills/godot-cli/SKILL.md"]) {
    check(files.has(file), `the package holds ${file}`);
  }
  check(![...files].some((file) => file.startsWith("src/") || file.startsWith("test/")), "the package holds no sources or tests");

  // 2. Installed into an empty prefix, as npm install -g would.
  const prefix = join(work, "prefix");
  const installed = run("npm", ["install", "-g", "--prefix", prefix, "--no-audit", "--no-fund", join(work, report.filename)]);
  check(installed.status === 0, "npm install -g from the tarball");
  const bin = isWindows ? prefix : join(prefix, "bin");
  const gd = join(bin, isWindows ? "gd.cmd" : "gd");
  const gdcli = join(bin, isWindows ? "gdcli.cmd" : "gdcli");

  for (const command of [gd, gdcli]) {
    const shown = run(command, ["--version"]);
    check(shown.status === 0 && shown.stdout.includes(`gd ${version} `), `${command} --version says ${version}`);
  }

  // 3. The bridge and the skills come from inside the package.
  const project = join(work, "game");
  mkdirSync(project);
  writeFileSync(join(project, "project.godot"), 'config_version=5\n\n[application]\n\nconfig/name="game"\n');
  const bridge = run(gd, ["bridge", "install", "--project", project, "--json"]);
  check(bridge.status === 0, "gd bridge install");
  const cfg = join(project, "addons", "gdcli", "plugin.cfg");
  check(existsSync(cfg) && readFileSync(cfg, "utf8").includes(`version="${version}"`), "the installed bridge has the package's version");

  const skills = join(work, "skills");
  const installedSkills = run(gdcli, ["skills", "install", "--dir", skills, "--yes", "--json"]);
  check(installedSkills.status === 0 && existsSync(join(skills, "godot-cli", "SKILL.md")), "gdcli skills install --dir");

  // 4. gd mcp answers a client: initialize, then the tool list.
  const tools = await mcpToolCount(gd, project);
  check(tools >= MIN_TOOLS, `gd mcp lists the tools (${tools})`);
} finally {
  rmSync(work, { recursive: true, force: true });
}

if (failures.length > 0) {
  process.stdout.write(`\n${failures.length} check(s) failed\n`);
  for (const failure of failures) {
    process.stdout.write(`::error title=package::${failure}\n`);
  }
  process.exitCode = 1;
} else {
  process.stdout.write("\npackage checks passed\n");
}

function mcpToolCount(command, project) {
  return new Promise((resolve) => {
    const [file, rest] = commandLine(command, ["mcp", "--project", project]);
    const child = spawn(file, rest, { shell: isWindows, stdio: ["pipe", "pipe", "inherit"] });
    let buffer = "";
    const timer = setTimeout(() => {
      // On Windows the child is cmd.exe; gd under it goes only with the whole tree.
      if (isWindows) {
        spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { stdio: "ignore" });
      } else {
        child.kill();
      }
      resolve(-1);
    }, MCP_TIMEOUT_MS);
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      buffer += chunk;
      for (const line of buffer.split("\n").slice(0, -1)) {
        let message;
        try {
          message = JSON.parse(line);
        } catch {
          continue; // Not a protocol message; if no answer comes, the timeout fails the check.
        }
        if (message.id === 2) {
          clearTimeout(timer);
          child.stdin.end();
          resolve(message.result?.tools?.length ?? -1);
        }
      }
      buffer = buffer.slice(buffer.lastIndexOf("\n") + 1);
    });
    const send = (message) => child.stdin.write(`${JSON.stringify(message)}\n`);
    send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "package-test", version: "0" } } });
    send({ jsonrpc: "2.0", method: "notifications/initialized" });
    send({ jsonrpc: "2.0", id: 2, method: "tools/list" });
  });
}
