extends RefCounted
## What ties nodes of the edited scene together besides the tree: the signal
## connections saved with the scene, and groups. Seeing them, and undoing them;
## making them is in node_edit_commands.gd.

const AccessPolicy = preload("../core/access_policy.gd")
const Edit = preload("../core/edit.gd")
const NodeInspect = preload("../core/node_inspect.gd")
const NodeRef = preload("../core/node_ref.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")

const _PATH := {"type": "string", "description": "Node path relative to the scene root; \".\" is the root."}

var _context: RefCounted


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "node_connections",
		"summary": "Signal connections of a node that are saved with the scene: which signal calls which method of which node.",
		"risk": AccessPolicy.RISK_READ,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {"path": _PATH, "signal": {"type": "string", "description": "Only this signal."}},
			"required": ["path"],
		},
		"returns": "{path, connections: [{signal, target, method}]}",
	}, _connections)
	registry.register({
		"name": "node_disconnect_signal",
		"summary": "Remove a signal connection saved with the scene, the reverse of node_connect_signal.",
		"risk": AccessPolicy.RISK_WRITE,
		"undoable": true,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"path": _PATH,
				"signal": {"type": "string"},
				"target": {"type": "string", "description": "Node whose method the signal calls."},
				"method": {"type": "string"},
			},
			"required": ["path", "signal", "target", "method"],
		},
		"returns": "{path, type} of the node; meta.undo names the undo step.",
	}, _disconnect)
	registry.register({
		"name": "node_remove_from_group",
		"summary": "Take a node out of a group, saved with the scene.",
		"risk": AccessPolicy.RISK_WRITE,
		"undoable": true,
		"requires": ["scene_open"],
		"params": {"type": "object", "properties": {"path": _PATH, "group": {"type": "string"}}, "required": ["path", "group"]},
		"returns": "{path, type} of the node; meta.undo names the undo step.",
	}, _remove_from_group)


func _root() -> Node:
	return _context.scene_root()


func _missing(path: String) -> Dictionary:
	return Reply.fail("NODE_NOT_FOUND", "The node does not exist.", "Use scene_tree to see the node paths.", {"path": TextSanitizer.clean_line(path)})


func _describe(node: Node) -> Dictionary:
	return {"path": TextSanitizer.clean_line(NodeRef.path_of(_root(), node)), "type": node.get_class()}


## The connections of `node` that the scene file keeps: made with CONNECT_PERSIST,
## to a node of the same scene. The engine's own connections are left out.
func _saved_connections(node: Node, only_signal: String = "") -> Array:
	var found := []
	var root := _root()
	for description in node.get_signal_list():
		var signal_name: String = description["name"]
		if only_signal != "" and signal_name != only_signal:
			continue
		for connection in node.get_signal_connection_list(signal_name):
			var callable: Callable = connection["callable"]
			var target: Object = callable.get_object()
			if connection["flags"] & CONNECT_PERSIST == 0 or not target is Node:
				continue
			if target != root and not root.is_ancestor_of(target):
				continue
			found.append({"signal": signal_name, "target_node": target, "method": str(callable.get_method()), "flags": connection["flags"], "callable": callable})
	return found


func _listed(connections: Array) -> Array:
	var listed := []
	for connection in connections:
		listed.append({
			"signal": TextSanitizer.clean_line(connection["signal"]),
			"target": TextSanitizer.clean_line(NodeRef.path_of(_root(), connection["target_node"])),
			"method": TextSanitizer.clean_line(connection["method"]),
		})
	return listed


func _connections(args: Dictionary) -> Dictionary:
	var node := NodeRef.resolve(_root(), args["path"])
	if node == null:
		return _missing(args["path"])
	return Reply.ok({"path": _describe(node)["path"], "connections": _listed(_saved_connections(node, args.get("signal", "")))})


func _disconnect(args: Dictionary, options: Dictionary) -> Dictionary:
	var node := NodeRef.resolve(_root(), args["path"])
	var target := NodeRef.resolve(_root(), args["target"])
	if node == null or target == null:
		return _missing(args["path"] if node == null else args["target"])
	var found: Dictionary = {}
	var saved := _saved_connections(node, args["signal"])
	for connection in saved:
		if connection["target_node"] == target and connection["method"] == args["method"]:
			found = connection
	if found.is_empty():
		return Reply.fail(
			"INVALID_ARGS", "There is no such connection saved with the scene.", "node_connections lists the ones there are.",
			{"connections": _listed(saved)},
		)
	if options["dry_run"]:
		return Edit.planned({"disconnect": args["signal"], "from": _describe(node)["path"], "to": _describe(target)["path"]})

	var undo: Object = _context.undo_redo()
	var action := Edit.undo_name("node_disconnect_signal", args["signal"])
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	undo.add_do_method(node, "disconnect", args["signal"], found["callable"])
	undo.add_undo_method(node, "connect", args["signal"], found["callable"], found["flags"])
	undo.commit_action()
	return Edit.done(_describe(node), action)


func _remove_from_group(args: Dictionary, options: Dictionary) -> Dictionary:
	var node := NodeRef.resolve(_root(), args["path"])
	if node == null:
		return _missing(args["path"])
	var group: String = args["group"]
	if group.begins_with("_") or not node.is_in_group(group):
		return Reply.fail("INVALID_ARGS", "The node is not in this group.", "node_get lists its groups.", {"groups": NodeInspect.visible_groups(node)})
	if _comes_from_instanced_scene(node, group):
		return Reply.fail(
			"PRECONDITION_FAILED", "The group comes from the scene this node is an instance of.",
			"Open that scene (scene_open) and remove it there.", {"scene": TextSanitizer.clean_line(_instance_scene(node))},
		)
	if options["dry_run"]:
		return Edit.planned({"remove": _describe(node)["path"], "from_group": group})

	var undo: Object = _context.undo_redo()
	var action := Edit.undo_name("node_remove_from_group", group)
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	undo.add_do_method(node, "remove_from_group", group)
	undo.add_undo_method(node, "add_to_group", group, true)
	undo.commit_action()
	return Edit.done(_describe(node), action)


## The scene file whose contents this node is part of, when that is not the edited scene.
func _instance_scene(node: Node) -> String:
	if node != _root() and node.scene_file_path != "":
		return node.scene_file_path
	var owner := node.owner
	return owner.scene_file_path if owner != null and owner != _root() else ""


func _comes_from_instanced_scene(node: Node, group: String) -> bool:
	# A node inside an instance belongs to that scene altogether.
	if node.owner != null and node.owner != _root():
		return true
	if node == _root() or node.scene_file_path == "":
		return false
	var scene: Variant = load(node.scene_file_path)
	if not scene is PackedScene:
		return false
	var state: SceneState = scene.get_state()
	return state.get_node_count() > 0 and group in state.get_node_groups(0)
