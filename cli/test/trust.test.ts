import { chmodSync, mkdirSync, symlinkSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, test } from "vitest";

import { isWritableOnlyByUser, readPrivateFile } from "../src/trust.js";
import { tempDir, writeFile } from "./helpers.js";

const POSIX = process.platform !== "win32";
const options = { platform: process.platform, maxBytes: 64, secret: false } as const;

/** A link where the system allows one (Windows needs developer mode for file links). */
function linkTo(target: string, path: string): boolean {
  try {
    symlinkSync(target, path);
    return true;
  } catch {
    return false;
  }
}

describe("readPrivateFile", () => {
  test("reads a small file of the user", () => {
    const file = writeFile(join(tempDir(), "config.json"), '{"a":1}');

    expect(readPrivateFile(file, options)).toBe('{"a":1}');
  });

  test("refuses a file past the size limit, a folder and a missing file", () => {
    const root = tempDir();
    const big = writeFile(join(root, "big.json"), "x".repeat(65));
    mkdirSync(join(root, "folder"));

    expect(readPrivateFile(big, options)).toBeUndefined();
    expect(readPrivateFile(join(root, "folder"), options)).toBeUndefined();
    expect(readPrivateFile(join(root, "missing.json"), options)).toBeUndefined();
  });

  test("refuses a link, whatever it points at", () => {
    const root = tempDir();
    const real = writeFile(join(root, "real.json"), "{}");
    const link = join(root, "link.json");

    if (linkTo(real, link)) {
      expect(readPrivateFile(link, options)).toBeUndefined();
    }
  });

  test.skipIf(!POSIX)("refuses a file others can change, and for a secret one others can read", () => {
    const root = tempDir();
    const shared = writeFile(join(root, "shared.json"), "{}");
    chmodSync(shared, 0o666);
    const readable = writeFile(join(root, "token.json"), "{}");
    chmodSync(readable, 0o644);

    expect(readPrivateFile(shared, options)).toBeUndefined();
    expect(readPrivateFile(readable, options)).toBe("{}");
    expect(readPrivateFile(readable, { ...options, secret: true })).toBeUndefined();
  });
});

describe("isWritableOnlyByUser", () => {
  test("a folder of the user is, a missing one and a link are not", () => {
    const root = tempDir();
    mkdirSync(join(root, "mine"));
    const link = join(root, "link");

    expect(isWritableOnlyByUser(join(root, "mine"), process.platform)).toBe(true);
    expect(isWritableOnlyByUser(join(root, "missing"), process.platform)).toBe(false);
    if (linkTo(join(root, "mine"), link)) {
      expect(isWritableOnlyByUser(link, process.platform)).toBe(false);
    }
  });

  test.skipIf(!POSIX)("a folder the group or others can write to is not", () => {
    const root = tempDir();
    const shared = join(root, "shared");
    mkdirSync(shared);
    chmodSync(shared, 0o777);

    expect(isWritableOnlyByUser(shared, process.platform)).toBe(false);
  });
});
