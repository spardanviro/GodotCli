extends RefCounted

const AccessPolicy = preload("../core/access_policy.gd")
const NodeRef = preload("../core/node_ref.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")

const DEFAULT_MAX_DEPTH := 8
const MAX_DEPTH_LIMIT := 64
const MAX_NODES := 2000

var _context: RefCounted


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "scene_tree",
		"summary": "Node tree of the scene being edited.",
		"risk": AccessPolicy.RISK_READ,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "Subtree to return, relative to the scene root.",
					"default": NodeRef.ROOT_PATH,
				},
				"max_depth": {
					"type": "integer",
					"description": "Levels below the starting node to include.",
					"default": DEFAULT_MAX_DEPTH,
					"minimum": 0,
					"maximum": MAX_DEPTH_LIMIT,
				},
			},
		},
		"returns": "tree: nested {name, type, path, script?, instance?, groups?, children}; truncated when over %d nodes." % MAX_NODES,
	}, _tree)
	registry.register({
		"name": "scene_list_open",
		"summary": "Scenes open in editor tabs and which one is being edited.",
		"risk": AccessPolicy.RISK_READ,
		"returns": "scenes: [path], current: path",
	}, _list_open)


func _tree(args: Dictionary) -> Dictionary:
	var root: Node = _context.scene_root()
	var start := NodeRef.resolve(root, args["path"])
	if start == null:
		return Reply.fail(
			"NODE_NOT_FOUND", "The node does not exist.", "Paths are relative to the scene root; \".\" is the root.",
			{"path": TextSanitizer.clean_line(args["path"])},
		)
	var budget := {"remaining": MAX_NODES, "truncated": false}
	var tree := _describe(root, start, args["max_depth"], budget)
	return Reply.ok({"tree": tree, "truncated": budget["truncated"]})


func _describe(root: Node, node: Node, depth_left: int, budget: Dictionary) -> Dictionary:
	budget["remaining"] -= 1
	var described := {
		"name": TextSanitizer.clean_line(str(node.name)),
		"type": node.get_class(),
		"path": TextSanitizer.clean_line(NodeRef.path_of(root, node)),
	}
	var script: Script = node.get_script()
	if script != null and script.resource_path != "":
		described["script"] = TextSanitizer.clean_line(script.resource_path)
	if node != root and node.scene_file_path != "":
		described["instance"] = TextSanitizer.clean_line(node.scene_file_path)
	var groups := _visible_groups(node)
	if not groups.is_empty():
		described["groups"] = groups

	var children := []
	var omitted := 0
	for child in node.get_children():
		if depth_left > 0 and budget["remaining"] > 0:
			children.append(_describe(root, child, depth_left - 1, budget))
		else:
			omitted += 1
			if budget["remaining"] <= 0:
				budget["truncated"] = true
	described["children"] = children
	if omitted > 0:
		described["children_omitted"] = omitted
	return described


# Groups starting with an underscore are the editor's own bookkeeping.
func _visible_groups(node: Node) -> Array:
	var groups := []
	for group in node.get_groups():
		var name := str(group)
		if not name.begins_with("_"):
			groups.append(TextSanitizer.clean_line(name))
	return groups


func _list_open(_args: Dictionary) -> Dictionary:
	return Reply.ok({
		"scenes": TextSanitizer.clean_lines(_context.open_scenes()),
		"current": TextSanitizer.clean_line(_context.scene_path()),
	})
