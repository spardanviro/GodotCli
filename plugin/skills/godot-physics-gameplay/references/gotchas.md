# Pitfalls: physics, movement, input, navigation and tile maps

81 entries, each a mistake that is easy to make in Godot 4 and what to do instead. Do not read this file from top to bottom:
search it for the class, method or term you are about to use (the `keywords` line of each entry lists them) and read the entries that match.
The other skills of this plugin have a file like this one for their topics: `../../*/references/gotchas.md` searches all of them.

Imported from the knowledge base of the Godot AI assistant module (github.com/spardanviro/Godot_AI) by `scripts/import-knowledge.mjs`; do not edit by hand.

<!-- keywords: CharacterBody2D, CharacterBody3D, move_and_slide, velocity, delta, _physics_process -->
### move_and_slide() already includes delta — do NOT multiply velocity by delta
`CharacterBody2D.move_and_slide()` and `CharacterBody3D.move_and_slide()` handle the physics timestep internally. Do NOT pre-multiply `velocity` by `delta` before calling it (unlike `move_and_collide()`, which requires manual delta scaling). HOWEVER, gravity IS an acceleration and MUST be multiplied by `delta`:
```gdscript
func _physics_process(delta: float) -> void:
    velocity.y += gravity * delta  # gravity: multiply by delta (it's acceleration)
    move_and_slide()               # NO delta here — timestep already baked in
# WRONG: move_and_slide(velocity * delta)  ← double-applies timestep
```


<!-- keywords: RigidBody, velocity, RigidBody2D, RigidBody3D, physics, int -->
### RigidBody: never set position/linear_velocity directly — use _integrate_forces()
Setting `position`, `global_position`, `linear_velocity`, or `angular_velocity` on a `RigidBody2D`/`RigidBody3D` directly from outside `_integrate_forces()` breaks the physics simulation (tunneling, jitter, lost momentum). To move or rotate a rigid body from code:
- Use `_integrate_forces(state: PhysicsDirectBodyState3D)` override and set `state.linear_velocity`, `state.angular_velocity`, or `state.transform`
- For one-shot placement only (e.g. spawn position), `set_global_transform()` is acceptable
- NEVER call `look_at()` every frame on a RigidBody — use `_integrate_forces()` with angular_velocity instead


<!-- keywords: RigidBody, RigidBody2D, RigidBody3D, int -->
### RigidBody sleeping stops _integrate_forces() from being called
When a `RigidBody2D`/`RigidBody3D` has been at rest long enough, it goes to sleep to save CPU. While sleeping, `_integrate_forces()` is NOT called at all. If your rigid body logic requires continuous processing, either set `can_sleep = false` (performance cost) or apply a tiny continuous force/impulse to keep it awake.


<!-- keywords: Ray, physics, delta, _physics_process -->
### Ray-casting (direct_space_state) is only safe inside _physics_process()
The physics space is 'locked' between physics frames. Accessing `get_world_2d().direct_space_state` or `get_world_3d().direct_space_state` outside of `_physics_process()` causes an error. Always perform ray-casts / shape queries inside `_physics_process()`:
```gdscript
func _physics_process(delta: float) -> void:
    var space := get_world_3d().direct_space_state
    var query := PhysicsRayQueryParameters3D.create(origin, end)
    var result := space.intersect_ray(query)
```


<!-- keywords: Never, CollisionShape, collision, Node, CollisionShape2D, CollisionShape3D -->
### Never scale CollisionShape nodes — use shape size handles instead
Scaling a `CollisionShape2D` or `CollisionShape3D` node (via the Node2D/Node3D Scale property) causes incorrect collision behavior: the shape visually scales but collision detection uses wrong extents. ALWAYS resize collision shapes using the size handles in the editor or by setting the shape's size/radius properties directly:
  WRONG:  collision_shape.scale = Vector2(2, 2)   # scale property — breaks collisions
  CORRECT: (collision_shape.shape as RectangleShape2D).size = Vector2(64, 32)  # shape size


<!-- keywords: collision, collision_layer -->
### set_collision_layer_value(layer_number, bool) — layer_number is 1-based
The convenience method `set_collision_layer_value(layer_number, value)` uses 1-based layer numbers (Layer 1 = 1, Layer 2 = 2, etc.), unlike the raw `collision_layer` bitmask where Layer 1 = bit 0 = value 1. This is cleaner than bitmask arithmetic:
  CORRECT: body.set_collision_layer_value(2, true)   # enable layer 2 cleanly
  CORRECT: body.set_collision_mask_value(1, true)    # enable mask for layer 1
  VERBOSE: body.collision_layer = 2                  # same but as raw bitmask


<!-- keywords: NavigationAgent, NavigationAgent2D, navigation, _ready -->
### NavigationAgent: DON'T query path in _ready() — map not synced yet
If you set `NavigationAgent2D.target_position` or call `get_next_path_position()` inside `_ready()`, the navigation map may not have finished its first synchronization. The result is an empty path and the agent immediately considers itself at the destination. Wait for the first physics frame (`await get_tree().physics_frame`) before setting the target, or set it in the first `_physics_process()` tick:
```gdscript
func _ready() -> void:
    call_deferred("_set_initial_target")  # deferred, after map sync

func _set_initial_target() -> void:
    navigation_agent.target_position = target_pos
```


<!-- keywords: NavigationAgent, ONCE, physics, navigation, delta, _physics_process -->
### NavigationAgent: call get_next_path_position() ONCE per _physics_process, check is_navigation_finished() first
`get_next_path_position()` updates the agent's internal path state. Calling it more than once per physics frame, or calling it after the destination is reached, causes the agent to jitter. Always guard with `is_navigation_finished()`:
```gdscript
func _physics_process(delta: float) -> void:
    if navigation_agent.is_navigation_finished():
        return
    var next_pos := navigation_agent.get_next_path_position()  # call ONCE
    var direction := (next_pos - global_position).normalized()
    velocity = direction * speed
    move_and_slide()
```


<!-- keywords: Input, input -->
### Input.get_vector() — clean 8-way movement input
Use `Input.get_vector(negative_x, positive_x, negative_y, positive_y)` to get a normalized diagonal-aware input vector for 8-way movement. It returns a Vector2 with magnitude ≤ 1.0:
```gdscript
func _physics_process(delta: float) -> void:
    var dir := Input.get_vector("left", "right", "up", "down")
    velocity = dir * speed
    move_and_slide()
```
This is cleaner and more correct than `Input.is_action_pressed()` + manual normalization.


<!-- keywords: TileMapLayer, NavigationRegion2D, navigation, pathfinding, TileMap, tile, 2D -->
### TileMapLayer built-in navigation is limited — bake to NavigationRegion2D for real games
TileMapLayer's built-in navigation has performance and quality limitations. For production use, after designing your TileMap, bake it to a `NavigationRegion2D` with an explicit `NavigationPolygon` and disable the TileMapLayer's navigation. Also note: **2D navigation meshes cannot be layered** — stacking multiple navigation meshes on the same navigation map causes merge errors that break pathfinding.


<!-- keywords: Collision, WHERE, WHAT, collision, physics, collision_layer, collision_mask -->
### Collision layer vs mask: layer = WHERE you are, mask = WHAT you scan
`collision_layer` = the physics layers this body EXISTS on. `collision_mask` = the physics layers this body DETECTS (scans for collisions). Both objects must have the right combination for a collision to register:
  - Object A (enemy) is on layer 2. Object B (player) scans layer 2 (mask includes bit 2).
  - Only B detects A, not vice versa unless A's mask also includes B's layer.
Use `set_collision_layer_value(N, bool)` / `set_collision_mask_value(N, bool)` (N is 1-based) to modify individual bits.


<!-- keywords: Physics, Godot, physics -->
### Physics is NOT deterministic in Godot
Godot's physics engine does not guarantee identical results across runs, devices, or frame rates. Never assume physics simulation will be exactly reproducible. Use `is_equal_approx()` for float comparisons derived from physics, and design for approximate outcomes.


<!-- keywords: Physics, physics, Input, input, int -->
### Physics interpolation reduces jitter but increases input lag — careful for fighting/rhythm games
Enabling physics interpolation (Project Settings > Physics > Common > Enable Object Motion Interpolation) smooths jitter caused by physics/framerate mismatch. However, it **adds one physics tick of input lag** to physics-driven movement. For most games this is acceptable. For competitive games requiring tight input response (fighting games, rhythm games), either disable it or compensate by increasing the physics tick rate (e.g., to 120 Hz). Also: when teleporting objects with interpolation enabled, call `Node3D.reset_physics_interpolation()` to prevent visible interpolation from old to new position.


<!-- keywords: Projectiles -->
### Projectiles must NOT be children of the shooter — they inherit transform and get deleted with parent
A common mistake: making a bullet/projectile a child of the player or enemy that fires it. Problems:
1. The projectile **inherits the parent's transform** — moving the parent moves the bullet too.
2. If the parent is freed (enemy dies), all its children including mid-flight projectiles are freed.
Instead, emit a signal that a root-level manager node handles, or `add_child()` the projectile to the **scene root** or a dedicated 'projectiles' node:
  # In player.gd
  signal bullet_fired(bullet_scene, global_pos, direction)
  # In main.gd or a BulletManager autoload
  func _on_player_bullet_fired(scene, pos, dir):
      var b = scene.instantiate()
      get_tree().root.add_child(b)  # root-level, not under player
      b.global_position = pos


<!-- keywords: Collision, Scale, NEVER, collision, physics -->
### Collision shape Scale must stay (1,1,1) — NEVER scale via transform handles
Scaling a CollisionShape2D/3D using the node's scale property or the transform scale handles causes **broken collision behavior** (incorrect collision bounds, tunneling, etc.). To resize a collision shape, use the **shape's own size handles** in the editor (the orange dots) or set the `shape.size` / `shape.radius` / `shape.height` properties directly. The Transform > Scale in the Inspector should always remain at (1,1) for 2D or (1,1,1) for 3D. This is one of the most common physics bugs.


<!-- keywords: Collision, LAYER, MASK, collision, physics -->
### Collision LAYER = what object you are; Collision MASK = what objects you can collide with
A contact is detected when **either** object's collision **mask** includes a layer the other is **on**:
- Object A's mask includes Object B's layer, **or**
- Object B's mask includes Object A's layer.
Which body is pushed is decided by the moving one: a CharacterBody's move_and_slide() only collides with what its own mask includes.
A common mistake: set both layer AND mask to the same layer and wonder why an enemy doesn't detect a coin. The enemy's mask must include the coin's layer. Name your layers in Project Settings > Layer Names > 2D/3D Physics. Set them per-bit using `set_collision_layer_value(layer_num, bool)` in code (layer numbers start at 1, not 0).


<!-- keywords: RigidBody, NEVER, physics, int, global, RigidBody3D, GDScript -->
### RigidBody: NEVER call set_global_transform()/look_at() every frame — use _integrate_forces()
Calling `look_at()`, `set_global_transform()`, or directly setting `position`/`rotation` on a RigidBody every frame overrides the physics engine's state and **breaks simulation** (the body appears to teleport, no collision response, etc.). For one-time placement, these are fine. For continuous control, use the `_integrate_forces(state)` callback and modify `state.angular_velocity` or `state.linear_velocity` instead. To make a RigidBody look at a target, calculate the angular velocity needed to rotate toward the target within `_integrate_forces()` (see Godot docs for the `look_follow()` pattern).


<!-- keywords: Input, InputEvent, input -->
### Input event flow order: _input() → GUI → _shortcut_input() → _unhandled_key_input() → _unhandled_input()
Godot dispatches InputEvents through nodes in a strict order (deepest-child-first, reverse depth-first):
1. `_input()` — called first on all nodes, even while GUI is focused. Use for raw input.
2. GUI Controls get the event via `_gui_input()`. If a Control `accept_event()`, propagation stops.
3. `_shortcut_input()` — for keyboard shortcuts and joypad buttons only.
4. `_unhandled_key_input()` — for unhandled keyboard events only.
5. `_unhandled_input()` — for everything else. **Best for gameplay input**: only fires if GUI didn't consume the event.
Important: SubViewports do NOT receive input unless inside a SubViewportContainer. GUI keyboard/joypad events do NOT travel up the scene tree (unlike mouse events).


<!-- keywords: Physics, NEVER, CollisionShapes, Resources, SHARED, collision, physics, Resource, CollisionShape -->
### Physics: NEVER scale CollisionShapes, and collision shape Resources are SHARED
Two critical physics gotchas:
1. **Scaling physics bodies doesn't work**: Godot doesn't support non-uniform scaling of physics bodies or shapes. Instead, change the shape's `size` (boxes; Godot 3 called it extents, at half the size), `radius`, or `height` directly. Change the visual node's scale separately. The CollisionShape must NOT be a child of the scaled visual node in this case.
2. **Collision shape Resources are shared**: When you change a collision shape's size at runtime, it affects ALL nodes using the same resource. Call `.duplicate()` on the resource first:
  collision_shape.shape = collision_shape.shape.duplicate()
  collision_shape.shape.size = new_size


<!-- keywords: Physics, Continuous, physics -->
### Physics tunneling: use Continuous CD or thicker colliders for fast-moving objects
At high speeds, objects can pass through thin colliders between physics frames (tunneling). Solutions:
- Enable **Continuous CD** in RigidBody properties
- Make static colliders thicker than their visual representation
- Increase Physics Ticks per Second (default 60 Hz; use multiples: 120, 180, 240)
Also: TileMap edges cause bumps when objects slide across them. Fix: use composite colliders (one shape per connected tile group). In Godot 4.5+, TileMapLayer does this automatically via **Physics Quadrant Size**.


<!-- keywords: Physics, Cylinder, GodotPhysics, Box, Capsule, physics -->
### Physics: Cylinder shapes are unstable in GodotPhysics — use Box or Capsule
CylinderShape3D is known to be unreliable in Godot's built-in GodotPhysics engine (remnant of the Bullet→GodotPhysics migration). For character controllers, use BoxShape3D (most reliable) or CapsuleShape3D (no diagonal enlargement). Alternatively, switch to the **Jolt** physics engine (4th option in Project Settings > Physics > 3D > Physics Engine) for better stability and cylinder support.


<!-- keywords: Physics, physics, int, float -->
### Physics: floating-point precision degrades far from the world origin
Physics simulation (and rendering) loses precision as coordinates grow large. Objects far from (0,0,0) exhibit wobbling, jitter, and incorrect collisions. For large open worlds, enable **Large World Coordinates** (double-precision mode) in Project Settings, or implement an origin-shifting system that moves the world around the player to keep the player near (0,0,0).


<!-- keywords: Raycasting, Area3D, physics, Area2D, _process, _physics_process, RayCast -->
### Raycasting: must be done in _physics_process(); Area3D not hit by default
Two non-obvious raycast rules:
1. **Space is locked outside _physics_process()**. Calling `get_world_3d().direct_space_state` from `_process()` or `_ready()` causes a 'space locked' error. Always do ray queries inside `_physics_process()` (or `_physics_process()` via call_deferred).
2. **Area3D/Area2D are not hit by default**: Must set `query.collide_with_areas = true` on the PhysicsRayQueryParameters object.
3. **Raycast from a CollisionObject hits itself**: Add `query.exclude = [get_rid()]` (exclude takes RIDs, not nodes) to exclude the caster.
4. **Raycast result is an empty Dictionary on miss** (not null): Check `if result:` not `if result != null:`.


<!-- keywords: Multiplayer, RPCs, RPC -->
### Multiplayer @rpc: ALL RPCs must match between client and server — even unused ones
Godot validates RPC signatures using a checksum of ALL `@rpc`-annotated functions in a script. The checksum includes the annotation parameters, function name, return type, AND the node's path. If even ONE unused RPC is declared differently on client vs server, ALL RPCs in that script will fail — often with a cryptic unrelated error message. Rules:
1. Every `@rpc` function must be declared on BOTH client and server scripts
2. The annotation parameters must match exactly: `@rpc("any_peer", ...)` on both sides
3. Nodes using RPCs must have the same NodePath — use `add_child(node, true)` (`force_readable_name=true`) for dynamically spawned nodes
4. RPCs cannot serialize Objects or Callables — only Variant types


<!-- keywords: Multiplayer, RPC, network -->
### Multiplayer @rpc defaults: 'authority' and 'call_remote' — understand the difference
`@rpc` with no arguments is equivalent to `@rpc('authority', 'call_remote', 'reliable')`:
- **'authority'**: Only the multiplayer authority (server by default, unless changed with `set_multiplayer_authority()`) can call this RPC on remote peers. Clients calling it are ignored.
- **'any_peer'**: Any client can call this RPC on remote peers. Essential for client→server RPCs (player input, actions).
- **'call_remote'**: The function is NOT called on the sender. Only runs on recipients.
- **'call_local'**: The function ALSO runs on the local peer. Needed when the server is also a player (listen server).
- Server's peer ID is always **1**. Use `multiplayer.get_remote_sender_id()` inside an RPC to identify who called it.
- Godot's high-level networking uses **UDP only** — forward the UDP port (not TCP) when hosting.


<!-- keywords: Controller, Input, input -->
### Controller input is visible to ALL windows, including unfocused windows
Unlike keyboard/mouse input (which requires the game window to be focused), controller/gamepad inputs are received by ALL running applications including unfocused ones. Enable the project setting `input_devices/joypads/ignore_joypad_on_unfocused_application` (or, in versions that have it, `Input.ignore_joypad_on_unfocused_application = true` at runtime; check with `gd api class Input`) to prevent accidental input while the player interacts with another window. Also:
- Holding a controller button does NOT generate 'echo' events (keyboard holding does) — implement echo manually with a Timer if needed
- Controller inputs do NOT prevent screen sleep/power saving — check 'Display > Window > Energy Saving > Keep Screen On'
- **Windows: max 4 simultaneous controllers** (XInput API limitation)


<!-- keywords: Input, Vector2, input, action -->
### Input.get_vector() gives circular deadzone; manual Vector2 subtraction gives square deadzone
Use `Input.get_vector(neg_x, pos_x, neg_y, pos_y)` for joystick/WASD movement — it normalizes the result and applies a **circular deadzone** (correct behavior, prevents drift at diagonal). Manual construction `Vector2(get_action_strength(...), get_action_strength(...)).limit_length(1.0)` uses a **square deadzone**, which causes asymmetric sensitivity near diagonal edges. The optional 5th parameter to `get_vector()` overrides the per-action deadzone average.


<!-- keywords: NavigationServer3D, physics, navigation, pathfinding, await -->
### NavigationServer3D does NOT sync on the first frame — must await physics_frame
On the very first frame, NavigationServer3D's map has not yet synchronized region data. Any path query called in `_ready()` will return an empty path. Pattern to fix:
```gdscript
func _ready():
    actor_setup.call_deferred()
func actor_setup():
    await get_tree().physics_frame  # Wait for NavigationServer sync
    navigation_agent.set_target_position(target_pos)
```
Also: NavigationObstacle3D does **NOT** affect pathfinding — it only constrains avoidance velocity. To block pathfinding, modify navigation meshes instead.


<!-- keywords: NavigationAgent, NavigationAgent2D, navigation, avoidance, pathfinding -->
### NavigationAgent: avoidance needs target_position set, and never call get_next_path_position after finish
Non-obvious NavigationAgent pitfalls:
- `get_next_path_position()` must be called **once per `_physics_process`** until `is_navigation_finished()` returns true. Calling it AFTER the target is reached triggers repeated path updates and causes the agent to jitter/dance in place.
- NavigationAgent avoidance requires a `target_position` to be set **even when only using avoidance** — without it, `velocity_computed` always emits a zero vector.
- RVO avoidance fails in perfectly symmetric scenarios (agents moving directly toward each other at equal speeds) — agents can't determine which side to pass on.
- 2D avoidance (xz plane) and 3D avoidance (xyz) run in **separate simulations** — agents cannot affect agents in the other mode.
- NavigationObstacle3D affects avoidance ONLY, not pathfinding. To block pathfinding, change the navigation mesh.


<!-- keywords: FRAMERATE, DEPENDENT, delta, _process, _physics_process -->
### lerp(a, b, delta * speed) is FRAMERATE-DEPENDENT — use exponential formula for framerate independence
The common 'smooth follow' pattern `position = position.lerp(target, delta * speed)` is **framerate-dependent** because the weight parameter is a percentage of remaining distance, not an absolute amount. At higher frame rates, more lerp steps occur per second, reaching the target faster. For true framerate independence:
```gdscript
# Framerate-independent exponential decay smooth follow:
var weight = 1.0 - exp(-speed * delta)
position = position.lerp(target, weight)
```
In `_physics_process()`, `delta` is nearly constant (fixed physics rate), so the simple form usually works fine. In `_process()` (variable delta), always use the exponential formula.


<!-- keywords: TileMap, Godot, TileMapLayer, TileSet, Node, Resource, tile, int -->
### TileMap in Godot 4.3+: TileMap split into TileMapLayer nodes; share TileSet as external resource
Since Godot 4.3, the old TileMap node was replaced by individual **TileMapLayer** nodes:
- Each layer is a separate TileMapLayer node — you can only place **one tile per position per layer**. Use multiple TileMapLayer nodes to overlap tiles (e.g., background + objects + foreground).
- To share the same TileSet across multiple levels/scenes: save the TileSet as an **external .tres resource** (click dropdown next to TileSet property > Save). Built-in TileSet is not shareable.
- Y-Sort on TileMapLayer: tiles are grouped by Y position instead of quadrants when enabled — this is required for top-down games where tiles overlap based on vertical position.


<!-- keywords: NavigationObstacle, ENABLED, navigation, navmesh, avoidance, Mesh, mesh -->
### NavigationObstacle avoidance is ENABLED by default — disable it if using only for navmesh baking
NavigationObstacle2D/3D has avoidance_enabled = true by default. If you only want it to affect navigation mesh baking (affect_navigation_mesh=true), set avoidance_enabled=false to save performance. For nav mesh baking, obstacles only REMOVE geometry from the navmesh — they never add geometry.


<!-- keywords: Static, NavigationObstacles, navigation, static -->
### Static NavigationObstacles (polygon vertices) can't move cheaply; use radius (dynamic) for moving obstacles
- **Static obstacle** (vertices set): Acts as hard boundary for 2D avoidance mode only. Cannot be moved without a full rebuild (expensive). Warping a static obstacle on top of agents gets them stuck.
- **Dynamic obstacle** (radius > 0): A 'please move away' soft repulsion. Can update position every frame with no extra cost. Set velocity to allow agents to predict movement.
- Static obstacles only affect agents using 2D avoidance mode; 3D avoidance uses the radius (sphere) form.


<!-- keywords: SpringArm3D, Camera3D, DIRECT, collision, Camera, camera, Node3D, RayCast -->
### SpringArm3D: camera collision shape only works if Camera3D is DIRECT child; otherwise falls back to inaccurate raycast
For third-person cameras:
- SpringArm3D uses the Camera3D near-plane pyramid as its collision shape ONLY when Camera3D is a direct child of SpringArm3D.
- If a custom shape is assigned, that shape is ALWAYS used (overrides camera shape).
- If no shape AND camera is not a direct child, falls back to a single ray cast — inaccurate for camera collisions.
- Standard setup: Node3D (pivot) → SpringArm3D → Camera3D. Move pivot up so it's not at ground level.


<!-- keywords: Pausing, physics, signal, connect, emit, Node, _process, _physics_process, input -->
### Pausing: signals still fire on paused nodes; physics servers stop even for PROCESS_MODE_ALWAYS nodes
When get_tree().paused = true:
- SIGNALS still emit and call connected functions, even on paused nodes
- Physics servers are SHUT DOWN globally — even nodes with PROCESS_MODE_ALWAYS won't get physics (collisions, move_and_slide, etc.)
- Animation/audio/particles auto-pause and auto-resume
- For pause menu: set root node of menu to PROCESS_MODE_WHEN_PAUSED; all children inherit it
- To resume physics while paused: PhysicsServer2D.set_active(true) / PhysicsServer3D.set_active(true)


<!-- keywords: Scaling, collision, physics, instantiate -->
### Scaling physics bodies or collision shapes is NOT supported — change the shape's size instead; duplicate() before per-instance resize
Physics shape gotchas:
- Godot does NOT support scaling CollisionShape2D/3D nodes. Change the shape's size/radius directly instead.
- Collision shape resources are SHARED by default. If you resize one, ALL instances using it change. Call .duplicate() on the shape resource before modifying.
- Cylinder collision shapes are buggy in GodotPhysics. Use box (most reliable) or capsule instead. Jolt physics handles cylinders better.
- Tunneling (fast objects passing through walls): enable Continuous CD, use thicker colliders, or increase physics tick rate (prefer multiples of 60: 120, 180, 240).


<!-- keywords: Physics, MUST, physics, _process, Node, delta, _physics_process, error, RayCast2D, RayCast3D, RayCast -->
### Physics space queries (raycast from code) MUST be done inside _physics_process(); accessing from _process() errors
Direct physics queries (raycasts, shape casts) via PhysicsDirectSpaceState must be called from _physics_process(), NOT _process() or _ready(). The physics space is LOCKED outside of physics steps.
```gdscript
func _physics_process(delta):
    var space = get_world_3d().direct_space_state
    var query = PhysicsRayQueryParameters3D.create(from, to)
    var result = space.intersect_ray(query)
    if result:
        print(result.position)
```
RayCast2D/RayCast3D nodes handle this automatically (results available every frame). Use code queries only when you need dynamic parameters.


<!-- keywords: Multiplayer, HTML5, network -->
### Multiplayer uses UDP only — forward UDP port (not just TCP); HTML5 has no raw TCP/UDP
Networking gotchas:
- Godot high-level multiplayer is UDP only (ENet). Router port forwarding must be UDP, not TCP.
- HTML5/Web platform: no raw TCP or UDP access. Only WebSocket and WebRTC are available.
- Multiplayer API uses SceneTree; any networked game must handle security (no server-side validation = exploitable).


<!-- keywords: CollisionShape, DIRECT, PhysicsBody, collision, physics, CollisionShape2D -->
### CollisionShape must be DIRECT child of PhysicsBody — indirect children (grandchildren) are silently ignored
CollisionShape2D/3D nodes must be immediate children of the PhysicsBody. If nested inside another node (e.g., a Node3D organizer), the shape won't be used for collision. Also, concave/trimesh shapes can ONLY be used with StaticBody (not CharacterBody or RigidBody unless frozen/static mode). Concave shapes have no 'volume' — objects can exist both inside and outside.


<!-- keywords: DIRECTION, CHANGES, move_and_slide, CharacterBody, velocity, collision, property -->
### move_and_slide() silently modifies the velocity property; get_slide_collision_count() only counts DIRECTION CHANGES
After calling move_and_slide(), the CharacterBody's velocity is automatically altered to reflect sliding/collision response. Do NOT re-assign velocity after the call if you want the slide result. Also, get_slide_collision_count() only counts collisions where the body changed direction, not every surface contact.


<!-- keywords: Jolt, Physics, DEFAULT, Godot, OPPOSITE, physics, RigidBody3D, int -->
### Jolt Physics is the default 3D engine for NEW projects since Godot 4.6; single-body joints behave OPPOSITE to Godot Physics
Jolt gotchas:
- Projects created in 4.6 or later use Jolt for 3D by default; older projects keep GodotPhysics until switched in Project Settings > Physics > 3D > Physics Engine. Many joint soft-limit properties (bias, softness, relaxation) are ignored.
- Single-body joints: Jolt assigns the body to node_b (Godot Physics uses node_a), giving INVERTED limits.
- Ray-cast face_index always returns -1 by default (opt-in setting, costs +25% memory for ConcavePolygonShape3D).
- Kinematic RigidBody3D contacts are NOT reported by default (opt-in via project setting).
- Collision margins work differently: Jolt shrinks shape then applies shell (size preserved but corners rounded).


<!-- keywords: Avoid, CollisionShapes, collision, physics, CollisionShape -->
### Avoid translating/rotating/scaling CollisionShapes at runtime — breaks physics engine broad-phase optimization
The physics engine's broad phase can efficiently discard inactive bodies only when StaticBody has a single non-transformed collision shape. Transforming shapes forces expensive narrow-phase checks against every shape. For dynamic objects, keep shapes at origin and adjust the PhysicsBody transform instead.


<!-- keywords: Physics, PAST, DISABLE, physics, Camera, mouse, int -->
### Physics interpolation shows objects 1-2 ticks IN THE PAST; camera mouse-look should DISABLE interpolation
Physics interpolation (disabled by default) smooths motion between physics ticks by interpolating between PREVIOUS and CURRENT tick transforms. This means visual positions lag 1-2 ticks behind actual physics state. Gotchas:
- Child with interpolation OFF still interpolates if PARENT has interpolation ON (interpolation is on local transform)
- For cameras: disable auto interpolation, use get_global_transform_interpolated() to follow target, handle mouse look in _process() without interpolation
- get_global_transform_interpolated() is expensive — use only for cameras, not everywhere in gameplay code


<!-- keywords: SoftBody3D, CollisionShape3D, Simulation, Precision, collision, physics, Mesh, MeshInstance3D, mesh -->
### SoftBody3D: NO CollisionShape3D child — collision derived from mesh; Simulation Precision below 5 causes collapse
SoftBody3D does NOT use CollisionShape3D children. Collision is derived directly from the mesh geometry. Gotchas:
- Simulation Precision below 5 causes the soft body to collapse into itself
- Pressure > 0 only works on CLOSED meshes — open meshes fly around uncontrollably
- Physics interpolation does NOT affect SoftBody3D nodes (only rigid/character bodies)
- Jolt physics significantly improves soft body behavior vs Godot Physics
- Soft body mesh must be linked to a MeshInstance3D — set the mesh path in the SoftBody3D inspector


<!-- keywords: Scene, TileMapLayer, HIGHER, BEFORE, scene, Texture, texture, TileSet, tile, import, performance -->
### Scene tiles in TileMapLayer have HIGHER performance cost; set tile size BEFORE importing atlas texture
TileSet gotchas:
- Scene tiles (tiles that instance a scene) have significantly higher performance overhead than atlas tiles — each is instantiated as a separate scene
- Tile size in TileSet must be set BEFORE importing the atlas image. Changing tile size after import requires reimporting
- TileMapLayer uses a y-sort origin per tile for correct depth sorting — origin is at tile TOP by default in isometric mode
- Navigation baking via TileSet navigation layer requires NavigationRegion2D to be present in the scene


<!-- keywords: Ragdoll, collision, physics, Bone -->
### Ragdoll: collision layers must differ from character capsule or bones collide with each other on activation
Ragdoll system gotchas:
- Physical bones and the character's capsule CollisionShape must be on DIFFERENT collision layers, or the ragdoll bones collide with the capsule and bounce uncontrollably when simulation starts
- physical_bones_start_simulation() with nonexistent bone names produces NO error or warning — bones simply don't simulate, leaving the character motionless
- Default PinJoint type causes visual 'crumpling' of characters — change to HingeJoint3D or ConeTwistJoint3D for anatomically correct ragdolls
- Adjusting a joint's rotation ALSO rotates its collision shape — adjust joints before collision shapes to avoid double-work


<!-- keywords: Physics, collision, physics, _physics_process, int, 3D -->
### Physics interpolation: transforms changed outside _physics_process() cause jitter; 3D collision shapes don't interpolate
Physics interpolation additional gotchas:
- Setting object transforms (or their parent transforms) outside _physics_process() makes interpolation incorrect — may only appear on some players' hardware depending on frame timing
- In 3D: visible collision shape outlines do NOT reflect physics interpolation, appearing slightly ahead of the visual mesh. This is a known limitation (2D correctly shows interpolation)
- Order for initial placement: set transform → reset_physics_interpolation() → then set the first physics-tick transform. Wrong order causes streaking from origin


<!-- keywords: Godot, SceneMultiplayer, TileMap, Android, scene, Node, tile -->
### Godot 4.3 breaking changes: SceneMultiplayer protocol incompatible with 4.2; TileMap layers became separate nodes; Android auto-permissions removed
Upgrading to 4.3 gotchas:
- SceneMultiplayer: caching changed to send ID instead of node path — 4.2 and 4.3 clients CANNOT communicate with each other, no graceful degradation
- TileMap layers are now individual TileMapLayer nodes — complex tilemap setups require significant refactoring
- Android: permissions are NO LONGER requested automatically — must call request_permission() explicitly or apps silently fail
- Reverse-Z depth buffer was introduced in 4.3 — custom depth-reading shaders break without manual updates (POSITION must use 1.0 for near, not 0.0)
- auto_translate inheritance changed: parent with auto_translate=false now cascades to children, possibly silently disabling translations


<!-- keywords: RPCs, BOTH, Node, add_child, RPC -->
### RPC: ALL RPCs must exist on BOTH peers; dynamic add_child() nodes need force_readable_name=true or RPCs silently fail
High-level multiplayer RPC gotchas:
- RPC signatures are verified by a CHECKSUM of ALL RPCs in the script. If any peer has a different set of RPCs (even unused ones), ALL RPCs fail for that script — no partial matching
- Dynamic nodes added via add_child() get auto-generated names (e.g., '@@2'). These names differ between peers, causing NodePath mismatch and silently failing RPCs. Fix: use `add_child(node, true)` (force_readable_name=true)
- High-level multiplayer uses UDP ONLY — port forwarding for WAN hosting must be UDP, not TCP
- RPC function argument count is NOT validated during checksum — `func foo()` and `func foo(a, b)` match each other, causing runtime mismatch without checksum failure


<!-- keywords: Web, _process, Input, input, export -->
### Web export: background tab silently stops _process(); fullscreen/cursor capture requires an input event callback
Web/HTML5 export gotchas:
- When the user switches to another browser tab, `_process()` and `_physics_process()` STOP RUNNING silently. Networked games will disconnect without realizing why.
- Fullscreen mode and cursor capture (`Input.mouse_mode = Input.MOUSE_MODE_CAPTURED`) CANNOT be called from regular code — must be called from within an active input event callback (_input, _unhandled_input). Calling from _ready() or a button's pressed signal does NOT work.
- Audio autoplay is BLOCKED by browsers — user must interact (click/tap/key) before any audio plays. Display a splash/start screen.
- Gamepads are not detected until the user presses a button (browser privacy limitation)
- Service worker caching shows OLD project version — must manually unregister service worker in browser DevTools after deploying an update
- Threaded web exports require CORS headers: `Cross-Origin-Opener-Policy: same-origin` AND `Cross-Origin-Embedder-Policy: require-corp`. Missing these causes threaded export to silently fail.
- .wasm file must be served with `application/wasm` MIME type or startup optimizations are bypassed


<!-- keywords: PhysicsDirectSpaceState, LOCKED, physics, _process, _physics_process, RayCast -->
### PhysicsDirectSpaceState is LOCKED outside _physics_process() — only do raycasts/shape queries there
Physics raycasting gotchas:
- PhysicsDirectSpaceState (used for ray_intersect, shape_intersect, etc.) is LOCKED outside of `_physics_process()`. Calling it from `_input()`, `_process()`, or other callbacks causes errors.
- Must pass `collide_with_areas = true` in query params to detect Area2D/3D hits — by default, only physics bodies are hit
- Use `query.exclude = [get_rid()]` to prevent self-collision on character body raycasts
- Cylinder CollisionShape3D is UNSTABLE in physics simulation — use boxes or capsules instead
- Scaling a physics body (set_scale()) does NOT work — change the collision shape's size/radius directly
- Stacked physics objects wobble at 60 physics ticks/second — increase to a multiple of 60 (120, 180, 240) for stability


<!-- keywords: Pausing, Always, physics, Node -->
### Pausing: physics disabled even for Always-process nodes — must call set_active(true) on physics server
Pausing gotchas:
- When SceneTree is paused, physics is DISABLED for ALL nodes — even nodes with ProcessMode = ALWAYS. To re-enable physics for specific operations while paused, call `PhysicsServer3D.set_active(true)` (and reset after).
- Signals fire on PAUSED nodes — callback code executes even if the node cannot process. Check pause state manually in signal callbacks if needed.
- Process mode INHERIT (default) means 'whatever my parent does' — if no ancestor explicitly sets a non-Inherit mode, SceneTree.paused controls everything


<!-- keywords: SpringArm3D, DIRECT, collision, Camera, camera -->
### SpringArm3D: camera must be DIRECT child for pyramid collision; any assigned shape disables the camera pyramid
SpringArm3D (camera collision) gotchas:
- SpringArm3D uses the camera's frustum pyramid shape for collision ONLY if the camera is a DIRECT child. Nested cameras (grandchildren) fall back to a simple raycast — inaccurate for camera collision.
- Assigning ANY shape to SpringArm3D's Shape property COMPLETELY DISABLES the camera pyramid detection, even if you intended them to work together. Remove the explicit shape to use the camera pyramid.


<!-- keywords: FRAME, STALE, physics, _process, threading -->
### _process() reads physics state ONE FRAME STALE — physics runs before _process() in single-threaded mode
In single-threaded execution, _physics_process() runs before _process(). Physics body positions read in _process() reflect the physics state AFTER the step that just completed, but before the next one — so position is one physics frame behind current visual intent.


<!-- keywords: NavigationAgent, IGNORED, NavigationAgent3D, navigation, NavigationMesh, navmesh, mesh -->
### NavigationAgent: agent radius is IGNORED by navmesh — you must manually shrink the baked navmesh to account for agent size
The agent_radius on NavigationAgent3D only affects RVO avoidance calculations. The navmesh itself has no knowledge of agent size — it describes where the center point can move. To prevent agents from clipping walls, set the 'Agent Radius' in NavigationMesh bake settings to shrink the walkable area before baking.


<!-- keywords: Navigation, AFTER, NavigationServer, navigation -->
### Navigation region layers changed at runtime only take effect AFTER the next NavigationServer sync frame
Changing navigation_layers on a NavigationRegion3D/2D at runtime does NOT take effect immediately. The NavigationServer processes the change at its next synchronization step (end of physics frame). Path queries issued in the same frame as the layer change may use the old layer mask.


<!-- keywords: Controller, Windows, XInput, SILENTLY, Input, input -->
### Controller input: Windows supports max 4 XInput controllers — additional controllers are SILENTLY ignored
On Windows, Godot uses the XInput API which has a hard limit of 4 simultaneous controllers. Controllers 5 and beyond are silently not recognized. If you need more than 4, use the DirectInput backend (requires a plugin) or target Linux/macOS.


<!-- keywords: InputEventMouseMotion, CENTER, Input, input, mouse -->
### InputEventMouseMotion in MOUSE_MODE_CAPTURED: event.position returns screen CENTER, not cursor position — use event.relative
When the mouse is captured (Input.MOUSE_MODE_CAPTURED), the cursor is locked to the center of the screen. event.position will always return the screen center, not meaningful cursor coordinates. For FPS-style camera rotation, always use event.relative or event.screen_relative instead.


<!-- keywords: Controller, Button, pressed, keyboard, Input, InputEvent -->
### Controller buttons do NOT generate 'echo' events when held — keyboard repeat is NOT available for controllers
Keyboard keys generate repeated InputEvent when held down (echo=true). Controller buttons never do. If you need repeated fire or menu scroll from a held button, you must implement your own timer-based repeat using Input.is_action_pressed() in _process().


<!-- keywords: NavigationLink, navigation, pathfinding, animation -->
### NavigationLink does NOT move agents — game code must provide all movement (teleport, animation, etc.)
A NavigationLink tells the pathfinder 'these two points are connected', but does NOTHING to move the agent across the gap. You must write code to detect when the agent reaches the link start, then teleport or animate it to the link end. Without this, agents will walk off ledges or into walls trying to follow the link.


<!-- keywords: NavigationLink, DISABLES, ITSELF, navigation, navmesh, mesh -->
### NavigationLink silently DISABLES ITSELF if no navmesh polygon is found within its search radius
When a NavigationLink is placed, it searches for the nearest navmesh polygon within its connection_radius. If none is found (link is too far from the navmesh), the link silently disables with no error. Check that both link endpoints are above or very near the navmesh surface.


<!-- keywords: Navigation, UNREACHABLE, navigation, pathfinding, Mesh, mesh -->
### Navigation path queries to UNREACHABLE targets are much slower than reachable ones — pathfinding exhausts the entire mesh
When a target is reachable, A* exits early once the goal is found. When the target is unreachable, pathfinding must visit EVERY polygon in the mesh to confirm unreachability. Having agents frequently query paths to unreachable positions can cause severe CPU spikes. Pre-validate reachability or throttle queries.


<!-- keywords: NavigationAgent, EVERY, FRAME, NavigationAgent3D, navigation, pathfinding -->
### NavigationAgent: setting target_position EVERY FRAME requests a new path every frame — only update when target moves significantly
NavigationAgent3D/2D requests a complete path recalculation whenever target_position changes. Setting it in _process() to a moving target triggers a full pathfind every frame. Only update target_position when the target moves more than path_desired_distance, or use a timer to throttle recalculation.


<!-- keywords: Motion, DISABLED, Input, input -->
### Controller motion sensors (gyroscope, accelerometer) are DISABLED by default — enable them with Input.set_joy_motion_sensors_enabled() (recent versions only: check with `gd api class Input`)
Controller gyroscope and accelerometer sensors must be explicitly enabled with Input.set_joy_motion_sensors_enabled(device, true) (check Input.has_joy_motion_sensors(device) first) or they produce no data and silently drain battery. Also: accelerometer reports GRAVITY by default, so values immediately after stopping still show movement from gravity cancellation.


<!-- keywords: Keyboard, SILENTLY, keyboard -->
### Keyboard ghosting: multiple simultaneous keys can be SILENTLY missed — test key layouts on physical hardware
Most keyboards can only detect 2-6 simultaneous key presses depending on the key matrix. Certain combinations (especially on the same keyboard row) silently fail to register. WASD+Shift+Space is a common problem combination. Test movement + action combinations on real hardware, not only in the editor.


<!-- keywords: Emulate, Touch, From, Mouse, mouse, Input -->
### 'Emulate Touch From Mouse' only works on NON-touchscreen devices — mouse does not perfectly emulate touch
The project setting 'Input Devices > Pointing > Emulate Touch From Mouse' lets you test touch in the editor on desktop. However, mouse doesn't generate multi-touch events, and the behavior differs from real touch (no pressure, no touch ID pooling). Always test touch-specific UI on a real touch device before release.


<!-- keywords: Custom, Web, rendering, mouse, Input -->
### Custom mouse cursor: max 256x256 on desktop, max 128x128 on Web — larger sizes cause rendering issues
Input.set_custom_mouse_cursor() has platform size limits. Web browsers enforce a 128x128 maximum; larger cursors are silently cropped or broken. Desktop platforms support up to 256x256 but behavior varies. Always provide cursors within these limits and test on the web platform explicitly.


<!-- keywords: NavigationServer, STILL, DISABLED, navigation, Node, global -->
### NavigationServer: -noimp suffix STILL works even when 'nodes/use_node_type_suffixes' is DISABLED globally
The -noimp suffix in 3D scene names (which removes nodes from the imported scene) is special — it cannot be globally disabled unlike other name suffixes. Even with node_type_suffixes disabled, nodes named with -noimp will still be removed on import.


<!-- keywords: NavigationPolygon, FAIL, EXACT, navigation, int, float -->
### NavigationPolygon: overlapping or intersecting outlines FAIL to bake silently — vertex merging requires EXACT float equality
NavigationPolygon outlines must not overlap or intersect. Also, for two navmesh regions to connect, their edge vertices must match exactly (bit-for-bit float equality). Even positions that appear identical in the editor but differ by a floating-point epsilon will prevent edge connection. Use snapping when placing nav regions.


<!-- keywords: NavigationRegion, navigation, NavigationRegion3D, navmesh, mesh -->
### NavigationRegion: changing scale does NOT update the navmesh on the server — must manually rebake
Scaling a NavigationRegion3D/2D node at runtime does not trigger a navmesh update on the NavigationServer. The navmesh is baked in local space at a specific time and remains at that scale. You must call bake_navigation_mesh() again after scaling to get a correctly-scaled navmesh.


<!-- keywords: NavigationRegion, NavigationAgent, navigation, NavigationRegion3D -->
### NavigationRegion: disabling/enabling at runtime does NOT update existing paths — agents keep old paths through disabled regions
When you toggle enabled on a NavigationRegion3D/2D, current agents are NOT notified. They continue following their last computed path even if it now passes through the disabled region. Force path recalculation by resetting NavigationAgent target_position after toggling regions.


<!-- keywords: NavigationRegion, SILENTLY, REMOVES, navigation -->
### NavigationRegion: assigning to a new map SILENTLY REMOVES it from the old map — regions can only belong to ONE map
A navigation region can only be registered to a single NavigationMap. Calling NavigationServer.region_set_map() with a new map automatically removes it from the previous map. There's no error or warning — it simply disappears from the old map.


<!-- keywords: Navigation, WRONG, navigation, pathfinding -->
### Navigation path_search_max_distance set too LOW causes paths to go in WRONG direction — not just short paths
The path_search_max_distance parameter on NavigationPathQueryParameters limits how far the pathfinder searches. If set too low, pathfinding may return a path to a local nearby point rather than toward the target, causing agents to walk the WRONG direction. Set this only as a deliberate optimization for known limited-range queries.


<!-- keywords: collision_layer, collision_mask -->
### Collision layer bitmask vs Inspector layer index
In code, `collision_layer` and `collision_mask` are BITMASKS, NOT the layer number shown in the Inspector.
Inspector Layer 1 = bitmask 1 (2^0)
Inspector Layer 2 = bitmask 2 (2^1)
Inspector Layer 3 = bitmask 4 (2^2)
Inspector Layer 4 = bitmask 8 (2^3)
So `collision_layer = 4` means Inspector Layer 3, NOT Layer 4. Use powers of 2.
Example: to put a body on Inspector Layer 2 and collide with Layer 1:
  body.collision_layer = 2   # bitmask for layer 2
  body.collision_mask  = 1   # bitmask for layer 1


<!-- keywords: collision_mask -->
### Default collision_mask = 1 misses non-default layers
New physics bodies always start with `collision_mask = 1` (only layer 1). If terrain/walls use layer 2+, the player falls through with NO error message. Always explicitly set `collision_mask` to include all layers the body must collide with.


<!-- keywords: CharacterBody3D, MOTION_MODE_FLOATING, motion_mode, floor_stop_on_slope -->
### CharacterBody3D: MOTION_MODE_FLOATING is for movement without a floor
FLOATING has no floor: `is_on_floor()` is always false, so it suits space or swimming, not a game with gravity. With a floor (vehicles, snowboards, walking on slopes) keep the default GROUNDED and tune `floor_stop_on_slope`, `floor_max_angle` and `floor_snap_length` instead.
CORRECT for movement with no floor (space, underwater):
  body.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING


<!-- keywords: _physics_process, target_position, follow_speed -->
### Camera lerp from origin glitch
Cameras using `lerp()` in `_physics_process()` will visibly swoop from `(0, 0, 0)` on the first frame. Fix with an `_initialized` flag:
```gdscript
var _initialized := false
func _physics_process(delta: float) -> void:
    if not _initialized:
        position = target_position  # snap on frame 1
        _initialized = true
        return
    position = position.lerp(target_position, follow_speed * delta)
```


<!-- keywords: CollisionShape -->
### 2D collision shape slightly smaller than tile for smooth movement
For grid-based 2D games, make the collision shape slightly smaller than the tile (e.g., 48px CollisionShape in a 64px grid). Without this, characters snag on corridor entrances and can't pass through 1-tile-wide corridors.


<!-- keywords: TileMapLayer, get_coords_for_body_rid, physics_quadrant_size, get_cell_source_id -->
### TileMapLayer (Godot 4.3+) — physics quadrant chunking changes get_coords_for_body_rid()
In Godot 4.5+, `TileMapLayer` enables physics quadrant chunking by default (`physics_quadrant_size` is non-zero). This means `get_coords_for_body_rid(rid)` may return wrong tile coordinates if the body spans a quadrant boundary or if quadrant size is large. To get reliable per-tile coords from a physics body RID, either:
- Call `get_coords_for_body_rid()` as usual but verify with `get_cell_source_id(coords) != -1`
- Or set `physics_quadrant_size = 1` (the value that disables merging) to get exact cell coordinates if precision is critical.


<!-- keywords: TileMap, TileMapLayer, Node2D -->
### TileMap is deprecated — use TileMapLayer (Godot 4.3+)
The old `TileMap` node still exists for compatibility but is deprecated. All new projects should use one or more `TileMapLayer` nodes directly as children of the scene root or a Node2D. Each `TileMapLayer` represents one layer (previously `TileMap` had multiple layers).
WRONG:  var tm = TileMap.new()  # deprecated
CORRECT: var layer = TileMapLayer.new()  # one node per layer


<!-- keywords: RigidBody2D, body_entered, body_exited, get_colliding_bodies, contact_monitor, max_contacts_reported -->
### RigidBody2D: contact monitoring requires both flags set
To receive `body_entered`/`body_exited` signals and use `get_colliding_bodies()`, you MUST set BOTH:
  body.contact_monitor = true
  body.max_contacts_reported = 4  # or however many contacts you need
Setting only one has no effect. Collision results are one physics frame delayed.
