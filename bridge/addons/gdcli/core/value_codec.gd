extends RefCounted
## Variant to tagged JSON (docs/protocol.md section 6.4). Output only: decoding
## arrives with the modifying commands.

const TextSanitizer = preload("text_sanitizer.gd")

const MAX_DEPTH := 16
const MAX_ELEMENTS := 256
## Values encoded for one command; a hostile scene cannot make a reply unbounded.
const DEFAULT_BUDGET := 20000
# Largest integer a JSON number carries exactly (2^53).
const MAX_SAFE_INTEGER := 9007199254740992

const _COMPONENT_TYPES := {
	TYPE_VECTOR2: ["x", "y"],
	TYPE_VECTOR2I: ["x", "y"],
	TYPE_VECTOR3: ["x", "y", "z"],
	TYPE_VECTOR3I: ["x", "y", "z"],
	TYPE_VECTOR4: ["x", "y", "z", "w"],
	TYPE_VECTOR4I: ["x", "y", "z", "w"],
	TYPE_QUATERNION: ["x", "y", "z", "w"],
}


static func new_budget(size: int = DEFAULT_BUDGET) -> Dictionary:
	return {"left": size}


## `scene_root` lets node references be written relative to the edited scene.
## Pass one `budget` to every call that contributes to the same reply.
static func encode(value: Variant, scene_root: Node = null, budget: Dictionary = new_budget(), depth: int = 0) -> Variant:
	budget["left"] -= 1
	var type := typeof(value)
	if depth > MAX_DEPTH or budget["left"] < 0:
		return {"$type": type_string(type), "truncated": true}

	match type:
		TYPE_NIL, TYPE_BOOL:
			return value
		TYPE_INT:
			if value > MAX_SAFE_INTEGER or value < -MAX_SAFE_INTEGER:
				return {"$type": "int", "value": str(value)}
			return value
		TYPE_FLOAT:
			# JSON has no spelling for these.
			if is_nan(value) or is_inf(value):
				return {"$type": "float", "value": str(value)}
			return value
		TYPE_STRING, TYPE_STRING_NAME:
			return TextSanitizer.clean(str(value))
		TYPE_NODE_PATH:
			return _tagged(type, TextSanitizer.clean_line(str(value)))
		TYPE_COLOR:
			return _tagged(type, "#" + (value as Color).to_html(true))
		TYPE_RECT2, TYPE_RECT2I:
			return _tagged(type, _numbers([value.position.x, value.position.y, value.size.x, value.size.y]))
		TYPE_OBJECT:
			return _encode_object(value, scene_root)
		TYPE_ARRAY:
			return _encode_sequence(value, scene_root, budget, depth)
		TYPE_DICTIONARY:
			return _encode_dictionary(value, scene_root, budget, depth)
		TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return {"$type": type_string(type)}

	if _COMPONENT_TYPES.has(type):
		var components := []
		for component in _COMPONENT_TYPES[type]:
			components.append(value[component])
		return _tagged(type, _numbers(components))
	if type >= TYPE_PACKED_BYTE_ARRAY:
		return _encode_packed(value, type, budget, depth)
	# Remaining math types (Transform2D, Basis, AABB, ...) in Godot's own text form.
	return _tagged(type, var_to_str(value))


static func _tagged(type: int, value: Variant) -> Dictionary:
	return {"$type": type_string(type), "value": value}


# Components can be NaN or infinite too; those become strings.
static func _numbers(values: Array) -> Array:
	var encoded := []
	for value in values:
		var is_unsafe: bool = value is float and (is_nan(value) or is_inf(value))
		encoded.append(str(value) if is_unsafe else value)
	return encoded


# Untyped on purpose: a freed object fails a typed parameter before the
# validity check can run.
static func _encode_object(value: Variant, scene_root: Node) -> Variant:
	if not is_instance_valid(value):
		return null
	if value is Node:
		var node := value as Node
		if scene_root != null and (node == scene_root or scene_root.is_ancestor_of(node)):
			return {"$node": TextSanitizer.clean_line(str(scene_root.get_path_to(node)))}
		return {"$type": "Node", "class": node.get_class()}
	if value is Resource:
		var path := (value as Resource).resource_path
		# A path containing "::" names a resource embedded in another file.
		if path != "" and not path.contains("::"):
			return {"$res": TextSanitizer.clean_line(path), "class": value.get_class()}
		return {"$type": "Resource", "class": value.get_class(), "embedded": true}
	return {"$type": "Object", "class": value.get_class()}


static func _encode_sequence(values: Array, scene_root: Node, budget: Dictionary, depth: int) -> Variant:
	var encoded := []
	for index in mini(values.size(), MAX_ELEMENTS):
		encoded.append(encode(values[index], scene_root, budget, depth + 1))
	if values.size() > MAX_ELEMENTS:
		return {"$type": "Array", "value": encoded, "size": values.size(), "truncated": true}
	return encoded


static func _encode_dictionary(values: Dictionary, scene_root: Node, budget: Dictionary, depth: int) -> Dictionary:
	var encoded := {}
	var count := 0
	for key in values:
		if count >= MAX_ELEMENTS:
			break
		encoded[TextSanitizer.clean_line(str(key))] = encode(values[key], scene_root, budget, depth + 1)
		count += 1
	return encoded


static func _encode_packed(values: Variant, type: int, budget: Dictionary, depth: int) -> Dictionary:
	var encoded := []
	for index in mini(values.size(), MAX_ELEMENTS):
		encoded.append(encode(values[index], null, budget, depth + 1))
	var result := {"$type": type_string(type), "value": encoded, "size": values.size()}
	if values.size() > MAX_ELEMENTS:
		result["truncated"] = true
	return result
