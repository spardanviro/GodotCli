extends "res://tests/suite.gd"

const Edit = preload("res://addons/gdcli/core/edit.gd")
const NodeEditCommands = preload("res://addons/gdcli/commands/node_edit_commands.gd")
const Registry = preload("res://addons/gdcli/core/registry.gd")
const Schema = preload("res://addons/gdcli/core/schema.gd")
const FakeContext = preload("res://tests/fake_context.gd")

signal probe

var _root: Node2D
var _context: RefCounted
var _registry: RefCounted
var _commands: RefCounted


func cleanup() -> void:
	if _root != null:
		_root.free()
		_root = null


# Main (Node2D)
# ├─ Player (Node2D) ── Sprite (Sprite2D)
# └─ World (Node)
func _scene() -> void:
	_root = Node2D.new()
	_root.name = "Main"
	var player := Node2D.new()
	player.name = "Player"
	_add(_root, player)
	var sprite := Sprite2D.new()
	sprite.name = "Sprite"
	_add(player, sprite)
	var world := Node.new()
	world.name = "World"
	_add(_root, world)

	_context = FakeContext.new()
	_context.root = _root
	_context.path = "res://main.tscn"
	_registry = Registry.new()
	_commands = NodeEditCommands.new(_context)
	_commands.register(_registry)


func _add(parent: Node, child: Node) -> void:
	parent.add_child(child)
	child.owner = _root


func _call(command: String, args: Dictionary, dry_run: bool = false) -> Dictionary:
	var validated := Schema.validate(args, _registry.descriptor_of(command)["params"])
	if not validated["ok"]:
		return validated
	return _registry.handler_of(command).call(validated["args"], {"dry_run": dry_run, "confirm": false, "mode": "standard"})


func _code(command: String, args: Dictionary) -> String:
	var reply := _call(command, args)
	return "" if reply["ok"] else reply["error"]["code"]


func test_node_create_adds_an_owned_node_and_one_undo_step() -> void:
	_scene()

	var reply := _call("node_create", {"parent": "World", "type": "CharacterBody2D", "name": "Enemy", "properties": {"position": [5, 6]}})

	var enemy := _root.get_node("World/Enemy")
	equal(reply["data"], {"path": "World/Enemy", "type": "CharacterBody2D"}, "reply")
	equal(reply["undo"], "gdcli: node_create Enemy", "undo step name")
	equal(enemy.owner, _root, "owned by the scene root, so it is saved")
	equal(enemy.position, Vector2(5, 6), "properties applied")
	equal(_context.undo.action_names(), ["gdcli: node_create Enemy"], "exactly one step")

	_context.undo.undo()
	equal(_root.has_node("World/Enemy"), false, "undo removes it")
	enemy.free()


func test_node_create_defaults_the_name_and_rejects_bad_input() -> void:
	_scene()

	equal(_call("node_create", {"type": "Timer"})["data"]["path"], "Timer", "default name and parent")
	equal(_code("node_create", {"type": "NoSuchNode"}), "INVALID_ARGS", "unknown class")
	equal(_code("node_create", {"type": "Resource"}), "INVALID_ARGS", "not a node")
	equal(_code("node_create", {"type": "Node", "name": "a/b"}), "INVALID_ARGS", "bad name")
	equal(_code("node_create", {"type": "Node", "parent": "Ghost"}), "NODE_NOT_FOUND", "missing parent")
	equal(_code("node_create", {"type": "Node2D", "properties": {"position": "x"}}), "TYPE_MISMATCH", "bad property value")
	equal(_code("node_create", {"type": "Node2D", "properties": {"script": null}}), "TYPE_MISMATCH", "script via properties")
	equal(_root.get_child_count(), 3, "only the one valid node was added")


func test_node_create_dry_run_changes_nothing() -> void:
	_scene()

	var reply := _call("node_create", {"type": "Node", "name": "Ghost"}, true)

	equal(reply["data"]["dry_run"], true, "flagged as a dry run")
	equal(_root.has_node("Ghost"), false, "no node")
	equal(_context.undo.action_names(), [], "no undo step")
	check(not reply.has("undo"), "no undo name")


func test_node_delete_removes_and_undo_restores_position_and_owners() -> void:
	_scene()
	var player := _root.get_node("Player")
	var sprite := _root.get_node("Player/Sprite")

	var reply := _call("node_delete", {"path": "Player"})

	equal(reply["data"]["children_removed"], 1, "reports the children")
	equal(_root.has_node("Player"), false, "removed")
	check(sprite.owner == null, "owners are cleared when the node leaves")

	_context.undo.undo()
	equal(_root.get_child(0), player, "back at its old index")
	equal(player.owner, _root, "owner restored")
	equal(sprite.owner, _root, "child owner restored")


func test_node_delete_refuses_the_root_and_unknown_nodes() -> void:
	_scene()

	equal(_code("node_delete", {"path": "."}), "INVALID_ARGS", "root")
	equal(_code("node_delete", {"path": "Ghost"}), "NODE_NOT_FOUND", "missing")
	equal(_code("node_delete", {"path": "../Main"}), "NODE_NOT_FOUND", "outside the scene")


func test_node_set_changes_properties_as_one_undoable_step() -> void:
	_scene()
	var player: Node2D = _root.get_node("Player")
	player.position = Vector2(1, 1)

	var reply := _call("node_set", {"path": "Player", "properties": {"position": {"x": 9, "y": 8}, "visible": false}})

	equal(player.position, Vector2(9, 8), "position")
	equal(player.visible, false, "visible")
	equal(reply["data"]["set"], ["position", "visible"], "reports what was set")
	equal(_context.undo.action_names().size(), 1, "one step for both properties")
	_context.undo.undo()
	equal(player.position, Vector2(1, 1), "undo restores the position")
	equal(player.visible, true, "and visibility")


func test_node_set_validates_everything_before_changing_anything() -> void:
	_scene()
	var player: Node2D = _root.get_node("Player")

	equal(_code("node_set", {"path": "Player", "properties": {"visible": false, "position": "nope"}}), "TYPE_MISMATCH", "one bad value")
	equal(player.visible, true, "the good value was not applied either")
	equal(_code("node_set", {"path": "Player", "properties": {}}), "INVALID_ARGS", "nothing to set")
	equal(_code("node_set", {"path": "Player", "properties": {"nope": 1}}), "INVALID_ARGS", "unknown property")


func test_node_rename_checks_names_and_siblings() -> void:
	_scene()

	equal(_call("node_rename", {"path": "Player", "name": "Hero"})["data"]["path"], "Hero", "renamed")
	equal(_code("node_rename", {"path": "Hero", "name": "World"}), "ALREADY_EXISTS", "sibling has the name")
	equal(_code("node_rename", {"path": "Hero", "name": "bad:name"}), "INVALID_ARGS", "invalid characters")
	_context.undo.undo()
	check(_root.has_node("Player"), "undo restores the name")


func test_node_move_reparents_keeps_owners_and_undoes() -> void:
	_scene()
	var player := _root.get_node("Player")
	var sprite := _root.get_node("Player/Sprite")

	var reply := _call("node_move", {"path": "Player", "parent": "World"})

	equal(reply["data"]["path"], "World/Player", "new path")
	equal(player.owner, _root, "owner kept")
	equal(sprite.owner, _root, "child owner kept")
	_context.undo.undo()
	equal(_root.get_child(0), player, "undo puts it back first")
	equal(sprite.owner, _root, "child owner after undo")


func test_node_move_reorders_among_siblings() -> void:
	_scene()

	_call("node_move", {"path": "World", "index": 0})

	equal(_root.get_child(0).name, &"World", "moved to the front")
	_call("node_move", {"path": "World", "index": 99})
	equal(_root.get_child(1).name, &"World", "an index past the end means last")


func test_node_move_refuses_impossible_moves() -> void:
	_scene()

	equal(_code("node_move", {"path": ".", "parent": "World"}), "INVALID_ARGS", "the root")
	equal(_code("node_move", {"path": "Player", "parent": "Player/Sprite"}), "INVALID_ARGS", "into its own child")
	equal(_code("node_move", {"path": "Player", "parent": "Ghost"}), "NODE_NOT_FOUND", "missing parent")
	_call("node_create", {"parent": "World", "type": "Node", "name": "Player"})
	equal(_code("node_move", {"path": "Player", "parent": "World"}), "ALREADY_EXISTS", "name clash at the destination")


func test_node_duplicate_copies_children_with_owners() -> void:
	_scene()

	var reply := _call("node_duplicate", {"path": "Player", "name": "Player2"})

	var copy := _root.get_node("Player2")
	equal(reply["data"]["path"], "Player2", "path of the copy")
	equal(copy.get_index(), 1, "placed after the original")
	equal(copy.owner, _root, "copy is owned")
	equal(copy.get_node("Sprite").owner, _root, "and so are its children")
	_context.undo.undo()
	equal(_root.has_node("Player2"), false, "undo removes the copy")
	copy.free()


func test_node_attach_script_validates_the_path() -> void:
	_scene()

	equal(_code("node_attach_script", {"path": "Player", "script": "res://../evil.gd"}), "PATH_NOT_ALLOWED", "outside the project")
	equal(_code("node_attach_script", {"path": "Player", "script": "res://nowhere.gd"}), "RESOURCE_NOT_FOUND", "missing")
	equal(_code("node_attach_script", {"path": "Player", "script": "res://tests/fixtures/main.tscn"}), "TYPE_MISMATCH", "not a script")
	equal(_code("node_attach_script", {"path": "Ghost", "script": ""}), "NODE_NOT_FOUND", "missing node")


func test_node_attach_script_attaches_detaches_and_undoes() -> void:
	_scene()
	var world := _root.get_node("World")

	var reply := _call("node_attach_script", {"path": "World", "script": "res://tests/fixtures/empty_script.gd"})

	equal(reply["data"]["script"], "res://tests/fixtures/empty_script.gd", "reply")
	equal(world.get_script().resource_path, "res://tests/fixtures/empty_script.gd", "attached")
	_call("node_attach_script", {"path": "World", "script": ""})
	equal(world.get_script(), null, "detached with an empty path")
	_context.undo.undo()
	check(world.get_script() != null, "undo re-attaches")


func test_node_connect_signal_makes_a_persistent_connection() -> void:
	_scene()
	var player := _root.get_node("Player")
	var world := _root.get_node("World")

	var reply := _call("node_connect_signal", {"path": "Player", "signal": "visibility_changed", "target": "World", "method": "_on_player_visibility_changed"})

	var connections: Array = player.get_signal_connection_list("visibility_changed")
	equal(connections.size(), 1, "connected")
	check(connections[0]["flags"] & CONNECT_PERSIST != 0, "saved with the scene")
	equal(connections[0]["callable"].get_object(), world, "to the target")
	equal(reply["warnings"].size(), 1, "warns that the method does not exist yet")
	equal(_code("node_connect_signal", {"path": "Player", "signal": "visibility_changed", "target": "World", "method": "_on_player_visibility_changed"}), "ALREADY_EXISTS", "twice")
	equal(_code("node_connect_signal", {"path": "Player", "signal": "no_such_signal", "target": "World", "method": "x"}), "INVALID_ARGS", "unknown signal")
	equal(_code("node_connect_signal", {"path": "Player", "signal": "visibility_changed", "target": "World", "method": "not valid"}), "INVALID_ARGS", "bad method name")
	_context.undo.undo()
	equal(player.get_signal_connection_list("visibility_changed").size(), 0, "undo disconnects")


func test_node_add_to_group_is_persistent_and_undoable() -> void:
	_scene()
	var world := _root.get_node("World")

	_call("node_add_to_group", {"path": "World", "group": "level"})

	check(world.is_in_group("level"), "in the group")
	equal(_code("node_add_to_group", {"path": "World", "group": "level"}), "ALREADY_EXISTS", "twice")
	equal(_code("node_add_to_group", {"path": "World", "group": "_internal"}), "INVALID_ARGS", "reserved name")
	_context.undo.undo()
	check(not world.is_in_group("level"), "undo removes it")


func test_node_instantiate_scene_adds_an_owned_instance() -> void:
	_scene()

	var reply := _call("node_instantiate_scene", {"parent": "World", "scene": "res://tests/fixtures/main.tscn", "name": "Level"})

	var instance := _root.get_node("World/Level")
	equal(reply["data"]["scene"], "res://tests/fixtures/main.tscn", "reply")
	equal(instance.owner, _root, "instance root is owned")
	equal(instance.scene_file_path, "res://tests/fixtures/main.tscn", "it is an instance, not a copy")
	check(instance.get_node("Player").owner != _root, "its children stay owned by their own scene")
	equal(_code("node_instantiate_scene", {"scene": "res://main.tscn"}), "INVALID_ARGS", "the scene itself")
	equal(_code("node_instantiate_scene", {"scene": "res://tests/fixtures/empty_script.gd"}), "TYPE_MISMATCH", "not a scene")
	equal(_code("node_instantiate_scene", {"scene": "res://missing.tscn"}), "RESOURCE_NOT_FOUND", "missing")
	_context.undo.undo()
	instance.free()


# Adds an instance of the fixture scene: Level (Node2D) with Player and World inside.
func _add_instance() -> Node:
	var instance: Node = load("res://tests/fixtures/main.tscn").instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	instance.name = "Level"
	_add(_root, instance)
	return instance


func test_node_edits_refuse_nodes_inside_an_instanced_scene() -> void:
	_scene()
	_add_instance()

	for command in ["node_delete", "node_duplicate"]:
		equal(_code(command, {"path": "Level/Player"}), "PRECONDITION_FAILED", command)
	equal(_code("node_rename", {"path": "Level/Player", "name": "Hero"}), "PRECONDITION_FAILED", "rename")
	equal(_code("node_move", {"path": "Level/Player", "parent": "World"}), "PRECONDITION_FAILED", "move")
	check(_root.has_node("Level/Player"), "the instance is untouched")
	equal(_code("node_set", {"path": "Level/Player", "properties": {"visible": false}}), "", "overriding a property is fine")


func test_node_duplicate_of_an_instance_keeps_its_inside_out_of_this_scene() -> void:
	_scene()
	var instance := _add_instance()

	_call("node_duplicate", {"path": "Level", "name": "Level2"})

	var copy := _root.get_node("Level2")
	equal(copy.owner, _root, "the copied instance root belongs to this scene")
	check(copy.get_node("Player").owner != _root, "its inner nodes do not")
	check(instance.get_node("Player").owner != _root, "nor do the original's")
	_context.undo.undo()
	copy.free()


func test_node_structure_commands_survive_undo_redo_undo() -> void:
	_scene()
	var player := _root.get_node("Player")
	var sprite := _root.get_node("Player/Sprite")
	var history: RefCounted = _context.undo

	_call("node_delete", {"path": "Player"})
	history.undo()
	history.redo()
	check(not _root.has_node("Player") and player.owner == null, "delete, redone")
	history.undo()
	check(player.get_parent() == _root and player.owner == _root and sprite.owner == _root, "delete, undone twice")

	_call("node_move", {"path": "Player", "parent": "World"})
	history.undo()
	history.redo()
	check(player.get_parent() == _root.get_node("World") and player.owner == _root and sprite.owner == _root, "move, redone")
	history.undo()
	check(player.get_parent() == _root and player.get_index() == 0 and sprite.owner == _root, "move, undone twice")

	_call("node_create", {"type": "Node2D", "name": "Fresh"})
	var fresh := _root.get_node("Fresh")
	history.undo()
	history.redo()
	check(fresh.get_parent() == _root and fresh.owner == _root, "create, redone")
	history.undo()
	check(fresh.get_parent() == null and fresh.owner == null, "create, undone twice")
	fresh.free()

	_call("node_duplicate", {"path": "Player", "name": "Twin"})
	var twin := _root.get_node("Twin")
	history.undo()
	history.redo()
	check(twin.owner == _root and twin.get_node("Sprite").owner == _root, "duplicate, redone")
	history.undo()
	check(twin.get_parent() == null, "duplicate, undone twice")
	twin.free()


func test_node_attach_script_refuses_a_script_for_another_class() -> void:
	_scene()

	# The fixture script extends Node; a Resource-only base would not fit, and
	# a Node2D-only script does not fit a plain Node.
	equal(_code("node_attach_script", {"path": "World", "script": "res://tests/fixtures/node2d_script.gd"}), "TYPE_MISMATCH", "Node2D script on a Node")
	equal(_code("node_attach_script", {"path": "Player", "script": "res://tests/fixtures/node2d_script.gd"}), "", "Node2D script on a Node2D")


func test_node_attach_script_asks_a_person_for_a_tool_script() -> void:
	_scene()

	var reply := _call("node_attach_script", {"path": "Player", "script": "res://gdcli_commands/project_echo.gd"})

	check(reply["ok"] and reply.has("later"), "a tool script waits for a person, however it got into the project")


func test_edit_confirmation_gate_passes_only_with_confirm_or_full_mode() -> void:
	equal(Edit.confirmation_gate({"mode": "standard", "confirm": false, "dry_run": true}, "x"), {}, "a dry run")
	equal(Edit.confirmation_gate({"mode": "standard", "confirm": false}, "x")["error"]["code"], "CONFIRMATION_REQUIRED", "unconfirmed")
	equal(Edit.confirmation_gate({"mode": "standard", "confirm": true}, "x"), {}, "confirmed")
	equal(Edit.confirmation_gate({"mode": "full", "confirm": false}, "x"), {}, "full mode")


func test_node_create_sets_properties_after_the_node_is_in_the_tree() -> void:
	_scene()
	var panel := Control.new()
	panel.name = "Panel"
	panel.size = Vector2(200, 100)
	_add(_root, panel)
	Engine.get_main_loop().root.add_child(_root)

	var reply := _call("node_create", {"type": "ColorRect", "parent": "Panel", "name": "Fill", "properties": {"anchors_preset": 15}})
	var fill: Control = panel.get_node("Fill")

	equal(reply["ok"], true, "created")
	equal(fill.layout_mode, 1, "the layout mode is switched to anchors, as the inspector does")
	equal([fill.anchor_right, fill.anchor_bottom], [1.0, 1.0], "the full-rect preset took effect")


func test_node_set_switches_the_layout_mode_for_an_anchors_preset() -> void:
	_scene()
	var panel := Control.new()
	panel.name = "Panel"
	panel.size = Vector2(200, 100)
	_add(_root, panel)
	var label := Label.new()
	label.name = "Title"
	_add(panel, label)
	Engine.get_main_loop().root.add_child(_root)

	_call("node_set", {"path": "Panel/Title", "properties": {"anchors_preset": 15}})
	var after := [label.layout_mode, label.anchor_right]
	_context.undo.undo()

	equal(after, [1, 1.0], "preset applied")
	equal(label.anchor_right, 0.0, "and undone with the rest")


func test_node_move_keeps_the_node_where_it_is_on_screen() -> void:
	_scene()
	var player: Node2D = _root.get_node("Player")
	var sprite: Node2D = player.get_node("Sprite")
	player.position = Vector2(100, 0)
	sprite.position = Vector2(10, 5)
	Engine.get_main_loop().root.add_child(_root)

	_call("node_move", {"path": "Player/Sprite", "parent": "."})
	var moved := [sprite.get_parent(), sprite.position]
	_context.undo.undo()
	var undone := [sprite.get_parent(), sprite.position]
	_call("node_move", {"path": "Player/Sprite", "parent": ".", "keep_global_transform": false})

	equal(moved, [_root, Vector2(110, 5)], "same place on screen under the new parent")
	equal(undone, [player, Vector2(10, 5)], "undo restores parent and local position")
	equal(sprite.position, Vector2(10, 5), "the local values are kept when asked")


func test_node_attach_script_dry_run_does_not_load_a_tool_script() -> void:
	_scene()
	var path := "res://tests/tmp/dry_tool_%d.gd" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	FileAccess.open(path, FileAccess.WRITE).store_string("@tool\nextends Node2D\n")

	var plan := _call("node_attach_script", {"path": "Player", "script": path}, true)

	equal(plan["ok"], true, "the plan is made")
	equal(plan["data"]["would"].get("runs_in_editor"), true, "and says the script runs in the editor")
	check(not ResourceLoader.has_cached(path), "without loading it, which would run its static code")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
