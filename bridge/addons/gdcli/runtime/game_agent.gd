extends Node
## The part of the gd bridge that runs inside the game. The editor's bridge
## talks to it over the debugger connection the editor already has to a game
## it started, which is how `game_tree` and the other game_* commands see a
## running game.
##
## It is registered as the autoload "GdcliGame". In an exported game, and in
## any game that has no debugger attached, it removes itself at once and does
## nothing.

const GameInspector = preload("game_inspector.gd")

const CAPTURE := "gdcli"
const REQUEST := "request"
const MESSAGE_HELLO := "gdcli:hello"
const MESSAGE_REPLY := "gdcli:reply"
const RUNTIME_PROTOCOL := 1

var _inspector: GameInspector


func _ready() -> void:
	# "editor" is a feature of the editor binary only, which is what runs a game
	# started from the editor. A debug export pointed at some debugger with
	# --remote-debug does not have it, and gets no helper.
	if not (EngineDebugger.is_active() and OS.has_feature("editor")):
		queue_free()
		return
	# Requests are answered while the game is paused too.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_inspector = GameInspector.new(get_tree())
	EngineDebugger.register_message_capture(CAPTURE, _on_message)
	EngineDebugger.send_message(MESSAGE_HELLO, [RUNTIME_PROTOCOL])


func _exit_tree() -> void:
	if _inspector != null and EngineDebugger.has_capture(CAPTURE):
		EngineDebugger.unregister_message_capture(CAPTURE)


# `message` arrives without the "gdcli:" prefix; `data` is [id, method, args].
func _on_message(message: String, data: Array) -> bool:
	if message != REQUEST or data.size() != 3:
		return true
	if not (data[0] is int and data[1] is String and data[2] is Dictionary):
		return true
	EngineDebugger.send_message(MESSAGE_REPLY, [data[0], _inspector.handle(data[1], data[2])])
	return true
