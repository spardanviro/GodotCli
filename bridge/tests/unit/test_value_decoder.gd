extends "res://tests/suite.gd"

const ValueCodec = preload("res://addons/gdcli/core/value_codec.gd")
const ValueDecoder = preload("res://addons/gdcli/core/value_decoder.gd")

var _nodes: Array[Node] = []


func cleanup() -> void:
	for node in _nodes:
		node.free()
	_nodes.clear()


func _value(raw: Variant, type: int, info: Dictionary = {}) -> Variant:
	var decoded := ValueDecoder.new().decode(raw, type, info)
	return decoded["value"] if decoded["ok"] else "FAILED:" + decoded["error"]["code"]


func _fails(raw: Variant, type: int, info: Dictionary = {}) -> bool:
	return not ValueDecoder.new().decode(raw, type, info)["ok"]


func test_value_decoder_json_numbers_become_the_property_type() -> void:
	equal(_value(3.0, TYPE_INT), 3, "integral float to int")
	equal(_value(3, TYPE_FLOAT), 3.0, "int to float")
	equal(_value(true, TYPE_BOOL), true, "bool")
	equal(_value("text", TYPE_STRING), "text", "string")
	equal(_value("jump", TYPE_STRING_NAME), &"jump", "string name")
	equal(_value("../Target", TYPE_NODE_PATH), NodePath("../Target"), "node path")


func test_value_decoder_wrong_json_types_are_rejected() -> void:
	check(_fails(1.5, TYPE_INT), "fraction as int")
	check(_fails(1e30, TYPE_INT), "float beyond exact integers")
	check(_fails("3", TYPE_INT), "string as int")
	check(_fails(1, TYPE_BOOL), "number as bool")
	check(_fails(1, TYPE_STRING), "number as string")
	check(_fails("x", TYPE_FLOAT), "string as float")


func test_value_decoder_vectors_accept_arrays_objects_and_tags() -> void:
	equal(_value([10, 20], TYPE_VECTOR2), Vector2(10, 20), "array")
	equal(_value({"x": 1, "y": 2}, TYPE_VECTOR2), Vector2(1, 2), "object")
	equal(_value({"$type": "Vector2", "value": [3, 4]}, TYPE_VECTOR2), Vector2(3, 4), "tagged")
	equal(_value([1, 2, 3], TYPE_VECTOR3I), Vector3i(1, 2, 3), "integer vector")
	equal(_value([0, 0, 0, 1], TYPE_QUATERNION), Quaternion(0, 0, 0, 1), "quaternion")
	equal(_value([1, 2, 3, 4], TYPE_RECT2), Rect2(1, 2, 3, 4), "rect")


func test_value_decoder_malformed_vectors_are_rejected() -> void:
	check(_fails([1], TYPE_VECTOR2), "too few numbers")
	check(_fails([1, 2, 3], TYPE_VECTOR2), "too many numbers")
	check(_fails([1, "2"], TYPE_VECTOR2), "not a number")
	check(_fails({"x": 1}, TYPE_VECTOR2), "missing component")
	check(_fails([1.5, 2], TYPE_VECTOR2I), "fraction in an integer vector")
	check(_fails({"$type": "Vector3", "value": [1, 2, 3]}, TYPE_VECTOR2), "tag of another type")
	check(_fails({"$type": "Nonsense", "value": 1}, TYPE_NIL), "unknown tag")


func test_value_decoder_colors_accept_html_names_and_arrays() -> void:
	equal(_value("#ff8000", TYPE_COLOR), Color.html("#ff8000"), "html")
	equal(_value("red", TYPE_COLOR), Color.RED, "name")
	equal(_value([1, 0.5, 0], TYPE_COLOR), Color(1, 0.5, 0, 1), "rgb array")
	equal(_value([1, 0.5, 0, 0.25], TYPE_COLOR), Color(1, 0.5, 0, 0.25), "rgba array")
	check(_fails("not-a-colour", TYPE_COLOR), "unknown name")
	check(_fails([1, 2], TYPE_COLOR), "short array")


func test_value_decoder_enums_accept_member_names() -> void:
	var info := {"hint": PROPERTY_HINT_ENUM, "hint_string": "Idle,Walk:4,Run"}

	equal(_value("Idle", TYPE_INT, info), 0, "first member")
	equal(_value("walk", TYPE_INT, info), 4, "explicit value, any case")
	equal(_value("Run", TYPE_INT, info), 5, "counts on from the explicit value")
	equal(_value(4, TYPE_INT, info), 4, "numbers still work")
	check(_fails("Fly", TYPE_INT, info), "unknown member")
	check(_fails("Idle", TYPE_INT), "a name without an enumeration")


func test_value_decoder_new_builds_only_code_free_builtin_resources() -> void:
	var shape: Variant = _value({"$new": "RectangleShape2D", "properties": {"size": [32, 16]}}, TYPE_OBJECT)

	check(shape is RectangleShape2D, "built-in resource is created")
	equal(shape.size, Vector2(32, 16), "with its properties converted")
	for forbidden in ["GDScript", "Script", "PackedScene", "Node", "Object", "NoSuchClass", "EditorPlugin"]:
		check(_fails({"$new": forbidden}, TYPE_OBJECT), "$new %s" % forbidden)


func test_value_decoder_script_property_cannot_be_set() -> void:
	var decoder := ValueDecoder.new()
	var node := Node2D.new()
	_nodes.append(node)

	var direct := decoder.decode_properties(node, {"script": null})
	var nested := decoder.decode({"$new": "RectangleShape2D", "properties": {"script": {"$res": "res://x.gd"}}}, TYPE_OBJECT)

	equal(direct["ok"], false, "on a node")
	equal(direct["error"]["code"], "TYPE_MISMATCH", "code")
	equal(nested["ok"], false, "inside $new")


func test_value_decoder_res_goes_through_the_path_policy() -> void:
	for path in ["res://../outside.tres", "user://x.tres", "res://.godot/x.res", "C:/x.tres"]:
		var decoded := ValueDecoder.new().decode({"$res": path}, TYPE_OBJECT)
		equal(decoded["ok"], false, path)
		equal(decoded["error"]["code"], "PATH_NOT_ALLOWED", path)
	equal(ValueDecoder.new().decode({"$res": "res://nowhere.tres"}, TYPE_OBJECT)["error"]["code"], "RESOURCE_NOT_FOUND", "missing file")


func test_value_decoder_res_loads_and_checks_the_resource_class() -> void:
	var texture_only := {"hint": PROPERTY_HINT_RESOURCE_TYPE, "hint_string": "Texture2D"}
	var scene_ok := {"hint": PROPERTY_HINT_RESOURCE_TYPE, "hint_string": "PackedScene"}
	var reference := {"$res": "res://tests/fixtures/main.tscn"}

	check(_value(reference, TYPE_OBJECT, scene_ok) is PackedScene, "matching class loads")
	check(_fails(reference, TYPE_OBJECT, texture_only), "wrong class is refused")
	equal(_value(null, TYPE_OBJECT, texture_only), null, "null clears the property")


func test_value_decoder_node_references_resolve_inside_the_scene() -> void:
	var root := Node.new()
	var child := Node.new()
	child.name = "Child"
	root.add_child(child)
	_nodes.append(root)
	var decoder := ValueDecoder.new(root)

	equal(decoder.decode({"$node": "Child"}, TYPE_OBJECT)["value"], child, "existing node")
	equal(decoder.decode({"$node": "Ghost"}, TYPE_OBJECT)["error"]["code"], "NODE_NOT_FOUND", "missing node")
	equal(decoder.decode({"$node": ".."}, TYPE_OBJECT)["error"]["code"], "NODE_NOT_FOUND", "outside the scene")


func test_value_decoder_untyped_targets_keep_json_and_honour_tags() -> void:
	equal(_value({"a": [1, {"$type": "Vector2", "value": [1, 2]}]}, TYPE_NIL), {"a": [1.0 if false else 1, Vector2(1, 2)]}, "nested tag")
	equal(_value("plain", TYPE_NIL), "plain", "string")
	equal(_value([{"$type": "Color", "value": "#ff0000"}], TYPE_ARRAY), [Color.RED], "array elements")


func test_value_decoder_properties_report_the_offending_name() -> void:
	var node := Node2D.new()
	_nodes.append(node)
	var decoder := ValueDecoder.new()

	var good := decoder.decode_properties(node, {"position": [1, 2], "visible": false})
	var unknown := decoder.decode_properties(node, {"positoin": [1, 2]})
	var wrong := decoder.decode_properties(node, {"position": "far away"})

	equal(good["values"], {"position": Vector2(1, 2), "visible": false}, "converted values")
	equal(node.position, Vector2.ZERO, "the object itself is not touched")
	equal(unknown["error"]["code"], "INVALID_ARGS", "unknown property")
	equal(wrong["error"]["code"], "TYPE_MISMATCH", "wrong value")
	equal(wrong["error"]["details"]["property"], "position", "names the property")


func test_value_decoder_unsupported_and_too_deep_values_fail_cleanly() -> void:
	var deep: Variant = 1
	for level in ValueDecoder.MAX_DEPTH + 4:
		deep = [deep]

	check(_fails(1, TYPE_RID), "a type without a JSON form")
	check(_fails(deep, TYPE_ARRAY), "nesting beyond the limit")


func test_value_decoder_matrices_accept_nested_and_flat_columns() -> void:
	var moved := Transform2D(Vector2(0, 1), Vector2(-1, 0), Vector2(30, 40))
	var basis := Basis(Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3(-1, 0, 0))

	equal(_value([[0, 1], [-1, 0], [30, 40]], TYPE_TRANSFORM2D), moved, "Transform2D as columns")
	equal(_value([0, 1, -1, 0, 30, 40], TYPE_TRANSFORM2D), moved, "Transform2D flat")
	equal(_value([[0, 0, 1], [0, 1, 0], [-1, 0, 0]], TYPE_BASIS), basis, "Basis")
	equal(
		_value([[0, 0, 1], [0, 1, 0], [-1, 0, 0], [1, 2, 3]], TYPE_TRANSFORM3D), Transform3D(basis, Vector3(1, 2, 3)), "Transform3D"
	)
	equal(_value([1, 2, 3, 4, 5, 6], TYPE_AABB), AABB(Vector3(1, 2, 3), Vector3(4, 5, 6)), "AABB")
	equal(_value([0, 1, 0, 5], TYPE_PLANE), Plane(0, 1, 0, 5), "Plane")
	check(_fails([[0, 1], [-1, 0]], TYPE_TRANSFORM2D), "a missing column")
	check(_fails([[0, 1], [-1, 0], [30, "x"]], TYPE_TRANSFORM2D), "a column that is not numbers")
	check(_fails("Transform2D(Vector2(1, 0), Vector2(0, 1), Vector2(0, 0))", TYPE_TRANSFORM2D), "nested constructor text is not parsed")


func test_value_decoder_matrices_round_trip_through_the_codec() -> void:
	var originals := [
		Transform2D(0.5, Vector2(3, 4)),
		Basis(Vector3(0, 1, 0), 0.25),
		Transform3D(Basis(Vector3(1, 0, 0), 1.0), Vector3(7, 8, 9)),
		AABB(Vector3(1, 2, 3), Vector3(4, 5, 6)),
		Plane(Vector3(0, 1, 0), 2.0),
	]

	for original in originals:
		var wire: Variant = JSON.parse_string(JSON.stringify(ValueCodec.encode(original)))
		check(_value(wire, typeof(original)).is_equal_approx(original), type_string(typeof(original)))
	var projection := Projection(Vector4(1, 2, 3, 4), Vector4(5, 6, 7, 8), Vector4(9, 10, 11, 12), Vector4(13, 14, 15, 16))
	var projection_wire: Variant = JSON.parse_string(JSON.stringify(ValueCodec.encode(projection)))
	equal(_value(projection_wire, TYPE_PROJECTION), projection, "Projection")


func test_value_decoder_packed_arrays_convert_every_element() -> void:
	equal(_value([[0, 0], [16, 0], [16, 8]], TYPE_PACKED_VECTOR2_ARRAY), PackedVector2Array([Vector2(0, 0), Vector2(16, 0), Vector2(16, 8)]), "points")
	equal(_value([1.0, 2.0], TYPE_PACKED_INT32_ARRAY), PackedInt32Array([1, 2]), "ints")
	equal(_value(["a", "b"], TYPE_PACKED_STRING_ARRAY), PackedStringArray(["a", "b"]), "strings")
	equal(_value(["#ff0000", "blue"], TYPE_PACKED_COLOR_ARRAY), PackedColorArray([Color.RED, Color.BLUE]), "colours")
	equal(_value([0, 255], TYPE_PACKED_BYTE_ARRAY), PackedByteArray([0, 255]), "bytes")
	check(_fails([256], TYPE_PACKED_BYTE_ARRAY), "a byte out of range")
	check(_fails([[0, 0], [1]], TYPE_PACKED_VECTOR2_ARRAY), "a malformed element")
	check(_fails("points", TYPE_PACKED_VECTOR2_ARRAY), "not an array")

	var wire: Variant = JSON.parse_string(JSON.stringify(ValueCodec.encode(PackedVector3Array([Vector3(1, 2, 3)]))))
	equal(_value(wire, TYPE_PACKED_VECTOR3_ARRAY), PackedVector3Array([Vector3(1, 2, 3)]), "the codec's own output is accepted")


func test_value_decoder_accepts_values_written_as_in_a_script() -> void:
	equal(_value("Vector2(100, 50)", TYPE_VECTOR2), Vector2(100, 50), "Vector2")
	equal(_value(" Vector3i( 1,2 , 3 ) ", TYPE_VECTOR3I), Vector3i(1, 2, 3), "spacing")
	equal(_value("Color(1, 0, 0)", TYPE_COLOR), Color.RED, "Color by components")
	equal(_value("Rect2(0, 0, 16, 8)", TYPE_RECT2), Rect2(0, 0, 16, 8), "Rect2")
	equal(_value("Transform2D(1, 0, 0, 1, 30, 40)", TYPE_TRANSFORM2D), Transform2D(Vector2(1, 0), Vector2(0, 1), Vector2(30, 40)), "matrix as flat numbers")
	check(_fails("Vector3(1, 2, 3)", TYPE_VECTOR2), "the name of another type")
	check(_fails("Vector2(1, x)", TYPE_VECTOR2), "something that is not a number")
	check(_fails("Vector2(Vector2(1, 2))", TYPE_VECTOR2), "nested calls are not read")
	check(_fails("Vector2(1,,2)", TYPE_VECTOR2), "an empty place")
	check(_fails("Vector2(1, 2, 3)", TYPE_VECTOR2), "too many numbers")
	equal(_value("Vector2(1, 2)", TYPE_STRING), "Vector2(1, 2)", "a string property keeps the text")


func test_value_decoder_enums_accept_the_constant_names_of_the_class() -> void:
	var control := Control.new()
	var body := CharacterBody2D.new()
	_nodes.append_array([control, body])
	var decoder := ValueDecoder.new()

	var by_constant := decoder.decode_properties(control, {"mouse_filter": "MOUSE_FILTER_IGNORE", "process_mode": "PROCESS_MODE_ALWAYS"})
	var qualified := decoder.decode_properties(body, {"motion_mode": "CharacterBody2D.MOTION_MODE_FLOATING"})
	var by_label := decoder.decode_properties(control, {"mouse_filter": "Ignore"})
	var of_another_enum := decoder.decode_properties(control, {"mouse_filter": "PRESET_FULL_RECT"})
	var same_value_elsewhere := decoder.decode_properties(control, {"mouse_filter": "SIZE_FILL"})
	var unknown := decoder.decode_properties(control, {"mouse_filter": "MOUSE_FILTER_NEVER"})
	var nested := decoder.decode({"$new": "Environment", "properties": {"background_mode": "BG_SKY"}}, TYPE_OBJECT)

	equal(by_constant["values"], {"mouse_filter": Control.MOUSE_FILTER_IGNORE, "process_mode": Node.PROCESS_MODE_ALWAYS}, "constants of the class and of its ancestors")
	equal(qualified["values"], {"motion_mode": CharacterBody2D.MOTION_MODE_FLOATING}, "with the class name in front")
	equal(by_label["values"], {"mouse_filter": Control.MOUSE_FILTER_IGNORE}, "the inspector's label still works")
	equal(of_another_enum["ok"], false, "a constant whose value this enumeration does not have")
	equal(same_value_elsewhere["ok"], false, "a constant of another enumeration that happens to have a fitting value")
	equal(unknown["ok"], false, "a name that is no constant")
	equal(nested["value"].background_mode, Environment.BG_SKY, "inside a new resource")


func test_value_decoder_derived_properties_of_a_node_can_be_set() -> void:
	var spatial := Node3D.new()
	var flat := Node2D.new()
	_nodes.append_array([spatial, flat])
	var decoder := ValueDecoder.new()

	var degrees := decoder.decode_properties(spatial, {"rotation_degrees": [-45, 30, 0]})
	var flat_degrees := decoder.decode_properties(flat, {"rotation_degrees": 90, "global_position": [5, 6]})
	var bookkeeping := decoder.decode_properties(spatial, {"owner": {"$node": "."}})

	equal(degrees["values"], {"rotation_degrees": Vector3(-45, 30, 0)}, "rotation in degrees, which is not stored but sets rotation")
	equal(flat_degrees["values"], {"rotation_degrees": 90.0, "global_position": Vector2(5, 6)}, "on a 2D node")
	equal(bookkeeping["ok"], false, "other properties that are not stored stay out of reach")


func test_value_decoder_set_in_order_reaches_properties_that_appear_on_the_way() -> void:
	var decoder := ValueDecoder.new()
	var instance := MeshInstance3D.new()
	var untouched := MeshInstance3D.new()
	_nodes.append_array([instance, untouched])

	var at_once := decoder.decode_properties(untouched, {"mesh": {"$new": "BoxMesh"}, "surface_material_override/0": {"$new": "StandardMaterial3D"}})
	var in_order := decoder.set_in_order(instance, {"mesh": {"$new": "BoxMesh"}, "surface_material_override/0": {"$new": "StandardMaterial3D"}})
	var randomizer: Variant = _value({"$new": "AudioStreamRandomizer", "properties": {"streams_count": 2, "stream_1/weight": 3.0}}, TYPE_OBJECT)
	var failed := decoder.set_in_order(instance, {"visible": false, "no_such": 1})

	equal(at_once["ok"], false, "checked against the object as it is, the second property does not exist yet")
	equal(in_order["ok"], true, "set one after the other, it does")
	check(instance.get_surface_override_material(0) is StandardMaterial3D, "and the object has the values")
	equal(in_order["values"].keys(), ["mesh", "surface_material_override/0"], "the converted values, in the order given")
	check(randomizer is AudioStreamRandomizer and randomizer.get_stream_probability_weight(1) == 3.0, "a new resource is filled the same way")
	equal(failed["error"]["details"]["property"], "no_such", "a failure names the property")


func test_value_decoder_set_in_order_leaves_world_positions_of_a_detached_node_for_later() -> void:
	var spatial := Node3D.new()
	_nodes.append(spatial)

	var decoded := ValueDecoder.new().set_in_order(spatial, {"global_position": [1, 2, 3], "position": [4, 5, 6]})

	equal(decoded["values"], {"global_position": Vector3(1, 2, 3), "position": Vector3(4, 5, 6)}, "both are converted and handed back")
	equal(spatial.position, Vector3(4, 5, 6), "only the local one is set on a node that is not in the tree")


func test_value_decoder_nested_failures_name_the_whole_path() -> void:
	var instance := MeshInstance3D.new()
	_nodes.append(instance)

	var wrong := ValueDecoder.new().decode_properties(instance, {"mesh": {"$new": "BoxMesh", "properties": {"size": "big"}}})

	equal(wrong["error"]["details"]["property"], "mesh.size", "outer and inner property")
