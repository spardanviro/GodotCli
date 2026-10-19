import type { Envelope } from "./envelope.js";
import { sanitize, visibleCodePoints } from "./text.js";

const VERBATIM_TEXT_COMMAND = "fs_read_text";

function sanitizeValue(value: unknown): unknown {
  if (typeof value === "string") {
    return sanitize(value);
  }
  if (Array.isArray(value)) {
    return value.map(sanitizeValue);
  }
  if (typeof value === "object" && value !== null) {
    return Object.fromEntries(Object.entries(value).map(([key, entry]) => [sanitize(key), sanitizeValue(entry)]));
  }
  return value;
}

/**
 * JSON escapes control characters but not the invisible or reordering ones,
 * so machine output is cleaned like terminal output. The one exception is the
 * text of a file the caller asked to read: on the command line it arrives
 * unchanged (`verbatim`), for a model (gd mcp) with such characters shown as
 * <U+XXXX>, since a model reads them and they can hide instructions.
 */
export function sanitizeEnvelope(envelope: Envelope, verbatim = true): unknown {
  const cleaned = sanitizeValue(envelope) as Record<string, unknown>;
  const data = envelope.data as { text?: unknown } | null;
  if (envelope.command === VERBATIM_TEXT_COMMAND && envelope.success && typeof data?.text === "string") {
    const text = verbatim ? data.text : visibleCodePoints(data.text);
    return { ...cleaned, data: { ...(cleaned["data"] as Record<string, unknown>), text } };
  }
  return cleaned;
}
