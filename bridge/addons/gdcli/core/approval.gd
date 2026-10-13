extends RefCounted
## Waits for a person to allow or deny one change in the editor, then runs it.
## This is the only approval the caller cannot give itself: `confirm` comes
## with the request, a click in the editor does not.
##
## It is a waiter (see Reply.later): the HTTP layer polls it once per frame.

const ApprovalDialog = preload("approval_dialog.gd")
const Reply = preload("reply.gd")

## Shorter than the time the HTTP layer keeps a waiting request (60 s), so the
## caller gets this answer and not a bare timeout.
const WAIT_MSEC := 50000
const _HINT := "Do it in the editor yourself, or ask the user to allow it."

var _question: Object
var _action: Callable
var _deadline: int
var _running: RefCounted
var _answered := false
var _too_long := false


## `what` describes the change: {command, reason, target?, preview?}.
## `action` does it and returns a reply; it is called only after a yes.
func _init(context: RefCounted, what: Dictionary, action: Callable, wait_msec: int = WAIT_MSEC) -> void:
	_too_long = not ApprovalDialog.is_reviewable(what)
	if not _too_long:
		_question = context.ask_person(what)
	_action = action
	_deadline = Time.get_ticks_msec() + wait_msec


func poll() -> Dictionary:
	# Allowed, and the change itself takes several frames.
	if _running != null:
		return _running.poll()
	if _answered:
		return Reply.fail("INTERNAL_ERROR", "The request was already answered.")
	if _too_long:
		_answered = true
		return _refused("too long for a person to review")
	if _question == null:
		_answered = true
		return _refused("nobody can be asked: this editor has no window")
	if _question.decision == "":
		if Time.get_ticks_msec() < _deadline:
			return {}
		_question.close()
		_answered = true
		return _refused("nobody answered in time")
	_answered = true
	if _question.decision != "allowed":
		return _refused("denied in the editor")
	var reply: Variant = _action.call()
	if not (reply is Dictionary and reply.has("ok")):
		return Reply.fail("INTERNAL_ERROR", "The command did not return a reply.")
	if reply["ok"] and reply.has("later"):
		_running = reply["later"]
		return _running.poll()
	return reply


## The caller went away: a question nobody waits for is withdrawn. A change
## that was already allowed and is under way is finished.
func abandon() -> void:
	if _running == null and _question != null and _question.decision == "":
		_question.close()


func _refused(why: String) -> Dictionary:
	return Reply.fail("NOT_APPROVED", "A person has to allow this change in the editor, and did not.", _HINT, {"reason": why})
