extends RefCounted
## Playing and checking the running game, from inside it: sequences of real
## input events (keys, mouse, gamepad, actions), the game's speed, what its
## user interface shows, and checks of node values. Plain logic over the
## SceneTree, like game_inspector.gd, so it can be tested without a debugger.

const NodeRef = preload("../core/node_ref.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")
const ValueCodec = preload("../core/value_codec.gd")
const ValueDecoder = preload("../core/value_decoder.gd")

const MAX_EVENTS := 100
const MAX_SEQUENCE_SECONDS := 30.0
const MAX_HOLD_SECONDS := 10.0
# Long enough for a game that checks is_action_just_pressed in _physics_process.
const DEFAULT_TAP_SECONDS := 0.05
const MIN_SPEED := 0.05
const MAX_SPEED := 10.0
const MAX_UI_ELEMENTS := 300
const MAX_CHECKS := 50
const MAX_TEXT_CHARS := 500
const _MODIFIERS := {
	"ctrl": "ctrl_pressed", "control": "ctrl_pressed", "shift": "shift_pressed",
	"alt": "alt_pressed", "option": "alt_pressed", "meta": "meta_pressed", "cmd": "meta_pressed", "command": "meta_pressed",
}
const _MOUSE_BUTTONS := {"left": MOUSE_BUTTON_LEFT, "right": MOUSE_BUTTON_RIGHT, "middle": MOUSE_BUTTON_MIDDLE, "wheel_up": MOUSE_BUTTON_WHEEL_UP, "wheel_down": MOUSE_BUTTON_WHEEL_DOWN}
const _OPERATORS: Array[String] = ["equals", "not_equals", "approx", "less", "greater", "contains", "exists", "missing"]

var _tree: SceneTree


func _init(tree: SceneTree) -> void:
	_tree = tree


# ---------------------------------------------------------------------------
# Input sequences

## Sends each event in turn: one is pressed, held for its `hold` (game time),
## released, then the next one starts. {"wait": s} only lets time pass.
func input_events(args: Dictionary) -> Dictionary:
	var events: Variant = args.get("events")
	if not events is Array or events.is_empty() or events.size() > MAX_EVENTS:
		return Reply.fail("INVALID_ARGS", "events is a list of 1 to %d events." % MAX_EVENTS)
	var timeline := []
	var at := 0.0
	for index in events.size():
		var step: Variant = events[index]
		if not step is Dictionary:
			return _bad_event(index, "Each event is an object.")
		if step.has("wait"):
			var wait: Variant = step["wait"]
			if not (wait is float or wait is int) or wait < 0.0 or wait > MAX_HOLD_SECONDS:
				return _bad_event(index, "wait is 0 to %d seconds." % int(MAX_HOLD_SECONDS))
			at += float(wait)
			continue
		var made := _events_of(step)
		if made is String:
			return _bad_event(index, made)
		# A mouse move is instant unless told to take time; anything pressed is tapped.
		var hold: Variant = step.get("hold", DEFAULT_TAP_SECONDS if made["release"] != null else 0.0)
		if not (hold is float or hold is int) or hold < 0.0 or hold > MAX_HOLD_SECONDS:
			return _bad_event(index, "hold is 0 to %d seconds." % int(MAX_HOLD_SECONDS))
		timeline.append([at, made["press"]])
		# A mouse move has nothing to let go of.
		if made["release"] != null:
			timeline.append([at + float(hold), made["release"]])
		at += float(hold)
	if at > MAX_SEQUENCE_SECONDS:
		return Reply.fail("INVALID_ARGS", "The sequence lasts longer than %d seconds." % int(MAX_SEQUENCE_SECONDS), "Split it, and check the game in between.")
	for entry in timeline:
		_send_at(entry[0], entry[1])
	return Reply.ok({"events": events.size(), "duration": snappedf(at, 0.001)})


func _bad_event(index: int, message: String) -> Dictionary:
	return Reply.fail("INVALID_ARGS", message, "Events: {\"key\": \"Space\"}, {\"action\": \"jump\"}, {\"mouse_button\": \"left\", \"position\": [x, y]}, {\"mouse_move\": [x, y]}, {\"joypad_button\": 0}, {\"joypad_axis\": 0, \"value\": -1}, {\"wait\": 0.5}.", {"event": index})


## {press, release} input events for one step, or a message saying what is wrong.
func _events_of(step: Dictionary) -> Variant:
	if step.has("key"):
		var key: Variant = _key(step["key"])
		if key == null:
			return "Not a key name (\"Space\", \"A\", \"Ctrl+S\", \"Left\")."
		var up: InputEventKey = key.duplicate()
		up.pressed = false
		return {"press": key, "release": up}
	if step.has("action"):
		if not step["action"] is String or not InputMap.has_action(step["action"]):
			return "The project has no such input action."
		var strength: Variant = step.get("strength", 1.0)
		if not (strength is float or strength is int):
			return "strength is a number from 0 to 1."
		var down := InputEventAction.new()
		down.action = step["action"]
		down.pressed = true
		down.strength = clampf(strength, 0.0, 1.0)
		var released := InputEventAction.new()
		released.action = step["action"]
		return {"press": down, "release": released}
	if step.has("mouse_button"):
		var button: Variant = _MOUSE_BUTTONS.get(step["mouse_button"], step["mouse_button"])
		var position: Variant = _vector(step.get("position", null))
		if not (button is int or button is float) or int(button) < 1 or int(button) > 9 or position == null:
			return "mouse_button is left, right, middle, wheel_up, wheel_down or 1 to 9, with position [x, y] in the window."
		var click := InputEventMouseButton.new()
		click.button_index = int(button) as MouseButton
		click.position = position
		click.global_position = position
		click.pressed = true
		var let_go: InputEventMouseButton = click.duplicate()
		let_go.pressed = false
		return {"press": click, "release": let_go}
	if step.has("mouse_move"):
		var target: Variant = _vector(step["mouse_move"])
		if target == null:
			return "mouse_move is [x, y] in the window."
		var motion := InputEventMouseMotion.new()
		var from := _tree.root.get_mouse_position()
		motion.position = target
		motion.global_position = target
		motion.relative = target - from
		return {"press": motion, "release": null}
	if step.has("joypad_button"):
		var index: Variant = step["joypad_button"]
		if not (index is int or index is float) or int(index) < 0 or int(index) > 127:
			return "joypad_button is 0 to 127 (0 is the bottom face button)."
		var push := InputEventJoypadButton.new()
		push.button_index = int(index) as JoyButton
		push.device = int(step.get("device", 0))
		push.pressed = true
		var lift: InputEventJoypadButton = push.duplicate()
		lift.pressed = false
		return {"press": push, "release": lift}
	if step.has("joypad_axis"):
		var axis: Variant = step["joypad_axis"]
		var value: Variant = step.get("value", 1.0)
		if not (axis is int or axis is float) or int(axis) < 0 or int(axis) > 9 or not (value is float or value is int):
			return "joypad_axis is 0 to 9 (0 and 1 the left stick), with value -1 to 1."
		var tilt := InputEventJoypadMotion.new()
		tilt.axis = int(axis) as JoyAxis
		tilt.axis_value = clampf(value, -1.0, 1.0)
		tilt.device = int(step.get("device", 0))
		var centre: InputEventJoypadMotion = tilt.duplicate()
		centre.axis_value = 0.0
		return {"press": tilt, "release": centre}
	return "The event names no key, action, mouse_button, mouse_move, joypad_button, joypad_axis or wait."


## "Ctrl+S": the modifiers here, the key by the engine (as project_input_map_set reads them).
static func _key(text: Variant) -> InputEventKey:
	if not text is String or text.strip_edges() == "":
		return null
	var stripped: String = text.strip_edges()
	var key_name := "Plus" if stripped.ends_with("+") else ""
	var parts := stripped.trim_suffix("+").split("+", false) if key_name != "" else stripped.split("+", false)
	if key_name == "":
		key_name = parts[parts.size() - 1].strip_edges()
		parts.remove_at(parts.size() - 1)
	var keycode: int = OS.find_keycode_from_string(key_name) & KEY_CODE_MASK
	if keycode == KEY_NONE:
		return null
	var key := InputEventKey.new()
	key.keycode = keycode as Key
	key.physical_keycode = keycode as Key
	key.pressed = true
	for part in parts:
		var flag: String = _MODIFIERS.get(part.strip_edges().to_lower(), "")
		if flag == "":
			return null
		key.set(flag, true)
	return key


static func _vector(value: Variant) -> Variant:
	if value is Array and value.size() == 2 and (value[0] is float or value[0] is int) and (value[1] is float or value[1] is int):
		return Vector2(value[0], value[1])
	return null


# Game time: a paused game holds the key until it resumes; a slowed one holds it longer.
func _send_at(seconds: float, event: InputEvent) -> void:
	if seconds <= 0.0:
		Input.parse_input_event(event)
		return
	_tree.create_timer(seconds, false).timeout.connect(Input.parse_input_event.bind(event))


# ---------------------------------------------------------------------------
# Speed

func speed(args: Dictionary) -> Dictionary:
	var before := Engine.time_scale
	if args.has("scale"):
		var scale: Variant = args["scale"]
		if not (scale is float or scale is int) or scale < MIN_SPEED or scale > MAX_SPEED:
			return Reply.fail("INVALID_ARGS", "scale is %s to %s (1 is normal speed)." % [MIN_SPEED, MAX_SPEED])
		Engine.time_scale = float(scale)
	return Reply.ok({"scale": Engine.time_scale, "was": before})


# ---------------------------------------------------------------------------
# What the user interface shows

## The Controls a player can see now, with their text, place and state.
func ui(args: Dictionary) -> Dictionary:
	var start := NodeRef.resolve(_tree.root, args.get("path", NodeRef.ROOT_PATH)) if args.get("path", NodeRef.ROOT_PATH) is String else null
	if start == null:
		return Reply.fail("NODE_NOT_FOUND", "The node does not exist in the running game.", "Paths are relative to the root window; game_tree shows them.")
	var found := []
	var truncated := _collect_ui(start, found) if _ancestors_shown(start) else false
	return Reply.ok({"elements": found, "truncated": truncated})


# Each node's own visibility, its parents' already judged on the way down
# (is_visible_in_tree also asks the window, which a headless game hides).
func _collect_ui(node: Node, found: Array) -> bool:
	if (node is CanvasItem or node is CanvasLayer) and not node.visible:
		return false
	if node is Control:
		if found.size() >= MAX_UI_ELEMENTS:
			return true
		found.append(_describe_control(node))
	for child in node.get_children():
		if _collect_ui(child, found):
			return true
	return false


func _ancestors_shown(node: Node) -> bool:
	var above := node.get_parent()
	while above != null:
		if (above is CanvasItem or above is CanvasLayer) and not above.visible:
			return false
		above = above.get_parent()
	return true


func _describe_control(control: Control) -> Dictionary:
	var rect := control.get_global_rect()
	var entry := {
		"path": TextSanitizer.clean_line(NodeRef.path_of(_tree.root, control)),
		"type": control.get_class(),
		"rect": [snappedf(rect.position.x, 0.1), snappedf(rect.position.y, 0.1), snappedf(rect.size.x, 0.1), snappedf(rect.size.y, 0.1)],
	}
	var text := _text_of(control)
	if text != "":
		entry["text"] = text
	if control is BaseButton:
		entry["disabled"] = control.disabled
		if control.toggle_mode:
			entry["pressed"] = control.button_pressed
	if control is Range:
		entry["value"] = control.value
	if control.has_focus():
		entry["focused"] = true
	return entry


func _text_of(control: Control) -> String:
	var text := ""
	if control is RichTextLabel:
		text = control.get_parsed_text()
	elif control is Label or control is Button or control is LineEdit or control is TextEdit:
		text = str(control.get("text"))
	return TextSanitizer.clean_line(text.substr(0, MAX_TEXT_CHARS))


# ---------------------------------------------------------------------------
# Checks

## Each check: {path, property?, op, value?} or {text, op: exists|missing}.
## All are judged; the reply says which held, with the actual values.
func expect(args: Dictionary) -> Dictionary:
	var checks: Variant = args.get("checks")
	if not checks is Array or checks.is_empty() or checks.size() > MAX_CHECKS:
		return Reply.fail("INVALID_ARGS", "checks is a list of 1 to %d checks." % MAX_CHECKS)
	var results := []
	var passed := 0
	for index in checks.size():
		var judged := _judge(checks[index])
		if judged.has("error"):
			return Reply.fail("INVALID_ARGS", judged["error"], "A check is {\"path\": \"Main/Player\", \"property\": \"position:y\", \"op\": \"less\", \"value\": 300} or {\"text\": \"Game Over\", \"op\": \"exists\"}.", {"check": index})
		results.append(judged)
		if judged["passed"]:
			passed += 1
	return Reply.ok({"passed": passed == results.size(), "count": results.size(), "failed": results.size() - passed, "results": results})


func _judge(check: Variant) -> Dictionary:
	if not check is Dictionary:
		return {"error": "Each check is an object."}
	var op: Variant = check.get("op", "equals")
	if not op is String or op not in _OPERATORS:
		return {"error": "op is one of %s." % ", ".join(_OPERATORS)}
	if check.has("text"):
		if op != "exists" and op != "missing":
			return {"error": "A text check takes op exists or missing."}
		var shown := _text_on_screen(str(check["text"]))
		return {"text": TextSanitizer.clean_line(str(check["text"])), "op": op, "passed": shown == (op == "exists")}
	if not check.get("path") is String:
		return {"error": "A check names a path (or a text)."}
	var node := NodeRef.resolve(_tree.root, check["path"])
	var described := {"path": TextSanitizer.clean_line(check["path"]), "op": op}
	if op == "exists" or op == "missing":
		described["passed"] = (node != null) == (op == "exists")
		return described
	if node == null:
		described["passed"] = false
		described["actual"] = null
		described["reason"] = "no such node"
		return described
	if not check.get("property") is String:
		return {"error": "A value check names a property (\"position\", or \"position:y\" for one component)."}
	var actual: Variant = node.get_indexed(NodePath(check["property"]))
	described["property"] = TextSanitizer.clean_line(check["property"])
	described["actual"] = ValueCodec.encode(actual, _tree.root)
	var expected: Variant = check.get("value")
	var decoded: Dictionary = ValueDecoder.new(_tree.root).decode(expected, typeof(actual)) if actual != null else {"ok": true, "value": expected}
	if not decoded["ok"] and op != "contains":
		return {"error": "The value cannot be read as the property's type."}
	described["passed"] = _compare(actual, op, decoded.get("value", expected), check.get("tolerance", 0.01))
	return described


func _compare(actual: Variant, op: String, expected: Variant, tolerance: Variant) -> bool:
	match op:
		"equals":
			return typeof(actual) == typeof(expected) and actual == expected
		"not_equals":
			return not (typeof(actual) == typeof(expected) and actual == expected)
		"approx":
			var margin := float(tolerance) if tolerance is float or tolerance is int else 0.01
			if (actual is float or actual is int) and (expected is float or expected is int):
				return absf(float(actual) - float(expected)) <= margin
			if actual is Vector2 or actual is Vector3:
				return actual.distance_to(expected) <= margin
			return false
		"less":
			return (actual is float or actual is int) and (expected is float or expected is int) and actual < expected
		"greater":
			return (actual is float or actual is int) and (expected is float or expected is int) and actual > expected
		"contains":
			return (actual is String or actual is StringName) and str(actual).contains(str(expected))
	return false


func _text_on_screen(text: String) -> bool:
	var found := []
	_collect_ui(_tree.root, found)
	for element in found:
		if str(element.get("text", "")).contains(text):
			return true
	return false
