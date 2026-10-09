extends RefCounted
## Everything the bridge asks of the running editor. Tests substitute an
## object with the same methods.

const AccessPolicy = preload("access_policy.gd")

const SETTING_MODE := "gdcli/access/mode"
const SETTING_ALLOW_EVAL := "gdcli/access/allow_eval"
const PROJECT_SETTING_PREFIX := "gdcli/"


# The access mode lives in the per-user editor settings on purpose: the project
# file can be edited by the agent and arrives with any cloned repository.
func _init() -> void:
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


## Settings under gdcli/ in the project file are ignored; say so once.
func ignored_project_settings() -> Array:
	var ignored := []
	for property in ProjectSettings.get_property_list():
		var name: String = property["name"]
		if name.begins_with(PROJECT_SETTING_PREFIX):
			ignored.append(name)
	return ignored
