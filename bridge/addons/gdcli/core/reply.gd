extends RefCounted
## What a command handler returns. Messages and hints are fixed text; anything
## that comes from the project goes into `details` (docs/protocol.md section 4.5).


static func ok(data: Variant, warnings: Array = []) -> Dictionary:
	return {"ok": true, "data": data, "warnings": warnings.duplicate()}


static func fail(code: String, message: String, hint: String = "", details: Dictionary = {}) -> Dictionary:
	var error := {"code": code, "message": message}
	if hint != "":
		error["hint"] = hint
	if not details.is_empty():
		error["details"] = details.duplicate(true)
	return {"ok": false, "error": error}
