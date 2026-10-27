import { existsSync, readFileSync, symlinkSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, test } from "vitest";

import { SKILL_MARKER } from "../src/commands/skills.js";
import { ExitCode } from "../src/protocol.js";
import { harness, tempDir, writeFile } from "./helpers.js";

function setup(): { home: string; run: (...argv: string[]) => ReturnType<ReturnType<typeof harness>["json"]> } {
  const home = tempDir();
  const shipped = join(home, "package");
  writeFile(join(shipped, "skills", "godot-cli", "SKILL.md"), "---\nname: godot-cli\ndescription: Drive Godot with gd.\n---\n\n# gd\n");
  writeFile(join(shipped, "skills", "godot-ui", "SKILL.md"), "---\nname: godot-ui\ndescription: Build user interfaces.\n---\n");
  writeFile(join(shipped, "skills", "godot-ui", "references", "gotchas.md"), "- a pitfall\n");
  const h = harness({ homeDir: home, addonDir: join(shipped, "addon") });
  return { home, run: (...argv) => h.json("skills", ...argv) };
}

describe("gd skills", () => {
  test("lists the shipped skills with their descriptions", async () => {
    const { run } = setup();

    const result = await run("list");

    expect(result.envelope.data).toEqual({ skills: [{ name: "godot-cli", description: "Drive Godot with gd." }, { name: "godot-ui", description: "Build user interfaces." }] });
  });

  test("shows what it would install for Codex and writes nothing without --yes", async () => {
    const { home, run } = setup();

    const result = await run("install", "codex");

    expect(result.exitCode).toBe(ExitCode.Success);
    expect(result.envelope.data).toMatchObject({ folder: join(home, ".codex", "skills"), written: false, skills: [{ name: "godot-cli", state: "new" }, { name: "godot-ui", state: "new" }] });
    expect(existsSync(join(home, ".codex", "skills"))).toBe(false);
  });

  test("--dry-run with --yes still installs nothing", async () => {
    const { home, run } = setup();

    const result = await run("install", "codex", "--yes", "--dry-run");

    expect(result.envelope.data).toMatchObject({ written: false });
    expect(existsSync(join(home, ".codex", "skills"))).toBe(false);
  });

  test("installs with their references, marked as gd's, and updates them on the next run", async () => {
    const { home, run } = setup();
    const folder = join(home, ".codex", "skills");

    await run("install", "codex", "--yes");
    const again = await run("install", "codex", "--yes");

    expect(readFileSync(join(folder, "godot-ui", "references", "gotchas.md"), "utf8")).toBe("- a pitfall\n");
    expect(readFileSync(join(folder, "godot-cli", SKILL_MARKER), "utf8")).toBe("9.9.9\n");
    expect(again.envelope.data).toMatchObject({ written: true, skills: [{ state: "update" }, { state: "update" }] });
  });

  test("never replaces a skill of the same name that is not gd's", async () => {
    const { home, run } = setup();
    const own = writeFile(join(home, "agent", "godot-ui", "SKILL.md"), "mine\n");

    const result = await run("install", "--dir", join(home, "agent"), "--yes");

    expect(readFileSync(own, "utf8")).toBe("mine\n");
    expect(result.envelope.data).toMatchObject({ skipped: ["godot-ui"], written: true });
    expect(existsSync(join(home, "agent", "godot-cli", "SKILL.md"))).toBe(true);
  });

  test("an unmarked folder, or a marker that is not a file, is someone else's", async () => {
    const { home, run } = setup();
    writeFile(join(home, "agent", "godot-cli", "SKILL.md"), "mine\n");
    writeFile(join(home, "agent", "godot-ui", SKILL_MARKER, "inside"), "a folder, not a marker\n");

    const result = await run("install", "--dir", join(home, "agent"));

    expect(result.envelope.data).toMatchObject({ skipped: ["godot-cli", "godot-ui"] });
  });

  test.skipIf(process.platform === "win32")("does not write through a linked skills folder", async () => {
    const { home, run } = setup();
    const elsewhere = tempDir();
    symlinkSync(elsewhere, join(home, "linked"));

    const result = await run("install", "--dir", join(home, "linked"), "--yes");

    expect(result.envelope.errors[0]?.code).toBe("PRECONDITION_FAILED");
  });

  test("needs a target, and says so when the package has no skills", async () => {
    const { run } = setup();
    const empty = harness({ addonDir: join(tempDir(), "addon") });

    const noTarget = await run("install");
    const unknownAgent = await run("install", "cursor");
    const nothing = await empty.json("skills", "install", "codex");

    expect(noTarget.exitCode).toBe(ExitCode.Usage);
    expect(unknownAgent.exitCode).toBe(ExitCode.Usage);
    expect(nothing.envelope.errors[0]?.code).toBe("PRECONDITION_FAILED");
  });
});
