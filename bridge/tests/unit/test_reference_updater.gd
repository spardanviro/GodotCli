extends "res://tests/suite.gd"

const FileMove = preload("res://addons/gdcli/core/file_move.gd")
const ReferenceUpdater = preload("res://addons/gdcli/core/reference_updater.gd")
const FakeContext = preload("res://tests/fake_context.gd")

const FROM := "res://art/hero.png"
const TO := "res://art/characters/hero.png"
const FIXTURES := "res://tests/fixtures/"


func _file_move() -> RefCounted:
	return ReferenceUpdater.new(FROM, TO, false)


func _folder_move() -> RefCounted:
	return ReferenceUpdater.new("res://art", "res://assets/art", true)


func test_reference_updater_rewrite_replaces_the_path_wherever_it_stands() -> void:
	var updater := _file_move()
	var scene := "[ext_resource type=\"Texture2D\" path=\"res://art/hero.png\" id=\"1\"]\n"
	var script := "var a = preload('res://art/hero.png')\n# see res://art/hero.png.\nload(\"res://art/hero.png::2\")\n"

	equal(updater.rewrite(scene), "[ext_resource type=\"Texture2D\" path=\"res://art/characters/hero.png\" id=\"1\"]\n", "scene reference")
	equal(
		updater.rewrite(script),
		"var a = preload('res://art/characters/hero.png')\n# see res://art/characters/hero.png.\nload(\"res://art/characters/hero.png::2\")\n",
		"single quotes, a comment that ends the sentence, a sub-resource",
	)


func test_reference_updater_rewrite_leaves_longer_paths_alone() -> void:
	var updater := _file_move()
	var text := "\"res://art/hero.png.import\" \"res://art/hero.png.bak\" \"res://art/hero.pngx\" \"res://art/hero.png/x\" \"res://art/hero.png-old\""

	equal(updater.rewrite(text), text, "sidecars, other extensions, sub-paths and suffixed names")


func test_reference_updater_folder_rewrite_moves_everything_below() -> void:
	var updater := _folder_move()
	var text := "preload(\"res://art/hero.png\")\nDirAccess.open(\"res://art\")\n\"res://art/\" + name\n\"res://artwork/x.png\" \"res://art.png\"\n"

	equal(
		updater.rewrite(text),
		"preload(\"res://assets/art/hero.png\")\nDirAccess.open(\"res://assets/art\")\n\"res://assets/art/\" + name\n\"res://artwork/x.png\" \"res://art.png\"\n",
		"paths below the folder, the folder itself, a prefix used to build paths; not names that only start alike",
	)
	equal(updater.moved_path("res://art/a/b.tscn"), "res://assets/art/a/b.tscn", "a file inside follows the folder")
	equal(updater.moved_path("res://other/b.tscn"), "res://other/b.tscn", "a file outside stays")


func test_reference_updater_setting_after_handles_strings_autoloads_and_lists() -> void:
	var updater := _file_move()

	equal(updater.setting_after(FROM), TO, "plain path")
	equal(updater.setting_after("*" + FROM), "*" + TO, "singleton autoload")
	equal(updater.setting_after("res://other.png"), "res://other.png", "another path")
	equal(updater.setting_after(PackedStringArray([FROM, "res://b.po"])), PackedStringArray([TO, "res://b.po"]), "a list of paths")
	equal(updater.setting_after(42), 42, "not text")


func test_reference_updater_find_lists_the_files_that_name_the_path() -> void:
	# Put together here so that this file does not itself contain the reference.
	var found: Dictionary = ReferenceUpdater.new(FIXTURES + "move_target.gd", FIXTURES + "moved.gd", false).find()

	equal(found["files"], [FIXTURES + "uses_move_target.gd"], "the script that preloads it")
	equal(found["settings"], [], "no project setting names it")
	equal(found["truncated"], false, "the whole project was searched")


func test_reference_updater_find_reports_paths_built_from_pieces() -> void:
	var found: Dictionary = ReferenceUpdater.new(FIXTURES + "move_target.gd", FIXTURES + "moved.gd", false).find()
	var texts := []
	for entry in found["dynamic"]:
		if entry["file"] == FIXTURES + "builds_paths.gd":
			texts.append(entry["text"])

	equal(texts, ["\"res://tests/fixtures/move_\"", "\"res://tests/fixtures/%s_target.gd\""], "a prefix and a format, not the unrelated literal")


func test_file_move_saves_open_scenes_one_step_per_poll_before_moving() -> void:
	var context := FakeContext.new()
	context.path = "res://current.tscn"
	var from := FIXTURES + "no_such_file.gd"
	var references: Dictionary = ReferenceUpdater.nothing()
	references["files"] = ["res://level.tscn"]
	var updater := ReferenceUpdater.new(from, "res://tests/tmp/x.gd", false)
	var job := FileMove.new(context, from, "res://tests/tmp/x.gd", updater, references, ["res://level.tscn"], false)

	var replies := []
	for attempt in 8:
		replies.append(job.poll())
		if not replies[-1].is_empty():
			break

	equal(context.opened, ["res://level.tscn", "res://current.tscn"] as Array[String], "the open scene is shown, then the one that was being edited")
	equal(context.path, "res://current.tscn", "the editor is back on the scene it was editing")
	equal(context.saved_scenes, ["res://level.tscn"] as Array[String], "only the scene that refers to the file is saved")
	check(replies.size() > 3, "the steps are spread over several polls")
	equal(replies[-1]["error"]["code"], "COMMAND_FAILED", "a file that cannot be moved is reported")
	equal(context.reloaded, [] as Array[String], "and nothing is loaded again")
