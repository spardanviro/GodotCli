---
name: godot-sprite-animation
description: 2D sprite animation and pixel art in Godot 4 with the gd command line - cut a sprite sheet into frame animations for an AnimatedSprite2D, animate a Sprite2D's frame, switch animations from movement code, build an animation state machine, and set a project up for crisp pixel art (nearest filtering, pixel snapping, integer scaling). Use when the user has a sprite sheet or frame images, wants walk, idle or jump animations on a character, or is making a pixel-art or retro-style game.
---

# Sprite animation and pixel art

Run the commands with `gd command ...` (see the `godot-cli` skill). Each change is one undo step in the editor.

## Frames from a sprite sheet

A character with a handful of frame animations is an `AnimatedSprite2D`:

```bash
gd command node_create --type AnimatedSprite2D --parent Player --name Sprite
gd command sprite_frames_create --args '{"node": "Player/Sprite", "autoplay": "idle", "animations": [
  {"name": "idle", "sheet": "res://art/hero.png", "hframes": 4, "vframes": 2, "frames": [0, 1], "fps": 4},
  {"name": "run",  "sheet": "res://art/hero.png", "hframes": 4, "vframes": 2, "frames": [4, 5, 6, 7], "fps": 12},
  {"name": "jump", "sheet": "res://art/hero.png", "hframes": 4, "vframes": 2, "frames": [2], "loop": false}]}'
```

- `hframes` and `vframes` are the columns and rows of the sheet. `frames` picks cells, counted row by row from 0
  (in a sheet of 4 columns, the second row starts at 4); without it, every cell is used in order.
- You need to know the layout of the sheet: how many columns and rows, and which cells belong to which animation.
  Ask the user, or look at the image yourself when you can read image files. Guessing gives animations that flicker
  between unrelated poses.
- One image per frame instead of a sheet: `{"name": "explode", "files": ["res://art/boom_0.png", "res://art/boom_1.png"]}`.
- `fps` defaults to 10, `loop` to true. An animation of a name the node already has is replaced, the others stay;
  `"replace": true` starts over.
- `autoplay` is what plays when the scene starts.
- New images have to be imported first: `gd command fs_scan` after copying them in.
- Pixel art stays sharp through the texture filter, not the import: project setting
  `rendering/textures/canvas_textures/default_texture_filter` set to 0 (Nearest), or a node's `texture_filter`.
  Keep its import lossless (`import_settings_get` shows `compress/mode` 0) and without mipmaps.

Driving it from the character's script:

```gdscript
@onready var sprite: AnimatedSprite2D = $Sprite

func _update_animation() -> void:
	if not is_on_floor():
		sprite.play("jump")
	elif absf(velocity.x) > 1.0:
		sprite.play("run")
	else:
		sprite.play("idle")
	if velocity.x != 0.0:
		sprite.flip_h = velocity.x < 0.0
```

Call it at the end of `_physics_process`, after `move_and_slide()`. Calling `play` with the animation that is
already playing does nothing, so doing it every frame is fine. Face the other way with `flip_h`; do not scale the
body by -1, which mirrors its collision too.

## When to use an AnimationPlayer instead

When the animation moves more than the picture: a hit box that is switched on for three frames, a sound on the
footstep, a child node that follows the sword. Then the sheet goes on a `Sprite2D` and an `AnimationPlayer` animates
its `frame` together with everything else:

```bash
gd command node_create --type Sprite2D --parent Player --name Sheet \
  --properties '{"texture": {"$res": "res://art/hero.png"}, "hframes": 4, "vframes": 2}'
gd command node_create --type AnimationPlayer --parent Player --name Anim
gd command animation_create --args '{"player": "Player/Anim", "name": "hit", "length": 0.4, "tracks": [
  {"node": "Player/Sheet", "property": "frame", "keys": [{"time": 0, "value": 2}, {"time": 0.2, "value": 3}]},
  {"node": "Player/Sheet", "property": "modulate", "keys": [{"time": 0, "value": "#ff5555"}, {"time": 0.4, "value": "#ffffff"}]},
  {"node": "Player", "method": "set_physics_process", "keys": [{"time": 0, "args": [false]}, {"time": 0.4, "args": [true]}]}]}'
```

A track with `method` instead of `property` calls that method of the node at each key, with `args`. Use it for
what must happen at a moment of the animation: `queue_free` at the end of a death animation, a method of the
node's own script that spawns the projectile. More on tracks, loops and tweens is in the `godot-animation-audio` skill.

## Many animations with rules between them

When the question becomes "from which animation may it go to which, and when", build a state machine on an
`AnimationTree`. It plays the animations of an `AnimationPlayer`:

```bash
gd command node_create --type AnimationTree --parent Player --name Tree
gd command animation_state_machine_create --args '{"tree": "Player/Tree", "player": "Player/Anim",
  "states": [{"name": "Calm", "animation": "calm"}, {"name": "Hit", "animation": "hit"}],
  "transitions": [{"from": "Calm", "to": "Hit", "condition": "hurt"},
                  {"from": "Hit", "to": "Calm", "switch": "at_end", "auto": true}]}'
```

- A transition with a `condition` is taken when code sets that boolean; with `"switch": "at_end", "auto": true` it
  is taken when the animation has finished; with neither, only when code asks for the state.
- The answer lists the `parameters` to set. In the script:
  ```gdscript
  @onready var tree: AnimationTree = $Tree

  func take_hit() -> void:
  	tree["parameters/conditions/hurt"] = true        # set it back to false once it has been taken

  func go_to(state: String) -> void:
  	var playback: AnimationNodeStateMachinePlayback = tree["parameters/playback"]
  	playback.travel(state)
  ```
- `expression` on a transition is evaluated on the tree's parent node (the command sets the tree's
  `advance_expression_base_node` to `..`), e.g.
  `"expression": "velocity.length() > 10.0"`. A tree with an expression is left **inactive** by the command (the
  answer says `"active": false`): an active tree also runs inside the editor. Turn it on from the script, with
  `tree.active = true` in `_ready()`. Prefer a `condition` when a boolean will do.
- For three or four animations, the `play()` calls above are simpler and easier to debug. Nested state machines
  are built in the animation tree editor; there is no command for them.

## Blending by a value

A top-down character with a walk animation per direction, or idle that turns into run as speed grows, is a blend
space: animations placed at positions, mixed by one position that code sets.

```bash
gd command animation_blend_space_create --args '{"tree": "Player/Tree", "player": "Player/Anim",
  "points": [{"animation": "walk_up", "position": [0, -1]}, {"animation": "walk_down", "position": [0, 1]},
             {"animation": "walk_left", "position": [-1, 0]}, {"animation": "walk_right", "position": [1, 0]}]}'
gd command animation_blend_space_create --args '{"tree": "Player/Tree", "player": "Player/Anim",
  "points": [{"animation": "idle", "position": 0}, {"animation": "run", "position": 1}]}'
```

Positions are all numbers (one axis) or all `[x, y]` (a plane). The tree's root becomes the blend space, replacing
what it had. From the script: `tree["parameters/blend_position"] = input_direction` (a `Vector2`, or a float for
one axis). Blending suits animations that move bones or properties smoothly. Frame-by-frame sprite animations
cannot be mixed halfway; for a sprite that only has to face four ways, choosing the animation in code from the
input direction is simpler.

## Pixel art

Without these settings pixel art is blurred, shimmers when it moves and scales unevenly. They are project
settings: set them when the user is making a pixel-art game, not in passing.

```bash
gd command project_settings_set --name rendering/textures/canvas_textures/default_texture_filter --value 0 --yes   # nearest
gd command project_settings_set --name rendering/2d/snap/snap_2d_transforms_to_pixel --value true --yes
gd command project_settings_set --name display/window/size/viewport_width --value 320 --yes
gd command project_settings_set --name display/window/size/viewport_height --value 180 --yes
gd command project_settings_set --name display/window/stretch/mode --value viewport --yes
gd command project_settings_set --name display/window/stretch/scale_mode --value integer --yes
gd command project_settings_set --name display/window/size/window_width_override --value 1280 --yes
gd command project_settings_set --name display/window/size/window_height_override --value 720 --yes
```

- **Nearest filtering** keeps pixels square. Set per node instead with `{"texture_filter": "TEXTURE_FILTER_NEAREST"}`
  when only part of the game is pixel art.
- **A small viewport, stretched**: the game is drawn at its art resolution (320 by 180 here; 16:9 multiples of it
  fill common screens) and scaled up. `viewport` mode scales the finished picture, so everything stays on the pixel
  grid; `integer` keeps the scale a whole number so every pixel is the same size.
- **The window override** is the size of the window on a desktop; without it the window is as small as the viewport.
- All sprites should be drawn at the same pixel density. One sprite scaled by 1.5 breaks the look.
- A `Camera2D` with smoothing makes pixel art shimmer unless positions are snapped (the setting above); if it still
  does, turn smoothing off.

## Checking it

`sprite_frames_create` answers with every animation of the node (frames, fps, loop), the `animation` the editor
shows and the `autoplay` one: read that instead of asking for them again. With `autoplay` set, the animation
plays when the scene starts; there is no need to start the game to see that it does. For frames added to a node,
saving and one run are the check:

```bash
gd command scene_save
gd run --seconds 3 --headless
```

Start the game only when the animation has to change with what the character does (run while it moves, jump in the
air), and read each value once:

```bash
gd command editor_play
gd command game_node_get --path Level/Player/Sprite --properties '["animation", "frame"]'
gd command game_input --action move_right --hold 1
gd command game_node_get --path Level/Player/Sprite --properties '["animation", "flip_h"]'    # "run" while it moves
gd command game_screenshot                                                                    # needs a window
```

- Frames show parts of two poses: `hframes` or `vframes` do not match the sheet.
- The animation does not change: `play()` is not reached, or the name differs from the one created (names are
  case-sensitive).
- Blurry: the texture filter is still linear, on the project or on that node.
