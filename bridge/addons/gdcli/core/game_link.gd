@tool
extends EditorDebuggerPlugin
## The editor's end of the conversation with runtime/game_agent.gd. It rides
## on the debugger connection between the editor and a game the editor
## started, so there is no extra port and nothing for another process to
## connect to.

const CAPTURE := "gdcli"
const MESSAGE_REQUEST := "gdcli:request"
const MESSAGE_REPLY := "gdcli:reply"
const MESSAGE_HELLO := "gdcli:hello"
const AUTOLOAD_NAME := "GdcliGame"
const AUTOLOAD_SETTING := "autoload/GdcliGame"
const AUTOLOAD_SCRIPT := "res://addons/gdcli/runtime/game_agent.gd"
# The editor's own debugger panel. It is not part of the scripting interface,
# but it is a node with a signal that repeats every message from the game,
# which is the only place a plugin can read errors and the call stack from.
const _DEBUGGER_CLASS := "ScriptEditorDebugger"
const _MESSAGE_SIGNAL := "debug_data"

const GameDebugLog = preload("game_debug_log.gd")

# Answers nobody collected (the caller went away) are dropped after this long.
const _KEEP_MSEC := 60000

var _next_id := 1
# Requests that were sent and not yet answered: id -> {session, at}.
var _waiting := {}
# Answers not yet collected: id -> {answer, at}.
var _replies := {}
# Sessions whose game has announced its helper.
var _ready_sessions := {}
var _debug_log := GameDebugLog.new()
var _listening := false
# Before this engine version (0xMMmmpp) a script error halts the game without
# also being reported as an error.
const _SCRIPT_ERRORS_REPORTED_SINCE := 0x040500


func _init() -> void:
	_debug_log.record_script_errors = Engine.get_version_info()["hex"] < _SCRIPT_ERRORS_REPORTED_SINCE


func _has_capture(capture: String) -> bool:
	return capture == CAPTURE


func _setup_session(session_id: int) -> void:
	var session := get_session(session_id)
	# A session is reused for the next run: what is known about it starts over.
	session.started.connect(_reset.bind(session_id))
	session.started.connect(_debug_log.reset)
	session.stopped.connect(_reset.bind(session_id))
	# A game that ends while halted must not be remembered as halted.
	session.stopped.connect(_debug_log.reset)
	listen_to_debuggers()


## Connects to the editor's debugger panels; there is one per game instance,
## and more appear when several instances are run. Safe to call again.
func listen_to_debuggers() -> void:
	for panel in EditorInterface.get_base_control().find_children("*", _DEBUGGER_CLASS, true, false):
		if panel.has_signal(_MESSAGE_SIGNAL) and not panel.is_connected(_MESSAGE_SIGNAL, _debug_log.on_message):
			panel.connect(_MESSAGE_SIGNAL, _debug_log.on_message)
			_listening = true


## False when this editor version gives no way to hear the game's messages.
func can_listen() -> bool:
	return _listening


func debug_log() -> RefCounted:
	return _debug_log


func _active_session() -> EditorDebuggerSession:
	for session in get_sessions():
		if session != null and session.is_active():
			return session
	return null


## Sends one of the debugger's own commands (continue, step, next, out, break,
## get_stack_frame_vars) to the running game. False when no game is attached.
func debugger_command(message: String, data: Array = []) -> bool:
	var session := _active_session()
	if session == null:
		return false
	session.send_message(message, data)
	return true


func set_breakpoint(path: String, line: int, enabled: bool) -> bool:
	var session := _active_session()
	if session == null:
		return false
	session.set_breakpoint(path, line, enabled)
	return true


func _capture(message: String, data: Array, session_id: int) -> bool:
	if message == MESSAGE_HELLO:
		_ready_sessions[session_id] = true
	elif message == MESSAGE_REPLY and data.size() == 2 and data[0] is int:
		var id: int = data[0]
		if _waiting.has(id) and _waiting[id]["session"] == session_id:
			_waiting.erase(id)
			_replies[id] = {"answer": data[1], "at": Time.get_ticks_msec()}
	return true


func _reset(session_id: int) -> void:
	_ready_sessions.erase(session_id)
	for id in _waiting.keys():
		if _waiting[id]["session"] == session_id:
			_waiting.erase(id)


# -1 when no running game has a helper.
func _ready_session_id() -> int:
	for session_id in _ready_sessions:
		var session := get_session(session_id)
		if session != null and session.is_active():
			return session_id
	return -1


func _drop_stale() -> void:
	var oldest := Time.get_ticks_msec() - _KEEP_MSEC
	for entries in [_waiting, _replies]:
		for id in entries.keys():
			if entries[id]["at"] < oldest:
				entries.erase(id)


# --- the channel used by game_request.gd -------------------------------------

func is_ready() -> bool:
	return _ready_session_id() != -1


func send(method: String, args: Dictionary) -> int:
	_drop_stale()
	var id := _next_id
	_next_id += 1
	var session_id := _ready_session_id()
	if session_id != -1:
		_waiting[id] = {"session": session_id, "at": Time.get_ticks_msec()}
		get_session(session_id).send_message(MESSAGE_REQUEST, [id, method, args])
	return id


func is_stopped() -> bool:
	var session := _active_session()
	return session != null and session.is_breaked()


func stop_count() -> int:
	return _debug_log.stop_count()


func take_reply(id: int) -> Variant:
	if not _replies.has(id):
		return null
	var answer: Variant = _replies[id]["answer"]
	_replies.erase(id)
	return answer


func forget(id: int) -> void:
	_waiting.erase(id)
	_replies.erase(id)
