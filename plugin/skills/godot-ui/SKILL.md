---
name: godot-ui
description: Building user interfaces in Godot 4 with Control nodes - menus, HUDs, health bars, inventories, dialogue boxes; anchors and anchor presets, containers, CanvasLayer, themes and StyleBox, fonts, focus and mouse filtering, scaling for different screen sizes, translation. Use when adding or fixing anything the player reads or clicks.
---

# User interface

UI is built from `Control` nodes in the scene, with `gd command node_create` and `node_set` (the `godot-cli` skill),
not constructed in a script. Search `references/gotchas.md` for the node classes you use.

## Three rules that prevent most layout bugs

1. **A HUD or menu goes under a `CanvasLayer`**, never directly under game-world nodes: it must not move with the
   camera. Typical layers: 5 for the HUD, 10 for menus, 100 for full-screen effects.
2. **A child of a container is placed by the container.** Do not set `position`, `size` or anchors on it; they are
   overwritten. Steer it with `custom_minimum_size` and the `size_flags_*` properties.
3. **Anything else is placed with anchors**, not with `position`: use `anchors_preset`, then offsets.

## Anchors

`anchors_preset` takes the preset's number or the name of its constant (`"PRESET_FULL_RECT"`). `node_create` and
`node_set` switch the control to anchor layout for you when you set it.

| Preset | Value | Preset | Value |
|---|---|---|---|
| top left | 0 | center top | 5 |
| top right | 1 | center bottom | 7 |
| bottom left | 2 | center | 8 |
| bottom right | 3 | left wide | 9 |
| center left | 4 | top wide | 10 |
| center right | 6 | right wide | 11 |
| full rect | 15 | bottom wide | 12 |

```bash
gd command node_create --type CanvasLayer --name HUD --properties '{"layer": 5}'
gd command node_create --type ColorRect --parent HUD --name Dim --properties '{"anchors_preset": 15, "color": "#00000080"}'
gd command node_create --type Label --parent HUD --name Score \
  --properties '{"anchors_preset": 1, "offset_left": -220, "offset_top": 16, "offset_right": -16, "text": "0"}'
```

Offsets are pixels from the anchor: for a control anchored to the right edge, `offset_left` and `offset_right` are
negative. A control whose opposite anchors differ (full rect, wide presets) gets its size from the layout, after
`_ready()`: do not assign `size` in `_ready()`; use `custom_minimum_size` or `set_deferred("size", ...)`.

## Containers

Let containers do the arithmetic.

| Container | Does |
|---|---|
| `VBoxContainer`, `HBoxContainer` | stacks children; spacing is the theme constant `separation` |
| `GridContainer` | a grid; set `columns` |
| `MarginContainer` | padding around one child; the margins are theme constants, not properties |
| `CenterContainer` | centres its child |
| `PanelContainer` | a background panel sized to its child |
| `ScrollContainer` | scrolls one child that is larger than it |

```bash
gd command node_create --type CenterContainer --parent Menu --name Center --properties '{"anchors_preset": 15}'
gd command node_create --type VBoxContainer --parent Menu/Center --name Buttons
gd command node_create --type Button --parent Menu/Center/Buttons --name Start \
  --properties '{"text": "Start", "custom_minimum_size": [220, 48]}'
gd command node_create --type Button --parent Menu/Center/Buttons --name Quit \
  --properties '{"text": "Quit", "custom_minimum_size": [220, 48]}'
```

`size_flags_horizontal` / `size_flags_vertical`: 1 fill, 3 expand and fill (takes the spare room), 4 shrink to the
centre, 8 shrink to the end. Theme values of a node are set through its `theme_override_*` properties:

```bash
gd command node_set --path Menu/Center/Buttons --properties '{"theme_override_constants/separation": 12}'
gd command node_set --path HUD/Score --properties '{"theme_override_font_sizes/font_size": 32, "theme_override_colors/font_color": "#ffd24a"}'
gd command node_set --path Menu/Margin --properties '{"theme_override_constants/margin_left": 24, "theme_override_constants/margin_top": 24}'
```

## Making it do something

The button's signal is connected in the scene, to a method of a script that already exists:

```bash
gd command node_attach_script --path Menu --script res://scripts/menu.gd
gd command node_connect_signal --path Menu/Center/Buttons/Start --signal pressed --target Menu --method _on_start_pressed
```

A HUD listens; it does not poll. The player emits `health_changed(current, maximum)`, the HUD script updates the
bar in the handler. Nothing in `_process`.

## Common pieces

**Health bar.** A `ProgressBar` (set `max_value`, `value`, `show_percentage` false) or `TextureProgressBar` is the
direct way. For full control over the look: a `Control` with a fixed `custom_minimum_size`, a dark `ColorRect`
filling it, and a second `ColorRect` anchored to the left whose `anchor_right` is set to `current / maximum`:

```gdscript
func _on_health_changed(current: int, maximum: int) -> void:
	_fill.anchor_right = float(current) / float(maximum)
```

**Styled panel.** A `StyleBoxFlat` in the theme override:

```bash
gd command node_create --type PanelContainer --parent HUD --name Box --properties '{
  "anchors_preset": 7, "offset_top": -140, "offset_bottom": -20, "offset_left": -300, "offset_right": 300,
  "theme_override_styles/panel": {"$new": "StyleBoxFlat", "properties": {
    "bg_color": "#0d0d1aeb", "border_color": "#666699",
    "corner_radius_top_left": 8, "corner_radius_top_right": 8,
    "corner_radius_bottom_left": 8, "corner_radius_bottom_right": 8,
    "border_width_left": 1, "border_width_top": 1, "border_width_right": 1, "border_width_bottom": 1}}}'
```

**Typewriter text.** A `RichTextLabel` with `bbcode_enabled` true; animate `visible_characters` from 0 with a tween:
`create_tween().tween_property(label, "visible_characters", text.length(), text.length() / 30.0)`.

**Floating numbers, pop-ups, fades.** A tween, then `queue_free` in its last step, not a counter in `_process`.

**Inventory grid.** `ScrollContainer` > `GridContainer` (`columns`), each slot a scene of its own
(`node_instantiate_scene`, or `instantiate()` in code when the contents are data).

**Pause menu.** The menu's root has `process_mode` set to always (`{"process_mode": "PROCESS_MODE_ALWAYS"}`), or it
stops with the rest when `get_tree().paused` is true.

## Input and focus

- A control that should not swallow clicks (an overlay, a decorative `ColorRect` or `TextureRect` on top of a button) gets
  `mouse_filter` ignore: `{"mouse_filter": "MOUSE_FILTER_IGNORE"}`. A full-rect control with the default filter
  blocks every click behind it; this is the usual reason "the button does nothing". (A `Label` already ignores
  the mouse.)
- Keyboard and gamepad navigation needs a focused control: call `grab_focus()` on the first button when a menu
  opens.
- UI gets input before the game. Game input in `_unhandled_input` does not fire for events the UI used.

## Screen sizes

Set once per project, when the user asks for it or the game cannot work without it:

```bash
gd command project_settings_set --name display/window/size/viewport_width --value 1280 --yes
gd command project_settings_set --name display/window/size/viewport_height --value 720 --yes
gd command project_settings_set --name display/window/stretch/mode --value canvas_items --yes
gd command project_settings_set --name display/window/stretch/aspect --value expand --yes
```

`canvas_items` keeps UI sharp at any size; pixel-art games use `viewport` with integer scaling. With `expand`, the
visible area grows on wider screens, which is exactly what anchors are for.

## Text and languages

The default font covers few scripts. On desktop, missing glyphs (Chinese, Japanese, Korean, Arabic, ...) are borrowed
from a system font, so text that looks right in the editor can show as boxes in a web export or on another machine:
set a font that has them in the theme or as `theme_override_fonts/font`. Text of labels and buttons is
looked up as a translation key automatically.

## Checking it

`gd command editor_screenshot` shows the editor with the scene; `game_screenshot` shows the running game (both need
a window). Read the picture: overlapping controls, text cut off and things at the top-left corner (a missing
anchor) are visible at a glance. `game_node_get --properties '["size", "global_position"]'` gives the laid-out
numbers.

## References

- `references/gotchas.md` - UI, layout, font and translation pitfalls. Search by class name.
- `references/api.md` - notes on `Control`, `Button`, `Label`, `RichTextLabel`, `LineEdit`.
