extends RefCounted
## Everything the bridge asks of the running editor. Tests substitute an
## object with the same methods.

const AccessPolicy = preload("access_policy.gd")

const SETTING_MODE := "gdcli/access/mode"
const SETTING_ALLOW_EVAL := "gdcli/access/allow_eval"
const PROJECT_SETTING_PREFIX := "gdcli/"
const HOST_FLAG := "--gdcli-host"
const SCREENSHOT_DIR_NAME := "screenshots"
const MAX_SCREENSHOTS := 20

var _plugin: EditorPlugin
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


func save_scene() -> Error:
	return EditorInterface.save_scene()


## Tells the editor about one file written behind its back.
func file_changed(path: String) -> void:
	EditorInterface.get_resource_filesystem().update_file(path)


func scan_files() -> void:
	var filesystem := EditorInterface.get_resource_filesystem()
	if not filesystem.is_scanning():
		filesystem.scan()


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
	if image == null or _home_dir == "":
		return {}
	var directory := _home_dir.path_join(SCREENSHOT_DIR_NAME)
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return {}
	var path := directory.path_join("editor-%d.png" % Time.get_ticks_usec())
	if image.save_png(path) != OK:
		return {}
	# Keep the folder from growing without bound.
	var files := Array(DirAccess.get_files_at(directory))
	files.sort()
	for stale in files.slice(0, maxi(files.size() - MAX_SCREENSHOTS, 0)):
		DirAccess.remove_absolute(directory.path_join(stale))
	return {"path": path, "width": image.get_width(), "height": image.get_height()}


## Settings under gdcli/ in the project file are ignored; say so once.
func ignored_project_settings() -> Array:
	var ignored := []
	for property in ProjectSettings.get_property_list():
		var name: String = property["name"]
		if name.begins_with(PROJECT_SETTING_PREFIX):
			ignored.append(name)
	return ignored
