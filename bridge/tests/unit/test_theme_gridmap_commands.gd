extends "res://tests/suite.gd"
## theme_set, and the GridMap commands.

const GridmapCommands = preload("res://addons/gdcli/commands/gridmap_commands.gd")
const Registry = preload("res://addons/gdcli/core/registry.gd")
const Schema = preload("res://addons/gdcli/core/schema.gd")
const ThemeCommands = preload("res://addons/gdcli/commands/theme_commands.gd")
const FakeContext = preload("res://tests/fake_context.gd")

const THEME := "res://tests/tmp/theme_probe.tres"

var _context: RefCounted
var _registry: RefCounted
var _sets: Array = []
var _root: Node3D


func cleanup() -> void:
	if _root != null:
		_root.free()
		_root = null
	DirAccess.remove_absolute(ProjectSettings.globalize_path(THEME))


func _setup() -> void:
	_root = Node3D.new()
	_root.name = "Level"
	var gridmap := GridMap.new()
	gridmap.name = "Blocks"
	_root.add_child(gridmap)
	gridmap.owner = _root
	_context = FakeContext.new()
	_context.root = _root
	_context.path = "res://tests/fixtures/main.tscn"
	_registry = Registry.new()
	_sets = [ThemeCommands.new(_context), GridmapCommands.new(_context)]
	for command_set in _sets:
		command_set.register(_registry)


func _call(command: String, args: Dictionary) -> Dictionary:
	var descriptor: Dictionary = _registry.descriptor_of(command)
	var validated := Schema.validate(args, descriptor["params"])
	if not validated["ok"]:
		return validated
	if descriptor["risk"] == "read":
		return _registry.handler_of(command).call(validated["args"])
	return _registry.handler_of(command).call(validated["args"], {"dry_run": false, "confirm": false, "mode": "standard"})


func test_theme_set_creates_a_theme_and_adds_items() -> void:
	_setup()

	var made := _call("theme_set", {"path": THEME, "default_font_size": 20, "items": [
		{"type": "Button", "kind": "color", "name": "font_color", "value": "#ffcc00"},
		{"type": "Button", "kind": "stylebox", "name": "normal", "value": {"$new": "StyleBoxFlat", "properties": {"bg_color": "#202040", "corner_radius_top_left": 6}}},
		{"type": "Label", "kind": "font_size", "name": "font_size", "value": 24},
	]})
	var again := _call("theme_set", {"path": THEME, "items": [{"type": "Label", "kind": "color", "name": "font_color", "value": "#ffffff"}]})
	var theme := ResourceLoader.load(THEME, "", ResourceLoader.CACHE_MODE_IGNORE) as Theme

	check(made["ok"] and made["data"]["created"], "made: %s" % made)
	check(again["ok"] and not again["data"]["created"], "added to the existing file")
	equal([theme.get_color("font_color", "Button").to_html(false), theme.get_font_size("font_size", "Label"), theme.default_font_size], ["ffcc00", 24, 20], "the items")
	check(theme.get_stylebox("normal", "Button") is StyleBoxFlat and theme.has_color("font_color", "Label"), "a style box, and the item added later")


func test_theme_set_refuses_what_it_should_not_write() -> void:
	_setup()

	equal(_call("theme_set", {"path": THEME, "items": [{"type": "Button", "kind": "shade", "name": "x", "value": 1}]})["error"]["code"], "INVALID_ARGS", "an unknown kind")
	equal(_call("theme_set", {"path": THEME, "items": [{"type": "Button", "kind": "font", "name": "font", "value": {"$res": "user://f.ttf"}}]})["error"]["code"], "PATH_NOT_ALLOWED", "a font from outside the project")
	equal(_call("theme_set", {"path": "res://addons/gdcli/theme.tres", "items": []})["error"]["code"], "PATH_NOT_ALLOWED", "the bridge's own folder")
	check(not FileAccess.file_exists(THEME), "nothing written")


func test_gridmap_builds_a_library_and_places_cells() -> void:
	_setup()
	var gridmap: GridMap = _root.get_node("Blocks")

	var added := _call("gridmap_library_add", {"gridmap": "Blocks", "name": "floor", "mesh": {"$new": "BoxMesh", "properties": {"size": [2, 0.5, 2]}}})
	var item: int = added["data"]["item"]
	var placed := _call("gridmap_set_cells", {"gridmap": "Blocks", "cells": [[0, 0, 0, item]], "box": {"from": [1, 0, 0], "to": [2, 0, 1], "item": item}})
	var listed := _call("gridmap_get", {"gridmap": "Blocks"})

	check(added["ok"] and placed["ok"], "made: %s %s" % [added, placed])
	equal(placed["data"]["cells"], 5, "one cell and a 2 by 2 box")
	equal(gridmap.get_used_cells().size(), 5, "placed")
	check(gridmap.mesh_library.get_item_shapes(item).size() == 2, "the piece has a collision shape")
	equal(listed["data"]["items"], [{"item": item, "name": "floor"}], "listed")
	_context.undo.undo()
	equal(gridmap.get_used_cells().size(), 0, "undo empties them again")
	equal(_call("gridmap_set_cells", {"gridmap": "Blocks", "cells": [[0, 0, 0, 99]]})["error"]["code"], "INVALID_ARGS", "an item the library does not have")
	equal(_call("gridmap_set_cells", {"gridmap": "Blocks", "cells": [[0, 0, 0.5, item]]})["error"]["code"], "INVALID_ARGS", "not a whole cell")


func test_gridmap_set_cells_refuses_boxes_it_cannot_hold() -> void:
	_setup()
	var added := _call("gridmap_library_add", {"gridmap": "Blocks", "name": "floor", "mesh": {"$new": "BoxMesh"}})
	var item: int = added["data"]["item"]

	equal(_call("gridmap_set_cells", {"gridmap": "Blocks", "box": {"from": [-2147483648, -2147483648, -2147483648], "to": [2147483647, 2147483647, 2147483647], "item": item}})["error"]["code"], "INVALID_ARGS", "corners out of a GridMap's range")
	equal(_call("gridmap_set_cells", {"gridmap": "Blocks", "box": {"from": [0, 0, 0], "to": [1000, 1000, 0], "item": item}})["error"]["code"], "INVALID_ARGS", "more cells than at once")
	equal(_call("gridmap_set_cells", {"gridmap": "Blocks", "box": {"from": [0, 0, 0, 7], "to": [1, 1, 1], "item": item}})["error"]["code"], "INVALID_ARGS", "a corner with a fourth number")
	equal((_root.get_node("Blocks") as GridMap).get_used_cells().size(), 0, "nothing placed")


func test_theme_set_asks_before_loading_a_theme_that_names_a_script() -> void:
	_setup()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/tmp"))
	FileAccess.open(THEME, FileAccess.WRITE).store_string("[gd_resource type=\"Theme\" load_steps=2 format=3]\n\n[ext_resource type=\"Script\" path=\"res://tests/fixtures/empty_script.gd\" id=\"1\"]\n\n[resource]\nscript = ExtResource(\"1\")\n")
	_context.answer = "denied"

	var reply := _call("theme_set", {"path": THEME, "items": [{"type": "Label", "kind": "font_size", "name": "font_size", "value": 20}]})
	var final: Dictionary = reply["later"].poll() if reply.get("ok") and reply.has("later") else reply

	equal(final.get("error", {}).get("code"), "NOT_APPROVED", "the person decides first")
