---
name: godot-gdscript
description: Writing GDScript for Godot 4 that compiles and behaves - static typing rules, the mistakes that break scripts in this engine, how scripts, nodes, scenes, signals, resources and autoloads fit together, where files go, saving data, threads and export platforms. Use whenever you write or change a .gd file or decide how a Godot project is structured.
---

# GDScript and project structure in Godot 4

How the script reaches the project is covered by the `godot-cli` skill (`gd command fs_write_text --text-file ...`,
then `node_attach_script`). This skill is about what goes into the script.

## Before you write

- Look at what is there: `gd command scene_tree`, and read the scripts you are going to touch or call.
- Do not rely on memory for an API you are not sure of. `gd api class <Name>` prints the members of the installed
  Godot version; `gd api search <text>` finds a name.
- Search `references/gotchas.md` for the classes and methods you are about to use. Each entry starts with a
  `keywords` line; read the entries that match, not the file.

## The mistakes that actually break scripts

Write Godot 4 GDScript, never 3.x syntax; statically typed; indented with tabs.

- `:=` only when the right-hand side has an obvious static type (`var v := Vector2(1, 2)`, `var n := 0`).
  Dictionary access, `.get()`, elements of an untyped Array and calls to untyped functions are Variant, and inferring
  from a Variant is an error ("Cannot infer the type"): write `var dmg: float = stats["damage"]`.
- Typed containers: `Array[int]`, `Array[Vector2]`, `Dictionary[String, int]` (Godot 4.4 and newer for typed
  dictionaries). Nested typed collections do not exist: `Array[Array]`, not `Array[Array[int]]`.
- `int / int` is integer division and raises a warning; for a float result make one side a float.
- `%` is for ints: floats use `fmod()`, wrapping uses `posmod()` / `fposmod()`. Prefer the typed maths functions
  (`absf`, `clampi`, `lerpf`, `floori`, `roundi`, `signf`).
- `match` does not convert types: `1.0` does not match `1`.
- Do not name a parameter or variable after a member of the base class (`position`, `rotation`, `scale`, `size`,
  `name`, `owner`). Prefix an unused parameter of an overridden virtual with `_` (`func _process(_delta: float)`).
- Lambdas capture locals by value; share mutable state through an Array or Dictionary. For the same reason value
  types (`int`, `float`, `bool`, `Vector2`, `AABB`, `Transform3D`) cannot be out-parameters.
- `x as Type` is null when the object is not of that type: check before use.
- `preload()` is resolved when the script is parsed, and needs a constant path to a file that exists at that
  moment. Create and save the scene or script it names before you write the script that preloads it; when that is
  not possible (two files that refer to each other), use `load()` in `_ready()`.
- Inside a physics callback (`body_entered`, `area_entered`, and what they call) do not change physics state
  directly: `call_deferred("add_child", node)`, `set_deferred("monitoring", false)`, `set_deferred("disabled", true)`.
  Otherwise: "Can't change this state while flushing queries".
- A custom input action has to exist before a script reads it: `Input.is_action_pressed("jump")` on an unregistered
  action is a runtime error. Only the `ui_*` actions exist by default (`gd command project_input_map_set`).
- Reach the nodes of the scene with `@onready var bar: ProgressBar = $UI/HealthBar`. In `_ready()`, create and store
  child nodes before calling anything that uses them.
- `await` a coroutine when you call it; a function that awaits returns to its caller at the first `await`.
- A `Node` is not freed when nothing refers to it: `queue_free()`. A `RefCounted` or `Resource` is.
- `load()` returns one shared resource. Changing it changes it for every user: `.duplicate()` for a separate copy.
- `res://` is read-only in an exported game. Save games and settings go to `user://`.
- A script without `extends` is a `RefCounted`, not a `Node`.

Order inside a script: `class_name`, `extends`, signals, enums, constants, `@export` variables, variables, `@onready`
variables, built-in virtuals (`_ready`, `_process`, ...), public methods, private `_methods`. Names: snake_case for
files, functions and variables, PascalCase for classes and nodes, CONSTANT_CASE for constants, past tense for signals.
`and` / `or` / `not`, not `&&` / `||` / `!`.

## Scene first, script second

- Build the tree with nodes and set what the Inspector shows as properties (`node_create`, `node_set`). A script
  holds behaviour, not layout: no `Sprite2D.new()` and positions in `_ready()` for things that are always there.
- What should be tunable is an `@export` variable; then it is a property that `node_set` and the Inspector can set.
- One script per responsibility. A node that needs behaviour gets its own script; the scene root coordinates.
- Reusable pieces are their own scenes (`scene_new`, build, `scene_save`), placed with `node_instantiate_scene`.
  A scene made at run time: `const Bullet := preload("res://scenes/bullet.tscn")`, then `Bullet.instantiate()`.
- Things that are spawned (bullets, effects) are added to the level, not to the node that spawned them, or they
  move and die with it.

## Signals

Children announce, parents decide: a child emits a signal upward and does not reach for its parent or siblings.

```gdscript
signal health_changed(current: int, maximum: int)
signal died

func take_damage(amount: int) -> void:
	health = maxi(health - amount, 0)
	health_changed.emit(health, max_health)
	if health == 0:
		died.emit()
```

- Connections between nodes of one scene belong in the scene: `gd command node_connect_signal --path Player
  --signal died --target . --method _on_player_died`. The method must already exist in the target's script.
- Connections to nodes created at run time are made in code: `enemy.died.connect(_on_enemy_died.bind(enemy))`.
- Nodes that have to be found from anywhere (the player, all enemies) go into a group (`node_add_to_group`) and are
  found with `get_tree().get_nodes_in_group("enemies")` or `get_first_node_in_group("player")`.

## Autoloads

A script or scene registered as an autoload exists once, above every scene, for the whole run: game state, audio,
scene switching. It is not freed on scene change and must never be freed by hand.

Registering one changes what the project loads, so it is one of the changes a person approves at the editor:

```bash
gd command project_settings_set --name autoload/GameState --value '*res://scripts/autoload/game_state.gd' --yes
```

(The `*` makes it a node reachable by its name.) Use an autoload when state really has to outlive scenes; a
group or a signal is enough for most "how do I reach X" questions.

## Where files go

When the user names a path, or the file already exists, that path wins. When you choose:

- not directly in `res://`;
- by type for a small project: `res://scripts/`, `res://scenes/`, `res://resources/`, `res://art/`, `res://audio/`,
  `res://shaders/`;
- a self-contained feature keeps its files together (`res://enemies/slime/slime.tscn`, `slime.gd`);
- lower-case file names with underscores. An exported game's pack is case-sensitive on every platform, and so
  are Linux and Android: `Player.gd` and `player.gd` are different files there, though the editor on Windows
  and macOS finds either.

Move or rename files with `gd command fs_move`, which also rewrites the references to them. Moving a file with a
shell command breaks every scene that uses it.

## Building something large

For a whole game or a feature with several systems:

1. **The core loop first**: movement, collision, camera. Run it (`gd run`) before adding anything.
2. **Then content**: enemies, items, levels, on top of a core that works.
3. **Polish last**: particles, shaders, sound, menus.

Isolate what is risky and try it on its own before building on it: procedural generation, custom animation trees,
vehicle or ragdoll physics, custom shaders, geometry built at run time, navigation that changes at run time, camera
rigs with smoothing. Character movement with `move_and_slide()`, tile maps, navigation on a static map, ordinary UI,
timers and spawning are routine and need no prototype.

Run after every step, not at the end. An error found right after the change that caused it is cheap.

## References

- `references/gotchas.md` - pitfalls of the language, nodes, scenes, resources, files, threads and platforms. Search by keyword.
- `references/api.md` - notes on `Node`, `SceneTree`, `Timer`, `FileAccess`, `DirAccess`, `JSON`, `HTTPRequest`.
