extends RefCounted

const AccessPolicy = preload("../core/access_policy.gd")
const Edit = preload("../core/edit.gd")
const NodeRef = preload("../core/node_ref.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")

var _context: RefCounted


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "editor_status",
		"summary": "Engine version, project, edited scene, open scenes, play state and access mode.",
		"risk": AccessPolicy.RISK_READ,
		"returns": "An object describing the editor's current state.",
	}, _status)
	registry.register({
		"name": "editor_selection",
		"summary": "Nodes currently selected in the editor, as paths relative to the scene root.",
		"risk": AccessPolicy.RISK_READ,
		"requires": ["scene_open"],
		"returns": "nodes: [{path, type}]",
	}, _selection)
	registry.register({
		"name": "editor_select",
		"summary": "Select nodes in the editor, so the person sees them in the Scene dock and the Inspector.",
		"risk": AccessPolicy.RISK_WRITE,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {"paths": {"type": "array", "items": {"type": "string"}, "description": "Node paths relative to the scene root; [] clears the selection."}},
			"required": ["paths"],
		},
		"returns": "nodes: [{path, type}] now selected",
	}, _select)


func _status(_args: Dictionary) -> Dictionary:
	var version := Engine.get_version_info()
	var headless: bool = _context.is_headless()
	return Reply.ok({
		"godot_version": "%d.%d.%d-%s" % [version["major"], version["minor"], version["patch"], version["status"]],
		"project_name": TextSanitizer.clean_line(str(ProjectSettings.get_setting("application/config/name", ""))),
		"project_path": TextSanitizer.clean_line(ProjectSettings.globalize_path("res://").trim_suffix("/")),
		"scene": TextSanitizer.clean_line(_context.scene_path()),
		"open_scenes": TextSanitizer.clean_lines(_context.open_scenes()),
		"playing": _context.is_playing(),
		"headless": headless,
		"access_mode": _context.access_mode(),
		"allow_eval": _context.allow_eval(),
		"capabilities": [] if headless else ["screenshot"],
	})


func _select(args: Dictionary, options: Dictionary) -> Dictionary:
	var root: Node = _context.scene_root()
	var nodes := []
	for path in args["paths"]:
		var node := NodeRef.resolve(root, str(path))
		if node == null:
			return Reply.fail("NODE_NOT_FOUND", "The node does not exist.", "Use scene_tree to see the node paths.", {"path": TextSanitizer.clean_line(str(path))})
		nodes.append(node)
	if options["dry_run"]:
		return Edit.planned({"select": args["paths"].size()})
	_context.select_nodes(nodes)
	return _selection({})


func _selection(_args: Dictionary) -> Dictionary:
	var root: Node = _context.scene_root()
	var nodes := []
	for node in _context.selected_nodes():
		if node == root or root.is_ancestor_of(node):
			nodes.append({"path": TextSanitizer.clean_line(NodeRef.path_of(root, node)), "type": node.get_class()})
	return Reply.ok({"nodes": nodes})
