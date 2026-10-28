extends "res://tests/suite.gd"
## Scene, file, project and editor-control commands. Anything that would write
## to disk is exercised here only up to the point of writing (validation and
## dry runs); the real writes are covered by scripts/bridge-test.mjs.

const AccessPolicy = preload("res://addons/gdcli/core/access_policy.gd")
const Approval = preload("res://addons/gdcli/core/approval.gd")
const Bridge = preload("res://addons/gdcli/core/bridge.gd")
const Edit = preload("res://addons/gdcli/core/edit.gd")
const Reply = preload("res://addons/gdcli/core/reply.gd")
const EditorControlCommands = preload("res://addons/gdcli/commands/editor_control_commands.gd")
const FsEditCommands = preload("res://addons/gdcli/commands/fs_edit_commands.gd")
const ProjectEditCommands = preload("res://addons/gdcli/commands/project_edit_commands.gd")
const Registry = preload("res://addons/gdcli/core/registry.gd")
const SceneEditCommands = preload("res://addons/gdcli/commands/scene_edit_commands.gd")
const NodeEditCommands = preload("res://addons/gdcli/commands/node_edit_commands.gd")
const Schema = preload("res://addons/gdcli/core/schema.gd")
const FakeContext = preload("res://tests/fake_context.gd")

const SCENE := "res://tests/fixtures/main.tscn"

var _context: RefCounted
var _registry: RefCounted
var _command_sets: Array = []
var _scene_root: Node


func cleanup() -> void:
	if _scene_root != null:
		_scene_root.free()
		_scene_root = null


func _setup() -> void:
	_context = FakeContext.new()
	_scene_root = Node2D.new()
	_scene_root.name = "Main"
	_context.root = _scene_root
	_context.path = SCENE
	_registry = Registry.new()
	_command_sets = [
		SceneEditCommands.new(_context), FsEditCommands.new(_context),
		ProjectEditCommands.new(_context), EditorControlCommands.new(_context), NodeEditCommands.new(_context),
	]
	for command_set in _command_sets:
		command_set.register(_registry)


func _call(command: String, args: Dictionary = {}, options: Dictionary = {}) -> Dictionary:
	var descriptor: Dictionary = _registry.descriptor_of(command)
	var validated := Schema.validate(args, descriptor["params"])
	if not validated["ok"]:
		return validated
	if descriptor["risk"] == AccessPolicy.RISK_READ:
		return _registry.handler_of(command).call(validated["args"])
	var complete := {"dry_run": false, "confirm": false, "mode": "standard"}
	complete.merge(options, true)
	return _settle(_registry.handler_of(command).call(validated["args"], complete))


# A reply that is still waiting (for a person, for the next frame) is polled
# to its end, the way the HTTP layer does it.
func _settle(reply: Dictionary) -> Dictionary:
	if not (reply["ok"] and reply.has("later")):
		return reply
	for attempt in 50:
		var final: Dictionary = reply["later"].poll()
		if not final.is_empty():
			return final
	return {"ok": false, "error": {"code": "STILL_WAITING"}}


func _code(command: String, args: Dictionary = {}, options: Dictionary = {}) -> String:
	var reply := _call(command, args, options)
	return "" if reply["ok"] else reply["error"]["code"]


func test_scene_open_validates_and_opens() -> void:
	_setup()

	equal(_call("scene_open", {"path": SCENE})["data"], {"scene": SCENE}, "opens an existing scene")
	equal(_context.opened, [SCENE], "through the editor")
	equal(_code("scene_open", {"path": "res://tests/fixtures/notes.txt"}), "INVALID_ARGS", "not a scene extension")
	equal(_code("scene_open", {"path": "res://missing.tscn"}), "RESOURCE_NOT_FOUND", "missing file")
	equal(_code("scene_open", {"path": "res://../x.tscn"}), "PATH_NOT_ALLOWED", "outside the project")


func test_scene_new_plans_and_validates_without_writing() -> void:
	_setup()

	var plan := _call("scene_new", {"path": "res://tests/tmp/level_two.tscn", "root_type": "Node3D"}, {"dry_run": true})

	equal(plan["data"]["would"], {"create": "res://tests/tmp/level_two.tscn", "root": {"name": "LevelTwo", "type": "Node3D"}}, "plan with a name from the file")
	check(not FileAccess.file_exists("res://tests/tmp/level_two.tscn"), "nothing was written")
	equal(_code("scene_new", {"path": SCENE}), "ALREADY_EXISTS", "existing file")
	equal(_code("scene_new", {"path": "res://x.tscn", "root_type": "Resource"}), "INVALID_ARGS", "root that is not a node")
	equal(_code("scene_new", {"path": "res://x.tscn", "root_name": "a/b"}), "INVALID_ARGS", "bad root name")
	equal(_code("scene_new", {"path": "res://addons/gdcli/x.tscn"}), "PATH_NOT_ALLOWED", "inside the bridge")


func test_scene_save_reports_the_editor_result() -> void:
	_setup()

	equal(_call("scene_save")["data"], {"scene": SCENE}, "saved")
	_context.save_result = ERR_FILE_CANT_WRITE
	equal(_code("scene_save"), "COMMAND_FAILED", "editor could not save")
	_context.path = ""
	equal(_code("scene_save"), "PRECONDITION_FAILED", "scene without a file")


func test_edit_undo_and_redo_step_through_the_scene_history() -> void:
	_setup()
	var target := Node2D.new()
	_scene_root.add_child(target)
	_context.undo.create_action("gdcli: node_set Target")
	_context.undo.add_do_property(target, "visible", false)
	_context.undo.add_undo_property(target, "visible", true)
	_context.undo.commit_action()

	equal(_call("edit_undo")["data"], {"undone": "gdcli: node_set Target"}, "names the undone step")
	equal(target.visible, true, "undone")
	equal(_code("edit_undo"), "PRECONDITION_FAILED", "nothing left to undo")
	equal(_call("edit_redo")["data"], {"redone": "gdcli: node_set Target"}, "names the redone step")
	equal(target.visible, false, "redone")
	equal(_code("edit_redo"), "PRECONDITION_FAILED", "nothing left to redo")


func test_fs_write_text_refuses_to_replace_without_asking() -> void:
	_setup()
	var existing := "res://tests/fixtures/notes.txt"

	equal(_code("fs_write_text", {"path": existing, "text": "x"}), "ALREADY_EXISTS", "without overwrite")
	equal(_code("fs_write_text", {"path": existing, "text": "x", "overwrite": true}), "CONFIRMATION_REQUIRED", "overwrite without confirm")
	var plan := _call("fs_write_text", {"path": existing, "text": "héllo", "overwrite": true}, {"dry_run": true})
	equal(plan["data"]["would"], {"write": existing, "bytes": 6, "overwrites": true}, "a dry run needs no confirmation and counts UTF-8 bytes")
	equal(FileAccess.get_file_as_string(existing).strip_edges(), "fixture text for fs_read_text", "file untouched")


func test_fs_write_text_leaves_sensitive_targets_to_a_person() -> void:
	_setup()

	for path in ["res://project.godot", "res://addons/other/plugin.cfg", "res://gdcli_commands/x.gd", "res://bin/lib.gdextension"]:
		# Confirmed by the caller, which settles the overwrite but not the location.
		equal(_code("fs_write_text", {"path": path, "text": "x", "overwrite": true}, {"confirm": true}), "NOT_APPROVED", path)
	equal(_code("fs_write_text", {"path": "res://gdcli_commands/x.gd", "text": "x"}, {"mode": "full", "dry_run": true}), "", "full mode does not ask")
	equal(_code("fs_write_text", {"path": "res://addons/gdcli/plugin.gd", "text": "x", "overwrite": true}, {"confirm": true}), "PATH_NOT_ALLOWED", "the bridge itself, even confirmed")
	equal(_code("fs_write_text", {"path": "res://.godot/x", "text": "x"}), "PATH_NOT_ALLOWED", "hidden folder")
	equal(_code("fs_write_text", {"path": "res://tests", "text": "x"}), "INVALID_ARGS", "a folder")
	equal(_code("fs_write_text", {"path": "res://scripts/new.gd", "text": "extends Node\n"}, {"dry_run": true}), "", "an ordinary new script needs no confirmation")


func test_fs_write_text_asks_before_writing_a_tool_script() -> void:
	_setup()
	var tool_script := "# a helper\n@tool\nextends EditorScript\n"

	equal(_code("fs_write_text", {"path": "res://scripts/helper.gd", "text": tool_script}), "NOT_APPROVED", "tool script")
	equal(_code("fs_write_text", {"path": "res://scripts/helper.gd", "text": tool_script}, {"confirm": true, "dry_run": true}), "", "confirmed")
	equal(_code("fs_write_text", {"path": "res://scripts/helper.gd", "text": "extends Node\n# mentions @tool in a comment\n"}, {"dry_run": true}), "", "an ordinary script")
	equal(_code("fs_write_text", {"path": "res://notes/tooling.txt", "text": "@tool\n"}, {"dry_run": true}), "", "not a script file")


func test_fs_write_text_keeps_out_of_git_folders_at_any_depth() -> void:
	_setup()

	equal(_code("fs_write_text", {"path": "res://vendor/lib/.git/config", "text": "x"}), "PATH_NOT_ALLOWED", "nested repository")
	equal(_code("fs_write_text", {"path": "res://vendor/.GIT/hooks/post-checkout", "text": "x"}), "PATH_NOT_ALLOWED", "any case")
	equal(_code("fs_write_text", {"path": "res://vendor/.gitmodules", "text": "x"}), "NOT_APPROVED", "git control file")
	equal(_code("fs_write_text", {"path": "res://.gitignore", "text": "x"}, {"dry_run": true}), "", ".gitignore is an ordinary file")


func test_scene_new_and_resource_set_gate_sensitive_paths() -> void:
	_setup()

	equal(_code("scene_new", {"path": "res://gdcli_commands/a.tscn"}), "NOT_APPROVED", "scene_new into gdcli_commands")
	equal(_code("scene_new", {"path": "res://addons/other/a.tscn"}), "NOT_APPROVED", "scene_new into addons")
	_context.path = "res://addons/other/a.tscn"
	equal(_code("scene_save"), "NOT_APPROVED", "saving a scene that lives under addons")
	_context.path = "res://addons/gdcli/x.tscn"
	equal(_code("scene_save"), "PATH_NOT_ALLOWED", "saving into the bridge itself")
	equal(_code("resource_create", {"path": "res://addons/other/box.tres", "type": "RectangleShape2D"}), "NOT_APPROVED", "resource_create under addons")
	var box := "res://gdcli_commands/zz_box.tres"
	ResourceSaver.save(RectangleShape2D.new(), box)
	equal(_code("resource_set", {"path": box, "properties": {"size": [4, 4]}}), "NOT_APPROVED", "resource_set in gdcli_commands")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(box))


func test_project_settings_set_asks_for_dotnet_and_main_loop_settings() -> void:
	_setup()

	var dotnet := _code("project_settings_set", {"name": "dotnet/project/assembly_name", "value": "Game"}, {"confirm": true})
	var main_loop := _code("project_settings_set", {"name": "application/run/main_loop_type", "value": "Evil"}, {"confirm": true})

	equal(dotnet, "NOT_APPROVED", "the .NET build reads it")
	equal(main_loop, "NOT_APPROVED", "the main loop class runs first of all")


func test_destructive_dry_run_needs_no_confirmation() -> void:
	_setup()
	var bridge := Bridge.new(_registry, _context, {"instance_id": "0123456789abcdef", "protocol": 1, "bridge_version": "0"}, "token")
	var head := {"method": "POST", "path": "/v1/commands/fs_delete", "query": {}, "headers": {}}
	var args := '"args": {"path": "res://tests/fixtures/notes.txt"}'

	var plain: Dictionary = JSON.parse_string(bridge.handle(head, ("{%s}" % args).to_utf8_buffer())["body"].get_string_from_utf8())
	var dry: Dictionary = JSON.parse_string(bridge.handle(head, ("{%s, \"dry_run\": true}" % args).to_utf8_buffer())["body"].get_string_from_utf8())
	_context.mode = "readonly"
	var readonly: Dictionary = JSON.parse_string(bridge.handle(head, ("{%s, \"dry_run\": true}" % args).to_utf8_buffer())["body"].get_string_from_utf8())

	equal(plain["errors"][0]["code"], "CONFIRMATION_REQUIRED", "the real thing asks")
	equal(dry["data"]["dry_run"], true, "the dry run does not")
	equal(readonly["errors"][0]["code"], "READONLY_MODE", "read-only mode still refuses")
	check(FileAccess.file_exists("res://tests/fixtures/notes.txt"), "nothing was deleted")


func test_fs_move_and_delete_validate_before_touching_anything() -> void:
	_setup()
	var existing := "res://tests/fixtures/notes.txt"

	equal(_code("fs_delete", {"path": "res://missing.txt"}), "RESOURCE_NOT_FOUND", "delete missing")
	equal(_code("fs_delete", {"path": "res://tests/fixtures"}), "RESOURCE_NOT_FOUND", "delete a folder")
	equal(_call("fs_delete", {"path": existing}, {"dry_run": true})["data"]["would"], {"delete": existing}, "delete plan")
	equal(_code("fs_move", {"from": existing, "to": SCENE}), "ALREADY_EXISTS", "destination taken")
	equal(_code("fs_move", {"from": existing, "to": "res://../x.txt"}), "PATH_NOT_ALLOWED", "destination outside")
	equal(_code("fs_move", {"from": "res://missing.txt", "to": "res://x.txt"}), "RESOURCE_NOT_FOUND", "source missing")
	check(FileAccess.file_exists(existing), "the fixture is still there")


func test_fs_move_dry_run_lists_the_references_it_would_update() -> void:
	_setup()
	var user := "res://tests/fixtures/uses_move_target.gd"
	# Put together here so that this file does not itself contain the reference.
	var args := {"from": "res://tests/fixtures/" + "move_target.gd", "to": "res://tests/fixtures/renamed.gd"}
	_context.open = PackedStringArray([user])

	var planned: Dictionary = _call("fs_move", args, {"dry_run": true})["data"]["would"]
	var untouched: Dictionary = _call("fs_move", args.merged({"update_references": false}), {"dry_run": true})["data"]["would"]

	equal(planned["references"]["files"], [user], "the file that preloads the script")
	equal(planned["references"]["open_scenes_saved_and_reloaded"], [user], "open files among them are named")
	equal(untouched["references"]["files"], [], "nothing is searched when updating is off")
	equal(_context.saved_scenes, [] as Array[String], "a dry run saves nothing")
	check(FileAccess.file_exists(args["from"]), "nothing was moved")


func test_fs_write_text_of_the_bus_layout_gives_the_editor_its_buses_at_once() -> void:
	_setup()
	var path := "res://tests/tmp/bus_layout.tres"
	var setting := "audio/buses/default_bus_layout"
	var old_setting: Variant = ProjectSettings.get_setting(setting)
	var old_layout := AudioServer.generate_bus_layout()
	ProjectSettings.set_setting(setting, path)
	var text := "[gd_resource type=\"AudioBusLayout\" format=3]\n\n[resource]\nbus/1/name = &\"TestMusic\"\nbus/1/volume_db = -6.0\nbus/1/send = &\"Master\"\n"

	var written := _call("fs_write_text", {"path": path, "text": text})
	var index := AudioServer.get_bus_index("TestMusic")
	var volume := AudioServer.get_bus_volume_db(index) if index >= 0 else 0.0
	var elsewhere := _call("fs_write_text", {"path": "res://tests/tmp/other_layout.tres", "text": text})

	equal(written["data"].get("bus_layout_loaded"), true, "the reply says so")
	check(index > 0, "the editor has the new bus")
	equal(volume, -6.0, "with its volume")
	check(not elsewhere["data"].has("bus_layout_loaded"), "another .tres is only written")
	# A layout that points at another file is written, not loaded.
	var pointing := "[gd_resource type=\"AudioBusLayout\" load_steps=2 format=3]\n\n[ext_resource type=\"AudioStream\" path=\"res://tests/fixtures/beep.wav\" id=\"1\"]\n\n[resource]\nbus/1/name = &\"TestOther\"\nbus/1/send = &\"Master\"\n"
	var refused := _call("fs_write_text", {"path": path, "text": pointing, "overwrite": true}, {"confirm": true})
	equal(refused["data"].get("bus_layout_loaded"), false, "a layout with an ext_resource is not loaded")
	check(AudioServer.get_bus_index("TestOther") < 0, "and the editor did not get its bus")
	AudioServer.set_bus_layout(old_layout)
	ProjectSettings.set_setting(setting, old_setting)
	for leftover in [path, "res://tests/tmp/other_layout.tres"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(leftover))


func test_fs_write_text_overwrite_in_ask_mode_waits_for_a_person() -> void:
	_setup()
	var path := "res://tests/tmp/overwrite_me.txt"
	_call("fs_write_text", {"path": path, "text": "old\n"})

	var standard := _call("fs_write_text", {"path": path, "text": "new\n", "overwrite": true}, {"confirm": true})
	var asked := _call("fs_write_text", {"path": path, "text": "newer\n", "overwrite": true}, {"confirm": true, "mode": "ask"})

	equal(standard["ok"], true, "standard mode: the caller's yes is enough")
	equal(asked.get("error", {}).get("code"), "NOT_APPROVED", "ask mode: a person decides, and nobody is there")
	equal(FileAccess.get_file_as_string(path), "new\n", "the refused overwrite changed nothing")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_fs_move_refuses_text_that_changed_while_the_person_decided() -> void:
	_setup()
	var notes := "res://tests/tmp/plain_swap.txt"
	var target := "res://tests/tmp/Swap.cs"
	_call("fs_write_text", {"path": notes, "text": "public partial class Swap : Godot.Node {}
"})
	_context.answer = ""
	var args := {"from": notes, "to": target, "update_references": false}
	var waiting: Dictionary = _registry.handler_of("fs_move").call(args, {"dry_run": false, "confirm": false, "mode": "standard"})

	_call("fs_write_text", {"path": notes, "text": "[Tool] public partial class Swap : Godot.Node {}
", "overwrite": true}, {"confirm": true})
	_context.questions[-1].decision = "allowed"
	var reply: Dictionary = waiting["later"].poll()

	equal(reply.get("error", {}).get("code"), "PRECONDITION_FAILED", "what the person allowed is not what would move")
	check(not FileAccess.file_exists(target), "nothing was moved")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(notes))


func test_fs_write_text_ask_mode_overwrite_names_the_strongest_reason() -> void:
	_setup()
	var path := "res://tests/tmp/overwrite_tool.gd"
	_call("fs_write_text", {"path": path, "text": "extends Node
"})

	_call("fs_write_text", {"path": path, "text": "@tool
extends Node
", "overwrite": true}, {"confirm": true, "mode": "ask"})

	check(str(_context.questions[-1].what["reason"]).contains("tool"), "the person is told it runs in the editor, not only that it overwrites")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_fs_move_dry_run_shows_text_that_becomes_csharp() -> void:
	_setup()
	var notes := "res://tests/tmp/plain_for_plan.txt"
	_call("fs_write_text", {"path": notes, "text": "public partial class Plan : Godot.Node {}\n"})

	var plan := _call("fs_move", {"from": notes, "to": "res://tests/tmp/Plan.cs", "update_references": false}, {"dry_run": true})

	equal(plan["data"]["would"].get("becomes_code"), true, "the plan says the text becomes code")
	check(str(plan["data"]["would"].get("text", "")).contains("class Plan"), "and shows it, for the person in ask mode")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(notes))


func test_fs_move_points_the_uid_at_the_new_path_at_once() -> void:
	# A scene loaded again right after the move finds the file by uid; the
	# editor's own scan updates the uid only frames later.
	_setup()
	var from := "res://tests/tmp/uid_probe.gd"
	var to := "res://tests/tmp/moved/uid_probe.gd"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/tmp"))
	FileAccess.open(from, FileAccess.WRITE).store_string("extends Node\n")
	var id := ResourceUID.create_id()
	FileAccess.open(from + ".uid", FileAccess.WRITE).store_string(ResourceUID.id_to_text(id) + "\n")
	ResourceUID.add_id(id, from)

	var moved := _call("fs_move", {"from": from, "to": to, "update_references": false}, {"confirm": true})

	equal(moved["ok"], true, "moved")
	equal(ResourceUID.get_id_path(id), to, "the uid names the new path")
	check(FileAccess.file_exists(to + ".uid"), "the .uid file went along")

	# A .uid file that claims someone else's uid moves nothing but itself.
	var other := ResourceUID.create_id()
	ResourceUID.add_id(other, "res://tests/fixtures/empty_script.gd")
	var claimer := "res://tests/tmp/claimer.gd"
	FileAccess.open(claimer, FileAccess.WRITE).store_string("extends Node\n")
	FileAccess.open(claimer + ".uid", FileAccess.WRITE).store_string(ResourceUID.id_to_text(other) + "\n")
	_call("fs_move", {"from": claimer, "to": "res://tests/tmp/moved/claimer.gd", "update_references": false}, {"confirm": true})
	equal(ResourceUID.get_id_path(other), "res://tests/fixtures/empty_script.gd", "the other resource keeps its uid")

	ResourceUID.remove_id(id)
	ResourceUID.remove_id(other)
	for leftover in [to, to + ".uid", "res://tests/tmp/moved/claimer.gd", "res://tests/tmp/moved/claimer.gd.uid"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(leftover))


func test_fs_move_refuses_folders_and_names_that_cannot_be_moved_safely() -> void:
	_setup()
	var fixtures := "res://tests/fixtures"
	var file := fixtures + "/notes.txt"

	equal(_code("fs_move", {"from": fixtures, "to": fixtures + "/inner"}, {"dry_run": true}), "INVALID_ARGS", "a folder into itself")
	equal(_code("fs_move", {"from": fixtures, "to": "res://tests/Fixtures/inner"}, {"dry_run": true}), "INVALID_ARGS", "in any spelling")
	equal(_code("fs_move", {"from": "res://addons", "to": "res://plugins"}, {"dry_run": true}), "PATH_NOT_ALLOWED", "the folder with the bridge in it")
	equal(_code("fs_move", {"from": "res://", "to": "res://x"}, {"dry_run": true}), "PATH_NOT_ALLOWED", "the project itself")
	equal(_code("fs_move", {"from": file, "to": fixtures + "/a');b.txt"}, {"dry_run": true}), "PATH_NOT_ALLOWED", "a name that would end a string in a script")
	equal(
		_call("fs_move", {"from": file, "to": fixtures + "/a');b.txt", "update_references": false}, {"dry_run": true})["ok"], true,
		"which is fine when nothing is rewritten",
	)
	equal(_call("fs_move", {"from": fixtures, "to": "res://tests/moved"}, {"dry_run": true})["data"]["would"]["folder"], true, "a folder move is planned as one")


func test_resource_create_builds_only_safe_classes() -> void:
	_setup()

	var plan := _call("resource_create", {"path": "res://tests/tmp/box.tres", "type": "RectangleShape2D", "properties": {"size": [8, 8]}}, {"dry_run": true})

	equal(plan["data"]["would"], {"create": "res://tests/tmp/box.tres", "type": "RectangleShape2D"}, "plan")
	equal(_code("resource_create", {"path": "res://x.tres", "type": "GDScript"}), "TYPE_MISMATCH", "a script class")
	equal(_code("resource_create", {"path": "res://x.tres", "type": "RectangleShape2D", "properties": {"size": "big"}}), "TYPE_MISMATCH", "bad property")
	equal(_code("resource_create", {"path": "res://x.txt", "type": "RectangleShape2D"}), "INVALID_ARGS", "wrong extension")
	equal(_code("resource_set", {"path": "res://missing.tres", "properties": {}}), "RESOURCE_NOT_FOUND", "resource_set on a missing file")


func test_project_settings_set_converts_to_the_existing_type() -> void:
	_setup()

	equal(_code("project_settings_set", {"name": "application/config/name", "value": "New Name"}, {"dry_run": true}), "", "string setting")
	equal(_code("project_settings_set", {"name": "application/config/name", "value": 5}), "TYPE_MISMATCH", "wrong type for an existing setting")
	equal(_code("project_settings_set", {"name": "gdcli/access/mode", "value": "full"}), "INVALID_ARGS", "the bridge's own settings")
	equal(_code("project_settings_set", {"name": "input/jump", "value": {}}), "INVALID_ARGS", "input actions have their own command")
	equal(_code("project_settings_set", {"name": "noslash", "value": 1}), "INVALID_ARGS", "not a setting path")
	equal(str(ProjectSettings.get_setting("application/config/name")), "gdcli bridge dev", "nothing was changed")


func test_project_input_map_set_understands_event_descriptions() -> void:
	_setup()
	var events := [{"key": "Space"}, {"mouse_button": 1}, {"joypad_button": 0}, {"joypad_axis": 1, "axis_value": -1}]

	equal(_call("project_input_map_set", {"action": "jump", "events": events}, {"dry_run": true})["data"]["would"], {"action": "jump", "events": 4}, "plan")
	for bad in [{"key": "NotAKey"}, {"mouse_button": -1}, {"mouse_button": 1.5}, {}, {"something": 1}]:
		equal(_code("project_input_map_set", {"action": "jump", "events": [bad]}), "INVALID_ARGS", JSON.stringify(bad))
	equal(_code("project_input_map_set", {"action": "bad/name", "events": []}), "INVALID_ARGS", "action name")
	check(not ProjectSettings.has_setting("input/jump"), "nothing was changed")


func test_editor_play_and_stop_go_through_the_editor() -> void:
	_setup()

	equal(_call("editor_play", {"scene": SCENE})["data"], {"playing": true, "scene": SCENE}, "one scene")
	equal(_context.played, [SCENE], "asked the editor")
	equal(_code("editor_play", {"scene": "res://missing.tscn"}), "RESOURCE_NOT_FOUND", "missing scene")
	equal(_code("editor_play"), "PRECONDITION_FAILED", "no main scene configured")
	equal(_call("editor_stop")["data"], {"playing": false}, "stop")
	equal(_context.stopped, 1, "asked the editor to stop")


func test_editor_screenshot_needs_a_window() -> void:
	_setup()

	equal(_code("editor_screenshot"), "PRECONDITION_FAILED", "headless")
	_context.headless = false
	equal(_call("editor_screenshot")["data"], {"path": "/tmp/shot.png", "width": 4, "height": 3}, "with a window")
	equal(_registry.descriptor_of("editor_screenshot")["risk"], "write", "it writes a file, so read-only mode refuses it")


func test_editor_errors_explains_older_engines() -> void:
	_setup()

	equal(_code("editor_errors"), "UNSUPPORTED_GODOT_VERSION", "no log available")


func test_eval_runs_code_with_the_scene_and_returns_the_result() -> void:
	_setup()
	_context.answer = "allowed"

	var reply := _call("eval", {"code": "var doubled := 21 * 2\nreturn {\"answer\": doubled, \"root\": scene.name}"})

	equal(reply["data"], {"result": {"answer": 42, "root": "Main"}}, "result is encoded")
	check(reply["warnings"][0].contains("undo stack"), "warns that it bypasses undo")
	equal(_call("eval", {"code": "return 1"}, {"dry_run": true})["data"]["dry_run"], true, "dry run runs nothing")
	equal(_code("eval", {"code": "   "}), "INVALID_ARGS", "empty code")


func test_eval_is_refused_by_the_bridge_unless_enabled() -> void:
	_setup()
	var bridge := Bridge.new(_registry, _context, {"instance_id": "0123456789abcdef", "protocol": 1, "bridge_version": "0"}, "token")
	var head := {"method": "POST", "path": "/v1/commands/eval", "query": {}, "headers": {}}
	var body := '{"args": {"code": "return 1"}, "confirm": true}'.to_utf8_buffer()

	var disabled: Dictionary = JSON.parse_string(bridge.handle(head, body)["body"].get_string_from_utf8())
	_context.eval_allowed = true
	var denied: Dictionary = JSON.parse_string(bridge.handle(head, body)["pending"].call()["body"].get_string_from_utf8())
	_context.answer = "allowed"
	var enabled: Dictionary = JSON.parse_string(bridge.handle(head, body)["pending"].call()["body"].get_string_from_utf8())

	equal(disabled["errors"][0]["code"], "EVAL_DISABLED", "off by default")
	equal(denied["errors"][0]["code"], "NOT_APPROVED", "enabled and confirmed by the caller is still not enough")
	equal(_context.questions[0].what["preview"], "return 1", "the person is shown the code")
	equal(enabled["data"], {"result": 1.0}, "runs once a person allows it")


func test_bridge_passes_options_and_reports_the_undo_step() -> void:
	_setup()
	var registry := Registry.new()
	var seen := {}
	registry.register({"name": "probe_write", "summary": "", "risk": "write"}, func(_args: Dictionary, options: Dictionary) -> Dictionary:
		seen.merge(options)
		var reply := {"ok": true, "data": {}, "warnings": [], "undo": "gdcli: probe"}
		return reply)
	var bridge := Bridge.new(registry, _context, {"instance_id": "0123456789abcdef", "protocol": 1, "bridge_version": "0"}, "token")
	var head := {"method": "POST", "path": "/v1/commands/probe_write", "query": {}, "headers": {}}

	var envelope: Dictionary = JSON.parse_string(bridge.handle(head, '{"dry_run": true, "confirm": true}'.to_utf8_buffer())["body"].get_string_from_utf8())

	equal(seen, {"dry_run": true, "confirm": true, "mode": "standard"}, "options reach the handler")
	equal(envelope["meta"]["undo"], "gdcli: probe", "undo step in meta")


func test_host_quit_only_works_for_a_host_started_by_gd() -> void:
	_setup()

	equal(_code("host_quit"), "PRECONDITION_FAILED", "an ordinary editor")
	_context.host = true
	equal(_call("host_quit")["data"], {"quitting": true}, "a gd host")
	check(_context.quit_requested, "quit was requested")


func test_person_gate_asks_for_code_carrying_changes_and_runs_them_only_after_a_yes() -> void:
	_setup()
	var tool_script := "@tool\nextends Node\n"
	var args := {"path": "res://tests/tmp/unit_tool.gd", "text": tool_script}

	var confirmed_by_caller := _code("fs_write_text", args, {"confirm": true})
	_context.has_window = false
	var headless := _call("fs_write_text", args, {"confirm": true})
	_context.has_window = true
	var planned := _call("fs_write_text", args, {"dry_run": true})
	var full := _call("fs_write_text", args, {"mode": "full", "dry_run": true})

	equal(confirmed_by_caller, "NOT_APPROVED", "the caller's own confirm does not replace the person")
	equal(_context.questions.size(), 1, "the person was asked once; a dry run and a missing window ask nobody")
	equal(_context.questions[0].what["target"], args["path"], "and shown the target")
	equal(_context.questions[0].what["preview"], tool_script, "and the content")
	equal(headless["error"]["details"]["reason"], "nobody can be asked: this editor has no window", "a headless editor refuses")
	equal(planned["data"]["dry_run"], true, "a dry run needs nobody")
	equal(full["data"]["dry_run"], true, "full mode needs nobody")


func test_person_gate_covers_autoloads_plugins_and_sensitive_moves() -> void:
	_setup()

	var autoload := _code("project_settings_set", {"name": "autoload/Evil", "value": "*res://evil.gd"}, {"confirm": true})
	var plugins := _code("project_settings_set", {"name": "editor_plugins/enabled", "value": []}, {"confirm": true})
	var ordinary := _call("project_settings_set", {"name": "application/config/description", "value": "x"}, {"confirm": true, "dry_run": true})
	var move := _code("fs_move", {"from": "res://tests/fixtures/notes.txt", "to": "res://addons/other/notes.txt"}, {"confirm": true})

	equal(autoload, "NOT_APPROVED", "adding an autoload")
	equal(plugins, "NOT_APPROVED", "changing the enabled plugins")
	equal(ordinary["data"]["dry_run"], true, "other settings stay with the caller's confirmation")
	equal(move, "NOT_APPROVED", "moving a file into addons")
	check(FileAccess.file_exists("res://tests/fixtures/notes.txt"), "nothing moved")


func test_approval_times_out_withdraws_the_question_and_can_be_abandoned() -> void:
	_setup()
	_context.answer = ""
	var calls := [0]
	var action := func() -> Dictionary:
		calls[0] += 1
		return Reply.ok({"done": true})

	var late := Approval.new(_context, {"command": "x"}, action, -1)
	var timed_out: Dictionary = late.poll()
	var unreadable := Approval.new(_context, {"command": "x", "preview": "x".repeat(60001)}, action)
	var too_long: Dictionary = unreadable.poll()
	_context.questions.clear()
	var waiting := Approval.new(_context, {"command": "x"}, action)
	var first: Dictionary = waiting.poll()
	waiting.abandon()
	var after_abandon: Dictionary = waiting.poll()
	var allowed := Approval.new(_context, {"command": "x"}, action)
	_context.questions[1].decision = "allowed"
	var done: Dictionary = allowed.poll()

	equal(timed_out["error"]["details"]["reason"], "nobody answered in time", "an unanswered question times out")
	equal(too_long["error"]["details"]["reason"], "too long for a person to review", "what cannot be shown in full is not asked at all")
	equal(first, {}, "waits for the person")
	check(_context.questions[0].closed, "a caller that goes away withdraws the question")
	equal(after_abandon["error"]["code"], "NOT_APPROVED", "which counts as a no")
	equal(done["data"], {"done": true}, "a yes runs the change")
	equal(calls[0], 1, "exactly once")


func test_bridge_asks_a_person_for_destructive_commands_in_ask_mode() -> void:
	_setup()
	_context.mode = "ask"
	var bridge := Bridge.new(_registry, _context, {"instance_id": "0123456789abcdef", "protocol": 1, "bridge_version": "0"}, "token")
	var head := {"method": "POST", "path": "/v1/commands/fs_delete", "query": {}, "headers": {}}
	var body := '{"args": {"path": "res://tests/fixtures/notes.txt"}}'.to_utf8_buffer()
	var scan_head := {"method": "POST", "path": "/v1/commands/fs_scan", "query": {}, "headers": {}}
	var missing := '{"args": {"path": "res://tests/fixtures/no_such_file.txt"}}'.to_utf8_buffer()

	var denied: Dictionary = JSON.parse_string(bridge.handle(head, body)["pending"].call()["body"].get_string_from_utf8())
	var ordinary: Dictionary = JSON.parse_string(bridge.handle(scan_head, PackedByteArray())["body"].get_string_from_utf8())
	var hopeless: Dictionary = JSON.parse_string(bridge.handle(head, missing)["body"].get_string_from_utf8())

	equal(denied["errors"][0]["code"], "NOT_APPROVED", "without the caller's confirm, and refused by the person")
	equal(_context.questions[0].what["command"], "fs_delete", "the person is told which command")
	check(_context.questions[0].what["preview"].contains("\"delete\""), "and what it would do, from a dry run")
	equal(ordinary["success"], true, "a write-tier command is not asked about, and is not held back afterwards")
	equal(hopeless["errors"][0]["code"], "RESOURCE_NOT_FOUND", "a request that cannot succeed bothers nobody")
	equal(_context.questions.size(), 1, "one question in all")


func test_edit_runs_in_editor_finds_the_tool_annotation_however_it_is_written() -> void:
	for text in [
		"@tool\nextends Node\n",
		"  @tool\r\nextends Node\r\n",
		"@icon(\"res://i.svg\") @tool\nextends Node\n",
		char(0xfeff) + "@tool\nextends Node\n",
		"[sub_resource type=\"GDScript\" id=\"1\"]\nscript/source = \"@tool\\nextends Node\"\n",
	]:
		check(Edit.runs_in_editor(text), text.c_escape())
	check(not Edit.runs_in_editor("extends Node\n\nvar tools := 3\n# uses a toolbox\n"), "an ordinary script")


func test_edit_runs_in_editor_counts_every_csharp_file() -> void:
	for text in [
		"[Tool]\npublic partial class Hud : Control {}\n",
		"[GlobalClass, Tool]\npublic partial class Hud : Control {}\n",
		"[Godot.Tool()]\npublic partial class Hud : Control {}\n",
		"[ToolAttribute]\npublic partial class Hud : Control {}\n",
		"static class Boot {\n\t[System.Runtime.CompilerServices.ModuleInitializer]\n\tinternal static void Run() {}\n}\n",
		"[GlobalClass,\n Tool]\npublic partial class Hud : Control {}\n",
		"[Icon(new[] { 1 }), global::Godot.ToolAttribute]\npublic partial class Hud : Control {}\n",
		"[T\\u006fol]\npublic partial class Hud : Control {}\n",
		"// was: [Tool]\npublic partial class Hud : Control {}\n",
	]:
		check(Edit.runs_in_editor(text, "cs"), text.c_escape())
	# An exported field's initializer runs in the editor too (scripts/dotnet-probe.mjs).
	check(Edit.runs_in_editor("public partial class Player : CharacterBody2D\n{\n\t[Export] public float Speed = 3;\n}\n", "cs"), "an ordinary class")
	check(Edit.runs_in_editor("", "CS"), "the extension in any case, whatever the text")
	check(not Edit.runs_in_editor("[node name=\"Tool\" type=\"Node\"]\n", "tscn"), "the same word in a file that is not C#")


func test_fs_write_text_asks_before_writing_any_csharp() -> void:
	_setup()

	equal(_code("fs_write_text", {"path": "res://tests/tmp/Hud.cs", "text": "[Tool]\npublic partial class Hud : Godot.Control {}\n"}), "NOT_APPROVED", "a tool class")
	equal(_code("fs_write_text", {"path": "res://tests/tmp/Player.cs", "text": "public partial class Player : Godot.Node {}\n"}), "NOT_APPROVED", "an ordinary class")
	check(not FileAccess.file_exists("res://tests/tmp/Player.cs"), "nothing was written")


func test_fs_move_asks_when_a_rename_turns_text_into_csharp() -> void:
	_setup()
	var notes := "res://tests/tmp/hud_notes.txt"
	_call("fs_write_text", {"path": notes, "text": "[Tool]\npublic partial class Hud : Godot.Control {}\n"})
	var plain := "res://tests/tmp/plain_notes.txt"
	_call("fs_write_text", {"path": plain, "text": "public partial class Player : Godot.Node {}\n"})

	var renamed := _code("fs_move", {"from": notes, "to": "res://tests/tmp/Hud.cs", "update_references": false}, {"confirm": true})
	var plain_renamed := _code("fs_move", {"from": plain, "to": "res://tests/tmp/Player.cs", "update_references": false}, {"confirm": true})
	var harmless := _code("fs_move", {"from": plain, "to": "res://tests/tmp/plain_notes_2.txt", "update_references": false}, {"confirm": true})

	equal(renamed, "NOT_APPROVED", "a tool class that arrives by being renamed")
	check(FileAccess.file_exists(notes), "is still where it was")
	equal(plain_renamed, "NOT_APPROVED", "an ordinary class that arrives by being renamed")
	equal(harmless, "", "text renamed to other text")
	for leftover in [notes, plain, "res://tests/tmp/plain_notes_2.txt"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(leftover))


func test_fs_write_text_asks_for_tool_code_in_any_file_and_refuses_binary_resources() -> void:
	_setup()
	# The annotation spelled with an escape, which the text parser undoes.
	var escaped := "[gd_resource type=\"Resource\" load_steps=2 format=3]\n[sub_resource type=\"GDScript\" id=\"1\"]\nscript/source = \"@\\u0074ool\\nextends Resource\"\n[resource]\nscript = SubResource(\"1\")\n"
	equal(_code("fs_write_text", {"path": "res://tests/tmp/escaped.tres", "text": escaped}), "NOT_APPROVED", "an embedded script, whatever it spells")
	var embedded := "[gd_scene format=3]\n[sub_resource type=\"GDScript\" id=\"1\"]\nscript/source = \"@tool\\nextends Node\"\n"

	equal(_code("fs_write_text", {"path": "res://tests/tmp/carrier.tscn", "text": embedded}), "NOT_APPROVED", "a scene with a tool script inside")
	equal(_code("fs_write_text", {"path": "res://tests/tmp/x.gd", "text": "@icon(\"res://i.svg\") @tool\nextends Node\n"}), "NOT_APPROVED", "the annotation after another one")
	equal(_code("fs_write_text", {"path": "res://tests/tmp/x.scn", "text": "RSRC"}), "INVALID_ARGS", "a binary scene")
	equal(_code("fs_write_text", {"path": "res://tests/tmp/Game.csproj", "text": "<Project/>"}), "NOT_APPROVED", "a build file")
	equal(_code("project_settings_set", {"name": "application/config/project_settings_override", "value": "res://o.cfg"}, {"confirm": true}), "NOT_APPROVED", "a setting that pulls in another settings file")


func test_bridge_runs_an_asked_command_once_after_a_yes_and_frees_the_editor_again() -> void:
	_setup()
	_context.mode = "ask"
	_context.answer = "allowed"
	var runs := [0]
	_registry.register({"name": "probe_delete", "summary": "", "risk": AccessPolicy.RISK_DESTRUCTIVE},
		func(_args: Dictionary, options: Dictionary) -> Dictionary:
			if options["dry_run"]:
				return Reply.ok({"dry_run": true, "would": {"delete": "everything"}})
			runs[0] += 1
			return Reply.ok({"deleted": true}))
	var bridge := Bridge.new(_registry, _context, {"instance_id": "0123456789abcdef", "protocol": 1, "bridge_version": "0"}, "token")
	var head := {"method": "POST", "path": "/v1/commands/probe_delete", "query": {}, "headers": {}}
	var scan_head := {"method": "POST", "path": "/v1/commands/fs_scan", "query": {}, "headers": {}}

	var done: Dictionary = JSON.parse_string(bridge.handle(head, PackedByteArray())["pending"].call()["body"].get_string_from_utf8())
	var afterwards: Dictionary = JSON.parse_string(bridge.handle(scan_head, PackedByteArray())["body"].get_string_from_utf8())

	equal(done["data"], {"deleted": true}, "allowed by the person, with no confirm from the caller")
	equal(runs[0], 1, "the real run happened once; the rehearsal was dry")
	check(_context.questions[0].what["preview"].contains("everything"), "the person saw what the dry run reported")
	equal(afterwards["success"], true, "other changes are accepted again")


func test_fs_write_text_compile_check_reports_without_refusing() -> void:
	_setup()
	var commands: RefCounted = _command_sets[1]

	var good: Dictionary = commands._compile("class_name Hero\nextends Node\n\nvar speed := 3.0\n")
	var bad: Dictionary = commands._compile("extends Node\n\nvar speed: int = \"fast\"\n")

	var loads: Dictionary = commands._compile("extends Node\n\nconst Other = preload(\"res://tests/fixtures/empty_script.gd\")\n")
	var by_path: Dictionary = commands._compile("extends \"res://tests/fixtures/empty_script.gd\"\n")
	var own_name: Dictionary = commands._compile("class_name Hero\nextends Node\n\nstatic func make() -> Hero:\n\treturn null\n")

	equal(good, {"compiles": true}, "a script that compiles, class name and all")
	equal(bad["compiles"], false, "a type error is found without running or loading the file")
	check(loads.has("skipped") and by_path.has("skipped"), "a script that would make the compiler load other files is not compiled")
	check(own_name.has("skipped"), "nor one that needs its own class name to be known")


func test_a_scene_that_uses_a_script_outside_the_project_is_neither_written_nor_loaded() -> void:
	_setup()
	var outside := OS.get_user_data_dir().path_join("gdcli_outside_probe.gd")
	FileAccess.open(outside, FileAccess.WRITE).store_string("@tool\nextends Node\n")
	var text := '[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Script" path="%s" id="1"]\n\n[node name="Main" type="Node"]\nscript = ExtResource("1")\n' % outside
	var planted := "res://tests/tmp/planted_outside.tscn"
	# Written behind the bridge's back, as an agent's own file tools could.
	FileAccess.open(planted, FileAccess.WRITE).store_string(text)

	var written := _code("fs_write_text", {"path": "res://tests/tmp/outside.tscn", "text": text})
	var opened := _code("scene_open", {"path": planted})
	var instanced := _code("node_instantiate_scene", {"parent": ".", "scene": planted})

	equal(written, "PATH_NOT_ALLOWED", "writing it is refused, approval or not")
	equal(opened, "PATH_NOT_ALLOWED", "opening one that is already there is refused")
	equal(instanced, "PATH_NOT_ALLOWED", "and so is instancing it")
	check(not FileAccess.file_exists("res://tests/tmp/outside.tscn"), "nothing was written")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(planted))
	DirAccess.remove_absolute(outside)


func test_text_that_uses_outside_files_cannot_become_a_resource_by_a_rename_or_another_extension() -> void:
	_setup()
	var text := '[gd_resource type="Resource" format=3]\n\n[ext_resource type="Script" path="C:/elsewhere/evil.gd" id="1"]\n\n[resource]\nscript = ExtResource("1")\n'
	var notes := "res://tests/tmp/innocent_notes.txt"
	# Through the bridge even a .txt with this text is refused (its first line makes it a resource),
	var written := _code("fs_write_text", {"path": notes, "text": text})
	# so it is planted the way an agent's own file tools could.
	FileAccess.open(notes, FileAccess.WRITE).store_string(text)

	var moved := _code("fs_move", {"from": notes, "to": "res://tests/tmp/innocent.tres", "update_references": false}, {"confirm": true})
	var material := _code("fs_write_text", {"path": "res://tests/tmp/stone.material", "text": text})

	equal(written, "PATH_NOT_ALLOWED", "a resource's text is judged by what it is, not by its extension")
	equal(moved, "PATH_NOT_ALLOWED", "renaming it into a resource is refused")
	equal(material, "PATH_NOT_ALLOWED", "so is writing it under a resource extension the list does not name")
	check(not FileAccess.file_exists("res://tests/tmp/innocent.tres"), "nothing was moved")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(notes))


func test_project_input_map_set_reads_modifiers_as_modifiers() -> void:
	_setup()
	var commands := ProjectEditCommands.new(_context)

	var save: InputEventKey = commands._event_from({"key": "Ctrl+S"})
	var nothing: Variant = commands._event_from({"key": "Ctrl+Foo"})
	var plain: InputEventKey = commands._event_from({"key": "Space"})
	var plus: InputEventKey = commands._event_from({"key": "+"})
	var zoom: InputEventKey = commands._event_from({"key": "Ctrl++"})

	equal([save.physical_keycode, save.ctrl_pressed], [KEY_S, true], "S with Ctrl held, on every engine version")
	equal(nothing, null, "modifiers alone name no key")
	equal([plain.physical_keycode, plain.ctrl_pressed], [KEY_SPACE, false], "a plain key is unchanged")
	equal([plus.physical_keycode, plus.ctrl_pressed], [KEY_PLUS, false], "the plus key alone")
	equal([zoom.physical_keycode, zoom.ctrl_pressed], [KEY_PLUS, true], "the plus key with Ctrl held")


func test_resource_set_on_a_state_machine_resource_asks_a_person() -> void:
	_setup()
	var machine := AnimationNodeStateMachine.new()
	var path := "res://tests/tmp/machine.tres"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/tmp"))
	ResourceSaver.save(machine, path)

	var reply := _code("resource_set", {"path": path, "properties": {"transitions": []}})

	equal(reply, "NOT_APPROVED", "it may be an active tree's root: a person decides")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_an_approval_does_not_outlast_a_switch_to_read_only() -> void:
	_setup()
	_context.answer = ""
	var args := {"path": "res://addons/other/late.gd", "text": "extends Node\n"}
	var waiting: Dictionary = _registry.handler_of("fs_write_text").call(args, {"dry_run": false, "confirm": false, "mode": "standard"})

	_context.mode = "readonly"
	_context.questions[-1].decision = "allowed"
	var reply: Dictionary = waiting["later"].poll()

	equal(reply.get("error", {}).get("code"), "READONLY_MODE", "the editor became read-only while the person decided")
	check(not FileAccess.file_exists("res://addons/other/late.gd"), "nothing was written")


func test_fs_move_renames_a_file_by_its_case_alone() -> void:
	_setup()
	var lower := "res://tests/tmp/case_probe.txt"
	_call("fs_write_text", {"path": lower, "text": "x"})

	var reply := _code("fs_move", {"from": lower, "to": "res://tests/tmp/Case_Probe.txt", "update_references": false}, {"confirm": true})

	equal(reply, "", "a rename that changes only the case is not 'already exists'")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://tests/tmp/Case_Probe.txt"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(lower))


func test_fs_move_tells_the_file_itself_from_another_of_the_new_name() -> void:
	_setup()
	var path := "res://tests/tmp/listed_probe.txt"
	_call("fs_write_text", {"path": path, "text": "x"})

	var itself := FsEditCommands._listed_exactly(path)
	var other_case := FsEditCommands._listed_exactly("res://tests/tmp/Listed_Probe.txt")

	equal([itself, other_case], [true, false], "only an entry of exactly that name is another file")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_fs_edit_text_replaces_parts_of_a_script() -> void:
	_setup()
	var path := "res://tests/tmp/edit_probe.gd"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/tmp"))
	FileAccess.open(path, FileAccess.WRITE).store_string("extends Node\n\nconst SPEED := 100.0\n\n\nfunc _ready() -> void:\n\tprint(SPEED)\n")

	var reply := _call("fs_edit_text", {"path": path, "edits": [
		{"old": "SPEED := 100.0", "new": "SPEED := 250.0"},
		{"old": "\tprint(SPEED)", "new": "\tprint(\"speed \", SPEED)"},
	]})
	var after := FileAccess.get_file_as_string(path)

	check(reply["ok"], "edited: %s" % reply)
	equal(reply["data"].get("edits"), 2, "both applied")
	check(after.contains("SPEED := 250.0") and after.contains("print(\"speed \", SPEED)") and after.begins_with("extends Node"), "the rest is as it was: %s" % after)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_fs_edit_text_refuses_an_edit_it_cannot_place() -> void:
	_setup()
	var path := "res://tests/tmp/edit_probe2.gd"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/tmp"))
	FileAccess.open(path, FileAccess.WRITE).store_string("extends Node\nvar a := 1\nvar b := 1\n")

	equal(_code("fs_edit_text", {"path": path, "edits": [{"old": ":= 1", "new": ":= 2"}]}), "INVALID_ARGS", "found twice")
	equal(_code("fs_edit_text", {"path": path, "edits": [{"old": "var c", "new": "var d"}]}), "INVALID_ARGS", "not found")
	equal(_code("fs_edit_text", {"path": path, "edits": [{"old": "", "new": "x"}]}), "INVALID_ARGS", "empty old text")
	equal(_code("fs_edit_text", {"path": "res://tests/tmp/none.gd", "edits": [{"old": "a", "new": "b"}]}), "RESOURCE_NOT_FOUND", "no file")
	equal(FileAccess.get_file_as_string(path), "extends Node\nvar a := 1\nvar b := 1\n", "the file was not touched")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_fs_edit_text_that_makes_a_tool_script_asks_a_person() -> void:
	_setup()
	_context.answer = "denied"
	var path := "res://tests/tmp/edit_probe3.gd"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/tmp"))
	FileAccess.open(path, FileAccess.WRITE).store_string("extends Node\n")

	var reply := _call("fs_edit_text", {"path": path, "edits": [{"old": "extends Node", "new": "@tool\nextends Node"}]})

	equal(reply.get("error", {}).get("code"), "NOT_APPROVED", "the new whole text is what the person judges")
	equal(FileAccess.get_file_as_string(path), "extends Node\n", "nothing written")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_fs_edit_text_keeps_windows_line_ends_and_refuses_text_that_is_not_utf8() -> void:
	_setup()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/tmp"))
	var windows := "res://tests/tmp/edit_crlf.gd"
	FileAccess.open(windows, FileAccess.WRITE).store_string("extends Node\r\nvar a := 1\r\nvar b := 2\r\n")
	var latin := "res://tests/tmp/edit_latin.gd"
	var bytes := "extends Node\n# caf".to_utf8_buffer()
	bytes.append(0xE9)
	bytes.append_array("\nvar a := 1\n".to_utf8_buffer())
	FileAccess.open(latin, FileAccess.WRITE).store_buffer(bytes)

	var edited := _call("fs_edit_text", {"path": windows, "edits": [{"old": "var a := 1\nvar b", "new": "var a := 5\nvar b"}]})
	var refused := _code("fs_edit_text", {"path": latin, "edits": [{"old": "var a := 1", "new": "var a := 2"}]})

	check(edited["ok"], "found with \\n: %s" % edited)
	equal(FileAccess.get_file_as_string(windows), "extends Node\r\nvar a := 5\r\nvar b := 2\r\n", "Windows line ends kept")
	equal(refused, "INVALID_ARGS", "a file that is not UTF-8 is not edited")
	equal(FileAccess.get_file_as_bytes(latin), bytes, "and not touched")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(windows))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(latin))


func test_input_events_are_described_in_english_whatever_the_editor_language() -> void:
	var InputText = load("res://addons/gdcli/core/input_text.gd")
	var save := InputEventKey.new()
	save.keycode = KEY_S
	save.ctrl_pressed = true
	var physical := InputEventKey.new()
	physical.physical_keycode = KEY_W
	var stick := InputEventJoypadMotion.new()
	stick.axis = JOY_AXIS_LEFT_X
	stick.axis_value = -1.0

	equal([InputText.describe(save), InputText.describe(physical), InputText.describe(stick)], ["Ctrl+S", "W (physical)", "Joypad axis 0 -"], "fixed words")
