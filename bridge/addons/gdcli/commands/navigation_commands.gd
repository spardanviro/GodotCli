extends RefCounted
## Baking the navigation mesh of a region, which is otherwise a button in
## the editor.

const AccessPolicy = preload("../core/access_policy.gd")
const Edit = preload("../core/edit.gd")
const NodeRef = preload("../core/node_ref.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")

const MAX_OUTLINE_POINTS := 4096
const _MIN_OUTLINE_POINTS := 3
const _MESH_PROPERTY := "navigation_mesh"
const _POLYGON_PROPERTY := "navigation_polygon"
const _NOTHING_BAKED := "Nothing was baked: no walkable geometry was found. Check what the mesh or polygon parses (meshes or static colliders, and which collision layers); in an editor without a window meshes have no geometry, so use static colliders there."

var _context: RefCounted


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "navigation_bake",
		"summary": "Bake the navigation mesh of a NavigationRegion3D or the navigation polygon of a NavigationRegion2D from the geometry under it.",
		"risk": AccessPolicy.RISK_WRITE,
		"undoable": true,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"region": {"type": "string", "description": "Path of the NavigationRegion3D or NavigationRegion2D node."},
				"outline": {
					"type": "array",
					"description": "2D only: the points [[x, y], ...] of the area agents may walk in, in the region's own coordinates. Replaces the outlines the polygon has. Obstacles found inside are cut out.",
				},
			},
			"required": ["region"],
		},
		"returns": "{region, kind: 2d|3d, polygons, vertices}; meta.undo names the undo step. The region gets a baked copy of its mesh or polygon (a new one when it had none); undo puts the earlier one back.",
	}, _bake)


func _bake(args: Dictionary, options: Dictionary) -> Dictionary:
	var root: Node = _context.scene_root()
	var region := NodeRef.resolve(root, args["region"])
	if region == null:
		return Reply.fail("NODE_NOT_FOUND", "The node does not exist.", "Use scene_tree to see the node paths.", {"path": TextSanitizer.clean_line(args["region"])})
	var path := TextSanitizer.clean_line(NodeRef.path_of(root, region))
	if not (region is NavigationRegion3D or region is NavigationRegion2D):
		return Reply.fail(
			"TYPE_MISMATCH", "The node is not a NavigationRegion3D or NavigationRegion2D.", "Create one with node_create and put the level under it.",
			{"path": path, "class": region.get_class()},
		)
	var flat := region is NavigationRegion2D
	var property := _POLYGON_PROPERTY if flat else _MESH_PROPERTY
	var previous: Resource = region.get(property)
	# A mesh that is a file of its own is shared by whatever else uses it.
	if previous != null and previous.resource_path != "" and not previous.resource_path.contains("::"):
		return Reply.fail(
			"PRECONDITION_FAILED", "The region's navigation data is a file of its own, which this command does not change.",
			"Bake it in the editor, or make it part of the scene first.", {"resource": TextSanitizer.clean_line(previous.resource_path)},
		)
	var outline: Variant = _outline(args) if flat else PackedVector2Array()
	if outline is Dictionary:
		return outline
	if not flat and args.has("outline"):
		return Reply.fail("INVALID_ARGS", "outline is for a NavigationRegion2D.", "A 3D mesh is baked from the geometry under the region.")
	if flat and outline.is_empty() and (previous == null or previous.get_outline_count() == 0):
		return Reply.fail("PRECONDITION_FAILED", "The region has no outline to bake inside.", "Pass outline: the corner points of the walkable area.")
	if options["dry_run"]:
		return Edit.planned({"bake": path, "kind": "2d" if flat else "3d", "new_outline": not outline.is_empty()})

	# Baked into a copy, so that undo has the earlier data to return to and
	# nothing else that holds the old resource sees it change.
	var baked: Resource = previous.duplicate() if previous != null else (NavigationPolygon.new() if flat else NavigationMesh.new())
	if flat and not outline.is_empty():
		baked.clear_outlines()
		baked.add_outline(outline)
	var action := Edit.undo_name("navigation_bake", str(region.name))
	var undo: Object = _context.undo_redo()
	undo.create_action(action, UndoRedo.MERGE_DISABLE, root)
	undo.add_do_property(region, property, baked)
	undo.add_undo_property(region, property, previous)
	undo.commit_action()
	# On this thread: the answer has to describe the finished mesh. Geometry
	# is read from the scene tree, which the edited scene is always part of.
	if region.is_inside_tree():
		if flat:
			region.bake_navigation_polygon(false)
		else:
			region.bake_navigation_mesh(false)
	var data := {"region": path, "kind": "2d" if flat else "3d", "polygons": baked.get_polygon_count(), "vertices": baked.get_vertices().size()}
	return Edit.done(data, action, [_NOTHING_BAKED] if data["polygons"] == 0 else [])


# The outline given, empty when none was, or a failed reply.
func _outline(args: Dictionary) -> Variant:
	var outline := PackedVector2Array()
	if not args.has("outline"):
		return outline
	var given: Variant = args["outline"]
	if not given is Array or given.size() < _MIN_OUTLINE_POINTS or given.size() > MAX_OUTLINE_POINTS:
		return Reply.fail("INVALID_ARGS", "outline is a list of at least 3 points [x, y].")
	for point in given:
		if not (point is Array and point.size() == 2 and (point[0] is float or point[0] is int) and (point[1] is float or point[1] is int)):
			return Reply.fail("INVALID_ARGS", "outline is a list of at least 3 points [x, y].")
		outline.append(Vector2(point[0], point[1]))
	return outline
