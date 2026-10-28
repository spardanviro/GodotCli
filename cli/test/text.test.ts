import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, test } from "vitest";

import { UNSAFE_RANGES, sanitize } from "../src/text.js";

const BRIDGE_SANITIZER = fileURLToPath(new URL("../../bridge/addons/gdcli/core/text_sanitizer.gd", import.meta.url));

/** The ranges of the bridge's _UNSAFE_RANGES, as pairs. */
function bridgeRanges(): number[][] {
  const text = readFileSync(BRIDGE_SANITIZER, "utf8");
  const block = /_UNSAFE_RANGES: Array\[int\] = \[([\s\S]*?)\n\]/u.exec(text)?.[1] ?? "";
  const numbers = [...block.replaceAll(/#[^\n]*/gu, "").matchAll(/0x([0-9A-Fa-f]+)/gu)].map((match) => Number.parseInt(match[1] ?? "", 16));
  const pairs: number[][] = [];
  for (let index = 0; index < numbers.length; index += 2) {
    pairs.push([numbers[index] ?? -1, numbers[index + 1] ?? -1]);
  }
  return pairs;
}

describe("sanitize", () => {
  test("removes the same characters as the bridge does", () => {
    expect(UNSAFE_RANGES.map(([first, last]) => [first, last])).toEqual(bridgeRanges());
  });

  test("leaves visible text, tabs and line breaks, and removes what hides text", () => {
    const hidden = ["‮", "​", "ᅟ", "⠀", "\u{e0100}", "\u{e0041}"].join("");

    expect(sanitize(`a\tb\nc${hidden}d 中文`)).toBe("a\tb\ncd 中文");
  });
});
