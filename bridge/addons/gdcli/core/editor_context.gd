extends RefCounted
## Everything the bridge asks of the running editor. Tests substitute an
## object with the same methods.

const AccessPolicy = preload("access_policy.gd")
const ApprovalDialog = preload("approval_dialog.gd")

const SETTING_MODE := "gdcli/access/mode"
const SETTING_ALLOW_EVAL := "gdcli/access/allow_eval"
const PROJECT_SETTING_PREFIX := "gdcli/"
const HOST_FLAG := "--gdcli-host"
const GAME_HELPER_SETTING := "autoload/GdcliGame"
const SCREENSHOT_DIR_NAME := "screenshots"
const MAX_SCREENSHOTS := 20
const MAX_SCREENSHOT_BYTES := 64 * 1024 * 1024
const _SCREENSHOT_NAME_PATTERN := "^(editor|game)-[0-9]+[.]png$"

var _plugin: EditorPlugin
var _game_link: Object
var _screenshot_regex := RegEx.create_from_string(_SCREENSHOT_NAME_PATTERN)
var _error_log: RefCounted
var _home_dir: String


# The access mode lives in the per-user editor settings on purpose: the project
# file can be edited by the agent and arrives with any cloned repository.
func _init(plugin: EditorPlugin, error_log: RefCounted, home_dir: String) -> void:
	_plugin = plugin
	_error_log = error_log
	_home_dir = home_dir
	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting(SETTING_MODE):
		settings.set_setting(SETTING_MODE, AccessPolicy.MODE_STANDARD)
	settings.set_initial_value(SETTING_MODE, AccessPolicy.MODE_STANDARD, false)
	settings.add_property_info({
		"name": SETTING_MODE,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": ",".join(AccessPolicy.MODES),
	})
	if not settings.has_setting(SETTING_ALLOW_EVAL):
		settings.set_setting(SETTING_ALLOW_EVAL, false)
	settings.set_initial_value(SETTING_ALLOW_EVAL, false, false)


func scene_root() -> Node:
	return EditorInterface.get_edited_scene_root()


func scene_path() -> String:
	var root := scene_root()
	return "" if root == null else root.scene_file_path


func open_scenes() -> PackedStringArray:
	return EditorInterface.get_open_scenes()


func selected_nodes() -> Array:
	return EditorInterface.get_selection().get_selected_nodes()


func is_playing() -> bool:
	return EditorInterface.is_playing_scene()


func is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


func access_mode() -> String:
	return AccessPolicy.normalize_mode(EditorInterface.get_editor_settings().get_setting(SETTING_MODE))


func allow_eval() -> bool:
	return EditorInterface.get_editor_settings().get_setting(SETTING_ALLOW_EVAL) == true


## The undo manager of the editor: changes made through it show up in the
## editor's history and can be taken back with Ctrl+Z.
func undo_redo() -> Object:
	return _plugin.get_undo_redo()


## The plain UndoRedo that holds the history of the edited scene.
func scene_history() -> Object:
	var manager := _plugin.get_undo_redo()
	return manager.get_history_undo_redo(manager.get_object_history_id(scene_root()))


func open_scene(path: String) -> void:
	EditorInterface.open_scene_from_path(path)


## The editor answers OK even when it could not write the file (it only logs
## "Cannot save file"): a read-only file and a folder that is gone are found
## before, and a file that is still missing after.
func save_scene() -> Error:
	var path := scene_path()
	if path != "" and not _can_write(path):
		return ERR_FILE_CANT_WRITE
	var result := EditorInterface.save_scene()
	if result == OK and path != "" and not FileAccess.file_exists(path):
		return ERR_FILE_CANT_WRITE
	return result


static func _can_write(path: String) -> bool:
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path.get_base_dir())):
		return false
	if not FileAccess.file_exists(path):
		return true
	# Opened for reading and writing, which changes nothing, and fails on a read-only file.
	return FileAccess.open(path, FileAccess.READ_WRITE) != null


## Loads an open scene again from its file, dropping what is in memory.
func reload_scene(path: String) -> void:
	EditorInterface.reload_scene_from_path(path)


## Tells the editor about one file written behind its back.
func file_changed(path: String) -> void:
	EditorInterface.get_resource_filesystem().update_file(path)


func scan_files() -> void:
	var filesystem := EditorInterface.get_resource_filesystem()
	if not filesystem.is_scanning():
		filesystem.scan()


func is_scanning() -> bool:
	return EditorInterface.get_resource_filesystem().is_scanning()


## Imports files again with the settings now in their .import files.
func reimport(paths: Array) -> void:
	EditorInterface.get_resource_filesystem().reimport_files(PackedStringArray(paths))


func play(scene: String) -> void:
	if scene == "":
		EditorInterface.play_main_scene()
	else:
		EditorInterface.play_custom_scene(scene)


func stop() -> void:
	EditorInterface.stop_playing_scene()


func editor_interface() -> Object:
	return EditorInterface


func error_log() -> RefCounted:
	return _error_log


## True when gd started this editor as a headless host (`gd host start`).
func is_host() -> bool:
	return is_headless() and HOST_FLAG in OS.get_cmdline_user_args()


func quit_soon() -> void:
	# Deferred so that the reply to the request is written first.
	_plugin.get_tree().create_timer(0.5).timeout.connect(_plugin.get_tree().quit)


## Saves a picture of the editor window outside the project.
## Returns {path, width, height}, or {} on failure.
func save_screenshot() -> Dictionary:
	var image := EditorInterface.get_base_control().get_viewport().get_texture().get_image()
	if image == null:
		return {}
	var path := store_screenshot(image.save_png_to_buffer(), "editor")
	if path == "":
		return {}
	return {"path": path, "width": image.get_width(), "height": image.get_height()}


## Writes PNG data into the screenshot folder under the gd home directory.
## Returns the absolute path, or "" on failure.
func store_screenshot(png: PackedByteArray, prefix: String) -> String:
	if _home_dir == "" or png.is_empty() or png.size() > MAX_SCREENSHOT_BYTES:
		return ""
	var directory := _home_dir.path_join(SCREENSHOT_DIR_NAME)
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return ""
	var path := directory.path_join("%s-%d.png" % [prefix, Time.get_ticks_usec()])
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_buffer(png)
	file.close()
	# Keep the folder from growing without bound: the oldest files go first.
	var files := []
	for name in DirAccess.get_files_at(directory):
		if _screenshot_regex.search(name) != null:
			files.append(name)
	files.sort_custom(_older_first)
	for stale in files.slice(0, maxi(files.size() - MAX_SCREENSHOTS, 0)):
		DirAccess.remove_absolute(directory.path_join(stale))
	return path


# File names are "<prefix>-<microseconds>.png".
func _older_first(a: String, b: String) -> bool:
	return a.get_slice("-", 1).to_int() < b.get_slice("-", 1).to_int()


## Puts a question to the person at the editor (see approval.gd). Returns an
## object whose `decision` is "" until they answer, or null when nobody can be
## asked because the editor has no window.
func ask_person(what: Dictionary) -> Object:
	if is_headless():
		return null
	return ApprovalDialog.new(EditorInterface.get_base_control(), what)


func set_game_link(link: Object) -> void:
	_game_link = link


## The connection to the game the editor is running (core/game_link.gd).
func game_link() -> Object:
	return _game_link


## Whether the project loads the helper that answers from inside the game.
func game_helper_installed() -> bool:
	return ProjectSettings.has_setting(GAME_HELPER_SETTING)


## Settings under gdcli/ in the project file are ignored; say so once.
func ignored_project_settings() -> Array:
	var ignored := []
	for property in ProjectSettings.get_property_list():
		var name: String = property["name"]
		if name.begins_with(PROJECT_SETTING_PREFIX):
			ignored.append(name)
	return ignored
