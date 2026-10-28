// Characters that can hide, recolour or reorder what a terminal shows.
// Same set as the bridge's text_sanitizer.gd; tab and newline are kept.
export const UNSAFE_RANGES: readonly (readonly [number, number])[] = [
  [0x00, 0x08],
  [0x0b, 0x1f],
  [0x7f, 0x9f],
  [0xad, 0xad],
  [0x34f, 0x34f],
  [0x61c, 0x61c],
  [0x115f, 0x1160],
  [0x17b4, 0x17b5],
  [0x180b, 0x180f],
  [0x200b, 0x200f],
  [0x2028, 0x202e],
  [0x2060, 0x206f],
  [0x2800, 0x2800],
  [0x3164, 0x3164],
  [0xfe00, 0xfe0f],
  [0xfeff, 0xfeff],
  [0xffa0, 0xffa0],
  [0xfff9, 0xfffb],
  [0xe0000, 0xe007f],
  [0xe0100, 0xe01ef],
];

const UNSAFE_PATTERN = new RegExp(
  `[${UNSAFE_RANGES.map(([first, last]) => `\\u{${first.toString(16)}}-\\u{${last.toString(16)}}`).join("")}]`,
  "gu",
);

// CSI and OSC escape sequences as a whole, so their printable tails go too.
// The OSC body stops at a line break: an unterminated sequence must not
// swallow the error lines that follow it.
const ANSI_PATTERN = /\u001b\[[0-9;?]*[ -/]*[@-~]|\u001b\][^\u0007\u001b\r\n]*(?:\u0007|\u001b\\)?/gu;

const CARRIAGE_RETURN = String.fromCodePoint(0x0d);

/**
 * Shows each hiding or reordering character as its code point (<U+200B>), so
 * a reader sees that it is there instead of being steered by it.
 */
export function visibleCodePoints(text: string): string {
  // A carriage return is only a line ending in a file read whole.
  return text.replace(UNSAFE_PATTERN, (character) => character === CARRIAGE_RETURN ? character : `<U+${(character.codePointAt(0) ?? 0).toString(16).toUpperCase().padStart(4, "0")}>`);
}

/** Makes text from a project or a child process safe to print. */
export function sanitize(text: string): string {
  return text.replace(ANSI_PATTERN, "").replace(UNSAFE_PATTERN, "");
}

export function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
