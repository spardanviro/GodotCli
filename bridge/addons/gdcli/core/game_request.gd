extends RefCounted
## One question to the running game and the wait for its answer. The game is
## another process, so the answer arrives some frames later: the HTTP layer
## keeps the connection open and calls poll() until this returns a reply.
##
## `channel` is game_link.gd, or a stand-in with the same methods in tests:
##   is_ready() -> bool            the game's helper has announced itself
##   send(method, args) -> int     returns the id of the request
##   take_reply(id) -> Variant     the answer, or null while there is none
##   is_stopped() -> bool          the game is halted in the debugger
##   stop_count() -> int           how often it has halted so far
##   forget(id)                    the answer is no longer wanted

const Reply = preload("reply.gd")
const TextSanitizer = preload("text_sanitizer.gd")

const DEFAULT_TIMEOUT_MSEC := 5000
const MAX_VALUES := 200000
const MAX_TEXT_CHARS := 4 * 1024 * 1024
const MAX_DEPTH := 64
const _NOT_SENT := -1
# A halted game still answers what is queued. If it halted after this request
# was sent and stays silent this long, the halt happened inside the request.
const HALT_GRACE_MSEC := 500
# What the game may report. Its own wording goes into `details`, because
# callers trust `message` and `hint` to be the bridge's words.
const _MESSAGES := {
	"INVALID_ARGS": "The running game rejected the arguments.",
	"NODE_NOT_FOUND": "The node does not exist in the running game.",
	"TYPE_MISMATCH": "The value cannot be converted to the property's type.",
	"RESOURCE_NOT_FOUND": "The running game could not find the resource.",
	"PATH_NOT_ALLOWED": "The running game refused the path.",
	"PRECONDITION_FAILED": "The running game cannot do this right now.",
	"COMMAND_FAILED": "The running game reported a failure.",
}

var _channel: Object
var _method: String
var _args: Dictionary
var _deadline: int
var _finish: Callable
var _id := _NOT_SENT
var _done := false
var _stops_when_sent := 0
var _halt_seen_at := 0


## `finish` turns the data of a successful answer into the command's reply;
## without it the data is returned after cleaning.
func _init(channel: Object, method: String, args: Dictionary, finish: Callable = Callable(), timeout_msec: int = DEFAULT_TIMEOUT_MSEC) -> void:
	_channel = channel
	_method = method
	_args = args
	_finish = finish
	_deadline = Time.get_ticks_msec() + timeout_msec


## {} while waiting; afterwards a reply (see reply.gd).
func poll() -> Dictionary:
	if _done:
		return Reply.fail("INTERNAL_ERROR", "The request was already answered.")
	if _id == _NOT_SENT and _channel.is_ready():
		_stops_when_sent = _channel.stop_count()
		_id = _channel.send(_method, _args)
	var answer: Variant = _channel.take_reply(_id) if _id != _NOT_SENT else null
	if answer != null:
		_done = true
		return _reply_from(answer)
	if Time.get_ticks_msec() < _deadline and not _halted_inside():
		return {}
	_done = true
	if _id == _NOT_SENT:
		return Reply.fail(
			"PRECONDITION_FAILED", "The running game has no gd helper.",
			"It is the autoload GdcliGame; `gd bridge install` adds it. Restart the game afterwards.",
		)
	_channel.forget(_id)
	# A halted game still answers, unless it halted inside this very request
	# (a call that hit a breakpoint or an error).
	if _channel.is_stopped():
		return Reply.fail(
			"PRECONDITION_FAILED", "The running game halted in the debugger before it answered.",
			"game_debug shows where and why; game_continue lets it run on.",
		)
	return Reply.fail("TIMEOUT", "The running game did not answer in time.", "It may be busy loading; try again.")


# True once the game has halted since the request went out and has given no
# answer for a moment: the request itself ran into a breakpoint or an error.
func _halted_inside() -> bool:
	if _id == _NOT_SENT or not _channel.is_stopped() or _channel.stop_count() == _stops_when_sent:
		return false
	if _halt_seen_at == 0:
		_halt_seen_at = Time.get_ticks_msec()
	return Time.get_ticks_msec() - _halt_seen_at >= HALT_GRACE_MSEC


func _reply_from(answer: Variant) -> Dictionary:
	if not (answer is Dictionary and answer.get("ok") is bool):
		return Reply.fail("COMMAND_FAILED", "The running game sent an answer the bridge does not understand.")
	if not answer["ok"]:
		return _failure(answer.get("error"))
	var data: Variant = answer.get("data")
	if _finish.is_valid():
		return _finish.call(data)
	return Reply.ok(clean(data))


func _failure(error: Variant) -> Dictionary:
	var code := "COMMAND_FAILED"
	var details := {}
	if error is Dictionary:
		if error.get("code") is String and _MESSAGES.has(error["code"]):
			code = error["code"]
		for key in ["message", "hint"]:
			if error.get(key) is String:
				details["reported_" + key] = TextSanitizer.clean_line(error[key])
		if error.get("details") is Dictionary:
			details["reported_details"] = clean(error["details"])
	return Reply.fail(code, _MESSAGES[code], "", details)


## The game is project code: what it sends is reduced to JSON values, and
## every string is cleaned like any other project text.
static func clean(value: Variant, budget: Dictionary = _new_budget(), depth: int = 0) -> Variant:
	budget["left"] -= 1
	if budget["left"] < 0 or depth > MAX_DEPTH:
		return null
	match typeof(value):
		TYPE_BOOL, TYPE_INT:
			return value
		TYPE_FLOAT:
			return value if is_finite(value) else null
		TYPE_STRING, TYPE_STRING_NAME:
			budget["chars"] -= str(value).length()
			return TextSanitizer.clean(str(value)) if budget["chars"] >= 0 else ""
		TYPE_ARRAY:
			var items := []
			for item in value:
				items.append(clean(item, budget, depth + 1))
			return items
		TYPE_DICTIONARY:
			var entries := {}
			for key in value:
				budget["chars"] -= str(key).length()
				if budget["chars"] < 0:
					break
				entries[TextSanitizer.clean_line(str(key))] = clean(value[key], budget, depth + 1)
			return entries
	return null


static func _new_budget() -> Dictionary:
	return {"left": MAX_VALUES, "chars": MAX_TEXT_CHARS}
