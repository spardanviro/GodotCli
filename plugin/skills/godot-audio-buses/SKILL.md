---
name: godot-audio-buses
description: Mix a Godot 4 game's sound with audio buses using the gd command line - create the bus layout (Music, SFX, Voice under Master) as res://default_bus_layout.tres, add effects to a bus (reverb, low-pass, compressor, limiter), send players to a bus, volume sliders and mute in an options menu (AudioServer, linear_to_db), ducking music under dialogue, and what does not work on the Web. Use when the user wants separate music and effects volume, a sound settings menu, reverb or muffled sound, mixing, or mentions audio buses, AudioServer or AudioBusLayout.
---

# Audio buses

Every sound plays on a bus. `Master` goes to the speakers; other buses (`Music`, `SFX`, `Voice`, ...) send their
sound on to `Master`, or to another bus further up the list. A bus has a volume, mute, solo, and a chain of effects.
Players name their bus with their `bus` property. For players and streams themselves, see the
`godot-animation-audio` skill. Commands are run with `gd command ...` (see the `godot-cli` skill).

## The layout

The buses of a project are the resource `res://default_bus_layout.tres` (the project setting
`audio/buses/default_bus_layout` names it). The game loads it at start. Write it as a text file:

```
[gd_resource type="AudioBusLayout" load_steps=2 format=3]

[sub_resource type="AudioEffectReverb" id="AudioEffectReverb_1"]
room_size = 0.6
wet = 0.25

[resource]
bus/1/name = &"Music"
bus/1/solo = false
bus/1/mute = false
bus/1/bypass_fx = false
bus/1/volume_db = -6.0
bus/1/send = &"Master"
bus/2/name = &"SFX"
bus/2/solo = false
bus/2/mute = false
bus/2/bypass_fx = false
bus/2/volume_db = 0.0
bus/2/send = &"Master"
bus/2/effect/0/effect = SubResource("AudioEffectReverb_1")
bus/2/effect/0/enabled = true
```

```bash
gd command fs_read_text --path res://default_bus_layout.tres      # keep what is there; it may not exist yet
gd command fs_write_text --path res://default_bus_layout.tres --text-file /tmp/default_bus_layout.tres --overwrite true --yes
```

- Bus 0 is `Master` and needs no lines unless it gets effects or another volume (`bus/0/...`). Buses are numbered
  without gaps.
- `send` names a bus with a lower number. Sound flows from higher numbers toward `Master`, never back.
- Each effect is a `sub_resource` with its own `id`, listed as `bus/N/effect/M/effect` with `.../enabled`, in the
  order they apply. Common ones: `AudioEffectReverb`, `AudioEffectLowPassFilter` (`cutoff_hz`, muffled sound),
  `AudioEffectHighPassFilter`, `AudioEffectCompressor` (with `sidechain` for ducking), `AudioEffectLimiter`,
  `AudioEffectDelay`, `AudioEffectChorus`, `AudioEffectEQ`. `gd api class AudioEffectReverb` lists the properties.
- `resource_create` cannot build this resource: the bus entries are not ordinary properties. Write the text.
- A player whose `bus` names a bus that does not exist plays on `Master` without a word, and so do players of a bus
  that was renamed. Check the names after changing the layout.
- Written with `fs_write_text`, the layout is also loaded into the editor at once (the reply says
  `bus_layout_loaded`), so players can be put on the new buses right away. Written another way, the editor knows
  the new buses only after it is opened again, and a player set to one of them is saved with `Master`.

## Players on buses

```bash
gd command node_set --path Music --properties '{"bus": "Music"}'
gd command node_create --type AudioStreamPlayer2D --parent Player --name Step --properties '{"stream": {"$res": "res://audio/step.wav"}, "bus": "SFX"}'
```

## Volume from the game

```gdscript
func set_bus_volume(bus_name: String, value: float) -> void:   # value 0..1 from a slider
	var bus := AudioServer.get_bus_index(bus_name)
	AudioServer.set_bus_volume_db(bus, linear_to_db(value))
	AudioServer.set_bus_mute(bus, value <= 0.001)
```

- Volume is in decibels: 0 dB is the bus at full, -6 dB about half, around -60 to -80 dB silence; above 0 dB on
  `Master` clips. Sliders work in 0..1 and go through `linear_to_db()` (and `db_to_linear()` back).
  From Godot 4.4, `AudioServer.set_bus_volume_linear()` does the conversion itself.
- `get_bus_index` returns -1 for a name that is not there: check it.
- Changes from code last until the game quits. Save the player's levels in `user://` (a `ConfigFile`) and set them
  again at start.
- Other calls: `set_bus_bypass_effects`, `set_bus_effect_enabled(bus, index, on)` (turn the reverb on in a cave),
  `get_bus_effect(bus, index)` to change an effect's properties while playing, `add_bus_effect` and `add_bus`.
- Ducking (music quieter while someone speaks): a compressor on `Music` with `sidechain` set to `Voice`, or a tween
  on the `Music` bus volume.

## Checking it

- `gd run --headless` with a script that prints `AudioServer.bus_count` and `AudioServer.get_bus_name(i)` for each
  bus, or on a running game `game_call` and `game_node_get` on the options menu's sliders.
- Whether it sounds right cannot be checked from here: say which bus should be louder or muffled and when.
- On the Web, sounds play as samples by default, and bus effects do nothing there; see the `godot-export` skill.
