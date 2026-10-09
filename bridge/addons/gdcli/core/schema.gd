extends RefCounted
## Validates command arguments against the JSON Schema subset used in command
## descriptors: type, properties, required, enum, default, items, minimum, maximum.

const Reply = preload("reply.gd")

const MAX_SAFE_INTEGER := 9007199254740992.0


## Returns {ok = true, args} with defaults filled in and integers restored,
## or a failed reply with code INVALID_ARGS.
static func validate(args: Dictionary, schema: Dictionary) -> Dictionary:
	var properties: Dictionary = schema.get("properties", {})
	var normalized := {}

	for key in args:
		if not properties.has(key):
			return _invalid("Unknown argument.", {"argument": str(key), "allowed": properties.keys()})

	for required_name in schema.get("required", []):
		if not args.has(required_name):
			return _invalid("A required argument is missing.", {"argument": required_name})

	for name in properties:
		var property_schema: Dictionary = properties[name]
		if not args.has(name):
			if property_schema.has("default"):
				normalized[name] = property_schema["default"]
			continue
		var checked := _check_value(args[name], property_schema)
		if not checked["ok"]:
			return _invalid(checked["reason"], {"argument": name, "expected": property_schema.get("type", "any")})
		normalized[name] = checked["value"]

	return {"ok": true, "args": normalized}


static func _check_value(value: Variant, schema: Dictionary) -> Dictionary:
	var expected: String = schema.get("type", "")
	var converted: Variant = value
	match expected:
		"string":
			if not value is String:
				return _mismatch()
		"boolean":
			if not value is bool:
				return _mismatch()
		"integer":
			# Godot's JSON parser reads every number as a float.
			# Beyond 2^53 a float no longer names one integer.
			if value is float and value == floorf(value) and absf(value) <= MAX_SAFE_INTEGER:
				converted = int(value)
			elif not value is int:
				return _mismatch()
		"number":
			if not (value is float or value is int):
				return _mismatch()
		"object":
			if not value is Dictionary:
				return _mismatch()
		"array":
			if not value is Array:
				return _mismatch()
			var items := _check_items(value, schema.get("items", {}))
			if not items["ok"]:
				return items
			converted = items["value"]

	if schema.has("enum") and converted not in schema["enum"]:
		return {"ok": false, "reason": "The value is not one of the allowed choices."}
	if schema.has("minimum") and converted < schema["minimum"]:
		return {"ok": false, "reason": "The value is below the minimum."}
	if schema.has("maximum") and converted > schema["maximum"]:
		return {"ok": false, "reason": "The value is above the maximum."}
	return {"ok": true, "value": converted}


static func _check_items(values: Array, item_schema: Dictionary) -> Dictionary:
	if item_schema.is_empty():
		return {"ok": true, "value": values}
	var converted := []
	for item in values:
		var checked := _check_value(item, item_schema)
		if not checked["ok"]:
			return checked
		converted.append(checked["value"])
	return {"ok": true, "value": converted}


static func _mismatch() -> Dictionary:
	return {"ok": false, "reason": "The argument has the wrong type."}


static func _invalid(message: String, details: Dictionary) -> Dictionary:
	return Reply.fail("INVALID_ARGS", message, "GET /v1/commands lists every command's arguments.", details)
