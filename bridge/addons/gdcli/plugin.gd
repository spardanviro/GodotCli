@tool
extends EditorPlugin

# Kept in step with plugin.cfg, cli/package.json and cli/src/protocol.ts
# by scripts/check-versions.mjs.
const BRIDGE_VERSION := "0.0.1"
const PROTOCOL := 1


func _enter_tree() -> void:
	# scripts/bridge-smoke.mjs looks for this line.
	print("gdcli bridge %s loaded (protocol %d)" % [BRIDGE_VERSION, PROTOCOL])
