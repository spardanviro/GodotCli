extends RefCounted
## Changing project settings and the input map. Both live in project.godot,
## which decides how the project and the editor load, so both are destructive.

const AccessPolicy = preload("../core/access_policy.gd")
const Edit = preload("../core/edit.gd")
const Reply = preload("../core/reply.gd")
const InputText = preload("../core/input_text.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")
const ValueDecoder = preload("../core/value_decoder.gd")

const _INPUT_PREFIX := "input/"
const _OWN_PREFIX := "gdcli/"
# Settings that decide which code is loaded, directly or through another file.
const _LOADS_CODE: Array[String] = [
	"autoload/", "editor_plugins/", "application/config/project_settings_override", "application/run/main_loop_type", "dotnet/",
	"audio/buses/default_bus_layout",
]
const _DEFAULT_DEADZONE := 0.5
# Section and key as they appear in project.godot; nothing that could start a
# new line or a new section there.
const _NAME_PATTERN := "^[A-Za-z0-9_]+(/[A-Za-z0-9_.]+)+\\z"
const _ACTION_PATTERN := "^[A-Za-z0-9_.]+\\z"

var _context: RefCounted


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "project_settings_set",
		"summary": "Set a project setting and save project.godot.",
		"risk": AccessPolicy.RISK_DESTRUCTIVE,
		"params": {
			"type": "object",
			"properties": {
				"name": {"type": "string", "description": "e.g. display/window/size/viewport_width"},
				"value": {"description": "New value; see docs/protocol.md 6.4 for value forms."},
			},
			"required": ["name", "value"],
		},
		"returns": "{name, new_setting}. Not undoable.",
	}, _settings_set)
	registry.register({
		"name": "project_input_map_set",
		"summary": "Define or replace an input action with its key, mouse or joypad events.",
		"risk": AccessPolicy.RISK_DESTRUCTIVE,
		"params": {
			"type": "object",
			"properties": {
				"action": {"type": "string", "description": "Action name, e.g. jump."},
				"events": {
					"type": "array",
					"items": {"type": "object"},
					"description": "Each one of {\"key\": \"Space\"}, {\"mouse_button\": 1}, {\"joypad_button\": 0}, {\"joypad_axis\": 0, \"axis_value\": -1}.",
				},
				"deadzone": {"type": "number", "default": _DEFAULT_DEADZONE, "minimum": 0, "maximum": 1},
			},
			"required": ["action", "events"],
		},
		"returns": "{action, events: [text]}. Not undoable. The running editor picks it up after a restart.",
	}, _input_map_set)


func _settings_set(args: Dictionary, options: Dictionary) -> Dictionary:
	var name: String = args["name"]
	if name.begins_with(_OWN_PREFIX):
		return Reply.fail("INVALID_ARGS", "Settings of the bridge itself are not project settings.", "They are in the editor settings.")
	if RegEx.create_from_string(_NAME_PATTERN).search(name) == null or name.begins_with(_INPUT_PREFIX):
		return Reply.fail("INVALID_ARGS", "Not a settable project setting name.", "Use project_input_map_set for input actions.", {"name": TextSanitizer.clean_line(name)})
	# An existing setting fixes the type; a new one takes the value as given.
	var existed := ProjectSettings.has_setting(name)
	var previous: Variant = ProjectSettings.get_setting(name) if existed else null
	var decoded: Dictionary = ValueDecoder.new(_context.scene_root()).decode(args["value"], typeof(previous))
	if not decoded["ok"]:
		return decoded
	# Autoloads and enabled plugins are code the editor or the game loads.
	for prefix in _LOADS_CODE:
		if name.begins_with(prefix):
			var what := {
				"command": "project_settings_set", "reason": "this setting decides which code is loaded",
				"target": name, "preview": JSON.stringify(args["value"]),
			}
			var gate := Edit.person_gate(_context, options, what, _settings_set.bind(args, Edit.approved(options)))
			if not gate.is_empty():
				return gate
	if options["dry_run"]:
		return Edit.planned({"set": name, "new_setting": not existed})

	ProjectSettings.set_setting(name, decoded["value"])
	var result := ProjectSettings.save()
	if result != OK:
		ProjectSettings.set_setting(name, previous)
		return Reply.fail("COMMAND_FAILED", "project.godot could not be saved.", "", {"error": error_string(result)})
	return Reply.ok({"name": TextSanitizer.clean_line(name), "new_setting": not existed}, [Edit.NOT_UNDOABLE])


func _input_map_set(args: Dictionary, options: Dictionary) -> Dictionary:
	var action: String = args["action"]
	if RegEx.create_from_string(_ACTION_PATTERN).search(action) == null:
		return Reply.fail("INVALID_ARGS", "Not a valid action name.", "", {"action": TextSanitizer.clean_line(action)})
	var events := []
	for spec in args["events"]:
		var event := _event_from(spec)
		if event == null:
			return Reply.fail(
				"INVALID_ARGS", "An event description was not understood.",
				"Use {\"key\": \"Space\"}, {\"mouse_button\": 1}, {\"joypad_button\": 0} or {\"joypad_axis\": 0, \"axis_value\": -1}.",
				{"event": TextSanitizer.clean_line(JSON.stringify(spec))},
			)
		events.append(event)
	if options["dry_run"]:
		return Edit.planned({"action": action, "events": events.size()})

	var setting := _INPUT_PREFIX + action
	var previous: Variant = ProjectSettings.get_setting(setting) if ProjectSettings.has_setting(setting) else null
	ProjectSettings.set_setting(setting, {"deadzone": args["deadzone"], "events": events})
	var result := ProjectSettings.save()
	if result != OK:
		ProjectSettings.set_setting(setting, previous)
		return Reply.fail("COMMAND_FAILED", "project.godot could not be saved.", "", {"error": error_string(result)})
	var described := []
	for event in events:
		described.append(TextSanitizer.clean_line(InputText.describe(event)))
	return Reply.ok({"action": TextSanitizer.clean_line(action), "events": described}, [Edit.NOT_UNDOABLE])


# "Ctrl+Shift+S": the modifiers are read here, the key by the engine. Engines
# before 4.5 drop the modifiers of such a name; later ones fold them into
# bits. Modifiers alone ("Ctrl+Foo") name no key.
static func _key_event(text: String) -> InputEventKey:
	# The plus key itself: "+", "Ctrl++".
	var key_name := "Plus" if text.strip_edges().ends_with("+") else ""
	var parts := text.strip_edges().trim_suffix("+").split("+", false) if key_name != "" else text.split("+", false)
	if key_name == "":
		if parts.is_empty():
			return null
		key_name = parts[parts.size() - 1].strip_edges()
		parts.remove_at(parts.size() - 1)
	var keycode: int = OS.find_keycode_from_string(key_name) & KEY_CODE_MASK
	if keycode == KEY_NONE:
		return null
	var key := InputEventKey.new()
	# Physical: the same position on every keyboard layout.
	key.physical_keycode = keycode as Key
	for part in parts:
		match part.strip_edges().to_lower():
			"ctrl", "control":
				key.ctrl_pressed = true
			"shift":
				key.shift_pressed = true
			"alt", "option":
				key.alt_pressed = true
			"meta", "cmd", "command", "super", "win", "windows":
				key.meta_pressed = true
			"cmdorctrl", "cmd_or_ctrl", "commandorcontrol":
				key.command_or_control_autoremap = true
			_:
				return null
	return key


func _event_from(spec: Variant) -> InputEvent:
	if not spec is Dictionary:
		return null
	if spec.get("key") is String:
		return _key_event(spec["key"])
	if _is_index(spec.get("mouse_button")):
		var button := InputEventMouseButton.new()
		button.button_index = int(spec["mouse_button"])
		return button
	if _is_index(spec.get("joypad_button")):
		var joy_button := InputEventJoypadButton.new()
		joy_button.button_index = int(spec["joypad_button"])
		return joy_button
	if _is_index(spec.get("joypad_axis")):
		var motion := InputEventJoypadMotion.new()
		motion.axis = int(spec["joypad_axis"])
		var value: Variant = spec.get("axis_value", 1.0)
		motion.axis_value = float(value) if value is float or value is int else 1.0
		return motion
	return null


func _is_index(value: Variant) -> bool:
	return (value is float or value is int) and value >= 0 and value == floorf(value) and value < 64
