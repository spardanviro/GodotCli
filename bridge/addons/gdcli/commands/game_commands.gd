extends RefCounted
## Looking into the game the editor is running: its node tree, the live values
## of a node, pressing an input action, a picture of its window. The game is
## another process; these commands ask the helper inside it (the GdcliGame
## autoload) over the editor's debugger connection.

const AccessPolicy = preload("../core/access_policy.gd")
const Edit = preload("../core/edit.gd")
const GameRequest = preload("../core/game_request.gd")
const NodeRef = preload("../core/node_ref.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")

const DEFAULT_MAX_DEPTH := 8
const MAX_DEPTH_LIMIT := 64
const MAX_HOLD_SECONDS := 10
const MAX_PICTURE_SIDE := 16384
const MAX_PNG_BYTES := 16 * 1024 * 1024
const _PATH_NOTE := "Node path in the running game, relative to the root window, e.g. Main/Player."
const _PNG_SIGNATURE: Array[int] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

var _context: RefCounted


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "game_tree",
		"summary": "Node tree of the running game, as it is right now.",
		"risk": AccessPolicy.RISK_READ,
		"requires": ["playing"],
		"params": {
			"type": "object",
			"properties": {
				"path": {"type": "string", "description": _PATH_NOTE, "default": NodeRef.ROOT_PATH},
				"max_depth": {"type": "integer", "default": DEFAULT_MAX_DEPTH, "minimum": 0, "maximum": MAX_DEPTH_LIMIT},
			},
		},
		"returns": "{tree: nested {name, type, path, script?, instance?, groups?, children}, truncated, current_scene: {path, file}, paused}",
	}, _tree)
	registry.register({
		"name": "game_node_get",
		"summary": "Live property values of one node in the running game, including ones the inspector hides (velocity, global_position, script variables).",
		"risk": AccessPolicy.RISK_READ,
		"requires": ["playing"],
		"params": {
			"type": "object",
			"properties": {
				"path": {"type": "string", "description": _PATH_NOTE},
				"properties": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Property names. Omit for the inspector properties and the script's variables.",
				},
			},
			"required": ["path"],
		},
		"returns": "{path, type, script?, groups, properties: {name: value}}",
	}, _node_get)
	registry.register({
		"name": "game_node_set",
		"summary": "Set properties of a node in the running game. Nothing is saved: the scene file and the editor are not changed.",
		"risk": AccessPolicy.RISK_WRITE,
		"requires": ["playing"],
		"params": {
			"type": "object",
			"properties": {"path": {"type": "string", "description": _PATH_NOTE}, "properties": {"type": "object"}},
			"required": ["path", "properties"],
		},
		"returns": "{path, set}",
	}, _node_set)
	registry.register({
		"name": "game_input",
		"summary": "Press or release an input action in the running game, as if the player did.",
		"risk": AccessPolicy.RISK_WRITE,
		"requires": ["playing"],
		"params": {
			"type": "object",
			"properties": {
				"action": {"type": "string", "description": "Name from the project's input map, e.g. ui_accept."},
				"pressed": {"type": "boolean", "default": true},
				"hold": {
					"type": "number", "default": 0, "minimum": 0, "maximum": MAX_HOLD_SECONDS,
					"description": "Seconds of game time after which a pressed action is released again. 0 leaves it pressed.",
				},
				"strength": {"type": "number", "default": 1, "minimum": 0, "maximum": 1},
			},
			"required": ["action"],
		},
		"returns": "{action, pressed, released_after}",
	}, _input)
	registry.register({
		"name": "game_screenshot",
		"summary": "Save a picture of the running game's window.",
		# It writes a file, so it is not available in read-only mode.
		"risk": AccessPolicy.RISK_WRITE,
		"requires": ["playing"],
		"returns": "{path: absolute file path, width, height}",
	}, _screenshot)


func _ask(method: String, args: Dictionary, finish: Callable = Callable()) -> Dictionary:
	var link: Object = _context.game_link()
	if link == null:
		return Reply.fail("PRECONDITION_FAILED", "This editor cannot talk to the running game.")
	if not _context.game_helper_installed():
		return Reply.fail(
			"PRECONDITION_FAILED", "The project has no gd helper for the running game.",
			"It is the autoload GdcliGame; `gd bridge install` adds it. Restart the game afterwards.",
		)
	return Reply.later(GameRequest.new(link, method, args, finish))


func _tree(args: Dictionary) -> Dictionary:
	return _ask("tree", args)


func _node_get(args: Dictionary) -> Dictionary:
	return _ask("node_get", args)


func _node_set(args: Dictionary, options: Dictionary) -> Dictionary:
	if options["dry_run"]:
		return Edit.planned({"set": TextSanitizer.clean_lines(args["properties"].keys()), "on": TextSanitizer.clean_line(args["path"]), "in": "running game"})
	return _ask("node_set", args)


func _input(args: Dictionary, options: Dictionary) -> Dictionary:
	if options["dry_run"]:
		return Edit.planned({"action": TextSanitizer.clean_line(args["action"]), "pressed": args["pressed"], "hold": args["hold"]})
	return _ask("input", args)


func _screenshot(_args: Dictionary, options: Dictionary) -> Dictionary:
	if options["dry_run"]:
		return Edit.planned({"screenshot": "running game"})
	return _ask("screenshot", {}, _save_picture)


func _is_png(bytes: PackedByteArray) -> bool:
	if bytes.size() < _PNG_SIGNATURE.size():
		return false
	for index in _PNG_SIGNATURE.size():
		if bytes[index] != _PNG_SIGNATURE[index]:
			return false
	return true


# The picture comes from the game, so it is checked before it is written.
func _save_picture(data: Variant) -> Dictionary:
	var failure := Reply.fail("COMMAND_FAILED", "The running game did not send a usable picture.")
	if not (data is Dictionary and data.get("png") is PackedByteArray and data.get("width") is int and data.get("height") is int):
		return failure
	var png: PackedByteArray = data["png"]
	if png.size() > MAX_PNG_BYTES:
		return failure
	if not _is_png(png):
		return failure
	if data["width"] < 1 or data["height"] < 1 or data["width"] > MAX_PICTURE_SIDE or data["height"] > MAX_PICTURE_SIDE:
		return failure
	var path: String = _context.store_screenshot(png, "game")
	if path == "":
		return Reply.fail("COMMAND_FAILED", "The screenshot could not be saved.")
	return Reply.ok({"path": path, "width": data["width"], "height": data["height"]})
