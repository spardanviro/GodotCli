---
name: godot-3d-rendering
description: 3D scenes and rendering in Godot 4 - meshes, materials, lights, shadows, environment and sky, cameras, the three renderers (Forward+, Mobile, Compatibility) and what each supports, shaders, transparency, importing models and textures, viewports, performance. Use when building a 3D scene, when something looks wrong on screen, or when writing a shader.
---

# 3D scenes, materials, lights and shaders

Nodes are created with `gd command node_create` and resources inline with `{"$new": ...}` (the `godot-cli` skill).
Rendering is where the engine has the most "works here, silently not there" behaviour: search
`references/gotchas.md` for the node, the effect or the renderer before you build on it.

## Know the renderer first

```bash
gd command project_settings_get --name rendering/renderer/rendering_method
```

| Renderer | Value | For | Does not have |
|---|---|---|---|
| Forward+ | `forward_plus` | desktop | - |
| Mobile | `mobile` | phones, weaker desktops | SDFGI, VoxelGI, volumetric fog, SSAO, SSIL, screen-space reflections, TAA, FSR2, subsurface scattering; 8 omni and 8 spot lights per mesh |
| Compatibility | `gl_compatibility` | web, old hardware | most of the above plus many post effects, decals, compute shaders |

An effect that needs Forward+ does nothing on the others, without an error. Changing the renderer is a project
decision: ask before you do it.

## A scene that shows something

A 3D scene is black until it has a camera, a light and something to light. The editor's preview sun and sky are
**editor only** and do not exist in the running game.

```bash
gd command scene_new --path res://scenes/world.tscn --root-type Node3D --root-name World

gd command node_create --type Camera3D --name Camera \
  --properties '{"position": [0, 5, 10], "rotation_degrees": [-25, 0, 0]}'
gd command node_create --type DirectionalLight3D --name Sun \
  --properties '{"rotation_degrees": [-45, -30, 0], "shadow_enabled": true}'
gd command node_create --type WorldEnvironment --name Environment --properties '{
  "environment": {"$new": "Environment", "properties": {
    "background_mode": "BG_SKY",
    "sky": {"$new": "Sky", "properties": {"sky_material": {"$new": "ProceduralSkyMaterial"}}},
    "tonemap_mode": "TONE_MAPPER_FILMIC"}}}'

gd command node_create --type StaticBody3D --name Floor
gd command node_create --type MeshInstance3D --parent Floor --name Mesh --properties '{
  "mesh": {"$new": "PlaneMesh", "properties": {"size": [20, 20],
    "material": {"$new": "StandardMaterial3D", "properties": {"albedo_color": "#666666"}}}}}'
gd command node_create --type CollisionShape3D --parent Floor --name Shape \
  --properties '{"shape": {"$new": "BoxShape3D", "properties": {"size": [20, 0.1, 20]}}, "position": [0, -0.05, 0]}'
```

- Y is up, -Z is forward, units are metres. A camera with no rotation looks along -Z.
- One `WorldEnvironment` per scene tree.
- The mesh is the look, the collision shape is the physics: a `MeshInstance3D` alone collides with nothing.
- Primitive meshes: `BoxMesh`, `SphereMesh`, `CapsuleMesh`, `CylinderMesh`, `PlaneMesh`, `QuadMesh`, `PrismMesh`,
  `TorusMesh`. For blocking out a level quickly, the `CSG*` nodes combine shapes and can generate collision
  (`use_collision`); they are for prototypes, not for final levels.

## Materials

`StandardMaterial3D` covers most needs: `albedo_color`, `albedo_texture`, `metallic`, `roughness`,
`emission_enabled` with `emission` and `emission_energy_multiplier`, `normal_enabled` with `normal_texture`.

Where the material goes decides who shares it:

- on the **mesh resource** (`"material"` of a primitive mesh): everything using that mesh;
- `material_override` on the `MeshInstance3D`: this instance, all surfaces;
- `surface_material_override/0`: this instance, one surface. This is the one to use on imported models.

```bash
gd command node_set --path Crate --properties '{
  "surface_material_override/0": {"$new": "StandardMaterial3D", "properties": {
    "albedo_color": "#b5651d", "roughness": 0.8}}}'
```

A material reused across scenes is a file: `gd command resource_create --type StandardMaterial3D --path
res://materials/metal.tres --properties '{...}'`, then `{"$res": "res://materials/metal.tres"}`.

Transparency costs: with `transparency` set to alpha, a material no longer casts shadows and is sorted by the
object's origin, not per pixel, so overlapping transparent objects can draw in the wrong order. For cut-outs
(leaves, fences) use alpha scissor; for soft things accept the sorting or set `render_priority`.
Emission makes a surface look bright; it lights nothing around it unless a global illumination method is on.

## Lights and shadows

- `DirectionalLight3D`: the sun. Only its rotation matters, not its position.
- `OmniLight3D` (`omni_range`), `SpotLight3D` (`spot_range`, `spot_angle`): local lights. Shadows are off by
  default (`shadow_enabled`) and each shadowed light costs.
- Mobile and Compatibility cap the lights that affect one mesh at 8 omni and 8 spot. Split large meshes or use
  fewer lights.
- Shadow acne or peter-panning: adjust `shadow_bias` and `shadow_normal_bias` on the light a little at a time.
- Z-fighting far away: raise the camera's `near`, do not lower `far`.

## Rotation

`rotation_degrees` is fine for setting a node up once. For something that turns every frame, work with the
basis or quaternions (`rotate_y(angle)`, `transform.basis`, `Quaternion.slerp`); adding to Euler angles over time
leads to gimbal lock and drift. A first-person look turns the body around Y and the head (camera pivot) around X,
and clamps the X angle.

## Shaders

A shader is a text file (`.gdshader`), which you write directly with your own file tools, then
`gd command fs_scan`, and use through a `ShaderMaterial`:

```bash
gd command node_set --path Water --properties '{
  "material_override": {"$new": "ShaderMaterial", "properties": {"shader": {"$res": "res://shaders/water.gdshader"}}}}'
```

```glsl
shader_type spatial;

uniform vec4 tint : source_color = vec4(0.1, 0.4, 0.8, 1.0);
uniform float speed = 1.0;

void fragment() {
	ALBEDO = tint.rgb;
	ROUGHNESS = 0.1;
	ALPHA = 0.8;
}
```

The language is close to GLSL ES 3.0 but is its own: `shader_type spatial` (3D), `canvas_item` (2D and UI),
`particles`, `sky`, `fog`.

- No implicit conversions: `float x = 1;` is an error, write `1.0`. `int` to `float` needs `float(i)`.
- Local variables are not initialised. Assign before use.
- A colour uniform needs `: source_color` or it is treated as raw data and looks washed out.
- Uniforms are set from code with `material.set_shader_parameter("speed", 2.0)`, and from here as
  `"shader_parameter/speed": 2.0` among the properties of the `ShaderMaterial`, after `shader`.
- Reading the screen (`hint_screen_texture`) and depth works differently per renderer; check the pitfalls file.

`gd run` reports shader compile errors with the line.

## Importing models and textures

- Put the file (`.glb` is the format to prefer; `.gltf`, `.fbx`, `.blend`, `.obj`) into the project, then
  `gd command fs_scan` (or `gd import` without an editor). The editor imports it as a scene.
- Use it with `gd command node_instantiate_scene --scene res://models/crate.glb`. Do not edit the imported scene:
  it is regenerated on every reimport. To change it, instance it in a scene of your own, or change import settings
  with `import_settings_get` and `import_settings_set` (switches and numbers such as `meshes/generate_lods`,
  `animation/fps`). The root type, per-mesh and per-material options are set in the Import dock.
- A texture's import: `compress/mode` (0 lossless, 1 lossy, 2 VRAM compressed, the one for 3D textures,
  3 VRAM uncompressed, 4 Basis Universal),
  `mipmaps/generate` (on for textures seen at a distance), `process/size_limit`.
- An imported model has no collision. Add a body and shape around it; trimesh collision is for static level
  geometry only.
- Textures that repeat should be power-of-two sized. Mobile devices cap at 4096 pixels.
- A texture's pixels are not readable from a script directly: `texture.get_image()` first.

## Viewports

A `SubViewport` renders a separate world or camera to a texture (minimaps, mirrors, 3D in UI). It is shown through
a `SubViewportContainer` or a `ViewportTexture`. It gets no input unless inside a `SubViewportContainer`, and its
texture is empty on the very first frame.

## When it looks wrong

Look at it: `gd command game_screenshot` on a game with a window, `gd command editor_screenshot` for the editor.

| Symptom | Usual cause |
|---|---|
| black screen | no camera, no light, or the camera faces away (-Z is forward) |
| grey, flat, no sky | no `WorldEnvironment` in the scene (the editor preview does not count) |
| object invisible | scale 0, inside the camera's `near`, wrong layer against the camera's `cull_mask`, material fully transparent |
| pink or checkered | missing texture or a shader that failed to compile (`gd run` has the error) |
| works in the editor, not in the game or on the device | a feature the target renderer lacks |
| flickering surfaces | two surfaces in the same place, or `near` too small |

## References

- `references/gotchas.md` - rendering, lighting, material, shader, import and viewport pitfalls. Search by class, effect or renderer name.
- `references/api.md` - notes on `Camera3D`, `StandardMaterial3D`, `ShaderMaterial`, `WorldEnvironment`, `DirectionalLight3D`, `MultiMesh`, `GridMap`, `SubViewport`.
