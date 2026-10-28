extends RefCounted
## Stands in for core/editor_context.gd in unit tests.

var root: Node = null
var path := ""
var open: PackedStringArray = PackedStringArray()
var selected: Array = []
var playing := false
var headless := true
var mode := "standard"
var eval_allowed := false


func scene_root() -> Node:
	return root


func scene_path() -> String:
	return path


func open_scenes() -> PackedStringArray:
	return open


func selected_nodes() -> Array:
	return selected


func is_playing() -> bool:
	return playing


func is_headless() -> bool:
	return headless


func access_mode() -> String:
	return mode


func allow_eval() -> bool:
	return eval_allowed


# --- used by the commands that change something ------------------------------

const FakeUndo = preload("res://tests/fake_undo.gd")

var undo := FakeUndo.new()
var opened: Array[String] = []
var changed_files: Array[String] = []
var scans := 0
var played: Array[String] = []
var stopped := 0
var host := false
var quit_requested := false
var log: RefCounted = null
var save_result: Error = OK
var saved_scenes: Array[String] = []
var reloaded: Array[String] = []


func undo_redo() -> Object:
	return undo


func scene_history() -> Object:
	return undo


func open_scene(scene: String) -> void:
	opened.append(scene)
	path = scene


func save_scene() -> Error:
	saved_scenes.append(path)
	return save_result




func reload_scene(scene: String) -> void:
	reloaded.append(scene)


func file_changed(file: String) -> void:
	changed_files.append(file)


func scan_files() -> void:
	scans += 1


var scanning := false
var reimported: Array = []


func is_scanning() -> bool:
	return scanning


func reimport(paths: Array) -> void:
	reimported.append_array(paths)


func play(scene: String) -> void:
	played.append(scene)
	playing = true


func stop() -> void:
	stopped += 1
	playing = false


func editor_interface() -> Object:
	return self


func error_log() -> RefCounted:
	return log


func is_host() -> bool:
	return host


func quit_soon() -> void:
	quit_requested = true


## Stands in for the question a person answers in the editor.
class Question:
	extends RefCounted

	var decision := ""
	var what: Dictionary
	var closed := false

	func close() -> void:
		closed = true
		if decision == "":
			decision = "denied"


var questions: Array = []
## What the person answers at once: "allowed", "denied", or "" to keep waiting.
var answer := "denied"
var has_window := true


func ask_person(what: Dictionary) -> Object:
	if not has_window:
		return null
	var question := Question.new()
	question.what = what
	question.decision = answer
	questions.append(question)
	return question


var link: Object = null
var helper_installed := true
var stored: Array = []


func game_link() -> Object:
	return link


func game_helper_installed() -> bool:
	return helper_installed


func store_screenshot(png: PackedByteArray, prefix: String) -> String:
	stored.append({"bytes": png.size(), "prefix": prefix})
	return "/tmp/%s.png" % prefix


func save_screenshot() -> Dictionary:
	return {"path": "/tmp/shot.png", "width": 4, "height": 3}
