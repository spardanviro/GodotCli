extends RefCounted
## Keeps the errors and warnings the editor process prints, for editor_errors.
## Uses the Logger class of Godot 4.5; on older versions `create` returns null.
##
## The logger itself is compiled from a string at run time. A script file that
## extends Logger would fail to parse on 4.3 and 4.4, where the class does not
## exist, and the editor parses every script it finds in the project.

const TextSanitizer = preload("text_sanitizer.gd")

const MAX_ENTRIES := 500

# @tool: inside the editor, a script without it cannot be instantiated.
const _LOGGER_SOURCE := """@tool
extends Logger

var sink: Object


func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, script_backtraces: Array) -> void:
	if sink != null:
		sink.record(function, file, line, code, rationale, error_type, script_backtraces)


func _log_message(_message: String, _error: bool) -> void:
	pass
"""
const _WARNING_TYPE := 1

var _entries: Array = []
var _dropped := 0
var _total := 0
# Errors can be reported from any thread.
var _mutex := Mutex.new()
var _logger: Object


## Starts capturing. Returns null where the engine has no Logger class.
static func create() -> RefCounted:
	if not ClassDB.class_exists("Logger"):
		return null
	var script := GDScript.new()
	script.source_code = _LOGGER_SOURCE
	if script.reload() != OK or not script.can_instantiate():
		return null
	var log: RefCounted = new()
	log._logger = script.new()
	log._logger.set("sink", log)
	OS.call("add_logger", log._logger)
	return log


func stop() -> void:
	if _logger != null:
		# Under the lock, so a report in flight on another thread finishes first.
		_mutex.lock()
		_logger.set("sink", null)
		_mutex.unlock()
		OS.call("remove_logger", _logger)
		_logger = null


## Called by the logger, possibly from another thread.
func record(function: String, file: String, line: int, code: String, rationale: String, error_type: int, script_backtraces: Array) -> void:
	var message := rationale if rationale != "" else code
	var entry := {
		"severity": "warning" if error_type == _WARNING_TYPE else "error",
		# Cut here, not when reading: a script can push megabytes per error.
		"message": message.left(TextSanitizer.MAX_LINE_LENGTH),
		"file": file.left(TextSanitizer.MAX_LINE_LENGTH),
		"line": line,
		"function": function.left(TextSanitizer.MAX_LINE_LENGTH),
	}
	# An error raised inside the engine is located in C++; the first script
	# frame is what the user can act on.
	for backtrace in script_backtraces:
		if backtrace != null and backtrace.get_frame_count() > 0:
			entry["file"] = str(backtrace.get_frame_file(0)).left(TextSanitizer.MAX_LINE_LENGTH)
			entry["line"] = backtrace.get_frame_line(0)
			entry["function"] = str(backtrace.get_frame_function(0)).left(TextSanitizer.MAX_LINE_LENGTH)
			break
	_mutex.lock()
	if _entries.size() >= MAX_ENTRIES:
		_entries.pop_front()
		_dropped += 1
	_entries.append(entry)
	_total += 1
	_mutex.unlock()


## How many entries were ever recorded; lets a caller see what one step added.
func total() -> int:
	_mutex.lock()
	var count := _total
	_mutex.unlock()
	return count


## The newest `limit` entries, oldest first. `dropped` counts entries lost
## because the buffer was full. Reading changes nothing.
func read(limit: int) -> Dictionary:
	_mutex.lock()
	var taken := _entries.slice(maxi(_entries.size() - limit, 0))
	var dropped := _dropped
	_mutex.unlock()

	var cleaned := []
	for entry in taken:
		cleaned.append({
			"severity": entry["severity"],
			"message": TextSanitizer.clean_line(str(entry["message"])),
			"file": TextSanitizer.clean_line(str(entry["file"])),
			"line": entry["line"],
			"function": TextSanitizer.clean_line(str(entry["function"])),
		})
	return {"entries": cleaned, "dropped": dropped}
