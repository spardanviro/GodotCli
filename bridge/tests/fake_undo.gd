extends RefCounted
## Stands in for both EditorUndoRedoManager and the scene's UndoRedo in unit
## tests. Like the real ones, it runs "do" operations on commit and runs the
## undo operations in the order they were added.

var _unset := RefCounted.new()
var _history: Array = []
var _position := 0
var _building := {}


func create_action(name: String, _merge_mode: int = 0, _context: Object = null, _backward: bool = false) -> void:
	_building = {"name": name, "do": [], "undo": []}


func add_do_method(object: Object, method: String, a: Variant = _unset, b: Variant = _unset, c: Variant = _unset) -> void:
	_building["do"].append(_callable(object, method, [a, b, c]))


func add_undo_method(object: Object, method: String, a: Variant = _unset, b: Variant = _unset, c: Variant = _unset) -> void:
	_building["undo"].append(_callable(object, method, [a, b, c]))


func add_do_property(object: Object, property: String, value: Variant) -> void:
	_building["do"].append(object.set.bind(property, value))


func add_undo_property(object: Object, property: String, value: Variant) -> void:
	_building["undo"].append(object.set.bind(property, value))


func add_do_reference(_object: Object) -> void:
	pass


func add_undo_reference(_object: Object) -> void:
	pass


func commit_action() -> void:
	_history = _history.slice(0, _position)
	_history.append(_building)
	_position += 1
	for operation in _building["do"]:
		operation.call()
	_building = {}


func has_undo() -> bool:
	return _position > 0


func has_redo() -> bool:
	return _position < _history.size()


func get_current_action_name() -> String:
	return "" if _position == 0 else _history[_position - 1]["name"]


func undo() -> void:
	_position -= 1
	for operation in _history[_position]["undo"]:
		operation.call()


func redo() -> void:
	for operation in _history[_position]["do"]:
		operation.call()
	_position += 1


func action_names() -> Array:
	var names := []
	for action in _history.slice(0, _position):
		names.append(action["name"])
	return names


func _callable(object: Object, method: String, arguments: Array) -> Callable:
	var given := []
	for argument in arguments:
		if not (argument is Object and argument == _unset):
			given.append(argument)
	return Callable(object, method).bindv(given)
