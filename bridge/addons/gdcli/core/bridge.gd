extends RefCounted
## Turns a parsed HTTP request into a response. Knows nothing about sockets,
## so it can be exercised without an editor.

const AccessPolicy = preload("access_policy.gd")
const Approval = preload("approval.gd")
const Envelope = preload("envelope.gd")
const Reply = preload("reply.gd")
const RequestGuard = preload("request_guard.gd")
const Schema = preload("schema.gd")
const TextSanitizer = preload("text_sanitizer.gd")

const COMMANDS_PATH := "/v1/commands"
const COMMAND_PREFIX := "/v1/commands/"
const NONCE_PATTERN := "^[0-9a-f]{32}$"
const _PAYLOAD_KEYS: Array[String] = ["args", "dry_run", "confirm"]

var _registry: RefCounted
var _context: RefCounted
var _identity: Dictionary
var _token: String
var _token_digest: String
var _port := 0
var _startup_warnings: Array = []
var _last_command_msec := Time.get_ticks_msec()
var _nonce_regex := RegEx.create_from_string(NONCE_PATTERN)
# Multi-frame changes in progress (see Reply.later).
var _exclusive_running := 0


## `identity` holds instance_id, protocol and bridge_version.
## `context` answers questions about the editor; see editor_context.gd.
func _init(registry: RefCounted, context: RefCounted, identity: Dictionary, token: String) -> void:
	_registry = registry
	_context = context
	_identity = identity.duplicate()
	_token = token
	_token_digest = token.sha256_text()


func set_port(port: int) -> void:
	_port = port


func set_startup_warnings(warnings: Array) -> void:
	_startup_warnings = warnings.duplicate()


## Called once the request head is complete. {} lets the request continue.
func check_head(head: Dictionary) -> Dictionary:
	var denied := RequestGuard.check(head, _port, _token_digest)
	if not denied.is_empty():
		return _respond(denied["status"], Envelope.failure("", denied["error"], _meta()))
	# Unknown routes are answered here so that no body is read for them.
	if not _is_known_route(head["method"], head["path"]):
		return _not_found()
	return {}


## For requests the HTTP layer could not parse.
func transport_error(status: int, reason: String) -> Dictionary:
	var error: Dictionary = Reply.fail("INVALID_ARGS", reason)["error"]
	return _respond(status, Envelope.failure("", error, _meta()))


func handle(head: Dictionary, body: PackedByteArray) -> Dictionary:
	var path: String = head["path"]
	var method: String = head["method"]
	if path == RequestGuard.PING_PATH and method == "GET":
		return _ping(head["query"])
	if path == COMMANDS_PATH and method == "GET":
		return _respond(200, Envelope.success("commands", {"commands": _registry.descriptors()}, _meta()))
	if path.begins_with(COMMAND_PREFIX) and method == "POST":
		return _run_command(path.substr(COMMAND_PREFIX.length()), body)
	return _not_found()


func _is_known_route(method: String, path: String) -> bool:
	if method == "GET":
		return path == RequestGuard.PING_PATH or path == COMMANDS_PATH
	return path.begins_with(COMMAND_PREFIX) and path.length() > COMMAND_PREFIX.length()


func _not_found() -> Dictionary:
	var error: Dictionary = Reply.fail("UNKNOWN_COMMAND", "No such endpoint.")["error"]
	return _respond(404, Envelope.failure("", error, _meta()))


# Proves possession of the token without the client having sent it.
func _ping(query: Dictionary) -> Dictionary:
	var nonce: String = query.get("nonce", "")
	if _nonce_regex.search(nonce) == null:
		var error: Dictionary = Reply.fail("INVALID_ARGS", "nonce must be 32 lower-case hex digits.")["error"]
		return _respond(400, Envelope.failure("ping", error, _meta()))
	var message := (nonce + str(_identity["instance_id"])).to_utf8_buffer()
	var proof := Crypto.new().hmac_digest(HashingContext.HASH_SHA256, _token.to_utf8_buffer(), message)
	var data := _identity.duplicate()
	data["proof"] = proof.hex_encode()
	return _respond(200, Envelope.success("ping", data, _meta(), _startup_warnings))


## Milliseconds since the last command, for hosts that exit when idle.
func idle_msec() -> int:
	return Time.get_ticks_msec() - _last_command_msec


func _run_command(name: String, body: PackedByteArray) -> Dictionary:
	var started := Time.get_ticks_msec()
	_last_command_msec = started
	var reply := _execute(name, body)
	if reply["ok"] and reply.has("later"):
		# The answer is not known yet; the HTTP layer asks again every frame.
		var exclusive: bool = reply.get("exclusive", false)
		if exclusive:
			_exclusive_running += 1
		return {
			"pending": _poll_later.bind(name, reply["later"], started, exclusive),
			"abandon": _abandon.bind(reply["later"]),
		}
	return _finish(name, reply, started)


# {} while the answer is still awaited, then the response.
func _poll_later(name: String, waiter: RefCounted, started: int, exclusive: bool) -> Dictionary:
	var reply: Variant = waiter.poll()
	if reply is Dictionary and reply.is_empty():
		return {}
	if exclusive:
		_exclusive_running -= 1
	if not (reply is Dictionary and reply.has("ok")):
		reply = Reply.fail("INTERNAL_ERROR", "The command did not return a reply.")
	return _finish(name, reply, started)


# The caller hung up or gave up waiting.
func _abandon(waiter: RefCounted) -> void:
	if waiter.has_method("abandon"):
		waiter.abandon()


func _finish(name: String, reply: Dictionary, started: int) -> Dictionary:
	var meta := _meta()
	meta["duration_ms"] = Time.get_ticks_msec() - started
	var scene: String = _context.scene_path()
	if scene != "":
		meta["scene"] = TextSanitizer.clean_line(scene)

	if reply["ok"]:
		if reply.has("undo"):
			meta["undo"] = TextSanitizer.clean_line(str(reply["undo"]))
		return _respond(200, Envelope.success(name, reply["data"], meta, reply.get("warnings", [])))
	var error: Dictionary = reply["error"]
	return _respond(Envelope.http_status_for(error["code"]), Envelope.failure(name, error, meta))


func _execute(name: String, body: PackedByteArray) -> Dictionary:
	if not _registry.has(name):
		return Reply.fail("UNKNOWN_COMMAND", "No such command.", "GET /v1/commands lists the commands.")
	var payload := _parse_payload(body)
	if not payload["ok"]:
		return payload

	var descriptor: Dictionary = _registry.descriptor_of(name)
	var denied := AccessPolicy.decide(
		descriptor["risk"], _context.access_mode(), _context.allow_eval(), payload["confirm"], payload["dry_run"]
	)
	if not denied.is_empty():
		return denied
	if _exclusive_running > 0 and descriptor["risk"] != AccessPolicy.RISK_READ and not payload["dry_run"]:
		return Reply.fail("EDITOR_BUSY", "The editor is in the middle of a change that takes several frames.", "Retry in a moment.")
	var unmet := _unmet_requirement(descriptor["requires"])
	if not unmet.is_empty():
		return unmet
	var validated := Schema.validate(payload["args"], descriptor["params"])
	if not validated["ok"]:
		return validated

	# Read commands take only their arguments; commands that change something
	# also get the request options, so they can plan (dry_run) or insist on a
	# confirmation for sensitive targets.
	var handler: Callable = _registry.handler_of(name)
	var reply: Variant
	if descriptor["risk"] == AccessPolicy.RISK_READ:
		reply = handler.call(validated["args"])
	else:
		var options := {"dry_run": payload["dry_run"], "confirm": payload["confirm"], "mode": _context.access_mode()}
		if AccessPolicy.asks_person(descriptor["risk"], options["mode"], options["dry_run"]):
			return _ask_first(name, descriptor, handler, validated["args"], options)
		reply = handler.call(validated["args"], options)
	if not (reply is Dictionary and reply.has("ok")):
		return Reply.fail("INTERNAL_ERROR", "The command did not return a reply.")
	return reply


# Ask mode: the command is first run dry, so that a request that would fail is
# answered without bothering anyone, and so that the person is shown what
# would change and not only the arguments.
func _ask_first(name: String, descriptor: Dictionary, handler: Callable, args: Dictionary, options: Dictionary) -> Dictionary:
	var shown := {"arguments": args}
	# A project's own command may not honour dry_run, so it is not tried.
	if not descriptor.get("custom", false):
		var rehearsal := options.duplicate()
		rehearsal["dry_run"] = true
		var planned: Variant = handler.call(args, rehearsal)
		if not (planned is Dictionary and planned.has("ok")):
			return Reply.fail("INTERNAL_ERROR", "The command did not return a reply.")
		if not planned["ok"]:
			return planned
		shown["would"] = planned.get("data")
	var what := {
		"command": name,
		"reason": "ask mode: this command deletes, overwrites or runs code",
		"preview": JSON.stringify(shown, "  "),
	}
	var allowed := options.duplicate()
	allowed["approved"] = true
	return Reply.later(Approval.new(_context, what, handler.bind(args, allowed)), true)


func _parse_payload(body: PackedByteArray) -> Dictionary:
	if body.is_empty():
		return {"ok": true, "args": {}, "dry_run": false, "confirm": false}
	var parser := JSON.new()
	if parser.parse(body.get_string_from_utf8()) != OK or not parser.data is Dictionary:
		return Reply.fail("INVALID_ARGS", "The request body must be a JSON object.")
	var payload: Dictionary = parser.data
	for key in payload:
		if key not in _PAYLOAD_KEYS:
			return Reply.fail("INVALID_ARGS", "Unknown field in the request body.", "", {"field": str(key)})
	var args: Variant = payload.get("args", {})
	var dry_run: Variant = payload.get("dry_run", false)
	var confirm: Variant = payload.get("confirm", false)
	if not args is Dictionary or not dry_run is bool or not confirm is bool:
		return Reply.fail("INVALID_ARGS", "args must be an object; dry_run and confirm must be booleans.")
	return {"ok": true, "args": args, "dry_run": dry_run, "confirm": confirm}


func _unmet_requirement(requirements: Array) -> Dictionary:
	for requirement in requirements:
		match requirement:
			"scene_open":
				if _context.scene_root() == null:
					return Reply.fail("PRECONDITION_FAILED", "No scene is open in the editor.", "Open a scene first.")
			"not_playing":
				if _context.is_playing():
					return Reply.fail("PRECONDITION_FAILED", "The project is running.", "Stop it first.")
			"playing":
				if not _context.is_playing():
					return Reply.fail("PRECONDITION_FAILED", "The project is not running.")
	return {}


func _meta() -> Dictionary:
	return {"protocol": _identity["protocol"], "instance_id": _identity["instance_id"]}


func _respond(status: int, envelope: Dictionary) -> Dictionary:
	return {"status": status, "body": JSON.stringify(envelope).to_utf8_buffer()}
