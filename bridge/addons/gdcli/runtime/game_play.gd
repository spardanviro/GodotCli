extends RefCounted
## Playing and checking the running game, from inside it: sequences of real
## input events (keys, typed text, mouse clicks, drags and moves, gamepad,
## actions), the game's speed, what its user interface shows, and checks of
## node values. Plain logic over the SceneTree, like game_inspector.gd, so it
## can be tested without a debugger.
##
## Positions are in the window's pixels, the coordinates a mouse event has:
## game_ui reports controls in them, so a click on a control's centre lands on
## it whatever the stretch mode, canvas layer or camera.

const NodeRef = preload("../core/node_ref.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")
const ValueCodec = preload("../core/value_codec.gd")
const ValueDecoder = preload("../core/value_decoder.gd")

const MAX_EVENTS := 100
const MAX_SEQUENCE_SECONDS := 30.0
const MAX_HOLD_SECONDS := 10.0
const MAX_TYPED_CHARS := 200
# Long enough for a game that checks is_action_just_pressed in _physics_process.
const DEFAULT_TAP_SECONDS := 0.05
const DEFAULT_DRAG_SECONDS := 0.3
const TYPED_CHAR_SECONDS := 0.03
const MIN_SPEED := 0.05
const MAX_SPEED := 10.0
const MAX_UI_ELEMENTS := 300
const MAX_CHECKS := 50
const MAX_TEXT_CHARS := 500
const MAX_DEVICE := 15
const _MODIFIERS := {
	"ctrl": "ctrl_pressed", "control": "ctrl_pressed", "shift": "shift_pressed",
	"alt": "alt_pressed", "option": "alt_pressed", "meta": "meta_pressed", "cmd": "meta_pressed", "command": "meta_pressed",
}
const _MOUSE_BUTTONS := {"left": MOUSE_BUTTON_LEFT, "right": MOUSE_BUTTON_RIGHT, "middle": MOUSE_BUTTON_MIDDLE, "wheel_up": MOUSE_BUTTON_WHEEL_UP, "wheel_down": MOUSE_BUTTON_WHEEL_DOWN}
const _OPERATORS: Array[String] = ["equals", "not_equals", "approx", "less", "greater", "contains", "exists", "missing"]
const _HINT := "Events: {\"key\": \"Space\"}, {\"text\": \"hello\"}, {\"action\": \"jump\"}, {\"mouse_button\": \"left\", \"position\": [x, y]}, {\"drag\": [[x1, y1], [x2, y2]]}, {\"mouse_move\": [x, y]}, {\"joypad_button\": 0}, {\"joypad_axis\": 0, \"value\": -1}, {\"wait\": 0.5}."

var _tree: SceneTree
# Where the mouse is, in window pixels, as the sequence being planned moves it.
var _mouse := Vector2.ZERO


func _init(tree: SceneTree) -> void:
	_tree = tree


# ---------------------------------------------------------------------------
# Input sequences

## Plans the whole sequence first (nothing is sent when any event is wrong),
## then sends each event at its time. One event is pressed, held for its
## `hold` (game time), released, then the next one starts.
func input_events(args: Dictionary) -> Dictionary:
	var events: Variant = args.get("events")
	if not events is Array or events.is_empty() or events.size() > MAX_EVENTS:
		return Reply.fail("INVALID_ARGS", "events is a list of 1 to %d events." % MAX_EVENTS)
	_mouse = _to_window(_tree.root.get_mouse_position())
	var timeline := []
	var at := 0.0
	for index in events.size():
		var step: Variant = events[index]
		if not step is Dictionary:
			return _bad_event(index, "Each event is an object.")
		var planned: Variant = _plan(step)
		if planned is String:
			return _bad_event(index, planned)
		for entry in planned["timed"]:
			timeline.append([at + entry[0], entry[1]])
		at += planned["duration"]
	if at > MAX_SEQUENCE_SECONDS:
		return Reply.fail("INVALID_ARGS", "The sequence lasts longer than %d seconds." % int(MAX_SEQUENCE_SECONDS), "Split it, and check the game in between.")
	for entry in timeline:
		_send_at(entry[0], entry[1])
	return Reply.ok({"events": events.size(), "duration": snappedf(at, 0.001)})


func _bad_event(index: int, message: String) -> Dictionary:
	return Reply.fail("INVALID_ARGS", message, _HINT, {"event": index})


## {timed: [[seconds from the event's start, InputEvent]], duration}, or a message.
func _plan(step: Dictionary) -> Variant:
	if step.has("wait"):
		var wait: Variant = _seconds(step["wait"])
		return "wait is 0 to %d seconds." % int(MAX_HOLD_SECONDS) if wait == null else {"timed": [], "duration": wait}
	if step.has("text"):
		return _plan_text(step["text"])
	if step.has("drag"):
		return _plan_drag(step)
	if step.has("mouse_move"):
		var target: Variant = _vector(step["mouse_move"])
		if target == null:
			return "mouse_move is [x, y] in the window."
		var hold: Variant = _seconds(step.get("hold", 0.0))
		if hold == null:
			return "hold is 0 to %d seconds." % int(MAX_HOLD_SECONDS)
		return {"timed": [[0.0, _motion(target, 0)]], "duration": hold}
	var made: Variant = _press_release(step)
	if made is String:
		return made
	var held: Variant = _seconds(step.get("hold", DEFAULT_TAP_SECONDS))
	if held == null:
		return "hold is 0 to %d seconds." % int(MAX_HOLD_SECONDS)
	var timed := [[0.0, made[0]], [held, made[1]]]
	# The mouse goes to the place first, so hover and focus follow as with a real one.
	if made[0] is InputEventMouseButton:
		timed.push_front([0.0, _motion(made[0].position, 0)])
	return {"timed": timed, "duration": held}


func _seconds(value: Variant) -> Variant:
	if not (value is float or value is int) or value < 0.0 or value > MAX_HOLD_SECONDS:
		return null
	return float(value)


## [pressed event, released event] for a key, action, mouse button or gamepad input.
func _press_release(step: Dictionary) -> Variant:
	if step.has("key"):
		var key: Variant = _key(step["key"])
		if key == null:
			return "Not a key name (\"Space\", \"A\", \"Ctrl+S\", \"Left\")."
		var up: InputEventKey = key.duplicate()
		up.pressed = false
		return [key, up]
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
		return [down, released]
	if step.has("mouse_button"):
		var button: Variant = _button(step["mouse_button"])
		var position: Variant = _vector(step.get("position", null))
		if button == null or position == null:
			return "mouse_button is left, right, middle, wheel_up, wheel_down or 1 to 9, with position [x, y] in the window."
		var click := _click(button, position, true)
		return [click, _click(button, position, false)]
	var device: Variant = step.get("device", 0)
	if not (device is int or device is float) or int(device) < 0 or int(device) > MAX_DEVICE:
		return "device is 0 to %d." % MAX_DEVICE
	if step.has("joypad_button"):
		var index: Variant = step["joypad_button"]
		if not (index is int or index is float) or int(index) < 0 or int(index) > 127:
			return "joypad_button is 0 to 127 (0 is the bottom face button)."
		var push := InputEventJoypadButton.new()
		push.button_index = int(index) as JoyButton
		push.device = int(device)
		push.pressed = true
		var lift: InputEventJoypadButton = push.duplicate()
		lift.pressed = false
		return [push, lift]
	if step.has("joypad_axis"):
		var axis: Variant = step["joypad_axis"]
		var value: Variant = step.get("value", 1.0)
		if not (axis is int or axis is float) or int(axis) < 0 or int(axis) > 9 or not (value is float or value is int):
			return "joypad_axis is 0 to 9 (0 and 1 the left stick), with value -1 to 1."
		var tilt := InputEventJoypadMotion.new()
		tilt.axis = int(axis) as JoyAxis
		tilt.axis_value = clampf(value, -1.0, 1.0)
		tilt.device = int(device)
		var centre: InputEventJoypadMotion = tilt.duplicate()
		centre.axis_value = 0.0
		return [tilt, centre]
	return "The event names no key, text, action, mouse_button, drag, mouse_move, joypad_button, joypad_axis or wait."


## Each character typed as a key with its character, so a focused LineEdit
## receives it.
func _plan_text(text: Variant) -> Variant:
	if not text is String or text == "" or text.length() > MAX_TYPED_CHARS:
		return "text is 1 to %d characters to type." % MAX_TYPED_CHARS
	var timed := []
	for index in text.length():
		var character: String = text[index]
		var down := InputEventKey.new()
		down.unicode = character.unicode_at(0)
		var keycode: int = OS.find_keycode_from_string(character.to_upper()) & KEY_CODE_MASK
		down.keycode = keycode as Key
		down.physical_keycode = keycode as Key
		down.shift_pressed = character != character.to_lower()
		down.pressed = true
		var up: InputEventKey = down.duplicate()
		up.pressed = false
		timed.append([index * TYPED_CHAR_SECONDS, down])
		timed.append([index * TYPED_CHAR_SECONDS + TYPED_CHAR_SECONDS / 2.0, up])
	return {"timed": timed, "duration": text.length() * TYPED_CHAR_SECONDS}


## Press at the first point, move to the second with the button held, release there.
func _plan_drag(step: Dictionary) -> Variant:
	var points: Variant = step["drag"]
	var from: Variant = _vector(points[0]) if points is Array and points.size() == 2 else null
	var to: Variant = _vector(points[1]) if from != null else null
	var button: Variant = _button(step.get("button", "left"))
	var hold: Variant = _seconds(step.get("hold", DEFAULT_DRAG_SECONDS))
	if to == null or button == null or hold == null:
		return "drag is [[x1, y1], [x2, y2]] in the window, with button (default left) and hold (seconds, default 0.3)."
	var mask: int = 1 << (int(button) - 1)
	var timed := [[0.0, _motion(from, 0)], [0.0, _click(button, from, true)]]
	var steps := 4
	for index in range(1, steps + 1):
		timed.append([hold * index / (steps + 1), _motion(from.lerp(to, float(index) / steps), mask)])
	timed.append([hold, _click(button, to, false)])
	return {"timed": timed, "duration": hold}


func _button(value: Variant) -> Variant:
	var button: Variant = _MOUSE_BUTTONS.get(value, value) if value is String else value
	if not (button is int or button is float) or int(button) < 1 or int(button) > 9:
		return null
	return int(button)


func _click(button: int, position: Vector2, pressed: bool) -> InputEventMouseButton:
	var click := InputEventMouseButton.new()
	click.button_index = button as MouseButton
	click.position = position
	click.global_position = position
	click.pressed = pressed
	click.button_mask = (1 << (button - 1)) if pressed else 0
	return click


func _motion(target: Vector2, mask: int) -> InputEventMouseMotion:
	var motion := InputEventMouseMotion.new()
	motion.position = target
	motion.global_position = target
	motion.relative = target - _mouse
	motion.button_mask = mask
	_mouse = target
	return motion


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
	# A single character, or Space, also types itself into a focused text field.
	if key_name.length() == 1:
		key.unicode = key_name.to_lower().unicode_at(0)
	elif key_name.to_lower() == "space":
		key.unicode = 32
	for part in parts:
		var flag: String = _MODIFIERS.get(part.strip_edges().to_lower(), "")
		if flag == "":
			return null
		key.set(flag, true)
	if key.ctrl_pressed or key.alt_pressed or key.meta_pressed:
		key.unicode = 0
	elif key.shift_pressed and key_name.length() == 1:
		key.unicode = key_name.to_upper().unicode_at(0)
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


# From the root viewport's coordinates to the window's pixels (the stretch mode's scale and offset).
func _to_window(point: Vector2) -> Vector2:
	return _tree.root.get_final_transform() * point


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
	var truncated := _collect_ui(start, found, MAX_UI_ELEMENTS) if _ancestors_shown(start) else false
	var described := []
	for control in found:
		described.append(_describe_control(control))
	return Reply.ok({"elements": described, "truncated": truncated})


## Whether a node is hidden by its own visibility: a CanvasItem, a CanvasLayer
## or a Window (a dialog or popup) that is not shown.
static func _hidden(node: Node) -> bool:
	return (node is CanvasItem or node is CanvasLayer or node is Window) and not node.visible


# Each node's own visibility, its parents' already judged on the way down
# (is_visible_in_tree also asks the window, which a headless game hides; the
# root window is the game itself and counts as shown). Returns whether the
# list was cut at `most`; most < 0 is no limit.
func _collect_ui(node: Node, found: Array, most: int) -> bool:
	if node != _tree.root and _hidden(node):
		return false
	if node is Control:
		if most >= 0 and found.size() >= most:
			return true
		found.append(node)
	for child in node.get_children():
		if _collect_ui(child, found, most):
			return true
	return false


func _ancestors_shown(node: Node) -> bool:
	var above := node.get_parent()
	while above != null and above != _tree.root:
		if _hidden(above):
			return false
		above = above.get_parent()
	return true


func _describe_control(control: Control) -> Dictionary:
	# Through canvas layers and cameras to the viewport, then to the window.
	var to_window := _tree.root.get_final_transform() * control.get_global_transform_with_canvas()
	var corner := to_window * Vector2.ZERO
	var size := to_window.basis_xform(control.size).abs()
	var entry := {
		"path": TextSanitizer.clean_line(NodeRef.path_of(_tree.root, control)),
		"type": control.get_class(),
		"rect": [snappedf(corner.x, 0.1), snappedf(corner.y, 0.1), snappedf(size.x, 0.1), snappedf(size.y, 0.1)],
		"center": [snappedf(corner.x + size.x / 2.0, 0.1), snappedf(corner.y + size.y / 2.0, 0.1)],
	}
	var text := _raw_text(control)
	if text != "":
		entry["text"] = TextSanitizer.clean_line(text.substr(0, MAX_TEXT_CHARS))
	if control is BaseButton:
		entry["disabled"] = control.disabled
		if control.toggle_mode:
			entry["pressed"] = control.button_pressed
	if control is Range:
		entry["value"] = control.value
	if control.has_focus():
		entry["focused"] = true
	return entry


func _raw_text(control: Control) -> String:
	if control is RichTextLabel:
		return control.get_parsed_text()
	if control is Label or control is Button or control is LineEdit or control is TextEdit:
		return str(control.get("text"))
	return ""


# ---------------------------------------------------------------------------
# Checks

## Each check: {path, property?, op, value?} or {text, op: exists|missing}.
## All are judged; the reply says which held, with the actual values. A check
## that cannot be judged (no such property, a value of another kind) does not
## hold, with the reason; only a malformed check stops the request.
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
		if check.has("property"):
			return {"error": "exists and missing are about the node; leave property out."}
		described["passed"] = (node != null) == (op == "exists")
		return described
	if not check.get("property") is String:
		return {"error": "A value check names a property (\"position\", or \"position:y\" for one component)."}
	described["property"] = TextSanitizer.clean_line(check["property"])
	if node == null:
		return _not_held(described, "no such node")
	if not _has_property(node, check["property"].get_slice(":", 0)):
		return _not_held(described, "no such property")
	var actual: Variant = node.get_indexed(NodePath(check["property"]))
	described["actual"] = ValueCodec.encode(actual, _tree.root)
	var expected: Variant = check.get("value")
	var verdict := _compare(actual, op, expected, check.get("tolerance", 0.01))
	if verdict is String:
		return _not_held(described, verdict)
	described["passed"] = verdict
	return described


func _not_held(described: Dictionary, reason: String) -> Dictionary:
	described["passed"] = false
	described["reason"] = reason
	return described


func _has_property(node: Node, name: String) -> bool:
	for property in node.get_property_list():
		if property["name"] == name:
			return true
	return false


## true or false, or why the two cannot be compared.
func _compare(actual: Variant, op: String, expected: Variant, tolerance: Variant) -> Variant:
	var margin := float(tolerance) if tolerance is float or tolerance is int else 0.01
	match op:
		"less", "greater":
			if not _is_number(actual) or not _is_number(expected):
				return "less and greater compare numbers"
			return float(actual) < float(expected) if op == "less" else float(actual) > float(expected)
		"approx":
			var have: Variant = _components(actual)
			var want: Variant = _components(_decoded(expected, actual))
			if have == null or want == null or have.size() != want.size():
				return "approx compares numbers, vectors and colours of the same size"
			for index in have.size():
				if is_nan(have[index]) or is_nan(want[index]) or absf(have[index] - want[index]) > margin:
					return false
			return true
		"contains":
			if actual is String or actual is StringName:
				return str(actual).contains(str(expected))
			if actual is Array or actual is PackedStringArray or actual is PackedInt32Array or actual is PackedInt64Array or actual is PackedFloat32Array or actual is PackedFloat64Array:
				return actual.has(_decoded(expected, actual[0]) if actual.size() > 0 else expected)
			if actual is Dictionary:
				return actual.has(expected)
			return "contains looks in text, lists and dictionaries"
		"equals", "not_equals":
			var same: bool
			if _is_number(actual) and _is_number(expected):
				same = float(actual) == float(expected)
			else:
				var wanted: Variant = _decoded(expected, actual)
				same = typeof(wanted) == typeof(actual) and wanted == actual
			return same if op == "equals" else not same
	return "unknown op"


static func _is_number(value: Variant) -> bool:
	return value is int or value is float


# The expected value read as the actual one's type, when it can be; else as it was given.
func _decoded(expected: Variant, actual: Variant) -> Variant:
	if actual == null:
		return expected
	var decoded: Dictionary = ValueDecoder.new(_tree.root).decode(expected, typeof(actual))
	return decoded["value"] if decoded["ok"] else expected


static func _components(value: Variant) -> Variant:
	if value is int or value is float:
		return [float(value)]
	if value is Vector2 or value is Vector2i:
		return [float(value.x), float(value.y)]
	if value is Vector3 or value is Vector3i:
		return [float(value.x), float(value.y), float(value.z)]
	if value is Vector4 or value is Vector4i:
		return [float(value.x), float(value.y), float(value.z), float(value.w)]
	if value is Color:
		return [value.r, value.g, value.b, value.a]
	return null


# Every visible control, without the listing's limit: a missing text must not be missed.
func _text_on_screen(text: String) -> bool:
	var found := []
	_collect_ui(_tree.root, found, -1)
	for control in found:
		if _raw_text(control).contains(text):
			return true
	return false
