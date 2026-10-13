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
	if not registry.is_valid_name(name) or registry.has(name):
		return "its name is not lower snake case or is already taken."

	var complete: Dictionary = descriptor.duplicate(true)
	# The declared tier can only be raised: what the script really does cannot
	# be checked, so nothing custom is treated as read-only.
	var declared: Variant = descriptor.get("risk")
	complete["risk"] = declared if declared in [AccessPolicy.RISK_DESTRUCTIVE, AccessPolicy.RISK_EXEC] else AccessPolicy.RISK_WRITE
	complete["summary"] = str(descriptor.get("summary", ""))
	complete["group"] = "custom"
	complete["custom"] = true
	if not (complete.get("params") is Dictionary):
		complete["params"] = {"type": "object", "properties": {}}
	registry.register(complete, _run.bind(instance))
	_instances.append(instance)
	return ""


func _run(args: Dictionary, options: Dictionary, instance: RefCounted) -> Dictionary:
	var result: Variant = instance.call("run", args, options)
	if result is Dictionary and result.get("ok") == false:
		return _failure(result.get("error"))
	if result is Dictionary and result.get("ok") == true and result.has("data"):
		result = result["data"]
	return Reply.ok(ValueCodec.encode(result, _context.scene_root()))


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
