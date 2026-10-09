extends "res://tests/suite.gd"

const Schema = preload("res://addons/gdcli/core/schema.gd")

const SCHEMA := {
	"type": "object",
	"properties": {
		"path": {"type": "string"},
		"depth": {"type": "integer", "default": 8, "minimum": 0, "maximum": 64},
		"recursive": {"type": "boolean", "default": false},
		"kind": {"type": "string", "enum": ["file", "dir"]},
		"names": {"type": "array", "items": {"type": "string"}},
		"scale": {"type": "number"},
		"extra": {"type": "object"},
	},
	"required": ["path"],
}


func _code(args: Dictionary) -> String:
	var result := Schema.validate(args, SCHEMA)
	return "" if result["ok"] else result["error"]["code"]


func test_schema_valid_args_get_defaults_filled_in() -> void:
	var result := Schema.validate({"path": "."}, SCHEMA)

	check(result["ok"], "valid")
	equal(result["args"], {"path": ".", "depth": 8, "recursive": false}, "normalized args")


func test_schema_integral_float_becomes_an_integer() -> void:
	var result := Schema.validate({"path": ".", "depth": 3.0}, SCHEMA)

	equal(typeof(result["args"]["depth"]), TYPE_INT, "type")
	equal(result["args"]["depth"], 3, "value")


func test_schema_float_beyond_exact_integers_is_rejected() -> void:
	equal(_code({"path": ".", "depth": 1e30}), "INVALID_ARGS", "1e30 is not an integer the bridge can represent")


func test_schema_missing_required_argument_is_rejected() -> void:
	var result := Schema.validate({}, SCHEMA)

	equal(result["ok"], false, "ok")
	equal(result["error"]["code"], "INVALID_ARGS", "code")
	equal(result["error"]["details"]["argument"], "path", "which argument")


func test_schema_unknown_argument_is_rejected() -> void:
	equal(_code({"path": ".", "pth": "typo"}), "INVALID_ARGS", "typo")


func test_schema_wrong_types_are_rejected() -> void:
	for args in [
		{"path": 1}, {"path": ".", "depth": 1.5}, {"path": ".", "depth": "3"}, {"path": ".", "recursive": 1},
		{"path": ".", "names": "a"}, {"path": ".", "names": ["a", 2]}, {"path": ".", "scale": "big"},
		{"path": ".", "extra": []},
	]:
		equal(_code(args), "INVALID_ARGS", var_to_str(args))


func test_schema_range_and_enum_are_enforced() -> void:
	equal(_code({"path": ".", "depth": -1}), "INVALID_ARGS", "below minimum")
	equal(_code({"path": ".", "depth": 65}), "INVALID_ARGS", "above maximum")
	equal(_code({"path": ".", "kind": "link"}), "INVALID_ARGS", "not in enum")
	equal(_code({"path": ".", "kind": "dir", "depth": 64, "scale": 2}), "", "boundary values")
