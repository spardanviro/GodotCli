extends "res://tests/suite.gd"

const NodeCommands = preload("res://addons/gdcli/commands/node_commands.gd")
const NodeRef = preload("res://addons/gdcli/core/node_ref.gd")
const Registry = preload("res://addons/gdcli/core/registry.gd")
const SceneCommands = preload("res://addons/gdcli/commands/scene_commands.gd")
const Schema = preload("res://addons/gdcli/core/schema.gd")
const FakeContext = preload("res://tests/fake_context.gd")

var _root: Node
var _registry: RefCounted
var _command_sets: Array = []


func cleanup() -> void:
	if _root != null:
		_root.free()
		_root = null


# Main (Node2D)
# ├─ Player (CharacterBody2D, position 10,20)
# │  └─ Sprite2D
# └─ World (Node, group "level")
#    └─ Enemy1, Enemy2 (Node2D)
func _build_scene() -> void:
	_root = Node2D.new()
	_root.name = "Main"
	var player := CharacterBody2D.new()
	player.name = "Player"
	player.position = Vector2(10, 20)
	_root.add_child(player)
	var sprite := Sprite2D.new()
	sprite.name = "Sprite2D"
	player.add_child(sprite)
	var world := Node.new()
	world.name = "World"
	world.add_to_group("level")
	world.add_to_group("_editor_internal")
	_root.add_child(world)
	for index in [1, 2]:
		var enemy := Node2D.new()
		enemy.name = "Enemy%d" % index
		world.add_child(enemy)

	var context := FakeContext.new()
	context.root = _root
	_registry = Registry.new()
	_command_sets = [SceneCommands.new(context), NodeCommands.new(context)]
	for command_set in _command_sets:
		command_set.register(_registry)


func _call(command: String, args: Dictionary) -> Dictionary:
	var validated := Schema.validate(args, _registry.descriptor_of(command)["params"])
	if not validated["ok"]:
		return validated
	return _registry.handler_of(command).call(validated["args"])


func test_node_ref_resolves_only_paths_inside_the_scene() -> void:
	_build_scene()

	equal(NodeRef.resolve(_root, "."), _root, "root")
	equal(NodeRef.resolve(_root, "Player/Sprite2D").name, &"Sprite2D", "nested")
	for path in ["", "..", "Player/..", "/root", "Player//Sprite2D", "Missing", "%Player", "Player/../.."]:
		equal(NodeRef.resolve(_root, path), null, "path '%s'" % path)


func test_scene_tree_returns_the_whole_tree_with_paths() -> void:
	_build_scene()

	var tree: Dictionary = _call("scene_tree", {})["data"]["tree"]

	equal(tree["name"], "Main", "root name")
	equal(tree["type"], "Node2D", "root type")
	equal(tree["path"], ".", "root path")
	equal(tree["children"][0]["path"], "Player", "child path")
	equal(tree["children"][0]["children"][0]["path"], "Player/Sprite2D", "grandchild path")
	equal(tree["children"][1]["groups"], ["level"], "editor-internal groups are hidden")


func test_scene_tree_depth_limit_reports_omitted_children() -> void:
	_build_scene()

	var tree: Dictionary = _call("scene_tree", {"max_depth": 1})["data"]["tree"]

	equal(tree["children"].size(), 2, "first level is present")
	equal(tree["children"][1]["children"], [], "second level is cut")
	equal(tree["children"][1]["children_omitted"], 2, "and counted")


func test_scene_tree_subtree_and_missing_path() -> void:
	_build_scene()

	equal(_call("scene_tree", {"path": "World"})["data"]["tree"]["children"].size(), 2, "subtree")
	var missing := _call("scene_tree", {"path": "Nowhere"})
	equal(missing["error"]["code"], "NODE_NOT_FOUND", "code")
	equal(missing["error"]["details"], {"path": "Nowhere"}, "the path is in details, not in the message")


func test_node_get_returns_tagged_properties() -> void:
	_build_scene()

	var data: Dictionary = _call("node_get", {"path": "Player", "properties": ["position", "visible"]})["data"]

	equal(data["type"], "CharacterBody2D", "type")
	equal(data["properties"]["position"], {"$type": "Vector2", "value": [10.0, 20.0]}, "position")
	equal(data["properties"]["visible"], true, "visible")


func test_node_get_lists_inspector_properties_by_default() -> void:
	_build_scene()

	var properties: Dictionary = _call("node_get", {"path": "Player"})["data"]["properties"]

	check(properties.has("position") and properties.has("collision_layer"), "inspector properties are listed")
	check(not properties.has("script"), "script is reported separately")


func test_node_get_rejects_unknown_nodes_and_properties() -> void:
	_build_scene()

	equal(_call("node_get", {"path": "Ghost"})["error"]["code"], "NODE_NOT_FOUND", "node")
	equal(_call("node_get", {"path": "Player", "properties": ["nope"]})["error"]["code"], "INVALID_ARGS", "property")


func test_node_find_filters_by_name_type_and_group() -> void:
	_build_scene()

	var by_name: Array = _call("node_find", {"name": "Enemy*"})["data"]["nodes"]
	var by_type: Array = _call("node_find", {"type": "CanvasItem"})["data"]["nodes"]
	var by_group: Array = _call("node_find", {"group": "level"})["data"]["nodes"]

	equal(by_name.map(func(n: Dictionary) -> String: return n["path"]), ["World/Enemy1", "World/Enemy2"], "name pattern, document order")
	equal(by_type.size(), 5, "inherited classes match")
	equal(by_group, [{"path": "World", "type": "Node"}], "group")


func test_node_find_needs_a_criterion_and_honours_the_limit() -> void:
	_build_scene()

	equal(_call("node_find", {})["error"]["code"], "INVALID_ARGS", "no criteria")
	var limited: Dictionary = _call("node_find", {"type": "Node", "limit": 2})["data"]
	equal(limited["nodes"].size(), 2, "limit")
	equal(limited["truncated"], true, "truncated flag")
