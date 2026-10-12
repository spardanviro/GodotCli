import { mkdirSync, symlinkSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, test } from "vitest";

import { isEnvelopeError } from "../src/envelope.js";
import { findProject, gdcliHome, samePath, toResPath } from "../src/project.js";
import { sanitize } from "../src/text.js";
import { harness, makeProject, tempDir, writeFile } from "./helpers.js";

const NO_GLOBALS = { format: "human", yes: false, dryRun: false } as const;

describe("findProject", () => {
  test("walks up from the working directory to the nearest project.godot", () => {
    const root = tempDir();
    const project = makeProject(root);
    const nested = join(project, "scenes", "levels");
    mkdirSync(nested, { recursive: true });

    expect(findProject(harness({ cwd: nested }).context, NO_GLOBALS)).toBe(project);
  });

  test("prefers --project over the environment over the working directory", () => {
    const root = tempDir();
    const project = makeProject(root);
    const context = harness({ cwd: root, env: { GDCLI_PROJECT: project } }).context;

    expect(findProject(context, NO_GLOBALS)).toBe(project);
    expect(findProject(context, { ...NO_GLOBALS, project: join(project, "project.godot") })).toBe(project);
    expect(findProject(context, { ...NO_GLOBALS, project: join(root, "elsewhere") })).toMatchObject({ code: "NO_PROJECT" });
  });

  test("reports NO_PROJECT when nothing is found", () => {
    expect(findProject(harness({ cwd: tempDir() }).context, NO_GLOBALS)).toMatchObject({ code: "NO_PROJECT" });
  });
});

describe("gdcliHome", () => {
  test("uses GDCLI_HOME when set and ~/.gdcli otherwise", () => {
    const home = tempDir();

    expect(gdcliHome(harness({ homeDir: home, env: { GDCLI_HOME: "D:/custom" } }).context)).toBe("D:/custom");
    expect(gdcliHome(harness({ homeDir: home, env: { GDCLI_HOME: "" } }).context)).toBe(join(home, ".gdcli"));
  });
});

describe("samePath", () => {
  test("ignores separators and trailing slashes, and case only on Windows", () => {
    expect(samePath("C:\\Games\\Demo\\", "c:/games/demo", "win32")).toBe(true);
    expect(samePath("/home/me/Demo", "/home/me/demo", "linux")).toBe(false);
    expect(samePath("/home/me/demo/", "/home/me/demo", "linux")).toBe(true);
  });
});

describe("toResPath", () => {
  function fixture(): { root: string; project: string } {
    const root = tempDir();
    const project = makeProject(root);
    writeFile(join(project, "scenes", "main.tscn"), "");
    writeFile(join(project, ".godot", "cache.bin"), "");
    writeFile(join(root, "outside.gd"), "");
    return { root, project };
  }

  test("accepts res:// paths and paths relative to the working directory", () => {
    const { project } = fixture();

    expect(toResPath(project, project, "res://scenes/main.tscn")).toBe("res://scenes/main.tscn");
    expect(toResPath(project, project, "scenes/main.tscn")).toBe("res://scenes/main.tscn");
    expect(toResPath(project, join(project, "scenes"), "main.tscn")).toBe("res://scenes/main.tscn");
  });

  test.each(["--main-pack", "-s", ""])("refuses %j, which the engine could read as an option", (input) => {
    const { project } = fixture();

    expect(toResPath(project, project, input)).toMatchObject({ code: "PATH_NOT_ALLOWED" });
  });

  test("refuses paths outside the project and hidden folders", () => {
    const { root, project } = fixture();

    for (const input of ["../outside.gd", "res://../outside.gd", join(root, "outside.gd"), "res://.godot/cache.bin", "res://", "."]) {
      expect(toResPath(project, project, input), input).toMatchObject({ code: "PATH_NOT_ALLOWED" });
    }
  });

  test("refuses other spellings of the hidden folders and Windows path tricks", () => {
    const { project } = fixture();
    writeFile(join(project, "..notes.gd"), "");

    for (const input of ["res://.GODOT/cache.bin", "res://GODOT~1/cache.bin", "res://scenes/main.tscn:stream", "res://scenes./main.tscn", "res://nul.gd"]) {
      expect(toResPath(project, project, input), input).toMatchObject({ code: "PATH_NOT_ALLOWED" });
    }
    expect(toResPath(project, project, "..notes.gd")).toBe("res://..notes.gd");
  });

  test("reports a missing file as not found", () => {
    const { project } = fixture();

    expect(toResPath(project, project, "scenes/missing.tscn")).toMatchObject({ code: "RESOURCE_NOT_FOUND" });
    expect(toResPath(project, project, "scenes")).toMatchObject({ code: "RESOURCE_NOT_FOUND" });
  });

  test("refuses a link that points out of the project", () => {
    const { root, project } = fixture();
    try {
      symlinkSync(join(root, "outside.gd"), join(project, "link.gd"));
    } catch {
      // Creating links needs a privilege on Windows; nothing to test without it.
      return;
    }

    const result = toResPath(project, project, "link.gd");

    expect(isEnvelopeError(result) && result.code).toBe("PATH_NOT_ALLOWED");
  });
});

describe("sanitize", () => {
  test("removes escape sequences and invisible characters but keeps ordinary text", () => {
    const hostile = `ok${String.fromCodePoint(0x1b)}[31mred${String.fromCodePoint(0x1b)}[0m ${String.fromCodePoint(0x202e)}rtl${String.fromCodePoint(0x200b)}${String.fromCodePoint(0xe0041)}`;

    expect(sanitize(hostile)).toBe("okred rtl");
    expect(sanitize("line one\n\ttabbed 中文 é")).toBe("line one\n\ttabbed 中文 é");
  });

  test("removes an OSC title sequence whole", () => {
    expect(sanitize(`a${String.fromCodePoint(0x1b)}]0;evil title${String.fromCodePoint(0x07)}b`)).toBe("ab");
  });
});
