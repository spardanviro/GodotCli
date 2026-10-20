@tool
extends EditorPlugin

const AccessPolicy = preload("core/access_policy.gd")
const Bridge = preload("core/bridge.gd")
const CustomCommands = preload("core/custom_commands.gd")
const ErrorLog = preload("core/error_log.gd")
const EditorContext = preload("core/editor_context.gd")
const HttpServer = preload("core/http_server.gd")
const LockFile = preload("core/lock_file.gd")
const Registry = preload("core/registry.gd")
const AnimationCommands = preload("commands/animation_commands.gd")
const AnimationTreeCommands = preload("commands/animation_tree_commands.gd")
const EditorCommands = preload("commands/editor_commands.gd")
const EditorControlCommands = preload("commands/editor_control_commands.gd")
const FsCommands = preload("commands/fs_commands.gd")
const FsEditCommands = preload("commands/fs_edit_commands.gd")
const GameCommands = preload("commands/game_commands.gd")
const GameDebugCommands = preload("commands/game_debug_commands.gd")
const GameLink = preload("core/game_link.gd")
const NodeCommands = preload("commands/node_commands.gd")
const NavigationCommands = preload("commands/navigation_commands.gd")
const NodeEditCommands = preload("commands/node_edit_commands.gd")
const ProjectCommands = preload("commands/project_commands.gd")
const ProjectEditCommands = preload("commands/project_edit_commands.gd")
const SceneCommands = preload("commands/scene_commands.gd")
const SceneEditCommands = preload("commands/scene_edit_commands.gd")
const SpriteCommands = preload("commands/sprite_commands.gd")
const TileCommands = preload("commands/tile_commands.gd")
const TilesetCommands = preload("commands/tileset_commands.gd")

# Kept in step with plugin.cfg, cli/package.json and cli/src/protocol.ts
# by scripts/check-versions.mjs.
const BRIDGE_VERSION := "0.3.1"
const PROTOCOL := 1

const INSTANCE_ID_BYTES := 8
const TOKEN_BYTES := 32
# A headless host started by gd quits by itself when nobody talks to it.
const HOST_IDLE_EXIT_MSEC := 30 * 60 * 1000
const IDLE_CHECK_SECONDS := 30.0

var _server: HttpServer
var _lock_file: LockFile
var _bridge: Bridge
var _context: EditorContext
var _error_log: RefCounted
var _custom_commands: CustomCommands
var _game_link: GameLink
var _idle_check_in := IDLE_CHECK_SECONDS
# Command handlers are Callables, which do not keep their objects alive.
var _command_sets: Array = []


func _enter_tree() -> void:
	var crypto := Crypto.new()
	var instance_id := crypto.generate_random_bytes(INSTANCE_ID_BYTES).hex_encode()
	var token := crypto.generate_random_bytes(TOKEN_BYTES).hex_encode()
	if instance_id.length() != INSTANCE_ID_BYTES * 2 or token.length() != TOKEN_BYTES * 2:
		push_error("gdcli: no secure random numbers available; the bridge is not running.")
		return

	_error_log = ErrorLog.create()
	var context := EditorContext.new(self, _error_log, LockFile.home_dir())
	_context = context
	_game_link = GameLink.new()
	add_debugger_plugin(_game_link)
	_game_link.listen_to_debuggers()
	context.set_game_link(_game_link)
	var registry := Registry.new()
	_command_sets = [
		EditorCommands.new(context),
		SceneCommands.new(context),
		NodeCommands.new(context),
		FsCommands.new(),
		ProjectCommands.new(),
		NodeEditCommands.new(context),
		SceneEditCommands.new(context),
		FsEditCommands.new(context),
		ProjectEditCommands.new(context),
		EditorControlCommands.new(context),
		AnimationCommands.new(context),
		AnimationTreeCommands.new(context),
		TileCommands.new(context),
		TilesetCommands.new(context),
		SpriteCommands.new(context),
		NavigationCommands.new(context),
		GameCommands.new(context),
		GameDebugCommands.new(context),
	]
	for command_set in _command_sets:
		command_set.register(registry)
	# Project code is not loaded in read-only mode: what it does cannot be vetted.
	var startup_warnings := []
	if context.access_mode() != AccessPolicy.MODE_READONLY:
		_custom_commands = CustomCommands.new(context)
		startup_warnings.append_array(_custom_commands.load_into(registry))

	var identity := {"instance_id": instance_id, "protocol": PROTOCOL, "bridge_version": BRIDGE_VERSION}
	var bridge := Bridge.new(registry, context, identity, token)
	_bridge = bridge
	var ignored: Array = context.ignored_project_settings()
	if not ignored.is_empty():
		startup_warnings.append("Project settings under gdcli/ are ignored; access is set in the editor settings.")
	bridge.set_startup_warnings(startup_warnings)

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


# Called when the plugin is switched on in the project settings. The helper
# that answers from inside a running game is an autoload of the project.
func _enable_plugin() -> void:
	if not ProjectSettings.has_setting(GameLink.AUTOLOAD_SETTING):
		add_autoload_singleton(GameLink.AUTOLOAD_NAME, GameLink.AUTOLOAD_SCRIPT)


func _disable_plugin() -> void:
	if ProjectSettings.has_setting(GameLink.AUTOLOAD_SETTING):
		remove_autoload_singleton(GameLink.AUTOLOAD_NAME)


func _exit_tree() -> void:
	if _game_link != null:
		remove_debugger_plugin(_game_link)
		_game_link = null
	if _lock_file != null:
		_lock_file.remove()
		_lock_file = null
	if _server != null:
		_server.stop()
		_server = null
	if _error_log != null:
		_error_log.stop()
		_error_log = null
	_command_sets = []
	_custom_commands = null
	_bridge = null
	_context = null


func _process(delta: float) -> void:
	if _server == null:
		return
	_server.poll()
	_idle_check_in -= delta
	if _idle_check_in <= 0.0:
		_idle_check_in = IDLE_CHECK_SECONDS
		if _context.is_host() and _bridge.idle_msec() > HOST_IDLE_EXIT_MSEC:
			print("gdcli: no requests for a while; the headless host is quitting.")
			get_tree().quit()


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
