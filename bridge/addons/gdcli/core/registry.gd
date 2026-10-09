extends RefCounted
## The commands the bridge exposes. A descriptor is the public description
## returned by GET /v1/commands; the handler is `func(args: Dictionary) -> reply`.

const AccessPolicy = preload("access_policy.gd")

const PROTOCOL_SINCE := 1
const _NAME_PATTERN := "^[a-z][a-z0-9_]*$"

var _entries := {}
var _name_regex := RegEx.create_from_string(_NAME_PATTERN)


func register(descriptor: Dictionary, handler: Callable) -> void:
	var name: String = descriptor.get("name", "")
	assert(_name_regex.search(name) != null, "Command names are lower snake case: %s" % name)
	assert(not _entries.has(name), "Command registered twice: %s" % name)
	assert(descriptor.get("risk", "") in AccessPolicy.RISKS, "Unknown risk tier for %s" % name)

	var complete := descriptor.duplicate(true)
	complete["group"] = descriptor.get("group", name.get_slice("_", 0))
	complete["undoable"] = descriptor.get("undoable", false)
	complete["requires"] = descriptor.get("requires", [])
	complete["params"] = descriptor.get("params", {"type": "object", "properties": {}})
	complete["since"] = descriptor.get("since", PROTOCOL_SINCE)
	_entries[name] = {"descriptor": complete, "handler": handler}


func has(name: String) -> bool:
	return _entries.has(name)


func descriptor_of(name: String) -> Dictionary:
	return _entries[name]["descriptor"]


func handler_of(name: String) -> Callable:
	return _entries[name]["handler"]


func descriptors() -> Array:
	var names := _entries.keys()
	names.sort()
	var result := []
	for name in names:
		result.append(_entries[name]["descriptor"].duplicate(true))
	return result
