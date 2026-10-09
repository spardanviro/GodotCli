extends RefCounted
## The per-request checks of docs/protocol.md section 4.2. They run on the
## parsed head, before any of the body is read.

const Reply = preload("reply.gd")

const PING_PATH := "/v1/ping"
const _BEARER_PREFIX := "Bearer "
const _JSON_TYPE := "application/json"
const STATUS_UNSUPPORTED_MEDIA := 415


## Returns {} when the request may proceed, otherwise {status, error}.
static func check(head: Dictionary, port: int, token_digest: String) -> Dictionary:
	var headers: Dictionary = head["headers"]

	# gd never sends these; a browser always sends at least one of them.
	if headers.has("origin") or headers.has("sec-fetch-site"):
		return _deny(403, "FORBIDDEN_ORIGIN", "Requests from browsers are not accepted.")

	var host: String = headers.get("host", "")
	if host != "127.0.0.1:%d" % port and host != "localhost:%d" % port:
		return _deny(403, "FORBIDDEN_ORIGIN", "The Host header does not name this bridge.")

	var is_ping: bool = head["method"] == "GET" and head["path"] == PING_PATH
	if not is_ping and not _has_valid_token(headers, token_digest):
		return _deny(401, "AUTH_FAILED", "Missing or wrong bearer token.")

	if head["method"] == "POST":
		var content_type: String = headers.get("content-type", "").to_lower()
		if content_type != _JSON_TYPE and not content_type.begins_with(_JSON_TYPE + ";"):
			return _deny(STATUS_UNSUPPORTED_MEDIA, "INVALID_ARGS", "Content-Type must be application/json.")

	return {}


# Digests are compared instead of the tokens so that the comparison time
# does not depend on how many leading characters of a guess are right.
static func _has_valid_token(headers: Dictionary, token_digest: String) -> bool:
	var authorization: String = headers.get("authorization", "")
	if not authorization.begins_with(_BEARER_PREFIX):
		return false
	return authorization.substr(_BEARER_PREFIX.length()).sha256_text() == token_digest


static func _deny(status: int, code: String, message: String) -> Dictionary:
	return {"status": status, "error": Reply.fail(code, message)["error"]}
