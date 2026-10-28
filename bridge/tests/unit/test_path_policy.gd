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
		# What a .NET build or restore reads by name.
		"res://Game.csproj.user", "res://Directory.Build.rsp", "res://NuGet.Config", "res://sub/nuget.config",
		"res://global.json", "res://.config/dotnet-tools.json", "res://Game.slnx", "res://Build.proj",
	]:
		equal(PathPolicy.check_text(path, "write")["sensitive"], true, path)
	for path in ["res://main.tscn", "res://scripts/player.gd", "res://sub/project.godot", "res://my_addons/x.gd"]:
		equal(PathPolicy.check_text(path, "write")["sensitive"], false, path)


func test_path_policy_refuses_a_path_through_a_link() -> void:
	# On Windows a directory junction, which anyone can make without rights;
	# elsewhere a symbolic link. Either would let a write leave the project.
	var target := ProjectSettings.globalize_path("res://tests/tmp/link_target")
	var link := ProjectSettings.globalize_path("res://tests/tmp/link_here")
	DirAccess.make_dir_recursive_absolute(target)
	DirAccess.remove_absolute(link)
	if OS.get_name() == "Windows":
		OS.execute("cmd.exe", ["/c", "mklink", "/J", link.replace("/", "\\"), target.replace("/", "\\")])
	else:
		DirAccess.open(target).create_link(target, link)
	check(DirAccess.dir_exists_absolute(link), "the link was made")
	# check(), not check_text(): looking at the disk is the full check's part.
	check(not PathPolicy.check("res://tests/tmp/link_here/x.gd", "write")["ok"], "a write through the link")
	check(not PathPolicy.check("res://tests/tmp/link_here/x.gd", "read")["ok"], "a read through the link")
	check(PathPolicy.check("res://tests/tmp/link_target/x.gd", "write")["ok"], "the real folder")
	DirAccess.remove_absolute(link)
	DirAccess.remove_absolute(target)


func test_path_policy_a_nested_git_folder_is_neither_read_nor_listed() -> void:
	check(not _allowed("res://sub/.git/config", "read"), "its config can hold a remote URL with a token")
	check(not _allowed("res://a/b/.GIT/hooks/pre-commit", "write"), "and nothing is written into it")
	check(PathPolicy.is_hidden_name(".git", "res://sub/"), "listings leave it out at any depth")
	check(not PathPolicy.is_hidden_name(".godot", "res://sub/"), "a nested .godot is an ordinary folder")


func test_path_policy_texts_that_use_files_outside_the_project_are_found() -> void:
	var outside_script := '[ext_resource type="Script" path="C:/elsewhere/evil.gd" id="1"]'
	var import_script := '[params]\nimport_script/path="/tmp/post.gd"'
	var climbing := '[ext_resource type="Texture2D" path="res://../secret.png" id="1"]'
	var ordinary := '[ext_resource type="Texture2D" uid="uid://abc" path="res://art/a.png" id="1"]\n[remap]\npath.s3tc="res://.godot/imported/a.ctex"'

	equal(PathPolicy.outside_reference_in_text(outside_script), "C:/elsewhere/evil.gd", "a script on another drive")
	equal(PathPolicy.outside_reference_in_text(import_script), "/tmp/post.gd", "an import script outside")
	equal(PathPolicy.outside_reference_in_text(climbing), "res://../secret.png", "a path that climbs out")
	equal(PathPolicy.outside_reference_in_text(ordinary), "", "files of the project are fine")
	check(PathPolicy.check_text("res://art/a.png.import", "write")["sensitive"], "import settings are a sensitive file")


func test_path_policy_other_spellings_and_extensions_of_a_reference_are_found() -> void:
	var root_script := '[params]\nnodes/root_script="/tmp/evil.gd"'
	var dictionary := '_subresources={"materials": {"m": {"use_external/path": "C:/x.tres"}}}'
	var material := '[gd_resource type="StandardMaterial3D" format=3]\n[ext_resource type="Script" path="/tmp/evil.gd" id="1"]'

	equal(PathPolicy.outside_reference_in_text(root_script), "/tmp/evil.gd", "a root script in import settings")
	equal(PathPolicy.outside_reference_in_text(dictionary), "C:/x.tres", "a dictionary entry")
	check(PathPolicy.names_other_files("res://art/stone.material", material), "a text resource under any extension, by its first line")
	check(not PathPolicy.names_other_files("res://notes.txt", "just notes"), "ordinary text is not")


func test_path_policy_low_findings() -> void:
	for path in ["res://CONIN$", "res://a/conout$.txt", "res://COM¹", "res://lpt².log"]:
		check(not _allowed(path, "read"), "a Windows device name: %s" % path)
	for path in ["res://.vscode/tasks.json", "res://.github/workflows/ci.yml", "res://.envrc", "res://.husky/pre-commit", "res://sub/.vscode/settings.json"]:
		check(PathPolicy.check_text(path, "write")["sensitive"], "run by other tools without asking: %s" % path)
	check(not PathPolicy.check_text("res://.github/README.md", "write")["sensitive"], "other files of .github are ordinary")
