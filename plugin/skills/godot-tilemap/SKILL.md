---
name: godot-tilemap
description: Build 2D levels from tiles in Godot 4 with the gd command line - cut an atlas image into a tile set, paint and erase cells of a TileMapLayer, give tiles collision (solid, slopes, one-way platforms), set up terrains so tiles pick themselves (autotiling), stack layers, read a level back. Use when the user wants a tile-based level, platforms or walls made of tiles, a tile set from a tileset image, or mentions TileMap, TileMapLayer, TileSet, tiles, terrain or autotiling.
---

# Tile map levels

A level made of tiles is one or more `TileMapLayer` nodes that share the look of a `TileSet`. The commands here
build both; they are run with `gd command ...` (see the `godot-cli` skill). Every change is a step on the editor's
undo stack. `TileMap`, the node with several layers inside, is deprecated since Godot 4.3: use one `TileMapLayer` per layer.

## From an image to a level

```bash
gd command fs_list --path res:// --pattern "*.png" --recursive true     # find the tile image
gd command node_create --type TileMapLayer --name Ground
gd command tileset_add_atlas --layer Ground --texture res://art/tiles.png --tile-size '[16, 16]' --collision true
gd command tilemap_set_cells --layer Ground --rect '[0, 10, 40, 2]' --atlas '[1, 0]'
gd command tilemap_set_cells --layer Ground --cells '[[12, 9], [13, 9], [13, 8]]' --atlas '[2, 0]'
gd command tilemap_set_cells --layer Ground --rect '[20, 10, 3, 2]' --erase true
gd command tilemap_get --layer Ground
gd command scene_save
```

- `tileset_add_atlas` cuts the whole image into a grid of tiles and adds them as one source of the layer's tile
  set, making the tile set if the layer has none. It answers with the `source` id and the number of `columns` and
  `rows`. Know the tile size before you call it: ask the user or look at the image; a wrong size cuts tiles in half.
  `--margins` and `--separation` are for images with a border around or gaps between the tiles.
- A tile is named by its place in the image: `--atlas '[column, row]'`, counted from 0 at the top left.
  You cannot see the image from the command line. If you do not know which tile is grass and which is stone, ask,
  or look at the picture yourself when you can read image files.
- Cells are map coordinates: `[x, y]` in tiles, y growing downward. `--rect '[x, y, width, height]'` fills a
  rectangle; `--cells` takes single cells; both may be given. One call paints one tile: a level with five kinds of
  tile is five or more calls.
- `--erase true` clears cells. `tilemap_get` lists the sources and the painted cells (`--rect` to look at a part).
- A new image has to be imported before it can be used: `gd command fs_scan` after copying it in.

## Collision

`--collision true` on `tileset_add_atlas` gives every tile of the atlas a square collision shape and the tile set a
physics layer. That is right for an image whose tiles are all solid ground. `tileset_set_collision` then shapes
single tiles, or all of them:

```bash
gd command tileset_set_collision --layer Ground --tiles '[[3, 0]]' --shape slope_right
gd command tileset_set_collision --layer Ground --tiles '[[4, 0]]' --shape slope_left
gd command tileset_set_collision --layer Ground --tiles '[[5, 0]]' --polygon '[[0, 0], [1, 0], [1, 0.25], [0, 0.25]]' --one-way true
gd command tileset_set_collision --layer Ground --tiles '[[6, 0], [7, 0]]' --shape none
```

- Shapes: `full`, `none`, `half_bottom`, `half_top`, `half_left`, `half_right`, `slope_right` (rises towards the
  right, high side on the right), `slope_left`. Without `--tiles`, every tile of the source gets the shape.
- `--polygon` is a shape of your own: the corner points of a convex outline, with `[0, 0]` the top left of the
  tile and `[1, 1]` its bottom right. It is used instead of `--shape`.
- `--one-way true` makes the shape solid from above only: a platform a character can jump up through. Give a
  one-way platform a thin shape at the top of the tile, as above.
- The command replaces the shapes those tiles had. Decoration tiles that should not collide get `--shape none`, or
  go in a layer of their own with `collision_enabled` false.
- The tiles collide on physics layer 1 with mask 1 by default, the same as a new `CharacterBody2D`, so a character
  stands on them without further setup.
- A character climbs slopes with `move_and_slide()` as it is. `floor_max_angle` on the body is in radians and
  defaults to 45 degrees: for steeper slopes set it in a script (`floor_max_angle = deg_to_rad(60)`). Set
  `floor_snap_length` to 8 or so, so that it does not hop when running downhill.

## Terrains: tiles that pick themselves

With a terrain, you paint an area and the engine chooses, for every cell, the tile whose edges fit the neighbours:
corners at the corners, edges along the edges. The common tile image has, for each kind of ground, a 3 by 3 block
drawn as one piece: four corners, four edges, a centre.

```bash
gd command tileset_set_terrain --layer Ground --terrain grass --block '[0, 0]'
gd command tilemap_set_cells --layer Ground --rect '[0, 10, 12, 4]' --terrain grass
gd command tilemap_set_cells --layer Ground --cells '[[12, 12], [13, 12], [13, 11]]' --terrain grass
```

- `--block '[column, row]'` names the top left tile of such a 3 by 3 block; its nine tiles get the right
  neighbours. You need to know where the block is in the image: ask, or look at it.
- Painting with `--terrain` re-picks the tiles next to the painted cells too, so areas painted in several calls
  join up. A block has tiles for outer corners and straight edges: rectangles come out exactly. Where two areas
  meet at an inner corner, or for a strip one tile thick, there is no exact tile in a 3 by 3 block and the engine
  takes the closest one. Look at the result (`tilemap_get`, or a screenshot) before calling it done.
- Tiles that are not in such a block are set one by one with `--tiles`:
  `'[{"atlas": [4, 0], "connects": ["right", "bottom"]}]'`, where `connects` lists the directions in which the
  same terrain continues from that tile.
- `--mode` is `sides` (default), `corners` or `corners_and_sides`: what the engine compares. `corners_and_sides` is
  for the large 47-tile sets that have inner corners; it needs every one of those tiles set with `--tiles`. The
  mode is fixed when the first terrain is made.
- A second kind of ground is a second terrain: another `tileset_set_terrain` with another name and block.
- Collision is separate: `tileset_add_atlas --collision true` or `tileset_set_collision` as above.

## Layers

One `TileMapLayer` node per layer, drawn in tree order (later nodes on top), or by `z_index`:

```bash
gd command node_create --type TileMapLayer --name Decor --properties '{"z_index": 1, "collision_enabled": false}'
```

Each layer has a tile set of its own: run `tileset_add_atlas` for the second layer too, with the same image when it
uses the same tiles. A tile set made here is stored inside the scene. To use one tile set in several scenes, the
user saves it as a file in the editor; a tile set that is a file is not changed by these commands.

## What these commands do not do

- Animated tiles, alternative tiles, custom data and navigation polygons of tiles: the tile set editor, by the user.
- Changing a tile set that is saved as its own `.tres` file.
- Scenes as tiles (a scene collection source).

For a level that is generated, do it in the game instead: a script on the layer calls
`set_cell(Vector2i(x, y), source_id, Vector2i(column, row))` in `_ready()`, or
`set_cells_terrain_connect(cells, 0, terrain_index)` to use a terrain, with the tile set made here.

## From code

```gdscript
@onready var ground: TileMapLayer = $Ground

func tile_under(world_position: Vector2) -> Vector2i:
	return ground.local_to_map(ground.to_local(world_position))

func is_solid(cell: Vector2i) -> bool:
	return ground.get_cell_source_id(cell) != -1

func dig(cell: Vector2i) -> void:
	ground.erase_cell(cell)
```

`map_to_local(cell)` gives the centre of a cell in the layer's coordinates. `get_used_rect()` is the size of the
level in cells; multiply by the tile size for camera limits.

## Pixel art

Tiles drawn as pixel art look blurred and show seams unless the project filters textures as nearest. That, and the
other project settings for pixel art, are in the `godot-sprite-animation` skill.

## Checking it

```bash
gd command scene_save
gd run --seconds 3 --headless
gd command editor_play
gd command game_call --path Level/Player --method is_on_floor       # true once it has landed on the tiles
gd command game_screenshot                                           # what it looks like; needs a window
```

- Falls through the tiles: the atlas was added without `--collision true` (give them shapes with
  `tileset_set_collision`), or the character is on another collision layer.
- Tiles look cut in the wrong place: wrong `--tile-size`, or the image has margins or separation.
- Nothing visible: the cells were painted far from the camera. `tilemap_get` gives `used_rect` in cells.
