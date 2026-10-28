extends SceneTree
## Evaluates the checks of an eval task that need the engine: scenes, nodes,
## properties, scripts, project settings, input actions. Run by evals/run.mjs:
##   godot --headless --path <project> --script <this file> -- <checks.json> <out.json>
## Writes [{index, ok, detail}] for the checks it knows and leaves the rest out.
## The checks come from the task files of this repository, not from the agent.

const SCENE_CHECKS := ["node", "node_missing", "node_count", "expression", "setting", "input_action", "script_compiles"]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var results: Array = []
	if args.size() == 2:
		var checks = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
		if checks is Array:
			for index in checks.size():
				var check: Dictionary = checks[index]
				if check.get("type", "") in SCENE_CHECKS:
					var verdict = _evaluate(check)
					if not (verdict is Dictionary):
						verdict = _fail("the check could not be evaluated")
					verdict["index"] = index
					results.append(verdict)
					# Written after every check: should one still fail hard, the others count.
					_write(args[1], results)
		_write(args[1], results)
	quit()


func _write(path: String, results: Array) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(results))


func _evaluate(check: Dictionary) -> Dictionary:
	match check.get("type", ""):
		"setting":
			return _setting(check)
		"input_action":
			return _input_action(check)
		"script_compiles":
			return _script_compiles(check)
	var scene_path: String = check.get("scene", "res://main.tscn")
	if not ResourceLoader.exists(scene_path):
		return _fail("scene missing: " + scene_path)
	var packed := load(scene_path) as PackedScene
	if packed == null:
		return _fail("scene does not load: " + scene_path)
	var root := packed.instantiate()
	if root == null:
		return _fail("scene does not instantiate: " + scene_path)
	var verdict: Dictionary
	match check["type"]:
		"node":
			verdict = _node(root, check)
		"node_missing":
			verdict = _ok() if root.get_node_or_null(NodePath(check["path"])) == null else _fail("node exists: " + str(check["path"]))
		"node_count":
			var count := _find(root, check["class"]).size()
			var low: int = check.get("min", 0)
			var high: int = check.get("max", 1_000_000)
			verdict = _ok() if count >= low and count <= high else _fail("%d nodes of class %s" % [count, check["class"]])
		"expression":
			verdict = _expression(root, check)
	root.free()
	return verdict


func _node(root: Node, check: Dictionary) -> Dictionary:
	var path: String = check["path"]
	var node := root if path == "." else root.get_node_or_null(NodePath(path))
	if node == null:
		return _fail("node not found: " + path)
	if check.has("class") and not node.is_class(check["class"]):
		return _fail("%s is a %s, not a %s" % [path, node.get_class(), check["class"]])
	if check.get("script", false) and node.get_script() == null:
		return _fail("no script on " + path)
	if check.has("group") and not node.is_in_group(check["group"]):
		return _fail("%s is not in group %s" % [path, check["group"]])
	var properties: Dictionary = check.get("properties", {})
	for name in properties:
		if not (name in node):
			return _fail("%s has no property %s" % [path, name])
		var expected = properties[name]
		var actual = node.get(name)
		if not _equal(actual, expected):
			return _fail("%s.%s = %s, expected %s" % [path, name, var_to_str(actual), str(expected)])
	return _ok()


## Expected values are written as GDScript literals ("Vector2(100, 50)") or JSON values.
## Never raises: a runtime error here would stop the script before it writes its results.
func _equal(actual, expected) -> bool:
	# A text property is compared as text: "10" stays the string "10".
	if actual is String or actual is StringName or actual is NodePath:
		return expected is String and str(actual) == expected
	var wanted = expected
	if expected is String:
		var parsed = str_to_var(expected)
		if parsed == null:
			return false
		wanted = parsed
	var numbers := [TYPE_INT, TYPE_FLOAT]
	if typeof(actual) in numbers or typeof(wanted) in numbers:
		return typeof(actual) in numbers and typeof(wanted) in numbers and is_equal_approx(float(actual), float(wanted))
	if typeof(actual) != typeof(wanted):
		return false
	if typeof(actual) in [TYPE_VECTOR2, TYPE_VECTOR3, TYPE_COLOR, TYPE_RECT2]:
		return actual.is_equal_approx(wanted)
	return actual == wanted


func _expression(root: Node, check: Dictionary) -> Dictionary:
	var expression := Expression.new()
	# Expressions cannot reach the engine's singletons by themselves.
	if expression.parse(check["code"], ["root", "helper", "AudioServer", "ProjectSettings", "TranslationServer"]) != OK:
		return _fail("expression does not parse: " + expression.get_error_text())
	var result = expression.execute([root, self, AudioServer, ProjectSettings, TranslationServer], self)
	if expression.has_execute_failed():
		return _fail("expression failed: " + expression.get_error_text())
	return _ok() if result == true else _fail("false: " + str(check["code"]))


## For expressions: the classes of the effects on a bus, in order (empty for no such bus).
func bus_effects(bus_name: String) -> PackedStringArray:
	var bus := AudioServer.get_bus_index(bus_name)
	var classes := PackedStringArray()
	if bus >= 0:
		for index in AudioServer.get_bus_effect_count(bus):
			classes.append(AudioServer.get_bus_effect(bus, index).get_class())
	return classes


## For expressions: every node below (and including) root of a class.
## Whether a script's code (its comments left out) contains the text: a word
## written only in a comment does not count as done.
func code_contains(path: String, text: String) -> bool:
	var code := PackedStringArray()
	for line in FileAccess.get_file_as_string(path).split("\n"):
		code.append(_without_comment(line))
	return "\n".join(code).contains(text)


# The line up to a # that is not inside a string.
static func _without_comment(line: String) -> String:
	var quote := ""
	for index in line.length():
		var character := line[index]
		if quote != "":
			if character == "\\":
				continue
			if character == quote and (index == 0 or line[index - 1] != "\\"):
				quote = ""
		elif character == "\"" or character == "'":
			quote = character
		elif character == "#":
			return line.substr(0, index)
	return line


## For expressions, which cannot call load(): a resource of the project, or null.
func res(path: String) -> Resource:
	return ResourceLoader.load(path) if path != "" and ResourceLoader.exists(path) else null


func find(root: Node, class_name_text: String) -> Array:
	return _find(root, class_name_text)


func _find(root: Node, class_name_text: String) -> Array:
	var found: Array = []
	if root.is_class(class_name_text):
		found.append(root)
	for child in root.get_children():
		found.append_array(_find(child, class_name_text))
	return found


func _setting(check: Dictionary) -> Dictionary:
	var name: String = check["name"]
	if not ProjectSettings.has_setting(name):
		return _fail("setting missing: " + name)
	if check.has("equals") and not _equal(ProjectSettings.get_setting(name), check["equals"]):
		return _fail("%s = %s" % [name, var_to_str(ProjectSettings.get_setting(name))])
	return _ok()


func _input_action(check: Dictionary) -> Dictionary:
	var name: String = check["name"]
	var setting = ProjectSettings.get_setting("input/" + name)
	if not (setting is Dictionary):
		return _fail("input action missing: " + name)
	var keys: Array = check.get("keycodes", [])
	if keys.is_empty():
		return _ok()
	var codes := keys.map(func(key): return int(key))  # JSON numbers arrive as floats.
	for event in setting.get("events", []):
		if event is InputEventKey and (int(event.physical_keycode) in codes or int(event.keycode) in codes):
			return _ok()
	return _fail("%s is not bound to any of %s" % [name, str(keys)])


func _script_compiles(check: Dictionary) -> Dictionary:
	var file: String = check["file"]
	if not FileAccess.file_exists(file):
		return _fail("missing file: " + file)
	# Loaded from its path, so a class_name is its own and not a second one.
	var script = ResourceLoader.load(file, "", ResourceLoader.CACHE_MODE_IGNORE)
	return _ok() if script is Script and script.can_instantiate() else _fail("does not compile: " + file)


func _ok() -> Dictionary:
	return {"ok": true, "detail": ""}


func _fail(detail: String) -> Dictionary:
	return {"ok": false, "detail": detail}
