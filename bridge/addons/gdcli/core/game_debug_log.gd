extends RefCounted
## What the editor's debugger hears from the running game: the errors it
## prints, whether it is halted and why, the call stack and the variables of a
## frame. It is fed the debugger's own messages (see game_link.gd) and keeps
## them in a form the commands can return. The game is project code, so every
## text is cleaned on the way in.

const TextSanitizer = preload("text_sanitizer.gd")
const ValueCodec = preload("value_codec.gd")

const MAX_ERRORS := 200
const MAX_FRAMES := 64
const MAX_VARIABLES := 500
const MAX_MESSAGE_CHARS := 4000
# Layout of an "error" message (core/debugger/debugger_marshalls.cpp).
const _ERROR_HEAD_SIZE := 11
const _SCOPES: Array[String] = ["locals", "members", "globals"]

var _errors: Array = []
var _error_total := 0
var _stopped := false
var _stops := 0
var _reason := ""
var _can_continue := false
var _stack: Array = []
var _variables_expected := -1
var _variables: Array = []


## A new run of the game starts with nothing known.
func reset() -> void:
	_errors = []
	_error_total = 0
	_stopped = false
	_reason = ""
	_can_continue = false
	_stack = []
	_variables_expected = -1
	_variables = []


func on_message(message: String, data: Array) -> void:
	match message:
		"error":
			_add_error(data)
		"debug_enter":
			_stopped = true
			_stops += 1
			_can_continue = data.size() > 0 and data[0] == true
			_reason = TextSanitizer.clean(str(data[1]).left(MAX_MESSAGE_CHARS)) if data.size() > 1 else ""
			_stack = []
		"debug_exit":
			_stopped = false
			_reason = ""
			_stack = []
		"stack_dump":
			_stack = _frames(data, 1, 0, 1, 2)
		"stack_frame_vars":
			_variables_expected = int(data[0]) if data.size() > 0 and (data[0] is int or data[0] is float) else 0
			_variables = []
		"stack_frame_var":
			if data.size() >= 4 and _variables.size() < MAX_VARIABLES:
				_variables.append(data)


## The most recent errors and warnings: {entries: [{severity, message,
## detail?, source: {file, line, function}, stack: [{file, line, function}]}],
## total}. `total` counts all of them since the game started.
func errors(limit: int) -> Dictionary:
	return {"entries": _errors.slice(maxi(_errors.size() - limit, 0)), "total": _error_total}


func error_total() -> int:
	return _error_total


func is_stopped() -> bool:
	return _stopped


## How many times the game has halted in the debugger during this run.
func stop_count() -> int:
	return _stops


## {stopped, reason, can_continue, stack: [{frame, file, line, function}]}
func status() -> Dictionary:
	return {"stopped": _stopped, "reason": _reason, "can_continue": _can_continue, "stack": _stack.duplicate(true)}


## The game was told to run on; it is no longer halted, whatever arrives next.
func mark_running() -> void:
	_stopped = false
	_reason = ""
	_stack = []


## Forget the variables received so far, before asking for those of a frame.
func expect_variables() -> void:
	_variables_expected = -1
	_variables = []


func variables_ready() -> bool:
	return _variables_expected >= 0 and _variables.size() >= mini(_variables_expected, MAX_VARIABLES)


## {locals: {name: value}, members: {...}, globals: {...}}, values encoded as
## docs/protocol.md section 6.4 describes.
func variables() -> Dictionary:
	var grouped := {}
	for scope in _SCOPES:
		grouped[scope] = {}
	var budget := ValueCodec.new_budget()
	for entry in _variables:
		var scope: int = entry[1] if entry[1] is int else 0
		var value: Variant = entry[3]
		# Objects of the game arrive as ids: they live in another process.
		if value is EncodedObjectAsID:
			value = {"$type": "Object", "id": str(value.object_id)}
		grouped[_SCOPES[clampi(scope, 0, _SCOPES.size() - 1)]][TextSanitizer.clean_line(str(entry[0]))] = ValueCodec.encode(value, null, budget)
	return grouped


func _add_error(data: Array) -> void:
	if data.size() < _ERROR_HEAD_SIZE:
		return
	_error_total += 1
	var summary := str(data[7])
	var description := str(data[8])
	var entry := {
		"severity": "warning" if data[9] == true else "error",
		# The description is what the script or the engine wrote; the summary
		# is the failed condition or the name of the function.
		"message": TextSanitizer.clean((description if description != "" else summary).left(MAX_MESSAGE_CHARS)),
		"source": {
			"file": TextSanitizer.clean_line(str(data[4])),
			"line": int(data[6]) if data[6] is int else 0,
			"function": TextSanitizer.clean_line(str(data[5])),
		},
		"stack": _frames(data, _ERROR_HEAD_SIZE, 0, 2, 1),
	}
	if description != "" and summary != "":
		entry["detail"] = TextSanitizer.clean(summary.left(MAX_MESSAGE_CHARS))
	_errors.append(entry)
	if _errors.size() > MAX_ERRORS:
		_errors.pop_front()


# Frames are stored flat, three values each; the two messages that carry them
# order the values differently.
func _frames(data: Array, first: int, file_at: int, line_at: int, function_at: int) -> Array:
	var frames := []
	var index := first
	while index + 2 < data.size() and frames.size() < MAX_FRAMES:
		frames.append({
			"frame": frames.size(),
			"file": TextSanitizer.clean_line(str(data[index + file_at])),
			"line": int(data[index + line_at]) if data[index + line_at] is int else 0,
			"function": TextSanitizer.clean_line(str(data[index + function_at])),
		})
		index += 3
	return frames
