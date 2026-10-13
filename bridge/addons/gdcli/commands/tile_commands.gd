extends RefCounted
## Tile maps: giving a TileMapLayer a tile set cut from an atlas image,
## painting cells and reading them back. Without these, a level made of tiles
## can only be painted by hand or by code run in the editor.

const AccessPolicy = preload("../core/access_policy.gd")
const Edit = preload("../core/edit.gd")
const NodeRef = preload("../core/node_ref.gd")
const ImageFile = preload("../core/image_file.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")

const MAX_CELLS := 20000
const MAX_TILES := 4096
const MAX_LISTED_CELLS := 2000
const _DEFAULT_TILE_SIZE := Vector2i(16, 16)
const _NO_SOURCE := -1
# Far beyond any level, and small enough to add and multiply without care.
const _MAX_COORDINATE := 1.0e9
const _NO_TILE := Vector2i(-1, -1)
const _PHYSICS_LAYER := 0
const _GROUP := "tilemap"
const _OTHER_TILE_SIZE := "The tiles are cut at a size other than the tile set's tile size: they will not line up with the cells."

var _context: RefCounted


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "tileset_add_atlas",
		"group": _GROUP,
		"summary": "Cut an image into tiles and add them to the tile set of a TileMapLayer, creating the tile set if the layer has none.",
		"risk": AccessPolicy.RISK_WRITE,
		"undoable": true,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"layer": {"type": "string", "description": "Path of the TileMapLayer node."},
				"texture": {"type": "string", "description": "res:// path of the atlas image."},
				"tile_size": {"type": "array", "description": "[width, height] of one tile in pixels. Default: the tile set's tile size, or 16 by 16 for a new one."},
				"margins": {"type": "array", "description": "[x, y] pixels around the tiles in the image. Default [0, 0]."},
				"separation": {"type": "array", "description": "[x, y] pixels between tiles in the image. Default [0, 0]."},
				"collision": {
					"type": "boolean", "default": false,
					"description": "Give every tile a collision shape that fills it (the tile set gets a physics layer when it has none).",
				},
			},
			"required": ["layer", "texture"],
		},
		"returns": "{layer, source: id to paint with, columns, rows, tiles, tile_size}; meta.undo names the undo step. A tile is addressed by its column and row in the image: [0, 0] is the top left one.",
	}, _add_atlas)
	registry.register({
		"name": "tilemap_set_cells",
		"group": _GROUP,
		"summary": "Paint or erase cells of a TileMapLayer.",
		"risk": AccessPolicy.RISK_WRITE,
		"undoable": true,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"layer": {"type": "string", "description": "Path of the TileMapLayer node."},
				"cells": {"type": "array", "description": "Cells as [x, y] pairs in map coordinates."},
				"rect": {"type": "array", "description": "[x, y, width, height] in cells: every cell of the rectangle, in addition to `cells`."},
				"source": {"type": "integer", "default": 0, "description": "Id of the tile set source, as tileset_add_atlas returned it."},
				"atlas": {"type": "array", "description": "[column, row] of the tile in the atlas. Default [0, 0]."},
				"alternative": {"type": "integer", "default": 0, "minimum": 0},
				"erase": {"type": "boolean", "default": false, "description": "Clear the cells instead of painting them."},
			},
			"required": ["layer"],
		},
		"returns": "{layer, cells: number changed, used_rect: [x, y, width, height]}; meta.undo names the undo step.",
	}, _set_cells)
	registry.register({
		"name": "tilemap_get",
		"group": _GROUP,
		"summary": "The tile set sources of a TileMapLayer and the cells that are painted.",
		"risk": AccessPolicy.RISK_READ,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"layer": {"type": "string", "description": "Path of the TileMapLayer node."},
				"rect": {"type": "array", "description": "[x, y, width, height] in cells: list only the cells inside."},
				"limit": {"type": "integer", "default": 500, "minimum": 0, "maximum": MAX_LISTED_CELLS},
			},
			"required": ["layer"],
		},
		"returns": "{layer, tile_size, sources: [{id, texture, columns, rows, tiles}], used_rect, cell_count, cells: [{x, y, source, atlas: [column, row]}], truncated}",
	}, _get_cells)


func _root() -> Node:
	return _context.scene_root()


# The TileMapLayer, or a failed reply.
func _layer(path: String) -> Variant:
	var node := NodeRef.resolve(_root(), path)
	if node == null:
		return Reply.fail("NODE_NOT_FOUND", "The node does not exist.", "Use scene_tree to see the node paths.", {"path": TextSanitizer.clean_line(path)})
	if not node is TileMapLayer:
		return Reply.fail(
			"TYPE_MISMATCH", "The node is not a TileMapLayer.", "Create one with node_create; each layer of a map is a node of its own.",
			{"path": TextSanitizer.clean_line(path), "class": node.get_class()},
		)
	return node


# `count` whole numbers from a JSON array, or null. JSON numbers arrive as floats.
static func _ints(value: Variant, count: int) -> Variant:
	if not value is Array or value.size() != count:
		return null
	var numbers: Array[int] = []
	for entry in value:
		if not (entry is int or (entry is float and entry == floorf(entry) and absf(entry) <= _MAX_COORDINATE)):
			return null
		numbers.append(int(entry))
	return numbers


# Whether a width and a height make a rectangle of at most MAX_CELLS cells.
# Each is bounded before they are multiplied: the product of two huge numbers
# wraps around to a small one.
static func _is_area(width: int, height: int) -> bool:
	return width >= 1 and height >= 1 and width <= MAX_CELLS and height <= MAX_CELLS and width * height <= MAX_CELLS


# A pair of whole numbers of at least `minimum`, `fallback` when not given, or null.
static func _pair(value: Variant, fallback: Vector2i, minimum: int) -> Variant:
	if value == null:
		return fallback
	var numbers: Variant = _ints(value, 2)
	if numbers == null or numbers[0] < minimum or numbers[1] < minimum:
		return null
	return Vector2i(numbers[0], numbers[1])


func _add_atlas(args: Dictionary, options: Dictionary) -> Dictionary:
	var layer: Variant = _layer(args["layer"])
	if layer is Dictionary:
		return layer
	var texture: Variant = ImageFile.load_texture(args["texture"])
	if texture is Dictionary:
		return texture

	var existing: TileSet = layer.tile_set
	var stored := _stored_elsewhere(existing)
	if not stored.is_empty():
		return stored
	var size: Variant = _pair(args.get("tile_size"), existing.tile_size if existing != null else _DEFAULT_TILE_SIZE, 1)
	var margins: Variant = _pair(args.get("margins"), Vector2i.ZERO, 0)
	var separation: Variant = _pair(args.get("separation"), Vector2i.ZERO, 0)
	if size == null or margins == null or separation == null:
		return Reply.fail("INVALID_ARGS", "tile_size, margins and separation are pairs of whole numbers; a tile is at least one pixel.")

	var source := TileSetAtlasSource.new()
	source.texture = texture
	source.margins = margins
	source.separation = separation
	source.texture_region_size = size
	var grid := source.get_atlas_grid_size()
	if grid.x < 1 or grid.y < 1 or grid.x * grid.y > MAX_TILES:
		return Reply.fail(
			"INVALID_ARGS", "With this tile size the image holds no tile, or more than %d." % MAX_TILES, "",
			{"image": [texture.get_width(), texture.get_height()], "tile_size": [size.x, size.y]},
		)
	for row in grid.y:
		for column in grid.x:
			source.create_tile(Vector2i(column, row))
	if options["dry_run"]:
		return Edit.planned({"add_atlas": texture.resource_path, "to": args["layer"], "columns": grid.x, "rows": grid.y, "new_tile_set": existing == null})

	var tile_set := existing if existing != null else TileSet.new()
	if existing == null:
		tile_set.tile_size = size
	var id := tile_set.get_next_source_id()
	var adds_physics_layer: bool = args["collision"] and tile_set.get_physics_layers_count() == 0
	var action := Edit.undo_name("tileset_add_atlas", str(layer.name))
	var undo: Object = _context.undo_redo()
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	if existing == null:
		undo.add_do_property(layer, "tile_set", tile_set)
		undo.add_undo_property(layer, "tile_set", null)
	undo.add_do_method(self, "_attach_source", tile_set, source, id, args["collision"])
	undo.add_undo_method(self, "_detach_source", tile_set, id, adds_physics_layer)
	undo.add_do_reference(source)
	undo.commit_action()
	return Edit.done({
		"layer": TextSanitizer.clean_line(NodeRef.path_of(_root(), layer)),
		"source": id, "columns": grid.x, "rows": grid.y, "tiles": grid.x * grid.y, "tile_size": [size.x, size.y],
	}, action, [_OTHER_TILE_SIZE] if size != tile_set.tile_size else [])


# A tile set that is a file of its own is shared by every scene that uses it,
# and saving the scene does not save it. Changing one is left to the person.
func _stored_elsewhere(tile_set: TileSet) -> Dictionary:
	if tile_set == null or tile_set.resource_path == "" or tile_set.resource_path.contains("::"):
		return {}
	return Reply.fail(
		"PRECONDITION_FAILED", "The layer's tile set is a file of its own, which this command does not change.",
		"Make the tile set part of the scene (set tile_set to a new TileSet with node_set), or edit the file in the editor.",
		{"tile_set": TextSanitizer.clean_line(tile_set.resource_path)},
	)


# Called by the undo history, also when the step is redone.
func _attach_source(tile_set: TileSet, source: TileSetAtlasSource, id: int, collision: bool) -> void:
	if collision and tile_set.get_physics_layers_count() == 0:
		tile_set.add_physics_layer()
	tile_set.add_source(source, id)
	if not collision:
		return
	# Tile shapes are measured from the centre of the tile.
	var half := Vector2(source.texture_region_size) / 2.0
	var square := PackedVector2Array([Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y)])
	for index in source.get_tiles_count():
		var data := source.get_tile_data(source.get_tile_id(index), 0)
		if data.get_collision_polygons_count(_PHYSICS_LAYER) == 0:
			data.add_collision_polygon(_PHYSICS_LAYER)
			data.set_collision_polygon_points(_PHYSICS_LAYER, 0, square)


func _detach_source(tile_set: TileSet, id: int, remove_physics_layer: bool) -> void:
	tile_set.remove_source(id)
	if remove_physics_layer:
		tile_set.remove_physics_layer(_PHYSICS_LAYER)


# The distinct cells named by `cells` and `rect`, or a failed reply.
func _cells_of(args: Dictionary) -> Variant:
	var found := {}
	if args.get("cells", []).size() > MAX_CELLS:
		return Reply.fail("INVALID_ARGS", "Name between 1 and %d cells with cells and rect." % MAX_CELLS)
	for entry in args.get("cells", []):
		var pair: Variant = _ints(entry, 2)
		if pair == null:
			return Reply.fail("INVALID_ARGS", "Each cell is a pair of whole numbers [x, y].")
		found[Vector2i(pair[0], pair[1])] = true
	if args.has("rect"):
		var rect: Variant = _ints(args["rect"], 4)
		if rect == null or not _is_area(rect[2], rect[3]):
			return Reply.fail("INVALID_ARGS", "rect is [x, y, width, height] in whole cells, at most %d of them." % MAX_CELLS)
		for y in rect[3]:
			for x in rect[2]:
				found[Vector2i(rect[0] + x, rect[1] + y)] = true
	if found.is_empty() or found.size() > MAX_CELLS:
		return Reply.fail("INVALID_ARGS", "Name between 1 and %d cells with cells and rect." % MAX_CELLS)
	var cells: Array[Vector2i] = []
	cells.assign(found.keys())
	return cells


func _set_cells(args: Dictionary, options: Dictionary) -> Dictionary:
	var layer: Variant = _layer(args["layer"])
	if layer is Dictionary:
		return layer
	var cells: Variant = _cells_of(args)
	if cells is Dictionary:
		return cells
	var source_id: int = _NO_SOURCE if args["erase"] else args["source"]
	var atlas := _NO_TILE
	if not args["erase"]:
		var picked: Variant = _pair(args.get("atlas"), Vector2i.ZERO, 0)
		if picked == null:
			return Reply.fail("INVALID_ARGS", "atlas is the [column, row] of a tile.")
		atlas = picked
		var missing := _missing_tile(layer.tile_set, source_id, atlas, args["alternative"])
		if not missing.is_empty():
			return missing
	if options["dry_run"]:
		return Edit.planned({"cells": cells.size(), "on": args["layer"], "erase": args["erase"]})

	var before := []
	for cell in cells:
		before.append([cell, layer.get_cell_source_id(cell), layer.get_cell_atlas_coords(cell), layer.get_cell_alternative_tile(cell)])
	var action := Edit.undo_name("tilemap_set_cells", str(layer.name))
	var undo: Object = _context.undo_redo()
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	undo.add_do_method(self, "_paint", layer, cells, source_id, atlas, args["alternative"])
	undo.add_undo_method(self, "_restore", layer, before)
	undo.commit_action()
	var used: Rect2i = layer.get_used_rect()
	return Edit.done({
		"layer": TextSanitizer.clean_line(NodeRef.path_of(_root(), layer)),
		"cells": cells.size(), "used_rect": [used.position.x, used.position.y, used.size.x, used.size.y],
	}, action)


# A failed reply when the tile to paint with does not exist; {} when it does.
func _missing_tile(tile_set: TileSet, source_id: int, atlas: Vector2i, alternative: int) -> Dictionary:
	if tile_set == null:
		return Reply.fail("PRECONDITION_FAILED", "The layer has no tile set.", "Give it one with tileset_add_atlas.")
	if not tile_set.has_source(source_id):
		return Reply.fail("INVALID_ARGS", "The tile set has no source with this id.", "tilemap_get lists the sources.", {"source": source_id})
	var source := tile_set.get_source(source_id)
	if source is TileSetAtlasSource and not (source.has_tile(atlas) and source.has_alternative_tile(atlas, alternative)):
		var grid: Vector2i = source.get_atlas_grid_size()
		return Reply.fail(
			"INVALID_ARGS", "The source has no such tile.", "A tile is [column, row] in the atlas image, counted from 0.",
			{"atlas": [atlas.x, atlas.y], "alternative": alternative, "columns": grid.x, "rows": grid.y},
		)
	return {}


func _paint(layer: TileMapLayer, cells: Array, source_id: int, atlas: Vector2i, alternative: int) -> void:
	for cell in cells:
		layer.set_cell(cell, source_id, atlas, alternative)


func _restore(layer: TileMapLayer, before: Array) -> void:
	for entry in before:
		layer.set_cell(entry[0], entry[1], entry[2], entry[3])


func _get_cells(args: Dictionary) -> Dictionary:
	var layer: Variant = _layer(args["layer"])
	if layer is Dictionary:
		return layer
	var inside := Rect2i()
	if args.has("rect"):
		var rect: Variant = _ints(args["rect"], 4)
		if rect == null or rect[2] < 1 or rect[3] < 1:
			return Reply.fail("INVALID_ARGS", "rect is [x, y, width, height] in whole cells.")
		inside = Rect2i(rect[0], rect[1], rect[2], rect[3])

	var tile_set: TileSet = layer.tile_set
	var sources := []
	if tile_set != null:
		for index in tile_set.get_source_count():
			sources.append(_describe_source(tile_set, tile_set.get_source_id(index)))
	var listed := []
	var matching := 0
	for cell in layer.get_used_cells():
		if args.has("rect") and not inside.has_point(cell):
			continue
		matching += 1
		if listed.size() < args["limit"]:
			var atlas: Vector2i = layer.get_cell_atlas_coords(cell)
			listed.append({"x": cell.x, "y": cell.y, "source": layer.get_cell_source_id(cell), "atlas": [atlas.x, atlas.y]})
	var used: Rect2i = layer.get_used_rect()
	return Reply.ok({
		"layer": TextSanitizer.clean_line(NodeRef.path_of(_root(), layer)),
		"tile_size": [tile_set.tile_size.x, tile_set.tile_size.y] if tile_set != null else null,
		"sources": sources,
		"used_rect": [used.position.x, used.position.y, used.size.x, used.size.y],
		"cell_count": matching,
		"cells": listed,
		"truncated": matching > listed.size(),
	})


func _describe_source(tile_set: TileSet, id: int) -> Dictionary:
	var source := tile_set.get_source(id)
	var described := {"id": id, "class": source.get_class(), "tiles": source.get_tiles_count()}
	if source is TileSetAtlasSource:
		var grid: Vector2i = source.get_atlas_grid_size()
		described["columns"] = grid.x
		described["rows"] = grid.y
		described["texture"] = TextSanitizer.clean_line(source.texture.resource_path) if source.texture != null else null
	return described
