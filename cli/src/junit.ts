/**
 * Reads a JUnit XML report, the format GUT and gdUnit4 both write. Only what a
 * report needs is read: each test case, and whether it failed or was skipped.
 */

export interface TestCase {
  readonly suite: string;
  readonly name: string;
  readonly outcome: "passed" | "failed" | "skipped";
  /** Why it failed or was skipped, first lines only. */
  readonly message: string;
}

export interface TestReport {
  readonly tests: number;
  readonly passed: number;
  readonly failed: number;
  readonly skipped: number;
  readonly cases: readonly TestCase[];
}

const MAX_MESSAGE_CHARS = 600;
const TEST_CASE = /<testcase\b([^>]*?)(?:\/>|>([\s\S]*?)<\/testcase>)/gu;
const FAILURE = /<(failure|error)\b([^>]*?)(?:\/>|>([\s\S]*?)<\/\1>)/u;
const SKIPPED = /<skipped\b([^>]*?)(?:\/>|>([\s\S]*?)<\/skipped>)/u;
const ENTITIES: Readonly<Record<string, string>> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };

const MAX_CODE_POINT = 0x10ffff;

function character(code: number, whole: string): string {
  return Number.isInteger(code) && code >= 0 && code <= MAX_CODE_POINT ? String.fromCodePoint(code) : whole;
}

function entities(text: string): string {
  return text.replace(/&(?:#x([0-9a-f]+)|#(\d+)|(\w+));/giu, (whole, hex: string | undefined, decimal: string | undefined, name: string | undefined) => {
    if (hex !== undefined) {
      return character(Number.parseInt(hex, 16), whole);
    }
    if (decimal !== undefined) {
      return character(Number.parseInt(decimal, 10), whole);
    }
    return ENTITIES[name ?? ""] ?? whole;
  });
}

/** Text of XML: entities decoded, CDATA sections taken as they are. */
function decode(text: string): string {
  return text
    .split(/(<!\[CDATA\[[\s\S]*?\]\]>)/u)
    .map((part) => (part.startsWith("<![CDATA[") ? part.slice("<![CDATA[".length, -"]]>".length) : entities(part)))
    .join("");
}

function attribute(attributes: string, name: string): string {
  const found = new RegExp(`\\b${name}\\s*=\\s*"([^"]*)"`, "u").exec(attributes);
  return found === null ? "" : decode(found[1] ?? "");
}

function messageOf(attributes: string, body: string | undefined): string {
  const text = [attribute(attributes, "message"), decode(body ?? "").trim()].filter((part) => part !== "").join("\n");
  return text.length > MAX_MESSAGE_CHARS ? `${text.slice(0, MAX_MESSAGE_CHARS)}...` : text;
}

/** The suite a test case belongs to: its classname, or the enclosing testsuite's name. */
function suiteAt(xml: string, index: number): string {
  const opening = xml.lastIndexOf("<testsuite ", index);
  return opening === -1 ? "" : attribute(xml.slice(opening, xml.indexOf(">", opening)), "name");
}

export function parseJUnit(xml: string): TestReport {
  const cases: TestCase[] = [];
  for (const match of xml.matchAll(TEST_CASE)) {
    const attributes = match[1] ?? "";
    const body = match[2] ?? "";
    const suite = attribute(attributes, "classname") || suiteAt(xml, match.index ?? 0);
    const name = attribute(attributes, "name");
    const failure = FAILURE.exec(body);
    const skipped = SKIPPED.exec(body);
    if (failure !== null) {
      cases.push({ suite, name, outcome: "failed", message: messageOf(failure[2] ?? "", failure[3]) });
    } else if (skipped !== null) {
      cases.push({ suite, name, outcome: "skipped", message: messageOf(skipped[1] ?? "", skipped[2]) });
    } else {
      cases.push({ suite, name, outcome: "passed", message: "" });
    }
  }
  const count = (outcome: TestCase["outcome"]): number => cases.filter((entry) => entry.outcome === outcome).length;
  return { tests: cases.length, passed: count("passed"), failed: count("failed"), skipped: count("skipped"), cases };
}
