---
name: godot-tilemap
description: Build 2D levels from tiles in Godot 4 with the gd command line - cut an atlas image into a tile set, paint and erase cells of a TileMapLayer, give tiles collision, stack layers, read a level back. Use when the user wants a tile-based level, platforms or walls made of tiles, a tile set from a tileset image, or mentions TileMap, TileMapLayer, TileSet, tiles or autotiling.
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

`--collision true` gives every tile of the atlas a square collision shape and the tile set a physics layer. That is
right for an image whose tiles are all solid ground. When only some tiles are solid, use two atlases or two layers:
solid tiles in a layer whose tile set has collision, decoration in a layer whose tile set does not.

- The tiles collide on physics layer 1 with mask 1 by default, the same as a new `CharacterBody2D`, so a character
  stands on them without further setup. `collision_enabled` on the layer turns it off for that layer.
- Slopes, one-way platforms and shapes smaller than the tile are set per tile in the tile set editor. There is no
  command for them: say so and leave it to the user, or use separate `StaticBody2D` nodes for the few special pieces.

## Layers

One `TileMapLayer` node per layer, drawn in tree order (later nodes on top), or by `z_index`:

```bash
gd command node_create --type TileMapLayer --name Decor --properties '{"z_index": 1, "collision_enabled": false}'
```

Each layer has a tile set of its own: run `tileset_add_atlas` for the second layer too, with the same image when it
uses the same tiles. A tile set made here is stored inside the scene. To use one tile set in several scenes, the
user saves it as a file in the editor; a tile set that is a file is not changed by these commands.

## What these commands do not do

- **Terrains (autotiling)**, where the engine picks edge and corner tiles as you paint: the terrain rules are set
  per tile in the tile set editor. Paint the exact tiles yourself, or ask the user to set up the terrain.
- Animated tiles, alternative tiles, custom data and navigation polygons of tiles.
- Changing a tile set that is saved as its own `.tres` file.
- Scenes as tiles (a scene collection source).

For a level that is generated, do it in the game instead: a script on the layer calls
`set_cell(Vector2i(x, y), source_id, Vector2i(column, row))` in `_ready()`, with the tile set made here.

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

- Falls through the tiles: the atlas was added without `--collision true`, or the character is on another
  collision layer.
- Tiles look cut in the wrong place: wrong `--tile-size`, or the image has margins or separation.
- Nothing visible: the cells were painted far from the camera. `tilemap_get` gives `used_rect` in cells.
