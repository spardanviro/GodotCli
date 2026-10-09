extends RefCounted

const AccessPolicy = preload("../core/access_policy.gd")
const NodeRef = preload("../core/node_ref.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")
const ValueCodec = preload("../core/value_codec.gd")

const DEFAULT_FIND_LIMIT := 50
const MAX_FIND_LIMIT := 500
const MAX_VISITED := 20000
const _STRUCTURAL_USAGE := PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP

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

	var listed := {}
	for property in node.get_property_list():
		if property["usage"] & PROPERTY_USAGE_EDITOR and not property["usage"] & _STRUCTURAL_USAGE:
			listed[property["name"]] = true
	listed.erase("script")

	var wanted: Array = args.get("properties", listed.keys())
	var properties := {}
	var budget := ValueCodec.new_budget()
	for name in wanted:
		if not listed.has(name):
			return Reply.fail(
				"INVALID_ARGS", "The node has no such inspector property.",
				"Call node_get without `properties` to list them.", {"property": TextSanitizer.clean_line(name)},
			)
		properties[TextSanitizer.clean_line(name)] = ValueCodec.encode(node.get(name), root, budget)

	var result := {
		"path": TextSanitizer.clean_line(NodeRef.path_of(root, node)),
		"type": node.get_class(),
		"groups": _visible_groups(node),
		"properties": properties,
	}
	var script: Script = node.get_script()
	if script != null and script.resource_path != "":
		result["script"] = TextSanitizer.clean_line(script.resource_path)
	return Reply.ok(result)


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


func _visible_groups(node: Node) -> Array:
	var groups := []
	for group in node.get_groups():
		var name := str(group)
		if not name.begins_with("_"):
			groups.append(TextSanitizer.clean_line(name))
	return groups


func _not_found(path: String) -> Dictionary:
	return Reply.fail(
		"NODE_NOT_FOUND", "The node does not exist.", "Use scene_tree to see the node paths of the edited scene.",
		{"path": TextSanitizer.clean_line(path)},
	)
