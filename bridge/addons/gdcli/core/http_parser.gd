extends RefCounted
## Strict parser for the narrow slice of HTTP/1.1 the bridge accepts.
## Anything outside docs/protocol.md section 3 is rejected rather than interpreted.

const MAX_REQUEST_LINE_BYTES := 2048
const MAX_HEAD_BYTES := 8192
const MAX_HEADERS := 64
const MAX_BODY_BYTES := 4 * 1024 * 1024

const STATUS_BAD_REQUEST := 400
const STATUS_TOO_LARGE := 413

const _CR := 13
const _LF := 10
const _TAB := 9
const _FIRST_PRINTABLE := 0x20
const _LAST_PRINTABLE := 0x7e

const _SINGLETON_HEADERS: Array[String] = ["host", "authorization", "content-type", "content-length"]
const _FORBIDDEN_HEADERS: Array[String] = ["transfer-encoding", "expect"]

const _REQUEST_LINE_PATTERN := "^(GET|POST) (/[A-Za-z0-9_/]*)(?:\\?([A-Za-z0-9_=&]*))? HTTP/1\\.1$"
const _HEADER_NAME_PATTERN := "^[A-Za-z0-9_-]+$"
const _CONTENT_LENGTH_PATTERN := "^[0-9]{1,9}$"

static var _request_line_regex: RegEx
static var _header_regex: RegEx
static var _content_length_regex: RegEx


## Index of the first byte after the blank line that ends the head, or -1.
static func find_head_end(buffer: PackedByteArray, from: int) -> int:
	var last_start := buffer.size() - 4
	var index := maxi(from, 0)
	while index <= last_start:
		var cr := buffer.find(_CR, index)
		if cr == -1 or cr > last_start:
			return -1
		if buffer[cr + 1] == _LF and buffer[cr + 2] == _CR and buffer[cr + 3] == _LF:
			return cr + 4
		index = cr + 1
	return -1


## Parses the bytes up to and including the blank line.
## Returns {ok = true, method, path, query, headers, content_length}
## or {ok = false, status, reason}.
static func parse_head(head: PackedByteArray) -> Dictionary:
	if head.size() > MAX_HEAD_BYTES:
		return _reject(STATUS_BAD_REQUEST, "Request head is too large.")
	if not _is_plain_ascii(head):
		return _reject(STATUS_BAD_REQUEST, "Request head contains bytes outside printable ASCII.")

	var lines := head.get_string_from_ascii().split("\r\n")
	# The head ends with CRLF CRLF, which leaves two empty strings at the end.
	if lines.size() < 3 or lines[lines.size() - 1] != "" or lines[lines.size() - 2] != "":
		return _reject(STATUS_BAD_REQUEST, "Request head is not terminated correctly.")

	# After splitting on CRLF, a leftover CR or LF is a bare line break.
	for line in lines:
		if line.contains("\r") or line.contains("\n"):
			return _reject(STATUS_BAD_REQUEST, "Bare CR or LF in the request head.")

	var request_line := lines[0]
	if request_line.length() > MAX_REQUEST_LINE_BYTES:
		return _reject(STATUS_BAD_REQUEST, "Request line is too long.")
	var request_match := _regex_request_line().search(request_line)
	if request_match == null:
		return _reject(STATUS_BAD_REQUEST, "Unsupported method, target or HTTP version.")

	var header_lines := lines.slice(1, lines.size() - 2)
	if header_lines.size() > MAX_HEADERS:
		return _reject(STATUS_BAD_REQUEST, "Too many headers.")
	var parsed_headers := _parse_headers(header_lines)
	if parsed_headers["error"] != "":
		return _reject(STATUS_BAD_REQUEST, parsed_headers["error"])
	var headers: Dictionary = parsed_headers["headers"]

	var content_length := 0
	if headers.has("content-length"):
		var raw_length: String = headers["content-length"]
		if _regex_content_length().search(raw_length) == null:
			return _reject(STATUS_BAD_REQUEST, "Content-Length must be a plain decimal number.")
		content_length = raw_length.to_int()
		if content_length > MAX_BODY_BYTES:
			return _reject(STATUS_TOO_LARGE, "Request body is too large.")
	elif request_match.get_string(1) == "POST":
		return _reject(STATUS_BAD_REQUEST, "POST requires Content-Length.")

	return {
		"ok": true,
		"method": request_match.get_string(1),
		"path": request_match.get_string(2),
		"query": _parse_query(request_match.get_string(3)),
		"headers": headers,
		"content_length": content_length,
	}


static func _parse_headers(lines: PackedStringArray) -> Dictionary:
	var headers := {}
	for line in lines:
		# Split by hand: a pattern with a lazy value followed by optional
		# blanks backtracks quadratically on a long run of spaces.
		var colon := line.find(":")
		if colon <= 0 or _regex_header().search(line.substr(0, colon)) == null:
			return {"error": "Malformed header line.", "headers": {}}
		var name := line.substr(0, colon).to_lower()
		if name in _FORBIDDEN_HEADERS:
			return {"error": "Transfer-Encoding and Expect are not supported.", "headers": {}}
		if headers.has(name):
			if name in _SINGLETON_HEADERS:
				return {"error": "A header that must appear once was repeated.", "headers": {}}
			continue
		headers[name] = line.substr(colon + 1).strip_edges()
	return {"error": "", "headers": headers}


# No percent-decoding: the only parameter in the protocol is a hex nonce.
static func _parse_query(raw: String) -> Dictionary:
	var query := {}
	for pair in raw.split("&", false):
		var separator := pair.find("=")
		if separator > 0:
			query[pair.substr(0, separator)] = pair.substr(separator + 1)
	return query


static func _is_plain_ascii(bytes: PackedByteArray) -> bool:
	for byte in bytes:
		var printable := byte >= _FIRST_PRINTABLE and byte <= _LAST_PRINTABLE
		if not printable and byte != _CR and byte != _LF and byte != _TAB:
			return false
	return true


static func _reject(status: int, reason: String) -> Dictionary:
	return {"ok": false, "status": status, "reason": reason}


static func _regex_request_line() -> RegEx:
	if _request_line_regex == null:
		_request_line_regex = RegEx.create_from_string(_REQUEST_LINE_PATTERN)
	return _request_line_regex


static func _regex_header() -> RegEx:
	if _header_regex == null:
		_header_regex = RegEx.create_from_string(_HEADER_NAME_PATTERN)
	return _header_regex


static func _regex_content_length() -> RegEx:
	if _content_length_regex == null:
		_content_length_regex = RegEx.create_from_string(_CONTENT_LENGTH_PATTERN)
	return _content_length_regex
