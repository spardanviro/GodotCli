extends "res://tests/suite.gd"

const AccessPolicy = preload("res://addons/gdcli/core/access_policy.gd")
const Bridge = preload("res://addons/gdcli/core/bridge.gd")
const Registry = preload("res://addons/gdcli/core/registry.gd")
const Reply = preload("res://addons/gdcli/core/reply.gd")
const FakeContext = preload("res://tests/fake_context.gd")

const TOKEN := "0123456789abcdef"
const INSTANCE_ID := "9f2c41d07a5be813"
const NONCE := "000102030405060708090a0b0c0d0e0f"

var _context: RefCounted
var _calls := 0
var _scene: Node


func cleanup() -> void:
	if _scene != null:
		_scene.free()
		_scene = null


func _bridge() -> RefCounted:
	_context = FakeContext.new()
	_calls = 0
	var registry := Registry.new()
	registry.register({
		"name": "probe_read", "summary": "", "risk": AccessPolicy.RISK_READ,
		"params": {"type": "object", "properties": {"text": {"type": "string", "default": "hi"}}},
	}, func(args: Dictionary) -> Dictionary:
		_calls += 1
		return Reply.ok({"echo": args["text"]}, ["a warning"]))
	registry.register({"name": "probe_write", "summary": "", "risk": AccessPolicy.RISK_WRITE}, _count_call)
	registry.register({"name": "probe_delete", "summary": "", "risk": AccessPolicy.RISK_DESTRUCTIVE}, _count_call)
	registry.register({
		"name": "probe_scene", "summary": "", "risk": AccessPolicy.RISK_READ, "requires": ["scene_open"],
	}, _count_call)
	registry.register({"name": "probe_broken", "summary": "", "risk": AccessPolicy.RISK_READ},
		func(_args: Dictionary) -> Variant: return null)
	var identity := {"instance_id": INSTANCE_ID, "protocol": 1, "bridge_version": "0.0.1"}
	return Bridge.new(registry, _context, identity, TOKEN)


func _count_call(_args: Dictionary) -> Dictionary:
	_calls += 1
	return Reply.ok({})


func _http_get(bridge: RefCounted, path: String, query: Dictionary = {}) -> Dictionary:
	var response: Dictionary = bridge.handle({"method": "GET", "path": path, "query": query, "headers": {}}, PackedByteArray())
	return {"status": response["status"], "envelope": JSON.parse_string(response["body"].get_string_from_utf8())}


func _http_post(bridge: RefCounted, command: String, body: String = "") -> Dictionary:
	var head := {"method": "POST", "path": "/v1/commands/" + command, "query": {}, "headers": {}}
	var response: Dictionary = bridge.handle(head, body.to_utf8_buffer())
	return {"status": response["status"], "envelope": JSON.parse_string(response["body"].get_string_from_utf8())}


func test_bridge_ping_returns_a_proof_bound_to_the_token_and_nonce() -> void:
	var bridge := _bridge()
	var expected := Crypto.new().hmac_digest(
		HashingContext.HASH_SHA256, TOKEN.to_utf8_buffer(), (NONCE + INSTANCE_ID).to_utf8_buffer()
	).hex_encode()

	var result := _http_get(bridge, "/v1/ping", {"nonce": NONCE})

	equal(result["status"], 200, "status")
	equal(result["envelope"]["data"]["proof"], expected, "proof")
	equal(result["envelope"]["data"]["instance_id"], INSTANCE_ID, "instance id")
	check(not JSON.stringify(result["envelope"]).contains(TOKEN), "the token itself is never returned")


func test_bridge_ping_rejects_a_malformed_nonce() -> void:
	var bridge := _bridge()

	for nonce in ["", "abc", NONCE.to_upper(), NONCE + "00", "zz0102030405060708090a0b0c0d0e0f"]:
		equal(_http_get(bridge, "/v1/ping", {"nonce": nonce})["status"], 400, "nonce '%s'" % nonce)


func test_bridge_commands_endpoint_lists_descriptors_sorted_with_defaults() -> void:
	var result := _http_get(_bridge(), "/v1/commands")

	var commands: Array = result["envelope"]["data"]["commands"]
	equal(commands[0]["name"], "probe_broken", "sorted by name")
	equal(commands[0]["group"], "probe", "group defaults to the name prefix")
	equal(commands[0]["undoable"], false, "undoable default")
	equal(commands[0]["requires"], [], "requires default")


func test_bridge_command_success_fills_the_envelope() -> void:
	var bridge := _bridge()
	_context.path = "res://main.tscn"

	var result := _http_post(bridge, "probe_read", '{"args": {"text": "yo"}}')

	var envelope: Dictionary = result["envelope"]
	equal(result["status"], 200, "status")
	equal(envelope["success"], true, "success")
	equal(envelope["command"], "probe_read", "command")
	equal(envelope["data"], {"echo": "yo"}, "data")
	equal(envelope["warnings"], ["a warning"], "warnings")
	equal(envelope["meta"]["scene"], "res://main.tscn", "scene is echoed")
	equal(envelope["meta"]["instance_id"], INSTANCE_ID, "instance id")
	check(envelope["meta"].has("duration_ms"), "duration is reported")


func test_bridge_empty_body_means_default_arguments() -> void:
	equal(_http_post(_bridge(), "probe_read")["envelope"]["data"], {"echo": "hi"}, "defaults")


func test_bridge_unknown_command_is_a_404() -> void:
	var result := _http_post(_bridge(), "no_such_command")

	equal(result["status"], 404, "status")
	equal(result["envelope"]["errors"][0]["code"], "UNKNOWN_COMMAND", "code")
	equal(result["envelope"]["data"], null, "data is null on failure")


func test_bridge_malformed_bodies_are_invalid_args() -> void:
	var bridge := _bridge()

	for body in ["not json", "[1]", '{"args": []}', '{"confirm": "yes"}', '{"args": {}, "surprise": 1}', '{"args": {"text": 5}}']:
		var result := _http_post(bridge, "probe_read", body)
		equal(result["status"], 400, body)
		equal(result["envelope"]["errors"][0]["code"], "INVALID_ARGS", body)
	equal(_calls, 0, "the handler never ran")


func test_bridge_readonly_mode_blocks_writes_before_the_handler_runs() -> void:
	var bridge := _bridge()
	_context.mode = "readonly"

	var result := _http_post(bridge, "probe_write")

	equal(result["status"], 409, "status")
	equal(result["envelope"]["errors"][0]["code"], "READONLY_MODE", "code")
	equal(_calls, 0, "handler calls")


func test_bridge_destructive_command_runs_only_when_confirmed() -> void:
	var bridge := _bridge()

	equal(_http_post(bridge, "probe_delete")["envelope"]["errors"][0]["code"], "CONFIRMATION_REQUIRED", "unconfirmed")
	equal(_calls, 0, "not run yet")
	equal(_http_post(bridge, "probe_delete", '{"confirm": true}')["envelope"]["success"], true, "confirmed")
	equal(_calls, 1, "ran once")


func test_bridge_scene_requirement_is_checked() -> void:
	var bridge := _bridge()

	equal(_http_post(bridge, "probe_scene")["envelope"]["errors"][0]["code"], "PRECONDITION_FAILED", "no scene")
	_scene = Node.new()
	_context.root = _scene
	equal(_http_post(bridge, "probe_scene")["envelope"]["success"], true, "scene open")


func test_bridge_handler_without_a_reply_is_an_internal_error() -> void:
	var result := _http_post(_bridge(), "probe_broken")

	equal(result["status"], 500, "status")
	equal(result["envelope"]["errors"][0]["code"], "INTERNAL_ERROR", "code")


func test_bridge_check_head_wraps_guard_failures_in_an_envelope() -> void:
	var bridge := _bridge()
	bridge.set_port(4000)
	var head := {"method": "GET", "path": "/v1/commands", "query": {}, "headers": {"host": "127.0.0.1:4000"}}

	var denied: Dictionary = bridge.check_head(head)

	equal(denied["status"], 401, "status")
	equal(JSON.parse_string(denied["body"].get_string_from_utf8())["errors"][0]["code"], "AUTH_FAILED", "code")
	head["headers"]["authorization"] = "Bearer " + TOKEN
	equal(bridge.check_head(head), {}, "with the token")
