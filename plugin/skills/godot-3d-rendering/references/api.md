# Class notes: 3D scenes, rendering, materials, shaders and importing assets

Members that are used most and the notes that matter, one section per class. This is a reminder, not the documentation:
`gd api class <Name>` and `gd api class <Name> --member <member>` print the reference of the Godot version that is installed, and they win where the two differ.

Imported from the knowledge base of the Godot AI assistant module (github.com/spardanviro/Godot_AI) by `scripts/import-knowledge.mjs`; do not edit by hand.

## Camera3D
Camera3D: fov:float=75, near:float, far:float, environment:Environment, attributes:CameraAttributes.
  make_current() — use this to activate camera (NOT current=true).
  is_current()->bool, get_viewport()->Viewport.
  project_ray_origin(screen_point)->Vector3, project_ray_normal(screen_point)->Vector3.

## ShaderMaterial
ShaderMaterial: shader:Shader.
  set_shader_parameter(param:StringName, value:Variant) — set uniform values.
  get_shader_parameter(param:StringName)->Variant.
  IMPORTANT: param name must exactly match the uniform name in the .gdshader file.

## StandardMaterial3D
StandardMaterial3D: albedo_color:Color, albedo_texture:Texture2D, metallic:float, roughness:float.
  emission_enabled:bool, emission:Color, emission_energy_multiplier:float.
  transparency: TRANSPARENCY_DISABLED|ALPHA|ALPHA_SCISSOR|ALPHA_HASH|ALPHA_DEPTH_PRE_PASS.
  shading_mode: SHADING_MODE_UNSHADED|PER_VERTEX|PER_PIXEL.
  cull_mode: CULL_BACK|FRONT|DISABLED. no_depth_test:bool, render_priority:int.
  CAUTION: no_depth_test=true + transparency=ALPHA = invisible in forward_plus. Use UNSHADED instead.

## GridMap
GridMap: mesh_library:MeshLibrary, cell_size:Vector3, cell_octant_size:int.
  set_cell_item(position:Vector3i, item:int, orientation:int=0).
  get_cell_item(position:Vector3i)->int (-1 if empty).
  get_used_cells()->Array[Vector3i], get_used_cells_by_item(item:int)->Array[Vector3i].
  INVALID_CELL_ITEM=-1 (use to erase). map_to_local(pos:Vector3i)->Vector3, local_to_map(pos)->Vector3i.

## MultiMesh
MultiMesh: mesh:Mesh, instance_count:int, transform_format:TRANSFORM_3D|2D.
  set_instance_transform(instance:int, transform:Transform3D).
  set_instance_color(instance:int, color:Color) — requires use_colors=true.
  visible_instance_count:int (-1 = all). instance_count must be set BEFORE set_instance_transform.

## MultiMeshInstance3D
MultiMeshInstance3D: multimesh:MultiMesh resource.
  IMPORTANT: NO set_surface_override_material() — set material on MultiMesh.mesh instead.
  For custom AABB (if particles fly far): set_custom_aabb(AABB(origin, size)).

## PathFollow3D
PathFollow3D (child of Path3D): progress:float (meters along path), progress_ratio:float (0.0-1.0).
  loop:bool, cubic_interp:bool, rotation_mode:RotationMode.
  Animate progress_ratio with Tween or AnimationPlayer to move along path.

## SubViewport
SubViewport: size:Vector2i, render_target_update_mode:UpdateMode.
  UpdateMode: UPDATE_DISABLED|ONCE|WHEN_VISIBLE(default)|WHEN_PARENT_VISIBLE|ALWAYS.
  render_target_clear_mode, transparent_bg:bool.
  get_texture()->ViewportTexture — use as texture on MeshInstance3D or TextureRect.

## Node3D
Node3D: position:Vector3, rotation:Vector3 (radians), rotation_degrees:Vector3, scale:Vector3.
  global_position:Vector3, global_rotation:Vector3, global_transform:Transform3D.
  look_at(target:Vector3, up:Vector3=Vector3.UP, use_model_front:bool=false).
  translate(offset:Vector3), rotate(axis:Vector3, angle:float).
  visible:bool, show(), hide().

## WorldEnvironment
WorldEnvironment: environment:Environment, camera_attributes:CameraAttributes.
  Environment: background_mode, sky:Sky, ambient_light_color, glow_enabled, ssao_enabled, fog_enabled.
  Sky: sky_material:SkyMaterial (ProceduralSkyMaterial/PanoramaSkyMaterial/PhysicalSkyMaterial).
  ProceduralSkyMaterial: sky_top_color, sky_horizon_color, ground_bottom_color.
  Multiple DirectionalLight3D: set sky_mode = SKY_MODE_LIGHT_ONLY on fill lights to avoid multiple sun discs.

## DirectionalLight3D
DirectionalLight3D: light_color:Color, light_energy:float, shadow_enabled:bool.
  sky_mode: SKY_MODE_LIGHT_AND_SKY(default) | SKY_MODE_LIGHT_ONLY | SKY_MODE_SKY_ONLY.
  IMPORTANT: Multiple DirectionalLight3D with SKY_MODE_LIGHT_AND_SKY = multiple sun discs in sky.
  Fix: set all fill lights to sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY.
