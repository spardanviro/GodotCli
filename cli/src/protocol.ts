// Constants shared with the editor bridge. The normative text is docs/protocol.md;
// scripts/check-versions.mjs keeps PROTOCOL_VERSION in step with the bridge.

export const PROTOCOL_VERSION = 1;

export const ExitCode = {
  Success: 0,
  Internal: 1,
  Usage: 2,
  Auth: 3,
  Precondition: 4,
  Transient: 5,
  CommandFailed: 6,
  Interrupted: 130,
} as const;

export type ExitCode = (typeof ExitCode)[keyof typeof ExitCode];

const EXIT_CODE_BY_ERROR = {
  USAGE: ExitCode.Usage,
  INVALID_ARGS: ExitCode.Usage,
  UNKNOWN_COMMAND: ExitCode.Usage,
  AUTH_FAILED: ExitCode.Auth,
  FORBIDDEN_ORIGIN: ExitCode.Auth,
  NO_PROJECT: ExitCode.Precondition,
  GODOT_NOT_FOUND: ExitCode.Precondition,
  UNSUPPORTED_GODOT_VERSION: ExitCode.Precondition,
  BRIDGE_NOT_INSTALLED: ExitCode.Precondition,
  NO_EDITOR: ExitCode.Precondition,
  MULTIPLE_EDITORS: ExitCode.Precondition,
  PROTOCOL_MISMATCH: ExitCode.Precondition,
  READONLY_MODE: ExitCode.Precondition,
  CONFIRMATION_REQUIRED: ExitCode.Precondition,
  EVAL_DISABLED: ExitCode.Precondition,
  PRECONDITION_FAILED: ExitCode.Precondition,
  EDITOR_BUSY: ExitCode.Transient,
  TIMEOUT: ExitCode.Transient,
  PATH_NOT_ALLOWED: ExitCode.CommandFailed,
  NODE_NOT_FOUND: ExitCode.CommandFailed,
  RESOURCE_NOT_FOUND: ExitCode.CommandFailed,
  ALREADY_EXISTS: ExitCode.CommandFailed,
  TYPE_MISMATCH: ExitCode.CommandFailed,
  COMMAND_FAILED: ExitCode.CommandFailed,
  INTERNAL_ERROR: ExitCode.Internal,
} as const satisfies Record<string, ExitCode>;

export type ErrorCode = keyof typeof EXIT_CODE_BY_ERROR;

export const ERROR_CODES: readonly ErrorCode[] = Object.freeze(
  Object.keys(EXIT_CODE_BY_ERROR) as ErrorCode[],
);

export function isErrorCode(code: string): code is ErrorCode {
  return Object.hasOwn(EXIT_CODE_BY_ERROR, code);
}

/**
 * Codes this build does not know (a newer bridge, a project-defined command)
 * are treated as an ordinary command failure rather than an internal error.
 */
export function exitCodeFor(code: string): ExitCode {
  return isErrorCode(code) ? EXIT_CODE_BY_ERROR[code] : ExitCode.CommandFailed;
}
