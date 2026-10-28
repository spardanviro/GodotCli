extends "tile_commands.gd"
## What the tiles of a tile set are, beyond their picture: the shape they
## collide with (slopes, half tiles, one-way platforms) and the terrain they
## belong to, from which the engine picks tiles that fit their neighbours.

const _HALF := 0.5
const _MAX_POLYGON_POINTS := 32
const _MIN_POLYGON_POINTS := 3
# Shapes as corners of the tile, (0, 0) top left and (1, 1) bottom right.
const _SHAPES := {
	"full": [[0, 0], [1, 0], [1, 1], [0, 1]],
	"none": [],
	"half_bottom": [[0, 0.5], [1, 0.5], [1, 1], [0, 1]],
	"half_top": [[0, 0], [1, 0], [1, 0.5], [0, 0.5]],
	"half_left": [[0, 0], [0.5, 0], [0.5, 1], [0, 1]],
	"half_right": [[0.5, 0], [1, 0], [1, 1], [0.5, 1]],
	"slope_right": [[0, 1], [1, 0], [1, 1]],
	"slope_left": [[0, 0], [1, 1], [0, 1]],
}
const _MODES := {
	"sides": TileSet.TERRAIN_MODE_MATCH_SIDES,
	"corners": TileSet.TERRAIN_MODE_MATCH_CORNERS,
	"corners_and_sides": TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES,
}
const _SIDES := {
	"right": TileSet.CELL_NEIGHBOR_RIGHT_SIDE, "bottom": TileSet.CELL_NEIGHBOR_BOTTOM_SIDE,
	"left": TileSet.CELL_NEIGHBOR_LEFT_SIDE, "top": TileSet.CELL_NEIGHBOR_TOP_SIDE,
}
# Each corner with the two sides it lies between.
const _CORNERS := {
	"bottom_right": [TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER, "bottom", "right"],
	"bottom_left": [TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER, "bottom", "left"],
	"top_left": [TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER, "top", "left"],
	"top_right": [TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER, "top", "right"],
}
const _BLOCK_SIZE := 3
const _TERRAIN_NAME_PATTERN := "^[^\\x00-\\x1f]{1,64}\\z"


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "tileset_set_collision",
		"group": "tilemap",
		"summary": "Give tiles of a TileMapLayer's tile set a collision shape: full, a slope, half a tile, a polygon of your own, or none; optionally one-way.",
		"risk": AccessPolicy.RISK_WRITE,
		"undoable": true,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"layer": {"type": "string", "description": "Path of the TileMapLayer node."},
				"source": {"type": "integer", "default": 0, "description": "Id of the tile set source."},
				"tiles": {"type": "array", "description": "Tiles as [column, row] in the atlas. Default: every tile of the source."},
				"shape": {
					"type": "string", "enum": _SHAPES.keys(), "default": "full",
					"description": "slope_right rises towards the right (its high side is on the right), slope_left towards the left.",
				},
				"polygon": {
					"type": "array",
					"description": "Instead of shape (it wins when both are given): corner points [[x, y], ...] of a convex outline, with (0, 0) the top left of the tile and (1, 1) its bottom right.",
				},
				"one_way": {"type": "boolean", "default": false, "description": "Solid only from above: a platform that can be jumped through from below."},
			},
			"required": ["layer"],
		},
		"returns": "{layer, source, tiles: number of tiles given, shape}; meta.undo names the undo step. Replaces the collision shapes these tiles had.",
	}, _set_collision)
	registry.register({
		"name": "tileset_set_terrain",
		"group": "tilemap",
		"summary": "Make tiles part of a terrain, so that painting with the terrain picks the tile that fits its neighbours (autotiling).",
		"risk": AccessPolicy.RISK_WRITE,
		"undoable": true,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"layer": {"type": "string", "description": "Path of the TileMapLayer node."},
				"source": {"type": "integer", "default": 0, "description": "Id of the tile set source."},
				"terrain": {"type": "string", "description": "Name of the terrain, e.g. grass. Created when the tile set has none of this name."},
				"mode": {
					"type": "string", "enum": _MODES.keys(),
					"description": "What neighbours are compared: sides, corners, or both. Applies when the terrain set is created (default sides); an existing one keeps its mode.",
				},
				"block": {
					"type": "array",
					"description": "[column, row] of the top left tile of a 3 by 3 block drawn as one piece of ground: corners, edges and a centre. Its nine tiles get the matching neighbours.",
				},
				"tiles": {
					"type": "array",
					"items": {"type": "object"},
					"description": "Single tiles: {atlas: [column, row], connects: [directions the same terrain continues in: right, bottom, left, top, and with corners bottom_right, bottom_left, top_left, top_right]}.",
				},
			},
			"required": ["layer", "terrain"],
		},
		"returns": "{layer, terrain, mode, tiles: number set}; meta.undo names the undo step. Paint with tilemap_set_cells and terrain.",
	}, _set_terrain)


# The atlas source to change, or a failed reply.
func _source_of(layer: TileMapLayer, source_id: int) -> Variant:
	var tile_set: TileSet = layer.tile_set
	if tile_set == null:
		return Reply.fail("PRECONDITION_FAILED", "The layer has no tile set.", "Give it one with tileset_add_atlas.")
	var stored := _stored_elsewhere(tile_set)
	if not stored.is_empty():
		return stored
	if not tile_set.has_source(source_id) or not tile_set.get_source(source_id) is TileSetAtlasSource:
		return Reply.fail("INVALID_ARGS", "The tile set has no atlas source with this id.", "tilemap_get lists the sources.", {"source": source_id})
	return tile_set.get_source(source_id)


# One tile of `source` from a JSON pair, or null.
func _tile(source: TileSetAtlasSource, value: Variant) -> Variant:
	var pair: Variant = _pair(value, Vector2i.ZERO, 0)
	return pair if value != null and pair != null and source.has_tile(pair) else null


func _set_collision(args: Dictionary, options: Dictionary) -> Dictionary:
	var layer: Variant = _layer(args["layer"])
	if layer is Dictionary:
		return layer
	var source: Variant = _source_of(layer, args["source"])
	if source is Dictionary:
		return source
	var tiles: Array[Vector2i] = []
	if args.has("tiles"):
		if args["tiles"].size() > MAX_TILES:
			return Reply.fail("INVALID_ARGS", "At most %d tiles in one call." % MAX_TILES)
		for entry in args["tiles"]:
			var tile: Variant = _tile(source, entry)
			if tile == null:
				return Reply.fail("INVALID_ARGS", "A tile is the [column, row] of a tile the source has.", "tilemap_get gives the columns and rows of a source.")
			tiles.append(tile)
	else:
		for index in source.get_tiles_count():
			tiles.append(source.get_tile_id(index))
	if tiles.is_empty():
		return Reply.fail("INVALID_ARGS", "Name at least one tile.")
	var corners: Variant = args.get("polygon", _SHAPES[args["shape"]])
	# Shapes are measured in the cell the tile is drawn in.
	var polygon: Variant = _polygon(corners, Vector2(layer.tile_set.tile_size))
	if polygon == null:
		return Reply.fail("INVALID_ARGS", "polygon is a list of 3 to %d points [x, y], each between 0 and 1." % _MAX_POLYGON_POINTS)
	if options["dry_run"]:
		return Edit.planned({"collision_of": tiles.size(), "on": args["layer"], "shape": args["shape"] if not args.has("polygon") else "polygon"})

	var tile_set: TileSet = layer.tile_set
	# Removing shapes from a tile set without physics adds nothing.
	var adds_layer: bool = tile_set.get_physics_layers_count() == 0 and not polygon.is_empty()
	var spec := {"source": args["source"], "tiles": tiles, "polygon": polygon, "one_way": args["one_way"]}
	var action := Edit.undo_name("tileset_set_collision", str(layer.name))
	var undo: Object = _context.undo_redo()
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	undo.add_do_method(self, "_apply_shapes", tile_set, spec)
	undo.add_undo_method(self, "_restore_shapes", tile_set, args["source"], _shapes_of(tile_set, source, tiles), adds_layer)
	undo.commit_action()
	return Edit.done({
		"layer": TextSanitizer.clean_line(NodeRef.path_of(_root(), layer)), "source": args["source"], "tiles": tiles.size(),
		"shape": "polygon" if args.has("polygon") else args["shape"],
	}, action)


# Corners given in tile units as points around the tile's centre, or null.
func _polygon(corners: Variant, tile_size: Vector2) -> Variant:
	if not corners is Array or (not corners.is_empty() and (corners.size() < _MIN_POLYGON_POINTS or corners.size() > _MAX_POLYGON_POINTS)):
		return null
	var points := PackedVector2Array()
	for corner in corners:
		if not (corner is Array and corner.size() == 2 and _is_unit(corner[0]) and _is_unit(corner[1])):
			return null
		points.append((Vector2(corner[0], corner[1]) - Vector2(_HALF, _HALF)) * tile_size)
	return points


static func _is_unit(value: Variant) -> bool:
	return (value is float or value is int) and value >= 0.0 and value <= 1.0


# The collision polygons the tiles have now, for undo.
func _shapes_of(tile_set: TileSet, source: TileSetAtlasSource, tiles: Array) -> Array:
	var saved := []
	for tile in tiles:
		var polygons := []
		if tile_set.get_physics_layers_count() > 0:
			var data := source.get_tile_data(tile, 0)
			for index in data.get_collision_polygons_count(_PHYSICS_LAYER):
				polygons.append([data.get_collision_polygon_points(_PHYSICS_LAYER, index), data.is_collision_polygon_one_way(_PHYSICS_LAYER, index)])
		saved.append([tile, polygons])
	return saved


func _clear_shapes(data: TileData) -> void:
	while data.get_collision_polygons_count(_PHYSICS_LAYER) > 0:
		data.remove_collision_polygon(_PHYSICS_LAYER, data.get_collision_polygons_count(_PHYSICS_LAYER) - 1)


func _add_shape(data: TileData, points: PackedVector2Array, one_way: bool) -> void:
	var index := data.get_collision_polygons_count(_PHYSICS_LAYER)
	data.add_collision_polygon(_PHYSICS_LAYER)
	data.set_collision_polygon_points(_PHYSICS_LAYER, index, points)
	data.set_collision_polygon_one_way(_PHYSICS_LAYER, index, one_way)


# Called by the undo history, also when the step is redone.
func _apply_shapes(tile_set: TileSet, spec: Dictionary) -> void:
	if tile_set.get_physics_layers_count() == 0:
		if spec["polygon"].is_empty():
			return
		tile_set.add_physics_layer()
	var source: TileSetAtlasSource = tile_set.get_source(spec["source"])
	for tile in spec["tiles"]:
		var data := source.get_tile_data(tile, 0)
		_clear_shapes(data)
		if not spec["polygon"].is_empty():
			_add_shape(data, spec["polygon"], spec["one_way"])


func _restore_shapes(tile_set: TileSet, source_id: int, saved: Array, remove_physics_layer: bool) -> void:
	if remove_physics_layer:
		tile_set.remove_physics_layer(_PHYSICS_LAYER)
		return
	var source: TileSetAtlasSource = tile_set.get_source(source_id)
	for entry in saved:
		var data := source.get_tile_data(entry[0], 0)
		_clear_shapes(data)
		for polygon in entry[1]:
			_add_shape(data, polygon[0], polygon[1])


func _set_terrain(args: Dictionary, options: Dictionary) -> Dictionary:
	var layer: Variant = _layer(args["layer"])
	if layer is Dictionary:
		return layer
	var source: Variant = _source_of(layer, args["source"])
	if source is Dictionary:
		return source
	var name: String = args["terrain"]
	if RegEx.create_from_string(_TERRAIN_NAME_PATTERN).search(name) == null:
		return Reply.fail("INVALID_ARGS", "A terrain name is 1 to 64 characters on one line.")
	var tile_set: TileSet = layer.tile_set
	# Sides and corners are those of a square; other shapes have other neighbours.
	if tile_set.tile_shape != TileSet.TILE_SHAPE_SQUARE:
		return Reply.fail("PRECONDITION_FAILED", "Terrains are set up here for square tiles only.", "Set the terrain up in the tile set editor.")
	var has_set := tile_set.get_terrain_sets_count() > _TERRAIN_SET
	var mode: int = tile_set.get_terrain_set_mode(_TERRAIN_SET) if has_set else _MODES[args.get("mode", "sides")]
	if has_set and args.has("mode") and _MODES[args["mode"]] != mode:
		return Reply.fail(
			"INVALID_ARGS", "The tile set's terrains already compare other neighbours.", "Leave mode out to keep what the tile set has.",
			{"mode": _MODES.find_key(mode)},
		)
	var tiles: Variant = _terrain_tiles(source, args, mode)
	if tiles is Dictionary:
		return tiles
	if options["dry_run"]:
		return Edit.planned({"terrain": name, "tiles": tiles.size(), "on": args["layer"], "mode": _MODES.find_key(mode)})

	var spec := {"source": args["source"], "name": name, "mode": mode, "tiles": tiles}
	var action := Edit.undo_name("tileset_set_terrain", str(layer.name))
	var undo: Object = _context.undo_redo()
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	undo.add_do_method(self, "_apply_terrain", tile_set, spec)
	undo.add_undo_method(self, "_restore_terrain", tile_set, spec, _terrains_of(tile_set, source, tiles), not has_set, _terrain_index(tile_set, name) == -1)
	undo.commit_action()
	return Edit.done({
		"layer": TextSanitizer.clean_line(NodeRef.path_of(_root(), layer)), "terrain": name, "mode": _MODES.find_key(mode), "tiles": tiles.size(),
	}, action)


# The tiles to set as [[coords, {neighbour: connects}]], or a failed reply.
func _terrain_tiles(source: TileSetAtlasSource, args: Dictionary, mode: int) -> Variant:
	var tiles := []
	if args.has("block"):
		var origin: Variant = _pair(args["block"], Vector2i.ZERO, 0)
		if origin == null:
			return Reply.fail("INVALID_ARGS", "block is the [column, row] of the block's top left tile.")
		for row in _BLOCK_SIZE:
			for column in _BLOCK_SIZE:
				var coords: Vector2i = origin + Vector2i(column, row)
				if not source.has_tile(coords):
					return Reply.fail("INVALID_ARGS", "The 3 by 3 block does not fit in the atlas at this place.", "", {"missing": [coords.x, coords.y]})
				var connects: Array[String] = []
				if column > 0: connects.append("left")
				if column < _BLOCK_SIZE - 1: connects.append("right")
				if row > 0: connects.append("top")
				if row < _BLOCK_SIZE - 1: connects.append("bottom")
				tiles.append([coords, _neighbours(connects, mode, true)])
	if args.get("tiles", []).size() > MAX_TILES:
		return Reply.fail("INVALID_ARGS", "At most %d tiles in one call." % MAX_TILES)
	for entry in args.get("tiles", []):
		var coords: Variant = _tile(source, entry.get("atlas") if entry is Dictionary else null)
		var connects: Variant = entry.get("connects", []) if entry is Dictionary else null
		if coords == null or not connects is Array:
			return Reply.fail("INVALID_ARGS", "A tile needs atlas, the [column, row] of a tile the source has, and connects, a list of directions.")
		for direction in connects:
			if not (_SIDES.has(direction) or _CORNERS.has(direction)):
				return Reply.fail("INVALID_ARGS", "A direction is right, bottom, left, top, bottom_right, bottom_left, top_left or top_right.")
		tiles.append([coords, _neighbours(connects, mode, false)])
	if tiles.is_empty() or tiles.size() > MAX_TILES:
		return Reply.fail("INVALID_ARGS", "Give block, tiles, or both.")
	return tiles


# {neighbour constant: whether the terrain continues there}, for the
# neighbours the mode compares. With `fill_corners`, a corner between two
# connected sides is connected too.
func _neighbours(connects: Array, mode: int, fill_corners: bool) -> Dictionary:
	var neighbours := {}
	if mode != TileSet.TERRAIN_MODE_MATCH_CORNERS:
		for side in _SIDES:
			neighbours[_SIDES[side]] = side in connects
	if mode != TileSet.TERRAIN_MODE_MATCH_SIDES:
		for corner in _CORNERS:
			var between: Array = _CORNERS[corner]
			neighbours[between[0]] = corner in connects or (fill_corners and between[1] in connects and between[2] in connects)
	return neighbours


func _terrain_index(tile_set: TileSet, name: String) -> int:
	if tile_set.get_terrain_sets_count() > _TERRAIN_SET:
		for index in tile_set.get_terrains_count(_TERRAIN_SET):
			if tile_set.get_terrain_name(_TERRAIN_SET, index) == name:
				return index
	return -1


# What the tiles belong to now, for undo: [[coords, terrain_set, terrain, {neighbour: terrain}]].
func _terrains_of(tile_set: TileSet, source: TileSetAtlasSource, tiles: Array) -> Array:
	var saved := []
	for entry in tiles:
		var data := source.get_tile_data(entry[0], 0)
		var bits := {}
		if data.terrain_set >= 0:
			for neighbour in entry[1]:
				if data.is_valid_terrain_peering_bit(neighbour):
					bits[neighbour] = data.get_terrain_peering_bit(neighbour)
		saved.append([entry[0], data.terrain_set, data.terrain, bits])
	return saved


# Called by the undo history, also when the step is redone.
func _apply_terrain(tile_set: TileSet, spec: Dictionary) -> void:
	if tile_set.get_terrain_sets_count() <= _TERRAIN_SET:
		tile_set.add_terrain_set()
		tile_set.set_terrain_set_mode(_TERRAIN_SET, spec["mode"])
	var terrain := _terrain_index(tile_set, spec["name"])
	if terrain == -1:
		terrain = tile_set.get_terrains_count(_TERRAIN_SET)
		tile_set.add_terrain(_TERRAIN_SET)
		tile_set.set_terrain_name(_TERRAIN_SET, terrain, spec["name"])
		# The colour only tells terrains apart in the editor.
		tile_set.set_terrain_color(_TERRAIN_SET, terrain, Color.from_hsv(fmod(0.13 + 0.31 * terrain, 1.0), 0.6, 0.9))
	var source: TileSetAtlasSource = tile_set.get_source(spec["source"])
	for entry in spec["tiles"]:
		var data := source.get_tile_data(entry[0], 0)
		data.terrain_set = _TERRAIN_SET
		data.terrain = terrain
		for neighbour in entry[1]:
			data.set_terrain_peering_bit(neighbour, terrain if entry[1][neighbour] else -1)


func _restore_terrain(tile_set: TileSet, spec: Dictionary, saved: Array, remove_set: bool, remove_terrain: bool) -> void:
	# Taking a terrain set away clears its tiles by itself.
	if remove_set:
		tile_set.remove_terrain_set(_TERRAIN_SET)
		return
	var source: TileSetAtlasSource = tile_set.get_source(spec["source"])
	for entry in saved:
		var data := source.get_tile_data(entry[0], 0)
		data.terrain_set = entry[1]
		if entry[1] >= 0:
			data.terrain = entry[2]
			for neighbour in entry[3]:
				data.set_terrain_peering_bit(neighbour, entry[3][neighbour])
	if remove_terrain:
		tile_set.remove_terrain(_TERRAIN_SET, _terrain_index(tile_set, spec["name"]))
