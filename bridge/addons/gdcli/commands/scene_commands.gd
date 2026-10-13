extends RefCounted

const AccessPolicy = preload("../core/access_policy.gd")
const NodeInspect = preload("../core/node_inspect.gd")
const NodeRef = preload("../core/node_ref.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")

const DEFAULT_MAX_DEPTH := 8
const MAX_DEPTH_LIMIT := 64

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
		"returns": "tree: nested {name, type, path, script?, instance?, groups?, children}; truncated when over %d nodes." % NodeInspect.MAX_NODES,
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
	return Reply.ok(NodeInspect.tree(root, start, args["max_depth"]))


func _list_open(_args: Dictionary) -> Dictionary:
	return Reply.ok({
		"scenes": TextSanitizer.clean_lines(_context.open_scenes()),
		"current": TextSanitizer.clean_line(_context.scene_path()),
	})
