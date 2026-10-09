import { describe, expect, test } from "vitest";

import { ERROR_CODES, ExitCode, exitCodeFor, isErrorCode } from "../src/protocol.js";

describe("exitCodeFor", () => {
  test.each([
    ["INVALID_ARGS", ExitCode.Usage],
    ["AUTH_FAILED", ExitCode.Auth],
    ["NO_EDITOR", ExitCode.Precondition],
    ["CONFIRMATION_REQUIRED", ExitCode.Precondition],
    ["EDITOR_BUSY", ExitCode.Transient],
    ["TIMEOUT", ExitCode.Transient],
    ["NODE_NOT_FOUND", ExitCode.CommandFailed],
    ["INTERNAL_ERROR", ExitCode.Internal],
  ])("maps %s to exit code %i", (code, expected) => {
    expect(exitCodeFor(code)).toBe(expected);
  });

  test("treats a code from a newer bridge as a command failure", () => {
    expect(exitCodeFor("SOMETHING_ADDED_LATER")).toBe(ExitCode.CommandFailed);
  });

  test("does not mistake inherited object keys for error codes", () => {
    expect(isErrorCode("toString")).toBe(false);
    expect(exitCodeFor("constructor")).toBe(ExitCode.CommandFailed);
  });
});

describe("ERROR_CODES", () => {
  test("never maps a failure to the success exit code", () => {
    const codesExitingZero = ERROR_CODES.filter((code) => exitCodeFor(code) === ExitCode.Success);

    expect(codesExitingZero).toEqual([]);
  });

  test("uses upper snake case for every code", () => {
    const malformed = ERROR_CODES.filter((code) => !/^[A-Z][A-Z0-9_]*$/.test(code));

    expect(malformed).toEqual([]);
  });
});
