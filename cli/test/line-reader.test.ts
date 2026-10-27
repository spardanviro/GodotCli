import { describe, expect, test } from "vitest";

import { boundedLines } from "../src/line-reader.js";

async function collect(chunks: readonly (Buffer | string)[], maxChars: number): Promise<string[]> {
  const lines: string[] = [];
  for await (const line of boundedLines(chunks, maxChars)) {
    lines.push(line);
  }
  return lines;
}

describe("boundedLines", () => {
  test("splits lines across chunks, drops CR, and keeps a last line without a newline", async () => {
    expect(await collect(["ab", "c\r\nde\n", "f"], 10)).toEqual(["abc", "de", "f"]);
  });

  test("a line past the limit comes out one character too long, and the rest of it is skipped", async () => {
    const lines = await collect(["x".repeat(6), "y".repeat(6), "zz\nok\n"], 8);

    expect(lines).toEqual(["x".repeat(6) + "yyy", "ok"]);
  });

  test("a line of exactly the limit whose CRLF is split between chunks is kept", async () => {
    expect(await collect(["abcd\r", "\nok\n"], 4)).toEqual(["abcd", "ok"]);
  });

  test("a character split between chunks is put back together", async () => {
    const bytes = Buffer.from("é\n", "utf8");

    expect(await collect([bytes.subarray(0, 1), bytes.subarray(1)], 10)).toEqual(["é"]);
  });
});
