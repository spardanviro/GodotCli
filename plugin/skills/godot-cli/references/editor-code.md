# Code that runs in the editor

For what no command does: painting tile map cells, building an `AnimationTree`, changing many nodes at once,
anything that needs a loop over the scene. There are three ways, in the order to consider them.

## 1. Do it in the game instead

Much of what looks like an editor job can be a few lines in a script of the game: fill a `TileMapLayer` in
`_ready()`, build a grid of nodes from data, set up a state machine. It needs no special permission, it is plain
project code the user can read, and it is tested by running the game. Prefer this when the result does not have to
be visible in the editor.

## 2. `gd eval`

```bash
gd eval 'return scene.get_child_count()'
gd eval --file /tmp/paint_tiles.gd
```

The code is the body of `func run(editor, scene)`: `editor` is `EditorInterface`, `scene` is the root of the scene
being edited. `return` gives the result back.

- It is **off unless the user turned it on** in the editor settings, it is not sandboxed, and each call is shown to
  the person at the editor, who has to allow it. A headless editor refuses it. So: one call that does everything,
  not ten small ones, and only for what the commands cannot do.
- `EVAL_DISABLED`: tell the user what you need it for and offer the alternatives. Do not ask them to enable it as a
  matter of routine.
- `print()` output is not returned. `return` what you want to see.

Rules for the code:

- A node added to the scene needs its owner set, **after** `add_child()`, or it is not saved with the scene:
  ```gdscript
  var marker := Marker2D.new()
  marker.name = "Spawn"
  scene.add_child(marker)
  marker.owner = scene          # always after add_child, always the scene root
  ```
- For a change the user should be able to undo, go through the undo manager:
  ```gdscript
  var undo := editor.get_editor_undo_redo()
  undo.create_action("Add spawn points")
  undo.add_do_method(scene, "add_child", marker)
  undo.add_do_property(marker, "owner", scene)
  undo.add_do_reference(marker)
  undo.add_undo_method(scene, "remove_child", marker)
  undo.commit_action()
  ```
- Use the `EditorInterface` singleton (the `editor` argument). `get_editor_interface()`, `get_scene()` and a bare
  `add_root_node()` are deprecated.
- `add_to_group("enemies", true)`: without `true` the group is not saved with the scene.
- Do not call `Camera2D.make_current()` on a node of the edited scene; a camera in the scene becomes current when
  the game runs.
- No `OS.execute`, `OS.create_process`, `OS.shell_open`, no network access, no file writes outside `res://`.

Example: fill a rectangle of a tile map layer.

```gdscript
var layer: TileMapLayer = scene.get_node("Ground")
for x in range(0, 40):
	for y in range(10, 12):
		layer.set_cell(Vector2i(x, y), 0, Vector2i(1, 0))
return layer.get_used_cells().size()
```

## 3. A command of the project's own

A project can add commands by putting scripts in `res://gdcli_commands/`. Each is a tool script that extends
`RefCounted` and provides `descriptor()` and `run(args, options)`:

```gdscript
@tool
extends RefCounted


func descriptor() -> Dictionary:
	return {
		"name": "level_stats",
		"summary": "Counts the character bodies of the edited scene.",
		"risk": "write",
		"params": {"type": "object", "properties": {}},
	}


func run(_args: Dictionary, _options: Dictionary) -> Variant:
	var scene := EditorInterface.get_edited_scene_root()
	return {"enemies": scene.find_children("*", "CharacterBody2D", true, false).size()}
```

They appear in `gd list` and run with `gd command <name>`. Worth it for a job that will be repeated. Know the cost:

- A command of the project counts as `write` at least, whatever it declares.
- The folder is one of the places a person has to approve writes to, and the scripts are loaded only when the
  bridge starts: the editor has to be restarted (or the addon re-enabled) before a new command exists.
- Such a script is editor code of the project, trusted like any other tool script. Propose it to the user; do not
  add one on the side to get around a refusal.
