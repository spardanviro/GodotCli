import { describe, expect, test } from "vitest";

import { errorOf, exitCodeOf, failure, failureWithData, isEnvelopeError, success } from "../src/envelope.js";
import { ExitCode, PROTOCOL_VERSION } from "../src/protocol.js";

describe("success", () => {
  test("builds an envelope with data, no errors and the protocol number", () => {
    const envelope = success("scene_tree", { root: "Main" }, { scene: "res://main.tscn" });

    expect(envelope).toEqual({
      success: true,
      command: "scene_tree",
      data: { root: "Main" },
      errors: [],
      warnings: [],
      meta: { protocol: PROTOCOL_VERSION, scene: "res://main.tscn" },
    });
  });

  test("does not let the caller's warnings array be changed through the envelope", () => {
    const warnings = ["not undoable"];

    const envelope = success("scene_save", {}, {}, warnings);

    expect(envelope.warnings).toEqual(warnings);
    expect(envelope.warnings).not.toBe(warnings);
  });

  test("exits with zero", () => {
    expect(exitCodeOf(success("help", {}))).toBe(ExitCode.Success);
  });
});

describe("failure", () => {
  test("sets data to null and keeps every error", () => {
    const errors = [
      { code: "NODE_NOT_FOUND", message: "no such node", details: { path: "A/B" } },
      { code: "COMMAND_FAILED", message: "follow-up" },
    ];

    const envelope = failure("node_get", errors);

    expect(envelope.success).toBe(false);
    expect(envelope.data).toBeNull();
    expect(envelope.errors).toEqual(errors);
    expect(envelope.errors).not.toBe(errors);
  });

  test("takes the exit code from the first error", () => {
    const envelope = failure("node_get", [
      { code: "EDITOR_BUSY", message: "busy" },
      { code: "INTERNAL_ERROR", message: "later" },
    ]);

    expect(exitCodeOf(envelope)).toBe(ExitCode.Transient);
  });

  test("reports a failure without errors as an internal error", () => {
    expect(exitCodeOf(failure("node_get", []))).toBe(ExitCode.Internal);
  });

  test("can carry a report while still being a failure", () => {
    const envelope = failureWithData("run", { error_count: 2 }, [errorOf("COMMAND_FAILED", "errors")]);

    expect(envelope.success).toBe(false);
    expect(envelope.data).toEqual({ error_count: 2 });
    expect(exitCodeOf(envelope)).toBe(ExitCode.CommandFailed);
  });
});

describe("errorOf", () => {
  test("leaves out the optional fields that were not given", () => {
    expect(errorOf("NO_EDITOR", "none")).toEqual({ code: "NO_EDITOR", message: "none" });
    expect(errorOf("NO_EDITOR", "none", "open it", { project: "p" })).toEqual({
      code: "NO_EDITOR",
      message: "none",
      hint: "open it",
      details: { project: "p" },
    });
  });

  test("is recognised as an error and plain values are not", () => {
    expect(isEnvelopeError(errorOf("TIMEOUT", "late"))).toBe(true);
    expect(isEnvelopeError("C:/project")).toBe(false);
    expect(isEnvelopeError(null)).toBe(false);
    expect(isEnvelopeError({ code: 1, message: "x" })).toBe(false);
  });
});
