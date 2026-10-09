extends RefCounted
## Loopback-only HTTP server polled from the editor's main thread. One request
## per connection, nothing blocks, and the body is read only after the head
## has passed the handler's checks (docs/protocol.md section 3).

const HttpParser = preload("http_parser.gd")

const LOOPBACK := "127.0.0.1"
const MAX_CONNECTIONS := 8
const HEAD_DEADLINE_MS := 1000
const REQUEST_DEADLINE_MS := 5000
const WRITE_DEADLINE_MS := 10000
# After answering a request whose body was never read, keep discarding input
# for a moment: closing with unread data makes TCP reset the connection and
# the client may lose the response.
const DRAIN_MS := 250
const IO_CHUNK_BYTES := 65536
# An unfocused editor polls only about ten times a second, so each poll moves
# as much data as it can within this budget rather than one chunk.
const IO_BUDGET_MS := 4
const FALLBACK_PORT_FIRST := 49152
const FALLBACK_PORT_LAST := 65535
const FALLBACK_ATTEMPTS := 32

enum State { READ_HEAD, READ_BODY, WRITE, DRAIN }

const _REASONS := {
	200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
	409: "Conflict", 413: "Content Too Large", 415: "Unsupported Media Type",
	422: "Unprocessable Content", 500: "Internal Server Error", 503: "Service Unavailable",
}
const _FALLBACK_STATUS := 500
const _FALLBACK_ERROR := {"code": "INTERNAL_ERROR", "message": "The bridge failed to handle the request."}

var _server := TCPServer.new()
var _connections: Array = []
var _handler: RefCounted


## `handler` provides check_head(head), handle(head, body) and
## transport_error(status, reason); each returns {status, body}.
## Returns the port, or 0 when no port could be opened.
func start(handler: RefCounted) -> int:
	_handler = handler
	if _server.listen(0, LOOPBACK) == OK and _server.get_local_port() > 0:
		return _server.get_local_port()
	_server.stop()
	for attempt in FALLBACK_ATTEMPTS:
		var port := randi_range(FALLBACK_PORT_FIRST, FALLBACK_PORT_LAST)
		if _server.listen(port, LOOPBACK) == OK:
			return port
	return 0


func stop() -> void:
	for connection in _connections:
		connection["peer"].disconnect_from_host()
	_connections = []
	_server.stop()


func poll() -> void:
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if _connections.size() >= MAX_CONNECTIONS and not _evict_idle_connection():
			peer.disconnect_from_host()
			continue
		peer.set_no_delay(true)
		_connections.append({
			"peer": peer,
			"buffer": PackedByteArray(),
			"opened": Time.get_ticks_msec(),
			"state": State.READ_HEAD,
			"scan_from": 0,
			"early": false,
		})

	var open := []
	for connection in _connections:
		if _step(connection):
			open.append(connection)
		else:
			connection["peer"].disconnect_from_host()
	_connections = open


# Makes room by dropping the oldest connection that has not sent a complete
# head yet, so idle sockets cannot keep real requests out.
func _evict_idle_connection() -> bool:
	for index in _connections.size():
		if _connections[index]["state"] == State.READ_HEAD:
			_connections[index]["peer"].disconnect_from_host()
			_connections.remove_at(index)
			return true
	return false


# Returns false when the connection is finished and should be closed.
func _step(connection: Dictionary) -> bool:
	var peer: StreamPeerTCP = connection["peer"]
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return false
	var now := Time.get_ticks_msec()
	var elapsed := now - int(connection["opened"])

	if connection["state"] == State.READ_HEAD:
		if elapsed > HEAD_DEADLINE_MS or not _read(connection, HttpParser.MAX_HEAD_BYTES + 1):
			return false
		_advance_head(connection)
	if connection["state"] == State.READ_BODY:
		var head: Dictionary = connection["head"]
		var body_end: int = connection["body_start"] + head["content_length"]
		if elapsed > REQUEST_DEADLINE_MS or not _read(connection, body_end):
			return false
		var buffer: PackedByteArray = connection["buffer"]
		if buffer.size() >= body_end:
			# Leave the reading state first: if the handler fails, the request
			# must not be handled a second time on the next poll.
			connection["state"] = State.WRITE
			_begin_response(connection, _handler.handle(head, buffer.slice(connection["body_start"], body_end)))
	if connection["state"] == State.WRITE:
		if now - int(connection["write_started"]) > WRITE_DEADLINE_MS or not _write(connection):
			return false
	if connection["state"] == State.DRAIN:
		return _drain(connection, now)
	return true


func _advance_head(connection: Dictionary) -> void:
	var buffer: PackedByteArray = connection["buffer"]
	var head_end := HttpParser.find_head_end(buffer, connection["scan_from"])
	if head_end == -1:
		if buffer.size() > HttpParser.MAX_HEAD_BYTES:
			_begin_early_response(connection, _handler.transport_error(400, "Request head is too large."))
		else:
			connection["scan_from"] = maxi(buffer.size() - 3, 0)
		return

	connection["state"] = State.WRITE
	var head := HttpParser.parse_head(buffer.slice(0, head_end))
	if not head["ok"]:
		_begin_early_response(connection, _handler.transport_error(head["status"], head["reason"]))
		return
	var denied: Variant = _handler.check_head(head)
	if not (denied is Dictionary and denied.is_empty()):
		_begin_early_response(connection, denied)
	elif head["method"] == "GET":
		_begin_response(connection, _handler.handle(head, PackedByteArray()))
	else:
		connection["head"] = head
		connection["body_start"] = head_end
		connection["state"] = State.READ_BODY


# Reads what is available without letting the buffer grow past `limit` bytes.
func _read(connection: Dictionary, limit: int) -> bool:
	var peer: StreamPeerTCP = connection["peer"]
	var buffer: PackedByteArray = connection["buffer"]
	var deadline := Time.get_ticks_msec() + IO_BUDGET_MS
	while true:
		var wanted := mini(mini(peer.get_available_bytes(), IO_CHUNK_BYTES), limit - buffer.size())
		if wanted <= 0:
			break
		var result := peer.get_partial_data(wanted)
		if result[0] != OK:
			return false
		buffer.append_array(result[1])
		if Time.get_ticks_msec() >= deadline:
			break
	connection["buffer"] = buffer
	return true


# For responses sent before the request body was read.
func _begin_early_response(connection: Dictionary, response: Variant) -> void:
	connection["early"] = true
	_begin_response(connection, response)


# `response` is untyped on purpose: a handler that hit a script error returns
# null, and the connection must still get an answer and be closed.
func _begin_response(connection: Dictionary, response: Variant) -> void:
	var status := _FALLBACK_STATUS
	var body := JSON.stringify({
		"success": false, "command": "", "data": null, "errors": [_FALLBACK_ERROR], "warnings": [], "meta": {},
	}).to_utf8_buffer()
	if response is Dictionary and response.get("body") is PackedByteArray and response.get("status") is int:
		status = response["status"]
		body = response["body"]

	var head := "HTTP/1.1 %d %s\r\n" % [status, _REASONS.get(status, "Error")]
	head += "Content-Type: application/json; charset=utf-8\r\n"
	head += "Content-Length: %d\r\n" % body.size()
	head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
	var out := head.to_ascii_buffer()
	out.append_array(body)
	connection["out"] = out
	connection["sent"] = 0
	connection["write_started"] = Time.get_ticks_msec()
	connection["state"] = State.WRITE
	# The request is no longer needed; do not hold megabytes while writing.
	connection["buffer"] = PackedByteArray()


# Returns false on a socket error. Moves to DRAIN or finishes when all is sent.
func _write(connection: Dictionary) -> bool:
	var out: PackedByteArray = connection["out"]
	var sent: int = connection["sent"]
	var peer: StreamPeerTCP = connection["peer"]
	var deadline := Time.get_ticks_msec() + IO_BUDGET_MS
	while sent < out.size():
		var result := peer.put_partial_data(out.slice(sent, mini(sent + IO_CHUNK_BYTES, out.size())))
		if result[0] != OK:
			return false
		var written := int(result[1])
		sent += written
		if written == 0 or Time.get_ticks_msec() >= deadline:
			break
	connection["sent"] = sent
	if sent < out.size():
		return true
	if not connection["early"]:
		return false
	connection["state"] = State.DRAIN
	connection["drain_until"] = Time.get_ticks_msec() + DRAIN_MS
	return true


func _drain(connection: Dictionary, now: int) -> bool:
	if now >= int(connection["drain_until"]):
		return false
	var peer: StreamPeerTCP = connection["peer"]
	var available := mini(peer.get_available_bytes(), IO_CHUNK_BYTES)
	if available > 0:
		peer.get_partial_data(available)
	return true
