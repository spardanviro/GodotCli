extends "res://tests/suite.gd"
## collision_shape_fit: a shape the size of the sprite or mesh beside it.

const Registry = preload("res://addons/gdcli/core/registry.gd")
const Schema = preload("res://addons/gdcli/core/schema.gd")
const ShapeCommands = preload("res://addons/gdcli/commands/shape_commands.gd")
const FakeContext = preload("res://tests/fake_context.gd")

var _context: RefCounted
var _registry: RefCounted
var _sets: Array = []
var _root: Node2D


func cleanup() -> void:
	if _root != null:
		_root.free()
		_root = null


func _setup() -> void:
	_root = Node2D.new()
	_root.name = "ShapeTestMain"
	var body := CharacterBody2D.new()
	body.name = "Player"
	body.position = Vector2(100, 100)
	_root.add_child(body)
	var sprite := Sprite2D.new()
	sprite.name = "Sprite2D"
	var image := Image.create(40, 60, false, Image.FORMAT_RGBA8)
	sprite.texture = ImageTexture.create_from_image(image)
	sprite.scale = Vector2(2, 2)
	sprite.offset = Vector2(0, -10)
	body.add_child(sprite)
	var holder := CollisionShape2D.new()
	holder.name = "CollisionShape2D"
	body.add_child(holder)
	var world := Node3D.new()
	world.name = "World"
	_root.add_child(world)
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2, 4, 2)
	mesh.mesh = box
	world.add_child(mesh)
	var holder3d := CollisionShape3D.new()
	holder3d.name = "Shape3D"
	world.add_child(holder3d)
	_context = FakeContext.new()
	_context.root = _root
	_context.path = "res://tests/fixtures/main.tscn"
	_registry = Registry.new()
	_sets = [ShapeCommands.new(_context)]
	for command_set in _sets:
		command_set.register(_registry)


func _fit(args: Dictionary) -> Dictionary:
	var validated := Schema.validate(args, _registry.descriptor_of("collision_shape_fit")["params"])
	if not validated["ok"]:
		return validated
	return _registry.handler_of("collision_shape_fit").call(validated["args"], {"dry_run": false, "confirm": false, "mode": "standard"})


func test_collision_shape_fit_sizes_a_rectangle_to_the_sprite() -> void:
	_setup()
	var holder: CollisionShape2D = _root.get_node("Player/CollisionShape2D")

	var reply := _fit({"shape": "Player/CollisionShape2D"})

	check(reply["ok"], "fitted: %s" % reply)
	equal((holder.shape as RectangleShape2D).size, Vector2(80, 120), "the texture's size times the sprite's scale")
	equal(holder.position, Vector2(0, -20), "moved to the drawn centre (the offset, scaled)")
	_context.undo.undo()
	check(holder.shape == null and holder.position == Vector2.ZERO, "one undo step")


func test_collision_shape_fit_makes_circles_capsules_and_3d_boxes() -> void:
	_setup()

	_fit({"shape": "Player/CollisionShape2D", "kind": "capsule", "margin": 0.5})
	var capsule := _root.get_node("Player/CollisionShape2D").shape as CapsuleShape2D
	_fit({"shape": "World/Shape3D"})
	var box := _root.get_node("World/Shape3D").shape as BoxShape3D

	equal([capsule.radius, capsule.height], [20.0, 60.0], "a capsule inside half the size")
	equal(box.size, Vector3(2, 4, 2), "a box around the mesh")


func test_collision_shape_fit_refuses_what_it_cannot_measure() -> void:
	_setup()
	(_root.get_node("Player/Sprite2D") as Sprite2D).texture = null

	equal(_fit({"shape": "Player/CollisionShape2D"})["error"]["code"], "PRECONDITION_FAILED", "a sprite without a texture")
	equal(_fit({"shape": "Player"})["error"]["code"], "TYPE_MISMATCH", "not a collision shape")
	equal(_fit({"shape": "Nope"})["error"]["code"], "NODE_NOT_FOUND", "no such node")
