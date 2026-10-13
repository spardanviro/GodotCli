extends RefCounted
## Writing, moving and deleting project files, and creating resources.

const AccessPolicy = preload("../core/access_policy.gd")
const Edit = preload("../core/edit.gd")
const PathPolicy = preload("../core/path_policy.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")
const ValueDecoder = preload("../core/value_decoder.gd")

const _RESOURCE_EXTENSIONS: Array[String] = ["tres", "res"]
const _SENSITIVE := "sensitive path"
const _OVERWRITE := "overwrites an existing file"
const _TOOL_SCRIPT := "tool script, runs inside the editor"
const _TOOL_PATTERN := "(?m)^[ \\t]*@tool\\b"

var _context: RefCounted


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "fs_write_text",
		"summary": "Write a text file in the project, such as a script.",
		"risk": AccessPolicy.RISK_WRITE,
		"params": {
			"type": "object",
			"properties": {
				"path": {"type": "string"},
				"text": {"type": "string"},
				"overwrite": {"type": "boolean", "default": false, "description": "Replace an existing file; needs confirmation."},
			},
			"required": ["path", "text"],
		},
		"returns": "{path, bytes, created}. Not undoable.",
	}, _write_text)
	registry.register({
		"name": "fs_scan",
		"summary": "Make the editor notice files changed outside it.",
		"risk": AccessPolicy.RISK_WRITE,
		"returns": "{scanning}",
	}, _scan)
	registry.register({
		"name": "fs_delete",
		"summary": "Move a project file to the system's recycle bin.",
		"risk": AccessPolicy.RISK_DESTRUCTIVE,
		"params": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
		"returns": "{path}. Recoverable from the recycle bin, not from the editor.",
	}, _delete)
	registry.register({
		"name": "fs_move",
		"summary": "Move or rename a project file. References to it in other files are not updated.",
		"risk": AccessPolicy.RISK_DESTRUCTIVE,
		"params": {
			"type": "object",
			"properties": {"from": {"type": "string"}, "to": {"type": "string"}},
			"required": ["from", "to"],
		},
		"returns": "{from, to}",
	}, _move)
	registry.register({
		"name": "resource_create",
		"summary": "Create a resource file of a built-in class, e.g. a RectangleShape2D or a Theme.",
		"risk": AccessPolicy.RISK_WRITE,
		"params": {
			"type": "object",
			"properties": {
				"path": {"type": "string", "description": "res:// path ending in .tres."},
				"type": {"type": "string", "description": "Built-in Resource class."},
				"properties": {"type": "object"},
			},
			"required": ["path", "type"],
		},
		"returns": "{path, type}. Not undoable.",
	}, _resource_create)
	registry.register({
		"name": "resource_set",
		"summary": "Set properties of a resource file and save it.",
		"risk": AccessPolicy.RISK_WRITE,
		"params": {
			"type": "object",
			"properties": {"path": {"type": "string"}, "properties": {"type": "object"}},
			"required": ["path", "properties"],
		},
		"returns": "{path, set}. Not undoable.",
	}, _resource_set)


func _write_text(args: Dictionary, options: Dictionary) -> Dictionary:
	var checked := PathPolicy.check(args["path"], PathPolicy.ACCESS_WRITE)
	if not checked["ok"]:
		return checked
	var path: String = checked["path"]
	if path == PathPolicy.ROOT or DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)):
		return Reply.fail("INVALID_ARGS", "The path names a folder.", "", {"path": path})
	var exists := FileAccess.file_exists(path)
	if exists and not args["overwrite"]:
		return Reply.fail("ALREADY_EXISTS", "The file already exists.", "Pass overwrite to replace it.", {"path": path})
	# Overwriting loses the old content; sensitive files change how the
	# project or the editor loads. Both need an explicit yes.
	if exists or checked["sensitive"]:
		var gate := Edit.confirmation_gate(options, _OVERWRITE if exists else _SENSITIVE)
		if not gate.is_empty():
			return gate
	# An ordinary script runs when the game runs. A tool script runs inside
	# the editor as soon as something loads it, with everything the editor
	# can do, so writing one is confirmed like other sensitive changes.
	if path.get_extension().to_lower() == "gd" and _is_tool_script(args["text"]):
		var tool_gate := Edit.confirmation_gate(options, _TOOL_SCRIPT)
		if not tool_gate.is_empty():
			return tool_gate
	var bytes: PackedByteArray = args["text"].to_utf8_buffer()
	if options["dry_run"]:
		return Edit.planned({"write": path, "bytes": bytes.size(), "overwrites": exists})

	var new_folder := not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var made := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE) if made == OK else null
	if file == null:
		return Reply.fail("COMMAND_FAILED", "The file could not be written.", "", {"path": path})
	file.store_buffer(bytes)
	file.close()
	_announce(path, new_folder)
	return Reply.ok({"path": path, "bytes": bytes.size(), "created": not exists}, [Edit.NOT_UNDOABLE])


# The editor ignores a single-file update for a folder it has not seen yet.
func _announce(path: String, new_folder: bool) -> void:
	if new_folder:
		_context.scan_files()
	else:
		_context.file_changed(path)


# Godot keeps a file's identity and import settings in files next to it.
const _SIDECARS: Array[String] = [".uid", ".import"]


func _is_tool_script(text: String) -> bool:
	return RegEx.create_from_string(_TOOL_PATTERN).search(text) != null


func _scan(_args: Dictionary, options: Dictionary) -> Dictionary:
	if options["dry_run"]:
		return Edit.planned({"scan": PathPolicy.ROOT})
	_context.scan_files()
	return Reply.ok({"scanning": true})


func _existing_file(raw: String) -> Dictionary:
	var checked := PathPolicy.check(raw, PathPolicy.ACCESS_WRITE)
	if checked["ok"] and not FileAccess.file_exists(checked["path"]):
		return Reply.fail("RESOURCE_NOT_FOUND", "The file does not exist.", "Folders are not handled by this command.", {"path": checked["path"]})
	return checked


func _delete(args: Dictionary, options: Dictionary) -> Dictionary:
	var checked := _existing_file(args["path"])
	if not checked["ok"]:
		return checked
	var path: String = checked["path"]
	if options["dry_run"]:
		return Edit.planned({"delete": path})
	# The recycle bin, not an unlink: the user can get the file back.
	var result := OS.move_to_trash(ProjectSettings.globalize_path(path))
	if result != OK:
		return Reply.fail("COMMAND_FAILED", "The file could not be moved to the recycle bin.", "", {"path": path, "error": error_string(result)})
	for suffix in _SIDECARS:
		if FileAccess.file_exists(path + suffix):
			OS.move_to_trash(ProjectSettings.globalize_path(path + suffix))
	_context.scan_files()
	return Reply.ok({"path": path}, [Edit.NOT_UNDOABLE])


func _move(args: Dictionary, options: Dictionary) -> Dictionary:
	var source := _existing_file(args["from"])
	if not source["ok"]:
		return source
	var target := PathPolicy.check(args["to"], PathPolicy.ACCESS_WRITE)
	if not target["ok"]:
		return target
	var from: String = source["path"]
	var to: String = target["path"]
	if FileAccess.file_exists(to) or DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(to)):
		return Reply.fail("ALREADY_EXISTS", "Something already exists at the destination.", "", {"to": to})
	if options["dry_run"]:
		return Edit.planned({"move": from, "to": to})

	var made := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(to.get_base_dir()))
	var result := DirAccess.rename_absolute(ProjectSettings.globalize_path(from), ProjectSettings.globalize_path(to)) if made == OK else made
	if result != OK:
		return Reply.fail("COMMAND_FAILED", "The file could not be moved.", "", {"from": from, "to": to, "error": error_string(result)})
	# Without its .uid the file would get a new identity and uid:// references break.
	for suffix in _SIDECARS:
		if FileAccess.file_exists(from + suffix):
			DirAccess.rename_absolute(ProjectSettings.globalize_path(from + suffix), ProjectSettings.globalize_path(to + suffix))
	_context.scan_files()
	return Reply.ok({"from": from, "to": to}, [Edit.NOT_UNDOABLE, "Other files that refer to the old path were not changed."])


func _resource_path(raw: String) -> Dictionary:
	var checked := PathPolicy.check(raw, PathPolicy.ACCESS_WRITE)
	if checked["ok"] and checked["path"].get_extension().to_lower() not in _RESOURCE_EXTENSIONS:
		return Reply.fail("INVALID_ARGS", "A resource path ends in .tres or .res.", "", {"path": TextSanitizer.clean_line(raw)})
	return checked


func _resource_create(args: Dictionary, options: Dictionary) -> Dictionary:
	var checked := _resource_path(args["path"])
	if not checked["ok"]:
		return checked
	var path: String = checked["path"]
	if FileAccess.file_exists(path):
		return Reply.fail("ALREADY_EXISTS", "The file already exists.", "Change it with resource_set.", {"path": path})
	if checked["sensitive"]:
		var gate := Edit.confirmation_gate(options, _SENSITIVE)
		if not gate.is_empty():
			return gate
	# The decoder applies the rule that only built-in, code-free classes are built.
	var decoded: Dictionary = ValueDecoder.new(_context.scene_root()).decode(
		{"$new": args["type"], "properties": args.get("properties", {})}, TYPE_OBJECT
	)
	if not decoded["ok"]:
		return decoded
	if options["dry_run"]:
		return Edit.planned({"create": path, "type": args["type"]})

	var new_folder := not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var made := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var result := ResourceSaver.save(decoded["value"], path) if made == OK else made
	if result != OK:
		return Reply.fail("COMMAND_FAILED", "The resource could not be saved.", "", {"path": path, "error": error_string(result)})
	_announce(path, new_folder)
	return Reply.ok({"path": path, "type": decoded["value"].get_class()}, [Edit.NOT_UNDOABLE])


func _resource_set(args: Dictionary, options: Dictionary) -> Dictionary:
	var checked := _resource_path(args["path"])
	if not checked["ok"]:
		return checked
	var path: String = checked["path"]
	if not ResourceLoader.exists(path):
		return Reply.fail("RESOURCE_NOT_FOUND", "The resource does not exist.", "Create it with resource_create.", {"path": path})
	var resource := ResourceLoader.load(path)
	if resource == null or resource is Script or resource is PackedScene:
		return Reply.fail("TYPE_MISMATCH", "This file is not a plain resource.", "Scripts are written with fs_write_text; scenes are edited with the node commands.", {"path": path})
	if checked["sensitive"]:
		var gate := Edit.confirmation_gate(options, _SENSITIVE)
		if not gate.is_empty():
			return gate
	var properties: Dictionary = args["properties"]
	var decoded: Dictionary = ValueDecoder.new(_context.scene_root()).decode_properties(resource, properties)
	if not decoded["ok"]:
		return decoded
	if options["dry_run"]:
		return Edit.planned({"set": properties.keys(), "on": path})

	for name in decoded["values"]:
		resource.set(name, decoded["values"][name])
	var result := ResourceSaver.save(resource, path)
	if result != OK:
		return Reply.fail("COMMAND_FAILED", "The resource could not be saved.", "", {"path": path, "error": error_string(result)})
	_context.file_changed(path)
	return Reply.ok({"path": path, "set": properties.keys()}, [Edit.NOT_UNDOABLE])
