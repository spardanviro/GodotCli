# Pitfalls: 3D scenes, rendering, materials, shaders and importing assets

115 entries, each a mistake that is easy to make in Godot 4 and what to do instead. Do not read this file from top to bottom:
search it for the class, method or term you are about to use (the `keywords` line of each entry lists them) and read the entries that match.
The other skills of this plugin have a file like this one for their topics: `../../*/references/gotchas.md` searches all of them.

Imported from the knowledge base of the Godot AI assistant module (github.com/spardanviro/Godot_AI) by `scripts/import-knowledge.mjs`; do not edit by hand.

<!-- keywords: StandardMaterial3D, Alpha, material -->
### StandardMaterial3D with Alpha transparency: can't cast shadows + sorting issues
Alpha-blended `StandardMaterial3D` (transparency = TRANSPARENCY_ALPHA) has important limitations:
- Cannot cast shadows (only receives them)
- Does NOT appear in screen-space reflections or SDFGI sharp reflections
- Sorting artifacts when transparent surfaces overlap each other
- Significantly slower to render than opaque
For foliage/fences use `TRANSPARENCY_ALPHA_SCISSOR` (hard edges, casts shadows). For hair use `TRANSPARENCY_ALPHA_HASH`. Only use ALPHA for particles and VFX that truly need blending.


<!-- keywords: RenderingServer, physics, rendering, canvas, int -->
### RenderingServer canvas items need reset_physics_interpolation() on first frame
When creating canvas items directly via `RenderingServer` (bypassing nodes), call `RenderingServer.canvas_item_reset_physics_interpolation(rid)` on the first frame after creation. Without this, the item visually 'teleports in' from position (0,0) due to stale interpolation state.


<!-- keywords: Shader, shader, GLSL -->
### Shader local variables are NOT initialized — always assign before use
In Godot's shading language, **local variables** (inside functions) are NOT zero-initialized. They contain whatever garbage was in memory at that address. Reading an unassigned local variable produces unpredictable visual glitches. Only `uniform` and `varying` declarations are initialized to a default value (0). Always assign a value before using a local variable:
```glsl
// WRONG: 'result' is uninitialized — garbage output
vec3 result;
if (some_condition) { result = vec3(1.0); }
ALBEDO = result;  // undefined behavior if condition was false

// CORRECT: always initialize
vec3 result = vec3(0.0);
if (some_condition) { result = vec3(1.0); }
ALBEDO = result;
```


<!-- keywords: Shader, shader, GLSL, int, float -->
### Shader: no implicit type casting — int/float/uint must be explicit
Godot's shading language (like GLSL ES 3.0) does NOT allow implicit casting between scalar types. Integer literals are signed `int` by default. This means:
```glsl
float a = 2;        // INVALID — int literal cannot implicitly cast to float
float a = 2.0;      // valid
float a = float(2); // valid
uint b = 2;         // INVALID — signed int literal cannot implicitly cast to uint
uint b = uint(2);   // valid
```


<!-- keywords: Don, Node3D, Transform3D, Quaternion, Node, 3D, rotation -->
### Don't use Node3D.rotation for continuous 3D rotation — use Transform3D/Quaternion
The `rotation` property of `Node3D` is stored as Euler angles (XYZ order). Using Euler angles for continuous rotation or interpolation causes gimbal lock and non-linear behavior (rotating from 270° to 0° may spin the wrong direction). For 3D games:
- Use `global_transform.basis` to read orientation
- Rotate using `rotate_object_local()` or `rotate_y()` for incremental rotation
- Use `Quaternion.slerp()` for smooth rotation interpolation
- For FPS cameras: rotate Y on parent node (global yaw) + rotate X on child Camera3D (local pitch)


<!-- keywords: Light, Mobile, Compatibility, Mesh, mesh, rendering, light -->
### Light limits per renderer — Mobile and Compatibility cap at 8 per mesh
The number of lights that can affect a single mesh depends on the renderer:
- **Forward+**: 512 clustered elements (lights + decals + probes) in view — effectively unlimited for most scenes
- **Mobile**: max 8 OmniLights + 8 SpotLights per mesh resource (hard limit, cannot be changed)
- **Compatibility**: same 8+8 per-mesh limit (can be raised in Project Settings > Rendering > Limits > OpenGL at cost of performance)
Exceeding these limits silently drops some lights. For Mobile/Compatibility, use fewer dynamic lights and rely on baked lighting.


<!-- keywords: StandardMaterial3D, Material, material, OmniLight3D, light -->
### StandardMaterial3D emission does NOT light nearby objects by default
Setting `emission_enabled = true` and `emission_color` on a material makes the surface appear to glow, but it does NOT actually emit light onto nearby geometry unless:
- SDFGI or VoxelGI bakes the emission into GI, OR
- Screen-space indirect lighting is enabled (Forward+ only)
To make a glowing object actually light its surroundings, pair it with a small OmniLight3D at the same position.


<!-- keywords: Camera3D, Near, Camera, camera, property, 3D -->
### 3D Z-fighting fix: increase Camera3D Near property
Z-fighting (flickering surfaces) happens when two surfaces occupy the same depth buffer value. The depth buffer is non-linear — most precision is near the camera. To fix Z-fighting: **increase `Camera3D.near`** (e.g. from 0.05 → 0.1 or higher). Also decrease `Camera3D.far` to the minimum needed. Alternatively, move the overlapping surfaces apart in world space.


<!-- keywords: Transparency, Node3D, rendering, 3D -->
### 3D Transparency sorting: by Node3D origin, not vertex — fix with render_priority / sorting_offset
Transparent objects are sorted back-to-front by the **origin of the Node3D**, not by vertex positions. This causes incorrect overlap with large or oddly-shaped transparent meshes. Fix:
- `material.render_priority = N` — higher value = drawn in front of other transparent materials
- `visual_instance.sorting_offset = N` — shifts the object's depth for sorting purposes (positive = drawn later / in front)
Alpha transparent materials also do NOT appear in SSR or SSAO (normal-roughness buffer). Prefer Alpha Scissor for foliage/fences — it sorts correctly and can cast shadows.


<!-- keywords: StandardMaterial3D, Transparency, Material, material -->
### StandardMaterial3D: alpha blending is forced by more than just Transparency mode
Godot **automatically** switches a material to alpha blending (with all its limitations: no shadows, sorting issues, slower) if ANY of these are enabled:
- Transparency mode set to **Alpha**
- Blend mode set to anything other than **Mix** (Add, Sub, Mul, etc.)
- **Refraction** enabled
- **Proximity Fade** enabled
- **Distance Fade** set to **Pixel Alpha** mode
If you accidentally enable one of these properties, your material loses shadow casting ability silently.


<!-- keywords: WorldEnvironment, EDITOR, ONLY, Node, DirectionalLight3D, light, Environment -->
### WorldEnvironment preview sun/sky is EDITOR-ONLY — add nodes for game lighting
The default preview sun and sky you see in the 3D editor viewport are **NOT** visible in the running game. They exist only to help you see your scene during editing. To have sky and sun in the actual game, you must add:
- `WorldEnvironment` node with an `Environment` resource (for sky, fog, GI, post-processing)
- `DirectionalLight3D` node (for sunlight)
Only ONE `WorldEnvironment` node should exist per scene tree — adding more triggers a warning and unpredictable behavior. The background sky also affects ambient light and reflections, even if it's not directly visible on screen.


<!-- keywords: Texture, Image, Texture2D, texture -->
### Texture pixels not CPU-accessible directly — convert to Image first
A `Texture2D` stored in GPU video memory cannot have its pixel data read directly from GDScript. To read or modify pixels, call `texture.get_image()` to download to an `Image` (slow — avoid per-frame). Then use `image.get_pixel(x, y)` / `image.set_pixel(x, y, color)`. To upload modified pixels back: create a new `ImageTexture.create_from_image(image)`.


<!-- keywords: XR, AR -->
### PNG is 8-bit only — use EXR or HDR for high-dynamic-range images
PNG format is limited to 8 bits per channel in Godot (even if the source file is 16-bit). For HDR panorama skies or lightmaps, use `.exr` or `.hdr` format. JPEG does not support transparency. SVG: text must be converted to paths in the vector editor before importing, and complex SVGs may not render correctly.


<!-- keywords: Compatibility, Shader, shader, rendering -->
### Compatibility renderer: manually warm up shaders to avoid first-frame stutter
The Compatibility (OpenGL) renderer cannot use the ubershader approach used by Forward+/Mobile. Shaders compile the first time a mesh/material appears on screen, causing visible stutter. Workaround: **spawn all unique meshes and particle effects off-screen for one frame** at level load (behind a fullscreen ColorRect). Forward+ and Mobile handle this automatically since Godot 4.4 via ubershaders.


<!-- keywords: Pixel, Viewport, rendering, int -->
### Pixel art games: use viewport stretch mode + integer scale mode
For pixel art, set:
  Project Settings > Display > Window > Stretch:
    Mode = viewport       # render at base resolution, then scale
    Aspect = keep (or expand)
    Scale Mode = integer  # CRITICAL: prevents uneven pixel scaling
Without integer scale mode, a 640x360 viewport on a 1366x768 screen scales at 2.133x, making pixels appear inconsistently sized. With integer mode, it scales to exactly 2x (1280x720) with black bars. A good pixel art base: 640x360 (scales cleanly to 720p, 1080p, 1440p, 4K).


<!-- keywords: Camera, Keep, Height, Hor, FoV, Width, Vert, Camera3D, 3D -->
### 3D Camera FOV: default Keep Height (Hor+) widens FoV for widescreen; use Keep Width (Vert-) for portrait mobile
Camera3D.keep_aspect defaults to KEEP_HEIGHT: wider screens automatically see more horizontally (Hor+). This is correct for desktop and landscape mobile. For **portrait mobile games**, switch to KEEP_WIDTH (Vert-): taller screens see more vertically instead of getting a cropped view. Set via Inspector: Camera3D > Keep Aspect > Keep Width.


<!-- keywords: Viewport, EMPTY, RenderingServer, await, Texture, texture, rendering -->
### Viewport texture capture is EMPTY on first frame — await RenderingServer.frame_post_draw
Calling `get_viewport().get_texture().get_image()` in `_ready()` or at the start of the first frame returns an empty image because rendering hasn't happened yet. To capture a screenshot or viewport contents, wait for the frame to finish:
  await RenderingServer.frame_post_draw
  var img = get_viewport().get_texture().get_image()


<!-- keywords: Renderer, Forward, Compatibility, rendering -->
### Renderer capabilities: know what requires Forward+ vs Compatibility
Key features ONLY available in specific renderers:
- Forward+ only: VoxelGI, SDFGI, SSR (screen-space reflections), SSIL, TAA, FSR2, PCSS for DirectionalLight, normal/roughness buffer, sub-surface scattering, volumetric fog
- Forward+ and Mobile only: Decals, particle trails, depth-of-field blur, MSAA 2D, FXAA, SMAA, light projector textures, compositor effects
- Compatibility only renderer for: Web platform (no other option), very old hardware without Vulkan/D3D12/Metal
- Compatibility shader limitation: no ubershader → must manually warm up shaders (see above)
When writing code that uses advanced effects, always check if the target renderer supports them. The renderer is set per-project but can be overridden at runtime on some platforms.


<!-- keywords: BackBufferCopy, Node, Texture, texture, Shader, shader, int, 2D -->
### hint_screen_texture in 2D: overlapping nodes with this shader don't see each other — use BackBufferCopy
In 2D, when Godot sees a node using `hint_screen_texture`, it copies the entire screen to a back buffer exactly ONCE before drawing that node. Later nodes using the same hint don't get a new copy — they see the same original screen (without earlier hint_screen_texture nodes applied). This means two overlapping screen-reading shader objects won't see each other's effects. Fix: place a `BackBufferCopy` node between them in the scene tree to force an additional screen copy. In 3D, the screen texture is captured once after opaque geometry but BEFORE transparent geometry — transparent objects won't appear in the screen texture.


<!-- keywords: Shader, shader, light -->
### Shader light() function disabled on mobile by default — vertex lighting
The `light()` processor function in spatial shaders will NOT run if:
- The shader has `render_mode vertex_lighting` set
- **Project Settings > Rendering > Quality > Shading > Force Vertex Shading** is enabled (which is the DEFAULT on mobile platforms)
If your shader uses a custom `light()` function for effects like rim lighting or custom specularity, these will silently disappear on mobile. Verify this setting for mobile exports. On desktop, this setting is off by default.


<!-- keywords: AVOID, Transform3D, Basis, Quaternion, property, Node3D, 3D, rotation -->
### 3D rotations: AVOID using the .rotation property — use Transform3D/Basis/Quaternion
Euler angles (.rotation on Node3D) have two fundamental problems in 3D:
1. **Axis order dependency**: The final rotation depends on which axis is rotated first. Rotating Y then X gives a different result than X then Y (FPS camera needs Y-first for correct behavior).
2. **Gimbal lock**: When two axes align, a degree of freedom is lost.
3. **Non-linear interpolation**: Lerping Euler angles can rotate the wrong direction (the 270°→0° vs 270°→360° problem).
Use `transform.basis` (or Quaternion / Transform3D) for rotations in game code. Godot's 3D convention: X=Right, Y=Up, Z=Back (toward camera).


<!-- keywords: Node, rendering, 3D -->
### 3D rendering: transparent objects sort by node position, not vertex — use render_priority
Transparent materials in Godot are sorted back-to-front by the **node's origin position**, not by individual vertex distance. This causes incorrect sorting when:
- Two transparent objects overlap
- A single large transparent mesh has parts at different distances
Fix with `material.render_priority` (higher = rendered in front of other transparents) or `VisualInstance3D.sorting_offset`. Better alternatives to alpha blending:
- **Alpha Scissor**: for textures with hard transparent/opaque edges (no sorting, faster, slight aliasing)
- **Depth Pre-Pass**: renders the opaque silhouette first, then blends
- **Pixel/Object Dither**: for distance fade effects (no actual transparency blending)
Note: transparent objects don't appear in the normal-roughness buffer, so screen-space effects like SSR won't affect them.


<!-- keywords: INCREASING, Camera, Near, Far, rendering, Camera3D, 3D -->
### 3D rendering: Z-fighting — fix by INCREASING Camera Near, not decreasing Far
Z-fighting (flickering textures) occurs when two objects map to the same depth buffer value. The depth buffer is 24-bit on desktop, sometimes 16-bit on mobile. The precision is NON-LINEAR — it's much denser near the camera and sparse far away. To fix Z-fighting:
- **Increase Camera3D.near** (minimum clip distance): moves depth precision to start further out, giving more precision in the distance. This has the greatest impact.
- Decrease Camera3D.far only slightly helps compared to near.
- On mobile (16-bit depth), Z-fighting is much more common. Keep near as high as possible.


<!-- keywords: Texture, texture, rendering, 3D, Mobile -->
### 3D rendering: mobile textures max 4096x4096; use power-of-two for repeating textures
Mobile GPU texture constraints:
- Maximum texture size: typically 4096×4096 (some mobile: 2048×2048)
- **Non-power-of-two textures may not repeat** on some mobile GPUs. If a texture needs to tile, keep its dimensions at powers of 2 (64, 128, 256, 512, 1024, 2048, 4096)
- **VRAM texture compression does NOT work for transparent textures on Android** (only opaque). Transparent textures on Android may use more memory than expected
- **VRAM compression should be DISABLED for pixel art** — the compression artifacts are very visible at low resolution without any performance benefit


<!-- keywords: Forward, Mobile, Texture, texture, rendering, int, 3D -->
### 3D rendering: color banding — enable debanding for Forward+/Mobile, or bake noise into textures
Color banding (visible 'steps' in gradients, especially in dark areas or large solid-color surfaces) occurs because Godot renders in HDR internally but outputs to a lower-precision buffer. Severity by renderer:
- **Forward+**: best precision, enable `use_debanding` in Project Settings > Rendering > Anti Aliasing to apply a cheap fullscreen post-process fix
- **Mobile**: lower precision than Forward+, also supports debanding post-process
- **Compatibility**: lowest precision (no HDR), affects both 3D and 2D smooth gradients. Debanding must be done via custom shader or baking noise into textures


<!-- keywords: Mobile, OmniLights, SpotLights, MESH, Mesh, mesh, rendering, light, 3D, RESOURCE, scene, Resource -->
### 3D lights: Mobile renderer hard limit of 8 OmniLights + 8 SpotLights PER MESH
Light limits vary by renderer:
- **Forward+**: Up to 512 combined OmniLights + SpotLights + Decals + ReflectionProbes in camera view (adjustable in Project Settings > Rendering > Limits > Cluster Builder). Essentially unlimited lights as long as performance allows.
- **Mobile**: Hard limit of **8 OmniLights + 8 SpotLights per mesh resource** (not per scene, per mesh). Also max 256 per view. These limits CANNOT be changed. Lights exceeding the limit pop in/out during camera movement.
- **Compatibility**: 8 OmniLights + 8 SpotLights per mesh (can be increased in Project Settings > Rendering > Limits > OpenGL at performance cost).
- All renderers: max **8 DirectionalLights** simultaneously. Each additional one with shadows reduces ALL shadow atlas resolution.
Fix: use baked lightmaps, reduce dynamic lights, or split meshes (also improves culling).


<!-- keywords: Light, Cull, Mask, light, Shadow, Caster, STILL, DirectionalLight3D, 3D -->
### 3D lights: Light Cull Mask ≠ Shadow Caster — excluded objects STILL cast shadows
A common confusion: the light's **Cull Mask** controls which objects RECEIVE illumination from the light. Objects NOT in the cull mask won't be lit, but they will **still cast shadows** onto lit objects. To also prevent an object from casting shadows, change the object's **GeometryInstance3D > Cast Shadow** property, or adjust the light's **Shadow Caster Mask** (if available). DirectionalLight3D also has a **Shadow Max Distance** — keep this as LOW as possible for the best shadow quality and performance (fewer objects need shadow maps). The DirectionalLight3D's **position in the scene doesn't matter** — only its rotation (direction) does.


<!-- keywords: Compatibility, light, 3D -->
### 3D lights (Compatibility): enabling shadows may drastically change light appearance
On the Compatibility renderer (OpenGL), enabling shadows on a light causes it to render in **sRGB color space** instead of linear space (due to mobile hardware limitations with multi-pass rendering). This can make the light appear significantly darker or different in color. To achieve a similar appearance to the unshadowed version, you may need to increase the light's **Energy** value after enabling shadows.


<!-- keywords: StandardMaterial3D, Alpha, Material, material -->
### StandardMaterial3D: transparency mode 'Alpha' disables shadow casting and SSR
When a material's transparency is set to **Alpha** (alpha blending), the mesh:
- Cannot cast shadows (even if Cast Shadow is On)
- Is not visible in screen-space reflections (SSR)
- Is not written to the normal-roughness buffer
- Is automatically sorted back-to-front (by node origin position, not vertices) causing ordering issues
Use these alternatives for shadow-casting transparent meshes:
- **Alpha Scissor**: hard cut-off (foliage, fences) — CAN cast shadows, fastest
- **Alpha Hash**: dithered (realistic hair) — CAN cast shadows
- **Depth Pre-Pass**: opaque silhouette first, then blends — CAN cast shadows
Also note: Godot **forces Alpha blending** automatically if you enable Refraction, Proximity Fade, or Distance Fade — even if you didn't set the transparency mode explicitly.


<!-- keywords: Visibility, Fade, Self, Dependencies, rendering -->
### Visibility ranges (LOD): Fade mode 'Self' and 'Dependencies' force transparent rendering
GeometryInstance3D's visibility range (manual LOD) has a Fade Mode:
- **Disabled**: instant switch with hysteresis (no transparency cost) — best performance
- **Self**: alpha-blends the node out near its visibility boundary — forces transparent rendering during transition
- **Dependencies**: the parent node fades in its child nodes when it reaches its visibility limit — intended for HLOD setups
Visibility range distances are measured from the camera to the **AABB center** of the node, not any vertex. Use **Visibility Parent** for HLOD: child nodes automatically hide when the parent (distant LOD mesh) is visible. The visibility parent doesn't need to be a scene tree parent.


<!-- keywords: Scene, scene, import, resource -->
### OBJ files do NOT get automatic LOD generation — change import type to 'Scene'
By default, OBJ files are imported as individual mesh resources (not 3D scenes), so Godot's automatic mesh LOD generation is skipped. To enable LOD for OBJ files: select the OBJ in FileSystem dock → Import dock → change **Import As** to **Scene** → click **Reimport** (requires editor restart). GLTF, .blend, Collada, and FBX files automatically get LOD meshes generated on import.


<!-- keywords: MultiMeshInstance3D, SAME, instantiate, mesh -->
### MultiMeshInstance3D: ALL instances use the SAME LOD level simultaneously
LOD selection for MultiMeshInstance3D (and GPUParticles3D, CPUParticles3D) is based on the distance from the camera to the **closest point of the node's AABB**. All instances in the MultiMesh share that single LOD decision — you can't have some instances at LOD0 and others at LOD2. If instances are spread far apart, split them into separate MultiMeshInstance3D nodes for independent LOD. Also: GPUParticles3D needs **GPUParticles3D > Generate AABB** baked for correct LOD distance calculation.


<!-- keywords: Occlusion, MultiMesh, GPUParticles, Material, material, MeshInstance3D, mesh, CSG, GPUParticles3D, particles -->
### Occlusion culling baking excludes: MultiMesh, GPUParticles, CSG, and transparent materials
When baking occluders with OccluderInstance3D, only **MeshInstance3D nodes with opaque materials** are included in the bake. The following are NOT automatically baked as occluders:
- MultiMeshInstance3D, GPUParticles3D, CPUParticles3D
- CSG nodes (can be manually included after converting to MeshInstance3D in Godot 4.4+)
- Meshes with transparent materials (even if the texture is visually 100% opaque)
For these, manually add OccluderInstance3D with hand-placed primitive shapes. Also: the occludee's **entire AABB must be FULLY occluded** by the occluder shape to be culled — partial occlusion is insufficient. Moving OccluderInstance3D nodes at runtime is expensive (BVH rebuild); toggle visibility instead.


<!-- keywords: Compute, Forward, Mobile, Compatibility, Shader, shader, rendering -->
### Compute shaders only work with Forward+ or Mobile renderer, not Compatibility
Compute shaders require `RenderingServer.create_local_rendering_device()` which only works on the **Forward+** or **Mobile** renderer. The Compatibility renderer does not support compute shaders. Additionally:
- Compute shader support is **poor on mobile devices** due to driver bugs, even if technically supported
- Local RenderingDevice instances **cannot be debugged with RenderDoc**
- RIDs created via RenderingDevice are **NOT freed automatically** — you must call `rd.free_rid()` on each buffer, pipeline, and uniform set
- `rd.sync()` blocks the CPU until GPU finishes — for performance, wait **2-3 frames** before calling sync
- Long GPU computations (5-10 seconds) trigger **Windows TDR** (driver crash/reset) — split into multiple dispatches


<!-- keywords: WorldEnvironment, EDITOR, ONLY, scene, Environment, Tree -->
### WorldEnvironment: only ONE allowed per scene tree; preview sky is EDITOR-ONLY
Only one WorldEnvironment node can exist in the active scene tree — adding more generates a warning and the extras are ignored. The **preview environment and sun** shown in the editor's 3D viewport is ONLY visible in the editor, NOT in the running project. If no WorldEnvironment or DirectionalLight3D is in the scene at runtime, the sky will be black. Use the 'Add Sun to Scene' / 'Add Environment to Scene' buttons in the preview dialog to add them as real nodes. Also: the background sky affects ambient and reflected light on all objects even when the sky is never directly visible on screen.


<!-- keywords: CanvasModulate, DirectionalLight2D, canvas, light, 2D -->
### 2D lights: background color is unlit; CanvasModulate required; DirectionalLight2D shadows are infinitely long
Non-obvious 2D lighting gotchas:
- The **background color** (project background) does NOT receive 2D lighting. Add a Sprite2D for the background to light it.
- Without **CanvasModulate**, 2D lights only add brightness to the already-fully-lit unshaded scene (which looks fully bright). Add a CanvasModulate with a dark color to define the 'ambient darkness' that lights reveal.
- DirectionalLight2D shadows are **always infinitely long** regardless of the Height property — this is a rendering limitation.
- 2D light/shadow rendering uses the **Viewport's pixel resolution**, not sprite texel resolution. Nearest (pixel) texture filtering will NOT make shadows pixelated. Use a custom shader to snap LIGHT_VERTEX to a pixel grid.
- Enabling **normal maps** on 2D sprites makes lights appear weaker (because the surface angle now matters). Increase the light's **Height** property to compensate.
- PointLight2D **Offset** changes the position of the light texture but does **NOT** move the shadow source — only moving the node moves shadows.


<!-- keywords: SubViewport, audio, rendering, Viewport, Camera2D, Camera3D, Camera, Input, input -->
### SubViewport: no automatic input; needs audio listener enabled; camera renders to nearest parent viewport
SubViewport non-obvious behavior:
- SubViewports do **not** receive input automatically unless they are a direct child of a **SubViewportContainer**.
- To hear positional 3D or 2D audio from a SubViewport, enable **Audio Listener 2D/3D** on the SubViewport.
- A Camera3D/Camera2D always renders to the **closest parent Viewport** in the node hierarchy — not the root viewport. Cameras inside a SubViewport subtree render to that SubViewport, not to the screen.
- Only **one camera can be active per Viewport**. With multiple cameras, call `camera.make_current()` or set the `current` property.


<!-- keywords: Compatibility, Mesh, mesh, Shader, shader, rendering -->
### Compatibility renderer: shader stutter requires pre-warming all meshes for 1 frame during loading
Forward+ and Mobile renderers (Godot 4.4+) use an ubershader approach to minimize shader compilation stutter. The **Compatibility** renderer (OpenGL-based) cannot use this approach and will stutter the FIRST time any new mesh/material/particle is rendered. Workaround: during level loading, spawn ALL meshes and visual effects in front of the camera for **one frame** (hidden behind a fullscreen UI/ColorRect) to force shader compilation before gameplay starts.


<!-- keywords: VoxelGI, Forward, VoxelGIData, Mode, Static, Mesh, MeshInstance3D, mesh, static -->
### VoxelGI: Forward+ only; save VoxelGIData as .res not .tres; mesh must have GI Mode = Static
VoxelGI is supported **only** in the Forward+ renderer — it does NOT work in Mobile or Compatibility. Before baking:
- Static geometry must be imported with **Light Baking** set to **Static** or **Static Lightmaps** in the Import dock, OR have **Global Illumination > Mode = Static** set in the MeshInstance3D inspector.
- Always save the VoxelGIData resource as an **external .res file** (binary resource), not .tres (text). Using text format embeds large binary data in the scene file, making it huge and slow to load.


<!-- keywords: LightmapGI, light -->
### LightmapGI: only bakes siblings/children; UV2 slot reserved; no reflections included
Non-obvious LightmapGI limitations:
- LightmapGI **only bakes nodes that are siblings or children** of the LightmapGI node — it does NOT bake the entire scene. Use multiple LightmapGI nodes for different areas.
- After baking, the **UV2 slot is reserved** for lightmap data. You cannot use UV2 for other purposes in materials or custom shaders on those meshes.
- LightmapGI does **NOT** provide reflections — you must also add **ReflectionProbe** nodes for interiors or use a Sky for exteriors.
- Lightmap baking is **NOT supported in the web editor** (use desktop editor to bake, then render the result on web).
- For GridMap lightmaps: the lightmap texel size setting must be changed BEFORE converting the scene to a MeshLibrary — it cannot be changed afterward.


<!-- keywords: MeshLibrary, MeshInstance3D, scene, Node, Material, material, Mesh, mesh -->
### MeshLibrary: materials must be in the mesh's slots, not MeshInstance3D node slots
When creating a MeshLibrary scene for GridMap:
- Materials must be assigned in the **mesh resource's material slots** (via the Mesh property), **NOT** in the MeshInstance3D node's material override slots. Node materials are **ignored** during MeshLibrary export.
- Each MeshLibrary item's root must be a MeshInstance3D — only the visual mesh is exported. Allowed children: one StaticBody3D (for physics), one NavigationRegion3D (for navmesh). Other node types are silently ignored.
- GridMap is NOT a general-purpose 'nodes on a grid' system — it places optimized meshes only.


<!-- keywords: Texture2DArray, CubemapArray, Texture, texture, Shader, shader, 2D -->
### Texture2DArray and CubemapArray cannot be displayed without a custom shader
Image import type gotchas:
- **Texture2DArray** and **CubemapArray**: Godot's built-in 2D/3D shaders cannot display these — you must write a custom shader to sample and display them.
- **SVG**: Text elements in SVG files must be **converted to paths** before importing, or they will not appear in the rasterized result.
- **JPEG**: Does NOT support transparency. Use PNG or WebP for transparent images.
- **PNG**: Limited to **8 bits per channel** — no HDR support. Use .exr or .hdr for HDR images.
- **Textures stored in video memory**: Pixel data cannot be read back directly from CPU. Convert to Image first using `texture.get_image()` if you need CPU access.


<!-- keywords: Mesh, mesh, 3D, import -->
### 3D import name suffixes: -col keeps mesh; -colonly removes mesh; -loop needs no hyphen
3D scene name suffixes (case-insensitive, accept -, $, or _ as separator):
- `-col`: add trimesh StaticBody child, **keep visual mesh**
- `-colonly`: add trimesh StaticBody child, **REMOVE visual mesh** (for collision-only geometry)
- `-convcol`: add convex CollisionShape child, keep visual mesh
- `-convcolonly`: add convex CollisionShape, remove visual mesh
- `-navmesh`: convert to NavigationMesh, REMOVE visual mesh
- `-noimp`: remove the entire node on import
- `-occ`: keep mesh AND add OccluderInstance3D
- `-occonly`: remove mesh, add OccluderInstance3D only
- `-rigid`: make the node a RigidBody3D
- `-vehicle` / `-wheel`: wrap in VehicleBody3D / VehicleWheel3D
Animation loop: naming clips with **'loop' or 'cycle'** (prefix or suffix, NO hyphen required) imports them as looping. Note: in Blender NLA Editor, action must be named with loop/cycle prefix or suffix.


<!-- keywords: StandardMaterial3D, Disabled, Texture, texture, Material, material -->
### StandardMaterial3D: transparency is Disabled by default; transparent texture is invisible unless you change it
In Godot, materials are fully opaque by default. If your albedo texture has transparent pixels, they won't show until you change Transparency mode:
- **Alpha**: Full transparency, but no shadow casting, not in SSR, not in most reflections. Slower to render.
- **Alpha Scissor**: Hard cutout (all-or-nothing). Casts shadows. Best for foliage/fences.
- **Alpha Hash**: Dithered cutout. Casts shadows. Best for hair.
- **Depth Pre-Pass**: Mixed opaque + alpha blend. Mostly correct sorting. Casts shadows.
Also: Blender exports materials with Backface Culling DISABLED by default — enable it in Blender before exporting to avoid wasted GPU rendering backfaces in Godot.


<!-- keywords: ReflectionProbe, Mobile, Compatibility, Mesh, mesh -->
### ReflectionProbe: Mobile limit is 8 per mesh, Compatibility limit is 2 per mesh
- Forward+: 512 clustered elements limit in view (probes share this budget with lights/decals)
- Mobile: only 8 ReflectionProbes applied per mesh resource
- Compatibility: only 2 ReflectionProbes applied per mesh resource
- ReflectionProbe.max_distance controls what objects appear INSIDE the reflection (not the probe's own visible range)
- For probe blending: extents of neighboring probes must OVERLAP (only a few units needed)
- Enable Shadows on a probe in 'Always' update mode is very expensive; leave disabled unless necessary


<!-- keywords: Volumetric, Forward, ONLY, FogVolumes, SUBTRACT, global -->
### Volumetric fog is Forward+ ONLY; FogVolumes can ADD or SUBTRACT from global fog density
Volumetric fog is not available in Mobile or Compatibility renderers. FogVolumes affect fog density in a local area:
- Set FogVolume density positive to ADD fog in an area
- Set FogVolume density negative to REMOVE/subtract fog in an area (e.g., clear zones inside buildings)
- Volumetric fog emission adds ambient color but does NOT cast light on other surfaces
- Set Density=0 globally to have ONLY FogVolumes visible (local fog without global fog)


<!-- keywords: Decals, Compatibility, Normal, Albedo, Mix, rendering -->
### Decals are NOT supported in Compatibility renderer; Normal/ORM-only decals need Albedo Mix=0
- Decals require Forward+ or Mobile renderer. For Compatibility renderer, use Sprite3D instead.
- Decal Y-axis extent controls projection LENGTH — keep as short as possible for better culling performance.
- Normal Fade > 0 prevents projecting on non-facing surfaces (useful for floors/walls). 0 = projects on everything.
- For footsteps/wet puddles (normal+ORM only): set Albedo Mix = 0.0. Setting it to 0 doesn't reduce ORM/normal impact.


<!-- keywords: Parallax2D, Texture, texture -->
### Parallax2D: textures must have top-left at (0,0), NOT centered — centering breaks infinite repeat
Using Parallax2D (preferred over deprecated ParallaxBackground/ParallaxLayer):
- The 'infinite repeat canvas' starts at (0,0) and expands DOWN and RIGHT. Centering textures at origin causes partial repeat.
- repeat_size must match your TEXTURE size (not viewport size). Use scroll_offset to start at a different position.
- If camera zoom changes (Camera2D.zoom != 1), increase repeat_times so texture still covers screen when zoomed out.
- For split-screen: duplicate parallax nodes in each SubViewport; use visibility_layer + Viewport canvas_cull_mask to isolate them.


<!-- keywords: Screen, ONCE, Node, Texture, texture, Shader, shader, 2D -->
### Screen-reading shaders: in 2D screen texture copied only ONCE; overlapping nodes won't see each other
When hint_screen_texture is used in 2D, Godot copies the screen once for the first node that needs it. Subsequent overlapping nodes share the same copy — they won't see the first node's output. This causes the 'disappearing object' effect.
In 3D, screen texture is captured AFTER opaque geometry pass but BEFORE transparent pass — transparent objects are not in the screen texture.
textureLod(screen_texture, uv, LOD > 0) requires a mipmap-enabled filter (filter_nearest_mipmap or similar); with filter_nearest, LOD > 0 has no effect.


<!-- keywords: Spatial, RECEIVING, Shader, shader, particles -->
### Spatial shader: 'shadows_disabled' blocks RECEIVING shadows, NOT casting; 'fog_disabled' needed for blend_add particles
Spatial shader render mode gotchas:
- `shadows_disabled`: the mesh stops RECEIVING shadows from lights, but still CASTS shadows onto other surfaces
- `specular_disabled`: disables direct light specular highlights only. For no reflections at all, also set SPECULAR = 0.0 in fragment()
- `fog_disabled`: prevents fog from affecting the material. Essential for blend_add particles — otherwise fog multiplies incorrectly
- Stencil buffer read is only possible in the TRANSPARENT pass. Stencil reads in the opaque pass silently fail.


<!-- keywords: Compatibility, ONLY, scene, rendering, export -->
### Compatibility renderer is the ONLY option for web export; switching renderers may need manual scene adjustments
Renderer selection by platform:
- **Forward+**: Desktop only (default on desktop). Uses Vulkan/D3D12/Metal. Most features.
- **Mobile**: Mobile/desktop/XR. Uses Vulkan/D3D12/Metal. Good balance.
- **Compatibility**: Web/older devices. Uses OpenGL. REQUIRED for web export. Widest hardware support.
Switching Forward+ ↔ Mobile: minor tweaks needed. Switching to/from Compatibility: significant differences in lighting, shadows, effects.


<!-- keywords: GLSL, Godot, VERTEX, FRAGCOORD, Shader, shader -->
### GLSL to Godot shaders: VERTEX is model-space (auto-converted), UV Y is flipped vs FRAGCOORD, #include only .gdshaderinc
When porting GLSL/Shadertoy shaders to Godot:
- Godot VERTEX is model space; Godot handles model→clip conversion automatically (unlike gl_Position which is clip space)
- Shadertoy iResolution = 1.0 / SCREEN_PIXEL_SIZE in Godot
- UV y-coordinate is flipped compared to FRAGCOORD
- Shader #include only works with .gdshaderinc files (max depth 25)
- SCREEN_TEXTURE removed in Godot 4; use sampler2D with hint_screen_texture instead


<!-- keywords: CanvasItem, REPLACES, INVERTED, Shader, shader, canvas, light, 3D, 2D -->
### CanvasItem shader: defining light() REPLACES built-in lighting even if empty; 3D normal maps appear INVERTED in 2D
CanvasItem shader gotchas:
- If you define a light() function, it completely replaces the built-in light function, even if the body is empty. Use 'unshaded' render mode to skip lighting entirely.
- COLOR in fragment() already includes TEXTURE color multiplication. Writing `COLOR = COLOR;` is equivalent to an empty fragment() function.
- 3D normal maps appear inverted in 2D. Assign to NORMAL_MAP (not NORMAL directly) and Godot will convert automatically.
- TIME repeats every 3600 seconds (configurable). It's affected by time_scale but NOT by pausing.


<!-- keywords: Transparent, Node3D, POSITION, rendering -->
### Transparent objects sorted by Node3D POSITION, not vertex position — overlapping transparent objects render in wrong order
Godot sorts transparent materials back-to-front using the Node3D's origin, NOT per-vertex depth. Overlapping transparent meshes will frequently sort incorrectly. Workarounds:
- Use material Render Priority to force ordering between specific materials
- Use VisualInstance3D.sorting_offset to shift sort depth
- Use Alpha Scissor instead of alpha blend for mostly-opaque textures (also faster)
- Transparent objects are NOT rendered to the normal-roughness buffer, so SSR/SSAO won't affect them.


<!-- keywords: Shader, EVERYWHERE, shader, GLSL, error -->
### Shader #define with trailing semicolon inserts semicolons EVERYWHERE it's used — causes silent syntax errors
A common shader preprocessor mistake:
```glsl
// BAD — the semicolon becomes part of the replacement
#define MY_COLOR vec3(1, 0, 0);
// Expands to: ALBEDO = vec3(1, 0, 0);; (double semicolon, or worse in expressions)

// GOOD — no trailing semicolon in #define
#define MY_COLOR vec3(1, 0, 0)
```
Also: #elifdef is NOT supported in Godot shaders. Use nested #ifdef/#else instead. Since 4.4, use CURRENT_RENDERER built-in define for renderer-specific shader code.


<!-- keywords: Depth, Godot, REVERSED, rendering -->
### Depth buffer in Godot 4.3+ uses REVERSED-Z: near plane is 1.0, far is 0.0; NDC Z-range differs by renderer
Post-processing shaders accessing depth_texture must account for reversed-Z. The full-screen quad vertex shader must use:
```glsl
POSITION = vec4(VERTEX.xy, 1.0, 1.0); // 1.0 for near plane (reversed-Z)
// NOT vec4(VERTEX, 1.0) which was the old pre-4.3 code
```
NDC Z-range: Forward+/Mobile (Vulkan) = [0.0, 1.0]; Compatibility (OpenGL) = [-1.0, 1.0]. Use CURRENT_RENDERER define for cross-renderer shaders.


<!-- keywords: MSAA, EDGES, TEXTURE, Texture, texture, sprite, Shader, shader, int, 2D -->
### 2D MSAA only affects geometry EDGES and sprite TEXTURE edges — not pixel art interiors, shaders, or fonts
2D MSAA increases coverage samples but NOT color samples. It will NOT antialias: pixel art texture interiors, custom 2D shader output, specular aliasing from Light2D, or font rendering. For Line2D, use the built-in Antialiased property instead (lower cost). MSAA 2D is a SEPARATE setting from MSAA 3D. MSAA 2D is Forward+/Mobile only (not Compatibility).


<!-- keywords: MANIFOLD, Mesh, MeshInstance3D, mesh, CSG -->
### CSG meshes must be MANIFOLD (closed, watertight) — open meshes produce garbage results; CSG is prototyping-only
CSG (Constructive Solid Geometry) boolean operations require manifold (closed, watertight) meshes. Non-manifold meshes produce undefined behavior. Additional gotchas:
- CSG is NOT recommended for final game geometry — performance is poor vs static meshes
- Use 'Mesh > Bake Mesh' to convert CSG to a real MeshInstance3D for export
- CSGMesh3D wraps an existing Mesh resource in CSG, but requires the mesh to be manifold
- CSG nodes cannot use physics materials directly (bake first, then add StaticBody3D)


<!-- keywords: Sky, TIME, EVERY, Shader, shader -->
### Sky shader runs up to 6 times per frame; using TIME forces cubemap update EVERY frame
The sky shader executes for: full-res background, half-res pass, quarter-res pass, and all 6 faces of the radiance cubemap. Gotchas:
- Using TIME in a sky shader forces a radiance cubemap update EVERY frame — multiply your shader cost by 6+
- RADIANCE cubemap can ONLY be sampled during the background pass — sampling it during AT_CUBEMAP_PASS returns garbage
- ANY uniform change triggers a full radiance cubemap recalculation
- Use AT_CUBEMAP_PASS bool to skip expensive calculations: `if (!AT_CUBEMAP_PASS) { ... expensive stuff ... }`
- Set Sky.process_mode = PROCESS_MODE_REALTIME only when the sky actually changes at runtime


<!-- keywords: Fog, DENSITY, ALBEDO, EMISSION, Shader, shader -->
### Fog shader: DENSITY must be written or ALBEDO/EMISSION are completely ignored
FogVolume shader gotchas:
- If you only write to ALBEDO or EMISSION but forget DENSITY, the shader produces NO output
- Fog shader runs once per FROXEL (volumetric voxel) touched by the FogVolume's AABB — not per pixel
- A FogVolume that barely overlaps a froxel still runs the shader for that entire froxel
- Detail degrades with distance from camera (froxels get larger farther away)


<!-- keywords: Label3D, CANNOT, Cast, Shadow, Alpha, Cut, 3D -->
### Label3D CANNOT cast shadows regardless of Cast Shadow setting — use Alpha Cut for shadows (loses smoothness)
Label3D generates transparent quads internally (same as Sprite3D). Shadow casting is blocked for transparent geometry:
- Cast Shadow = On has NO effect on Label3D
- Workaround: use 'Alpha Cut' transparency mode to enable shadows, but text edges become jagged
- 'Opaque Pre-Pass' mode enables smooth shadows but causes transparency sorting artifacts
- TextMesh (3D mesh from text) supports shadows normally but does NOT support bitmap fonts (.fnt) — only TTF/OTF/WOFF
- Fonts with self-intersecting outlines (common in Google Fonts) render incorrectly in TextMesh — use official font source


<!-- keywords: MSAA, light -->
### MSAA does NOT antialias alpha scissor edges or specular highlights — only geometric silhouettes
3D antialiasing gotchas:
- MSAA only increases coverage samples; fragment shaders run ONCE per pixel. Alpha scissor (1-bit transparency) is completely unaffected by MSAA — must enable alpha antialiasing per-material
- TAA ghosting gets worse at lower framerates (slower convergence = more persistent ghost trails)
- FSR2 at NATIVE resolution is SLOWER than standard TAA — only use FSR2 if you're also lowering resolution for upscaling
- SSAA 2x scale = 4x pixels (per-axis!); 2x SSAA at 4K renders at 8K internally and can exhaust VRAM


<!-- keywords: SDFGI, Forward, Bounce, Feedback, rendering -->
### SDFGI only works in Forward+ renderer; Bounce Feedback above 0.5 causes infinite brightness feedback loop
SDFGI (Signed Distance Field Global Illumination) gotchas:
- Only available in Forward+ renderer — silent failure in Mobile or Compatibility renderers
- Bounce Feedback above 0.5 triggers exponential brightness feedback, making the scene blindingly bright within seconds. No warning.
- Modifying a Static GI mesh at runtime does NOT update SDFGI until the camera moves away and back into range
- GI takes 25 frames to converge after scene loads — causes visible flickering (no automatic fade)
- Fast camera movement degrades SDFGI quality significantly (cascade shift artifacts)
- Transparent materials use rough reflections regardless of their actual roughness value


<!-- keywords: Runtime, GLTFState, Texture, texture, GLTF -->
### Runtime glTF loading from buffer requires manually setting GLTFState.base_path or textures won't load
Runtime file loading gotchas:
- When loading glTF from bytes (append_from_buffer()), set `gltf_state.base_path` manually to the folder containing textures. From file, it's automatic; from buffer, it's not.
- Not all .ogg files are Ogg Vorbis — some are Ogg Theora (video) or Opus. AudioStreamOggVorbis.load_from_file() will fail silently on these
- VideoStreamPlayer: setting stream to null then back to a video breaks autoplay — must call play() explicitly even if autoplay is enabled
- ZIPReader.get_files() returns files in UNSORTED order — sort explicitly if processing order matters


<!-- keywords: Sync, XR -->
### XR: V-Sync must be disabled or framerate is capped at monitor refresh; initialize() must NOT be called multiple times
XR setup gotchas:
- V-Sync enabled at 60Hz caps OpenXR output to 60 FPS instead of the required 90+ FPS. Disable V-Sync for all XR projects
- Physics runs at 60 Hz by default; XR often runs at 90 Hz. Set `Engine.physics_ticks_per_second` to match XR framerate or physics feels choppy
- Calling initialize() multiple times across scene changes has 'unpredictable effects' — load levels as sub-scenes instead of calling initialize() in each scene
- A registered XR interface does NOT mean it's initialized successfully. Always check is_initialized() explicitly — registration only means the interface is available


<!-- keywords: EVERY, FRAME, Filmic, ACES -->
### HDR output: output_max_linear_value changes EVERY FRAME — never cache it; Filmic/ACES tonemappers ignore HDR entirely
HDR output gotchas:
- output_max_linear_value changes every frame as brightness/HDR settings change. Retrieve it each frame; caching will break HDR scaling
- Filmic and ACES tonemappers completely IGNORE output_max_linear_value and always produce SDR-range output — do not use them for HDR
- Mixing WorldEnvironment glow with output_max_linear_value causes glow strength to increase with higher max values (undesirable)
- HDR screens may do their own dynamic tonemapping (DTM) that dims the image when bright pixels exceed 1-10% of screen — unpredictable across devices


<!-- keywords: Godot, Upgrade, Only, Mesh, mesh -->
### Godot 4.2: mesh 'Upgrade Only' causes permanent per-launch upgrade cost; mesh format is one-way (can't open in 4.0/4.1)
Godot 4.2 upgrade gotchas:
- When asked to upgrade meshes, choosing 'Upgrade Only' (not 'Restart & Upgrade') upgrades in-memory ONLY — every project launch re-triggers the upgrade, permanently slowing load times
- The new 4.2 mesh format cannot be opened in Godot 4.0 or 4.1 — one-way upgrade
- AnimationTree.tree_root type changed from AnimationNode to AnimationRootNode — breaks C# source and binary compat with no compatibility shim
- GraphNode properties (comment, overlay, language, show_close) removed with no replacement — C# code using these won't compile


<!-- keywords: Bool, Float, Input, input, float, XR -->
### XR: Bool type from analog inputs unreliable — use Float with your own threshold; user binding overrides are allowed by spec
XR action map gotchas:
- XR runtimes do NOT guarantee sensible threshold for analog→Bool conversion. A trigger at 10% may register as pressed. Use Float type and apply your own threshold.
- XR runtimes are ALLOWED to let users customize/override your action bindings — your action map is a suggestion, not a guarantee
- No reliable way to know which physical controller the user has — you only know the profile, not the hardware
- Touch vs Click distinction (some controllers support both 'X touch' and 'X click') is not universal — relying on it breaks on unsupported devices


<!-- keywords: MeshDataTool, Mesh, mesh -->
### MeshDataTool: only works with PRIMITIVE_TRIANGLES; create_from_surface() silently clears existing data; must call commit_to_surface()
MeshDataTool gotchas:
- Only supports PRIMITIVE_TRIANGLES — silently fails or produces garbage with line/point/strip primitives
- create_from_surface() silently clears ALL existing data in the MeshDataTool instance without warning — data loss if called on initialized tool
- Changes to vertex data are NOT applied to the mesh until commit_to_surface() is explicitly called
- Manually accumulating face normals for vertex normals does NOT produce mathematically perfect smooth normals (only approximates)
- Significantly slower than direct ArrayMesh manipulation — use ArrayMesh when performance matters


<!-- keywords: LightmapGI, MUST, scene, Node, light, Control, import, resource -->
### LightmapGI: max 8 simultaneous nodes; UV2 lost on scene reimport; .unwrap_cache MUST be in version control
LightmapGI gotchas:
- Only 8 LightmapGI nodes can render simultaneously — having more causes flickering/popping with no warning
- LightmapGI only bakes SIBLINGS and DIRECT CHILDREN — not deeper descendants unless they're explicitly within scope
- UV2 generated via 'Mesh > Unwrap UV2' is LOST when the source scene is reimported. Store as separate resource.
- `.unwrap_cache` files MUST be committed to version control — ignoring them causes inconsistent UV2 results across machines/versions
- Lightmap baking is NOT supported in the web editor (graphics API limitation)


<!-- keywords: VoxelGI, Forward, ShaderMaterial, BLACK, Node, material, mesh, shader -->
### VoxelGI: Forward+ only; max 8 nodes, max 2 overlap; custom ShaderMaterial meshes bake as pure BLACK
VoxelGI gotchas:
- VoxelGI only works in Forward+ renderer — silent failure in Mobile or Compatibility
- Maximum 8 VoxelGI nodes render simultaneously (more = flickering)
- Only 2 VoxelGI nodes can BLEND at a single pixel — more than 2 overlapping causes flickering as camera moves
- Meshes using ShaderMaterial are treated as PURE BLACK during baking (only block light, emit nothing) — only StandardMaterial3D/ORMMaterial3D contribute color to baked GI
- BaseMaterial3D UV1 offset/scale, triplanar, and Emission > On UV2 properties are all IGNORED during VoxelGI baking


<!-- keywords: GridMap, MeshInstance3D, IGNORED, Node, Material, material, Mesh, mesh -->
### GridMap: materials on MeshInstance3D node are IGNORED — only materials embedded in the mesh are used
GridMap gotchas:
- When generating a MeshLibrary, materials assigned to the MeshInstance3D NODE (not embedded in the mesh resource) are silently ignored. Must embed materials in the mesh itself.
- Lightmap texel size must be set in Import dock BEFORE converting to MeshLibrary — changing it afterwards has no effect on existing library data
- NavigationMesh baked cell size must EXACTLY match the NavigationServer map cell size for proper merging — silent failure if mismatched
- Only MeshInstance3D, StaticBody3D, CollisionShape3D, NavigationRegion3D nodes are exported — all other node types are silently ignored


<!-- keywords: Viewport, EMPTY, SubViewport, rendering, 3D -->
### Viewport.get_texture().get_image() returns EMPTY on first frame; 3D shadows need positional_shadow_atlas_size > 0 (default 0)
Viewport gotchas:
- Viewport has no get_image(): use get_texture().get_image(). On the first frame that image is EMPTY. Must await RenderingServer.frame_post_draw signal before reading viewport texture.
- New Viewports have positional_shadow_atlas_size = 0 by default — 3D point/spot light shadows are completely invisible until this is set > 0
- Viewport texture is CLEARED every frame by default. For persistent drawing (e.g., paint canvas), set viewport.render_target_clear_mode = CLEAR_MODE_NEVER
- SubViewport does NOT receive mouse or touch input unless it has a SubViewportContainer as parent
- SubViewportContainer cannot be smaller than its child SubViewport's size (hard constraint)
- Only ONE camera per Viewport can be active — multiple cameras with current=true will conflict; use make_current() to switch


<!-- keywords: Compatibility, Sync, Shader, shader, rendering, FPS, delta -->
### Compatibility renderer: pre-spawn all shaders at level load to avoid runtime compilation stutter; V-Sync halves FPS on miss
Rendering/jitter gotchas:
- Compatibility renderer (OpenGL) does NOT use Godot's ubershader approach — shaders compile ON DEMAND the first time they're needed, causing frame stutter. Workaround: show a loading screen and force-render everything once before gameplay
- Double-buffered V-Sync drops to HALF refresh rate (e.g., 60Hz → 30 FPS) if you miss a frame. Use triple-buffering or adaptive V-Sync if you can't consistently hit the target
- Physics interpolation adds INPUT LAG for physics-controlled objects (player movement). Only enable if visual jitter is worse than acceptable lag
- Different physics_ticks_per_second values produce DIFFERENT simulation outcomes even with consistent delta — let players change this in competitive games and they gain unfair physics advantages


<!-- keywords: Apply, Root, Scale, scene, Node, Mesh, mesh, int, Node3D, 3D, import, resource -->
### 3D import: 'Apply Root Scale' bakes scale into mesh data permanently; inherited scenes cannot delete base nodes
3D scene import gotchas:
- 'Apply Root Scale' bakes the root transform scale INTO the meshes and animations, not the root Node3D. Nodes added as children after import won't automatically inherit this scale.
- When using scene inheritance on an imported .glb/.fbx scene, you CANNOT delete or rearrange nodes from the base scene — only add new nodes
- Subresources (materials, meshes) in inherited scenes are READ-ONLY. To edit them, save the subresource as a separate .tres/.res file first
- If 'Limit Playback' is enabled, animations are clipped to Blender's timeline playback range — missing keyframes outside that range


<!-- keywords: Importing, Godot, Mipmaps, Limit, Texture, texture, rendering, 3D, import -->
### Importing images: SVG text silently doesn't render; Godot auto-reimports 3D textures with mipmaps; 'Mipmaps Limit' is broken
Image import gotchas:
- SVG text is NOT rasterized by Godot's ThorVG library — text in SVG files simply doesn't appear. Convert text to paths in your SVG editor first.
- When Godot detects a texture is used in 3D, it SILENTLY auto-reimports it with mipmaps enabled and changes compression. This is automatic and may surprise you.
- The 'Mipmaps > Limit' setting in the import dock is NOT implemented — it exists in the UI but has no effect
- PNG images are always imported at 8 bits per channel — no HDR support. Use EXR or HDR format for high-precision textures.
- Pixel art textures should disable VRAM compression to avoid noticeable artifacts, even in 3D (performance cost is worth it for pixel art)


<!-- keywords: MUST, scene, 3D, import -->
### 3D import: _post_import() MUST return the scene or all modifications are silently discarded
When using an import script with _post_import(scene):
- The function MUST `return scene` (or the modified scene) at the end. Failing to return it silently discards ALL changes made during post-import processing — the original unmodified scene is used instead.
- Track filter rules in import are evaluated IN ORDER — an excluded track can be re-included by a later rule, making filter results order-dependent
- 'Ensure Tangents' is required for normal maps to display correctly — if disabled and the model has no tangent data, normal maps render wrong with no error


<!-- keywords: WEAKER, DirectionalLight2D, light, 2D -->
### 2D lights: background color is unaffected by lights; normal maps make lights appear WEAKER; DirectionalLight2D shadows are infinitely long
2D lighting gotchas:
- The canvas background color (Project Settings > Rendering > Background) is NEVER affected by 2D lights. Must place a Sprite2D/ColorRect to represent the background for it to receive lighting.
- Adding normal maps to sprites makes lights appear significantly WEAKER — must increase light Height and Energy properties to compensate
- PointLight2D.offset moves the glow texture but NOT the shadow origin — shadows stay anchored to the node position regardless
- DirectionalLight2D shadows are INFINITELY LONG by default and cannot be made finite through height adjustment — requires custom SDF shaders
- PCF13 soft shadows are very expensive — only use for a handful of lights. Multiple PCF13 lights cause severe frame drops.
- Filter Smooth values above ~4.0 with PCF5 create visible streaking artifacts instead of smooth shadows


<!-- keywords: MUST, Mesh, mesh, export, 3D, Bone, import -->
### 3D model: skeleton MUST be in rest pose before export or mesh imports permanently deformed; look_at() needs use_model_front
3D model export gotchas:
- If the skeleton is NOT reset to rest/T-pose before export, Godot imports the mesh with permanently deformed geometry matching whatever pose the bones were in at export time
- N-gon/quad auto-triangulation during import produces UNPREDICTABLE geometry. Always triangulate in your 3D software before export.
- look_at() uses a convention where model front is -Z (opposite of 3D software convention). Call `look_at(target, Vector3.UP, true)` (use_model_front=true) for assets designed to face +Z.
- Imported lights render very differently than in the source 3D software — design lighting in Godot rather than importing it


<!-- keywords: ALWAYS, Node, 3D, import, global -->
### 3D import naming: -noimp suffix ALWAYS removes the node even if name suffix processing is globally disabled
Import node name customization gotchas:
- The `-noimp` suffix (removes node during import) is respected EVEN WHEN all name suffix processing is globally disabled in import settings — it's the only suffix that cannot be opted out of
- Convex collision shapes on concave meshes create WRONG geometry: a hollow box becomes a solid box. Only use convex shapes on actually convex meshes.
- Animation `loop`/`cycle` suffixes do NOT require a `-` prefix (unlike all other suffixes) — naming inconsistency that's easy to miss


<!-- keywords: Parallax, Texture, texture, 2D -->
### 2D Parallax: texture origin must be at (0,0), NOT centered; infinite repeat expands right/down only
2D Parallax gotchas:
- Parallax repeat tiles starting from (0,0), expanding RIGHT and DOWN. Textures placed with negative x/y or centered at viewport center will NOT tile correctly.
- If the parallax texture is too small for the viewport, either scale the ParallaxLayer node or tile the texture itself — small textures break at zoom levels
- Split-screen parallax requires CLONING the parallax nodes into each SubViewport with visibility layer masking — a single parallax setup cannot be shared across viewports


<!-- keywords: Material, material, 3D, import -->
### 3D import: external material links break when source file renames a material; extracted material preview not shown in dialog
Advanced 3D import gotchas:
- If a material is extracted to an external .tres file and then RENAMED in the source 3D software (Blender/Maya), Godot loses the link and creates a new default material. Must manually reassociate in Advanced Import Settings.
- The Advanced Import Settings dialog shows the ORIGINAL materials from the 3D file, not your customized extracted versions — edits are invisible until the scene is placed in another scene in the editor.
- Skeleton retargeting 'Overwrite Axis' can produce 'horrible results' if the original Bone Rest values are important (the docs literally say this). Test carefully on each model.


<!-- keywords: PSSM, TIMES, rendering -->
### PSSM shadow splits: objects spanning all 4 splits render 5 TIMES; alpha blend disables shadows and reflections
3D lighting and material gotchas:
- Directional lights with PSSM shadow splits (e.g., 4 splits): an object that spans ALL split boundaries renders 5 TIMES (once per split + 1 final). Large objects with 4-split PSSM have major shadow performance cost.
- Alpha Blending mode on StandardMaterial3D DISABLES: shadow casting, receiving reflections from ReflectionProbe, SSR, SSAO — use Alpha Scissor or Alpha Hash for effects that need these.
- Normal maps must be OpenGL-style (Y+ up, green channel up). DirectX-style normal maps (Y- down, green channel down) appear inverted. Enable 'Flip Green Channel' in import settings for DirectX maps.
- Compatibility renderer forces 16-bit (not 32-bit) shadow depth — lower shadow precision than Forward+/Mobile


<!-- keywords: SubViewport, BELOW, World3D, Node, Viewport, rendering -->
### SubViewport only captures nodes BELOW it in hierarchy; sharing World3D requires explicit assignment
Viewport hierarchy gotchas:
- SubViewport renders only nodes that are CHILDREN or DESCENDANTS of it. Nodes above or beside it in the scene tree are invisible to that viewport.
- SubViewport by default creates its own World3D — to share the parent viewport's world (e.g., for picture-in-picture), assign `sub_viewport.world_3d = get_viewport().world_3d`
- SubViewport by default creates its own World2D too — share it similarly if needed for minimap effects
- Debug Draw modes (wireframe, overdraw, etc.) are NOT supported in the Compatibility renderer — always appear as normal


<!-- keywords: SSAO, AMBIENT, SSIL, light -->
### SSAO only affects AMBIENT light (not direct); SSR/SSAO/SSIL/glow ignore off-screen and occluded geometry
Environment post-processing gotchas:
- SSAO darkens only AMBIENT-lit areas by default — it has zero effect on direct light. Use 'Light Affect' parameter to partially apply to direct light (physically incorrect but sometimes desired)
- SSR, SSAO, SSIL, and Glow all fail to account for geometry OUTSIDE the camera view or occluded by other opaque objects — can cause jarring visual pops as objects enter/leave view
- Transparent materials do NOT appear in Screen-Space Reflections — SSR only reflects opaque geometry
- Glow is nearly invisible by default — must either lower HDR Threshold (so non-overbright areas glow) or increase Bloom above 0.0
- HDR Panorama sky with very bright spots produces visible sparkles in reflections — enable 'HDR Clamp Exposure' in the texture import settings


<!-- keywords: StandardMaterial3D, Blender, collision, physics, Material, material, action, export, 3D, blender, import -->
### StandardMaterial3D: refraction is screen-space only; Blender exports with backface culling OFF; height maps add no collision
Standard material gotchas:
- Refraction is SCREEN-SPACE only — materials cannot refract off themselves, other transparent objects, or off-screen geometry. Opaque objects in front get incorrect 'refracted' edges.
- Blender exports materials with backface culling DISABLED by default — renders hidden backfaces needlessly. Enable backface culling in Blender or set it manually in Godot import.
- Height maps (parallax/depth) create a VISUAL ILLUSION only — they add no actual geometry for physics collision. Use HeightMapShape3D for collision.
- Alpha antialiasing (alpha to coverage) requires MSAA 3D set to at least 2x in Project Settings — without it, only fixed dithering applies
- Glow Map texture stretches to viewport aspect ratio — use an image matching your target aspect ratio (e.g., 16:9) to avoid distortion
- Render Priority cannot force opaque objects to render over each other — depth testing takes precedence over render priority


<!-- keywords: DirectionalLight3D, Compatibility, rendering, OmniLight3D, SpotLight3D, light, 3D -->
### DirectionalLight3D position is irrelevant; shadows in Compatibility renderer change light to sRGB (alters appearance)
3D light and shadow gotchas:
- DirectionalLight3D POSITION in the scene has ZERO effect on lighting — only the node's rotation matters. Moving it anywhere produces identical results.
- Enabling shadows on lights in the Compatibility renderer causes the light to render in sRGB space instead of linear space, potentially dramatically altering the light's color/intensity appearance. Adjust Energy to compensate.
- Shadow atlas is SHARED across all visible DirectionalLights3D (up to 8). Each additional directional shadow reduces effective resolution for all others.
- SpotLight3D shadows stop working entirely at angles wider than 89 degrees — use OmniLight3D for wide-angle shadows
- Projector textures on lights MULTIPLY (darken) the light color — increase Energy to compensate for the darkening effect


<!-- keywords: Occlusion, AABB, MultiMesh, GPUParticles, MeshInstance3D, mesh, CSG, GPUParticles3D, particles -->
### Occlusion culling: entire AABB must be occluded; CSG/MultiMesh/GPUParticles ignored by bake; moving occluder = BVH rebuild
Occlusion culling gotchas:
- The occludee's ENTIRE AABB must be fully hidden by occluders for it to be culled — large objects with big AABBs are less likely to be culled
- CSG nodes (unless converted to MeshInstance3D), MultiMeshInstance3D, GPUParticles3D, and CPUParticles3D are IGNORED by the occluder bake. Must manually place OccluderInstance3D shapes for these.
- Moving an OccluderInstance3D at runtime (or its parent) triggers a BVH reconstruction EVERY FRAME — very expensive. Toggling visibility is much cheaper than moving.
- Moving static geometry after baking occluders causes incorrect culling (objects culled incorrectly) — must re-bake after ANY level geometry movement


<!-- keywords: Mesh, MultiMesh, SAME, instantiate, scene, mesh -->
### Mesh LOD: OBJ files skip LOD generation; all MultiMesh instances use the SAME LOD level simultaneously
LOD system gotchas:
- OBJ files are imported as individual mesh resources (not scenes), so LOD generation is SKIPPED. Change import type to 'Scene' and reimport to get LODs.
- MultiMeshInstance3D, GPUParticles3D, CPUParticles3D: ALL instances use the SAME LOD level at the same time (chosen by closest instance to camera). Instances far from the closest one get wrong LOD.
- MultiMesh instances spread far apart should be split into separate MultiMeshInstance3D nodes for correct per-group LOD and culling
- Mesh LOD automatically adjusts for camera FOV and viewport resolution — higher FOV or lower resolution makes LOD transitions more aggressive


<!-- keywords: Decals, Mobile, Albedo, Mix, Forward, Mesh, mesh -->
### Decals: Mobile hard limit 8 per mesh; Albedo Mix doesn't reduce normal impact; Forward+ shares 512-element cluster limit
Decal gotchas:
- Mobile renderer: maximum 8 decals per mesh — extras silently don't render with no warning
- Albedo Mix controls color blending but does NOT reduce normal/ORM texture impact. For footprint or wet surface decals (normal-only): set Albedo Mix to 0.0
- Forward+ renderer: decals share a 512-element cluster limit with lights and ReflectionProbes. Hitting this limit silently stops decals from rendering.
- Normal Fade = 0.0 means decal projects at ALL angles (including backwards through surfaces); 0.999 limits to nearly perpendicular only — counterintuitive direction


<!-- keywords: Volumetric, light -->
### Volumetric fog: finite range only; temporal reprojection leaves ghosting trails from moving lights/volumes
Volumetric fog gotchas:
- Volumetric fog only covers a FINITE range and stops rendering at distance — for large world coverage, combine with non-volumetric exponential fog
- Moving FogVolumes or Light3Ds with volumetric fog enabled leave visible GHOSTING TRAILS due to temporal reprojection. Set Volumetric Fog Energy to 0.0 on short-lived dynamic lights.
- Sky Affect = 0.0 disables volumetric fog on the skybox AND prevents FogVolumes from affecting the sky background
- NoiseTexture3D density textures: only the RED channel of the color ramp affects density; other channels are ignored


<!-- keywords: Visibility, AABB, CENTER -->
### Visibility range uses AABB CENTER for distance calculation — off-center geometry causes unexpected LOD pops
Visibility range gotchas:
- Distance for visibility range Begin/End is measured from the AABB CENTER, not the closest mesh point. Geometry far off-center from its pivot causes unexpected LOD transitions.
- Fade Mode has NO visual effect if Begin Margin AND End Margin are both 0.0
- Manually hiding a Visibility Parent target (Visible = false) breaks the dependency — the node stops being hidden by the visibility range rule


<!-- keywords: Physical, CameraAttributes, Camera, light -->
### Physical light units: enabling forces depth of field (GPU cost); missing CameraAttributes makes editor extremely bright
Physical light and camera unit gotchas:
- Enabling physical camera units (even just for exposure control) forces depth of field to be active, adding 'moderate' GPU performance cost even if blur is visually imperceptible
- Adding WorldEnvironment WITHOUT assigning a CameraAttributes resource while physical light units are enabled makes the 3D editor viewport EXTREMELY bright (functionally unusable)
- Default values (100,000 lux, f/16 aperture) are ONLY correct for outdoor daylight. Indoor/night scenes with these defaults show barely-visible lights — must adjust significantly.


<!-- keywords: Forward, SLOWER, Compatibility, Mobile, rendering, XR -->
### Forward+ is SLOWER than Compatibility on old hardware; 'Mobile' renderer NOT recommended for XR standalone; renderer auto-falls back silently
Renderer selection gotchas:
- Forward+ is the most feature-rich but WORST performing on old/low-end hardware — use Compatibility for low-end targets
- Despite its name, 'Mobile' renderer is only recommended for NEWER mobile devices. For standalone XR headsets (Quest, etc.), use Compatibility renderer.
- Since Godot 4.4, Forward+/Mobile automatically fall back to Compatibility if Vulkan/D3D12/Metal is unavailable — silently reduces quality. Disable in project settings if you want to show an error instead.


<!-- keywords: SubViewportContainer, CANNOT, SubViewport, rendering, Container, int -->
### SubViewportContainer CANNOT be sized smaller than its child SubViewport — size constraint is silently ignored
If you set SubViewportContainer smaller than the child SubViewport's size property, the container size setting is overridden. Set the SubViewport's size to control what's rendered; the container size follows.


<!-- keywords: Compositor, DIFFERS, rendering, Viewport, int -->
### Compositor effects: internal render size DIFFERS from viewport size when upscaling (FSR/TAA) is active
When using FSR2, TAA, or any upscaling, the compositor render buffer size is the INTERNAL resolution (smaller), not the final output resolution. Using viewport.get_size() inside a compositor effect gives wrong UV calculations. Use the texture's actual size instead.


<!-- keywords: Rendering, Shader, STILL, shader, rendering -->
### Rendering server: freeing a Shader RID auto-frees dependent pipelines, but you STILL must free the Shader RID
Godot's rendering server tracks shader→pipeline dependencies and frees pipelines when their parent shader is freed. However, the shader RID itself must still be explicitly freed with RenderingServer.free_rid() or it leaks. The auto-cleanup only applies to children, not the shader itself.


<!-- keywords: NavigationMesh, FREEZE, CRASH, navigation, mesh -->
### NavigationMesh baking: too-small cell_size/cell_height can FREEZE or CRASH the editor — voxel count explodes
Setting cell_size to very small values (e.g., 0.001) causes the baking process to create billions of voxels, consuming all RAM and freezing or crashing Godot. Use the largest cell size that still captures the necessary detail. A cell_size of 0.25 is fine for most games.


<!-- keywords: Image, Reimport, DISCARDS, import -->
### Image import: selecting another file before clicking 'Reimport' DISCARDS all pending import changes silently
In the Import panel, if you change import settings and then click on a different file in the FileSystem dock before clicking 'Reimport', all your changes are lost with no warning or undo. Always click Reimport immediately after changing import settings before navigating away.


<!-- keywords: Lossy, DISK, VRAM, Texture, texture -->
### Lossy texture compression reduces DISK size but NOT video memory — VRAM usage is the same as lossless
VRAM compression (BPTC, ASTC, ETC2, S3TC) is what reduces GPU memory usage. 'Lossy' mode in the importer only affects the on-disk .import cache file size. A lossy PNG that imports as uncompressed VRAM will use the same GPU memory as a lossless PNG.


<!-- keywords: Normal, OpenGL, DirectX, INVERTED, Map, Invert -->
### Normal maps must be OpenGL-format (Y+, green=up) — DirectX-format normal maps appear INVERTED without 'Normal Map Invert Y'
Godot uses OpenGL normal map convention where green channel = Y+ (up). DirectX-format normal maps (from some bakers) have the Y axis flipped (green = Y-). Without enabling 'Normal Map Invert Y' in import settings, lighting will appear inverted on surfaces. Check your normal map baker's output format.


<!-- keywords: High, BPTC, ASTC, Forward, Mobile, S3TC, ETC2, Compatibility, Texture, texture -->
### High-quality texture compression (BPTC/ASTC) only works in Forward+/Mobile — silently uses S3TC/ETC2 in Compatibility
BPTC (BC7) for desktop and ASTC for mobile are only available in Forward+ and Mobile renderers. In Compatibility renderer, Godot silently falls back to S3TC (DXT5) or ETC2, which have lower quality. If targeting Compatibility, test texture quality with that renderer specifically.


<!-- keywords: Apply, Root, Scale, scene, Node, Mesh, mesh, animation, int, 3D, import -->
### 3D import: 'Apply Root Scale' bakes scale into meshes/animations but NOT into later-added child nodes in inherited scenes
When 'Apply Root Scale' is enabled in the 3D importer, scale is baked into mesh vertex data and animation tracks. However, any nodes you ADD to the inherited scene afterward are not scaled — only the nodes that existed at import time. This causes scale mismatches when manually adding nodes like collision shapes to an imported character.


<!-- keywords: Ensure, Tangents, BROKEN, 3D, import, warning -->
### 3D import: 'Ensure Tangents' disabled saves disk/memory but causes BROKEN normal/height maps with no warning
Tangent vectors are required for normal mapping and parallax mapping. Disabling 'Ensure Tangents' in the mesh importer will silently produce incorrect lighting results on any mesh that uses normal maps. Only disable it for meshes that provably use neither normal nor height maps.


<!-- keywords: Blender, SILENTLY, DISCARDED, Limit, Playback, animation, 3D, blender, import -->
### 3D import animation: keyframes outside the Blender playback range are SILENTLY DISCARDED if 'Limit Playback' is enabled
The 'Limit Playback' import option restricts animation import to the Blender timeline's preview range. Any keyframes outside this range are silently dropped. If the timeline range wasn't set correctly in Blender before export, you'll get truncated animations with no error in Godot.


<!-- keywords: Navigation, REQUIRE, navigation, Mesh, mesh -->
### Navigation: different actor sizes REQUIRE separate navigation maps with separately-baked meshes — one map does not fit all
A navigation mesh is baked for a specific agent radius and height. You cannot use the same navmesh for large and small actors. Each actor size needs its own NavigationMap with its own baked NavigationMesh. Use NavigationServer3D.map_create() to create multiple maps and assign agents to the appropriate one.


<!-- keywords: Blender, DISABLED, rendering, export, blender, import, GLTF, performance -->
### Blender: backface culling is OFF by default — glTF exports with cull_mode=DISABLED, halving GPU render performance
Blender materials have backface culling disabled by default. When exported to glTF, Godot imports these with material cull_mode set to Disabled (renders both sides). This doubles the polygon fill rate for all meshes. Always enable backface culling in Blender material settings before exporting, or enable it in Godot's import settings.


<!-- keywords: Blender, Texture, texture, export, blender, import, GLTF -->
### Blender pre-3.2: emissive textures are NOT exported to glTF — must be manually re-linked after import
Blender versions before 3.2 do not write emissive texture data into glTF files. Emissive color values export fine, but texture references are lost. If your team uses Blender 3.1 or earlier, emissive textures must be manually assigned in Godot's imported material after each reimport.


<!-- keywords: Direct, Blender, Android, Web, blender, import, .blend -->
### Direct .blend file import requires Blender installed on ALL team members' machines — not available on Android/Web editor
Godot can import .blend files directly without manual export, but this requires Blender to be installed and accessible in the system PATH on every machine in the team. This silently fails (no asset) if Blender is not found. It's also completely unavailable in the Android editor and Web editor builds.


<!-- keywords: BoxShape3D, CapsuleShape3D, SphereShape3D -->
### BoxShape3D snags on trimesh surfaces (use CapsuleShape3D instead)
BoxShape3D catches on internal collision edges of trimesh surfaces (Godot/Jolt limitation). For objects that slide across trimesh (vehicles, rolling objects, players on terrain), use CapsuleShape3D or SphereShape3D instead.


<!-- keywords: ProceduralSkyMaterial, DirectionalLight3D, WorldEnvironment, sky_mode, SKY_MODE_LIGHT_AND_SKY, SKY_MODE_LIGHT_ONLY -->
### ProceduralSkyMaterial — avoid multiple sun discs
If you add multiple DirectionalLight3D nodes and WorldEnvironment uses ProceduralSkyMaterial, multiple sun discs appear. Fix:
- Primary sun light:  `light.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY`
- Fill/secondary lights:  `light.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY`


<!-- keywords: RenderingServer, instance_reset_physics_interpolation, instance_set_interpolated, Node3D, physics_interpolation_mode, reset_physics_interpolation -->
### RenderingServer physics interpolation methods removed (Godot 4.5)
`RenderingServer.instance_reset_physics_interpolation()` and `RenderingServer.instance_set_interpolated()` were removed. Use node-level interpolation instead: enable `Node3D.physics_interpolation_mode` and call `Node3D.reset_physics_interpolation()` on the node directly.


<!-- keywords: StandardMaterial3D, no_depth_test, TRANSPARENCY_ALPHA, forward_plus, TRANSPARENCY_DISABLED, shading_mode, SHADING_MODE_UNSHADED, render_priority -->
### StandardMaterial3D: no_depth_test + TRANSPARENCY_ALPHA = invisible
In `forward_plus` rendering mode, a `StandardMaterial3D` with BOTH `no_depth_test = true` AND transparency mode `TRANSPARENCY_ALPHA` set will be completely invisible. For UI overlays and billboards, use `transparency = TRANSPARENCY_DISABLED` + `shading_mode = SHADING_MODE_UNSHADED` instead.
For surfaces layered on terrain (roads on ground), offset vertically by 0.1–0.3m and set `render_priority = 1` to avoid Z-fighting.


<!-- keywords: push_unhandled_input, push_input, in_local_coords, SubViewport -->
### Viewport.push_unhandled_input() deprecated — use push_input()
`Viewport.push_unhandled_input(event)` is deprecated. Use `Viewport.push_input(event, in_local_coords)` instead. The deprecated version also does NOT propagate to embedded Window or SubViewport nodes.


<!-- keywords: _shortcut_input, _unhandled_key_input, _unhandled_input, _gui_input, set_input_as_handled -->
### Viewport input propagation order (4.7)
Input events are dispatched in this order: `_input()` → `Control._gui_input()` → `_shortcut_input()` → `_unhandled_key_input()` → `_unhandled_input()`. Call `set_input_as_handled()` (or `accept_event()` in a Control) at any stage to stop the event from going further.
