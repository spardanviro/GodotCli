extends RefCounted
## Finds and rewrites what refers to a moved file or folder by its res://
## path, for fs_move.
##
## A reference to a file is its exact path, wherever it stands: in quotes, in
## a scene's `path="..."`, in a comment. A longer path that merely starts the
## same way (`res://a.gd.uid`, `res://a.gd/x`, `res://a.gdx`) is left alone.
## A reference to a folder is the folder path followed by `/`, or the folder
## path alone in quotes. References by uid:// need no update.
##
## Paths that a script puts together while running cannot be rewritten; the
## string pieces that look like they build the moved path are reported instead.

const PathPolicy = preload("path_policy.gd")
const TextSanitizer = preload("text_sanitizer.gd")

const TEXT_EXTENSIONS: Array[String] = ["tscn", "tres", "gd", "gdshader", "gdshaderinc"]
# Big TileMap scenes run to a few megabytes; a larger file is reported, not skipped silently.
const MAX_FILE_BYTES := 16 * 1024 * 1024
const MAX_LISTED_TOO_LARGE := 50
const MAX_FILES_SCANNED := 20000
# The search runs on the editor's main thread; this bounds how long it can take.
const MAX_BYTES_SCANNED := 256 * 1024 * 1024
const MAX_DYNAMIC := 50
const MAX_PLACEHOLDERS := 4
const MAX_SNIPPET_CHARS := 200
const _SCRIPT_EXTENSION := "gd"
# After a file path: characters that would make it a different, longer path.
const _FILE_BOUNDARY := "(?![\\w\\-]|[./][\\w\\-])"
const _FOLDER_BOUNDARY := "(?=/|[\"'])"
const _LITERAL_PATTERN := "[\"'](res://[^\"'\\n]*)[\"']"
const _FORMAT_PATTERN := "%[-+0-9.]*[a-zA-Z]|\\{[^}]*\\}"
const _REGEX_SPECIALS := "\\.^$|?*+()[]{}"
const _FORMAT_MARK := "\u0001"

var _from: String
var _to: String
var _is_folder: bool
var _regex: RegEx
var _literal_regex := RegEx.create_from_string(_LITERAL_PATTERN)
var _format_regex := RegEx.create_from_string(_FORMAT_PATTERN)


func _init(from: String, to: String, is_folder: bool) -> void:
	_from = from
	_to = to
	_is_folder = is_folder
	_regex = RegEx.create_from_string(_escape(from) + (_FOLDER_BOUNDARY if is_folder else _FILE_BOUNDARY))


static func nothing() -> Dictionary:
	return {"files": [], "sensitive": [], "settings": [], "dynamic": [], "too_large": [], "truncated": false}


## `text` with every reference to the old path replaced by the new one.
func rewrite(text: String) -> String:
	if not text.contains(_from):
		return text
	var result := ""
	var copied := 0
	for found in _regex.search_all(text):
		result += text.substr(copied, found.get_start() - copied) + _to
		copied = found.get_end()
	return result + text.substr(copied)


## The value a project setting should have after the move; `value` itself
## when it does not refer to the path. Lists of paths are handled too.
func setting_after(value: Variant) -> Variant:
	if value is String:
		return rewrite(value)
	if value is PackedStringArray:
		var changed := PackedStringArray()
		for item in value:
			changed.append(rewrite(item))
		return changed
	return value


## What refers to the path: {files: [res:// paths], sensitive: [those of them
## in locations that are sensitive, see path_policy.gd], settings: [names],
## dynamic: [{file, line, text}] string pieces a script may build the path
## from, truncated}. Nothing is changed. A moved file itself is not listed;
## files inside a moved folder are, under their present paths.
func find() -> Dictionary:
	var found := nothing()
	for property in ProjectSettings.get_property_list():
		var name: String = property["name"]
		var value: Variant = ProjectSettings.get_setting(name)
		if (value is String or value is PackedStringArray) and setting_after(value) != value:
			found["settings"].append(name)

	var pending: Array[String] = [PathPolicy.ROOT]
	var scanned := 0
	var budget := {"bytes": MAX_BYTES_SCANNED}
	while not pending.is_empty() and not found["truncated"]:
		var folder: String = pending.pop_back()
		var directory := DirAccess.open(folder)
		if directory == null:
			continue
		directory.include_hidden = true
		for name in directory.get_directories():
			var child := folder.path_join(name)
			if not directory.is_link(child) and PathPolicy.check_text(child, PathPolicy.ACCESS_WRITE)["ok"]:
				pending.append(child)
		for name in directory.get_files():
			var path := folder.path_join(name)
			if (path == _from and not _is_folder) or name.get_extension().to_lower() not in TEXT_EXTENSIONS:
				continue
			scanned += 1
			if scanned > MAX_FILES_SCANNED or budget["bytes"] <= 0:
				found["truncated"] = true
				break
			if not directory.is_link(path):
				_look_at(path, found, budget)
	found["files"].sort()
	return found


## Rewrites the listed files. Returns {updated: [paths], failed: [paths]}.
func apply_to_files(files: Array) -> Dictionary:
	var outcome := {"updated": [], "failed": []}
	for path in files:
		var text := FileAccess.get_file_as_string(path)
		var rewritten := rewrite(text)
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
func apply_to_settings(names: Array) -> void:
	for name in names:
		ProjectSettings.set_setting(name, setting_after(ProjectSettings.get_setting(name)))


## Where a path will be after the move: paths inside a moved folder follow it.
func moved_path(path: String) -> String:
	if _is_folder and path.begins_with(_from + "/"):
		return _to + path.substr(_from.length())
	return path


# Hidden folders, nested repositories and the bridge's own files are skipped.
func _look_at(path: String, found: Dictionary, budget: Dictionary) -> void:
	var checked := PathPolicy.check_text(path, PathPolicy.ACCESS_WRITE)
	var file := FileAccess.open(path, FileAccess.READ) if checked["ok"] else null
	if file == null:
		return
	if file.get_length() > MAX_FILE_BYTES:
		if found["too_large"].size() < MAX_LISTED_TOO_LARGE:
			found["too_large"].append(path)
		return
	budget["bytes"] -= file.get_length()
	var text := file.get_as_text()
	if text.contains(_from) and _regex.search(text) != null:
		found["files"].append(path)
		# Sensitive where it is, or where it will be once its folder has moved.
		if checked["sensitive"] or PathPolicy.check_text(moved_path(path), PathPolicy.ACCESS_WRITE).get("sensitive", true):
			found["sensitive"].append(path)
	if path.get_extension().to_lower() == _SCRIPT_EXTENSION:
		_collect_dynamic(path, text, found["dynamic"])


# String literals that are the beginning of the moved path ("res://levels/" +
# name), or a format that produces it ("res://levels/level_%d.tscn").
func _collect_dynamic(path: String, text: String, dynamic: Array) -> void:
	if not text.contains(PathPolicy.ROOT):
		return
	for found in _literal_regex.search_all(text):
		if dynamic.size() >= MAX_DYNAMIC:
			return
		var literal := found.get_string(1)
		if literal == _from or not _could_build(literal):
			continue
		var line := text.count("\n", 0, found.get_start()) + 1 if found.get_start() > 0 else 1
		dynamic.append({
			"file": TextSanitizer.clean_line(path),
			"line": line,
			"text": TextSanitizer.clean_line(found.get_string(0).left(MAX_SNIPPET_CHARS)),
		})


func _could_build(literal: String) -> bool:
	if literal.length() <= PathPolicy.ROOT.length():
		return false
	# A folder's own prefix literal ("res://old/") is rewritten, not reported.
	if literal.length() < _from.length() and _from.begins_with(literal):
		return true
	# Each placeholder becomes a wildcard; many of them make matching very slow.
	var placeholders := _format_regex.search_all(literal).size()
	if _is_folder or placeholders == 0 or placeholders > MAX_PLACEHOLDERS:
		return false
	var pattern := _escape(_format_regex.sub(literal, _FORMAT_MARK, true)).replace(_FORMAT_MARK, ".*")
	var regex := RegEx.create_from_string("^" + pattern + "$")
	return regex != null and regex.is_valid() and regex.search(_from) != null


static func _escape(text: String) -> String:
	var escaped := ""
	for character in text:
		escaped += ("\\" + character) if _REGEX_SPECIALS.contains(character) else character
	return escaped
