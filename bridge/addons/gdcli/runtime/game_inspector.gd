extends RefCounted
## Answers the editor's questions about the running game. It lives in the
## game process (see game_agent.gd) and is plain logic, so it can be tested
## without a debugger connection.

const NodeInspect = preload("../core/node_inspect.gd")
const NodeRef = preload("../core/node_ref.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")
const ValueCodec = preload("../core/value_codec.gd")
const ValueDecoder = preload("../core/value_decoder.gd")

const DEFAULT_MAX_DEPTH := 8
const MAX_DEPTH_LIMIT := 64
const MAX_HOLD_SECONDS := 10.0
# The debugger connection carries a few megabytes per message at most.
const MAX_PNG_BYTES := 4 * 1024 * 1024
# Methods that only repeat what other commands do (set a property, call
# something else). This keeps calls direct; it is not a security boundary.
const _INDIRECT_METHODS: Array[String] = [
	"call", "callv", "call_deferred", "set", "set_deferred", "set_indexed", "set_script", "set_meta", "connect", "rpc", "rpc_id",
]

var _tree: SceneTree


func _init(tree: SceneTree) -> void:
	_tree = tree


## Returns a reply (see reply.gd). Paths are relative to the root window, so
## the main scene is usually the first segment: "Main/Player".
func handle(method: String, args: Dictionary) -> Dictionary:
	match method:
		"tree":
			return _scene_tree(args)
		"node_get":
			return _node_get(args)
		"node_set":
			return _node_set(args)
		"input":
			return _input(args)
		"screenshot":
			return _screenshot()
		"call":
			return _call_method(args)
	return Reply.fail("INVALID_ARGS", "The game helper does not know this request.")


func _find(args: Dictionary) -> Node:
	var path: Variant = args.get("path", NodeRef.ROOT_PATH)
	return NodeRef.resolve(_tree.root, path) if path is String else null


func _not_found(args: Dictionary) -> Dictionary:
	return Reply.fail(
		"NODE_NOT_FOUND", "The node does not exist in the running game.",
		"Paths are relative to the root window; game_tree shows them.",
		{"path": TextSanitizer.clean_line(str(args.get("path", "")))},
	)


func _scene_tree(args: Dictionary) -> Dictionary:
	var start := _find(args)
	if start == null:
		return _not_found(args)
	var depth: Variant = args.get("max_depth", DEFAULT_MAX_DEPTH)
	if not (depth is int or depth is float):
		return Reply.fail("INVALID_ARGS", "max_depth must be a number.")
	var result := NodeInspect.tree(_tree.root, start, clampi(int(depth), 0, MAX_DEPTH_LIMIT))
	var current := _tree.current_scene
	result["current_scene"] = null
	if current != null:
		result["current_scene"] = {
			"path": TextSanitizer.clean_line(NodeRef.path_of(_tree.root, current)),
			"file": TextSanitizer.clean_line(current.scene_file_path),
		}
	result["paused"] = _tree.paused
	return Reply.ok(result)


func _node_get(args: Dictionary) -> Dictionary:
	var node := _find(args)
	if node == null:
		return _not_found(args)
	var wanted: Variant = args.get("properties")
	if wanted != null and not wanted is Array:
		return Reply.fail("INVALID_ARGS", "properties must be a list of names.")
	return NodeInspect.node(_tree.root, node, wanted, true)


func _node_set(args: Dictionary) -> Dictionary:
	var node := _find(args)
	if node == null:
		return _not_found(args)
	var properties: Variant = args.get("properties")
	if not properties is Dictionary:
		return Reply.fail("INVALID_ARGS", "properties must be an object.")
	var decoded := ValueDecoder.new(_tree.root).decode_properties(node, properties, 0, ValueDecoder.ANY_USAGE)
	if not decoded["ok"]:
		return decoded
	for name in decoded["values"]:
		node.set(name, decoded["values"][name])
	return Reply.ok({"path": TextSanitizer.clean_line(NodeRef.path_of(_tree.root, node)), "set": TextSanitizer.clean_lines(properties.keys())})


func _call_method(args: Dictionary) -> Dictionary:
	var node := _find(args)
	if node == null:
		return _not_found(args)
	var method: Variant = args.get("method")
	var given: Variant = args.get("arguments", [])
	if not method is String or not given is Array:
		return Reply.fail("INVALID_ARGS", "method must be a name and arguments a list.")
	var details := {"method": TextSanitizer.clean_line(method), "class": node.get_class()}
	if method in _INDIRECT_METHODS:
		return Reply.fail("INVALID_ARGS", "This method cannot be called through the bridge.", "Call the method you mean directly.", details)
	var info := {}
	for candidate in node.get_method_list():
		if candidate["name"] == method:
			info = candidate
			break
	if info.is_empty():
		return Reply.fail("INVALID_ARGS", "The node has no such method.", "", details)
	var parameters: Array = info["args"]
	var is_vararg: bool = info["flags"] & METHOD_FLAG_VARARG != 0
	if (given.size() > parameters.size() and not is_vararg) or given.size() < parameters.size() - info["default_args"].size():
		details["takes"] = parameters.size()
		return Reply.fail("INVALID_ARGS", "The method takes a different number of arguments.", "", details)

	var decoder := ValueDecoder.new(_tree.root)
	var values := []
	for index in given.size():
		var parameter: Dictionary = parameters[index] if index < parameters.size() else {"type": TYPE_NIL}
		var decoded: Dictionary = decoder.decode(given[index], parameter["type"], parameter)
		if not decoded["ok"]:
			return decoded
		values.append(decoded["value"])
	# Taken before the call: the method may free the node.
	var path := TextSanitizer.clean_line(NodeRef.path_of(_tree.root, node))
	var result: Variant = node.callv(method, values)
	return Reply.ok({
		"path": path,
		"method": TextSanitizer.clean_line(method),
		"result": ValueCodec.encode(result, _tree.root),
	})


func _input(args: Dictionary) -> Dictionary:
	var action: Variant = args.get("action")
	if not action is String or not InputMap.has_action(action):
		return Reply.fail(
			"INVALID_ARGS", "The project has no such input action.", "project_input_map lists the actions.",
			{"action": TextSanitizer.clean_line(str(action))},
		)
	var hold: Variant = args.get("hold", 0.0)
	var strength: Variant = args.get("strength", 1.0)
	if not (hold is float or hold is int) or not (strength is float or strength is int) or hold < 0.0 or hold > MAX_HOLD_SECONDS:
		return Reply.fail("INVALID_ARGS", "hold must be 0 to %d seconds and strength a number." % int(MAX_HOLD_SECONDS))
	var pressed: bool = args.get("pressed", true) == true
	_send_action(action, pressed, clampf(strength, 0.0, 1.0))
	if pressed and hold > 0.0:
		# Counted in game time on purpose: a paused game keeps the key down.
		_tree.create_timer(hold, false).timeout.connect(_send_action.bind(action, false, 0.0))
	return Reply.ok({"action": TextSanitizer.clean_line(action), "pressed": pressed, "released_after": hold if pressed else 0.0})


## An input event, not only the action's state (Input.action_press): the game
## sees it in _input and _unhandled_input, and a focused button takes ui_accept,
## as with a real key; code that polls Input.is_action_pressed sees it as well.
func _send_action(action: String, pressed: bool, strength: float) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	event.strength = strength if pressed else 0.0
	# Handled with the next frame's input, not here and now: a game stopped at
	# a breakpoint answers commands, and running its input handlers then would
	# run its scripts inside the break. Stopped, it sees the key on resuming.
	Input.parse_input_event(event)


func _screenshot() -> Dictionary:
	if DisplayServer.get_name() == "headless":
		return Reply.fail("PRECONDITION_FAILED", "The game runs without a window, so there is no picture.")
	var texture := _tree.root.get_texture()
	var image := texture.get_image() if texture != null else null
	if image == null or image.is_empty():
		return Reply.fail("COMMAND_FAILED", "The game has not drawn a frame yet.")
	var png := image.save_png_to_buffer()
	if png.size() > MAX_PNG_BYTES:
		return Reply.fail("COMMAND_FAILED", "The picture is too large to send to the editor.", "", {"bytes": png.size()})
	return Reply.ok({"png": png, "width": image.get_width(), "height": image.get_height()})
