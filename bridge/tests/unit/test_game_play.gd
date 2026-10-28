extends "res://tests/suite.gd"
## game_play.gd: input sequences, game speed, the visible UI, and checks.

const GamePlay = preload("res://addons/gdcli/runtime/game_play.gd")

const ACTION := "ui_accept"

var _main: Node2D


func cleanup() -> void:
	Input.action_release(ACTION)
	Engine.time_scale = 1.0
	if _main != null:
		_main.free()
		_main = null


func _tree() -> SceneTree:
	return Engine.get_main_loop()


# Main with a Player, and a menu: a Label and a Button, one hidden Label.
func _play() -> RefCounted:
	_main = Node2D.new()
	_main.name = "PlayTestMain"
	var player := CharacterBody2D.new()
	player.name = "Player"
	player.position = Vector2(10, 20)
	_main.add_child(player)
	var menu := Control.new()
	menu.name = "Menu"
	_main.add_child(menu)
	var title := Label.new()
	title.name = "Title"
	title.text = "Game Over"
	menu.add_child(title)
	var again := Button.new()
	again.name = "Again"
	again.text = "Try again"
	again.disabled = true
	menu.add_child(again)
	var secret := Label.new()
	secret.name = "Secret"
	secret.text = "hidden words"
	secret.visible = false
	menu.add_child(secret)
	_tree().root.add_child(_main)
	return GamePlay.new(_tree())


func test_game_play_reads_key_names_with_modifiers() -> void:
	var save := GamePlay._key("Ctrl+S")
	var plus := GamePlay._key("Shift++")
	var space := GamePlay._key("Space")

	equal([save.keycode, save.ctrl_pressed, save.pressed], [KEY_S, true, true], "Ctrl+S")
	equal([plus.keycode, plus.shift_pressed], [KEY_PLUS, true], "the plus key")
	equal([space.physical_keycode, space.ctrl_pressed], [KEY_SPACE, false], "a plain key")
	equal([GamePlay._key("Ctrl+Nope"), GamePlay._key("Hyper+A"), GamePlay._key("")], [null, null, null], "names it does not know")


func test_game_play_input_events_sends_the_first_at_once_and_times_the_rest() -> void:
	var play := _play()

	var reply: Dictionary = play.input_events({"events": [{"action": ACTION, "hold": 0.2}, {"wait": 0.3}, {"key": "Space"}, {"mouse_move": [5, 5]}]})
	Input.flush_buffered_events()

	check(reply["ok"], "played: %s" % reply)
	equal(reply["data"]["duration"], 0.55, "0.2 held, 0.3 waited, a 0.05 tap, a move takes no time")
	check(Input.is_action_pressed(ACTION), "the first event is pressed now; its release waits for game time")


func test_game_play_input_events_refuses_what_it_cannot_send() -> void:
	var play := _play()

	var cases := {
		"no events": {"events": []},
		"an unknown key": {"events": [{"key": "Nope"}]},
		"an unknown action": {"events": [{"action": "no_such_action"}]},
		"a click without a place": {"events": [{"mouse_button": "left"}]},
		"a stick out of range": {"events": [{"joypad_axis": 40}]},
		"an event of no kind": {"events": [{"press": "x"}]},
		"too long": {"events": [{"wait": 10}, {"wait": 10}, {"wait": 10}, {"wait": 10}]},
	}
	for name in cases:
		equal(play.input_events(cases[name]).get("error", {}).get("code"), "INVALID_ARGS", name)


func test_game_play_speed_reads_and_sets_the_time_scale() -> void:
	var play := _play()

	var read: Dictionary = play.speed({})
	var slow: Dictionary = play.speed({"scale": 0.25})

	equal([read["data"]["scale"], slow["data"]["scale"], slow["data"]["was"]], [1.0, 0.25, 1.0], "read, then slowed")
	equal(Engine.time_scale, 0.25, "the engine runs slower")
	equal(play.speed({"scale": 100})["error"]["code"], "INVALID_ARGS", "out of range")


func test_game_play_ui_lists_what_is_visible() -> void:
	var play := _play()

	var reply: Dictionary = play.ui({"path": "PlayTestMain/Menu"})
	var by_name := {}
	for element in reply["data"]["elements"]:
		by_name[element["path"].get_file()] = element

	equal(by_name.get("Title", {}).get("text"), "Game Over", "a label's text")
	equal([by_name.get("Again", {}).get("text"), by_name.get("Again", {}).get("disabled")], ["Try again", true], "a button and its state")
	check(not by_name.has("Secret"), "a hidden control is not seen")
	equal(by_name["Title"]["rect"].size(), 4, "where it is on screen")


func test_game_play_expect_judges_every_check() -> void:
	var play := _play()

	var reply: Dictionary = play.expect({"checks": [
		{"path": "PlayTestMain/Player", "property": "position:y", "op": "less", "value": 30},
		{"path": "PlayTestMain/Player", "property": "position", "op": "approx", "value": [10, 20.005]},
		{"path": "PlayTestMain/Player", "property": "position:x", "op": "greater", "value": 50},
		{"path": "PlayTestMain/Nope", "op": "missing"},
		{"text": "Game Over", "op": "exists"},
		{"text": "hidden words", "op": "exists"},
	]})
	var passed := []
	for result in reply["data"]["results"]:
		passed.append(result["passed"])

	equal(passed, [true, true, false, true, true, false], "each judged on its own; hidden text is not on screen")
	equal([reply["data"]["passed"], reply["data"]["failed"]], [false, 2], "the summary")
	equal(reply["data"]["results"][2]["actual"], 10.0, "the actual value, to see why")
	equal(play.expect({"checks": [{"path": "PlayTestMain/Player", "op": "bigger"}]})["error"]["code"], "INVALID_ARGS", "an unknown op")
