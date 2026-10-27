extends "res://tests/suite.gd"

const FsCommands = preload("res://addons/gdcli/commands/fs_commands.gd")
const Registry = preload("res://addons/gdcli/core/registry.gd")
const Schema = preload("res://addons/gdcli/core/schema.gd")

const FOLDER := "res://tests/tmp/list_probe"

var _registry: RefCounted
var _commands: RefCounted


func _setup() -> void:
	_registry = Registry.new()
	_commands = FsCommands.new()
	_commands.register(_registry)


func _call(command: String, args: Dictionary) -> Dictionary:
	var validated := Schema.validate(args, _registry.descriptor_of(command)["params"])
	if not validated["ok"]:
		return validated
	return _registry.handler_of(command).call(validated["args"])


func _write(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	FileAccess.open(path, FileAccess.WRITE).store_buffer(bytes)


func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.include_hidden = true
	for name in directory.get_files():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path.path_join(name)))
	for name in directory.get_directories():
		_remove_tree(path.path_join(name))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _paths(reply: Dictionary) -> Array:
	var paths := []
	for entry in reply["data"]["entries"]:
		paths.append(entry["path"].trim_prefix(FOLDER + "/"))
	return paths


func test_fs_list_walks_in_tree_order_so_a_cut_listing_is_its_start() -> void:
	_setup()
	for name in ["c.txt", "a.txt", "a/b.txt"]:
		_write(FOLDER.path_join(name), "x".to_utf8_buffer())

	var full := _call("fs_list", {"path": FOLDER, "recursive": true})
	var cut := _call("fs_list", {"path": FOLDER, "recursive": true, "limit": 2})

	equal(_paths(full), ["a", "a/b.txt", "a.txt", "c.txt"], "a folder's contents come right after it")
	equal(full["data"]["truncated"], false, "nothing left out")
	equal(_paths(cut), ["a", "a/b.txt"], "the cut listing is the start of the full one")
	equal(cut["data"]["truncated"], true, "and says it was cut")
	_remove_tree(FOLDER)


func test_fs_list_hides_a_nested_git_folder() -> void:
	_setup()
	_write(FOLDER.path_join("sub/.git/config"), "token".to_utf8_buffer())
	_write(FOLDER.path_join("sub/keep.txt"), "x".to_utf8_buffer())

	var listed := _call("fs_list", {"path": FOLDER, "recursive": true})
	var read := _call("fs_read_text", {"path": FOLDER.path_join("sub/.git/config")})

	equal(_paths(listed), ["sub", "sub/keep.txt"], "the repository is not listed")
	equal(read.get("error", {}).get("code"), "PATH_NOT_ALLOWED", "nor read")
	_remove_tree(FOLDER)


func test_fs_read_text_cuts_between_characters_and_refuses_invalid_utf8() -> void:
	_setup()
	var accented := FOLDER.path_join("accented.txt")
	var binary := FOLDER.path_join("blob.dat")
	_write(accented, "abé".to_utf8_buffer())
	_write(binary, PackedByteArray([0x41, 0xFF, 0x42, 0x43]))

	var cut := _call("fs_read_text", {"path": accented, "max_bytes": 3})
	var whole := _call("fs_read_text", {"path": accented})
	var refused := _call("fs_read_text", {"path": binary})

	equal(cut["data"]["text"], "ab", "the half character is left out, not replaced")
	equal(cut["data"]["truncated"], true, "and the text says it was cut")
	equal(whole["data"]["text"], "abé", "a whole file reads as it is")
	equal(refused.get("error", {}).get("code"), "COMMAND_FAILED", "bytes that are not UTF-8 are not text, NUL or not")
	_remove_tree(FOLDER)


func test_fs_list_stops_at_the_depth_limit() -> void:
	_setup()
	var deep := FOLDER
	for level in FsCommands.MAX_DEPTH + 2:
		deep = deep.path_join("d")
	_write(deep.path_join("x.txt"), "x".to_utf8_buffer())

	var listed := _call("fs_list", {"path": FOLDER, "recursive": true, "limit": FsCommands.MAX_LIST_LIMIT})

	equal(listed["data"]["truncated"], true, "a tree deeper than the limit is cut, not walked to the end")
	equal(listed["data"]["entries"].size(), FsCommands.MAX_DEPTH + 1, "every folder down to the limit is listed")
	_remove_tree(FOLDER)


func test_fs_read_text_says_so_when_not_even_one_character_fits() -> void:
	_setup()
	var path := FOLDER.path_join("han.txt")
	_write(path, "\u4e2d".to_utf8_buffer())

	var reply := _call("fs_read_text", {"path": path, "max_bytes": 1})

	equal(reply["data"]["text"], "", "nothing whole to return")
	equal(reply.get("warnings", []), ["max_bytes is smaller than the file's first character: nothing could be returned."], "and it is said, so a caller does not loop")
	_remove_tree(FOLDER)


func test_fs_commands_utf8_checks_reject_overlong_and_surrogate_forms() -> void:
	check(FsCommands._is_utf8("plain 中文 \U01f600".to_utf8_buffer()), "ordinary text")
	check(not FsCommands._is_utf8(PackedByteArray([0xC0, 0xAF])), "overlong slash")
	check(not FsCommands._is_utf8(PackedByteArray([0xED, 0xA0, 0x80])), "a surrogate")
	check(not FsCommands._is_utf8(PackedByteArray([0xF4, 0x90, 0x80, 0x80])), "past U+10FFFF")
	equal(FsCommands._utf8_boundary(PackedByteArray([0x61, 0xE4, 0xB8])), 1, "a cut three-byte character goes")
	equal(FsCommands._utf8_boundary(PackedByteArray([0x61, 0xE4, 0xB8, 0xAD])), 4, "a whole one stays")


func test_fs_read_text_reads_past_a_byte_order_mark() -> void:
	_setup()
	var path := FOLDER.path_join("bom.gd")
	_write(path, PackedByteArray([0xEF, 0xBB, 0xBF]) + "extends Node\n".to_utf8_buffer())

	var reply := _call("fs_read_text", {"path": path})

	equal(reply["data"]["text"], "extends Node\n", "the text without the mark")
	equal(reply["data"].get("bom"), true, "and it says the mark was there")
	equal(reply["data"]["truncated"], false, "the whole file was read")
	_remove_tree(FOLDER)
