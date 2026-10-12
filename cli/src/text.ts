// Characters that can hide, recolour or reorder what a terminal shows.
// Same set as the bridge's text_sanitizer.gd; tab and newline are kept.
const UNSAFE_RANGES: readonly (readonly [number, number])[] = [
  [0x00, 0x08],
  [0x0b, 0x1f],
  [0x7f, 0x9f],
  [0xad, 0xad],
  [0x34f, 0x34f],
  [0x61c, 0x61c],
  [0x180e, 0x180e],
  [0x200b, 0x200f],
  [0x2028, 0x202e],
  [0x2060, 0x206f],
  [0x3164, 0x3164],
  [0xfe00, 0xfe0f],
  [0xfeff, 0xfeff],
  [0xfff9, 0xfffb],
  [0xe0000, 0xe007f],
];

const UNSAFE_PATTERN = new RegExp(
  `[${UNSAFE_RANGES.map(([first, last]) => `\\u{${first.toString(16)}}-\\u{${last.toString(16)}}`).join("")}]`,
  "gu",
);

// CSI and OSC escape sequences as a whole, so their printable tails go too.
// The OSC body stops at a line break: an unterminated sequence must not
// swallow the error lines that follow it.
const ANSI_PATTERN = /\u001b\[[0-9;?]*[ -/]*[@-~]|\u001b\][^\u0007\u001b\r\n]*(?:\u0007|\u001b\\)?/gu;

/** Makes text from a project or a child process safe to print. */
export function sanitize(text: string): string {
  return text.replace(ANSI_PATTERN, "").replace(UNSAFE_PATTERN, "");
}

export function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
