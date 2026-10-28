---
name: godot-animation-audio
description: Animation, effects and sound in Godot 4 - AnimationPlayer and keyframes, tweens, AnimatedSprite2D and sprite sheets, AnimationTree state machines and blending, particles (GPUParticles and CPUParticles), audio players, buses, music and sound effects. Use when making something move over time, adding visual effects or adding sound.
---

# Animation, particles and audio

Built with `gd command ...` (the `godot-cli` skill). Search `references/gotchas.md` for the node classes you use.

## Which tool for a motion

| For | Use |
|---|---|
| a fixed motion that is designed once: a door opening, an idle bob, a UI panel sliding in, a walk cycle on a sprite sheet | `AnimationPlayer` |
| a motion whose start or end is only known at run time: move to where the player clicked, fade this out now, a hit flash | a tween in code |
| frame-by-frame sprite animation | `AnimatedSprite2D` with `SpriteFrames`, or an `AnimationPlayer` on a `Sprite2D`'s `frame` |
| choosing and blending between many animations of a character | `AnimationTree` on top of an `AnimationPlayer` |

## AnimationPlayer

`animation_create` builds an animation from property keyframes; each track names a node of the scene, a property
and its keys:

```bash
gd command node_create --type AnimationPlayer --name Anim
gd command animation_create --args '{
  "player": "Anim", "name": "bob", "length": 1.0, "loop": "pingpong", "autoplay": true,
  "tracks": [
    {"node": "Coin", "property": "position", "keys": [{"time": 0, "value": [400, 250]}, {"time": 1, "value": [400, 238]}]},
    {"node": "Coin", "property": "modulate", "keys": [{"time": 0, "value": "#ffffff"}, {"time": 1, "value": "#ffe08a"}]}
  ]}'
gd command animation_list --player Anim
```

- `loop`: `none`, `linear` (restart), `pingpong` (back and forth). `autoplay` plays it when the scene starts.
- Per track: `interpolation` (`nearest`, `linear`, `cubic`) and `update` (`continuous`, `discrete`). Values that
  cannot be blended (booleans, integers such as a sprite's `frame`, strings, textures) step at their key.
- Values are written like any property value (`references/values.md` in `godot-cli`).
- `overwrite: true` replaces an animation of the same name. The whole thing is one undo step.
- Track paths are relative to the player's `root_node`, which is its parent by default. The command works that out;
  an `AnimationPlayer` that is itself the scene root needs `root_node` set to `"."`.
- A track with `method` instead of `property` calls that method of the node at its keys:
  `{"node": "Enemy", "method": "queue_free", "keys": [{"time": 1.0}]}`; arguments go in `"args": [...]`.
- A track with `"audio": true` plays sound files on an audio player node at its keys:
  `{"node": "Sfx", "audio": true, "keys": [{"time": 0.2, "stream": "res://audio/step.wav"}]}`. `start_offset` and
  `end_offset` (seconds) trim a sound. The node is an `AudioStreamPlayer`, `AudioStreamPlayer2D` or `3D`.
- Bezier tracks and editing single keys of an existing animation are jobs for the animation editor (ask the
  user). To change an animation, create it again with `overwrite: true`.

Sprite-sheet walk cycle: a `Sprite2D` with `hframes`/`vframes` set, and a track on `frame`:

```bash
gd command animation_create --args '{"player": "Player/Anim", "name": "walk", "length": 0.6, "loop": "linear",
  "tracks": [{"node": "Player/Sprite", "property": "frame",
    "keys": [{"time": 0, "value": 0}, {"time": 0.15, "value": 1}, {"time": 0.3, "value": 2}, {"time": 0.45, "value": 3}]}]}'
```

In scripts: `$Anim.play("walk")`, `$Anim.play_backwards("open")`, `await $Anim.animation_finished`. Playing the
animation that is already playing does nothing, so calling `play` every frame is fine.

An animation named exactly `RESET` (one key per animated property at time 0) holds the values the scene is saved
with and that blending starts from. Make one when several animations animate the same properties.

## Tweens

```gdscript
func flash() -> void:
	var tween := create_tween()
	tween.tween_property($Sprite, "modulate", Color.RED, 0.08)
	tween.tween_property($Sprite, "modulate", Color.WHITE, 0.12)

func pop_and_vanish() -> void:
	var tween := create_tween().set_parallel()
	tween.tween_property(self, "scale", Vector2(1.4, 1.4), 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "modulate:a", 0.0, 0.25)
	tween.chain().tween_callback(queue_free)
```

- Steps run one after another; `set_parallel()` runs them together; `chain()` goes back to sequence.
- `create_tween()` on a node ties the tween to it: it stops when the node is freed. A new tween on a property does
  not stop an old one on the same property: keep the tween and `kill()` it before starting another.
- A tween starts on its own. There is no `start()`, and no `Tween.new()` or Tween node (that was Godot 3).
- Smooth following every frame is not a tween: `lerp(a, b, 1.0 - exp(-speed * delta))`, which behaves the same at
  any frame rate.

## AnimatedSprite2D

`sprite_frames_create` fills one from sprite sheets or single images, one named animation each:

```bash
gd command sprite_frames_create --args '{"node": "Player/Sprite", "autoplay": "idle", "animations": [
  {"name": "idle", "sheet": "res://art/hero.png", "hframes": 4, "vframes": 2, "frames": [0, 1], "fps": 4},
  {"name": "run",  "sheet": "res://art/hero.png", "hframes": 4, "vframes": 2, "frames": [4, 5, 6, 7], "fps": 12}]}'
```

The `godot-sprite-animation` skill covers this workflow, driving it from movement code, and pixel-art settings.

## AnimationTree

For a character with many animations: a state machine (idle, run, jump, fall) or blend spaces (walk direction).

- It plays the animations of an `AnimationPlayer` (`anim_player` path); it has none of its own. Set `active` true.
- A state machine is built with `animation_state_machine_create`: states that each play one animation, and
  transitions with a condition, an expression, or "when the animation ends":
  ```bash
  gd command animation_state_machine_create --args '{"tree": "Player/Tree", "player": "Player/Anim",
    "states": [{"name": "Idle", "animation": "idle"}, {"name": "Run", "animation": "run"}],
    "transitions": [{"from": "Idle", "to": "Run", "condition": "moving", "xfade": 0.1},
                    {"from": "Run", "to": "Idle", "expression": "velocity.length() < 1.0"}]}'
  ```
  With an expression the tree is left inactive (it would run in the editor too): the script sets
  `active = true` in `_ready()`.
- A blend space mixes animations by a position set from code (walk direction, speed):
  ```bash
  gd command animation_blend_space_create --args '{"tree": "Player/Tree", "player": "Player/Anim",
    "points": [{"animation": "idle", "position": 0}, {"animation": "run", "position": 1}]}'
  ```
  Positions are numbers for one axis or `[x, y]` for a plane; code sets `tree["parameters/blend_position"]`.
- Blend trees, and a machine or blend space nested in another, are built in the animation tree editor: ask the user.
- Drive it from the script: `var playback: AnimationNodeStateMachinePlayback = $AnimationTree["parameters/playback"]`,
  then `playback.travel("run")`; blend positions are `$AnimationTree["parameters/Move/blend_position"] = direction`.
- For a handful of animations a few `play()` calls in the script are simpler and easier to debug. Reach for the
  tree when transitions and blending are the actual problem.

## Particles

`GPUParticles2D/3D` are the default, also in the Compatibility renderer (since Godot 4.2); `CPUParticles2D/3D` are
for old or weak devices where GPU particles are slow, or when a script must read particle positions. GPU particles need a process material, or nothing appears:

```bash
gd command node_create --type GPUParticles2D --name Dust --properties '{
  "amount": 24, "lifetime": 0.6, "one_shot": true, "explosiveness": 0.9, "emitting": false,
  "process_material": {"$new": "ParticleProcessMaterial", "properties": {
    "direction": [0, -1, 0], "spread": 60, "initial_velocity_min": 40, "initial_velocity_max": 90,
    "gravity": [0, 200, 0], "scale_min": 2, "scale_max": 4}}}'
```

- A burst: `one_shot` true, `explosiveness` near 1, and `restart()` (or `emitting = true`) from the script.
- In 3D each particle also needs something to draw: `draw_pass_1` with a mesh (`{"$new": "QuadMesh"}`), usually
  with a billboard material.
- Particles outside the `visibility_rect` (2D) or `visibility_aabb` (3D) vanish when the emitter's box leaves the
  screen: make the box cover where they travel.
- A one-shot effect scene frees itself: connect `finished` to `queue_free`.
- `ParticleProcessMaterial` vectors are 3D even for 2D particles.

## Audio

| Node | For |
|---|---|
| `AudioStreamPlayer` | music, UI sounds: no position |
| `AudioStreamPlayer2D`, `AudioStreamPlayer3D` | sounds in the world: volume and panning depend on distance to the listener |

```bash
gd command node_create --type AudioStreamPlayer --name Music --properties '{
  "stream": {"$res": "res://audio/theme.ogg"}, "autoplay": true, "bus": "Music", "volume_db": -6}'
gd command node_create --type AudioStreamPlayer2D --parent Player --name JumpSound \
  --properties '{"stream": {"$res": "res://audio/jump.wav"}}'
```

- Formats: WAV for short effects (cheap to play), Ogg Vorbis for music (small). Audio files are imported like any
  asset: copy them in, then `gd command fs_scan`.
- Looping is a setting of the imported file (or of the stream resource), not of the player. Ogg and MP3:
  `gd command import_settings_set --path res://audio/theme.ogg --params '{"loop": true}'`. WAV:
  `{"edit/loop_mode": 2}` (0 detect from the file, 1 off, 2 forward, 3 ping-pong, 4 backward). Check the
  names with `import_settings_get` first.
- Volume is in decibels: 0 is full, -6 about half as loud, -80 silent. A 0..1 slider value goes through
  `linear_to_db()`.
- One player plays one sound at a time; playing again restarts it. For overlapping copies of the same sound raise
  `max_polyphony`, or spawn a player per sound.
- A sound on a node that is being freed is cut off. Play "death" sounds from a node that survives.
- Buses (`Master`, and those the project adds, such as `Music` and `SFX`) are made and given effects as in the
  `godot-audio-buses` skill, and referred to **by name**; a name that does not exist falls back to `Master` silently. Volume per bus:
  `AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Music"), db)`.
- This plugin does not create audio. Use files the project has, or ask the user for them.

## Checking it

- `gd run` reports a missing stream, an animation name that does not exist, a track pointing at a node that is gone.
- On a game started with `editor_play`: `gd command game_node_get --path Main/Anim --properties
  '["current_animation", "current_animation_position"]'`, and `game_call --method is_playing` on a player.
- What it looks like: `game_screenshot`, a few of them over time.
- What it sounds like cannot be checked from here. Say so, and say what should be heard.

## References

- `references/gotchas.md` - animation, tween, particle and audio pitfalls. Search by class name.
- `references/api.md` - notes on `AnimationPlayer`, `AnimationTree`, `Tween`, the audio players, the particle nodes, `Skeleton3D`.
