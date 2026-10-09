extends "res://tests/suite.gd"

const PathPolicy = preload("res://addons/gdcli/core/path_policy.gd")


func _allowed(path: String, access: String) -> bool:
	return PathPolicy.check_text(path, access)["ok"]


func test_path_policy_plain_project_paths_are_allowed() -> void:
	for path in ["res://", "res://main.tscn", "res://scenes/level_1.tscn", "res://scenes/", "res://a b/c.gd", "res://a~b/~x.gd"]:
		check(_allowed(path, "read"), "read %s" % path)
		check(_allowed(path, "write"), "write %s" % path)


func test_path_policy_normalizes_a_trailing_slash() -> void:
	equal(PathPolicy.check_text("res://scenes/", "read")["path"], "res://scenes", "folder")
	equal(PathPolicy.check_text("res://", "read")["path"], "res://", "root")


func test_path_policy_rejects_paths_outside_res() -> void:
	for path in ["user://save.dat", "C:/Windows/win.ini", "/etc/passwd", "main.tscn", "", "file:///x", "RES://a"]:
		check(not _allowed(path, "read"), path)


func test_path_policy_rejects_traversal_and_odd_segments() -> void:
	for path in [
		"res://../secret", "res://a/../../b", "res://a/./b", "res://a//b", "res://a\\b", "res://a/b.txt:stream",
		"res://C:/x", "res://dir./x", "res://dir /x", "res://nul", "res://a/COM1.txt", "res://Aux",
		"res://GODOT~1/export_credentials.cfg", "res://GIT~1/config", "res://a/LONGFI~2.TXT",
	]:
		var result := PathPolicy.check_text(path, "read")
		equal(result["ok"], false, path)
		equal(result["error"]["code"], "PATH_NOT_ALLOWED", path)


func test_path_policy_hidden_roots_are_blocked_for_reading_in_any_case() -> void:
	for path in ["res://.godot/export_credentials.cfg", "res://.GODOT/x", "res://.git/config", "res://.Git", "res://.godot"]:
		check(not _allowed(path, "read"), path)
	check(_allowed("res://.gitignore", "read"), ".gitignore is an ordinary file")
	check(_allowed("res://docs/.godot/x", "read"), "only the top-level folder is special")


func test_path_policy_own_addon_is_readable_but_not_writable() -> void:
	check(_allowed("res://addons/gdcli/plugin.gd", "read"), "read")
	for path in ["res://addons/gdcli/plugin.gd", "res://Addons/GDCLI/core/x.gd", "res://addons/gdcli"]:
		check(not _allowed(path, "write"), "write %s" % path)
	check(_allowed("res://addons/gdcli_extras/x.gd", "write"), "a different addon with a similar name")


func test_path_policy_flags_sensitive_targets() -> void:
	for path in [
		"res://project.godot", "res://Project.Godot", "res://override.cfg", "res://export_presets.cfg",
		"res://addons/other/plugin.cfg", "res://gdcli_commands/x.gd", "res://bin/lib.gdextension",
	]:
		equal(PathPolicy.check_text(path, "write")["sensitive"], true, path)
	for path in ["res://main.tscn", "res://scripts/player.gd", "res://sub/project.godot", "res://my_addons/x.gd"]:
		equal(PathPolicy.check_text(path, "write")["sensitive"], false, path)
