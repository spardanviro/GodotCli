@tool
extends EditorPlugin

const Bridge = preload("core/bridge.gd")
const EditorContext = preload("core/editor_context.gd")
const HttpServer = preload("core/http_server.gd")
const LockFile = preload("core/lock_file.gd")
const Registry = preload("core/registry.gd")
const EditorCommands = preload("commands/editor_commands.gd")
const FsCommands = preload("commands/fs_commands.gd")
const NodeCommands = preload("commands/node_commands.gd")
const ProjectCommands = preload("commands/project_commands.gd")
const SceneCommands = preload("commands/scene_commands.gd")

# Kept in step with plugin.cfg, cli/package.json and cli/src/protocol.ts
# by scripts/check-versions.mjs.
const BRIDGE_VERSION := "0.0.1"
const PROTOCOL := 1

const INSTANCE_ID_BYTES := 8
const TOKEN_BYTES := 32

var _server: HttpServer
var _lock_file: LockFile
# Command handlers are Callables, which do not keep their objects alive.
var _command_sets: Array = []


func _enter_tree() -> void:
	var crypto := Crypto.new()
	var instance_id := crypto.generate_random_bytes(INSTANCE_ID_BYTES).hex_encode()
	var token := crypto.generate_random_bytes(TOKEN_BYTES).hex_encode()
	if instance_id.length() != INSTANCE_ID_BYTES * 2 or token.length() != TOKEN_BYTES * 2:
		push_error("gdcli: no secure random numbers available; the bridge is not running.")
		return

	var context := EditorContext.new()
	var registry := Registry.new()
	_command_sets = [
		EditorCommands.new(context),
		SceneCommands.new(context),
		NodeCommands.new(context),
		FsCommands.new(),
		ProjectCommands.new(),
	]
	for command_set in _command_sets:
		command_set.register(registry)

	var identity := {"instance_id": instance_id, "protocol": PROTOCOL, "bridge_version": BRIDGE_VERSION}
	var bridge := Bridge.new(registry, context, identity, token)
	var ignored: Array = context.ignored_project_settings()
	if not ignored.is_empty():
		bridge.set_startup_warnings(["Project settings under gdcli/ are ignored; access is set in the editor settings."])

	# Listen first: the lock file must never point at a port nobody answers on.
	_server = HttpServer.new()
	var port := _server.start(bridge)
	if port == 0:
		push_error("gdcli: could not open a local port; the bridge is not running.")
		_server = null
		return
	bridge.set_port(port)

	_lock_file = LockFile.new()
	var written := _lock_file.write(_lock_fields(identity, port, token, context.is_headless()))
	if written != OK:
		push_error("gdcli: could not write the instance file (%s); gd will not find this editor." % error_string(written))
	print("gdcli bridge %s listening on 127.0.0.1:%d (protocol %d)" % [BRIDGE_VERSION, port, PROTOCOL])


func _exit_tree() -> void:
	if _lock_file != null:
		_lock_file.remove()
		_lock_file = null
	if _server != null:
		_server.stop()
		_server = null
	_command_sets = []


func _process(_delta: float) -> void:
	if _server != null:
		_server.poll()


func _lock_fields(identity: Dictionary, port: int, token: String, headless: bool) -> Dictionary:
	var version := Engine.get_version_info()
	var fields := identity.duplicate()
	fields.merge({
		"pid": OS.get_process_id(),
		"host": HttpServer.LOOPBACK,
		"port": port,
		"token": token,
		"godot_version": "%d.%d.%d-%s" % [version["major"], version["minor"], version["patch"], version["status"]],
		"project_path": ProjectSettings.globalize_path("res://").trim_suffix("/"),
		"project_name": str(ProjectSettings.get_setting("application/config/name", "")),
		"headless": headless,
		"started_at": Time.get_datetime_string_from_system(true) + "Z",
	})
	return fields
