extends RefCounted
## Several steps in one request: building a character is a dozen node
## commands, and one that fails halfway should not leave half a character.
## Only steps the editor can take back are allowed (and reads), so that a
## failure undoes the steps already done; each stays its own undo step.

const AccessPolicy = preload("../core/access_policy.gd")
const Edit = preload("../core/edit.gd")
const Reply = preload("../core/reply.gd")
const Schema = preload("../core/schema.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")

const MAX_STEPS := 100
const NAME := "batch"

var _context: RefCounted
var _registry: RefCounted


func _init(context: RefCounted, registry: RefCounted) -> void:
	_context = context
	_registry = registry


func register(registry: RefCounted) -> void:
	registry.register({
		"name": NAME,
		"summary": "Run several commands in order as one request; if one fails, the ones already done are undone. Only commands that are undo steps, and reads, can be steps.",
		"risk": AccessPolicy.RISK_WRITE,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"steps": {
					"type": "array",
					"items": {"type": "object"},
					"description": "Each one {\"command\": \"node_create\", \"args\": {...}}, at most 100. A later step can use what an earlier one made (a node's path).",
				},
			},
			"required": ["steps"],
		},
		"returns": "{steps: [{command, data}], undo: [undo step names]}. On failure: the failed step's error, with details.step (from 0) and details.undone (how many were taken back). A dry run checks the commands and their arguments only.",
	}, _run)


func _run(args: Dictionary, options: Dictionary) -> Dictionary:
	var steps: Array = args["steps"]
	if steps.is_empty() or steps.size() > MAX_STEPS:
		return Reply.fail("INVALID_ARGS", "A batch has from 1 to %d steps." % MAX_STEPS)
	var checked := []
	for index in steps.size():
		var step := _check(steps[index], index)
		if not step["ok"]:
			return step
		checked.append(step)
	if options["dry_run"]:
		var names := []
		for step in checked:
			names.append(step["command"])
		return Edit.planned({"steps": names})

	var results := []
	var undo_names := []
	var history: Object = _context.scene_history()
	var version_before: int = history.get_version()
	for index in checked.size():
		var step: Dictionary = checked[index]
		var reply := _call(step)
		if not reply["ok"] or reply.has("later"):
			if reply.has("later") and reply["later"].has_method("abandon"):
				reply["later"].abandon()
			var undone := _take_back(history, version_before, checked.size())
			var waits := "This step answers later (the running game), which a batch does not wait for." if step["risk"] == AccessPolicy.RISK_READ else "This step needs a person's approval, which a batch does not ask for."
			var failure: Dictionary = reply if not reply["ok"] else Reply.fail("PRECONDITION_FAILED", waits, "Run that command on its own.")
			failure = failure.duplicate(true)
			var details: Dictionary = failure["error"].get("details", {})
			details["step"] = index
			details["command"] = step["command"]
			details["undone"] = undone
			failure["error"]["details"] = details
			return failure
		results.append({"command": step["command"], "data": reply.get("data")})
		if reply.has("undo"):
			undo_names.append(TextSanitizer.clean_line(str(reply["undo"])))
	return Reply.ok({"steps": results, "undo": undo_names})


## The step's command and validated arguments, or a failed reply naming the step.
func _check(step: Variant, index: int) -> Dictionary:
	var at := {"step": index}
	if not step is Dictionary or not step.get("command") is String:
		return Reply.fail("INVALID_ARGS", "Each step is {\"command\": name, \"args\": {...}}.", "", at)
	var command: String = step["command"]
	at["command"] = TextSanitizer.clean_line(command)
	var given: Variant = step.get("args", {})
	if not given is Dictionary:
		return Reply.fail("INVALID_ARGS", "A step's args must be an object.", "", at)
	if command == NAME or not _registry.has(command):
		return Reply.fail("UNKNOWN_COMMAND", "No such command for a step.", "GET /v1/commands lists the commands.", at)
	var descriptor: Dictionary = _registry.descriptor_of(command)
	var risk: String = descriptor["risk"]
	if not (risk == AccessPolicy.RISK_READ or (risk == AccessPolicy.RISK_WRITE and descriptor.get("undoable", false))):
		return Reply.fail(
			"INVALID_ARGS", "Only commands that are undo steps, and reads, can be steps of a batch.",
			"Run commands that write files, change project settings or delete things on their own.", at,
		)
	var validated := Schema.validate(given, descriptor["params"])
	if not validated["ok"]:
		var failure: Dictionary = validated.duplicate(true)
		var details: Dictionary = failure["error"].get("details", {})
		details.merge(at)
		failure["error"]["details"] = details
		return failure
	return {"ok": true, "command": command, "risk": risk, "args": validated["args"], "requires": descriptor.get("requires", [])}


func _call(step: Dictionary) -> Dictionary:
	if "playing" in step["requires"] and not _context.is_playing():
		return Reply.fail("PRECONDITION_FAILED", "The project is not running.")
	if "not_playing" in step["requires"] and _context.is_playing():
		return Reply.fail("PRECONDITION_FAILED", "The project is running.", "Stop it first.")
	var handler: Callable = _registry.handler_of(step["command"])
	var reply: Variant
	if step["risk"] == AccessPolicy.RISK_READ:
		reply = handler.call(step["args"])
	else:
		reply = handler.call(step["args"], {"dry_run": false, "confirm": false, "mode": _context.access_mode(), "in_batch": true})
	if not (reply is Dictionary and reply.has("ok")):
		return Reply.fail("INTERNAL_ERROR", "The command did not return a reply.")
	return reply


# Back to the history's version before the batch: what the steps added, and
# no more, whatever number of steps each command put on it.
func _take_back(history: Object, version_before: int, most: int) -> int:
	var undone := 0
	while history.get_version() != version_before and history.has_undo() and undone < most * 2:
		history.undo()
		undone += 1
	return undone
