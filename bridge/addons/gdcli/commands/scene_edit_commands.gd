extends RefCounted
## Opening, creating and saving scenes, and stepping through the undo history.

const AccessPolicy = preload("../core/access_policy.gd")
const Edit = preload("../core/edit.gd")
const PathPolicy = preload("../core/path_policy.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")

const _SCENE_EXTENSIONS: Array[String] = ["tscn", "scn"]
const _SENSITIVE := "sensitive location: files here are loaded by the editor or change how the project loads"

var _context: RefCounted


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "scene_open",
		"summary": "Open a scene file in the editor and make it the edited scene.",
		"risk": AccessPolicy.RISK_WRITE,
		"params": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
		"returns": "{scene}. Later commands act on this scene.",
	}, _open)
	registry.register({
		"name": "scene_new",
		"summary": "Create a scene file with a root node and open it.",
		"risk": AccessPolicy.RISK_WRITE,
		"params": {
			"type": "object",
			"properties": {
				"path": {"type": "string", "description": "res:// path ending in .tscn."},
				"root_type": {"type": "string", "description": "Built-in node class of the root.", "default": "Node2D"},
				"root_name": {"type": "string", "description": "Defaults to the file name."},
			},
			"required": ["path"],
		},
		"returns": "{scene, root: {name, type}}",
	}, _new)
	registry.register({
		"name": "scene_save",
		"summary": "Save the edited scene to its file.",
		"risk": AccessPolicy.RISK_WRITE,
		"requires": ["scene_open"],
		"returns": "{scene}",
	}, _save)
	registry.register({
		"name": "edit_undo",
		"summary": "Undo the last change to the edited scene, like Ctrl+Z in the editor.",
		"risk": AccessPolicy.RISK_WRITE,
		"requires": ["scene_open"],
		"returns": "{undone: name of the step}",
	}, _undo)
	registry.register({
		"name": "edit_redo",
		"summary": "Redo the last undone change to the edited scene.",
		"risk": AccessPolicy.RISK_WRITE,
		"requires": ["scene_open"],
		"returns": "{redone: name of the step}",
	}, _redo)


func _scene_path(raw: String) -> Dictionary:
	var checked := PathPolicy.check(raw, PathPolicy.ACCESS_WRITE)
	if checked["ok"] and checked["path"].get_extension().to_lower() not in _SCENE_EXTENSIONS:
		return Reply.fail("INVALID_ARGS", "A scene path ends in .tscn or .scn.", "", {"path": TextSanitizer.clean_line(raw)})
	return checked


func _open(args: Dictionary, options: Dictionary) -> Dictionary:
	var checked := _scene_path(args["path"])
	if not checked["ok"]:
		return checked
	if not FileAccess.file_exists(checked["path"]):
		return Reply.fail("RESOURCE_NOT_FOUND", "The scene file does not exist.", "Create it with scene_new.", {"path": checked["path"]})
	var outside := PathPolicy.refuse_outside_dependency(checked["path"])
	if not outside.is_empty():
		return outside
	if options["dry_run"]:
		return Edit.planned({"open": checked["path"]})
	_context.open_scene(checked["path"])
	if _context.scene_path() != checked["path"]:
		return Reply.fail("COMMAND_FAILED", "The editor did not open the scene.", "The file may be broken; check the editor's output.", {"path": checked["path"]})
	return Reply.ok({"scene": checked["path"]})


func _new(args: Dictionary, options: Dictionary) -> Dictionary:
	var checked := _scene_path(args["path"])
	if not checked["ok"]:
		return checked
	var path: String = checked["path"]
	if FileAccess.file_exists(path):
		return Reply.fail("ALREADY_EXISTS", "A file with this path already exists.", "Open it with scene_open.", {"path": path})
	if checked["sensitive"]:
		var what := {"command": "scene_new", "reason": _SENSITIVE, "target": path}
		var gate := Edit.person_gate(_context, options, what, _new.bind(args, Edit.approved(options)))
		if not gate.is_empty():
			return gate
	var type: String = args["root_type"]
	if not Edit.is_game_node_class(type):
		return Reply.fail("INVALID_ARGS", "Not a built-in node class that can be created.", "", {"root_type": TextSanitizer.clean_line(type)})
	var root_name: String = args.get("root_name", path.get_file().get_basename().to_pascal_case())
	if root_name == "" or root_name.validate_node_name() != root_name:
		return Reply.fail("INVALID_ARGS", "Not a valid node name.", "", {"root_name": TextSanitizer.clean_line(root_name)})
	if options["dry_run"]:
		return Edit.planned({"create": path, "root": {"name": root_name, "type": type}})

	var new_folder := not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var made := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	if made != OK:
		return Reply.fail("COMMAND_FAILED", "The folder for the scene could not be created.", "", {"path": path.get_base_dir()})
	var root: Node = ClassDB.instantiate(type)
	root.name = root_name
	var packed := PackedScene.new()
	var result := packed.pack(root)
	root.free()
	if result == OK:
		result = ResourceSaver.save(packed, path)
	if result != OK:
		return Reply.fail("COMMAND_FAILED", "The scene could not be saved.", "", {"path": path, "error": error_string(result)})
	# The editor ignores a single-file update for a folder it has not seen yet.
	if new_folder:
		_context.scan_files()
	else:
		_context.file_changed(path)
	_context.open_scene(path)
	return Reply.ok({"scene": path, "root": {"name": root_name, "type": type}}, [Edit.NOT_UNDOABLE])


func _save(args: Dictionary, options: Dictionary) -> Dictionary:
	var scene: String = _context.scene_path()
	if scene == "":
		return Reply.fail("PRECONDITION_FAILED", "The edited scene has never been saved and has no path.", "Create scenes with scene_new.")
	# The edited scene may be one the user opened by hand from anywhere.
	var checked := PathPolicy.check(scene, PathPolicy.ACCESS_WRITE)
	if not checked["ok"]:
		return checked
	if checked["sensitive"]:
		var what := {"command": "scene_save", "reason": _SENSITIVE, "target": scene}
		var gate := Edit.person_gate(_context, options, what, _save.bind(args, Edit.approved(options)))
		if not gate.is_empty():
			return gate
	if options["dry_run"]:
		return Edit.planned({"save": scene})
	var result: Error = _context.save_scene()
	if result != OK:
		return Reply.fail("COMMAND_FAILED", "The editor could not save the scene.", "", {"scene": scene, "error": error_string(result)})
	return Reply.ok({"scene": scene})


func _undo(_args: Dictionary, options: Dictionary) -> Dictionary:
	return _step(options, false)


func _redo(_args: Dictionary, options: Dictionary) -> Dictionary:
	return _step(options, true)


func _step(options: Dictionary, forward: bool) -> Dictionary:
	var history: Object = _context.scene_history()
	var available: bool = history.has_redo() if forward else history.has_undo()
	var key := "redone" if forward else "undone"
	if not available:
		return Reply.fail("PRECONDITION_FAILED", "There is nothing to %s in this scene." % ("redo" if forward else "undo"))
	if options["dry_run"]:
		return Edit.planned({key: "next step" if forward else TextSanitizer.clean_line(history.get_current_action_name())})
	# The name of the step being undone is the current one before stepping
	# back; of the step being redone, the current one after stepping forward.
	var name: String = "" if forward else history.get_current_action_name()
	if forward:
		history.redo()
		name = history.get_current_action_name()
	else:
		history.undo()
	return Reply.ok({key: TextSanitizer.clean_line(name)})
