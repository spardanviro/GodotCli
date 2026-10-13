extends RefCounted

const AccessPolicy = preload("../core/access_policy.gd")
const NodeInspect = preload("../core/node_inspect.gd")
const NodeRef = preload("../core/node_ref.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")

const DEFAULT_FIND_LIMIT := 50
const MAX_FIND_LIMIT := 500
const MAX_VISITED := 20000

var _context: RefCounted


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "node_get",
		"summary": "Class, script, groups and properties of one node.",
		"risk": AccessPolicy.RISK_READ,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"path": {"type": "string", "description": "Node path relative to the scene root."},
				"properties": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Property names to return. Omit for every property shown in the inspector.",
				},
			},
			"required": ["path"],
		},
		"returns": "{path, type, script?, groups, properties: {name: value}}",
	}, _node_get)
	registry.register({
		"name": "node_find",
		"summary": "Search the edited scene by name pattern, class and group.",
		"risk": AccessPolicy.RISK_READ,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"name": {"type": "string", "description": "Name pattern; * and ? are wildcards."},
				"type": {"type": "string", "description": "Class the node is or inherits, such as CollisionShape2D."},
				"group": {"type": "string", "description": "Group the node belongs to."},
				"limit": {
					"type": "integer",
					"default": DEFAULT_FIND_LIMIT,
					"minimum": 1,
					"maximum": MAX_FIND_LIMIT,
				},
			},
		},
		"returns": "nodes: [{path, type}], truncated",
	}, _node_find)


func _node_get(args: Dictionary) -> Dictionary:
	var root: Node = _context.scene_root()
	var node := NodeRef.resolve(root, args["path"])
	if node == null:
		return _not_found(args["path"])

	return NodeInspect.node(root, node, args.get("properties"), false)


func _node_find(args: Dictionary) -> Dictionary:
	if not (args.has("name") or args.has("type") or args.has("group")):
		return Reply.fail("INVALID_ARGS", "Give at least one of name, type or group.")
	var root: Node = _context.scene_root()
	var limit: int = args["limit"]
	var found := []
	var pending: Array[Node] = [root]
	var visited := 0
	var truncated := false

	while not pending.is_empty():
		var node: Node = pending.pop_back()
		visited += 1
		if visited > MAX_VISITED:
			truncated = true
			break
		if _matches(node, args):
			if found.size() >= limit:
				truncated = true
				break
			found.append({"path": TextSanitizer.clean_line(NodeRef.path_of(root, node)), "type": node.get_class()})
		var children := node.get_children()
		children.reverse()
		pending.append_array(children)
	return Reply.ok({"nodes": found, "truncated": truncated})


func _matches(node: Node, criteria: Dictionary) -> bool:
	if criteria.has("name") and not str(node.name).match(criteria["name"]):
		return false
	if criteria.has("type") and not node.is_class(criteria["type"]):
		return false
	if criteria.has("group") and not node.is_in_group(criteria["group"]):
		return false
	return true


func _not_found(path: String) -> Dictionary:
	return Reply.fail(
		"NODE_NOT_FOUND", "The node does not exist.", "Use scene_tree to see the node paths of the edited scene.",
		{"path": TextSanitizer.clean_line(path)},
	)
