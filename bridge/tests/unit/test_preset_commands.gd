extends "res://tests/suite.gd"
## preset_create: particles, animations and a camera, made with the commands underneath.

const AnimationCommands = preload("res://addons/gdcli/commands/animation_commands.gd")
const NodeEditCommands = preload("res://addons/gdcli/commands/node_edit_commands.gd")
const PresetCommands = preload("res://addons/gdcli/commands/preset_commands.gd")
const Registry = preload("res://addons/gdcli/core/registry.gd")
const Schema = preload("res://addons/gdcli/core/schema.gd")
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
	_root.name = "Main"
	var player := Sprite2D.new()
	player.name = "Hero"
	player.position = Vector2(100, 50)
	_root.add_child(player)
	player.owner = _root
	var anim := AnimationPlayer.new()
	anim.name = "Anim"
	_root.add_child(anim)
	anim.owner = _root
	_context = FakeContext.new()
	_context.root = _root
	_context.path = "res://tests/fixtures/main.tscn"
	_registry = Registry.new()
	_sets = [NodeEditCommands.new(_context), AnimationCommands.new(_context), PresetCommands.new(_context, _registry)]
	for command_set in _sets:
		command_set.register(_registry)


func _preset(args: Dictionary) -> Dictionary:
	var validated := Schema.validate(args, _registry.descriptor_of("preset_create")["params"])
	if not validated["ok"]:
		return validated
	return _registry.handler_of("preset_create").call(validated["args"], {"dry_run": false, "confirm": false, "mode": "standard"})


func test_preset_create_makes_a_particle_effect() -> void:
	_setup()

	var reply := _preset({"preset": "explosion", "target": "Hero", "color": "#66ccff"})
	var made := _root.get_node_or_null("Hero/Explosion") as GPUParticles2D

	check(reply["ok"] and made != null, "made: %s" % reply)
	var material := made.process_material as ParticleProcessMaterial
	check(material != null and material.color_ramp is GradientTexture1D, "a process material with a colour ramp")
	equal([made.one_shot, made.emitting, made.amount], [true, false, 48], "a one-shot effect, made ready but not fired")
	var first: Color = material.color_ramp.gradient.get_color(0)
	check(is_equal_approx(first.b, Color.html("#66ccff").b), "tinted")
	_context.undo.undo()
	check(_root.get_node_or_null("Hero/Explosion") == null, "one undo step")


func test_preset_create_makes_animations_from_the_nodes_values() -> void:
	_setup()

	var bob := _preset({"preset": "bob", "target": "Hero", "player": "Anim"})
	var fade := _preset({"preset": "fade_in", "target": "Hero", "player": "Anim", "name": "appear"})
	var player := _root.get_node("Anim") as AnimationPlayer

	check(bob["ok"] and fade["ok"], "made: %s %s" % [bob, fade])
	var animation := player.get_animation("bob")
	equal(animation.loop_mode, Animation.LOOP_LINEAR, "bob loops")
	equal([str(animation.track_get_path(0)), animation.track_get_key_value(0, 1)], ["Hero:offset", Vector2(0, -8)], "a sprite bobs by its offset, so it can be moved later")
	check(player.has_animation("appear"), "named as asked")


func test_preset_create_makes_a_following_camera_and_refuses_what_does_not_fit() -> void:
	_setup()

	check(_preset({"preset": "camera_follow", "target": "Hero"})["ok"], "camera")
	check((_root.get_node("Hero/Camera2D") as Camera2D).position_smoothing_enabled, "that follows smoothly")
	equal(_preset({"preset": "pulse", "target": "Hero"})["error"]["code"], "INVALID_ARGS", "an animation needs a player")
	equal(_preset({"preset": "pulse", "target": "Anim", "player": "Anim"})["error"]["code"], "TYPE_MISMATCH", "an AnimationPlayer has no position to move")
	equal(_preset({"preset": "fireworks", "target": "Hero"})["error"]["code"], "INVALID_ARGS", "an unknown preset")
	equal(_preset({"preset": "fire", "target": "Hero", "color": "blue-ish"})["error"]["code"], "INVALID_ARGS", "a colour it cannot read")


func test_preset_create_says_when_it_keys_a_position() -> void:
	_setup()
	var marker := Node2D.new()
	marker.name = "Marker"
	marker.position = Vector2(5, 5)
	_root.add_child(marker)
	marker.owner = _root

	var reply := _preset({"preset": "shake", "target": "Marker", "player": "Anim"})

	check(reply["ok"] and reply["warnings"].any(func(text: String) -> bool: return text.contains("make the preset again")), "warned: %s" % reply)
