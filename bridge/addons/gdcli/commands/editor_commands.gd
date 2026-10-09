extends RefCounted

const AccessPolicy = preload("../core/access_policy.gd")
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


func _selection(_args: Dictionary) -> Dictionary:
	var root: Node = _context.scene_root()
	var nodes := []
	for node in _context.selected_nodes():
		if node == root or root.is_ancestor_of(node):
			nodes.append({"path": TextSanitizer.clean_line(NodeRef.path_of(root, node)), "type": node.get_class()})
	return Reply.ok({"nodes": nodes})
