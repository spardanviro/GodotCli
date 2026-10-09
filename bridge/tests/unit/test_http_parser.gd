extends "res://tests/suite.gd"

const HttpParser = preload("res://addons/gdcli/core/http_parser.gd")


func _head(text: String) -> Dictionary:
	return HttpParser.parse_head(text.to_ascii_buffer())


func test_parses_a_get_with_query() -> void:
	var head := _head("GET /v1/ping?nonce=00ff HTTP/1.1\r\nHost: 127.0.0.1:5000\r\n\r\n")

	check(head["ok"], "the request should parse")
	equal(head["method"], "GET", "method")
	equal(head["path"], "/v1/ping", "path")
	equal(head["query"], {"nonce": "00ff"}, "query")
	equal(head["headers"]["host"], "127.0.0.1:5000", "header names are lower-cased")
	equal(head["content_length"], 0, "content length")


func test_parses_a_post_with_content_length() -> void:
	var head := _head("POST /v1/commands/scene_tree HTTP/1.1\r\nContent-Length: 12\r\nContent-Type:  application/json \r\n\r\n")

	check(head["ok"], "the request should parse")
	equal(head["content_length"], 12, "content length")
	equal(head["headers"]["content-type"], "application/json", "header values are trimmed")


func test_rejects_other_methods_versions_and_targets() -> void:
	for request_line in [
		"PUT /v1/ping HTTP/1.1", "OPTIONS /v1/ping HTTP/1.1", "GET /v1/ping HTTP/1.0",
		"GET http://127.0.0.1/v1/ping HTTP/1.1", "GET /v1/%70ing HTTP/1.1", "GET /v1/../x HTTP/1.1",
		"GET  /v1/ping HTTP/1.1",
	]:
		var head := _head(request_line + "\r\n\r\n")
		equal(head["ok"], false, request_line)
		equal(head.get("status"), 400, request_line)


func test_rejects_transfer_encoding_and_expect() -> void:
	equal(_head("POST /v1/commands/x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")["ok"], false, "chunked")
	equal(_head("POST /v1/commands/x HTTP/1.1\r\nContent-Length: 1\r\nExpect: 100-continue\r\n\r\n")["ok"], false, "expect")


func test_rejects_repeated_critical_headers() -> void:
	for name in ["Host", "Authorization", "Content-Type", "Content-Length"]:
		var head := _head("GET /v1/ping HTTP/1.1\r\n%s: 1\r\n%s: 1\r\n\r\n" % [name, name.to_upper()])
		equal(head["ok"], false, name)


func test_requires_a_plain_decimal_content_length_on_post() -> void:
	equal(_head("POST /v1/commands/x HTTP/1.1\r\n\r\n")["ok"], false, "missing")
	for value in ["+1", "1e3", "0x10", "1 2", "-1", ""]:
		var head := _head("POST /v1/commands/x HTTP/1.1\r\nContent-Length: %s\r\n\r\n" % value)
		equal(head["ok"], false, "Content-Length '%s'" % value)


func test_rejects_an_oversized_body_with_413() -> void:
	var head := _head("POST /v1/commands/x HTTP/1.1\r\nContent-Length: %d\r\n\r\n" % (HttpParser.MAX_BODY_BYTES + 1))

	equal(head["ok"], false, "ok")
	equal(head["status"], 413, "status")


func test_rejects_folded_and_malformed_header_lines() -> void:
	equal(_head("GET /v1/ping HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n")["ok"], false, "obsolete line folding")
	equal(_head("GET /v1/ping HTTP/1.1\r\nno colon here\r\n\r\n")["ok"], false, "no colon")


func test_rejects_bytes_outside_printable_ascii() -> void:
	var bytes := "GET /v1/ping HTTP/1.1\r\nX-A: b\r\n\r\n".to_ascii_buffer()
	bytes[25] = 0xC3

	equal(HttpParser.parse_head(bytes)["ok"], false, "high byte")


func test_rejects_too_many_headers() -> void:
	var text := "GET /v1/ping HTTP/1.1\r\n"
	for index in HttpParser.MAX_HEADERS + 1:
		text += "X-%d: 1\r\n" % index

	equal(_head(text + "\r\n")["ok"], false, "header count")


func test_finds_the_end_of_the_head() -> void:
	var bytes := "GET / HTTP/1.1\r\nA: b\r\n\r\nBODY".to_ascii_buffer()

	equal(HttpParser.find_head_end(bytes, 0), bytes.size() - 4, "index after the blank line")
	equal(HttpParser.find_head_end("GET / HTTP/1.1\r\nA: b\r\n".to_ascii_buffer(), 0), -1, "incomplete head")
	equal(HttpParser.find_head_end(PackedByteArray(), 0), -1, "empty buffer")
