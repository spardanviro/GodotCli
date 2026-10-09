extends RefCounted
## The response body shared by the bridge and `gd --format json`.

const STATUS_OK := 200
const STATUS_COMMAND_FAILED := 422

const _STATUS_BY_CODE := {
	"INVALID_ARGS": 400,
	"AUTH_FAILED": 401,
	"FORBIDDEN_ORIGIN": 403,
	"UNKNOWN_COMMAND": 404,
	"READONLY_MODE": 409,
	"CONFIRMATION_REQUIRED": 409,
	"EVAL_DISABLED": 409,
	"PRECONDITION_FAILED": 409,
	"INTERNAL_ERROR": 500,
	"EDITOR_BUSY": 503,
}


static func success(command: String, data: Variant, meta: Dictionary, warnings: Array = []) -> Dictionary:
	return {
		"success": true,
		"command": command,
		"data": data,
		"errors": [],
		"warnings": warnings.duplicate(),
		"meta": meta.duplicate(),
	}


static func failure(command: String, error: Dictionary, meta: Dictionary, warnings: Array = []) -> Dictionary:
	return {
		"success": false,
		"command": command,
		"data": null,
		"errors": [error.duplicate(true)],
		"warnings": warnings.duplicate(),
		"meta": meta.duplicate(),
	}


static func http_status_for(code: String) -> int:
	return _STATUS_BY_CODE.get(code, STATUS_COMMAND_FAILED)
