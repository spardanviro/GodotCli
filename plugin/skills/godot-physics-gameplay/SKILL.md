---
name: godot-physics-gameplay
description: Gameplay building blocks in Godot 4, 2D and 3D - character movement (CharacterBody, move_and_slide), rigid bodies, areas and triggers, collision shapes, layers and masks, raycasts, input actions, cameras that follow, tile maps, navigation and pathfinding, spawning. Use when making something move, collide, be controlled by the player or find its way.
---

# Movement, collisions, input, tile maps and navigation

Scenes and nodes are built with `gd command ...` (the `godot-cli` skill); scripts follow `godot-gdscript`.
Search `references/gotchas.md` for the classes you use before writing: physics has more silent failure modes than
any other part of the engine.

## Which body

| Node | For | Moved by |
|---|---|---|
| `CharacterBody2D/3D` | players, enemies, anything you steer | setting `velocity`, then `move_and_slide()` |
| `RigidBody2D/3D` | things the physics engine throws around: crates, balls, debris | forces and impulses; never by setting `position` each frame |
| `StaticBody2D/3D` | floors, walls, anything that does not move | nothing |
| `AnimatableBody2D/3D` | moving platforms, doors | an animation or code moving it; it pushes other bodies |
| `Area2D/3D` | triggers, pickups, hitboxes, damage zones: detects, does not block | nothing; emits `body_entered`, `area_entered` |

Every one of them needs a `CollisionShape2D/3D` child **with a shape**, or it collides with nothing:

```bash
gd command node_create --type CharacterBody2D --name Player --properties '{"position": [200, 100]}'
gd command node_create --type CollisionShape2D --parent Player --name Shape \
  --properties '{"shape": {"$new": "CapsuleShape2D", "properties": {"radius": 14, "height": 44}}}'
```

Shapes: `RectangleShape2D` (`size`), `CircleShape2D` (`radius`), `CapsuleShape2D` (`radius`, `height`);
`BoxShape3D` (`size`), `SphereShape3D`, `CapsuleShape3D`, `CylinderShape3D`. Size a shape through its properties.
**Never scale a collision shape node or a body**: collisions go wrong without an error.

## Character movement

Platformer (2D), in `_physics_process`:

```gdscript
extends CharacterBody2D

@export var speed := 220.0
@export var jump_velocity := -420.0

var _gravity: float = ProjectSettings.get_setting("physics/2d/default_gravity")


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y += _gravity * delta
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity
	velocity.x = Input.get_axis("move_left", "move_right") * speed
	move_and_slide()
```

Top-down (2D): set `motion_mode` to floating on the node (`{"motion_mode": "MOTION_MODE_FLOATING"}`), no gravity:

```gdscript
func _physics_process(_delta: float) -> void:
	velocity = Input.get_vector("move_left", "move_right", "move_up", "move_down") * speed
	move_and_slide()
```

3D is the same with `Vector3`; gravity is `physics/3d/default_gravity` and acts on `velocity.y` downward (subtract).
Build the direction from the input vector and the node's basis:
`var direction := (transform.basis * Vector3(input.x, 0, input.y)).normalized()`.

The rules that go wrong most:

- `move_and_slide()` takes no argument and applies the time step itself. **Do not multiply `velocity` by `delta`.**
  Gravity is an acceleration: that one is multiplied by `delta`.
- Movement code belongs in `_physics_process`, not `_process`.
- `is_on_floor()` is only meaningful after `move_and_slide()` has run.
- A complete, tested walk through this is in the `godot-cli` skill: `references/walkthrough-platformer.md`.

## Input

Actions are registered in the project before a script reads them:

```bash
gd command project_input_map
gd command project_input_map_set --action jump --events '[{"key": "Space"}, {"joypad_button": 0}]' --yes
gd command project_input_map_set --action shoot --events '[{"mouse_button": 1}]' --yes
```

Event forms: `{"key": "Space"}`, `{"mouse_button": 1}`, `{"joypad_button": 0}`, `{"joypad_axis": 0, "axis_value": -1}`.
Scripts use exactly the names registered. `Input.get_axis(negative, positive)` for one axis,
`Input.get_vector(left, right, up, down)` for two (already normalised with a circular dead zone),
`is_action_just_pressed` for things that happen once per press. One-off events (pause, shoot on click) are handled
in `_unhandled_input(event)` so that UI gets them first.

Test input without a person: `gd command game_input --action jump --hold 0.1` on a game started with `editor_play`.

## Layers and masks

`collision_layer` is where an object **is**; `collision_mask` is what it **looks for**. A collision needs the
mask of one to contain the layer of the other. Both are bit fields: layer 1 is value 1, layer 2 is 2, layer 3 is 4,
layer 4 is 8.

```bash
gd command node_set --path Player --properties '{"collision_layer": 1, "collision_mask": 6}'    # is on 1, sees 2 and 3
gd command node_set --path Coin   --properties '{"collision_layer": 8, "collision_mask": 1}'    # is on 4, sees the player
```

In code `set_collision_layer_value(3, true)` takes the layer **number** (1-based), not the bit value. Decide the
layers once (world, player, enemies, pickups) and note them where the project keeps its notes.

## Triggers, pickups, hitboxes

An `Area2D` with a shape, and a signal connected in the scene:

```bash
gd command node_create --type Area2D --name Coin --properties '{"position": [400, 250]}'
gd command node_create --type CollisionShape2D --parent Coin --name Shape \
  --properties '{"shape": {"$new": "CircleShape2D", "properties": {"radius": 10}}}'
# write res://scripts/coin.gd with func _on_body_entered(body: Node2D) -> void, then:
gd command node_attach_script --path Coin --script res://scripts/coin.gd
gd command node_connect_signal --path Coin --signal body_entered --target Coin --method _on_body_entered
```

Inside such a callback physics is being stepped: free the node with `queue_free()`, and change physics state with
`set_deferred` / `call_deferred` (see `godot-gdscript`). `body_entered` fires for bodies, `area_entered` for other
areas. A `RigidBody` reports contacts only with `contact_monitor` on and `max_contacts_reported` above 0.

## Raycasts

A `RayCast2D/3D` node for a ray that is always there (ground check, line of sight): set `target_position`
(relative to the node) and `collision_mask`; read `is_colliding()`, `get_collider()`, `get_collision_point()`.
It updates once per physics frame; call `force_raycast_update()` after moving it in the same frame.
One-off queries go through `get_world_2d().direct_space_state.intersect_ray(...)`, and only inside
`_physics_process`.

## Camera

2D: a `Camera2D` as a child of the player follows it. Set `position_smoothing_enabled` for a softer follow and
`limit_left/right/top/bottom` to keep it inside the level. There is no `current` property to set; the camera in the
scene is used when the game runs.

3D: a `Camera3D` under a pivot node that follows the player; put a `SpringArm3D` between them to keep the camera
out of walls. Mouse look rotates the body around Y and the pivot around X; never accumulate both on one node.

## Tile maps

`TileMapLayer` is the node (one layer each); `TileMap` is deprecated since 4.3. The `godot-tilemap` skill has the
whole workflow; in short:

```bash
gd command node_create --type TileMapLayer --name Ground
gd command tileset_add_atlas --layer Ground --texture res://art/tiles.png --tile-size '[16, 16]' --collision true
gd command tilemap_set_cells --layer Ground --rect '[0, 10, 40, 2]' --atlas '[1, 0]'
```

With `--collision true` every tile of the image is solid, on collision layer 1. Slopes and one-way platforms
(`tileset_set_collision`) and terrains that pick their own tiles (`tileset_set_terrain`) are in that skill too.

## Navigation

- 2D: a `NavigationRegion2D` with a `NavigationPolygon` covering the walkable area; 3D: a `NavigationRegion3D` with a
  baked `NavigationMesh`. The agent is a `NavigationAgent2D/3D` child of the character.
- The map is not ready in `_ready()`. Set the target after the first physics frame:
  ```gdscript
  func _ready() -> void:
  	await get_tree().physics_frame
  	_agent.target_position = target.global_position

  func _physics_process(_delta: float) -> void:
  	if _agent.is_navigation_finished():
  		return
  	var next := _agent.get_next_path_position()      # once per physics frame
  	velocity = global_position.direction_to(next) * speed
  	move_and_slide()
  ```
- Bake from here. 2D: give the walkable area as an outline; obstacles under the region are cut out of it.
  3D: the mesh is baked from the geometry under the region.
  ```bash
  gd command node_create --type NavigationRegion2D --name Nav
  gd command navigation_bake --region Nav --outline '[[0, 0], [640, 0], [640, 360], [0, 360]]'
  gd command navigation_bake --region World/Nav3D
  ```
  It is one undo step. The answer has the number of polygons; 0 means nothing walkable was found (what is parsed, meshes or static
  colliders and on which layers, is a property of the navigation mesh or polygon). A level that changes while the
  game runs is baked again from code (`bake_navigation_mesh()`, `bake_navigation_polygon()`).

## Spawning

```gdscript
const Bullet := preload("res://scenes/bullet.tscn")

func shoot() -> void:
	var bullet := Bullet.instantiate()
	bullet.global_position = $Muzzle.global_position
	get_tree().current_scene.add_child(bullet)       # the level, not the shooter
```

`preload` needs the scene to exist on disk when the script is written; if you create both in one go, save the
bullet scene first.

## Checking it

Run the game and read values instead of assuming (`references/running-game.md` in `godot-cli`):
`game_call --method is_on_floor`, `game_node_get` for `position` and `velocity` before and after a `game_input`,
`game_errors` for what the physics engine complained about.

- Falls through the floor: a body without a shape, a shape on the wrong layer, or a scaled shape.
- Does not move: no input action registered, movement in a script that is not attached, `velocity` multiplied by
  `delta`.
- Jitters: movement in `_process`, or a camera fighting physics interpolation.

## References

- `references/gotchas.md` - physics, input, navigation and tile map pitfalls. Search by class or method name.
- `references/api.md` - notes on the bodies, areas, shapes, raycasts, navigation agents, `TileMapLayer`, `Camera2D`.
