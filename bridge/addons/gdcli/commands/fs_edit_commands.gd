extends RefCounted
## Writing, moving and deleting project files, and creating resources.

const AccessPolicy = preload("../core/access_policy.gd")
const Edit = preload("../core/edit.gd")
const FileMove = preload("../core/file_move.gd")
const PathPolicy = preload("../core/path_policy.gd")
const Reply = preload("../core/reply.gd")
const ReferenceUpdater = preload("../core/reference_updater.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")
const ValueDecoder = preload("../core/value_decoder.gd")

const _RESOURCE_EXTENSIONS: Array[String] = ["tres", "res"]
const _SENSITIVE := "sensitive location: files here are loaded by the editor or change how the project loads"
const _OVERWRITE := "overwrites an existing file"
const _TOOL_SCRIPT := "tool script: it runs inside the editor as soon as it is loaded"
const _CSHARP := "C# file: once built, the editor runs part of any C# class (field initializers), not only [Tool] ones"
const _UNSAFE_IN_REFERENCES: Array[String] = ["\"", "'", ";", "%", "{", "}", "(", ")", "#", "$"]
# Binary scene and resource files can carry a script and cannot be reviewed.
const _SCRIPT_EXTENSION := "gd"
const _CLASS_NAME_PATTERN := "(?m)^[ \\t]*class_name[ \\t]+(\\w+)[ \\t]*"
const _LOADS_PATTERN := "\\bpreload\\s*\\(|(?m)^[ \\t]*(?:class_name[ \\t]+\\w+[ \\t]+)?extends[ \\t]+[\"']"
const _ANONYMOUS_SCRIPT := "gdscript://"
const _BINARY_EXTENSIONS: Array[String] = ["scn", "res"]

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
		"returns": "{path, bytes, created, check?: {compiles, errors?} or {skipped}}. A script that is not a tool script is compiled after writing; it is written even when it does not compile. Not undoable.",
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
		"summary": "Move or rename a project file or folder and update the scenes, resources, scripts and project settings that refer to it.",
		"risk": AccessPolicy.RISK_DESTRUCTIVE,
		"params": {
			"type": "object",
			"properties": {
				"from": {"type": "string"},
				"to": {"type": "string"},
				"update_references": {
					"type": "boolean",
					"default": true,
					"description": "Rewrite the old res:// path in .tscn, .tres, .gd and shader files and in project settings. Open scenes that refer to it are saved and reloaded.",
				},
			},
			"required": ["from", "to"],
		},
		"returns": "{from, to, references_updated: {files, settings, reloaded_scenes, possible_dynamic_references}}. Paths a script builds from pieces are listed, not changed. A dry run lists what would change. Not undoable.",
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
	if path.get_extension().to_lower() in _BINARY_EXTENSIONS:
		return Reply.fail("INVALID_ARGS", "Binary scene and resource files are not written as text.", "Use the text formats .tscn and .tres.", {"path": path})
	var exists := FileAccess.file_exists(path)
	if exists and not args["overwrite"]:
		return Reply.fail("ALREADY_EXISTS", "The file already exists.", "Pass overwrite to replace it.", {"path": path})
	# Overwriting loses the old content; sensitive files change how the
	# project or the editor loads. Both need an explicit yes.
	if exists:
		var gate := Edit.confirmation_gate(options, _OVERWRITE)
		if not gate.is_empty():
			return gate
	# An ordinary script runs when the game runs. A tool script runs inside
	# the editor as soon as something loads it, with everything the editor
	# can do; so do the files in the sensitive locations. A person allows those.
	var is_tool := Edit.runs_in_editor(args["text"], path.get_extension())
	if checked["sensitive"] or is_tool:
		var what := {"command": "fs_write_text", "reason": _code_reason(path) if is_tool else _SENSITIVE, "target": path, "preview": args["text"]}
		var person := Edit.person_gate(_context, options, what, _write_text.bind(args, Edit.approved(options)))
		if not person.is_empty():
			return person
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
	var data := {"path": path, "bytes": bytes.size(), "created": not exists}
	var warnings := [Edit.NOT_UNDOABLE]
	# A script is checked right away: the caller learns of a mistake now and
	# not when the game runs. It is written either way, since it may refer to
	# something the next step creates.
	if path.get_extension().to_lower() == _SCRIPT_EXTENSION and not is_tool:
		data["check"] = _compile(args["text"])
		if data["check"].get("compiles") == false:
			warnings.append("The script was written but does not compile; see data.check.")
	return Reply.ok(data, warnings)


# Compiles the text without loading the file. In the editor, compiling a
# script that is not a tool script runs none of it (static initialisers
# included), so this is safe for text that has not been reviewed.
# Returns {compiles, errors?} (the error texts need Godot 4.5 or newer), or
# {skipped: reason} for a script that cannot be judged this way.
func _compile(text: String) -> Dictionary:
	# Compiling follows preload() and a path after `extends`: it would load
	# other files of the project, tool scripts among them, on the say-so of
	# text nobody has looked at.
	if RegEx.create_from_string(_LOADS_PATTERN).search(text) != null:
		return {"skipped": "it preloads or extends other files; check it with `gd check`"}
	# The text is compiled on its own, where its class name is unknown.
	var declared := RegEx.create_from_string(_CLASS_NAME_PATTERN).search(text)
	if declared != null and RegEx.create_from_string("\\b%s\\b" % declared.get_string(1)).search_all(text).size() > 1:
		return {"skipped": "it refers to its own class name; check it with `gd check`"}
	var record: Object = _context.error_log()
	var errors_before: int = record.total() if record != null else 0
	var script := GDScript.new()
	# The file already carries this class name; a second script claiming it
	# would be an error of its own.
	script.source_code = RegEx.create_from_string(_CLASS_NAME_PATTERN).sub(text, "")
	var compiles := script.reload() == OK
	var check := {"compiles": compiles}
	if not compiles and record != null and record.total() > errors_before:
		check["errors"] = _own_errors(record.read(record.total() - errors_before)["entries"])
	return check


# Other things may have printed errors meanwhile; a script compiled from text
# is known by a made-up gdscript:// name.
func _own_errors(entries: Array) -> Array:
	var own := []
	for entry in entries:
		if entry.get("severity") == "error" and str(entry.get("file", "")).begins_with(_ANONYMOUS_SCRIPT):
			own.append({"message": entry["message"], "line": entry["line"]})
	return own


# The editor ignores a single-file update for a folder it has not seen yet.
func _announce(path: String, new_folder: bool) -> void:
	if new_folder:
		_context.scan_files()
	else:
		_context.file_changed(path)


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
	for suffix in FileMove.SIDECARS:
		if FileAccess.file_exists(path + suffix):
			OS.move_to_trash(ProjectSettings.globalize_path(path + suffix))
	_context.scan_files()
	return Reply.ok({"path": path}, [Edit.NOT_UNDOABLE])


func _move(args: Dictionary, options: Dictionary) -> Dictionary:
	var source := PathPolicy.check(args["from"], PathPolicy.ACCESS_WRITE)
	if not source["ok"]:
		return source
	var target := PathPolicy.check(args["to"], PathPolicy.ACCESS_WRITE)
	if not target["ok"]:
		return target
	var from: String = source["path"]
	var to: String = target["path"]
	var is_folder := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(from))
	if not is_folder and not FileAccess.file_exists(from):
		return Reply.fail("RESOURCE_NOT_FOUND", "There is no file or folder at this path.", "", {"path": from})
	if is_folder:
		var refused := _folder_move_refusal(from, to)
		if not refused.is_empty():
			return refused
	if FileAccess.file_exists(to) or DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(to)):
		return Reply.fail("ALREADY_EXISTS", "Something already exists at the destination.", "", {"to": to})
	# The new path is written into scripts and scenes as it is, so it must not
	# contain anything that would end a string or start code there.
	if args["update_references"]:
		for character in _UNSAFE_IN_REFERENCES:
			if to.contains(character):
				return Reply.fail(
					"PATH_NOT_ALLOWED", "The new path contains a character that cannot be written into the files that refer to it.",
					"Choose a plainer name, or pass update_references=false.", {"to": TextSanitizer.clean_line(to)},
				)
	var updater := ReferenceUpdater.new(from, to, is_folder)
	var references := ReferenceUpdater.nothing()
	if args["update_references"]:
		references = updater.find()
	var open_scenes := _open_among(references["files"])
	# Text that was harmless under one extension can be code under another:
	# a C# tool class written as notes.txt and renamed to Notes.cs.
	var becomes_code := not is_folder and to.get_extension().to_lower() != from.get_extension().to_lower() \
			and Edit.runs_in_editor(FileAccess.get_file_as_string(from), to.get_extension())
	if source["sensitive"] or target["sensitive"] or not references["sensitive"].is_empty() or becomes_code:
		var what := {
			"command": "fs_move", "reason": _code_reason(to) if becomes_code else _SENSITIVE, "target": "%s -> %s" % [from, to],
			"preview": FileAccess.get_file_as_string(from) if becomes_code else "Files in sensitive locations that would be rewritten:\n" + "\n".join(references["sensitive"]),
		}
		var person := Edit.person_gate(_context, options, what, _move.bind(args, Edit.approved(options)))
		if not person.is_empty():
			return person
	if options["dry_run"]:
		return Edit.planned({
			"move": from,
			"to": to,
			"folder": is_folder,
			"references": {
				"files": TextSanitizer.clean_lines(references["files"]),
				"possible_dynamic_references": references["dynamic"],
				"sensitive_files": TextSanitizer.clean_lines(references["sensitive"]),
				"search_incomplete": references["truncated"],
				"settings": TextSanitizer.clean_lines(references["settings"]),
				"open_scenes_saved_and_reloaded": TextSanitizer.clean_lines(open_scenes),
			},
		})

	var job := FileMove.new(_context, from, to, updater, references, open_scenes, not args["update_references"])
	# Open scenes are saved and loaded again around the move, one step per frame.
	return Reply.later(job, true) if job.needs_frames() else job.run_now()


# Why this folder cannot be moved there, or {} when it can.
func _folder_move_refusal(from: String, to: String) -> Dictionary:
	if from == PathPolicy.ROOT.trim_suffix("/") or from == PathPolicy.ROOT:
		return Reply.fail("PATH_NOT_ALLOWED", "The project folder itself cannot be moved.")
	# Compared in lower case: the default Windows and macOS filesystems fold case.
	if (to + "/").to_lower().begins_with((from + "/").to_lower()):
		return Reply.fail("INVALID_ARGS", "A folder cannot be moved into itself.", "", {"from": from, "to": to})
	# The bridge does not move its own files, alone or as part of a parent folder.
	if not PathPolicy.check_text(from.path_join("gdcli"), PathPolicy.ACCESS_WRITE)["ok"]:
		return Reply.fail("PATH_NOT_ALLOWED", "This folder contains the bridge's own files.", "Move its other contents one by one.")
	return {}


func _open_among(files: Array) -> Array:
	var open := []
	for scene in _context.open_scenes():
		if scene in files:
			open.append(scene)
	return open


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
		var what := {"command": "resource_create", "reason": _SENSITIVE, "target": path, "preview": JSON.stringify(args, "  ")}
		var gate := Edit.person_gate(_context, options, what, _resource_create.bind(args, Edit.approved(options)))
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
		var what := {"command": "resource_set", "reason": _SENSITIVE, "target": path, "preview": JSON.stringify(args, "  ")}
		var gate := Edit.person_gate(_context, options, what, _resource_set.bind(args, Edit.approved(options)))
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


static func _code_reason(path: String) -> String:
	return _CSHARP if path.get_extension().to_lower() == Edit.CSHARP_EXTENSION else _TOOL_SCRIPT
