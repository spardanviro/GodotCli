extends RefCounted
## Moves one project file and updates what refers to it (fs_move).
##
## When scenes that refer to the file are open in the editor, they are saved
## before the move and loaded again after it, so that neither their unsaved
## changes nor the rewritten paths are lost. The editor accepts only one
## change of the edited scene per frame, so that part is done in steps: the
## HTTP layer calls poll() once per frame until it returns the reply.

const Edit = preload("edit.gd")
const ReferenceUpdater = preload("reference_updater.gd")
const Reply = preload("reply.gd")
const TextSanitizer = preload("text_sanitizer.gd")

# Godot keeps a file's identity and import settings in files next to it.
const SIDECARS: Array[String] = [".uid", ".import"]
const STEP_TIMEOUT_MSEC := 5000

var _context: RefCounted
var _from: String
var _to: String
var _references: Dictionary
var _open_scenes: Array
var _note_untouched: bool
var _return_to: String
var _steps: Array[Callable] = []
var _step_started := 0
var _moved: Dictionary = {}
var _updated: Array = []
var _failure: Dictionary = {}
var _warnings: Array = []


## `references` is the result of ReferenceUpdater.find(); `open_scenes` are the
## files among them that are open in the editor. `note_untouched` adds the
## warning that other files were left as they are.
func _init(context: RefCounted, from: String, to: String, references: Dictionary, open_scenes: Array, note_untouched: bool) -> void:
	_context = context
	_from = from
	_to = to
	_references = references
	_open_scenes = open_scenes
	_note_untouched = note_untouched
	_return_to = context.scene_path()
	for scene in open_scenes:
		_steps.append(_show.bind(scene))
		_steps.append(_save.bind(scene))
	if not open_scenes.is_empty():
		_steps.append(_show.bind(_return_to))
	_steps.append(_move)
	for scene in open_scenes:
		_steps.append(_reload.bind(scene))
	if not open_scenes.is_empty():
		_steps.append(_show.bind(_return_to))


func needs_frames() -> bool:
	return not _open_scenes.is_empty()


## For a move that involves no open scene: everything at once.
func run_now() -> Dictionary:
	_move()
	return _reply()


## {} while there are steps left; one step is tried per call.
func poll() -> Dictionary:
	if _steps.is_empty():
		return _reply()
	if _step_started == 0:
		_step_started = Time.get_ticks_msec()
	var failed_before := not _failure.is_empty()
	if _steps[0].call():
		_steps.pop_front()
		_step_started = 0
	elif Time.get_ticks_msec() - _step_started > STEP_TIMEOUT_MSEC:
		# The file may already have moved: finish with what was done.
		_warnings.append("The editor did not switch scenes in time; check which scenes are open and saved.")
		_steps.clear()
	if not failed_before and not _failure.is_empty():
		# Nothing more is done, except going back to the scene that was edited.
		_steps.assign([_show.bind(_return_to)])
	return _reply() if _steps.is_empty() else {}


func _reply() -> Dictionary:
	if not _failure.is_empty():
		return _failure
	if _moved.is_empty():
		return Reply.fail("COMMAND_FAILED", "The file was not moved.", "", {"from": _from, "to": _to})
	return Reply.ok(_moved, _warnings)


# --- steps: each returns true when it is done ---------------------------------

# Makes `scene` the edited one. Asked again on later frames until it is.
func _show(scene: String) -> bool:
	if scene == "" or _context.scene_path() == scene:
		return true
	_context.open_scene(scene)
	return _context.scene_path() == scene


func _save(scene: String) -> bool:
	if _context.save_scene() != OK:
		_failure = Reply.fail(
			"COMMAND_FAILED", "An open scene that refers to the file could not be saved first.",
			"Save or close it, or pass update_references=false.", {"scene": TextSanitizer.clean_line(scene)},
		)
	return true


func _reload(scene: String) -> bool:
	if scene in _updated:
		_context.reload_scene(scene)
	return true


func _move() -> bool:
	var cached: Resource = ResourceLoader.load(_from) if ResourceLoader.has_cached(_from) else null
	var made := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_to.get_base_dir()))
	var result := DirAccess.rename_absolute(ProjectSettings.globalize_path(_from), ProjectSettings.globalize_path(_to)) if made == OK else made
	if result != OK:
		_failure = Reply.fail("COMMAND_FAILED", "The file could not be moved.", "", {"from": _from, "to": _to, "error": error_string(result)})
		return true
	# Without its .uid the file would get a new identity and uid:// references break.
	for suffix in SIDECARS:
		if FileAccess.file_exists(_from + suffix):
			DirAccess.rename_absolute(ProjectSettings.globalize_path(_from + suffix), ProjectSettings.globalize_path(_to + suffix))
	# What the editor already holds in memory follows the file.
	if cached != null:
		cached.take_over_path(_to)

	var outcome := ReferenceUpdater.apply_to_files(_references["files"], _from, _to)
	_updated = outcome["updated"]
	var settings: Array = _references["settings"]
	_warnings.append(Edit.NOT_UNDOABLE)
	if not settings.is_empty():
		ReferenceUpdater.apply_to_settings(settings, _from, _to)
		if ProjectSettings.save() != OK:
			_warnings.append("project.godot could not be saved; its references to the old path are unchanged on disk.")
	_context.scan_files()
	_add_warnings(outcome)
	var reloaded := []
	for scene in _open_scenes:
		if scene in outcome["updated"]:
			reloaded.append(scene)
	_moved = {
		"from": _from,
		"to": _to,
		"references_updated": {
			"files": TextSanitizer.clean_lines(outcome["updated"]),
			"settings": TextSanitizer.clean_lines(settings),
			"reloaded_scenes": TextSanitizer.clean_lines(reloaded),
		},
	}
	return true


func _add_warnings(outcome: Dictionary) -> void:
	if not outcome["failed"].is_empty():
		_warnings.append("Some files that refer to the old path could not be rewritten: %s" % ", ".join(TextSanitizer.clean_lines(outcome["failed"])))
	var sensitive := []
	for path in _references["sensitive"]:
		if path in outcome["updated"]:
			sensitive.append(path)
	if not sensitive.is_empty():
		_warnings.append("Files in sensitive locations were rewritten: %s" % ", ".join(TextSanitizer.clean_lines(sensitive)))
	if not _references["settings"].is_empty():
		_warnings.append("project.godot was saved with the new path.")
	if _references["truncated"]:
		_warnings.append("The project has too many files to search them all; some references may remain.")
	if _note_untouched:
		_warnings.append("Other files that refer to the old path were not changed.")
	if not _open_scenes.is_empty():
		_warnings.append("Open scenes that referred to the file were saved and loaded again; their undo history is gone.")
	if _from in _context.open_scenes():
		_warnings.append("The moved scene is still open under its old path; open it from the new path.")
