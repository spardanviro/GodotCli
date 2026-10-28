extends RefCounted
## 3D levels from blocks: a GridMap's mesh library (the pieces) and its cells.

const AccessPolicy = preload("../core/access_policy.gd")
const Edit = preload("../core/edit.gd")
const NodeRef = preload("../core/node_ref.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")
const ValueDecoder = preload("../core/value_decoder.gd")

const MAX_CELLS := 20000
# A GridMap stores each coordinate in 16 bits.
const MIN_COORDINATE := -32768
const MAX_COORDINATE := 32767
const MAX_LISTED_CELLS := 5000
const _COLLISIONS: Array[String] = ["box", "convex", "trimesh", "none"]
const _GRIDMAP := {"type": "string", "description": "Path of the GridMap node."}

var _context: RefCounted


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "gridmap_library_add",
		"summary": "Add a piece to a GridMap's mesh library (made when it has none): a mesh, with a collision shape made from it.",
		"risk": AccessPolicy.RISK_WRITE,
		"undoable": true,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"gridmap": _GRIDMAP,
				"name": {"type": "string"},
				"mesh": {"description": "{\"$new\": \"BoxMesh\", \"properties\": {...}} or {\"$res\": \"res://models/wall.tres\"}."},
				"collision": {"type": "string", "enum": _COLLISIONS, "default": "box", "description": "box: around the mesh; convex or trimesh: from its shape (trimesh for static level pieces); none."},
			},
			"required": ["gridmap", "name", "mesh"],
		},
		"returns": "{gridmap, item, name}: item is the number gridmap_set_cells uses. One undo step.",
	}, _library_add)
	registry.register({
		"name": "gridmap_set_cells",
		"summary": "Place or erase pieces in a GridMap's cells, one by one or filling a box.",
		"risk": AccessPolicy.RISK_WRITE,
		"undoable": true,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"gridmap": _GRIDMAP,
				"cells": {"type": "array", "description": "[[x, y, z, item], ...] or [x, y, z, item, orientation] (0 to 23); item -1 erases."},
				"box": {"type": "object", "description": "{\"from\": [x, y, z], \"to\": [x, y, z], \"item\": n}: every cell between, both ends included."},
			},
			"required": ["gridmap"],
		},
		"returns": "{gridmap, cells}; meta.undo names the undo step. At most 20000 cells at once.",
	}, _set_cells)
	registry.register({
		"name": "gridmap_get",
		"summary": "The pieces of a GridMap's mesh library and the cells in use.",
		"risk": AccessPolicy.RISK_READ,
		"requires": ["scene_open"],
		"params": {"type": "object", "properties": {"gridmap": _GRIDMAP}, "required": ["gridmap"]},
		"returns": "{gridmap, cell_size, items: [{item, name}], cells: [[x, y, z, item, orientation]], truncated}",
	}, _gridmap_get)


func _gridmap(path: String) -> Variant:
	var root: Node = _context.scene_root()
	var node := NodeRef.resolve(root, path)
	if node == null:
		return Reply.fail("NODE_NOT_FOUND", "The node does not exist.", "Use scene_tree to see the node paths.", {"path": TextSanitizer.clean_line(path)})
	if not node is GridMap:
		return Reply.fail("TYPE_MISMATCH", "The node is not a GridMap.", "Create one with node_create --type GridMap.", {"class": node.get_class()})
	return node


func _library_add(args: Dictionary, options: Dictionary) -> Dictionary:
	var found: Variant = _gridmap(args["gridmap"])
	if found is Dictionary:
		return found
	var gridmap: GridMap = found
	var previous: MeshLibrary = gridmap.mesh_library
	# A library that is a file of its own is shared with other scenes.
	if previous != null and previous.resource_path != "" and not previous.resource_path.contains("::"):
		return Reply.fail("PRECONDITION_FAILED", "The GridMap's mesh library is a file of its own, which this command does not change.", "Edit that library in the editor, or remove it from the GridMap first.", {"library": TextSanitizer.clean_line(previous.resource_path)})
	var holder := MeshInstance3D.new()
	var decoded: Dictionary = ValueDecoder.new(_context.scene_root()).decode_properties(holder, {"mesh": args["mesh"]})
	holder.free()
	if not decoded["ok"]:
		return decoded
	var mesh: Mesh = decoded["values"]["mesh"]
	if mesh == null:
		return Reply.fail("INVALID_ARGS", "mesh is needed.")
	var name: String = args["name"]
	var library: MeshLibrary = previous.duplicate() if previous != null else MeshLibrary.new()
	for existing in library.get_item_list():
		if library.get_item_name(existing) == name:
			return Reply.fail("ALREADY_EXISTS", "The library has a piece of this name.", "", {"item": existing})
	var item := library.get_last_unused_item_id()
	if options["dry_run"]:
		return Edit.planned({"gridmap": TextSanitizer.clean_line(args["gridmap"]), "item": item, "name": TextSanitizer.clean_line(name)})
	library.create_item(item)
	library.set_item_name(item, name)
	library.set_item_mesh(item, mesh)
	var shape := _shape_for(mesh, args.get("collision", "box"))
	if shape != null:
		# A box goes where the mesh is; shapes made from the mesh are already there.
		var place := Transform3D(Basis(), mesh.get_aabb().get_center()) if shape is BoxShape3D else Transform3D.IDENTITY
		library.set_item_shapes(item, [shape, place])

	var root: Node = _context.scene_root()
	var undo: Object = _context.undo_redo()
	var action := Edit.undo_name("gridmap_library_add", name)
	undo.create_action(action, UndoRedo.MERGE_DISABLE, root)
	undo.add_do_property(gridmap, "mesh_library", library)
	undo.add_undo_property(gridmap, "mesh_library", previous)
	undo.add_do_reference(library)
	undo.commit_action()
	return Edit.done({"gridmap": TextSanitizer.clean_line(NodeRef.path_of(root, gridmap)), "item": item, "name": TextSanitizer.clean_line(name)}, action)


static func _shape_for(mesh: Mesh, collision: String) -> Shape3D:
	match collision:
		"box":
			var box := BoxShape3D.new()
			box.size = mesh.get_aabb().size
			return box
		"convex":
			return mesh.create_convex_shape()
		"trimesh":
			return mesh.create_trimesh_shape()
	return null


func _set_cells(args: Dictionary, options: Dictionary) -> Dictionary:
	var found: Variant = _gridmap(args["gridmap"])
	if found is Dictionary:
		return found
	var gridmap: GridMap = found
	var cells := []
	for entry in args.get("cells", []):
		var cell := _cell(entry)
		if cell.is_empty():
			return Reply.fail("INVALID_ARGS", "A cell is [x, y, z, item] or [x, y, z, item, orientation] with whole numbers; orientation 0 to 23.", "", {"cell": TextSanitizer.clean_line(str(entry))})
		cells.append(cell)
	if args.has("box"):
		var filled: Variant = _box(args["box"])
		if filled is String:
			return Reply.fail("INVALID_ARGS", filled)
		cells.append_array(filled)
	if cells.is_empty():
		return Reply.fail("INVALID_ARGS", "No cells given.", "Pass cells, box, or both.")
	if cells.size() > MAX_CELLS:
		return Reply.fail("INVALID_ARGS", "At most %d cells at once." % MAX_CELLS)
	var library := gridmap.mesh_library
	for cell in cells:
		if cell[1] != GridMap.INVALID_CELL_ITEM and (library == null or not cell[1] in library.get_item_list()):
			return Reply.fail("INVALID_ARGS", "The mesh library has no such item.", "gridmap_get lists the items; gridmap_library_add adds one.", {"item": cell[1]})
	if options["dry_run"]:
		return Edit.planned({"gridmap": TextSanitizer.clean_line(args["gridmap"]), "cells": cells.size()})

	var root: Node = _context.scene_root()
	var undo: Object = _context.undo_redo()
	var action := Edit.undo_name("gridmap_set_cells", "%d cells" % cells.size())
	undo.create_action(action, UndoRedo.MERGE_DISABLE, root)
	for cell in cells:
		var position: Vector3i = cell[0]
		undo.add_do_method(gridmap, "set_cell_item", position, cell[1], cell[2])
	# Put back in reverse, so a cell given twice ends as it was.
	for index in range(cells.size() - 1, -1, -1):
		var position: Vector3i = cells[index][0]
		undo.add_undo_method(gridmap, "set_cell_item", position, gridmap.get_cell_item(position), gridmap.get_cell_item_orientation(position))
	undo.commit_action()
	return Edit.done({"gridmap": TextSanitizer.clean_line(NodeRef.path_of(root, gridmap)), "cells": cells.size()}, action)


## [Vector3i, item, orientation], or [] when the entry is not a cell.
static func _cell(entry: Variant) -> Array:
	if not (entry is Array and (entry.size() == 4 or entry.size() == 5)):
		return []
	for value in entry:
		if not (value is int or (value is float and is_finite(value) and value == floorf(value))):
			return []
	for axis in 3:
		if int(entry[axis]) < MIN_COORDINATE or int(entry[axis]) > MAX_COORDINATE:
			return []
	var orientation := int(entry[4]) if entry.size() == 5 else 0
	if orientation < 0 or orientation > 23:
		return []
	return [Vector3i(int(entry[0]), int(entry[1]), int(entry[2])), int(entry[3]), orientation]


static func _box(spec: Variant) -> Variant:
	if not (spec is Dictionary and spec.get("from") is Array and spec.get("to") is Array and spec.has("item") and spec["from"].size() == 3 and spec["to"].size() == 3):
		return "box is {from: [x, y, z], to: [x, y, z], item}."
	var from := _cell(spec["from"] + [spec["item"]])
	var to := _cell(spec["to"] + [spec["item"]])
	if from.is_empty() or to.is_empty():
		return "box corners are [x, y, z] with whole numbers from %d to %d." % [MIN_COORDINATE, MAX_COORDINATE]
	var a: Vector3i = from[0]
	var b: Vector3i = to[0]
	var low := Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z))
	var high := Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z))
	# Coordinates are 16 bits, so this product cannot overflow.
	var count := (high.x - low.x + 1) * (high.y - low.y + 1) * (high.z - low.z + 1)
	if count > MAX_CELLS:
		return "The box holds more than %d cells." % MAX_CELLS
	var cells := []
	for x in range(low.x, high.x + 1):
		for y in range(low.y, high.y + 1):
			for z in range(low.z, high.z + 1):
				cells.append([Vector3i(x, y, z), from[1], 0])
	return cells


func _gridmap_get(args: Dictionary) -> Dictionary:
	var found: Variant = _gridmap(args["gridmap"])
	if found is Dictionary:
		return found
	var gridmap: GridMap = found
	var items := []
	if gridmap.mesh_library != null:
		for item in gridmap.mesh_library.get_item_list():
			items.append({"item": item, "name": TextSanitizer.clean_line(gridmap.mesh_library.get_item_name(item))})
	var cells := []
	var used := gridmap.get_used_cells()
	for index in mini(used.size(), MAX_LISTED_CELLS):
		var position: Vector3i = used[index]
		cells.append([position.x, position.y, position.z, gridmap.get_cell_item(position), gridmap.get_cell_item_orientation(position)])
	return Reply.ok({
		"gridmap": TextSanitizer.clean_line(NodeRef.path_of(_context.scene_root(), gridmap)),
		"cell_size": [gridmap.cell_size.x, gridmap.cell_size.y, gridmap.cell_size.z],
		"items": items,
		"cells": cells,
		"truncated": used.size() > MAX_LISTED_CELLS,
	})
