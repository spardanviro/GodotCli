extends Node

## How many ui_accept events reached _unhandled_input (the bridge test presses it with game_input).
var accepted := 0


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		accepted += 1
