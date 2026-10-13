# Worked example: a 2D character that runs and jumps

The whole loop on a small task: register input, build the scene, write the script, run, test by playing.
Every command below was run as written against a real editor. Adapt names and numbers; keep the order.

## 1. Look first

```bash
gd doctor
gd command editor_status
gd command project_input_map
gd command fs_list --path res:// --recursive true
```

## 2. Input actions

A script that reads an action which does not exist fails at run time, so register them first.

```bash
gd command project_input_map_set --action move_left  --events '[{"key": "A"}, {"key": "Left"}]' --yes
gd command project_input_map_set --action move_right --events '[{"key": "D"}, {"key": "Right"}]' --yes
gd command project_input_map_set --action jump       --events '[{"key": "Space"}]' --yes
```

## 3. The scene

```bash
gd command scene_new --path res://scenes/main.tscn --root-type Node2D --root-name Main

gd command node_create --type CharacterBody2D --name Player --properties '{"position": [200, 100]}'
gd command node_create --type CollisionShape2D --parent Player --name Shape \
  --properties '{"shape": {"$new": "CapsuleShape2D", "properties": {"radius": 14, "height": 44}}}'
gd command node_create --type Polygon2D --parent Player --name Body \
  --properties '{"polygon": [[-14, -22], [14, -22], [14, 22], [-14, 22]], "color": "#4fa3ff"}'
gd command node_create --type Camera2D --parent Player --name Camera

gd command node_create --type StaticBody2D --name Ground --properties '{"position": [320, 300]}'
gd command node_create --type CollisionShape2D --parent Ground --name Shape \
  --properties '{"shape": {"$new": "RectangleShape2D", "properties": {"size": [640, 32]}}}'
gd command node_create --type Polygon2D --parent Ground --name Body \
  --properties '{"polygon": [[-320, -16], [320, -16], [320, 16], [-320, 16]], "color": "#3a3a3a"}'
```

Notes:

- A body needs a `CollisionShape2D` child with a shape, or it collides with nothing. The shape is sized through
  its own properties, never by scaling the node.
- `Polygon2D` gives something to look at without an image file. With art in the project, use a `Sprite2D` and
  `{"texture": {"$res": "res://art/player.png"}}`.
- A `Camera2D` under the player follows it.

## 4. The script

Write this to a scratch file outside the project, for example `/tmp/player.gd`:

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

```bash
gd command fs_write_text --path res://scripts/player.gd --text-file /tmp/player.gd
gd command node_attach_script --path Player --script res://scripts/player.gd
```

The answer of `fs_write_text` contains `"check": {"compiles": true}`. If it says `false`, fix the script before
going on.

Gravity is an acceleration and is multiplied by `delta`; `move_and_slide()` takes no argument and applies the time
step itself.

## 5. Save, make it the main scene, run

```bash
gd command scene_save
gd command project_settings_set --name application/run/main_scene --value res://scenes/main.tscn --yes
gd run --seconds 3 --headless
```

Setting the main scene is part of this task only because the user asked for something that runs. `gd run` should
answer `0 error(s), 0 warning(s)`.

## 6. Play it and check that it behaves

```bash
gd command editor_play
gd command game_call --path Main/Player --method is_on_floor          # true: it landed on the ground
gd command game_node_get --path Main/Player --properties '["position"]'
gd command game_input --action jump --hold 0.1
sleep 0.3
gd command game_node_get --path Main/Player --properties '["position"]'   # y is smaller (up is negative y): it is in the air
gd command game_input --action move_right --hold 1
sleep 1.3
gd command game_node_get --path Main/Player --properties '["position"]'   # x grew by about speed * 1 second
gd command game_errors
gd command editor_stop
```

If `is_on_floor` is false and `position.y` keeps growing, the player is falling through: check that both bodies
have shapes and that the ground is under the player.

## 7. Say what was done

One or two plain sentences: what exists now, where the files are, how to try it. No list of the commands that ran.
