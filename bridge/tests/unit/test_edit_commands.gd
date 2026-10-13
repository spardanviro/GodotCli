extends "res://tests/suite.gd"
## Scene, file, project and editor-control commands. Anything that would write
## to disk is exercised here only up to the point of writing (validation and
## dry runs); the real writes are covered by scripts/bridge-test.mjs.

const AccessPolicy = preload("res://addons/gdcli/core/access_policy.gd")
const Bridge = preload("res://addons/gdcli/core/bridge.gd")
const EditorControlCommands = preload("res://addons/gdcli/commands/editor_control_commands.gd")
const FsEditCommands = preload("res://addons/gdcli/commands/fs_edit_commands.gd")
const ProjectEditCommands = preload("res://addons/gdcli/commands/project_edit_commands.gd")
const Registry = preload("res://addons/gdcli/core/registry.gd")
const SceneEditCommands = preload("res://addons/gdcli/commands/scene_edit_commands.gd")
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
		ProjectEditCommands.new(_context), EditorControlCommands.new(_context),
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
	return _registry.handler_of(command).call(validated["args"], complete)


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


func test_fs_write_text_treats_sensitive_targets_as_destructive() -> void:
	_setup()

	for path in ["res://project.godot", "res://addons/other/plugin.cfg", "res://gdcli_commands/x.gd", "res://bin/lib.gdextension"]:
		equal(_code("fs_write_text", {"path": path, "text": "x", "overwrite": true}), "CONFIRMATION_REQUIRED", path)
	equal(_code("fs_write_text", {"path": "res://gdcli_commands/x.gd", "text": "x"}, {"mode": "full", "dry_run": true}), "", "full mode does not ask")
	equal(_code("fs_write_text", {"path": "res://addons/gdcli/plugin.gd", "text": "x", "overwrite": true}, {"confirm": true}), "PATH_NOT_ALLOWED", "the bridge itself, even confirmed")
	equal(_code("fs_write_text", {"path": "res://.godot/x", "text": "x"}), "PATH_NOT_ALLOWED", "hidden folder")
	equal(_code("fs_write_text", {"path": "res://tests", "text": "x"}), "INVALID_ARGS", "a folder")
	equal(_code("fs_write_text", {"path": "res://scripts/new.gd", "text": "extends Node\n"}, {"dry_run": true}), "", "an ordinary new script needs no confirmation")


func test_fs_write_text_asks_before_writing_a_tool_script() -> void:
	_setup()
	var tool_script := "# a helper\n@tool\nextends EditorScript\n"

	equal(_code("fs_write_text", {"path": "res://scripts/helper.gd", "text": tool_script}), "CONFIRMATION_REQUIRED", "tool script")
	equal(_code("fs_write_text", {"path": "res://scripts/helper.gd", "text": tool_script}, {"confirm": true, "dry_run": true}), "", "confirmed")
	equal(_code("fs_write_text", {"path": "res://scripts/helper.gd", "text": "extends Node\n# mentions @tool in a comment\n"}, {"dry_run": true}), "", "an ordinary script")
	equal(_code("fs_write_text", {"path": "res://notes/tooling.txt", "text": "@tool\n"}, {"dry_run": true}), "", "not a script file")


func test_fs_write_text_keeps_out_of_git_folders_at_any_depth() -> void:
	_setup()

	equal(_code("fs_write_text", {"path": "res://vendor/lib/.git/config", "text": "x"}), "PATH_NOT_ALLOWED", "nested repository")
	equal(_code("fs_write_text", {"path": "res://vendor/.GIT/hooks/post-checkout", "text": "x"}), "PATH_NOT_ALLOWED", "any case")
	equal(_code("fs_write_text", {"path": "res://vendor/.gitmodules", "text": "x"}), "CONFIRMATION_REQUIRED", "git control file")
	equal(_code("fs_write_text", {"path": "res://.gitignore", "text": "x"}, {"dry_run": true}), "", ".gitignore is an ordinary file")


func test_scene_new_and_resource_set_gate_sensitive_paths() -> void:
	_setup()

	equal(_code("scene_new", {"path": "res://gdcli_commands/a.tscn"}), "CONFIRMATION_REQUIRED", "scene_new into gdcli_commands")
	equal(_code("scene_new", {"path": "res://addons/other/a.tscn"}), "CONFIRMATION_REQUIRED", "scene_new into addons")
	_context.path = "res://addons/other/a.tscn"
	equal(_code("scene_save"), "CONFIRMATION_REQUIRED", "saving a scene that lives under addons")
	_context.path = "res://addons/gdcli/x.tscn"
	equal(_code("scene_save"), "PATH_NOT_ALLOWED", "saving into the bridge itself")


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
	var enabled: Dictionary = JSON.parse_string(bridge.handle(head, body)["body"].get_string_from_utf8())

	equal(disabled["errors"][0]["code"], "EVAL_DISABLED", "off by default")
	equal(enabled["data"], {"result": 1.0}, "runs once enabled and confirmed")


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
