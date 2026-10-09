extends RefCounted
## Removes characters that can hide or reorder text when project-derived
## strings reach a terminal or an agent (docs/protocol.md section 4.5).

const MAX_LINE_LENGTH := 2000
const MAX_TEXT_LENGTH := 65536
const TRUNCATION_MARK := " ...[truncated]"

# Built from code points so that this file contains no invisible characters.
# Each pair is an inclusive range.
const _UNSAFE_RANGES: Array[int] = [
	0x00, 0x08,  # C0 controls before tab
	0x0B, 0x1F,  # C0 controls after newline
	0x7F, 0x9F,  # DEL and C1 controls
	0xAD, 0xAD,  # soft hyphen
	0x34F, 0x34F,  # combining grapheme joiner
	0x61C, 0x61C,  # Arabic letter mark
	0x180E, 0x180E,  # Mongolian vowel separator
	0x200B, 0x200F,  # zero-width characters and directional marks
	0x2028, 0x202E,  # line/paragraph separators, bidirectional embeddings and overrides
	0x2060, 0x206F,  # word joiner, invisible operators, bidirectional isolates
	0x3164, 0x3164,  # Hangul filler
	0xFE00, 0xFE0F,  # variation selectors
	0xFEFF, 0xFEFF,  # byte order mark
	0xFFF9, 0xFFFB,  # interlinear annotation controls
	0xE0000, 0xE007F,  # tag characters, usable to smuggle invisible ASCII
]

static var _unsafe_regex: RegEx


## Strips unsafe characters and caps the length.
static func clean(text: String) -> String:
	var cleaned := _regex().sub(text, "", true)
	if cleaned.length() <= MAX_TEXT_LENGTH:
		return cleaned
	return cleaned.substr(0, MAX_TEXT_LENGTH) + TRUNCATION_MARK


## For single-line values such as names, paths and log lines.
static func clean_line(text: String) -> String:
	var cleaned := _regex().sub(text, "", true).replace("\n", " ")
	if cleaned.length() <= MAX_LINE_LENGTH:
		return cleaned
	return cleaned.substr(0, MAX_LINE_LENGTH) + TRUNCATION_MARK


static func clean_lines(values: Variant) -> Array:
	var cleaned := []
	for value in values:
		cleaned.append(clean_line(str(value)))
	return cleaned


static func _regex() -> RegEx:
	if _unsafe_regex == null:
		var pattern := "["
		for index in range(0, _UNSAFE_RANGES.size(), 2):
			pattern += "\\x{%X}-\\x{%X}" % [_UNSAFE_RANGES[index], _UNSAFE_RANGES[index + 1]]
		_unsafe_regex = RegEx.create_from_string(pattern + "]")
	return _unsafe_regex
