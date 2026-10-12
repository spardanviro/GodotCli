import { describe, expect, test } from "vitest";

import { readCliVersion, splitGlobals } from "../src/cli.js";
import { ExitCode, PROTOCOL_VERSION } from "../src/protocol.js";
import { harness } from "./helpers.js";

describe("gd --version", () => {
  test("prints the version and protocol number for people", async () => {
    const gd = harness();

    const result = await gd.text("--version");

    expect(result.exitCode).toBe(ExitCode.Success);
    expect(result.out).toBe(`gd 9.9.9 (protocol ${PROTOCOL_VERSION})\n`);
    expect(result.err).toBe("");
  });

  test("prints an envelope with --json", async () => {
    const { exitCode, envelope } = await harness().json("--version");

    expect(exitCode).toBe(ExitCode.Success);
    expect(envelope).toMatchObject({ success: true, command: "version", data: { version: "9.9.9", protocol: PROTOCOL_VERSION } });
  });

  test("reads the real version from the package manifest", () => {
    expect(readCliVersion()).toMatch(/^\d+\.\d+\.\d+/u);
  });
});

describe("gd --help", () => {
  test("prints usage and exits with zero when no command is given", async () => {
    const result = await harness().text();

    expect(result.exitCode).toBe(ExitCode.Success);
    expect(result.out).toContain("Usage: gd <command>");
  });

  test("prints usage for -h even when a command follows", async () => {
    const result = await harness().text("status", "-h");

    expect(result.exitCode).toBe(ExitCode.Success);
    expect(result.out).toContain("Usage: gd <command>");
  });
});

describe("output format", () => {
  test("reads the format from the environment", async () => {
    const gd = harness({ env: { GDCLI_FORMAT: "json" } });

    const result = await gd.text("--version");

    expect(JSON.parse(result.out)).toMatchObject({ command: "version" });
  });

  test("treats an empty environment variable as unset", async () => {
    const result = await harness({ env: { GDCLI_FORMAT: "" } }).text("--version");

    expect(result.out).toMatch(/^gd /u);
  });

  test("lets --format override both --json and the environment", async () => {
    const result = await harness({ env: { GDCLI_FORMAT: "json" } }).text("--version", "--json", "--format", "human");

    expect(result.out).toMatch(/^gd /u);
  });

  test("accepts --format=json", async () => {
    const result = await harness().text("--version", "--format=json");

    expect(JSON.parse(result.out)).toMatchObject({ command: "version" });
  });

  test("rejects an unknown format with a usage error", async () => {
    const result = await harness().text("--version", "--format", "yaml");

    expect(result.exitCode).toBe(ExitCode.Usage);
    expect(result.out).toBe("");
    expect(result.err).toContain("error[USAGE]");
    expect(result.err).toContain("yaml");
  });

  test("keeps --json when the requested format is unusable", async () => {
    const result = await harness().text("--version", "--format", "xml", "--json");

    expect(JSON.parse(result.out)).toMatchObject({ success: false, errors: [{ code: "USAGE" }] });
  });

  test("does not take the next option as a missing value", async () => {
    const { exitCode, envelope } = await harness().json("status", "--timeout", "--yes");

    expect(exitCode).toBe(ExitCode.Usage);
    expect(envelope.errors[0]?.message).toContain("--timeout needs a value");
  });

  test("rejects a value option without a value", async () => {
    const { exitCode, envelope } = await harness().json("status", "--project");

    expect(exitCode).toBe(ExitCode.Usage);
    expect(envelope.errors[0]?.message).toContain("--project needs a value");
  });
});

describe("--timeout", () => {
  test.each(["0", "-3", "soon", "99999"])("rejects %s", async (value) => {
    const { exitCode, envelope } = await harness().json("status", "--timeout", value);

    expect(exitCode).toBe(ExitCode.Usage);
    expect(envelope.errors[0]?.code).toBe("USAGE");
  });
});

describe("failures", () => {
  test("reports an unknown command on stderr for people", async () => {
    const result = await harness().text("frobnicate");

    expect(result.exitCode).toBe(ExitCode.Usage);
    expect(result.out).toBe("");
    expect(result.err).toContain('error[UNKNOWN_COMMAND]: Unknown command "frobnicate".');
    expect(result.err).toContain("hint:");
  });

  test("writes the failure envelope to stdout with --json", async () => {
    const { exitCode, envelope } = await harness().json("frobnicate");

    expect(exitCode).toBe(ExitCode.Usage);
    expect(envelope).toMatchObject({ success: false, command: "frobnicate", data: null, errors: [{ code: "UNKNOWN_COMMAND" }] });
  });

  test("does not treat inherited object keys as commands", async () => {
    const { envelope } = await harness().json("constructor");

    expect(envelope.errors[0]?.code).toBe("UNKNOWN_COMMAND");
  });

  test("answers with an INTERNAL_ERROR envelope instead of a stack trace", async () => {
    const gd = harness({
      readVersion: () => {
        throw new Error("manifest unreadable");
      },
    });

    const { exitCode, envelope } = await gd.json("--version");

    expect(exitCode).toBe(ExitCode.Internal);
    expect(envelope).toMatchObject({ success: false, errors: [{ code: "INTERNAL_ERROR", details: { reason: "manifest unreadable" } }] });
    expect(gd.out().match(/"success"/gu)).toHaveLength(1);
  });

  test("prints details and strips terminal escapes from error text", async () => {
    const result = await harness().text("bridge", "status", "--project", "no\u001b[31mwhere");

    expect(result.exitCode).toBe(ExitCode.Precondition);
    expect(result.err).toContain("error[NO_PROJECT]");
    expect(result.err).toContain("details:");
    expect(result.err).not.toContain("\u001b");
  });
});

describe("splitGlobals", () => {
  test("pulls global options out from anywhere and keeps the rest in order", () => {
    const split = splitGlobals(["--json", "command", "scene_tree", "--project", "p", "--max-depth", "2", "--yes"]);

    expect(split.rest).toEqual(["command", "scene_tree", "--max-depth", "2"]);
    expect(split.values["--project"]).toBe("p");
    expect([...split.flags].sort()).toEqual(["json", "yes"]);
  });

  test("leaves everything after a literal -- alone", () => {
    const split = splitGlobals(["exec", "tool.gd", "--", "--json", "--project", "x"]);

    expect(split.rest).toEqual(["exec", "tool.gd", "--", "--json", "--project", "x"]);
    expect(split.flags.has("json")).toBe(false);
    expect(split.values["--project"]).toBeUndefined();
  });
});
