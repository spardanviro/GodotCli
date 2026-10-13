---
name: godot-troubleshooting
description: Find out why a Godot 4 game misbehaves, from the symptom - falls through the floor, does not move, collisions or signals that do not fire, a button that does nothing, a black or blank screen, an animation that does not play, no sound, "null instance" and "nonexistent function" errors, changes that do not show up, works in the editor but not when exported. Use when something is broken, behaves oddly or throws an error, before changing code on a guess.
---

# Finding the cause

Look before you change anything. The running game can be read from here (the `godot-cli` skill,
`references/running-game.md`), so most questions have an answer that does not need a guess.

## The order to work in

1. **Get the error text.** Most problems announce themselves. Save first, because the run reads the files on disk.
   ```bash
   gd command scene_save
   gd run --seconds 5 --headless        # errors and warnings, with file and line
   ```
   Fix the first error first; later ones are often its consequences. An error names a file and a line: read them.
2. **If it runs without errors, watch it run.**
   ```bash
   gd command editor_play
   gd command game_tree                  # is the node there at all? under the parent you expect?
   gd command game_node_get --path Main/Player --properties '["position", "velocity", "visible"]'
   gd command game_errors
   gd command game_output                # what the game printed
   ```
3. **Make it happen and compare.** Read a value, press the input, read again:
   `gd command game_input --action jump --hold 0.1`. A value that does not change tells you which half of the
   chain is broken: the input, or what the input should cause.
4. **If it stops on an error**, the game is halted at the failing line: `gd command game_debug` shows where,
   `gd command game_locals` the variables at that moment. That is usually the whole answer.
5. **Change one thing**, run again, and check the same value. Say what the cause was, not only what you changed.

Do not rewrite a script because it "looks wrong" while the actual values have not been read.

## By symptom

### Falls through the floor, or walks through walls

| Check | How |
|---|---|
| Both bodies have a `CollisionShape2D/3D` child **with a shape** | `gd command scene_tree`, then `node_get` on the shape node: `shape` must not be null |
| Layers and masks meet: the mover's `collision_mask` contains the floor's `collision_layer` | `node_get --properties '["collision_layer", "collision_mask"]'` on both |
| Nothing is scaled: `scale` of bodies and shapes is 1 | `node_get --properties '["scale"]'`; size a shape through its own properties |
| Tiles have collision | `tileset_add_atlas --collision true` or `tileset_set_collision` (the `godot-tilemap` skill) |
| A fast object tunnels through a thin wall | thicker wall, or continuous collision detection on the body |
| The body is moved by setting `position` | a `CharacterBody` moves with `move_and_slide()`; a `RigidBody` with forces |

### Does not move, or moves wrongly

- The action is not registered: `gd command project_input_map`. A script reading an unknown action errors at
  run time; `gd run` shows it.
- The script is not attached, or attached to another node: `scene_tree` lists the script of each node.
- `velocity` is set but `move_and_slide()` is never called, or movement code is in `_process` instead of
  `_physics_process`.
- `velocity` multiplied by `delta` before `move_and_slide()`: it crawls. Gravity not multiplied by `delta`: it
  drops like a stone.
- `is_on_floor()` is always false: it is only valid after `move_and_slide()`; `up_direction` is wrong; or the
  body is in floating motion mode.
- Test with `game_input` and read `velocity` right after: zero velocity means the input never arrived; non-zero
  velocity with an unchanged position means something blocks or overrides it.

### A signal or collision callback never fires

- Is it connected? `gd command node_get --path <node>` does not list connections; read the scene file
  (`fs_read_text` on the `.tscn`, the `[connection ...]` lines), or connect it with `node_connect_signal`.
- The method name in the connection must exist in the target's script, spelled the same.
- `body_entered` fires for bodies, `area_entered` for areas. The detecting `Area` needs `monitoring` on and the
  other side on a layer its mask contains; another area is only seen while its own `monitorable` is on.
- A `RigidBody` reports contacts only with `contact_monitor` true and `max_contacts_reported` above 0.
- Put a `print()` at the top of the handler and read `game_output`: no line means it is not called; a line
  means the bug is inside it.

### A button does nothing, or clicks go to the wrong thing

- A control on top swallows the click. A full-rect `ColorRect`, `Panel` or `TextureRect` over the button with
  the default `mouse_filter` (stop) blocks it: set `{"mouse_filter": "MOUSE_FILTER_IGNORE"}` on the overlay.
  (A `Label` ignores the mouse by default.)
- The `pressed` signal is not connected (see above).
- The button is `disabled`, or invisible because a parent is.
- The UI is under a node that moves with the camera; it belongs under a `CanvasLayer`.
- While the tree is paused the menu does not react: its `process_mode` must be `PROCESS_MODE_ALWAYS`.

### Black, grey or empty screen

- 2D: is anything inside the camera's view? `game_node_get` the camera's and the player's `global_position`.
  A `Camera2D` far from the content shows the clear colour.
- 3D: no camera, no light, or the camera looks away (-Z is forward). No `WorldEnvironment` means no sky: the
  editor's preview sun and sky do not exist in the running game.
- The node is there but invisible: `visible` false, `modulate` alpha 0, `z_index` behind, scale 0.
- Pink or magenta: a missing texture or a shader that failed to compile; `gd run` has the error.
- Look at it: `gd command game_screenshot` (needs a window).

### An animation does not play

- The name passed to `play()` does not exist: `gd command animation_list --player <path>`. Names are
  case-sensitive.
- A track points at a node that was renamed or moved: `animation_list` shows the track paths.
- Nothing starts it: `autoplay` is empty and no script calls `play()`.
- An `AnimationTree` is active and overrides the `AnimationPlayer`, or is inactive and should not be:
  `node_get --properties '["active"]'`.
- `game_node_get --properties '["current_animation", "current_animation_position"]'` on the player shows what
  it thinks it is doing.

### No sound

- `stream` is empty, or `play()` is never called and `autoplay` is off.
- The `bus` name does not exist: it falls back to `Master` silently, which is audible; a muted or very quiet
  bus is not. `volume_db` at -80 is silence.
- An `AudioStreamPlayer2D/3D` too far from the listener (the current camera).
- The node was freed while playing.
- Sound cannot be heard from here. Say what was checked and what the user should hear.

### "Invalid call. Nonexistent function", "Invalid access to property ... on a base object of type 'Nil'"

- Something is null. `game_debug` and `game_locals` at the halt show which variable.
- A `$Path` that does not match the tree: compare with `game_tree`. Nodes renamed in the scene, or a script
  running `_ready` before the node it reaches exists.
- A node used after `queue_free()`: guard with `is_instance_valid(node)`.
- A method name from Godot 3, or from another class: `gd api class <Name>` lists what exists.
- `get_node()` in `_init()`: the node is not in the tree yet; use `_ready()` or `@onready`.

### The change does not show up

- The scene was not saved: `gd command scene_save`. `gd run` reads the files on disk.
- Another scene is being edited than the one that runs: `gd command editor_status` shows the edited scene;
  `project_settings_get --name application/run/main_scene` the one that starts.
- The property was changed on an instance, and the scene it is an instance of sets it again in a script.
- The game was already running: stop and start it (`editor_stop`, `editor_play`).
- A file was copied in from outside: `gd command fs_scan` so the editor imports it.

### Works in the editor, not in the exported game

- Files are found by a path with the wrong letter case: Windows forgives it, the export and Linux do not.
- The game writes to `res://`: read-only when exported. Saves go to `user://`.
- A resource is loaded by a path built at run time and was not exported: resources only referenced that way
  have to be included in the export preset.
- A feature of a renderer the target does not use (the web uses the compatibility renderer).
- Threads, or anything the web platform restricts.

## When it is not on this list

- Search the pitfalls of the area: the `references/gotchas.md` of `godot-physics-gameplay`, `godot-ui`,
  `godot-3d-rendering`, `godot-animation-audio`, `godot-gdscript`, by class or method name.
- The manual, when a copy is set up on this machine: `gd docs search <words>`, then `gd docs page <page>`.
  It has troubleshooting pages for physics, exporting and the editor itself.
- `gd api class <Name>` for what a class really offers in the installed version.

Say what you checked and what you found, also when the cause is still open. A list of things ruled out is worth
more to the user than a confident guess.
