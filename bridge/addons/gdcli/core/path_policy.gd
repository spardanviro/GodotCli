extends RefCounted
## File path rules of docs/protocol.md section 4.4.

const Reply = preload("reply.gd")
const TextSanitizer = preload("text_sanitizer.gd")

const ROOT := "res://"
const ACCESS_READ := "read"
const ACCESS_WRITE := "write"

# First path segment, lower case: never readable or writable through the bridge.
const _HIDDEN_ROOTS: Array[String] = [".godot", ".git"]
const _OWN_ADDON := "addons/gdcli"
const _SENSITIVE_ROOT_FILES: Array[String] = ["project.godot", "project.binary", "override.cfg", "export_presets.cfg"]
# Files git itself acts on (a submodule URL, a filter command), and those a
# .NET restore or build reads by name: package sources, the SDK version,
# MSBuild command-line arguments, local tools.
const _SENSITIVE_FILE_NAMES: Array[String] = [
	".gitmodules", ".gitattributes", "nuget.config", "global.json", "directory.build.rsp", "dotnet-tools.json",
]
const _GIT_DIR := ".git"
const _SENSITIVE_ROOTS: Array[String] = ["addons", "gdcli_commands"]
# Run by other programs without being asked: VS Code tasks and launch settings
# (a task can run when the folder opens), git hooks managers, direnv, CI.
const _SENSITIVE_TOOL_FOLDERS: Array[String] = [".vscode", ".husky", ".github/workflows"]
const _SENSITIVE_TOOL_FILES: Array[String] = [".envrc", ".pre-commit-config.yaml", ".pre-commit-config.yml"]
# Native libraries, and the files a C# build runs: projects and solutions of
# every kind, imported props and targets, a project's .user file (imported
# automatically) and response files.
# .import: its import script (import_script/path) runs in the editor when the asset is imported.
const _SENSITIVE_EXTENSIONS: Array[String] = [
	"gdextension", "csproj", "fsproj", "vbproj", "proj", "sln", "slnx", "slnf", "props", "targets", "user", "rsp", "import",
]
# Files whose text names other files the editor loads: scenes, resources, import settings.
const _REFERENCING_EXTENSIONS: Array[String] = ["tscn", "tres", "escn", "import"]
# Any key ending in path, script or file, as `key="..."` or `"key": "..."`:
# path=, path.s3tc=, import_script/path=, nodes/root_script=, source_file=,
# "use_external/path": ... The files such a text makes the editor load.
const _REFERENCE_PATTERN := "(?m)(?:^|[\\s{,\"])[\\w/.]*(?:path|script|file)(?:\\.[\\w]+)?\"?\\s*[=:]\\s*\"([^\"]*)\""
# Text resources start like this whatever their extension (.material, .theme, ...).
const _TEXT_RESOURCE_HEADERS: Array[String] = ["[gd_scene", "[gd_resource"]
# More files than a project's dependencies reach; past it the answer is no, not yes.
const _MAX_DEPENDENCIES := 20000
const _FIRST_PRINTABLE := 0x20
const _DELETE := 0x7f
# Also CONIN$/CONOUT$ and the superscript digits Windows takes as device numbers (COM¹).
const _RESERVED_DEVICE_PATTERN := "^(con|prn|aux|nul|conin\\$|conout\\$|com[1-9\u00b9\u00b2\u00b3]|lpt[1-9\u00b9\u00b2\u00b3])(\\..*)?$"

static var _reserved_regex: RegEx


## Purely textual part of the check.
## Returns {ok = true, path, sensitive} or a failed reply (PATH_NOT_ALLOWED).
static func check_text(raw_path: String, access: String) -> Dictionary:
	if not raw_path.begins_with(ROOT):
		return _deny("Only res:// paths are accepted.")
	var relative := raw_path.substr(ROOT.length()).trim_suffix("/")
	if relative.contains("\\") or relative.contains(":"):
		return _deny("The path contains a character that is not allowed.")

	var segments := relative.split("/") if relative != "" else PackedStringArray()
	for segment in segments:
		if not _is_plain_segment(segment):
			return _deny("The path contains an empty, relative or reserved segment.")
		# A repository nested anywhere in the project: its hooks and config
		# are run by git, so nothing is written into it; and its config can
		# hold a remote URL with a token, so nothing is read from it either.
		if segment.to_lower() == _GIT_DIR:
			return _deny("Nothing is written inside a .git folder." if access == ACCESS_WRITE else "A .git folder is not accessible through the bridge.")

	# Compared in lower case: the default Windows and macOS filesystems fold case.
	var folded := relative.to_lower()
	var first := folded.get_slice("/", 0)
	if first in _HIDDEN_ROOTS:
		return _deny("This location is not accessible through the bridge.")
	if access == ACCESS_WRITE and (folded == _OWN_ADDON or folded.begins_with(_OWN_ADDON + "/")):
		return _deny("The bridge does not modify its own files.")

	return {"ok": true, "path": ROOT + relative, "sensitive": _is_sensitive(folded, segments.size())}


## Full check: text rules, then no symbolic link on the way to the target.
static func check(raw_path: String, access: String) -> Dictionary:
	var resolved := raw_path
	if raw_path.begins_with("uid://"):
		var id := ResourceUID.text_to_id(raw_path)
		if id == ResourceUID.INVALID_ID or not ResourceUID.has_id(id):
			return _deny("Unknown uid.")
		resolved = ResourceUID.get_id_path(id)

	var checked := check_text(resolved, access)
	if not checked["ok"]:
		return checked
	if _passes_through_link(checked["path"]):
		return _deny("The path passes through a symbolic link.")
	return checked


static func is_hidden_name(name: String, parent: String) -> bool:
	return name.to_lower() == _GIT_DIR or (parent == ROOT and name.to_lower() in _HIDDEN_ROOTS)


static func _is_plain_segment(segment: String) -> bool:
	if segment == "" or segment == "." or segment == "..":
		return false
	if segment.ends_with(".") or segment.ends_with(" "):
		return false
	for index in segment.length():
		if segment.unicode_at(index) < _FIRST_PRINTABLE or segment.unicode_at(index) == _DELETE:
			return false
	# NTFS short names such as GODOT~1 are aliases that would slip past the
	# hidden-folder comparison.
	var tilde := segment.find("~")
	while tilde != -1:
		if tilde + 1 < segment.length() and segment[tilde + 1].is_valid_int():
			return false
		tilde = segment.find("~", tilde + 1)
	if _reserved_regex == null:
		_reserved_regex = RegEx.create_from_string(_RESERVED_DEVICE_PATTERN)
	return _reserved_regex.search(segment.to_lower()) == null


## Whether a file's text can name other files the editor loads: a scene, a
## resource (text resources load under any extension, by their first line),
## an asset's import settings.
static func names_other_files(path: String, text: String = "") -> bool:
	if path.get_extension().to_lower() in _REFERENCING_EXTENSIONS:
		return true
	var start := text.trim_prefix(char(0xfeff)).strip_edges(true, false)
	for header in _TEXT_RESOURCE_HEADERS:
		if start.begins_with(header):
			return true
	return false


## The first file outside the project that such a text names, or "". A scene
## or resource never needs one; one that does can load a tool script from
## anywhere, which no person was asked about (docs/protocol.md 4.1).
static func outside_reference_in_text(text: String) -> String:
	for found in RegEx.create_from_string(_REFERENCE_PATTERN).search_all(text):
		var named := found.get_string(1)
		if not _is_plain_project_path(named):
			return named
	return ""


## The first file outside the project that a resource depends on, directly or
## through other files of the project, or "". Checked before the editor loads it.
static func outside_dependency(path: String) -> String:
	var pending: Array[String] = [path]
	var seen := {}
	while not pending.is_empty():
		var current: String = pending.pop_back()
		if seen.has(current):
			continue
		if seen.size() >= _MAX_DEPENDENCIES:
			return "(more files than can be checked)"
		seen[current] = true
		for dependency in ResourceLoader.get_dependencies(current):
			var named := _dependency_path(dependency)
			if not _is_plain_project_path(named):
				return named
			if named.begins_with(ROOT):
				pending.append(named)
	return ""


# "uid::type::path", "path::type" or "uid::path": the path is the part that is
# neither a uid nor a type name.
static func _dependency_path(dependency: String) -> String:
	var parts := dependency.split("::")
	for index in range(parts.size() - 1, -1, -1):
		var part := parts[index]
		if part.begins_with("uid://"):
			continue
		if part.contains("/") or part.contains(":") or part.contains("."):
			return part
	return parts[0]


## The reply that refuses to load a resource reaching outside the project; {} when it does not.
static func refuse_outside_dependency(path: String) -> Dictionary:
	var outside := outside_dependency(path)
	if outside == "":
		return {}
	return Reply.fail(
		"PATH_NOT_ALLOWED", "The file uses a file outside the project.",
		"A scene or resource may only use files under res://.", {"path": path, "uses": TextSanitizer.clean_line(outside)},
	)


static func _is_plain_project_path(named: String) -> bool:
	if named.begins_with("uid://"):
		return true
	return named.begins_with(ROOT) and not named.contains("..") and not named.contains("\\") and not named.substr(ROOT.length()).contains(":")


static func _is_sensitive(folded: String, segment_count: int) -> bool:
	if segment_count == 1 and folded in _SENSITIVE_ROOT_FILES:
		return true
	if folded.get_slice("/", 0) in _SENSITIVE_ROOTS:
		return true
	if folded.get_file() in _SENSITIVE_FILE_NAMES or folded.get_file() in _SENSITIVE_TOOL_FILES:
		return true
	for folder in _SENSITIVE_TOOL_FOLDERS:
		if folded.begins_with(folder + "/") or folded.contains("/" + folder + "/"):
			return true
	return folded.get_extension() in _SENSITIVE_EXTENSIONS


static func _passes_through_link(path: String) -> bool:
	var directory := DirAccess.open(ROOT)
	if directory == null:
		# Without a way to look, assume the worst.
		return true
	var current := ROOT
	for segment in path.substr(ROOT.length()).split("/", false):
		current = current.path_join(segment)
		if directory.is_link(current):
			return true
	return false


static func _deny(message: String) -> Dictionary:
	return Reply.fail("PATH_NOT_ALLOWED", message, "Use a res:// path inside the project.")
