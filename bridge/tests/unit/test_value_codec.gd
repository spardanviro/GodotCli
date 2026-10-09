extends "res://tests/suite.gd"

const TextSanitizer = preload("res://addons/gdcli/core/text_sanitizer.gd")
const ValueCodec = preload("res://addons/gdcli/core/value_codec.gd")

var _nodes: Array[Node] = []


func cleanup() -> void:
	for node in _nodes:
		node.free()
	_nodes.clear()


func test_value_codec_json_native_values_pass_through() -> void:
	equal(ValueCodec.encode(null), null, "null")
	equal(ValueCodec.encode(true), true, "bool")
	equal(ValueCodec.encode(42), 42, "int")
	equal(ValueCodec.encode(1.5), 1.5, "float")
	equal(ValueCodec.encode("text"), "text", "string")
	equal(ValueCodec.encode(&"name"), "name", "string name")
	equal(ValueCodec.encode([1, "a"]), [1, "a"], "array")
	equal(ValueCodec.encode({"k": 1, 2: "v"}), {"k": 1, "2": "v"}, "dictionary keys become strings")


func test_value_codec_math_types_are_tagged() -> void:
	equal(ValueCodec.encode(Vector2(10, 20)), {"$type": "Vector2", "value": [10.0, 20.0]}, "Vector2")
	equal(ValueCodec.encode(Vector3i(1, 2, 3)), {"$type": "Vector3i", "value": [1, 2, 3]}, "Vector3i")
	equal(ValueCodec.encode(Rect2(1, 2, 3, 4)), {"$type": "Rect2", "value": [1.0, 2.0, 3.0, 4.0]}, "Rect2")
	equal(ValueCodec.encode(Color(1, 0.5, 0, 1)), {"$type": "Color", "value": "#ff8000ff"}, "Color")
	equal(ValueCodec.encode(NodePath("../Target")), {"$type": "NodePath", "value": "../Target"}, "NodePath")
	equal(ValueCodec.encode(Transform2D.IDENTITY)["$type"], "Transform2D", "other math types keep their name")


func test_value_codec_unsafe_numbers_become_strings() -> void:
	equal(ValueCodec.encode(9007199254740993), {"$type": "int", "value": "9007199254740993"}, "beyond 2^53")
	equal(ValueCodec.encode(INF), {"$type": "float", "value": "inf"}, "infinity")


func test_value_codec_node_references_are_relative_to_the_scene_root() -> void:
	var root := Node.new()
	root.name = "Main"
	var child := Node.new()
	child.name = "Child"
	root.add_child(child)
	var outsider := Node2D.new()
	_nodes = [root, outsider]

	equal(ValueCodec.encode(child, root), {"$node": "Child"}, "inside the scene")
	equal(ValueCodec.encode(outsider, root), {"$type": "Node", "class": "Node2D"}, "outside the scene")


func test_value_codec_resources_are_referenced_not_expanded() -> void:
	var saved := Gradient.new()
	saved.take_over_path("res://tests/fixtures/virtual_gradient.tres")

	equal(ValueCodec.encode(saved), {"$res": "res://tests/fixtures/virtual_gradient.tres", "class": "Gradient"}, "saved")
	equal(ValueCodec.encode(Gradient.new()), {"$type": "Resource", "class": "Gradient", "embedded": true}, "embedded")


func test_value_codec_long_and_deep_values_are_truncated() -> void:
	var long := range(ValueCodec.MAX_ELEMENTS + 5)
	var nested: Variant = 1
	for level in ValueCodec.MAX_DEPTH + 3:
		nested = [nested]

	var encoded_long: Dictionary = ValueCodec.encode(long)
	equal(encoded_long["truncated"], true, "long array flag")
	equal(encoded_long["value"].size(), ValueCodec.MAX_ELEMENTS, "long array length")
	check(JSON.stringify(ValueCodec.encode(nested)).contains("truncated"), "deep nesting stops")


func test_text_sanitizer_strips_control_and_direction_characters() -> void:
	# Built with char() so this file itself contains no invisible characters.
	var escape := char(0x1b)
	var override := char(0x202e)
	var zero_width := char(0x200b)
	var bom := char(0xfeff)
	var c1 := char(0x9b)
	var hostile := "safe" + escape + "[31m" + override + "evil" + zero_width + bom + c1 + " end"

	equal(TextSanitizer.clean(hostile), "safe[31mevil end", "escape, override, zero-width, BOM and C1 removed")
	var spaced := "tab" + char(9) + "and" + char(10) + "newline"
	equal(TextSanitizer.clean(spaced), spaced, "tab and newline are kept")
	equal(ValueCodec.encode("a" + override + "b"), "ab", "strings are cleaned on the way out")


func test_text_sanitizer_single_lines_are_flattened_and_capped() -> void:
	var long_line := "x".repeat(TextSanitizer.MAX_LINE_LENGTH + 10)

	equal(TextSanitizer.clean_line("one\ntwo"), "one two", "newline")
	check(TextSanitizer.clean_line(long_line).ends_with(TextSanitizer.TRUNCATION_MARK), "truncation mark")
