extends RefCounted
## Fitting a collision shape to what the body looks like: the size of its
## sprite or mesh, instead of a size worked out by hand.

const AccessPolicy = preload("../core/access_policy.gd")
const Edit = preload("../core/edit.gd")
const NodeRef = preload("../core/node_ref.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")

const NAME := "collision_shape_fit"
const _KINDS: Array[String] = ["box", "circle", "capsule"]

var _context: RefCounted


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	registry.register({
		"name": NAME,
		"summary": "Give a CollisionShape2D or CollisionShape3D a new shape the size of a sprite or mesh: a box (rectangle), circle (sphere) or capsule around it.",
		"risk": AccessPolicy.RISK_WRITE,
		"undoable": true,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"shape": {"type": "string", "description": "Path of the CollisionShape2D or CollisionShape3D."},
				"from": {"type": "string", "description": "The Sprite2D, AnimatedSprite2D or MeshInstance3D to fit; omit for the first one beside the shape or under its body."},
				"kind": {"type": "string", "enum": _KINDS, "default": "box"},
				"margin": {"type": "number", "default": 1, "minimum": 0.1, "maximum": 2, "description": "Scale of the fitted size: 0.9 is a little inside the picture."},
			},
			"required": ["shape"],
		},
		"returns": "{shape, from, kind, size, position}; meta.undo names the undo step. The shape is new (not shared with other nodes) and moved to the centre of what it fits.",
	}, _fit)


func _fit(args: Dictionary, options: Dictionary) -> Dictionary:
	var root: Node = _context.scene_root()
	var holder := NodeRef.resolve(root, args["shape"])
	if holder == null:
		return _missing(args["shape"])
	if not (holder is CollisionShape2D or holder is CollisionShape3D):
		return Reply.fail("TYPE_MISMATCH", "The node is not a CollisionShape2D or CollisionShape3D.", "", {"class": holder.get_class()})
	var flat := holder is CollisionShape2D
	var visual: Node = NodeRef.resolve(root, args["from"]) if args.has("from") else _visual_near(holder, flat)
	if visual == null:
		if args.has("from"):
			return _missing(args["from"])
		return Reply.fail("PRECONDITION_FAILED", "There is no sprite or mesh beside the shape to fit.", "Name it with from.")
	var bounds: Variant = _bounds_2d(visual, root) if flat else _bounds_3d(visual, root)
	if bounds is String:
		return Reply.fail("PRECONDITION_FAILED", bounds, "", {"from": TextSanitizer.clean_line(NodeRef.path_of(root, visual))})
	var kind: String = args.get("kind", "box")
	var margin: float = args.get("margin", 1.0)
	var size: Variant = bounds["size"] * margin
	var shape: Resource = _shape_2d(kind, size) if flat else _shape_3d(kind, size)
	# The centre of the picture, in the shape node's parent's space.
	var parent := holder.get_parent()
	var position: Variant = (_to_root_2d(parent, root).affine_inverse() if flat else _to_root_3d(parent, root).affine_inverse()) * bounds["centre"]
	var described := {
		"shape": TextSanitizer.clean_line(NodeRef.path_of(root, holder)),
		"from": TextSanitizer.clean_line(NodeRef.path_of(root, visual)),
		"kind": kind,
		"size": _numbers(size),
		"position": _numbers(position),
	}
	if options["dry_run"]:
		return Edit.planned(described)

	var undo: Object = _context.undo_redo()
	var action := Edit.undo_name(NAME, described["shape"])
	undo.create_action(action, UndoRedo.MERGE_DISABLE, root)
	undo.add_do_property(holder, "shape", shape)
	undo.add_do_property(holder, "position", position)
	undo.add_undo_property(holder, "shape", holder.shape)
	undo.add_undo_property(holder, "position", holder.position)
	undo.add_do_reference(shape)
	undo.commit_action()
	return Edit.done(described, action)


func _missing(path: String) -> Dictionary:
	return Reply.fail("NODE_NOT_FOUND", "The node does not exist.", "Use scene_tree to see the node paths.", {"path": TextSanitizer.clean_line(path)})


## The first sprite or mesh among the shape's siblings, then under its body.
func _visual_near(holder: Node, flat: bool) -> Node:
	var parent := holder.get_parent()
	if parent == null:
		return null
	for child in parent.get_children():
		if _is_visual(child, flat):
			return child
	for node in parent.find_children("*", "", true, false):
		if _is_visual(node, flat):
			return node
	return null


static func _is_visual(node: Node, flat: bool) -> bool:
	return (node is Sprite2D or node is AnimatedSprite2D) if flat else node is MeshInstance3D


# Transforms to the edited scene's root, from the nodes' own: the same in the
# editor and in a tree that has not been entered.
static func _to_root_2d(node: Node, root: Node) -> Transform2D:
	var xform := Transform2D.IDENTITY
	var current := node
	while current != null and current != root.get_parent():
		if current is CanvasItem:
			xform = current.get_transform() * xform
		current = current.get_parent()
	return xform


static func _to_root_3d(node: Node, root: Node) -> Transform3D:
	var xform := Transform3D.IDENTITY
	var current := node
	while current != null and current != root.get_parent():
		if current is Node3D:
			xform = current.transform * xform
		current = current.get_parent()
	return xform


## {size: Vector2, centre: Vector2 in the scene root's space} of a sprite as drawn, or why not.
func _bounds_2d(visual: Node, root: Node) -> Variant:
	var rect := Rect2()
	if visual is Sprite2D:
		if visual.texture == null:
			return "The sprite has no texture to measure."
		rect = visual.get_rect()
	elif visual is AnimatedSprite2D:
		var frames: SpriteFrames = visual.sprite_frames
		if frames == null or not frames.has_animation(visual.animation) or frames.get_frame_count(visual.animation) == 0:
			return "The animated sprite has no frame to measure."
		var texture: Texture2D = frames.get_frame_texture(visual.animation, visual.frame)
		var frame_size := texture.get_size()
		rect = Rect2(-frame_size / 2.0 if visual.centered else Vector2.ZERO, frame_size)
		rect.position += visual.offset
	else:
		return "from is not a Sprite2D or AnimatedSprite2D."
	var xform := _to_root_2d(visual, root)
	var scale := xform.get_scale().abs()
	return {"size": rect.size * scale, "centre": xform * rect.get_center()}


## {size: Vector3, centre: Vector3 in the scene root's space} of a mesh, or why not.
func _bounds_3d(visual: Node, root: Node) -> Variant:
	if not visual is MeshInstance3D:
		return "from is not a MeshInstance3D."
	if visual.mesh == null:
		return "The mesh instance has no mesh to measure."
	var box: AABB = visual.mesh.get_aabb()
	var xform := _to_root_3d(visual, root)
	var scale := xform.basis.get_scale().abs()
	return {"size": box.size * scale, "centre": xform * box.get_center()}


static func _shape_2d(kind: String, size: Vector2) -> Shape2D:
	match kind:
		"circle":
			var circle := CircleShape2D.new()
			circle.radius = maxf(size.x, size.y) / 2.0
			return circle
		"capsule":
			var capsule := CapsuleShape2D.new()
			capsule.radius = minf(size.x, size.y) / 2.0
			capsule.height = maxf(size.y, capsule.radius * 2.0)
			return capsule
	var rectangle := RectangleShape2D.new()
	rectangle.size = size
	return rectangle


static func _shape_3d(kind: String, size: Vector3) -> Shape3D:
	match kind:
		"circle":
			var sphere := SphereShape3D.new()
			sphere.radius = maxf(size.x, maxf(size.y, size.z)) / 2.0
			return sphere
		"capsule":
			var capsule := CapsuleShape3D.new()
			capsule.radius = maxf(size.x, size.z) / 2.0
			capsule.height = maxf(size.y, capsule.radius * 2.0)
			return capsule
	var box := BoxShape3D.new()
	box.size = size
	return box


static func _numbers(value: Variant) -> Array:
	if value is Vector2:
		return [snappedf(value.x, 0.01), snappedf(value.y, 0.01)]
	return [snappedf(value.x, 0.01), snappedf(value.y, 0.01), snappedf(value.z, 0.01)]
