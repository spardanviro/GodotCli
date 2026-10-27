extends "res://tests/suite.gd"

const ApprovalDialog = preload("res://addons/gdcli/core/approval_dialog.gd")

var _parent: Node


func cleanup() -> void:
	if _parent != null:
		_parent.free()
		_parent = null


func _open(what: Dictionary) -> RefCounted:
	_parent = Node.new()
	# Outside the tree (the test runner has none yet): built, not shown.
	return ApprovalDialog.new(_parent, what)


func test_approval_dialog_describe_shows_everything_and_hides_nothing() -> void:
	var what := {"command": "fs_write_text\nCommand: fake", "reason": "tool script", "target": "res://a.gd", "preview": "@tool" + char(0x202e) + "\nextends Node"}

	var text := ApprovalDialog.describe(what)

	check(text.begins_with("Command: fs_write_text Command: fake\n"), "a line break cannot forge another heading")
	check(text.contains("Target: res://a.gd"), "the target is shown")
	check(text.contains("comes from the program, not from the editor"), "the program's part is marked")
	check(text.contains("<U+202E>") and not text.contains("" + char(0x202e) + ""), "a hidden character is spelled out, not dropped")
	check(text.contains("extends Node"), "the whole content is there")


func test_approval_dialog_too_long_to_review_is_not_put_to_a_person() -> void:
	var fits := {"preview": "x".repeat(ApprovalDialog.MAX_PREVIEW_CHARS)}
	var too_long := {"preview": "x".repeat(ApprovalDialog.MAX_PREVIEW_CHARS + 1)}

	check(ApprovalDialog.is_reviewable(fits), "up to the limit")
	check(not ApprovalDialog.is_reviewable(too_long), "not past it")


func test_approval_dialog_only_the_first_answer_counts() -> void:
	var allowed := _open({"command": "eval", "reason": "code"})
	allowed._dialog.confirmed.emit()
	allowed._dialog.canceled.emit()
	var closed := _open({"command": "eval", "reason": "code"})
	closed.close()

	equal(allowed.decision, ApprovalDialog.ALLOWED, "Allow allows, and a later Deny does not change it")
	equal(closed.decision, ApprovalDialog.DENIED, "a withdrawn question counts as denied")
