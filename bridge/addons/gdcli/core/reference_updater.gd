extends RefCounted
## Finds and rewrites what refers to a file by its res:// path, for fs_move.
## A reference is the exact path in quotes: `path="res://a.gd"` in a scene,
## `preload("res://a.gd")` in a script, a main scene or autoload in the
## project settings. References by uid:// need no update.

const PathPolicy = preload("path_policy.gd")

const TEXT_EXTENSIONS: Array[String] = ["tscn", "tres", "gd", "gdshader", "gdshaderinc"]
const MAX_FILE_BYTES := 2 * 1024 * 1024
const MAX_FILES_SCANNED := 20000
# The search runs on the editor's main thread; this bounds how long it can take.
const MAX_BYTES_SCANNED := 256 * 1024 * 1024
const _QUOTES: Array[String] = ["\"", "'"]
# Autoloads are stored as "*res://path" when they are singletons.
const _AUTOLOAD_MARK := "*"


## Paths with a quote or a line break cannot be matched reliably.
static func can_update(from: String, to: String) -> bool:
	for path in [from, to]:
		if path.contains("\"") or path.contains("'") or path.contains("\n"):
			return false
	return true


## `text` with every quoted occurrence of `from` replaced by `to`.
static func rewrite(text: String, from: String, to: String) -> String:
	var result := text
	for quote in _QUOTES:
		result = result.replace(quote + from + quote, quote + to + quote)
	return result


## The value a project setting should have after the move; `value` itself
## when it does not refer to the file.
static func setting_after(value: Variant, from: String, to: String) -> Variant:
	if not value is String:
		return value
	if value == from:
		return to
	if value == _AUTOLOAD_MARK + from:
		return _AUTOLOAD_MARK + to
	return value


static func nothing() -> Dictionary:
	return {"files": [], "sensitive": [], "settings": [], "truncated": false}


## What refers to `from`: {files: [res:// paths], sensitive: [those of them in
## locations that are sensitive, see path_policy.gd], settings: [names],
## truncated}. Nothing is changed. The moved file itself is not listed.
static func find(from: String, to: String) -> Dictionary:
	var found := nothing()
	if not can_update(from, to):
		return found
	for property in ProjectSettings.get_property_list():
		var name: String = property["name"]
		var value: Variant = ProjectSettings.get_setting(name)
		if value is String and setting_after(value, from, to) != value:
			found["settings"].append(name)

	var pending: Array[String] = [PathPolicy.ROOT]
	var scanned := 0
	var budget := {"bytes": MAX_BYTES_SCANNED}
	while not pending.is_empty():
		var folder: String = pending.pop_back()
		var directory := DirAccess.open(folder)
		if directory == null:
			continue
		directory.include_hidden = true
		for name in directory.get_directories():
			var child := folder.path_join(name)
			if not directory.is_link(child) and _is_writable(child):
				pending.append(child)
		for name in directory.get_files():
			var path := folder.path_join(name)
			if path == from or name.get_extension().to_lower() not in TEXT_EXTENSIONS:
				continue
			scanned += 1
			if scanned > MAX_FILES_SCANNED or budget["bytes"] <= 0:
				found["truncated"] = true
				found["files"].sort()
				return found
			if directory.is_link(path):
				continue
			var checked := PathPolicy.check_text(path, PathPolicy.ACCESS_WRITE)
			if checked["ok"] and _refers(path, from, budget):
				found["files"].append(path)
				if checked["sensitive"]:
					found["sensitive"].append(path)
	found["files"].sort()
	return found


## Rewrites the listed files. Returns {updated: [paths], failed: [paths]}.
static func apply_to_files(files: Array, from: String, to: String) -> Dictionary:
	var outcome := {"updated": [], "failed": []}
	for path in files:
		var text := FileAccess.get_file_as_string(path)
		var rewritten := rewrite(text, from, to)
		if rewritten == text:
			continue
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			outcome["failed"].append(path)
			continue
		file.store_string(rewritten)
		file.close()
		outcome["updated"].append(path)
	return outcome


## Changes the listed settings in memory; the caller saves project.godot.
static func apply_to_settings(names: Array, from: String, to: String) -> void:
	for name in names:
		ProjectSettings.set_setting(name, setting_after(ProjectSettings.get_setting(name), from, to))


# Hidden folders, nested repositories and the bridge's own files are not touched.
static func _is_writable(path: String) -> bool:
	return PathPolicy.check_text(path, PathPolicy.ACCESS_WRITE)["ok"]


static func _refers(path: String, from: String, budget: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_FILE_BYTES:
		return false
	budget["bytes"] -= file.get_length()
	var text := file.get_as_text()
	if not text.contains(from):
		return false
	for quote in _QUOTES:
		if text.contains(quote + from + quote):
			return true
	return false
