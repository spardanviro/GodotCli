extends "res://tests/suite.gd"

const FileMove = preload("res://addons/gdcli/core/file_move.gd")
const ReferenceUpdater = preload("res://addons/gdcli/core/reference_updater.gd")
const FakeContext = preload("res://tests/fake_context.gd")

const FROM := "res://art/hero.png"
const TO := "res://art/characters/hero.png"


func test_reference_updater_rewrite_replaces_only_the_exact_quoted_path() -> void:
	var scene := "[ext_resource type=\"Texture2D\" path=\"res://art/hero.png\" id=\"1\"]\n"
	var script := "var a = preload('res://art/hero.png')\nvar b = \"res://art/hero.png.bak\"\n# res://art/hero.png\n"

	var new_scene := ReferenceUpdater.rewrite(scene, FROM, TO)
	var new_script := ReferenceUpdater.rewrite(script, FROM, TO)

	equal(new_scene, "[ext_resource type=\"Texture2D\" path=\"res://art/characters/hero.png\" id=\"1\"]\n", "scene reference")
	equal(
		new_script, "var a = preload('res://art/characters/hero.png')\nvar b = \"res://art/hero.png.bak\"\n# res://art/hero.png\n",
		"single quotes are handled; longer paths and comments are left alone",
	)


func test_reference_updater_setting_after_handles_plain_and_autoload_values() -> void:
	equal(ReferenceUpdater.setting_after(FROM, FROM, TO), TO, "plain path")
	equal(ReferenceUpdater.setting_after("*" + FROM, FROM, TO), "*" + TO, "singleton autoload")
	equal(ReferenceUpdater.setting_after("res://other.png", FROM, TO), "res://other.png", "another path")
	equal(ReferenceUpdater.setting_after(42, FROM, TO), 42, "not a string")


func test_reference_updater_paths_with_quotes_are_not_updated() -> void:
	check(ReferenceUpdater.can_update(FROM, TO), "ordinary paths")
	check(not ReferenceUpdater.can_update("res://a\"b.gd", TO), "a quote in the old path")
	equal(ReferenceUpdater.find("res://a'b.gd", TO)["files"], [], "nothing is searched for such a path")


func test_reference_updater_find_lists_the_files_that_name_the_path() -> void:
	# Put together here so that this file does not itself contain the reference.
	var found := ReferenceUpdater.find("res://tests/fixtures/" + "move_target.gd", "res://tests/fixtures/moved.gd")

	equal(found["files"], ["res://tests/fixtures/uses_move_target.gd"], "the script that preloads it")
	equal(found["settings"], [], "no project setting names it")
	equal(found["truncated"], false, "the whole project was searched")


func test_file_move_saves_open_scenes_one_step_per_poll_before_moving() -> void:
	var context := FakeContext.new()
	context.path = "res://current.tscn"
	var references := {"files": ["res://level.tscn"], "sensitive": [], "settings": [], "truncated": false}
	var job := FileMove.new(context, "res://tests/fixtures/no_such_file.gd", "res://tests/tmp/x.gd", references, ["res://level.tscn"], false)

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
