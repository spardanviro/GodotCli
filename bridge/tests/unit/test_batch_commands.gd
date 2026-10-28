extends "res://tests/suite.gd"
## batch: steps in order, and a failure undoes the steps already done.

const AccessPolicy = preload("res://addons/gdcli/core/access_policy.gd")
const BatchCommands = preload("res://addons/gdcli/commands/batch_commands.gd")
const FsEditCommands = preload("res://addons/gdcli/commands/fs_edit_commands.gd")
const NodeCommands = preload("res://addons/gdcli/commands/node_commands.gd")
const NodeEditCommands = preload("res://addons/gdcli/commands/node_edit_commands.gd")
const Registry = preload("res://addons/gdcli/core/registry.gd")
const Schema = preload("res://addons/gdcli/core/schema.gd")
const FakeContext = preload("res://tests/fake_context.gd")

var _context: RefCounted
var _registry: RefCounted
var _sets: Array = []
var _root: Node2D


func cleanup() -> void:
	if _root != null:
		_root.free()
		_root = null


func _setup() -> void:
	_root = Node2D.new()
	_root.name = "Main"
	_context = FakeContext.new()
	_context.root = _root
	_context.path = "res://tests/fixtures/main.tscn"
	_registry = Registry.new()
	_sets = [NodeEditCommands.new(_context), NodeCommands.new(_context), FsEditCommands.new(_context), BatchCommands.new(_context, _registry)]
	for command_set in _sets:
		command_set.register(_registry)


func _batch(steps: Array, options: Dictionary = {}) -> Dictionary:
	var descriptor: Dictionary = _registry.descriptor_of("batch")
	var validated := Schema.validate({"steps": steps}, descriptor["params"])
	if not validated["ok"]:
		return validated
	var complete := {"dry_run": false, "confirm": false, "mode": "standard"}
	complete.merge(options, true)
	return _registry.handler_of("batch").call(validated["args"], complete)


func _names() -> Array:
	var names := []
	for child in _root.get_children():
		names.append(str(child.name))
	return names


func test_batch_runs_the_steps_in_order() -> void:
	_setup()

	var reply := _batch([
		{"command": "node_create", "args": {"type": "CharacterBody2D", "name": "Player"}},
		{"command": "node_create", "args": {"type": "CollisionShape2D", "parent": "Player"}},
		{"command": "node_get", "args": {"path": "Player/CollisionShape2D", "properties": ["position"]}},
	])

	check(reply["ok"], "done: %s" % reply)
	equal(_names(), ["Player"], "the first step made the parent of the second")
	equal(reply["data"]["steps"].size(), 3, "every step answered")
	equal(reply["data"]["undo"].size(), 2, "the read made no undo step")


func test_batch_undoes_what_it_did_when_a_step_fails() -> void:
	_setup()

	var reply := _batch([
		{"command": "node_create", "args": {"type": "Node2D", "name": "A"}},
		{"command": "node_create", "args": {"type": "Node2D", "name": "B"}},
		{"command": "node_set", "args": {"path": "Nope", "properties": {"visible": false}}},
	])

	equal(reply["error"]["code"], "NODE_NOT_FOUND", "the failed step's own error")
	equal([reply["error"]["details"]["step"], reply["error"]["details"]["undone"]], [2, 2], "which step, and how many were taken back")
	equal(_names(), [], "nothing is left of the batch")


func test_batch_takes_only_undo_steps_and_reads() -> void:
	_setup()

	var cases := {
		"a file write": [{"command": "fs_write_text", "args": {"path": "res://a.txt", "text": "x"}}, "INVALID_ARGS"],
		"a batch in a batch": [{"command": "batch", "args": {"steps": []}}, "UNKNOWN_COMMAND"],
		"an unknown command": [{"command": "nope", "args": {}}, "UNKNOWN_COMMAND"],
		"a bad argument": [{"command": "node_create", "args": {"name": "No type"}}, "INVALID_ARGS"],
		"a step without a command": [{"args": {}}, "INVALID_ARGS"],
	}
	for name in cases:
		var reply := _batch([{"command": "node_create", "args": {"type": "Node2D", "name": "First"}}, cases[name][0]])
		equal(reply.get("error", {}).get("code"), cases[name][1], name)
		equal(reply["error"].get("details", {}).get("step"), 1, "%s: the step is named" % name)
	equal(_names(), [], "checked before anything ran")
	equal(_batch([])["error"]["code"], "INVALID_ARGS", "no steps")


func test_batch_dry_run_checks_and_changes_nothing() -> void:
	_setup()

	var reply := _batch([{"command": "node_create", "args": {"type": "Node2D", "name": "A"}}], {"dry_run": true})

	equal(reply["data"]["would"]["steps"], ["node_create"], "what would run")
	equal(_names(), [], "nothing made")


func test_batch_stops_at_a_step_that_needs_a_person() -> void:
	_setup()
	var tool_script := "res://tests/tmp/batch_tool.gd"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/tmp"))
	FileAccess.open(tool_script, FileAccess.WRITE).store_string("@tool\nextends Node2D\n")

	var reply := _batch([
		{"command": "node_create", "args": {"type": "Node2D", "name": "Host"}},
		{"command": "node_attach_script", "args": {"path": "Host", "script": tool_script}},
	])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tool_script))

	equal(reply["error"]["code"], "PRECONDITION_FAILED", "a batch does not ask anyone")
	equal(_context.questions.size(), 0, "no dialog was opened")
	equal(_names(), [], "the node it made first is gone again")
