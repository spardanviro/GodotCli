import { ExitCode, PROTOCOL_VERSION, exitCodeFor } from "./protocol.js";

export interface EnvelopeError {
  readonly code: string;
  readonly message: string;
  readonly hint?: string;
  readonly details?: Readonly<Record<string, unknown>>;
}

export interface EnvelopeMeta {
  readonly protocol: number;
  readonly instance_id?: string;
  readonly scene?: string;
  readonly duration_ms?: number;
  readonly undo?: string;
}

export interface Envelope<T = unknown> {
  readonly success: boolean;
  readonly command: string;
  readonly data: T | null;
  readonly errors: readonly EnvelopeError[];
  readonly warnings: readonly string[];
  readonly meta: EnvelopeMeta;
}

export type EnvelopeMetaInput = Omit<EnvelopeMeta, "protocol">;

export function success<T>(
  command: string,
  data: T,
  meta: EnvelopeMetaInput = {},
  warnings: readonly string[] = [],
): Envelope<T> {
  return {
    success: true,
    command,
    data,
    errors: [],
    warnings: [...warnings],
    meta: { protocol: PROTOCOL_VERSION, ...meta },
  };
}

export function failure(
  command: string,
  errors: readonly EnvelopeError[],
  meta: EnvelopeMetaInput = {},
  warnings: readonly string[] = [],
): Envelope<never> {
  return {
    success: false,
    command,
    data: null,
    errors: [...errors],
    warnings: [...warnings],
    meta: { protocol: PROTOCOL_VERSION, ...meta },
  };
}

/** A failure without any error entry is malformed and reported as an internal error. */
export function exitCodeOf(envelope: Envelope): ExitCode {
  if (envelope.success) {
    return ExitCode.Success;
  }
  const first = envelope.errors[0];
  return first === undefined ? ExitCode.Internal : exitCodeFor(first.code);
}
