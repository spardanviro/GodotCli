import { existsSync, mkdirSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, test } from "vitest";

import { isPluginEnabled } from "../src/commands/bridge.js";
import { headingsOf, pagesRoot, readable } from "../src/commands/docs.js";
import { projectFileText } from "../src/commands/new.js";
import { ExitCode } from "../src/protocol.js";
import { type Call, fakeProcesses, harness, tempDir, writeFile } from "./helpers.js";

/** A stand-in for the addon that ships with gd. */
function addon(root: string): string {
  const directory = join(root, "addon");
  writeFile(join(directory, "plugin.cfg"), '[plugin]\nname="gdcli"\nversion="9.9.9"\nscript="plugin.gd"\n');
  writeFile(join(directory, "runtime", "game_agent.gd"), "extends Node\n");
  return directory;
}

describe("gd new", () => {
  test("creates a project with the bridge installed and enabled", async () => {
    const root = tempDir();
    const gd = harness({ cwd: root, addonDir: addon(root) });

    const { exitCode, envelope } = await gd.json("new", "my game");
    const project = join(root, "my game");
    const projectText = readFileSync(join(project, "project.godot"), "utf8");

    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.data).toMatchObject({ project, name: "my game", renderer: "forward_plus", bridge: true });
    expect(projectText).toContain('config/name="my game"');
    expect(projectText).toContain("config_version=5");
    expect(isPluginEnabled(projectText)).toBe(true);
    expect(existsSync(join(project, "addons", "gdcli", "plugin.cfg"))).toBe(true);
    expect(readFileSync(join(project, ".gitignore"), "utf8")).toContain(".godot/");
  });

  test("takes a name and a renderer, and can leave the bridge out", async () => {
    const root = tempDir();
    const gd = harness({ cwd: root, addonDir: addon(root) });

    const { envelope } = await gd.json("new", "web", "--name", 'Say "hi"', "--renderer", "compatibility", "--no-bridge");
    const projectText = readFileSync(join(root, "web", "project.godot"), "utf8");

    expect(envelope.data).toMatchObject({ name: 'Say "hi"', renderer: "gl_compatibility", bridge: false });
    expect(projectText).toContain('config/name="Say \\"hi\\""');
    expect(projectText).toContain('renderer/rendering_method="gl_compatibility"');
    expect(projectText).toContain('renderer/rendering_method.mobile="gl_compatibility"');
    expect(existsSync(join(root, "web", "addons"))).toBe(false);
  });

  test("writes nothing about the renderer when it is the engine's default", () => {
    expect(projectFileText("x", "forward_plus")).not.toContain("[rendering]");
    expect(projectFileText("x", "mobile")).toContain('renderer/rendering_method="mobile"');
    expect(projectFileText("x", "mobile")).not.toContain(".mobile=");
  });

  test("refuses a folder that has something in it, and does nothing on a dry run", async () => {
    const root = tempDir();
    writeFile(join(root, "taken", "notes.txt"), "mine");
    const gd = harness({ cwd: root, addonDir: addon(root) });

    const taken = await gd.json("new", "taken");
    const dry = await gd.json("new", "fresh", "--dry-run");
    mkdirSync(join(root, "empty"));
    const intoEmpty = await gd.json("new", "empty");

    expect(taken.envelope.errors[0]?.code).toBe("ALREADY_EXISTS");
    expect(dry.envelope.data).toMatchObject({ dry_run: true, bridge: true });
    expect(existsSync(join(root, "fresh"))).toBe(false);
    expect(intoEmpty.exitCode).toBe(ExitCode.Success);
  });

  test("explains bad input", async () => {
    const gd = harness({ cwd: tempDir() });

    expect((await gd.json("new")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("new", "a", "b")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("new", "a", "--renderer", "vulkan")).envelope.errors[0]?.message).toContain("--renderer");
    expect((await gd.json("new", "a", "--renderer", "constructor")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("new", "a", "--name", "two\u2028lines")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("new", "a", "--name", " ")).exitCode).toBe(ExitCode.Usage);
  });

  test("still creates the project when the bridge cannot be installed", async () => {
    const root = tempDir();
    const gd = harness({ cwd: root });

    const { exitCode, envelope } = await gd.json("new", "bare");

    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.data).toMatchObject({ bridge: false });
    expect(envelope.warnings[0]).toContain("gd bridge install");
    expect(existsSync(join(root, "bare", "project.godot"))).toBe(true);
  });

  test("refuses a path that is a file, and leaves nothing behind", async () => {
    const root = tempDir();
    writeFile(join(root, "occupied"), "a file");
    const gd = harness({ cwd: root, addonDir: addon(root) });

    const { envelope } = await gd.json("new", "occupied");

    expect(envelope.errors[0]?.code).toBe("ALREADY_EXISTS");
    expect(readFileSync(join(root, "occupied"), "utf8")).toBe("a file");
  });
});

const TILEMAPS = `.. _doc_using_tilemaps:

Using TileMaps
==============

A tilemap is a grid of tiles. See :ref:\`TileMapLayer <class_TileMapLayer>\` and :ref:\`doc_using_tilesets\`.

.. figure:: img/tilemap.webp
   :align: center
   :alt: A picture

   The caption of the picture

Painting
--------

Use the paint tool.

Terrains
~~~~~~~~

Terrains pick tiles automatically.

Layers
------

One node per layer.
`;

/** A documentation folder as the offline HTML download lays it out. */
function docs(root: string): string {
  const folder = join(root, "godot-docs");
  writeFile(join(folder, "_sources", "index.rst.txt"), "Godot Docs\n==========\n\nWelcome.\n");
  writeFile(join(folder, "_sources", "tutorials", "2d", "using_tilemaps.rst.txt"), TILEMAPS);
  writeFile(join(folder, "_sources", "tutorials", "physics", "using_character_body_2d.rst.txt"), "Using CharacterBody2D\n=====================\n\nmove_and_slide moves the body. Tiles collide.\n");
  writeFile(join(folder, "_sources", "classes", "class_tilemaplayer.rst.txt"), "TileMapLayer\n============\n\nNode for 2D tile-based maps.\n");
  writeFile(join(folder, "index.html"), "<html></html>");
  return folder;
}

const HEADS = ["3.6", "4.4", "4.5", "master", "classref/sync-1234"].map((name) => `0123abc\trefs/heads/${name}`).join("\n");

/** A stand-in for git: lists the branches, and "clones" by writing two pages and a .git folder. */
function fakeGit(overrides: (call: Call) => Partial<{ code: number; stdout: string; spawnError: string }> | undefined = () => undefined) {
  return fakeProcesses((call) => {
    const override = overrides(call);
    if (override !== undefined) {
      return override;
    }
    if (call.args.includes("ls-remote")) {
      return { stdout: HEADS };
    }
    if (call.args.includes("clone")) {
      const target = call.args.at(-1) ?? "";
      writeFile(join(target, ".git", "config"), "[core]\n");
      writeFile(join(target, "index.rst"), "Godot Docs\n==========\n");
      writeFile(join(target, "tutorials", "2d", "using_tilemaps.rst"), TILEMAPS);
    }
    return {};
  }, "4.5.stable.official.876b29033\n");
}

describe("gd docs install", () => {
  test("fetches the manual of the Godot version in use, text only, and uses it from then on", async () => {
    const root = tempDir();
    const processes = fakeGit();
    const gd = harness({ homeDir: root, cwd: root, processes, env: { GODOT_BIN: writeFile(join(root, "godot-bin"), "") } });

    const { exitCode, envelope } = await gd.json("docs", "install");
    const folder = join(root, ".gdcli", "docs", "4.5");
    const clone = processes.calls.find((call) => call.args.includes("clone"));
    const found = await gd.json("docs", "search", "terrains");
    const where = await gd.json("docs", "where");

    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope.data).toMatchObject({ version: "4.5", folder, pages: 2 });
    const gitCalls = processes.calls.filter((call) => call.file === "git");
    expect(clone?.args).toEqual(
      expect.arrayContaining(["--template=", "--depth", "1", "--filter=blob:none", "--no-checkout", "--single-branch", "--branch", "4.5", "https://github.com/godotengine/godot-docs.git"]),
    );
    // Every call leaves the user's hooks and credential prompts out, and takes links as plain files.
    for (const call of gitCalls) {
      expect(call.args).toEqual(expect.arrayContaining(["core.hooksPath=/dev/null", "core.symlinks=false", "credential.interactive=never"]));
    }
    expect(gitCalls.map((call) => call.args.find((word) => ["ls-remote", "clone", "sparse-checkout", "checkout"].includes(word)))).toEqual(["ls-remote", "clone", "sparse-checkout", "checkout"]);
    expect(gitCalls[2]?.args).toContain("*.rst");
    expect(existsSync(join(folder, ".git"))).toBe(false);
    expect((found.envelope.data as { pages: { page: string }[] }).pages[0]?.page).toBe("tutorials/2d/using_tilemaps");
    expect(where.envelope.data).toMatchObject({ version: "4.5", pages: 2 });
  });

  test("takes the manual in development for a Godot newer than any published one", async () => {
    const root = tempDir();
    const base = fakeGit();
    const processes = { ...base, run: (file: string, args: readonly string[], options: { timeoutMs: number }) => (args[0] === "--version" ? Promise.resolve({ code: 0, stdout: "4.9.dev.custom_build\n", stderr: "", timedOut: false }) : base.run(file, args, options)) };
    const gd = harness({ homeDir: root, cwd: root, processes, env: { GODOT_BIN: writeFile(join(root, "godot-bin"), "") } });

    const dry = await gd.json("docs", "install", "--dry-run");
    const callsAfterDryRun = base.calls.length;
    const { envelope } = await gd.json("docs", "install");

    expect(dry.envelope.data).toMatchObject({ dry_run: true, version: "4.9", otherwise: "master" });
    expect(callsAfterDryRun).toBe(0);
    expect(envelope.data).toMatchObject({ version: "master", folder: join(root, ".gdcli", "docs", "master") });
  });

  test("takes a version by name, without needing Godot, and replaces an earlier download", async () => {
    const root = tempDir();
    const gd = harness({ homeDir: root, cwd: root, processes: fakeGit(), env: { PATH: "" } });
    writeFile(join(root, ".gdcli", "docs", "4.4", "stale.rst"), "Old\n===\n");

    const { envelope } = await gd.json("docs", "install", "4.4");
    const unknown = await gd.json("docs", "install", "9.9");
    const odd = await gd.json("docs", "install", "classref/sync-1234");

    expect(envelope.data).toMatchObject({ version: "4.4", pages: 2 });
    expect(existsSync(join(root, ".gdcli", "docs", "4.4", "stale.rst"))).toBe(false);
    expect(unknown.envelope.errors[0]).toMatchObject({ code: "RESOURCE_NOT_FOUND", details: { available: ["3.6", "4.4", "4.5", "master"] } });
    expect(odd.exitCode).toBe(ExitCode.Usage);
  });

  test("says what is missing when git is not there or the download fails, and leaves nothing half done", async () => {
    const root = tempDir();
    const noGit = harness({ homeDir: root, cwd: root, processes: fakeGit(() => ({ spawnError: "ENOENT" })) });
    const failing = harness({ homeDir: root, cwd: root, processes: fakeGit((call) => (call.args.includes("checkout") && !call.args.includes("sparse-checkout") ? { code: 128 } : undefined)) });

    const missing = await noGit.json("docs", "install", "4.5");
    const broken = await failing.json("docs", "install", "4.5");
    const noGodot = await harness({ homeDir: root, cwd: root, processes: fakeGit(), env: { PATH: "" } }).json("docs", "install");

    expect(missing.envelope.errors[0]).toMatchObject({ code: "PRECONDITION_FAILED", details: { reason: "git was not found" } });
    expect(broken.envelope.errors[0]).toMatchObject({ code: "PRECONDITION_FAILED", details: { step: "checkout" } });
    expect(existsSync(join(root, ".gdcli", "docs", "4.5"))).toBe(false);
    expect(readdirSync(join(root, ".gdcli", "docs"))).toEqual([]);
    expect(noGodot.envelope.errors[0]?.hint).toContain("gd docs install 4.5");
  });
});

describe("gd docs", () => {
  test("says how to get the documentation when none is set up", async () => {
    const { exitCode, envelope } = await harness().json("docs", "search", "tilemap");

    expect(exitCode).toBe(ExitCode.Precondition);
    expect(envelope.errors[0]?.hint).toContain("gd docs install");
  });

  test("remembers a folder and finds pages in it by what they are about", async () => {
    const root = tempDir();
    const gd = harness({ cwd: root });

    const used = await gd.json("docs", "use", docs(root));
    const found = await gd.json("docs", "search", "terrains", "tiles");
    const where = await gd.json("docs", "where");

    expect(used.envelope.data).toMatchObject({ pages: 4 });
    expect(found.envelope.data).toMatchObject({ pages: [{ page: "tutorials/2d/using_tilemaps", title: "Using TileMaps", sections: ["Terrains"] }], total: 1 });
    expect(where.envelope.data).toMatchObject({ pages: 4 });
  });

  test("leaves the class reference out unless asked, and ranks a title above a mention", async () => {
    const root = tempDir();
    const gd = harness({ cwd: root, env: { GDCLI_DOCS: docs(root) } });

    const manual = await gd.json("docs", "search", "tile");
    const all = await gd.json("docs", "search", "tilemaplayer", "--classes");

    expect((manual.envelope.data as { pages: { page: string }[] }).pages.map((page) => page.page)).toEqual([
      "tutorials/2d/using_tilemaps",
      "tutorials/physics/using_character_body_2d",
    ]);
    expect((all.envelope.data as { pages: { page: string }[] }).pages[0]?.page).toBe("classes/class_tilemaplayer");
  });

  test("falls back to pages with some of the words, and says so", async () => {
    const root = tempDir();
    const gd = harness({ cwd: root, env: { GDCLI_DOCS: docs(root) } });

    const { envelope } = await gd.json("docs", "search", "terrains", "quaternion");

    expect((envelope.data as { pages: unknown[] }).pages).toHaveLength(1);
    expect(envelope.warnings[0]).toContain("some of them");
  });

  test("prints a page as text a reader would see, or one section of it", async () => {
    const root = tempDir();
    const gd = harness({ cwd: root, env: { GDCLI_DOCS: docs(root) } });

    const page = await gd.json("docs", "page", "tutorials/2d/using_tilemaps");
    const section = await gd.json("docs", "page", "tutorials/2d/using_tilemaps.html", "--section", "painting");
    const short = await gd.json("docs", "page", "tutorials/2d/using_tilemaps", "--max-chars", "40");
    const data = page.envelope.data as { text: string; sections: string[]; truncated: boolean };

    expect(data.sections).toEqual(["Painting", "Terrains", "Layers"]);
    expect(data.text).toContain("See TileMapLayer and doc_using_tilesets.");
    expect(data.text).not.toContain("figure");
    expect(data.text).not.toContain("caption of the picture");
    expect((section.envelope.data as { text: string }).text).toMatch(/^Painting\n-+\n\nUse the paint tool\.\n\nTerrains\n~+\n\nTerrains pick tiles automatically\.\s*$/u);
    expect(short.envelope.data).toMatchObject({ truncated: true });
    expect(short.envelope.warnings[0]).toContain("--section");
  });

  test("reports pages, sections and folders that are not there", async () => {
    const root = tempDir();
    const gd = harness({ cwd: root, env: { GDCLI_DOCS: docs(root) } });

    const noPage = await gd.json("docs", "page", "tutorials/../../secrets");
    const noSection = await gd.json("docs", "page", "tutorials/2d/using_tilemaps", "--section", "Shaders");
    const notDocs = await gd.json("docs", "use", root);

    expect(noPage.envelope.errors[0]?.code).toBe("RESOURCE_NOT_FOUND");
    expect(noSection.envelope.errors[0]?.details).toMatchObject({ sections: ["Using TileMaps", "Painting", "Terrains", "Layers"] });
    expect(notDocs.envelope.errors[0]?.code).toBe("RESOURCE_NOT_FOUND");
    expect((await gd.json("docs")).exitCode).toBe(ExitCode.Usage);
    expect((await gd.json("docs", "search", "!")).exitCode).toBe(ExitCode.Usage);
  });

  test("does not take code for headings, skips what is no page, and changes nothing on a dry run", async () => {
    const root = tempDir();
    const folder = docs(root);
    writeFile(
      join(folder, "_sources", "tutorials", "code.rst.txt"),
      'Code\n====\n\n::\n\n    var text = \"\"\"\n    \"\"\"\n    ----\n\nReal part\n---------\n\n.. code-tab:: csharp\n\n    class X {}\n',
    );
    writeFile(join(folder, "_sources", "tutorials", "huge.rst.txt"), `Huge\n====\n${"terrains ".repeat(300_000)}`);
    const gd = harness({ cwd: root, env: { GDCLI_DOCS: folder } });

    const code = await gd.json("docs", "page", "tutorials/code");
    const huge = await gd.json("docs", "search", "huge");
    const remembered = await harness({ cwd: root }).json("docs", "use", folder, "--dry-run");

    expect((code.envelope.data as { sections: string[] }).sections).toEqual(["Real part"]);
    expect((code.envelope.data as { text: string }).text).not.toContain("class X");
    expect((huge.envelope.data as { pages: unknown[] }).pages).toHaveLength(0);
    expect(remembered.envelope.data).toMatchObject({ dry_run: true });
  });

  test("reads a checkout of the documentation repository too", () => {
    const root = tempDir();
    writeFile(join(root, "repo", "index.rst"), "Godot Docs\n==========\n");

    expect(pagesRoot(join(root, "repo"))).toBe(join(root, "repo"));
    expect(pagesRoot(root)).toBeUndefined();
  });

  test("tells headings from other underlined-looking lines", () => {
    expect(headingsOf(["Title", "=====", "", "text", "", "Part", "----", "====", "----"]).map((heading) => heading.text)).toEqual(["Title", "Part"]);
    expect(readable(":ref:`Sprite2D <class_Sprite2D>` and :kbd:`F5`")).toBe("Sprite2D and F5");
  });
});
