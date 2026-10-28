---
name: godot-migrate-3-to-4
description: Move a Godot 3 project, or code from a Godot 3 tutorial, to Godot 4 - the editor's converter (--convert-3to4) and what it leaves undone, the renames that break most scripts (KinematicBody2D, move_and_slide, onready, export, yield, connect, setget, instance, Tween, File), scenes and resources, tile maps, shaders, networking, C#, and how to check the result with the gd command line. Use when the user has a Godot 3 project to upgrade, code that uses Godot 3 names, errors like "Identifier not declared" for KinematicBody2D or yield, or asks how to port or update to Godot 4.
---

# From Godot 3 to Godot 4

Godot 4 changed names, the scene file format, physics bodies, signals, tweens, tile maps and the rendering
backends. A Godot 3 project does not open in Godot 4 without converting, and code from Godot 3 tutorials does not
compile in it. gdcli works with Godot 4 only (4.3 and later), so a Godot 3 project is converted first, then the
bridge is installed into the result.

## Converting a project

The converter rewrites the project's files **in place**. Before anything else:

1. Ask the user, and make sure the project is committed to version control or copied: there is no undo.
2. Convert a copy, not the original, when the user is unsure.

Then either the person opens the project in the Godot 4 Project Manager (it offers to convert), or it is run from
the command line with the user's agreement:

```bash
godot --headless --path /path/to/copy --convert-3to4      # rewrites scripts, scenes and project.godot
godot --headless --path /path/to/copy --validate-conversion-3to4   # only reports what it would change
```

After it:

```bash
gd bridge install --project /path/to/copy     # the bridge, for gd command and the game commands
gd import --project /path/to/copy             # imports the resources for Godot 4
gd check res://scripts/player.gd ...          # every script: what the converter missed shows here
gd run --seconds 5 --headless                 # the errors the game prints
```

The converter renames classes, methods and properties and moves annotations, but it does not understand code:
logic that changed meaning (`move_and_slide`, `yield`, tweens, file access) still has to be rewritten, and it
leaves lines it could not convert as they were. Work through `gd check` errors file by file.

## The renames that break most scripts

| Godot 3 | Godot 4 |
|---|---|
| `KinematicBody2D` / `KinematicBody` | `CharacterBody2D` / `CharacterBody3D` |
| `Spatial`, `MeshInstance`, `Camera` | `Node3D`, `MeshInstance3D`, `Camera3D` (3D classes gained `3D`) |
| `velocity = move_and_slide(velocity, Vector2.UP)` | set the built-in `velocity`, then `move_and_slide()`; `up_direction` is a property |
| `onready var x = $X` | `@onready var x = $X` |
| `export var speed = 100` / `export(int) var` | `@export var speed := 100` |
| `tool` | `@tool` |
| `yield(get_tree().create_timer(1), "timeout")` | `await get_tree().create_timer(1).timeout` |
| `connect("pressed", self, "_on_pressed")` | `pressed.connect(_on_pressed)` |
| `emit_signal("hit", 5)` | `hit.emit(5)` (the old form still works) |
| `var hp setget set_hp` | `var hp: int:` with `set(value):` and `get:` blocks |
| `scene.instance()` | `scene.instantiate()` |
| `$Tween.interpolate_property(...)` and a Tween node | `create_tween().tween_property(node, "position", target, 0.5)` |
| `File.new()`, `file.open(path, File.READ)` | `FileAccess.open(path, FileAccess.READ)` |
| `Directory.new()` | `DirAccess.open(path)` |
| `rand_range(a, b)`, `deg2rad`, `stepify` | `randf_range(a, b)`, `deg_to_rad`, `snapped` |
| `PoolStringArray`, `PoolVector2Array` | `PackedStringArray`, `PackedVector2Array` |
| `OS.window_size`, `OS.set_window_title` | `get_window().size`, `get_window().title` |
| `is_network_master()`, `remote`, `puppet`, `rset` | `is_multiplayer_authority()`, `@rpc` (the `godot-multiplayer` skill) |
| `funcref(obj, "m")` | `Callable(obj, "m")` or just `obj.m` |
| `get_tree().change_scene("res://x.tscn")` | `get_tree().change_scene_to_file("res://x.tscn")` |
| `.translation` of a 3D node | `.position` |
| `rect_position`, `rect_size`, `rect_min_size` | `position`, `size`, `custom_minimum_size` |

When unsure of a name, ask the installed engine: `gd api search <part of the name>` and `gd api class <Name>`.

## Things that changed shape, not just name

- **Physics bodies**: `CharacterBody2D` keeps its own `velocity`; `move_and_slide()` takes no arguments and uses
  `up_direction`, `floor_max_angle` and friends as properties. `is_on_floor()` works after `move_and_slide()`.
- **Signals with arguments**: `connect` with extra binds becomes `signal.connect(method.bind(arg))`.
- **Typed code is stricter**: Godot 4 refuses some implicit conversions Godot 3 allowed; `gd check` points to them.
- **Tile maps**: Godot 4's TileSet is a different resource. The converter keeps cells but tile sets often need
  setting up again (collision, terrains instead of autotiles); the `godot-tilemap` skill does that with gd. Since
  4.3 each layer is its own TileMapLayer node.
- **Shaders**: `hint_color` became `source_color`, `SCREEN_TEXTURE` a uniform with `hint_screen_texture`; the full
  table is in the `godot-shaders` skill.
- **Rendering**: GLES2 and GLES3 became the Compatibility renderer, and Forward+ is the new default. Lights,
  environment and materials look different; check the main scenes and adjust (the `godot-3d-rendering` skill).
- **Input map and project settings** are converted, but some setting paths moved; `gd command project_settings_get`
  reads the converted values.
- **Autoloads** keep working; their scripts need the same fixes as any other.
- **C#**: Godot 4 uses .NET 6 or later and a new project file; method names follow C# style (`_Ready`, `GetNode`)
  and signals are events. Convert C# by hand, file by file, building with the .NET editor.

## Porting code from a Godot 3 tutorial

Translate it with the table above before writing it into the project, then `gd check` the script. A tutorial that
uses `KinematicBody2D`, `yield`, `export var` or `setget` is a Godot 3 tutorial even when it does not say so; the
manual has the Godot 4 way (`gd docs search <topic>`).

## Order of work for a converted project

1. Convert, install the bridge, import (above).
2. `gd check` every script and fix the errors, starting with autoloads and base classes others extend.
3. Open the main scene in the editor (`gd command scene_open`), `gd run`, fix runtime errors.
4. Walk the game: tile maps, tweens, physics feel, UI layout (Controls lost the `rect_` prefix) and visuals.
5. Commit the result as one step, so the conversion can be compared with the original.
