import { StringDecoder } from "node:string_decoder";

/**
 * The lines of a stream, holding at most `maxChars` (+1) of any one line in
 * memory. A longer line is cut there, and the rest of it skipped; the cut
 * line comes out one character longer than `maxChars`, so the reader can
 * tell it apart and refuse it.
 */
export async function* boundedLines(input: AsyncIterable<Buffer | string> | Iterable<Buffer | string>, maxChars: number): AsyncGenerator<string> {
  const decoder = new StringDecoder("utf8");
  let line = "";
  let skipping = false;
  const take = function* (text: string): Generator<string> {
    let rest = text;
    for (let end = rest.indexOf("\n"); end !== -1; end = rest.indexOf("\n")) {
      const piece = rest.slice(0, end);
      if (!skipping) {
        yield stripCr(line + piece).slice(0, maxChars + 1);
      }
      line = "";
      skipping = false;
      rest = rest.slice(end + 1);
    }
    if (skipping) {
      return;
    }
    line += rest;
    // A trailing CR may be the first half of a CRLF still to come.
    if (line.length > maxChars + (line.endsWith("\r") ? 1 : 0)) {
      // Kept just long enough to be recognised as too long.
      yield line.slice(0, maxChars + 1);
      line = "";
      skipping = true;
    }
  };
  for await (const chunk of input) {
    yield* take(typeof chunk === "string" ? chunk : decoder.write(chunk));
  }
  yield* take(decoder.end());
  if (!skipping && line !== "") {
    yield stripCr(line);
  }
}

function stripCr(text: string): string {
  return text.endsWith("\r") ? text.slice(0, -1) : text;
}
