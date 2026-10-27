// Corrections to the knowledge imported from the native module (Godot_AI):
// statements found wrong for Godot 4.3–4.7 in an audit. import-knowledge.mjs
// applies them to what it writes, and check-plugin.mjs fails when a wrong one
// is back, so a new import cannot bring them back unnoticed. Fix them at the
// source too when that repository is next worked on.
//
// Each entry: the file (under plugin/skills), the text as imported, and what
// it becomes.

/** @type {ReadonlyArray<{ file: string, wrong: string, right: string }>} */
export const CORRECTIONS = [
  // 3D rendering
  {
    file: "godot-3d-rendering/references/gotchas.md",
    wrong: "Setting `emission_enabled = true` and `emission_color` on a material",
    right: "Setting `emission_enabled = true` and `emission` (the color) on a material",
  },
  {
    file: "godot-3d-rendering/references/api.md",
    wrong: "  make_current() — use this to activate camera (NOT current=true).",
    right: "  make_current() or current = true (also as a property when creating the node) activates the camera.",
  },
  {
    file: "godot-3d-rendering/references/gotchas.md",
    wrong: "- New Viewports have positional_shadow_atlas_size = 0 by default — 3D point/spot light shadows are completely invisible until this is set > 0",
    right: "- A Viewport whose positional_shadow_atlas_size is 0 shows no point or spot light shadows at all; check it when those shadows are missing (the default is 2048)",
  },
  {
    file: "godot-3d-rendering/references/gotchas.md",
    wrong: "- **Project Settings > Rendering > Quality > Shading > Force Vertex Shading** is enabled (which is the DEFAULT on mobile platforms)",
    right: "- **Project Settings > Rendering > Shading > Overrides > Force Vertex Shading** is enabled",
  },
  {
    file: "godot-3d-rendering/references/gotchas.md",
    wrong: "For standalone XR headsets (Quest, etc.), use Compatibility renderer.",
    right: "For standalone XR headsets (Quest, etc.), the Mobile renderer is the recommended one.",
  },
  // Physics and movement
  {
    file: "godot-physics-gameplay/references/api.md",
    wrong: "  motion_mode: MOTION_MODE_GROUNDED(default,platformer) | MOTION_MODE_FLOATING(top-down/vehicles/boats — required for non-platformer).",
    right: "  motion_mode: MOTION_MODE_GROUNDED(default: any game with a floor and gravity) | MOTION_MODE_FLOATING(no floor at all, e.g. space; is_on_floor() is then always false).",
  },
  {
    file: "godot-physics-gameplay/references/api.md",
    wrong: "  CRITICAL: For top-down or vehicle games, always set motion_mode = CharacterBody3D.MOTION_MODE_FLOATING.",
    right: "  Keep GROUNDED wherever there is a floor (vehicles, walking, sliding); FLOATING is for movement without one.",
  },
  {
    file: "godot-physics-gameplay/references/gotchas.md",
    wrong: "### CharacterBody3D: use MOTION_MODE_FLOATING for non-platformer 3D movement",
    right: "### CharacterBody3D: MOTION_MODE_FLOATING is for movement without a floor",
  },
  {
    file: "godot-physics-gameplay/references/gotchas.md",
    wrong: "For any 3D movement that is NOT a side-scroller (top-down, vehicles, boats, space), you MUST set `motion_mode = CharacterBody3D.MOTION_MODE_FLOATING`. The default GROUNDED mode applies `floor_stop_on_slope` which fights movement on slopes and breaks top-down games entirely.",
    right: "FLOATING has no floor: `is_on_floor()` is always false, so it suits space or swimming, not a game with gravity. With a floor (vehicles, snowboards, walking on slopes) keep the default GROUNDED and tune `floor_stop_on_slope`, `floor_max_angle` and `floor_snap_length` instead.",
  },
  {
    file: "godot-physics-gameplay/references/gotchas.md",
    wrong: "CORRECT for top-down / vehicles / snowboards:\n  body.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING",
    right: "CORRECT for movement with no floor (space, underwater):\n  body.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING",
  },
  {
    file: "godot-physics-gameplay/references/gotchas.md",
    wrong: "  CORRECT: (collision_shape.shape as BoxShape2D).size = Vector2(64, 32)  # shape size",
    right: "  CORRECT: (collision_shape.shape as RectangleShape2D).size = Vector2(64, 32)  # shape size",
  },
  {
    file: "godot-physics-gameplay/references/gotchas.md",
    wrong: "Instead, change the shape's `extents`, `radius`, or `height` directly.",
    right: "Instead, change the shape's `size` (boxes; Godot 3 called it extents, at half the size), `radius`, or `height` directly.",
  },
  {
    file: "godot-physics-gameplay/references/gotchas.md",
    wrong: "  collision_shape.shape.extents = new_size",
    right: "  collision_shape.shape.size = new_size",
  },
  {
    file: "godot-physics-gameplay/references/gotchas.md",
    wrong: "### Scaling physics bodies or collision shapes is NOT supported — change extents instead; duplicate() before per-instance resize",
    right: "### Scaling physics bodies or collision shapes is NOT supported — change the shape's size instead; duplicate() before per-instance resize",
  },
  {
    file: "godot-physics-gameplay/references/gotchas.md",
    wrong: "- Godot does NOT support scaling CollisionShape2D/3D nodes. Change the shape's extents/radius directly instead.",
    right: "- Godot does NOT support scaling CollisionShape2D/3D nodes. Change the shape's size/radius directly instead.",
  },
  {
    file: "godot-physics-gameplay/references/gotchas.md",
    wrong: "- Scaling a physics body (set_scale()) does NOT work — change collision shape Extents/Radius directly",
    right: "- Scaling a physics body (set_scale()) does NOT work — change the collision shape's size/radius directly",
  },
  {
    file: "godot-physics-gameplay/references/gotchas.md",
    wrong: "3. **Raycast from a CollisionObject hits itself**: Add `query.exclude = [self]` (or `[get_rid()]` in C#) to exclude the caster.",
    right: "3. **Raycast from a CollisionObject hits itself**: Add `query.exclude = [get_rid()]` (exclude takes RIDs, not nodes) to exclude the caster.",
  },
  {
    file: "godot-physics-gameplay/references/gotchas.md",
    wrong: "For two objects to collide, **BOTH conditions must be met**:\n- Object A's collision **mask** must include the layer that Object B is **on**\n- Object B's collision **mask** must include the layer that Object A is **on** (for Area2D, only one direction needs to match)",
    right: "A contact is detected when **either** object's collision **mask** includes a layer the other is **on**:\n- Object A's mask includes Object B's layer, **or**\n- Object B's mask includes Object A's layer.\nWhich body is pushed is decided by the moving one: a CharacterBody's move_and_slide() only collides with what its own mask includes.",
  },
  {
    file: "godot-physics-gameplay/references/gotchas.md",
    wrong: "Use `call_deferred()` or wait for the first `_physics_process()` tick:",
    right: "Wait for the first physics frame (`await get_tree().physics_frame`) before setting the target, or set it in the first `_physics_process()` tick:",
  },
  {
    file: "godot-physics-gameplay/references/gotchas.md",
    wrong: "(or set `Input.ignore_joypad_on_unfocused_application = true` at runtime)",
    right: "(or, in versions that have it, `Input.ignore_joypad_on_unfocused_application = true` at runtime; check with `gd api class Input`)",
  },
  {
    file: "godot-physics-gameplay/references/gotchas.md",
    wrong: "### Controller motion sensors (gyroscope, accelerometer) are DISABLED by default — enable them with Input.set_joy_motion_sensors_enabled()",
    right: "### Controller motion sensors (gyroscope, accelerometer) are DISABLED by default — enable them with Input.set_joy_motion_sensors_enabled() (recent versions only: check with `gd api class Input`)",
  },
  // GDScript
  {
    file: "godot-gdscript/references/gotchas.md",
    wrong: "  get_tree().change_scene_to_node(scene_node)               # from instantiated node",
    right: "  get_tree().change_scene_to_node(scene_node)               # from instantiated node (Godot 4.6+; earlier: change_scene_to_packed)",
  },
  {
    file: "godot-gdscript/references/gotchas.md",
    wrong: "Non-virtual engine methods like `get_class()`, `queue_free()`, `_to_string()` **cannot** be overridden",
    right: "Non-virtual engine methods like `get_class()`, `queue_free()` **cannot** be overridden (`_to_string()` is virtual and can be)",
  },
  {
    file: "godot-gdscript/references/gotchas.md",
    wrong: "- Overriding non-virtual engine methods (get_class(), queue_free(), etc.) SILENTLY FAILS — the engine calls its own implementation, not yours. Only override methods marked as `virtual` in the docs.",
    right: "- Overriding non-virtual engine methods (get_class(), queue_free(), etc.) does not compile: the native_method_override warning is an error by default. Only override methods marked as `virtual` in the docs.",
  },
  {
    file: "godot-gdscript/references/gotchas.md",
    wrong: "- `_process()`, `_physics_process()`, `_input()`, `_enter_tree()`: **pre-order** (parent called BEFORE children — top-to-bottom in the editor)",
    right: "- `_process()`, `_physics_process()`, `_enter_tree()`: **pre-order** (parent called BEFORE children — top-to-bottom in the editor)\n- `_input()`, `_unhandled_input()`: the other way round — the last child in the tree gets the event first, then up towards the root",
  },
  {
    file: "godot-gdscript/references/gotchas.md",
    wrong: "In Godot 4.5+, you can override `_log_message()` in an autoload to intercept all `print()`, `push_error()`, `push_warning()` calls.",
    right: "In Godot 4.5+, a class that extends `Logger`, registered with `OS.add_logger()`, receives all `print()`, `push_error()`, `push_warning()` output in `_log_message()`.",
  },
  {
    file: "godot-gdscript/references/gotchas.md",
    wrong: "- Enable large world coordinates in project settings (uses double-precision floats for physics)",
    right: "- Use a build of Godot compiled with double precision (`precision=double`); no project setting switches it on",
  },
  {
    file: "godot-gdscript/references/gotchas.md",
    wrong: "Must write `5 / 2.0` or `float(5) / 2` to get a float result. No warning or error.",
    right: "Must write `5 / 2.0` or `float(5) / 2` to get a float result. The editor warns (integer_division) but runs it.",
  },
  {
    file: "godot-gdscript/references/gotchas.md",
    wrong: "### TSCN format: load_steps deprecated, uid:// paths mandatory in 4.6+",
    right: "### TSCN format: load_steps deprecated in 4.6; uid:// references preferred (not required)",
  },
  // UI
  {
    file: "godot-ui/references/gotchas.md",
    wrong: "### @export_tool_button — adds a clickable button in the Inspector (Godot 4.3+)",
    right: "### @export_tool_button — adds a clickable button in the Inspector (Godot 4.4+)",
  },
  {
    file: "godot-ui/references/gotchas.md",
    wrong: "### Control.LAYOUT_DIRECTION_LOCALE deprecated — use LAYOUT_DIRECTION_APPLICATION_LOCALE",
    right: "### Control.LAYOUT_DIRECTION_LOCALE deprecated — use LAYOUT_DIRECTION_APPLICATION_LOCALE (Godot 4.4+)",
  },
  {
    file: "godot-ui/references/gotchas.md",
    wrong: "- The default Godot font only supports Latin-1. CJK (Chinese/Japanese/Korean), Arabic, Cyrillic, etc. render as blank squares with no error",
    right: "- The default Godot font covers few scripts. On desktop, missing glyphs (CJK, Arabic, ...) are borrowed from a system font, so they look right on the developer's machine and show as boxes in a web export or where no such font is installed: ship a font that has them",
  },
  // Animation
  {
    file: "godot-animation-audio/references/gotchas.md",
    wrong: "### AnimationPlayer: new section-based playback (Godot 4.7)\nAnimationPlayer gained section-based playback in 4.7.",
    right: "### AnimationPlayer: section-based playback (Godot 4.4+)\nAnimationPlayer gained section-based playback in 4.4.",
  },
];

/**
 * The text with every correction for this file applied. Text already
 * corrected is left as it is (some corrections only add to the original line),
 * so applying them twice changes nothing.
 */
export function applyCorrections(file, text) {
  let corrected = text;
  for (const entry of CORRECTIONS) {
    if (entry.file === file) {
      corrected = corrected
        .split(entry.right)
        .map((piece) => piece.split(entry.wrong).join(entry.right))
        .join(entry.right);
    }
  }
  return corrected;
}

/** Whether the text still holds the wrong statement outside its correction. */
export function stillWrong(entry, text) {
  return text.split(entry.right).join("").includes(entry.wrong);
}
