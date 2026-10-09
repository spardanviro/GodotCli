extends RefCounted
## File path rules of docs/protocol.md section 4.4.

const Reply = preload("reply.gd")

const ROOT := "res://"
const ACCESS_READ := "read"
const ACCESS_WRITE := "write"

# First path segment, lower case: never readable or writable through the bridge.
const _HIDDEN_ROOTS: Array[String] = [".godot", ".git"]
const _OWN_ADDON := "addons/gdcli"
const _SENSITIVE_ROOT_FILES: Array[String] = ["project.godot", "override.cfg", "export_presets.cfg"]
const _SENSITIVE_ROOTS: Array[String] = ["addons", "gdcli_commands"]
const _SENSITIVE_EXTENSIONS: Array[String] = ["gdextension"]
const _RESERVED_DEVICE_PATTERN := "^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\\..*)?$"

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
	return parent == ROOT and name.to_lower() in _HIDDEN_ROOTS


static func _is_plain_segment(segment: String) -> bool:
	if segment == "" or segment == "." or segment == "..":
		return false
	if segment.ends_with(".") or segment.ends_with(" "):
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


static func _is_sensitive(folded: String, segment_count: int) -> bool:
	if segment_count == 1 and folded in _SENSITIVE_ROOT_FILES:
		return true
	if folded.get_slice("/", 0) in _SENSITIVE_ROOTS:
		return true
	return folded.get_extension() in _SENSITIVE_EXTENSIONS


static func _passes_through_link(path: String) -> bool:
	var directory := DirAccess.open(ROOT)
	if directory == null:
		return false
	var current := ROOT
	for segment in path.substr(ROOT.length()).split("/", false):
		current = current.path_join(segment)
		if directory.is_link(current):
			return true
	return false


static func _deny(message: String) -> Dictionary:
	return Reply.fail("PATH_NOT_ALLOWED", message, "Use a res:// path inside the project.")
