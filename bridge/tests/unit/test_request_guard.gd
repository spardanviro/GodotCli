extends "res://tests/suite.gd"

const RequestGuard = preload("res://addons/gdcli/core/request_guard.gd")

const PORT := 51234
const TOKEN := "correct-token"


func _head(method: String, path: String, headers: Dictionary) -> Dictionary:
	return {"method": method, "path": path, "headers": headers, "query": {}, "content_length": 0}


func _check(method: String, path: String, headers: Dictionary) -> Dictionary:
	return RequestGuard.check(_head(method, path, headers), PORT, TOKEN.sha256_text())


func _good_headers() -> Dictionary:
	return {"host": "127.0.0.1:%d" % PORT, "authorization": "Bearer " + TOKEN, "content-type": "application/json"}


func test_accepts_a_well_formed_request() -> void:
	equal(_check("POST", "/v1/commands/scene_tree", _good_headers()), {}, "valid request")


func test_accepts_localhost_as_host() -> void:
	var headers := _good_headers()
	headers["host"] = "localhost:%d" % PORT

	equal(_check("GET", "/v1/commands", headers), {}, "localhost")


func test_rejects_browser_requests() -> void:
	for marker in ["origin", "sec-fetch-site"]:
		var headers := _good_headers()
		headers[marker] = "https://example.com"
		var denied := _check("GET", "/v1/commands", headers)
		equal(denied.get("status"), 403, marker)
		equal(denied["error"]["code"], "FORBIDDEN_ORIGIN", marker)


func test_rejects_a_foreign_host_header() -> void:
	for host in ["evil.example:%d" % PORT, "127.0.0.1", "127.0.0.1:%d" % (PORT + 1), ""]:
		var headers := _good_headers()
		headers["host"] = host
		equal(_check("GET", "/v1/commands", headers).get("status"), 403, "host '%s'" % host)


func test_rejects_a_missing_or_wrong_token() -> void:
	for authorization in ["", "Bearer wrong", "Basic " + TOKEN, TOKEN, "bearer " + TOKEN]:
		var headers := _good_headers()
		headers["authorization"] = authorization
		var denied := _check("GET", "/v1/commands", headers)
		equal(denied.get("status"), 401, "authorization '%s'" % authorization)
		equal(denied["error"]["code"], "AUTH_FAILED", "code")


func test_lets_ping_through_without_a_token() -> void:
	equal(_check("GET", "/v1/ping", {"host": "127.0.0.1:%d" % PORT}), {}, "ping")


func test_request_guard_ping_exemption_covers_get_only() -> void:
	var headers := {"host": "127.0.0.1:%d" % PORT, "content-type": "application/json"}

	equal(_check("POST", "/v1/ping", headers).get("status"), 401, "POST to the ping path needs the token")


func test_still_checks_origin_and_host_on_ping() -> void:
	equal(_check("GET", "/v1/ping", {"host": "127.0.0.1:%d" % PORT, "origin": "null"}).get("status"), 403, "origin")
	equal(_check("GET", "/v1/ping", {"host": "attacker.example"}).get("status"), 403, "host")


func test_requires_json_content_type_on_post() -> void:
	var headers := _good_headers()
	headers["content-type"] = "text/plain"
	equal(_check("POST", "/v1/commands/x", headers).get("status"), 415, "text/plain")

	headers["content-type"] = "application/jsonx"
	equal(_check("POST", "/v1/commands/x", headers).get("status"), 415, "look-alike type")

	headers["content-type"] = "Application/JSON; charset=utf-8"
	equal(_check("POST", "/v1/commands/x", headers), {}, "charset parameter")
