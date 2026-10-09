import { describe, expect, test } from "vitest";

import { type Io, readCliVersion, run } from "../src/cli.js";
import type { Envelope } from "../src/envelope.js";
import { ExitCode, PROTOCOL_VERSION } from "../src/protocol.js";

interface Captured {
  readonly io: Io;
  readonly out: () => string;
  readonly err: () => string;
}

function capture(env: Readonly<Record<string, string | undefined>> = {}): Captured {
  const out: string[] = [];
  const err: string[] = [];
  return {
    io: {
      stdout: (text) => void out.push(text),
      stderr: (text) => void err.push(text),
      env,
    },
    out: () => out.join(""),
    err: () => err.join(""),
  };
}

function parseEnvelope(text: string): Envelope {
  return JSON.parse(text) as Envelope;
}

describe("gd --version", () => {
  test("prints the version and protocol number for people", () => {
    const captured = capture();

    const exitCode = run(["--version"], captured.io);

    expect(exitCode).toBe(ExitCode.Success);
    expect(captured.out()).toBe(`gd ${readCliVersion()} (protocol ${PROTOCOL_VERSION})\n`);
    expect(captured.err()).toBe("");
  });

  test("prints an envelope with --json", () => {
    const captured = capture();

    const exitCode = run(["--version", "--json"], captured.io);

    expect(exitCode).toBe(ExitCode.Success);
    expect(parseEnvelope(captured.out())).toMatchObject({
      success: true,
      command: "version",
      data: { version: readCliVersion(), protocol: PROTOCOL_VERSION },
    });
  });
});

describe("gd --help", () => {
  test("prints usage and exits with zero when no command is given", () => {
    const captured = capture();

    const exitCode = run([], captured.io);

    expect(exitCode).toBe(ExitCode.Success);
    expect(captured.out()).toContain("Usage: gd");
  });

  test("prints usage for -h even when a command follows", () => {
    const captured = capture();

    const exitCode = run(["status", "-h"], captured.io);

    expect(exitCode).toBe(ExitCode.Success);
    expect(captured.out()).toContain("Usage: gd");
  });
});

describe("output format", () => {
  test("reads the format from the environment", () => {
    const captured = capture({ GDCLI_FORMAT: "json" });

    run(["--version"], captured.io);

    expect(parseEnvelope(captured.out()).command).toBe("version");
  });

  test("lets --format override both --json and the environment", () => {
    const captured = capture({ GDCLI_FORMAT: "json" });

    run(["--version", "--json", "--format", "human"], captured.io);

    expect(captured.out()).toMatch(/^gd /);
  });

  test("rejects an unknown format with a usage error", () => {
    const captured = capture();

    const exitCode = run(["--version", "--format", "yaml"], captured.io);

    expect(exitCode).toBe(ExitCode.Usage);
    expect(captured.out()).toBe("");
    expect(captured.err()).toContain("error[USAGE]");
    expect(captured.err()).toContain("yaml");
  });
});

describe("output format edge cases", () => {
  test("treats an empty environment variable as unset", () => {
    const captured = capture({ GDCLI_FORMAT: "" });

    const exitCode = run(["--version"], captured.io);

    expect(exitCode).toBe(ExitCode.Success);
    expect(captured.out()).toMatch(/^gd /);
  });

  test.each([
    [["--no-such-option", "--format", "json"]],
    [["--no-such-option", "--format=json"]],
    [["--format", "json", "--no-such-option"]],
  ])("keeps the JSON envelope for unparseable options given %j", (argv) => {
    const captured = capture();

    const exitCode = run(argv, captured.io);

    expect(exitCode).toBe(ExitCode.Usage);
    expect(captured.err()).toBe("");
    expect(parseEnvelope(captured.out()).errors[0]?.code).toBe("USAGE");
  });

  test("lets a later --format human override --json when options cannot be parsed", () => {
    const captured = capture();

    run(["--no-such-option", "--json", "--format", "human"], captured.io);

    expect(captured.out()).toBe("");
    expect(captured.err()).toContain("error[USAGE]");
  });
});

describe("internal errors", () => {
  const brokenDeps = {
    readVersion: (): string => {
      throw new Error("manifest unreadable");
    },
  };

  test("answers with an INTERNAL_ERROR envelope instead of a stack trace", () => {
    const captured = capture();

    const exitCode = run(["--version", "--json"], captured.io, brokenDeps);

    expect(exitCode).toBe(ExitCode.Internal);
    expect(parseEnvelope(captured.out())).toMatchObject({
      success: false,
      errors: [{ code: "INTERNAL_ERROR", message: "manifest unreadable" }],
    });
  });

  test("reports the internal error on stderr for people", () => {
    const captured = capture();

    const exitCode = run(["--version"], captured.io, brokenDeps);

    expect(exitCode).toBe(ExitCode.Internal);
    expect(captured.out()).toBe("");
    expect(captured.err()).toContain("error[INTERNAL_ERROR]: manifest unreadable");
  });
});

describe("failures", () => {
  test("reports an unknown command on stderr for people", () => {
    const captured = capture();

    const exitCode = run(["frobnicate"], captured.io);

    expect(exitCode).toBe(ExitCode.Usage);
    expect(captured.out()).toBe("");
    expect(captured.err()).toContain('error[UNKNOWN_COMMAND]: Unknown command "frobnicate".');
    expect(captured.err()).toContain("hint:");
  });

  test("writes the failure envelope to stdout with --json", () => {
    const captured = capture();

    const exitCode = run(["frobnicate", "--json"], captured.io);

    expect(exitCode).toBe(ExitCode.Usage);
    expect(captured.err()).toBe("");
    expect(parseEnvelope(captured.out())).toMatchObject({
      success: false,
      command: "frobnicate",
      data: null,
      errors: [{ code: "UNKNOWN_COMMAND" }],
    });
  });

  test("still answers with an envelope when the options cannot be parsed", () => {
    const captured = capture();

    const exitCode = run(["--no-such-option", "--json"], captured.io);

    expect(exitCode).toBe(ExitCode.Usage);
    expect(parseEnvelope(captured.out())).toMatchObject({
      success: false,
      errors: [{ code: "USAGE" }],
    });
  });

  test("reports unparseable options on stderr without --json", () => {
    const captured = capture();

    const exitCode = run(["--no-such-option"], captured.io);

    expect(exitCode).toBe(ExitCode.Usage);
    expect(captured.out()).toBe("");
    expect(captured.err()).toContain("error[USAGE]");
  });
});
