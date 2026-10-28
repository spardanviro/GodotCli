# The running game

Two ways to run the project, for two purposes.

## `gd run`: does it start, and what does it complain about

```bash
gd run --seconds 5 --headless           # the main scene
gd run res://scenes/level_2.tscn --seconds 5 --headless --json
```

Starts Godot on the files **on disk**, lets the game run for the given time, stops it and reports
`diagnostics` (errors and warnings with file and line), `error_count`, `warning_count` and the last lines of output.
No editor is needed. Save the scene first (`scene_save`): unsaved changes in the editor are not part of this run.
`--headless` runs without a window; leave it out when the game needs to render something to work.

This is the check to run after every piece of work.

## `editor_play`: look inside while it runs

```bash
gd command editor_play                              # like F5; --scene res://... runs one scene, like F6
gd command game_tree
gd command editor_stop
```

The `game_*` commands work only on a game started this way (or by the person pressing F5), not on one started by
`gd run`. Node paths are relative to the root window, so the main scene's root is the first segment: `Main/Player`.
`game_tree` shows the tree as it is now, with `current_scene` and the autoloads.

The game needs a moment to start; a `game_*` command sent right after `editor_play` waits for it (up to 5 seconds).

### Read and change live values

```bash
gd command game_node_get --path Main/Player --properties '["position", "velocity", "health"]'
gd command game_node_set --path Main/Player --properties '{"position": [400, 100]}'
gd command game_call --path Main/Player --method is_on_floor
gd command game_call --path Main/Spawner --method spawn_wave --arguments '[3]'
gd command game_output              # what the game printed
gd command game_errors              # errors and warnings it reported, each with a script call stack
```

`game_node_get` reads what the Inspector hides too: `velocity`, `global_position`, script variables.
`game_node_set` and `game_call` change the running game only; the scene file stays as it is. Use them to try a
value, then make the change that should stay in the scene or the script.

### Play it

```bash
gd command game_input --action move_right --hold 1.0     # hold an input action for a second of game time
gd command game_input --action jump --hold 0.1
gd command game_screenshot                                # path of a PNG you can open; not in a headless game
```

### How fast it runs

```bash
gd command game_performance      # fps, process_ms and physics_ms per frame, memory, nodes, orphan_nodes, draw calls
```

One reading of the debugger's Monitors tab; `fps` is the average of the last second. To see a trend, read it, play
for a while (`game_input`), and read again. `orphan_nodes` that keeps growing is a leak: nodes removed from the tree
with `remove_child` but never freed. `process_ms` near or above 16.7 is what makes a 60 fps game stutter. Render
numbers are 0 in a game without a window. A game's own counters show up under `custom` once its code calls
`Performance.add_custom_monitor("game/enemies", func(): return enemy_count)`.

`game_input` presses an action of the input map, as a player would: the game gets an input event, so code that polls
`Input`, `_input`/`_unhandled_input` handlers and a focused button (`ui_accept`) all see it. A sequence that tests
behaviour: read a value, press, wait, read again, compare.

```bash
gd command game_node_get --path Main/Player --properties '["position"]'
gd command game_input --action jump --hold 0.1
sleep 0.3
gd command game_node_get --path Main/Player --properties '["position"]'     # y is smaller: it left the ground
```

### Debug it

| Command | What it does |
|---|---|
| `game_debug` | whether the game is halted, why (breakpoint or the error text), and the call stack; frame 0 is where it stopped |
| `game_locals --frame N` | local variables, members of the object and globals of one frame |
| `game_breakpoint --path res://x.gd --line 42` | set a breakpoint for this run (`--enabled false` clears it) |
| `game_pause` | halt at the next line of script the game runs |
| `game_step --mode over\|into\|out` | run one line (or to the end of the function) and halt again |
| `game_continue` | let it run on |

- **A script error halts the game at the failing line.** Then `game_debug` has the error text as `reason` and the
  failing line on top of the stack, and `game_locals` shows the values that led to it. That is usually all that is
  needed to find the cause. `game_continue` afterwards, or `editor_stop`.
- While the game is halted, `game_node_get`, `game_tree` and `game_call` still answer.
- Breakpoints set here last until the game stops and do not show up in the script editor.
- Only the main thread is followed. There are no conditional breakpoints or watch expressions.

## When something does not answer

- `PRECONDITION_FAILED` on a `game_*` command: the game is not running, or it was not started from the editor.
- `TIMEOUT`: the game did not answer in 5 seconds. It may be busy loading, or frozen in a loop: `game_pause` and
  `game_debug` show where it is.
- A game started from a headless editor opens a window unless the project setting `editor/run/main_run_args` is
  `--headless`.
