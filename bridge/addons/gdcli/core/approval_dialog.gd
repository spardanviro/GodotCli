extends RefCounted
## The question put to the person at the editor: allow this change or not.
## `decision` is "" until they answer, then "allowed" or "denied".

const TextSanitizer = preload("text_sanitizer.gd")

const ALLOWED := "allowed"
const DENIED := "denied"
## More than a person can be expected to read; such a change is refused.
const MAX_PREVIEW_CHARS := 60000
const _SIZE := Vector2i(760, 520)
const _INTRO := "A program using the gd bridge wants to make a change that can run code in this editor or change what it loads. Allow it only if you asked for it."

var decision := ""

var _dialog: ConfirmationDialog


## `what` is {command, reason, target?, preview?}; all of it may come from the
## caller or the project, so it is shown as plain, cleaned text.
func _init(parent: Node, what: Dictionary) -> void:
	_dialog = ConfirmationDialog.new()
	_dialog.title = "gd bridge: allow this change?"
	_dialog.dialog_text = _INTRO
	_dialog.dialog_autowrap = true
	_dialog.ok_button_text = "Allow"
	_dialog.cancel_button_text = "Deny"
	var details := TextEdit.new()
	details.editable = false
	# Nothing may sit out of sight to the right.
	details.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	details.custom_minimum_size = Vector2(0, 300)
	details.text = describe(what)
	_dialog.add_child(details)
	_dialog.confirmed.connect(_decide.bind(ALLOWED))
	_dialog.canceled.connect(_decide.bind(DENIED))
	parent.add_child(_dialog)
	_dialog.popup_centered(_SIZE)
	# Enter must not allow anything by accident.
	_dialog.get_cancel_button().grab_focus()


## The text shown below the question.
static func describe(what: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("Command: " + TextSanitizer.clean_line(str(what.get("command", ""))))
	lines.append("Why it needs you: " + TextSanitizer.clean_line(str(what.get("reason", ""))))
	if str(what.get("target", "")) != "":
		lines.append("Target: " + TextSanitizer.clean_line(str(what["target"])))
	var preview := str(what.get("preview", ""))
	if preview != "":
		lines.append("")
		lines.append("----- everything below this line comes from the program, not from the editor -----")
		lines.append(TextSanitizer.reveal(preview))
	return "\n".join(lines)


## A change whose content cannot be shown in full is not put to the person.
static func is_reviewable(what: Dictionary) -> bool:
	return str(what.get("preview", "")).length() <= MAX_PREVIEW_CHARS


## Withdraws the question; an unanswered one counts as denied.
func close() -> void:
	_decide(DENIED)


func _decide(answer: String) -> void:
	if decision == "":
		decision = answer
	if is_instance_valid(_dialog):
		_dialog.queue_free()
