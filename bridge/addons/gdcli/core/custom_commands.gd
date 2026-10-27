extends RefCounted
## Loads the project's own commands from res://gdcli_commands/ (docs/protocol.md
## section 6.6). They are loaded once, when the bridge starts: reloading on file
## changes would turn "write a file" into "run code right now".
##
## A command script looks like this:
##
##   @tool
##   extends RefCounted
##
##   func descriptor() -> Dictionary:
##       return {"name": "level_stats", "summary": "...", "risk": "write",
##               "params": {"type": "object", "properties": {}}}
##
##   func run(args: Dictionary, options: Dictionary) -> Variant:
##       return {"enemies": 3}

const AccessPolicy = preload("access_policy.gd")
const Reply = preload("reply.gd")
const TextSanitizer = preload("text_sanitizer.gd")
const ValueCodec = preload("value_codec.gd")

const DIRECTORY := "res://gdcli_commands/"
const MAX_COMMANDS := 64
# What a descriptor may carry into gd list and MCP tool definitions, which a
# model reads: project text, so it is cleaned, shortened and type-checked.
const MAX_TEXT := 400
const _NOTHING_RETURNED := "The command returned nothing. If it stopped on a script error, the editor's Output panel shows it."
const MAX_PARAMS := 32
# Names a client can take as tool and argument names (gd caps tool names at 64).
const MAX_NAME := 48
const MAX_ENUM := 32
const _PARAM_TYPES: Array[String] = ["string", "number", "integer", "boolean", "array", "object"]

var _instances: Array = []
var _context: RefCounted


func _init(context: RefCounted) -> void:
	_context = context


## Registers every usable command and returns one warning per script skipped.
func load_into(registry: RefCounted) -> Array:
	var warnings := []
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(DIRECTORY)):
		return warnings
	var files := Array(DirAccess.get_files_at(DIRECTORY))
	files.sort()
	for file in files:
		if not file.ends_with(".gd"):
			continue
		if _instances.size() >= MAX_COMMANDS:
			warnings.append("More custom commands than the bridge loads; the rest were skipped.")
			break
		var problem := _load_one(DIRECTORY + file, registry)
		if problem != "":
			warnings.append("Custom command %s was skipped: %s" % [TextSanitizer.clean_line(file), problem])
	return warnings


func _load_one(path: String, registry: RefCounted) -> String:
	var script := ResourceLoader.load(path) as GDScript
	if script == null:
		return "it does not compile."
	if not script.is_tool():
		return "it must start with @tool to run inside the editor."
	if not script.can_instantiate():
		return "it does not compile."
	var instance: Variant = script.new()
	if not (instance is RefCounted and instance.has_method("descriptor") and instance.has_method("run")):
		return "it must extend RefCounted and define descriptor() and run()."
	var descriptor: Variant = instance.call("descriptor")
	if not (descriptor is Dictionary and descriptor.get("name") is String):
		return "descriptor() must return a dictionary with a name."
	var name: String = descriptor["name"]
	if name.length() > MAX_NAME or not registry.is_valid_name(name) or registry.has(name):
		return "its name is not lower snake case (at most %d characters) or is already taken." % MAX_NAME

	# Rebuilt from known fields only. The declared tier can only be raised:
	# what the script really does cannot be checked, so nothing custom is
	# treated as read-only.
	var declared: Variant = descriptor.get("risk")
	var complete := {
		"name": name,
		"summary": _text(descriptor.get("summary")),
		"returns": _text(descriptor.get("returns")),
		"risk": declared if declared in [AccessPolicy.RISK_DESTRUCTIVE, AccessPolicy.RISK_EXEC] else AccessPolicy.RISK_WRITE,
		"group": "custom",
		"custom": true,
		"params": _params(descriptor.get("params")),
	}
	registry.register(complete, _run.bind(instance, name))
	_instances.append(instance)
	return ""


# A dry run never reaches the script: nothing says it would honour dry_run,
# and the access checks let a dry run through without confirm or a person.
func _run(args: Dictionary, options: Dictionary, instance: RefCounted, name: String) -> Dictionary:
	if options.get("dry_run") == true:
		return Reply.ok({"dry_run": true, "would": {"run": name, "args": ValueCodec.encode(args, _context.scene_root())}})
	var result: Variant = instance.call("run", args, options)
	if result is Dictionary and result.get("ok") == false:
		return _failure(result.get("error"))
	if result is Dictionary and result.get("ok") == true and result.has("data"):
		result = result["data"]
	# A script error inside run() also comes back as null; say so instead of a plain success.
	var warnings := [_NOTHING_RETURNED] if result == null else []
	return Reply.ok(ValueCodec.encode(result, _context.scene_root()), warnings)


static func _text(value: Variant) -> String:
	return TextSanitizer.clean_line(value).left(MAX_TEXT) if value is String else ""


# {type: object, properties: {name: {type?, description?, enum?, default?}}, required?}
# with names that are identifiers, types from the schema list, and plain values.
static func _params(value: Variant) -> Dictionary:
	var properties := {}
	var required: Array[String] = []
	var given: Variant = value.get("properties") if value is Dictionary else null
	if given is Dictionary:
		for key in given.keys().slice(0, MAX_PARAMS):
			if not (key is String and key.is_valid_identifier() and key.length() <= MAX_NAME):
				continue
			var raw: Variant = given[key]
			var param := {}
			if raw is Dictionary:
				if raw.get("type") in _PARAM_TYPES:
					param["type"] = raw["type"]
				if raw.get("description") is String:
					param["description"] = _text(raw["description"])
				if raw.get("enum") is Array:
					var choices := []
					for choice in raw["enum"].slice(0, MAX_ENUM):
						if choice is String:
							choices.append(_text(choice))
						elif choice is int or choice is float or choice is bool:
							choices.append(choice)
					param["enum"] = choices
				var fallback: Variant = raw.get("default")
				if fallback is String:
					param["default"] = _text(fallback)
				elif fallback is int or fallback is float or fallback is bool:
					param["default"] = fallback
			properties[key] = param
	var wanted: Variant = value.get("required") if value is Dictionary else null
	if wanted is Array:
		for key in wanted:
			if key is String and properties.has(key):
				required.append(key)
	var params := {"type": "object", "properties": properties}
	if not required.is_empty():
		params["required"] = required
	return params


# Callers may trust `message` and `hint` to be the bridge's own words, so a
# project script does not get to write them: its text goes into `details`.
func _failure(error: Variant) -> Dictionary:
	var details := {}
	if error is Dictionary:
		for key in ["code", "message", "hint"]:
			if error.get(key) is String:
				details["reported_" + key] = TextSanitizer.clean_line(error[key])
		if error.get("details") is Dictionary:
			details["reported_details"] = ValueCodec.encode(error["details"], _context.scene_root())
	return Reply.fail("COMMAND_FAILED", "The project's command reported a failure.", "", details)
