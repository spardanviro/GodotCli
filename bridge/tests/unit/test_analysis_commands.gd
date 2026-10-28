extends "res://tests/suite.gd"
## project_analyze over a small folder of files written here.

const AnalysisCommands = preload("res://addons/gdcli/commands/analysis_commands.gd")
const FakeContext = preload("res://tests/fake_context.gd")

const FOLDER := "res://tests/tmp/analysis"


func cleanup() -> void:
	for name in ["a.tscn", "b.tscn", "used.gd", "orphan.gd"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(FOLDER.path_join(name)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FOLDER))


func _write(name: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FOLDER))
	FileAccess.open(FOLDER.path_join(name), FileAccess.WRITE).store_string(text)


func _setup() -> RefCounted:
	_write("a.tscn", "[gd_scene format=3]\n\n[ext_resource type=\"PackedScene\" path=\"res://tests/tmp/analysis/b.tscn\" id=\"1\"]\n[ext_resource type=\"Script\" path=\"res://tests/tmp/analysis/used.gd\" id=\"2\"]\n\n[node name=\"A\" type=\"Node\"]\n")
	_write("b.tscn", "[gd_scene format=3]\n\n[ext_resource type=\"PackedScene\" path=\"res://tests/tmp/analysis/a.tscn\" id=\"1\"]\n\n[node name=\"B\" type=\"Node\"]\n")
	_write("used.gd", "extends Node\n")
	_write("orphan.gd", "extends Node\n# nobody uses me\n")
	return AnalysisCommands.new(FakeContext.new())


func test_project_analyze_finds_files_nothing_uses() -> void:
	var commands := _setup()

	var reply: Dictionary = commands._analyze({"report": "unused"})

	check(FOLDER.path_join("orphan.gd") in reply["data"]["files"], "a script no file names")
	check(not FOLDER.path_join("used.gd") in reply["data"]["files"], "a script a scene uses")


func test_project_analyze_tells_what_uses_a_file_and_what_it_uses() -> void:
	var commands := _setup()

	var reply: Dictionary = commands._analyze({"report": "uses", "path": FOLDER.path_join("b.tscn")})

	equal(reply["data"]["used_by"], [FOLDER.path_join("a.tscn")], "used by")
	equal(reply["data"]["uses"], [FOLDER.path_join("a.tscn")], "and uses")
	equal(commands._analyze({"report": "uses", "path": "user://x"})["error"]["code"], "PATH_NOT_ALLOWED", "inside the project only")


func test_project_analyze_finds_scenes_that_contain_themselves() -> void:
	var commands := _setup()

	var cycles: Array = commands._analyze({"report": "cycles"})["data"]["cycles"]

	check(cycles.any(func(cycle: Array) -> bool: return FOLDER.path_join("a.tscn") in cycle and FOLDER.path_join("b.tscn") in cycle), "a and b contain each other: %s" % [cycles])


func test_project_analyze_counts_the_project() -> void:
	var commands := _setup()

	var stats: Dictionary = commands._analyze({"report": "stats"})["data"]

	check(stats["files"] > 4 and stats["by_extension"].get("gd", 0) >= 2 and stats["script_lines"] > 0, "counted: %s" % [stats["by_extension"]])
	equal(stats["largest"].size(), 10, "the largest files")
