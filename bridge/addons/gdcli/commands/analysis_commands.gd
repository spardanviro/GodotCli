extends RefCounted
## Reading the project as a whole: what it holds, which files nothing uses,
## what uses a file and what it uses, and scenes that end up containing
## themselves. Read only; files are read as text, nothing is loaded.

const AccessPolicy = preload("../core/access_policy.gd")
const PathPolicy = preload("../core/path_policy.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")

const MAX_FILES := 20000
const MAX_TEXT_BYTES := 2 * 1024 * 1024
const MAX_TOTAL_BYTES := 256 * 1024 * 1024
const MAX_LISTED := 500
const _TEXT_EXTENSIONS: Array[String] = ["tscn", "tres", "gd", "gdshader", "gdshaderinc", "cs", "cfg", "godot", "import", "json"]
# Files a game uses by reference; scripts and shaders included.
const _ASSET_EXTENSIONS: Array[String] = ["tscn", "tres", "gd", "gdshader", "gdshaderinc", "cs", "png", "jpg", "jpeg", "webp", "svg", "wav", "ogg", "mp3", "ttf", "otf", "woff", "woff2", "glb", "gltf", "fbx", "blend", "obj", "translation", "csv"]
const _SKIPPED_ROOTS: Array[String] = [".godot", ".git", "addons"]
const _PATH_PATTERN := "res://[^\"'\\s)\\]>,]+"
const _UID_PATTERN := "uid://[a-z0-9]+"
const _SCENE_LINK_PATTERN := "\\[ext_resource[^\\]]*path=\"(res://[^\"]+\\.(?:tscn|scn))\""

var _context: RefCounted
var _read_bytes := 0


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "project_analyze",
		"summary": "Read the project as a whole: stats (files by kind, script lines, the largest files), unused (files nothing refers to), uses (what refers to a file and what it refers to), cycles (scenes that contain themselves through others).",
		"risk": AccessPolicy.RISK_READ,
		"params": {
			"type": "object",
			"properties": {
				"report": {"type": "string", "enum": ["stats", "unused", "uses", "cycles"]},
				"path": {"type": "string", "description": "uses: the file to look at."},
			},
			"required": ["report"],
		},
		"returns": "stats: {files, by_extension, script_lines, largest}; unused: {files, note}; uses: {path, used_by, uses}; cycles: {cycles: [[scene, ...]]}. addons/ is left out. A path a script builds from pieces at run time is not seen, so unused means only that no file names it.",
	}, _analyze)


func _analyze(args: Dictionary) -> Dictionary:
	_read_bytes = 0
	var files := []
	var truncated := _walk(PathPolicy.ROOT, files)
	var reply: Dictionary
	match args["report"]:
		"stats":
			reply = _stats(files)
		"unused":
			reply = _unused(files)
		"uses":
			reply = _uses(files, args.get("path", ""))
		_:
			reply = _cycles(files)
	if reply["ok"] and truncated:
		reply["warnings"] = ["The project has more than %d files; only the first were read." % MAX_FILES]
	return reply


func _walk(folder: String, files: Array) -> bool:
	var dir := DirAccess.open(folder)
	if dir == null:
		return false
	for name in dir.get_files():
		if files.size() >= MAX_FILES:
			return true
		files.append(folder.path_join(name))
	for name in dir.get_directories():
		if folder == PathPolicy.ROOT and name.to_lower() in _SKIPPED_ROOTS:
			continue
		# A link may lead out of the project, or back into itself.
		if dir.is_link(name):
			continue
		if name.to_lower() == ".git" or PathPolicy.is_hidden_name(name, folder):
			continue
		if _walk(folder.path_join(name), files):
			return true
	return false


func _text(path: String) -> String:
	if path.get_extension().to_lower() not in _TEXT_EXTENSIONS:
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_TEXT_BYTES or _read_bytes + file.get_length() > MAX_TOTAL_BYTES:
		return ""
	_read_bytes += file.get_length()
	return file.get_as_text()


## path -> [res:// paths it names], with uid:// names turned into paths.
func _references(files: Array) -> Dictionary:
	var paths := RegEx.create_from_string(_PATH_PATTERN)
	var uids := RegEx.create_from_string(_UID_PATTERN)
	var named := {}
	var sources := files.duplicate()
	sources.append("res://project.godot")
	sources.append("res://export_presets.cfg")
	for path in sources:
		var text := _text(path)
		if text == "":
			continue
		var found := {}
		for match in paths.search_all(text):
			found[match.get_string().trim_suffix(".")] = true
		for match in uids.search_all(text):
			var id := ResourceUID.text_to_id(match.get_string())
			if id != ResourceUID.INVALID_ID and ResourceUID.has_id(id):
				found[ResourceUID.get_id_path(id)] = true
		# A .import file names its own source; that is not a use.
		if path.ends_with(".import"):
			continue
		found.erase(path)
		named[path] = found.keys()
	return named


func _stats(files: Array) -> Dictionary:
	var by_extension := {}
	var script_lines := 0
	var sizes := []
	for path in files:
		var extension: String = path.get_extension().to_lower()
		if extension == "import" or extension == "uid":
			continue
		by_extension[extension] = by_extension.get(extension, 0) + 1
		if extension == "gd":
			script_lines += _text(path).count("\n")
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			sizes.append([file.get_length(), path])
	sizes.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var largest := []
	for entry in sizes.slice(0, 10):
		largest.append({"path": TextSanitizer.clean_line(entry[1]), "bytes": entry[0]})
	return Reply.ok({"files": sizes.size(), "by_extension": by_extension, "script_lines": script_lines, "largest": largest})


func _unused(files: Array) -> Dictionary:
	var named := _references(files)
	var used := {}
	for source in named:
		for target in named[source]:
			used[target] = true
	var unused := []
	for path in files:
		if path.get_extension().to_lower() not in _ASSET_EXTENSIONS or used.has(path):
			continue
		unused.append(TextSanitizer.clean_line(path))
	return Reply.ok({
		"files": unused.slice(0, MAX_LISTED),
		"count": unused.size(),
		"note": "No scene, resource, script or setting names these files. Code that builds a path at run time, or loads from a folder listing, is not seen: check before deleting.",
	})


func _uses(files: Array, raw_path: Variant) -> Dictionary:
	if not raw_path is String or raw_path == "":
		return Reply.fail("INVALID_ARGS", "uses needs path: the file to look at.")
	var checked := PathPolicy.check(raw_path, PathPolicy.ACCESS_READ)
	if not checked["ok"]:
		return checked
	var path: String = checked["path"]
	if not FileAccess.file_exists(path):
		return Reply.fail("RESOURCE_NOT_FOUND", "There is no file at this path.", "", {"path": path})
	var named := _references(files)
	var used_by := []
	for source in named:
		if path in named[source]:
			used_by.append(TextSanitizer.clean_line(source))
	var uses := []
	for target in named.get(path, []):
		uses.append(TextSanitizer.clean_line(target))
	used_by.sort()
	uses.sort()
	return Reply.ok({"path": path, "used_by": used_by.slice(0, MAX_LISTED), "uses": uses.slice(0, MAX_LISTED)})


func _cycles(files: Array) -> Dictionary:
	var links := RegEx.create_from_string(_SCENE_LINK_PATTERN)
	var graph := {}
	for path in files:
		if path.get_extension().to_lower() != "tscn":
			continue
		var targets := []
		for match in links.search_all(_text(path)):
			targets.append(match.get_string(1))
		graph[path] = targets
	var cycles := []
	var state := {}
	for scene in graph:
		if not state.has(scene):
			_visit(scene, graph, state, [], cycles)
	return Reply.ok({"cycles": cycles.slice(0, MAX_LISTED)})


# Depth first; a scene met again while still on the path closes a cycle.
func _visit(scene: String, graph: Dictionary, state: Dictionary, path: Array, cycles: Array) -> void:
	state[scene] = "open"
	path.append(scene)
	for next in graph.get(scene, []):
		if state.get(next) == "open":
			var cycle := path.slice(path.find(next))
			cycle.append(next)
			var cleaned := []
			for entry in cycle:
				cleaned.append(TextSanitizer.clean_line(entry))
			cycles.append(cleaned)
		elif not state.has(next):
			_visit(next, graph, state, path, cycles)
	path.pop_back()
	state[scene] = "done"
