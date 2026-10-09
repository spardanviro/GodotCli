extends RefCounted

const AccessPolicy = preload("../core/access_policy.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")
const ValueCodec = preload("../core/value_codec.gd")

const MAX_SETTINGS := 300
const INPUT_PREFIX := "input/"


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "project_settings_get",
		"summary": "One project setting by name, or every setting under a prefix.",
		"risk": AccessPolicy.RISK_READ,
		"params": {
			"type": "object",
			"properties": {
				"name": {"type": "string", "description": "Exact setting, such as application/run/main_scene."},
				"prefix": {"type": "string", "description": "Section to list, such as display/window/."},
			},
		},
		"returns": "With name: {name, value}. With prefix: {settings: {name: value}, truncated}.",
	}, _settings_get)
	registry.register({
		"name": "project_input_map",
		"summary": "Input actions defined in the project settings, with their events.",
		"risk": AccessPolicy.RISK_READ,
		"returns": "actions: [{name, deadzone, events: [text]}]. Built-in ui_* actions appear only when overridden.",
	}, _input_map)


func _settings_get(args: Dictionary) -> Dictionary:
	if args.has("name") == args.has("prefix"):
		return Reply.fail("INVALID_ARGS", "Give exactly one of name or prefix.")
	if args.has("name"):
		var name: String = args["name"]
		if not ProjectSettings.has_setting(name):
			return Reply.fail(
				"RESOURCE_NOT_FOUND", "No such project setting.", "List a section with the prefix argument.",
				{"name": TextSanitizer.clean_line(name)},
			)
		var value: Variant = ValueCodec.encode(ProjectSettings.get_setting(name))
		return Reply.ok({"name": TextSanitizer.clean_line(name), "value": value})

	var settings := {}
	var truncated := false
	var budget := ValueCodec.new_budget()
	for property in ProjectSettings.get_property_list():
		var property_name: String = property["name"]
		if not property_name.begins_with(args["prefix"]) or not ProjectSettings.has_setting(property_name):
			continue
		if settings.size() >= MAX_SETTINGS:
			truncated = true
			break
		var encoded: Variant = ValueCodec.encode(ProjectSettings.get_setting(property_name), null, budget)
		settings[TextSanitizer.clean_line(property_name)] = encoded
	return Reply.ok({"settings": settings, "truncated": truncated})


func _input_map(_args: Dictionary) -> Dictionary:
	var actions := []
	for property in ProjectSettings.get_property_list():
		var property_name: String = property["name"]
		if not property_name.begins_with(INPUT_PREFIX):
			continue
		var action: Variant = ProjectSettings.get_setting(property_name)
		if not action is Dictionary:
			continue
		var events := []
		for event in action.get("events", []):
			if event is InputEvent:
				events.append(TextSanitizer.clean_line(event.as_text()))
		actions.append({
			"name": TextSanitizer.clean_line(property_name.substr(INPUT_PREFIX.length())),
			"deadzone": action.get("deadzone", 0.5),
			"events": events,
		})
	return Reply.ok({"actions": actions})
