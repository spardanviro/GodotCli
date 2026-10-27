# Class notes: physics, movement, input, navigation and tile maps

Members that are used most and the notes that matter, one section per class. This is a reminder, not the documentation:
`gd api class <Name>` and `gd api class <Name> --member <member>` print the reference of the Godot version that is installed, and they win where the two differ.

Imported from the knowledge base of the Godot AI assistant module (github.com/spardanviro/Godot_AI) by `scripts/import-knowledge.mjs`; do not edit by hand.

## CharacterBody3D
CharacterBody3D: velocity:Vector3, move_and_slide()->bool, is_on_floor()->bool, is_on_wall()->bool, is_on_ceiling()->bool.
  motion_mode: MOTION_MODE_GROUNDED(default: any game with a floor and gravity) | MOTION_MODE_FLOATING(no floor at all, e.g. space; is_on_floor() is then always false).
  up_direction:Vector3=Vector3.UP, floor_snap_length:float, floor_max_angle:float, wall_min_slide_angle:float.
  Keep GROUNDED wherever there is a floor (vehicles, walking, sliding); FLOATING is for movement without one.

## CharacterBody2D
CharacterBody2D: velocity:Vector2, move_and_slide()->bool, is_on_floor()->bool, is_on_wall()->bool.
  motion_mode: MOTION_MODE_GROUNDED(default) | MOTION_MODE_FLOATING.
  up_direction:Vector2=Vector2.UP, floor_snap_length:float.

## RigidBody3D
RigidBody3D: linear_velocity:Vector3, angular_velocity:Vector3, mass:float, gravity_scale:float.
  apply_central_impulse(impulse:Vector3), apply_impulse(impulse:Vector3, pos:Vector3=Vector3.ZERO).
  apply_central_force(force), apply_force(force, pos). freeze:bool, freeze_mode:FreezeModeEnum.
  Signals: body_entered(body:Node), body_exited(body:Node) — only if contact_monitor=true and max_contacts_reported>0.
  IMPORTANT: Do NOT put body_entered on RigidBody3D itself; use an Area3D child for overlap detection instead.

## RigidBody2D
RigidBody2D: linear_velocity:Vector2, angular_velocity:float, mass:float, gravity_scale:float.
  apply_central_impulse(impulse:Vector2), apply_impulse(impulse:Vector2, pos:Vector2=Vector2.ZERO).
  freeze:bool, contact_monitor:bool, max_contacts_reported:int.
  Signals: body_entered, body_exited (requires contact_monitor=true).

## Camera2D
Camera2D: offset:Vector2, zoom:Vector2=Vector2(1,1), limit_left/right/top/bottom:int.
  position_smoothing_enabled:bool, position_smoothing_speed:float.
  drag_horizontal_enabled:bool, drag_vertical_enabled:bool.
  make_current() — CRITICAL: no 'current' property. Call make_current() AFTER add_child().
  is_current()->bool.

## NavigationAgent3D
NavigationAgent3D: target_position:Vector3 (NOT destination), path_desired_distance:float, target_desired_distance:float.
  is_navigation_finished()->bool, get_next_path_position()->Vector3, distance_to_target()->float.
  navigation_map:RID, path_postprocessing, avoidance_enabled:bool, velocity:Vector3 (set for avoidance).
  Signals: navigation_finished, target_reached, velocity_computed(safe_velocity:Vector3).
  Usage: set target_position each frame or on arrival; call get_next_path_position() in _physics_process.

## NavigationAgent2D
NavigationAgent2D: target_position:Vector2, path_desired_distance:float, target_desired_distance:float.
  is_navigation_finished()->bool, get_next_path_position()->Vector2.
  Signals: navigation_finished, target_reached, velocity_computed(safe_velocity:Vector2).

## NavigationRegion3D
NavigationRegion3D: navigation_mesh:NavigationMesh, enabled:bool.
  bake_navigation_mesh(on_thread:bool=true) — bakes navmesh at runtime.
  navigation_mesh_changed signal.

## TileMapLayer
TileMapLayer (Godot 4.3+, replaces TileMap): tile_set:TileSet, enabled:bool, modulate:Color.
  set_cell(coords:Vector2i, source_id:int, atlas_coords:Vector2i=Vector2i(-1,-1), alt_tile:int=0).
  erase_cell(coords:Vector2i) — same as set_cell with source_id=-1.
  get_cell_source_id(coords)->int (-1 if empty), get_cell_atlas_coords(coords)->Vector2i.
  get_used_cells()->Array[Vector2i], get_used_rect()->Rect2i.
  local_to_map(local_pos:Vector2)->Vector2i, map_to_local(map_pos:Vector2i)->Vector2.
  For batch fill: loop over coords array and call set_cell() per cell.

## Area3D
Area3D: collision_layer:int (bitmask), collision_mask:int (bitmask), monitoring:bool, monitorable:bool.
  gravity_space_override:SpaceOverrideMode, gravity:float, gravity_direction:Vector3.
  Signals: body_entered(body:Node3D), body_exited, area_entered(area:Area3D), area_exited.
  get_overlapping_bodies()->Array[Node3D], get_overlapping_areas()->Array[Area3D].
  IMPORTANT: collision_layer/mask are BITMASKS. Layer 1=1, Layer 2=2, Layer 3=4, Layer 4=8.
  IMPORTANT: Use call_deferred() for add_child/remove_child inside body_entered callbacks.

## Area2D
Area2D: collision_layer:int (bitmask), collision_mask:int (bitmask), monitoring:bool, monitorable:bool.
  Signals: body_entered(body:Node2D), body_exited, area_entered, area_exited.
  get_overlapping_bodies()->Array[Node2D].
  IMPORTANT: collision_layer/mask are BITMASKS. Use call_deferred() inside signal callbacks.

## CollisionShape3D
CollisionShape3D: shape:Shape3D (BoxShape3D/SphereShape3D/CapsuleShape3D/etc.), disabled:bool.
  CAUTION: BoxShape3D snags on trimesh edges. Use CapsuleShape3D for characters/vehicles.
  set_deferred('disabled', true/false) when changing inside physics callbacks.

## CollisionShape2D
CollisionShape2D: shape:Shape2D (RectangleShape2D/CircleShape2D/CapsuleShape2D/etc.), disabled:bool.
  TIP: Make shape slightly smaller than tile (e.g. 48px in a 64px grid) for smooth movement.

## RayCast3D
RayCast3D: enabled:bool, target_position:Vector3, collision_mask:int (bitmask).
  is_colliding()->bool, get_collider()->Object, get_collision_point()->Vector3, get_collision_normal()->Vector3.
  force_raycast_update() — force update when not in physics frame. exclude_parent:bool.

## RayCast2D
RayCast2D: enabled:bool, target_position:Vector2, collision_mask:int (bitmask).
  is_colliding()->bool, get_collider()->Object, get_collision_point()->Vector2.
  force_raycast_update().

## PathFollow2D
PathFollow2D (child of Path2D): progress:float, progress_ratio:float (0.0-1.0). loop:bool.

## TileMap
TileMap: DEPRECATED since Godot 4.3. Use TileMapLayer instead (one node per layer).
  If you see TileMap in existing code: each layer maps to a separate TileMapLayer node.
  Migrate: replace TileMap.set_cell(layer, coords, ...) with TileMapLayer.set_cell(coords, ...).
