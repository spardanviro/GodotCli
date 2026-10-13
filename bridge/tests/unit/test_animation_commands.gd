extends "res://tests/suite.gd"

const AnimationCommands = preload("res://addons/gdcli/commands/animation_commands.gd")
const Registry = preload("res://addons/gdcli/core/registry.gd")
const Schema = preload("res://addons/gdcli/core/schema.gd")
const FakeContext = preload("res://tests/fake_context.gd")

var _root: Node2D
var _player: AnimationPlayer
var _context: RefCounted
var _registry: RefCounted
var _commands: RefCounted


func cleanup() -> void:
	if _root != null:
		_root.free()
		_root = null


# Main (Node2D)
# ├─ Hero (Sprite2D)
# └─ Anim (AnimationPlayer)
func _scene() -> void:
	_root = Node2D.new()
	_root.name = "Main"
	var hero := Sprite2D.new()
	hero.name = "Hero"
	_root.add_child(hero)
	_player = AnimationPlayer.new()
	_player.name = "Anim"
	_root.add_child(_player)
	_context = FakeContext.new()
	_context.root = _root
	_registry = Registry.new()
	_commands = AnimationCommands.new(_context)
	_commands.register(_registry)


func _create(args: Dictionary, dry_run: bool = false) -> Dictionary:
	var validated := Schema.validate(args, _registry.descriptor_of("animation_create")["params"])
	if not validated["ok"]:
		return validated
	return _registry.handler_of("animation_create").call(validated["args"], {"dry_run": dry_run, "confirm": false, "mode": "standard"})


func _bounce() -> Dictionary:
	return {
		"player": "Anim", "name": "bounce", "length": 1.0, "loop": "linear",
		"tracks": [
			{"node": "Hero", "property": "position", "keys": [{"time": 0, "value": [0, 0]}, {"time": 0.5, "value": "Vector2(0, -40)"}, {"time": 1, "value": [0, 0]}]},
			{"node": "Hero", "property": "visible", "keys": [{"time": 0, "value": true}]},
		],
	}


func test_animation_create_builds_tracks_with_values_of_the_property_type() -> void:
	_scene()

	var reply := _create(_bounce())
	var animation: Animation = _player.get_animation("bounce")

	equal(reply["ok"], true, "created")
	equal(reply["data"]["tracks"], ["Hero:position", "Hero:visible"], "track paths relative to the node the player animates from")
	equal([animation.length, animation.loop_mode], [1.0, Animation.LOOP_LINEAR], "length and loop")
	equal(animation.track_get_key_value(0, 1), Vector2(0, -40), "a key converted to Vector2")
	equal(animation.value_track_get_update_mode(1), Animation.UPDATE_DISCRETE, "a bool changes at the keyframe")
	equal(reply["undo"], "gdcli: animation_create bounce", "one undo step")


func test_animation_create_is_undone_and_replaces_only_when_asked() -> void:
	_scene()
	_create(_bounce())
	var first: Animation = _player.get_animation("bounce")

	var again := _create(_bounce())
	var replaced := _create(_bounce().merged({"overwrite": true, "length": 2.0}, true))
	var second_length := _player.get_animation("bounce").length
	_context.undo.undo()
	var after_undo: Animation = _player.get_animation("bounce")
	_context.undo.undo()

	equal(again["error"]["code"], "ALREADY_EXISTS", "an existing animation is not replaced silently")
	equal([replaced["ok"], second_length], [true, 2.0], "replaced when asked")
	equal(after_undo, first, "undo brings the earlier animation back")
	check(not _player.has_animation("bounce"), "and a second undo removes it")


func test_animation_create_rejects_what_it_cannot_animate() -> void:
	_scene()
	var wrong_value: Dictionary = _bounce()
	wrong_value["tracks"] = [{"node": "Hero", "property": "position", "keys": [{"time": 0, "value": "up"}]}]
	var no_node: Dictionary = _bounce()
	no_node["tracks"] = [{"node": "Ghost", "property": "position", "keys": [{"time": 0, "value": [0, 0]}]}]
	var no_property: Dictionary = _bounce()
	no_property["tracks"] = [{"node": "Hero", "property": "speed", "keys": [{"time": 0, "value": 1}]}]
	var late_key: Dictionary = _bounce()
	late_key["tracks"] = [{"node": "Hero", "property": "position", "keys": [{"time": 5, "value": [0, 0]}]}]

	equal(_create(wrong_value)["error"]["code"], "TYPE_MISMATCH", "a value of the wrong type")
	equal(_create(wrong_value)["error"]["details"]["track"], 0, "the track is named")
	equal(_create(no_node)["error"]["code"], "NODE_NOT_FOUND", "an animated node that does not exist")
	equal(_create(no_property)["error"]["code"], "INVALID_ARGS", "a property the node does not have")
	equal(_create(late_key)["error"]["code"], "INVALID_ARGS", "a key after the end")
	equal(_create(_bounce().merged({"player": "Hero"}, true))["error"]["code"], "TYPE_MISMATCH", "a node that is not an AnimationPlayer")
	equal(_create(_bounce(), true)["data"]["dry_run"], true, "a dry run")
	check(not _player.has_animation("bounce"), "nothing was created by any of these")


func test_animation_list_describes_the_animations_and_autoplay() -> void:
	_scene()
	_create(_bounce().merged({"autoplay": true}))

	var reply: Dictionary = _registry.handler_of("animation_list").call({"player": "Anim"})

	equal(reply["data"]["autoplay"], "bounce", "autoplay")
	equal(reply["data"]["animations"], [{"name": "bounce", "library": "", "length": 1.0, "loop": "linear", "tracks": ["Hero:position", "Hero:visible"]}], "the animation")
