---
name: godot-shaders
description: Write and use shaders in Godot 4 with the gd command line - the Godot shading language (shader_type canvas_item, spatial, particles, sky), uniforms and their hints, putting a ShaderMaterial on a node and setting its parameters from the command line and from a script, 2D effects (hit flash, outline, dissolve, palette swap, scrolling UV, pixel-art friendly sampling), full-screen effects with the screen texture, 3D surface shaders, what changed from Godot 3, and how to find a shader's errors. Use when the user wants a visual effect, a shader, a material that glows, flashes, dissolves or distorts, a post-processing effect, or mentions .gdshader, ShaderMaterial, uniform, fragment() or VisualShader.
---

# Shaders

A shader is a small program the GPU runs for every vertex and every pixel of what a node draws. In Godot it is a
text file (`.gdshader`) written in Godot's shading language, which looks like GLSL. A `ShaderMaterial` points at
the shader and holds the values of its parameters (`uniform`s); the node's `material` is that ShaderMaterial.
Commands are run with `gd command ...` (see the `godot-cli` skill).

Write shaders as text. A `VisualShader` (the node graph) can only be edited in the editor's graph view.

## The steps

1. Write the shader file with `fs_write_text` (a shader runs on the GPU, not in the editor, so it needs no
   person's approval):

```bash
gd command fs_write_text --path res://shaders/hit_flash.gdshader --text-file /tmp/hit_flash.gdshader
```

```glsl
shader_type canvas_item;

uniform vec4 flash_color : source_color = vec4(1.0);
uniform float flash : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 texel = texture(TEXTURE, UV) * COLOR;
	COLOR = vec4(mix(texel.rgb, flash_color.rgb, flash), texel.a);
}
```

2. Give the node a ShaderMaterial with it. `shader` first, then its parameters (they exist once the shader is set):

```bash
gd command node_set --path Player/Sprite2D --properties '{"material": {"$new": "ShaderMaterial", "properties":
  {"shader": {"$res": "res://shaders/hit_flash.gdshader"}, "shader_parameter/flash_color": "#ff4040"}}}'
```

3. Change a parameter from a script with `set_shader_parameter`, and animate it with a tween:

```gdscript
func flash() -> void:
	var material := $Sprite2D.material as ShaderMaterial
	material.set_shader_parameter("flash", 1.0)
	create_tween().tween_method(func(value: float) -> void: material.set_shader_parameter("flash", value), 1.0, 0.0, 0.2)
```

4. `gd command scene_save`, then `gd run --seconds 3`: shader compile errors come back with the file and line.
   `gd check` compiles GDScript only, not shaders.

A material is a resource, and resources are shared: every enemy instanced from one scene uses the **same**
ShaderMaterial, so flashing one flashes them all. Turn on the material's Local To Scene switch (the property resource_local_to_scene):
each instance of the scene then gets its own copy. Or give each node its own with `material = material.duplicate()` in `_ready()`.

## The language, briefly

- First line: `shader_type canvas_item;` (2D nodes and Control), `spatial;` (3D), `particles;`
  (GPUParticles process material), `sky;` (a Sky's material), `fog;` (FogVolume).
- `render_mode` after it: `unshaded`, `blend_add`, `cull_disabled`, `depth_draw_always`, ... (per type).
- Functions: `vertex()` (move vertices), `fragment()` (colour each pixel), `light()` (per light; leave it out to
  use the default lighting).
- Types: `float`, `vec2/3/4`, `int`, `bool`, `mat4`, `sampler2D`. Write floats with a dot: `1.0`, not `1`
  (`float x = 1;` is an error).
- canvas_item built-ins: `UV`, `COLOR`, `TEXTURE`, `TEXTURE_PIXEL_SIZE`, `VERTEX`, `TIME`, `SCREEN_UV`.
- spatial built-ins written in `fragment()`: `ALBEDO`, `ALPHA`, `METALLIC`, `ROUGHNESS`, `EMISSION`, `NORMAL_MAP`.
- `TIME` is seconds since the engine started; use it for anything that moves on its own.

## Uniforms and hints

| Uniform | What the hint does |
|---|---|
| `uniform vec4 tint : source_color = vec4(1.0);` | a colour, picked in sRGB like the Inspector's colours |
| `uniform float amount : hint_range(0.0, 1.0, 0.01) = 0.5;` | a slider |
| `uniform sampler2D noise : repeat_enable;` | a texture that tiles (for scrolling) |
| `uniform sampler2D palette : filter_nearest;` | sharp sampling: pixel art and lookup tables |
| `uniform sampler2D screen : hint_screen_texture, filter_linear_mipmap;` | what has been drawn so far |

A texture parameter is set with `{"$res": "res://art/noise.png"}`, or a generated one:
`"shader_parameter/noise": {"$new": "NoiseTexture2D", "properties": {"noise": {"$new": "FastNoiseLite"}, "seamless": true}}`.

## 2D effects

Outline (on a sprite with a transparent border):

```glsl
shader_type canvas_item;
uniform vec4 line_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float width : hint_range(0.0, 8.0) = 1.0;

void fragment() {
	vec4 texel = texture(TEXTURE, UV);
	vec2 step_size = TEXTURE_PIXEL_SIZE * width;
	float around = texture(TEXTURE, UV + vec2(step_size.x, 0.0)).a + texture(TEXTURE, UV - vec2(step_size.x, 0.0)).a
		+ texture(TEXTURE, UV + vec2(0.0, step_size.y)).a + texture(TEXTURE, UV - vec2(0.0, step_size.y)).a;
	COLOR = mix(line_color * min(around, 1.0), texel, texel.a);
}
```

Dissolve (a noise texture decides which pixels go first):

```glsl
shader_type canvas_item;
uniform sampler2D noise;
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform vec4 edge_color : source_color = vec4(1.0, 0.5, 0.0, 1.0);

void fragment() {
	vec4 texel = texture(TEXTURE, UV);
	float value = texture(noise, UV).r;
	if (value < progress) {
		discard;
	}
	COLOR = mix(texel, edge_color, step(value, progress + 0.05) * texel.a);
}
```

- Scrolling (water, conveyor, clouds): `texture(TEXTURE, UV + vec2(TIME * 0.1, 0.0))` on a texture that repeats:
  the node's `texture_repeat` set to Enabled for `TEXTURE`, `repeat_enable` for a `uniform sampler2D`.
- Palette swap: read the sprite's grey value and look it up in a 1-pixel-high palette texture with `filter_nearest`.
- Pixel art: sample with `filter_nearest` and keep the project's default texture filter at Nearest (the
  `godot-sprite-animation` skill), or the effect blurs the pixels.
- An outline or glow drawn outside the sprite needs room: the shader only colours pixels inside the node's
  rectangle. Leave a transparent border in the image.

## Full-screen effects

A ColorRect that covers the screen, on a CanvasLayer above the game, with a shader that reads the screen texture:

```glsl
shader_type canvas_item;
uniform sampler2D screen : hint_screen_texture, filter_linear_mipmap;
uniform float strength : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec3 color = texture(screen, SCREEN_UV).rgb;
	float grey = dot(color, vec3(0.299, 0.587, 0.114));
	COLOR = vec4(mix(color, vec3(grey), strength), 1.0);
}
```

```bash
gd command node_create --type CanvasLayer --name Effects --properties '{"layer": 10}'
gd command node_create --type ColorRect --parent Effects --name Greyscale --properties '{"anchors_preset": 15,
  "mouse_filter": "Ignore", "material": {"$new": "ShaderMaterial", "properties": {"shader": {"$res": "res://shaders/greyscale.gdshader"}}}}'
```

`mouse_filter` Ignore keeps the rectangle from eating clicks meant for the UI below. In 3D, glow, fog, colour
correction and depth of field are settings of the WorldEnvironment (the `godot-3d-rendering` skill); write a
shader only for what those do not offer.

## 3D surfaces

```glsl
shader_type spatial;
uniform vec4 base : source_color = vec4(0.2, 0.6, 1.0, 1.0);
uniform float pulse_speed = 2.0;

void fragment() {
	ALBEDO = base.rgb;
	ROUGHNESS = 0.4;
	EMISSION = base.rgb * (0.5 + 0.5 * sin(TIME * pulse_speed));
}
```

Put it on a MeshInstance3D's `material_override`, or one surface's `surface_material_override/0`. A
StandardMaterial3D covers most surfaces without a shader; convert one when you need what it cannot do. Wind on
grass and waves move vertices in `vertex()` (`VERTEX.y += sin(VERTEX.x + TIME) * 0.1;`).

## From Godot 3 (old tutorials)

| Godot 3 | Godot 4 |
|---|---|
| `hint_color` | `source_color` |
| `SCREEN_TEXTURE` | a uniform with `hint_screen_texture` |
| `DEPTH_TEXTURE` | a uniform with `hint_depth_texture` |
| `NORMALMAP` | `NORMAL_MAP` |
| `WORLD_MATRIX`, `CAMERA_MATRIX` | `MODEL_MATRIX`, `INV_VIEW_MATRIX` |
| `material.set_shader_param()` | `set_shader_parameter()` |
| property `shader_param/x` | `shader_parameter/x` |

## When it does not show

- Nothing changes: the node's `material` is not the ShaderMaterial (`gd command node_get --path ... --properties
  '["material"]'`), or a parent's `use_parent_material` / a CanvasGroup takes over.
- Drawn wrongly or not at all: the shader did not compile; `gd run` prints the error with its line.
- All instances change together: the shared material above.
- Works with Forward+, not on the Web or mobile: the Compatibility renderer lacks some built-ins and features;
  check the class reference (`gd docs search shading language`) for what each renderer supports.
- `references/` of the `godot-3d-rendering` skill has more rendering pitfalls; search `gotchas.md` for "shader".
