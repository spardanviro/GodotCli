extends "res://tests/suite.gd"
## node_connections, node_disconnect_signal, node_remove_from_group,
## resource_get and editor_select.

const AccessPolicy = preload("res://addons/gdcli/core/access_policy.gd")
const EditorCommands = preload("res://addons/gdcli/commands/editor_commands.gd")
const NodeLinkCommands = preload("res://addons/gdcli/commands/node_link_commands.gd")
const ResourceCommands = preload("res://addons/gdcli/commands/resource_commands.gd")
const Registry = preload("res://addons/gdcli/core/registry.gd")
const Schema = preload("res://addons/gdcli/core/schema.gd")
const ValueCodec = preload("res://addons/gdcli/core/value_codec.gd")
const FakeContext = preload("res://tests/fake_context.gd")

const TMP := "res://tests/tmp/link_probe"

var _context: RefCounted
var _registry: RefCounted
var _sets: Array = []
var _root: Node2D
var _button: Button
var _label: Label


func cleanup() -> void:
	if _root != null:
		_root.free()
		_root = null
	for file in ["shape.tres", "enemy.tscn", "tool.gd"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP + "/" + file))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


func _setup() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP))
	_root = Node2D.new()
	_root.name = "Main"
	_button = Button.new()
	_button.name = "Start"
	_label = Label.new()
	_label.name = "Title"
	_root.add_child(_button)
	_root.add_child(_label)
	_button.owner = _root
	_label.owner = _root
	_button.pressed.connect(_label.hide, CONNECT_PERSIST)
	_button.pressed.connect(_label.show)  # not saved with the scene
	_label.add_to_group("titles", true)
	_context = FakeContext.new()
	_context.root = _root
	_context.path = "res://tests/fixtures/main.tscn"
	_registry = Registry.new()
	_sets = [NodeLinkCommands.new(_context), ResourceCommands.new(), EditorCommands.new(_context)]
	for command_set in _sets:
		command_set.register(_registry)


func _call(command: String, args: Dictionary, options: Dictionary = {}) -> Dictionary:
	var descriptor: Dictionary = _registry.descriptor_of(command)
	var validated := Schema.validate(args, descriptor["params"])
	if not validated["ok"]:
		return validated
	if descriptor["risk"] == AccessPolicy.RISK_READ:
		return _registry.handler_of(command).call(validated["args"])
	var complete := {"dry_run": false, "confirm": false, "mode": "standard"}
	complete.merge(options, true)
	return _registry.handler_of(command).call(validated["args"], complete)


func _code(command: String, args: Dictionary, options: Dictionary = {}) -> String:
	var reply := _call(command, args, options)
	return "" if reply["ok"] else reply["error"]["code"]


func test_node_connections_lists_what_the_scene_saves() -> void:
	_setup()

	var reply := _call("node_connections", {"path": "Start"})

	equal(reply["data"]["connections"], [{"signal": "pressed", "target": "Title", "method": "hide"}], "only the connection saved with the scene")
	equal(_call("node_connections", {"path": "Start", "signal": "toggled"})["data"]["connections"], [], "filtered by signal")


func test_node_disconnect_signal_removes_it_and_undo_puts_it_back() -> void:
	_setup()
	var hide := Callable(_label, "hide")

	var reply := _call("node_disconnect_signal", {"path": "Start", "signal": "pressed", "target": "Title", "method": "hide"})

	check(reply["ok"] and not _button.pressed.is_connected(hide), "disconnected: %s" % reply)
	_context.undo.undo()
	check(_button.pressed.is_connected(hide), "undo connects it again")
	var flags: int = _button.get_signal_connection_list("pressed").filter(func(c: Dictionary) -> bool: return c["callable"] == hide)[0]["flags"]
	check(flags & CONNECT_PERSIST != 0, "and it is saved with the scene again")


func test_node_disconnect_signal_refuses_a_connection_that_is_not_saved() -> void:
	_setup()

	var reply := _call("node_disconnect_signal", {"path": "Start", "signal": "pressed", "target": "Title", "method": "show"})

	equal(reply["error"]["code"], "INVALID_ARGS", "the editor's own or a script's connection is not the scene's")
	equal(reply["error"]["details"]["connections"].size(), 1, "the ones there are")
	equal(_code("node_disconnect_signal", {"path": "Nope", "signal": "pressed", "target": "Title", "method": "hide"}), "NODE_NOT_FOUND", "a missing node")


func test_node_remove_from_group_and_undo() -> void:
	_setup()

	check(_call("node_remove_from_group", {"path": "Title", "group": "titles"})["ok"] and not _label.is_in_group("titles"), "removed")
	_context.undo.undo()
	check(_label.is_in_group("titles"), "undo adds it again")
	equal(_code("node_remove_from_group", {"path": "Title", "group": "enemies"}), "INVALID_ARGS", "a group it is not in")
	equal(_code("node_remove_from_group", {"path": "Title", "group": "_internal"}), "INVALID_ARGS", "the engine's own groups")


func test_node_remove_from_group_leaves_an_instanced_scenes_groups_to_that_scene() -> void:
	_setup()
	var enemy := Node2D.new()
	enemy.name = "Enemy"
	enemy.add_to_group("enemies", true)
	var packed := PackedScene.new()
	packed.pack(enemy)
	enemy.free()
	ResourceSaver.save(packed, TMP + "/enemy.tscn")
	var instance: Node = load(TMP + "/enemy.tscn").instantiate()
	_root.add_child(instance)
	instance.owner = _root
	instance.add_to_group("spawned", true)

	equal(_code("node_remove_from_group", {"path": "Enemy", "group": "enemies"}), "PRECONDITION_FAILED", "the group is the instanced scene's")
	equal(_code("node_remove_from_group", {"path": "Enemy", "group": "spawned"}), "", "one added in this scene can go")


func test_resource_get_reads_a_resource_file() -> void:
	_setup()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(32, 8)
	ResourceSaver.save(shape, TMP + "/shape.tres")

	var all := _call("resource_get", {"path": TMP + "/shape.tres"})
	var one := _call("resource_get", {"path": TMP + "/shape.tres", "properties": ["size"]})

	equal([all["data"]["type"], all["data"]["properties"].get("size")], ["RectangleShape2D", ValueCodec.encode(Vector2(32, 8))], "class and an Inspector property")
	equal(one["data"]["properties"].keys(), ["size"], "only what was asked")
	check(not all["data"]["properties"].has("resource_path"), "where it is stored is not one of its values")


func test_resource_get_refuses_what_is_not_a_plain_resource() -> void:
	_setup()
	FileAccess.open(TMP + "/tool.gd", FileAccess.WRITE).store_string("extends Node\n")

	equal(_code("resource_get", {"path": TMP + "/tool.gd"}), "TYPE_MISMATCH", "a script")
	equal(_code("resource_get", {"path": TMP + "/missing.tres"}), "RESOURCE_NOT_FOUND", "nothing there")
	equal(_code("resource_get", {"path": "user://shape.tres"}), "PATH_NOT_ALLOWED", "outside the project")


func test_editor_select_selects_nodes() -> void:
	_setup()

	var reply := _call("editor_select", {"paths": ["Start", "Title"]})

	equal(reply["data"]["nodes"], [{"path": "Start", "type": "Button"}, {"path": "Title", "type": "Label"}], "both selected")
	equal(_code("editor_select", {"paths": ["Nope"]}), "NODE_NOT_FOUND", "a missing node selects nothing")
	equal(_call("editor_select", {"paths": []})["data"]["nodes"], [], "an empty list clears it")
