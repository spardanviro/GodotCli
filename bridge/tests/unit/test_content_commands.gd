extends "res://tests/suite.gd"
## Tile maps, sprite frames, animation state machines and navigation.

const AnimationCommands = preload("res://addons/gdcli/commands/animation_commands.gd")
const AnimationTreeCommands = preload("res://addons/gdcli/commands/animation_tree_commands.gd")
const NavigationCommands = preload("res://addons/gdcli/commands/navigation_commands.gd")
const SpriteCommands = preload("res://addons/gdcli/commands/sprite_commands.gd")
const TileCommands = preload("res://addons/gdcli/commands/tile_commands.gd")
const Registry = preload("res://addons/gdcli/core/registry.gd")
const Schema = preload("res://addons/gdcli/core/schema.gd")
const FakeContext = preload("res://tests/fake_context.gd")

# 64 by 32 pixels: four columns and two rows of 16 pixel tiles.
const ATLAS := "res://tests/fixtures/tiles.png"

var _root: Node2D
var _context: RefCounted
var _registry: RefCounted
var _command_sets: Array = []


func cleanup() -> void:
	if _root != null:
		_root.free()
		_root = null


# Level (Node2D)
# ├─ Ground (TileMapLayer)
# ├─ Hero (AnimatedSprite2D)
# ├─ Anim (AnimationPlayer) with "idle" and "run"
# ├─ Tree (AnimationTree)
# └─ Nav (NavigationRegion2D)
func _scene() -> void:
	_root = Node2D.new()
	_root.name = "Level"
	for node in [TileMapLayer.new(), AnimatedSprite2D.new(), AnimationPlayer.new(), AnimationTree.new(), NavigationRegion2D.new()]:
		_root.add_child(node)
	for index in _root.get_child_count():
		_root.get_child(index).name = ["Ground", "Hero", "Anim", "Tree", "Nav"][index]
	var library := AnimationLibrary.new()
	library.add_animation("idle", Animation.new())
	library.add_animation("run", Animation.new())
	_root.get_node("Anim").add_animation_library("", library)
	_context = FakeContext.new()
	_context.root = _root
	_registry = Registry.new()
	_command_sets = [
		TileCommands.new(_context), SpriteCommands.new(_context), AnimationTreeCommands.new(_context),
		NavigationCommands.new(_context), AnimationCommands.new(_context),
	]
	for command_set in _command_sets:
		command_set.register(_registry)


func _run(command: String, args: Dictionary, dry_run: bool = false) -> Dictionary:
	var descriptor: Dictionary = _registry.descriptor_of(command)
	var validated := Schema.validate(args, descriptor["params"])
	if not validated["ok"]:
		return validated
	var options := {"dry_run": dry_run, "confirm": false, "mode": "standard"}
	if descriptor["risk"] == "read":
		return _registry.handler_of(command).call(validated["args"])
	return _registry.handler_of(command).call(validated["args"], options)


func _code(command: String, args: Dictionary) -> String:
	var reply := _run(command, args)
	return "ok" if reply["ok"] else reply["error"]["code"]


func test_tileset_add_atlas_cuts_the_image_into_tiles() -> void:
	_scene()
	var ground: TileMapLayer = _root.get_node("Ground")

	var planned := _run("tileset_add_atlas", {"layer": "Ground", "texture": ATLAS}, true)
	var before := ground.tile_set
	var reply := _run("tileset_add_atlas", {"layer": "Ground", "texture": ATLAS})
	var source: TileSetAtlasSource = ground.tile_set.get_source(reply["data"]["source"])

	check(planned["data"]["dry_run"] and before == null, "a dry run adds nothing")
	equal([reply["data"]["columns"], reply["data"]["rows"], reply["data"]["tiles"]], [4, 2, 8], "the grid the image holds at 16 pixels")
	equal(ground.tile_set.tile_size, Vector2i(16, 16), "a new tile set takes the tile size")
	check(source.has_tile(Vector2i(3, 1)) and not source.has_tile(Vector2i(4, 0)), "every cell of the image is a tile")
	equal(reply["undo"], "gdcli: tileset_add_atlas Ground", "one undo step")

	_context.undo.undo()
	check(ground.tile_set == null, "undo takes the tile set away again")


func test_tileset_add_atlas_gives_tiles_a_collision_shape_when_asked() -> void:
	_scene()
	var ground: TileMapLayer = _root.get_node("Ground")

	var reply := _run("tileset_add_atlas", {"layer": "Ground", "texture": ATLAS, "tile_size": [32, 32], "collision": true})
	var tile_set := ground.tile_set
	var data: TileData = tile_set.get_source(reply["data"]["source"]).get_tile_data(Vector2i(1, 0), 0)
	var second := _run("tileset_add_atlas", {"layer": "Ground", "texture": ATLAS, "tile_size": [32, 32]})

	equal([reply["data"]["columns"], reply["data"]["rows"]], [2, 1], "larger tiles, fewer of them")
	equal(tile_set.get_physics_layers_count(), 1, "the tile set got a physics layer")
	equal(data.get_collision_polygon_points(0, 0), PackedVector2Array([Vector2(-16, -16), Vector2(16, -16), Vector2(16, 16), Vector2(-16, 16)]), "a square around the tile's centre")
	check(second["data"]["source"] != reply["data"]["source"] and ground.tile_set == tile_set, "a second atlas joins the same tile set under another id")

	_context.undo.undo()
	_context.undo.undo()
	check(ground.tile_set == null, "both steps undone")
	equal(tile_set.get_physics_layers_count(), 0, "and the physics layer with them")


func test_tileset_add_atlas_is_redone_and_respects_what_the_tile_set_has() -> void:
	_scene()
	var ground: TileMapLayer = _root.get_node("Ground")
	_run("tileset_add_atlas", {"layer": "Ground", "texture": ATLAS, "collision": true})
	var tile_set := ground.tile_set

	_context.undo.undo()
	_context.undo.redo()
	var data: TileData = tile_set.get_source(0).get_tile_data(Vector2i(0, 0), 0)

	check(ground.tile_set == tile_set and tile_set.has_source(0), "redo brings the tile set and its source back")
	equal([tile_set.get_physics_layers_count(), data.get_collision_polygons_count(0)], [1, 1], "with one physics layer and one shape per tile, not two")

	var other_size := _run("tileset_add_atlas", {"layer": "Ground", "texture": ATLAS, "tile_size": [32, 32], "collision": true})
	_context.undo.undo()
	equal(other_size["warnings"].size(), 1, "tiles cut at another size than the tile set's come with a warning")
	equal(tile_set.get_physics_layers_count(), 1, "undoing a later atlas leaves the physics layer that was there before it")


func test_tileset_add_atlas_leaves_a_tile_set_file_alone() -> void:
	_scene()
	var shared := TileSet.new()
	shared.take_over_path("res://tests/tmp/shared_tiles.tres")
	_root.get_node("Ground").tile_set = shared

	equal(_code("tileset_add_atlas", {"layer": "Ground", "texture": ATLAS}), "PRECONDITION_FAILED", "a tile set that is a file of its own")
	equal(shared.get_source_count(), 0, "is not changed")
	shared.take_over_path("")


func test_tileset_add_atlas_refuses_what_it_cannot_cut() -> void:
	_scene()

	equal(_code("tileset_add_atlas", {"layer": "Hero", "texture": ATLAS}), "TYPE_MISMATCH", "a node that is not a tile map layer")
	equal(_code("tileset_add_atlas", {"layer": "Nope", "texture": ATLAS}), "NODE_NOT_FOUND", "a node that does not exist")
	equal(_code("tileset_add_atlas", {"layer": "Ground", "texture": "res://tests/fixtures/none.png"}), "RESOURCE_NOT_FOUND", "an image that does not exist")
	equal(_code("tileset_add_atlas", {"layer": "Ground", "texture": "res://tests/fixtures/empty_script.gd"}), "INVALID_ARGS", "a file that is not an image is not even loaded")
	equal(_code("tileset_add_atlas", {"layer": "Ground", "texture": "res://tests/fixtures/main.tscn"}), "INVALID_ARGS", "nor a resource file, which could bring a script along")
	equal(_code("tileset_add_atlas", {"layer": "Ground", "texture": "res://../outside.png"}), "PATH_NOT_ALLOWED", "a path outside the project")
	equal(_code("tileset_add_atlas", {"layer": "Ground", "texture": ATLAS, "tile_size": [128, 128]}), "INVALID_ARGS", "tiles larger than the image")
	equal(_code("tileset_add_atlas", {"layer": "Ground", "texture": ATLAS, "tile_size": [0, 16]}), "INVALID_ARGS", "a tile without width")
	equal(_code("tileset_add_atlas", {"layer": "Ground", "texture": ATLAS, "tile_size": [16.5, 16]}), "INVALID_ARGS", "half a pixel")
	check(_root.get_node("Ground").tile_set == null, "nothing was added by any of these")


func test_tilemap_set_cells_paints_erases_and_undoes() -> void:
	_scene()
	var ground: TileMapLayer = _root.get_node("Ground")
	_run("tileset_add_atlas", {"layer": "Ground", "texture": ATLAS})

	var floor_row := _run("tilemap_set_cells", {"layer": "Ground", "rect": [0, 5, 10, 1], "atlas": [1, 0]})
	var extra := _run("tilemap_set_cells", {"layer": "Ground", "cells": [[2, 4], [3, 4], [2, 4]], "atlas": [2, 1]})
	var listed := _run("tilemap_get", {"layer": "Ground", "rect": [2, 4, 2, 2]})
	var erased := _run("tilemap_set_cells", {"layer": "Ground", "rect": [0, 5, 3, 1], "erase": true})

	equal([floor_row["data"]["cells"], floor_row["data"]["used_rect"]], [10, [0, 5, 10, 1]], "a rectangle of cells")
	equal(extra["data"]["cells"], 2, "a cell named twice counts once")
	equal(ground.get_cell_atlas_coords(Vector2i(3, 4)), Vector2i(2, 1), "painted with the tile asked for")
	equal(listed["data"]["cell_count"], 4, "tilemap_get counts the cells inside a rectangle")
	check({"x": 2, "y": 5, "source": 0, "atlas": [1, 0]} in listed["data"]["cells"], "and lists them with their tile")
	equal([listed["data"]["sources"][0]["columns"], listed["data"]["sources"][0]["texture"]], [4, ATLAS], "and the sources of the tile set")
	equal([erased["ok"], ground.get_cell_source_id(Vector2i(1, 5)), ground.get_used_cells().size()], [true, -1, 9], "erased cells are empty")

	_context.undo.undo()
	equal(ground.get_cell_atlas_coords(Vector2i(1, 5)), Vector2i(1, 0), "undo puts back what was there")
	_context.undo.undo()
	_context.undo.undo()
	equal(ground.get_used_cells().size(), 0, "down to the empty layer")


func test_tilemap_set_cells_refuses_tiles_that_do_not_exist() -> void:
	_scene()

	equal(_code("tilemap_set_cells", {"layer": "Ground", "cells": [[0, 0]]}), "PRECONDITION_FAILED", "a layer without a tile set")
	_run("tileset_add_atlas", {"layer": "Ground", "texture": ATLAS})
	equal(_code("tilemap_set_cells", {"layer": "Ground", "cells": [[0, 0]], "source": 7}), "INVALID_ARGS", "a source the tile set does not have")
	equal(_code("tilemap_set_cells", {"layer": "Ground", "cells": [[0, 0]], "atlas": [9, 9]}), "INVALID_ARGS", "a tile outside the atlas")
	equal(_code("tilemap_set_cells", {"layer": "Ground"}), "INVALID_ARGS", "no cells at all")
	equal(_code("tilemap_set_cells", {"layer": "Ground", "cells": [[0.5, 0]]}), "INVALID_ARGS", "half a cell")
	equal(_code("tilemap_set_cells", {"layer": "Ground", "rect": [0, 0, 1000, 1000]}), "INVALID_ARGS", "more cells than one call takes")
	equal(_code("tilemap_set_cells", {"layer": "Ground", "rect": [0, 0, 4294967296.0, 4294967296.0]}), "INVALID_ARGS", "sides whose product wraps around to nothing")
	equal(_code("tilemap_get", {"layer": "Ground", "rect": [0, 0, 1.0e300, 1]}), "INVALID_ARGS", "a number no map reaches")
	equal(_run("tilemap_set_cells", {"layer": "Ground", "cells": [[0, 0]]}, true)["data"]["dry_run"], true, "a dry run")
	equal(_root.get_node("Ground").get_used_cells().size(), 0, "nothing was painted by any of these")


func test_sprite_frames_create_cuts_sheets_and_takes_single_images() -> void:
	_scene()
	var hero: AnimatedSprite2D = _root.get_node("Hero")

	var reply := _run("sprite_frames_create", {
		"node": "Hero", "autoplay": "walk",
		"animations": [
			{"name": "walk", "sheet": ATLAS, "hframes": 4, "vframes": 2, "frames": [4, 5, 6, 7], "fps": 12},
			{"name": "idle", "files": [ATLAS], "loop": false},
		],
	})
	var frames := hero.sprite_frames
	var third: AtlasTexture = frames.get_frame_texture("walk", 2)

	equal(reply["data"]["animations"], [
		{"name": "idle", "frames": 1, "fps": 10.0, "loop": false}, {"name": "walk", "frames": 4, "fps": 12.0, "loop": true},
	], "the animations, without the empty default one")
	equal(third.region, Rect2(32, 16, 16, 16), "a frame is its cell of the sheet, counted row by row")
	equal([str(hero.animation), hero.autoplay], ["walk", "walk"], "shown in the editor and played at the start")

	var more := _run("sprite_frames_create", {"node": "Hero", "animations": [{"name": "walk", "sheet": ATLAS, "hframes": 2}]})
	equal([more["ok"], hero.sprite_frames.get_frame_count("walk"), hero.sprite_frames.has_animation("idle")], [true, 2, true], "an animation of the same name is replaced, the others stay")
	equal(frames.get_frame_count("walk"), 4, "in a copy: the earlier resource is what undo returns to")
	_context.undo.undo()
	equal(hero.sprite_frames, frames, "undo")
	_context.undo.undo()
	check(hero.sprite_frames == null, "and again")


func test_sprite_frames_create_replaces_everything_when_asked() -> void:
	_scene()
	var hero: AnimatedSprite2D = _root.get_node("Hero")
	_run("sprite_frames_create", {"node": "Hero", "autoplay": "idle", "animations": [{"name": "idle", "sheet": ATLAS}, {"name": "run", "sheet": ATLAS, "hframes": 4}]})

	var reply := _run("sprite_frames_create", {"node": "Hero", "replace": true, "animations": [{"name": "walk", "sheet": ATLAS, "hframes": 2}]})

	equal(reply["data"]["animations"], [{"name": "walk", "frames": 2, "fps": 10.0, "loop": true}], "only the new animation is left")
	equal(hero.autoplay, "", "and autoplay no longer names one that is gone")
	_context.undo.undo()
	equal([hero.autoplay, hero.sprite_frames.has_animation("run")], ["idle", true], "undo brings both back")
	_context.undo.redo()
	equal([hero.autoplay, hero.sprite_frames.get_animation_names()], ["", PackedStringArray(["walk"])], "and redo takes them away again")


func test_sprite_frames_create_refuses_bad_input() -> void:
	_scene()

	equal(_code("sprite_frames_create", {"node": "Ground", "animations": [{"name": "a", "sheet": ATLAS}]}), "TYPE_MISMATCH", "a node that is not an animated sprite")
	equal(_code("sprite_frames_create", {"node": "Hero", "animations": []}), "INVALID_ARGS", "no animations")
	equal(_code("sprite_frames_create", {"node": "Hero", "animations": [{"name": "a"}]}), "INVALID_ARGS", "neither sheet nor files")
	equal(_code("sprite_frames_create", {"node": "Hero", "animations": [{"name": "a", "sheet": ATLAS, "hframes": 4, "frames": [4]}]}), "INVALID_ARGS", "a frame outside the sheet")
	equal(_code("sprite_frames_create", {"node": "Hero", "animations": [{"name": "a", "sheet": "res://nope.png"}]}), "RESOURCE_NOT_FOUND", "a sheet that does not exist")
	equal(_code("sprite_frames_create", {"node": "Hero", "animations": [{"name": "a", "sheet": ATLAS, "fps": 0}]}), "INVALID_ARGS", "no speed")
	equal(_code("sprite_frames_create", {"node": "Hero", "animations": [{"name": "a", "sheet": ATLAS}], "autoplay": "b"}), "INVALID_ARGS", "autoplay of an animation that is not there")
	check(_root.get_node("Hero").sprite_frames == null, "nothing was set by any of these")


func test_animation_state_machine_create_builds_states_and_transitions() -> void:
	_scene()
	var tree: AnimationTree = _root.get_node("Tree")

	var reply := _run("animation_state_machine_create", {
		"tree": "Tree", "player": "Anim",
		"states": [{"name": "Idle", "animation": "idle"}, {"name": "Run", "animation": "run"}],
		"transitions": [
			{"from": "Idle", "to": "Run", "condition": "moving", "xfade": 0.1},
			{"from": "Run", "to": "Idle", "expression": "velocity.length() < 1.0"},
		],
	})
	var machine: AnimationNodeStateMachine = tree.tree_root
	var to_run: AnimationNodeStateMachineTransition = machine.get_transition(1) if machine.get_transition_from(1) == &"Idle" else machine.get_transition(0)

	equal(reply["data"]["states"], ["Idle", "Run"], "the states")
	equal(reply["data"]["parameters"], ["parameters/playback", "parameters/conditions/moving"], "what code sets to drive it")
	equal(str(machine.get_node("Run").animation), "run", "a state plays its animation")
	check(machine.has_transition("Start", "Idle") and machine.has_transition("Idle", "Run") and machine.has_transition("Run", "Idle"), "transitions, and an entry into the first state")
	equal([str(to_run.advance_condition), to_run.advance_mode], ["moving", AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO], "a transition with a condition takes itself")
	check(is_equal_approx(to_run.xfade_time, 0.1), "with its cross-fade")
	equal([tree.anim_player, tree.active, reply["data"]["active"]], [NodePath("../Anim"), false, false], "the tree points at the player; with an expression it stays inactive in the editor")
	equal(reply["warnings"].size(), 1, "and says so")

	_context.undo.undo()
	check(tree.tree_root == null, "undo")
	var plain := _run("animation_state_machine_create", {
		"tree": "Tree", "player": "Anim", "states": [{"name": "Idle", "animation": "idle"}, {"name": "Run", "animation": "run"}],
		"transitions": [{"from": "Idle", "to": "Run", "condition": "moving"}], "start": "Run",
	})
	equal([tree.active, plain["data"]["active"]], [true, true], "without expressions the tree is made active")
	check(tree.tree_root.has_transition("Start", "Run"), "and starts where it was told to")


func test_animation_state_machine_create_refuses_bad_input() -> void:
	_scene()
	var states := [{"name": "Idle", "animation": "idle"}, {"name": "Run", "animation": "run"}]

	equal(_code("animation_state_machine_create", {"tree": "Anim", "player": "Anim", "states": states}), "TYPE_MISMATCH", "a node that is not an animation tree")
	equal(_code("animation_state_machine_create", {"tree": "Tree", "states": states}), "INVALID_ARGS", "no player given and none set")
	equal(_code("animation_state_machine_create", {"tree": "Tree", "player": "Anim", "states": [{"name": "Fly", "animation": "fly"}]}), "INVALID_ARGS", "an animation the player lacks")
	equal(_code("animation_state_machine_create", {"tree": "Tree", "player": "Anim", "states": [{"name": "Start", "animation": "idle"}]}), "INVALID_ARGS", "a reserved state name")
	equal(_code("animation_state_machine_create", {"tree": "Tree", "player": "Anim", "states": states, "start": "Jump"}), "INVALID_ARGS", "a start that is no state")
	equal(_code("animation_state_machine_create", {"tree": "Tree", "player": "Anim", "states": states, "start": 3}), "INVALID_ARGS", "a start that is not a name")
	equal(_code("animation_state_machine_create", {"tree": "Tree", "player": "Anim", "states": states, "transitions": [{"from": "Idle", "to": "Fly"}]}), "INVALID_ARGS", "a transition to nowhere")
	equal(_code("animation_state_machine_create", {"tree": "Tree", "player": "Anim", "states": states, "transitions": [{"from": "Idle", "to": "Run", "switch": "later"}]}), "INVALID_ARGS", "an unknown switch mode")
	check(_root.get_node("Tree").tree_root == null, "nothing was set by any of these")


func test_animation_create_adds_method_call_tracks() -> void:
	_scene()
	var player: AnimationPlayer = _root.get_node("Anim")

	var reply := _run("animation_create", {
		"player": "Anim", "name": "die", "length": 1.0,
		"tracks": [
			{"node": "Hero", "property": "modulate", "keys": [{"time": 0, "value": "#ffffff"}, {"time": 1, "value": "#ffffff00"}]},
			{"node": "Hero", "method": "queue_free", "keys": [{"time": 1}]},
			{"node": "Hero", "method": "set_frame_and_progress", "keys": [{"time": 0.5, "args": [2, 0.0]}]},
		],
	})
	var animation: Animation = player.get_animation("die")
	var bad := func(track: Dictionary) -> String:
		return _code("animation_create", {"player": "Anim", "name": "x", "length": 1.0, "tracks": [track]})

	equal(reply["data"]["tracks"], ["Hero:modulate", "Hero:queue_free()", "Hero:set_frame_and_progress()"], "property and method tracks side by side")
	equal(animation.track_get_type(1), Animation.TYPE_METHOD, "a method track")
	equal([animation.method_track_get_name(2, 0), animation.method_track_get_params(2, 0)], [&"set_frame_and_progress", [2, 0.0]], "with its arguments")
	for indirect in ["set_script", "call", "call_thread_safe", "propagate_call", "emit_signal"]:
		equal(bad.call({"node": "Hero", "method": indirect, "keys": [{"time": 0, "args": ["queue_free"]}]}), "INVALID_ARGS", "%s does something else than it says" % indirect)
	equal(bad.call({"node": "Hero", "method": "queue_free", "property": "modulate", "keys": [{"time": 0}]}), "INVALID_ARGS", "both a property and a method")
	equal(bad.call({"node": "Hero", "method": "queue_free", "keys": [{"time": 0, "args": 3}]}), "INVALID_ARGS", "arguments that are not a list")
	equal(bad.call({"node": "Hero", "method": "queue_free", "keys": [{"time": 2}]}), "INVALID_ARGS", "a key after the end")


func test_navigation_bake_checks_what_it_is_given() -> void:
	_scene()
	var nav: NavigationRegion2D = _root.get_node("Nav")

	equal(_code("navigation_bake", {"region": "Hero"}), "TYPE_MISMATCH", "a node that is not a navigation region")
	equal(_code("navigation_bake", {"region": "Nav"}), "PRECONDITION_FAILED", "a 2D region without an outline")
	equal(_code("navigation_bake", {"region": "Nav", "outline": [[0, 0], [10, 0]]}), "INVALID_ARGS", "an outline of two points")
	equal(_code("navigation_bake", {"region": "Nav", "outline": [[0, 0], [10, 0], "x"]}), "INVALID_ARGS", "a point that is not one")
	equal(_run("navigation_bake", {"region": "Nav", "outline": [[0, 0], [100, 0], [100, 100], [0, 100]]}, true)["data"]["dry_run"], true, "a dry run")
	check(nav.navigation_polygon == null, "nothing was changed by any of these")


func test_navigation_bake_leaves_a_navigation_file_alone_and_bakes_into_a_copy() -> void:
	_scene()
	var nav: NavigationRegion2D = _root.get_node("Nav")
	var shared := NavigationPolygon.new()
	shared.take_over_path("res://tests/tmp/shared_nav.tres")
	nav.navigation_polygon = shared
	var square := [[0, 0], [100, 0], [100, 100], [0, 100]]

	equal(_code("navigation_bake", {"region": "Nav", "outline": square}), "PRECONDITION_FAILED", "navigation data that is a file of its own")
	equal(shared.get_outline_count(), 0, "is not changed")
	shared.take_over_path("")

	var own := NavigationPolygon.new()
	nav.navigation_polygon = own
	var reply := _run("navigation_bake", {"region": "Nav", "outline": square})
	equal([reply["ok"], reply["undo"]], [true, "gdcli: navigation_bake Nav"], "baked, as one undo step")
	check(nav.navigation_polygon != own and own.get_outline_count() == 0, "into a copy: the earlier polygon is untouched")
	equal(nav.navigation_polygon.get_outline(0).size(), 4, "which has the outline")
	_context.undo.undo()
	check(nav.navigation_polygon == own, "and undo puts the earlier one back")
