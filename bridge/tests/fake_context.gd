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
