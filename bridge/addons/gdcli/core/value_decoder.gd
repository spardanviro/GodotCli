extends RefCounted
## Tagged JSON to Variant (docs/protocol.md section 6.4), the inverse of
## value_codec.gd. Values are converted towards the type of the property they
## are meant for. `str_to_var` is never used: it can construct arbitrary
## objects, which would be a way to run code without the exec tier.

const NodeRef = preload("node_ref.gd")
const PathPolicy = preload("path_policy.gd")
const Reply = preload("reply.gd")

const MAX_DEPTH := 8
# Largest float that still names exactly one integer (2^53).
const MAX_SAFE_INTEGER := 9007199254740992.0

const _COMPONENTS := {
	TYPE_VECTOR2: ["x", "y"],
	TYPE_VECTOR2I: ["x", "y"],
	TYPE_VECTOR3: ["x", "y", "z"],
	TYPE_VECTOR3I: ["x", "y", "z"],
	TYPE_VECTOR4: ["x", "y", "z", "w"],
	TYPE_VECTOR4I: ["x", "y", "z", "w"],
	TYPE_QUATERNION: ["x", "y", "z", "w"],
}
# Matrices: [number of column vectors, components of each].
const _MATRIX_SHAPES := {
	TYPE_TRANSFORM2D: [3, 2],
	TYPE_BASIS: [3, 3],
	TYPE_TRANSFORM3D: [4, 3],
	TYPE_PROJECTION: [4, 4],
}
const _FLAT_SIZES := {TYPE_PLANE: 4, TYPE_AABB: 6}
const _PACKED_ELEMENTS := {
	TYPE_PACKED_BYTE_ARRAY: TYPE_INT,
	TYPE_PACKED_INT32_ARRAY: TYPE_INT,
	TYPE_PACKED_INT64_ARRAY: TYPE_INT,
	TYPE_PACKED_FLOAT32_ARRAY: TYPE_FLOAT,
	TYPE_PACKED_FLOAT64_ARRAY: TYPE_FLOAT,
	TYPE_PACKED_STRING_ARRAY: TYPE_STRING,
	TYPE_PACKED_VECTOR2_ARRAY: TYPE_VECTOR2,
	TYPE_PACKED_VECTOR3_ARRAY: TYPE_VECTOR3,
	TYPE_PACKED_COLOR_ARRAY: TYPE_COLOR,
	TYPE_PACKED_VECTOR4_ARRAY: TYPE_VECTOR4,
}
const MAX_PACKED_ELEMENTS := 65536
const _BYTE_MAX := 255
const _INT32_MAX := 2147483647
# Types that may also be given as the text of their constructor call, e.g.
# "Vector2(100, 50)". Only the name and plain numbers are read, by the code
# below: nothing here can construct an object.
const _WRITTEN_AS_CALL: Array[int] = [
	TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_QUATERNION,
	TYPE_RECT2, TYPE_RECT2I, TYPE_COLOR, TYPE_TRANSFORM2D, TYPE_BASIS, TYPE_TRANSFORM3D, TYPE_PROJECTION,
	TYPE_AABB, TYPE_PLANE,
]
const _CALL_PATTERN := "^\\s*([A-Za-z0-9]+)\\s*\\(([^()]*)\\)\\s*$"
const _INTEGER_VECTORS: Array[int] = [TYPE_VECTOR2I, TYPE_VECTOR3I, TYPE_VECTOR4I, TYPE_RECT2I]
# Classes that carry code or whole scenes; they come from project files only.
const _NOT_CONSTRUCTIBLE: Array[String] = ["Script", "PackedScene", "GDExtension"]
const _SCRIPT_PROPERTY := "script"
const SAVED_USAGE := PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_STORAGE
const ANY_USAGE := -1
const _STRUCTURAL_USAGE := PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP

var _scene_root: Node
var _call_regex: RegEx


func _init(scene_root: Node = null) -> void:
	_scene_root = scene_root


## Sets `properties` on `object` after converting every value.
## Returns {ok = true, values = {name: converted}} without changing the object,
## or a failed reply. `usage` selects the properties that may be set: by
## default those the inspector shows or a file stores; a running game passes
## ANY_USAGE to reach properties such as velocity and script variables.
func decode_properties(object: Object, properties: Dictionary, depth: int = 0, usage: int = SAVED_USAGE) -> Dictionary:
	var known := {}
	for property in object.get_property_list():
		if property["usage"] & usage and not property["usage"] & _STRUCTURAL_USAGE:
			known[property["name"]] = property
	var values := {}
	for name in properties:
		# Scripts are attached through node_attach_script only.
		if str(name) == _SCRIPT_PROPERTY:
			return _mismatch("The script property cannot be set this way.", str(name), "a call to node_attach_script")
		if not known.has(name):
			return Reply.fail(
				"INVALID_ARGS", "The object has no such property.", "node_get lists the properties of a node.",
				{"property": str(name), "class": object.get_class()},
			)
		var decoded := decode(properties[name], known[name]["type"], known[name], depth)
		if not decoded["ok"]:
			var details: Dictionary = decoded["error"].get("details", {})
			details["property"] = str(name)
			decoded["error"]["details"] = details
			return decoded
		values[name] = decoded["value"]
	return {"ok": true, "values": values}


## Converts one value to `type`. `info` is the property description when there
## is one (for enum names and resource classes).
func decode(value: Variant, type: int, info: Dictionary = {}, depth: int = 0) -> Dictionary:
	if depth > MAX_DEPTH:
		return _mismatch("The value is nested too deeply.", "", "a simpler value")
	if value is Dictionary and value.has("$type"):
		return _decode_tagged(value, type, info, depth)
	if value is String and _WRITTEN_AS_CALL.has(type):
		var numbers: Variant = _numbers_of_call(value, type)
		if numbers != null:
			return decode(numbers, type, info, depth + 1)

	match type:
		TYPE_NIL:
			return _decode_untyped(value, depth)
		TYPE_BOOL:
			return _ok(value) if value is bool else _mismatch_type(type)
		TYPE_INT:
			return _decode_int(value, info)
		TYPE_FLOAT:
			return _ok(float(value)) if value is float or value is int else _mismatch_type(type)
		TYPE_STRING:
			return _ok(value) if value is String else _mismatch_type(type)
		TYPE_STRING_NAME:
			return _ok(StringName(value)) if value is String else _mismatch_type(type)
		TYPE_NODE_PATH:
			return _ok(NodePath(value)) if value is String else _mismatch_type(type)
		TYPE_COLOR:
			return _decode_color(value)
		TYPE_RECT2, TYPE_RECT2I:
			return _decode_rect(value, type)
		TYPE_OBJECT:
			return _decode_object(value, info, depth)
		TYPE_ARRAY:
			return _decode_array(value, depth)
		TYPE_DICTIONARY:
			return _decode_untyped(value, depth) if value is Dictionary else _mismatch_type(type)
	if _COMPONENTS.has(type):
		return _decode_components(value, type)
	if _MATRIX_SHAPES.has(type):
		return _decode_matrix(value, type)
	if _FLAT_SIZES.has(type):
		return _decode_flat(value, type)
	if _PACKED_ELEMENTS.has(type):
		return _decode_packed(value, type, depth)
	return _mismatch("Values of this type cannot be set through the bridge.", "", type_string(type))


# The numbers inside "TypeName(1, 2.5, ...)" when the name is that of `type`;
# null for any other text.
func _numbers_of_call(text: String, type: int) -> Variant:
	if _call_regex == null:
		_call_regex = RegEx.create_from_string(_CALL_PATTERN)
	var found := _call_regex.search(text)
	if found == null or found.get_string(1) != type_string(type):
		return null
	var numbers := []
	for part in found.get_string(2).split(","):
		var written := part.strip_edges()
		if not written.is_valid_float():
			return null
		numbers.append(written.to_float())
	return numbers


func _decode_tagged(value: Dictionary, type: int, info: Dictionary, depth: int) -> Dictionary:
	var named: String = str(value["$type"])
	var tagged_type := -1
	for candidate in TYPE_MAX:
		if type_string(candidate) == named:
			tagged_type = candidate
	if tagged_type == -1 or tagged_type == TYPE_OBJECT or not value.has("value"):
		return _mismatch("Unknown or incomplete $type.", "", "a known type name with a value")
	if type != TYPE_NIL and type != tagged_type:
		return _mismatch_type(type)
	return decode(value["value"], tagged_type, info, depth + 1)


# For Variant-typed targets: tagged forms are honoured, plain JSON stays as it is.
func _decode_untyped(value: Variant, depth: int) -> Dictionary:
	if value is Dictionary:
		if value.has("$res") or value.has("$new") or value.has("$node"):
			return _decode_object(value, {}, depth)
		var result := {}
		for key in value:
			var decoded := decode(value[key], TYPE_NIL, {}, depth + 1)
			if not decoded["ok"]:
				return decoded
			result[key] = decoded["value"]
		return _ok(result)
	if value is Array:
		return _decode_array(value, depth)
	return _ok(value)


func _decode_array(value: Variant, depth: int) -> Dictionary:
	if not value is Array:
		return _mismatch_type(TYPE_ARRAY)
	var result := []
	for item in value:
		var decoded := decode(item, TYPE_NIL, {}, depth + 1)
		if not decoded["ok"]:
			return decoded
		result.append(decoded["value"])
	return _ok(result)


func _decode_int(value: Variant, info: Dictionary) -> Dictionary:
	if value is int:
		return _ok(value)
	# Godot's JSON parser reads every number as a float.
	if value is float and value == floorf(value) and absf(value) <= MAX_SAFE_INTEGER:
		return _ok(int(value))
	if value is String and info.get("hint", PROPERTY_HINT_NONE) == PROPERTY_HINT_ENUM:
		var member := _enum_value(value, info.get("hint_string", ""))
		if member["found"]:
			return _ok(member["value"])
		return _mismatch("Not a member of this enumeration.", "", info.get("hint_string", ""))
	return _mismatch_type(TYPE_INT)


# "Idle,Walk:4,Run" numbers members from 0, with explicit values after a colon.
func _enum_value(name: String, hint_string: String) -> Dictionary:
	var next := 0
	for entry in hint_string.split(","):
		var label := entry.get_slice(":", 0).strip_edges()
		if entry.contains(":"):
			next = entry.get_slice(":", 1).to_int()
		if label.to_lower() == name.to_lower():
			return {"found": true, "value": next}
		next += 1
	return {"found": false}


func _decode_color(value: Variant) -> Dictionary:
	if value is String:
		if Color.html_is_valid(value):
			return _ok(Color.html(value))
		# from_string returns the fallback for unknown names; two different
		# fallbacks tell a real name from an unknown one.
		var first := Color.from_string(value, Color(0, 0, 0, 0))
		if first == Color.from_string(value, Color(1, 1, 1, 1)):
			return _ok(first)
		return _mismatch("Not a colour.", "", "\"#rrggbb\", \"#rrggbbaa\", a colour name, or [r, g, b, a]")
	if value is Array and (value.size() == 3 or value.size() == 4) and _all_numbers(value):
		return _ok(Color(value[0], value[1], value[2], value[3] if value.size() == 4 else 1.0))
	return _mismatch_type(TYPE_COLOR)


func _decode_components(value: Variant, type: int) -> Dictionary:
	var names: Array = _COMPONENTS[type]
	var numbers := []
	if value is Array and value.size() == names.size():
		numbers = value
	elif value is Dictionary and value.size() == names.size() and value.has_all(names):
		for name in names:
			numbers.append(value[name])
	if numbers.size() != names.size() or not _all_numbers(numbers):
		return _mismatch("Expected %d numbers." % names.size(), "", "%s as [%s]" % [type_string(type), ", ".join(names)])
	if type in _INTEGER_VECTORS and not _all_integral(numbers):
		return _mismatch("Expected whole numbers.", "", type_string(type))
	match type:
		TYPE_VECTOR2: return _ok(Vector2(numbers[0], numbers[1]))
		TYPE_VECTOR2I: return _ok(Vector2i(numbers[0], numbers[1]))
		TYPE_VECTOR3: return _ok(Vector3(numbers[0], numbers[1], numbers[2]))
		TYPE_VECTOR3I: return _ok(Vector3i(numbers[0], numbers[1], numbers[2]))
		TYPE_VECTOR4: return _ok(Vector4(numbers[0], numbers[1], numbers[2], numbers[3]))
		TYPE_VECTOR4I: return _ok(Vector4i(numbers[0], numbers[1], numbers[2], numbers[3]))
	return _ok(Quaternion(numbers[0], numbers[1], numbers[2], numbers[3]))


# Column vectors, either nested ([[xx, xy], [yx, yy], [ox, oy]]) or as one
# flat list in the same order.
func _decode_matrix(value: Variant, type: int) -> Dictionary:
	var columns: int = _MATRIX_SHAPES[type][0]
	var rows: int = _MATRIX_SHAPES[type][1]
	var failure := _mismatch(
		"Expected the column vectors of the matrix.", "", "%s as %d columns of %d numbers" % [type_string(type), columns, rows]
	)
	if not value is Array:
		return failure
	var n := []
	if value.size() == columns * rows:
		n = value
	elif value.size() == columns:
		for column in value:
			if not (column is Array and column.size() == rows):
				return failure
			n.append_array(column)
	if n.size() != columns * rows or not _all_numbers(n):
		return failure
	match type:
		TYPE_TRANSFORM2D:
			return _ok(Transform2D(Vector2(n[0], n[1]), Vector2(n[2], n[3]), Vector2(n[4], n[5])))
		TYPE_BASIS:
			return _ok(Basis(Vector3(n[0], n[1], n[2]), Vector3(n[3], n[4], n[5]), Vector3(n[6], n[7], n[8])))
		TYPE_TRANSFORM3D:
			return _ok(Transform3D(
				Basis(Vector3(n[0], n[1], n[2]), Vector3(n[3], n[4], n[5]), Vector3(n[6], n[7], n[8])),
				Vector3(n[9], n[10], n[11]),
			))
	return _ok(Projection(
		Vector4(n[0], n[1], n[2], n[3]), Vector4(n[4], n[5], n[6], n[7]),
		Vector4(n[8], n[9], n[10], n[11]), Vector4(n[12], n[13], n[14], n[15]),
	))


func _decode_flat(value: Variant, type: int) -> Dictionary:
	var size: int = _FLAT_SIZES[type]
	if not (value is Array and value.size() == size and _all_numbers(value)):
		var form := "[x, y, z, width, height, depth]" if type == TYPE_AABB else "[normal x, normal y, normal z, d]"
		return _mismatch("Expected %d numbers." % size, "", "%s as %s" % [type_string(type), form])
	if type == TYPE_AABB:
		return _ok(AABB(Vector3(value[0], value[1], value[2]), Vector3(value[3], value[4], value[5])))
	return _ok(Plane(value[0], value[1], value[2], value[3]))


func _decode_packed(value: Variant, type: int, depth: int) -> Dictionary:
	if not value is Array:
		return _mismatch_type(type)
	if value.size() > MAX_PACKED_ELEMENTS:
		return _mismatch("The array is too long to send in one command.", "", "at most %d elements" % MAX_PACKED_ELEMENTS)
	var elements := []
	for item in value:
		var decoded := decode(item, _PACKED_ELEMENTS[type], {}, depth + 1)
		if not decoded["ok"]:
			return decoded
		if not _fits_packed(decoded["value"], type):
			return _mismatch("A number does not fit the element type.", "", type_string(type))
		elements.append(decoded["value"])
	return _ok(type_convert(elements, type))


func _fits_packed(element: Variant, type: int) -> bool:
	if type == TYPE_PACKED_BYTE_ARRAY:
		return element >= 0 and element <= _BYTE_MAX
	if type == TYPE_PACKED_INT32_ARRAY:
		return element >= -_INT32_MAX - 1 and element <= _INT32_MAX
	return true


func _decode_rect(value: Variant, type: int) -> Dictionary:
	if not (value is Array and value.size() == 4 and _all_numbers(value)):
		return _mismatch("Expected [x, y, width, height].", "", type_string(type))
	if type == TYPE_RECT2I:
		if not _all_integral(value):
			return _mismatch("Expected whole numbers.", "", type_string(type))
		return _ok(Rect2i(value[0], value[1], value[2], value[3]))
	return _ok(Rect2(value[0], value[1], value[2], value[3]))


func _decode_object(value: Variant, info: Dictionary, depth: int) -> Dictionary:
	if value == null:
		return _ok(null)
	if not value is Dictionary:
		return _mismatch("Expected null, {\"$res\": path}, {\"$new\": class} or {\"$node\": path}.", "", "an object reference")
	if value.has("$node"):
		var node := NodeRef.resolve(_scene_root, str(value["$node"]))
		if node == null:
			return Reply.fail("NODE_NOT_FOUND", "The referenced node does not exist.", "", {"path": str(value["$node"])})
		return _ok(node)
	var decoded := _load_resource(str(value["$res"])) if value.has("$res") else _new_resource(value, depth)
	if not decoded["ok"]:
		return decoded
	var wanted: String = info.get("hint_string", "") if info.get("hint", PROPERTY_HINT_NONE) == PROPERTY_HINT_RESOURCE_TYPE else ""
	if wanted != "" and not _is_one_of(decoded["value"], wanted):
		return _mismatch("The resource is not of the class this property takes.", "", wanted)
	return decoded


func _load_resource(path: String) -> Dictionary:
	var checked := PathPolicy.check(path, PathPolicy.ACCESS_READ)
	if not checked["ok"]:
		return checked
	if not ResourceLoader.exists(checked["path"]):
		return Reply.fail("RESOURCE_NOT_FOUND", "The resource does not exist.", "", {"path": checked["path"]})
	var resource := ResourceLoader.load(checked["path"])
	if resource == null:
		return Reply.fail("COMMAND_FAILED", "The resource could not be loaded.", "", {"path": checked["path"]})
	return _ok(resource)


func _new_resource(value: Dictionary, depth: int) -> Dictionary:
	if not value.has("$new"):
		return _mismatch("Expected $res, $new or $node.", "", "an object reference")
	var class_to_make := str(value["$new"])
	# Native classes only: a script class would run project code on construction.
	var allowed := ClassDB.class_exists(class_to_make) and ClassDB.is_parent_class(class_to_make, "Resource") and ClassDB.can_instantiate(class_to_make)
	for forbidden in _NOT_CONSTRUCTIBLE:
		if allowed and (class_to_make == forbidden or ClassDB.is_parent_class(class_to_make, forbidden)):
			allowed = false
	if not allowed:
		return _mismatch("$new takes a built-in Resource class that is not a script or a scene.", "", "e.g. RectangleShape2D")
	var resource: Resource = ClassDB.instantiate(class_to_make)
	var properties: Variant = value.get("properties", {})
	if not properties is Dictionary:
		return _mismatch("properties must be an object.", "", "an object")
	var decoded := decode_properties(resource, properties, depth + 1)
	if not decoded["ok"]:
		return decoded
	for name in decoded["values"]:
		resource.set(name, decoded["values"][name])
	return _ok(resource)


func _is_one_of(object: Object, class_list: String) -> bool:
	for name in class_list.split(","):
		if object.is_class(name.strip_edges()):
			return true
	return false


func _all_numbers(values: Array) -> bool:
	for value in values:
		if not (value is float or value is int):
			return false
	return true


func _all_integral(values: Array) -> bool:
	for value in values:
		if value is float and value != floorf(value):
			return false
	return true


func _ok(value: Variant) -> Dictionary:
	return {"ok": true, "value": value}


func _mismatch_type(type: int) -> Dictionary:
	return _mismatch("The value cannot be converted to the property's type.", "", type_string(type))


func _mismatch(message: String, property: String, expected: String) -> Dictionary:
	var details := {"expected": expected}
	if property != "":
		details["property"] = property
	return Reply.fail("TYPE_MISMATCH", message, "docs/protocol.md section 6.4 lists the accepted forms.", details)
