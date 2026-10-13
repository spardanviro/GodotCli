extends RefCounted
## What a command handler returns. Messages and hints are fixed text; anything
## that comes from the project goes into `details` (docs/protocol.md section 4.5).


static func ok(data: Variant, warnings: Array = []) -> Dictionary:
	return {"ok": true, "data": data, "warnings": warnings.duplicate()}


## For answers that arrive later, such as one from the running game.
## `waiter.poll()` returns {} while waiting and a reply once it is known.
## `exclusive` is for work that changes the editor over several frames: until
## it is done, other commands that change something are told to retry.
static func later(waiter: RefCounted, exclusive: bool = false) -> Dictionary:
	return {"ok": true, "later": waiter, "exclusive": exclusive}


static func fail(code: String, message: String, hint: String = "", details: Dictionary = {}) -> Dictionary:
	var error := {"code": code, "message": message}
	if hint != "":
		error["hint"] = hint
	if not details.is_empty():
		error["details"] = details.duplicate(true)
	return {"ok": false, "error": error}
