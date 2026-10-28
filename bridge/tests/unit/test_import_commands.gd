extends "res://tests/suite.gd"
## import_settings_get and import_settings_set against a .import written here;
## the real reimport is covered by scripts/bridge-test.mjs.

const AccessPolicy = preload("res://addons/gdcli/core/access_policy.gd")
const ImportCommands = preload("res://addons/gdcli/commands/import_commands.gd")
const Registry = preload("res://addons/gdcli/core/registry.gd")
const Schema = preload("res://addons/gdcli/core/schema.gd")
const FakeContext = preload("res://tests/fake_context.gd")

const FOLDER := "res://tests/tmp/import_probe"
const SOURCE := FOLDER + "/hero.png"
const IMPORT_TEXT := """[remap]

importer="texture"
type="CompressedTexture2D"

[params]

compress/mode=0
mipmaps/generate=false
process/size_limit=0
roughness/src_normal=""
import_script/path=""
nodes/root_type=""
fonts/fallbacks=[]
_subresources={}
"""

var _context: RefCounted
var _registry: RefCounted
var _commands: RefCounted


func cleanup() -> void:
	for file in [SOURCE, SOURCE + ".import"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(file))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FOLDER))


func _setup(import_text: String = IMPORT_TEXT) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FOLDER))
	FileAccess.open(SOURCE, FileAccess.WRITE).store_string("not really a png")
	if import_text != "":
		FileAccess.open(SOURCE + ".import", FileAccess.WRITE).store_string(import_text)
	_context = FakeContext.new()
	_registry = Registry.new()
	_commands = ImportCommands.new(_context)
	_commands.register(_registry)


func _call(command: String, args: Dictionary, options: Dictionary = {}) -> Dictionary:
	var descriptor: Dictionary = _registry.descriptor_of(command)
	var validated := Schema.validate(args, descriptor["params"])
	if not validated["ok"]:
		return validated
	if descriptor["risk"] == AccessPolicy.RISK_READ:
		return _registry.handler_of(command).call(validated["args"])
	var complete := {"dry_run": false, "confirm": false, "mode": "standard"}
	complete.merge(options, true)
	return _registry.handler_of(command).call(validated["args"], complete)


func _code(command: String, args: Dictionary, options: Dictionary = {}) -> String:
	var reply := _call(command, args, options)
	return "" if reply["ok"] else reply["error"]["code"]


func _saved(key: String) -> Variant:
	var config := ConfigFile.new()
	config.load(SOURCE + ".import")
	return config.get_value("params", key)


func test_import_settings_get_lists_the_importer_and_its_options() -> void:
	_setup()

	var reply := _call("import_settings_get", {"path": SOURCE})

	equal([reply["data"]["importer"], reply["data"]["type"]], ["texture", "CompressedTexture2D"], "the importer")
	equal(reply["data"]["params"].get("mipmaps/generate"), false, "an option with its value")
	check("compress/mode" in reply["data"]["changeable"] and not "import_script/path" in reply["data"]["changeable"], "which options can be changed here")


func test_import_settings_set_puts_the_settings_back_when_the_import_fails() -> void:
	# The fake editor imports nothing, so the file the .import names stays missing.
	_setup(IMPORT_TEXT + "
[deps]

dest_files=[\"res://tests/tmp/import_probe/missing.ctex\"]
")

	var reply := _call("import_settings_set", {"path": SOURCE, "params": {"mipmaps/generate": true}})

	equal(reply.get("error", {}).get("code"), "COMMAND_FAILED", "a failed import is reported")
	equal(_saved("mipmaps/generate"), false, "and the earlier settings are back")


func test_import_settings_set_writes_the_options_and_imports_again() -> void:
	_setup()

	var reply := _call("import_settings_set", {"path": SOURCE, "params": {"mipmaps/generate": true, "compress/mode": 2.0}})

	check(reply["ok"], "set: %s" % reply)
	equal([_saved("mipmaps/generate"), _saved("compress/mode"), typeof(_saved("compress/mode"))], [true, 2, TYPE_INT], "saved with the types the file had")
	equal(reply["data"]["previous"], {"mipmaps/generate": false, "compress/mode": 0}, "what to pass back to undo it")
	equal(_context.reimported, [SOURCE], "the editor imports the file again")


func test_import_settings_set_dry_run_changes_nothing() -> void:
	_setup()

	var reply := _call("import_settings_set", {"path": SOURCE, "params": {"mipmaps/generate": true}}, {"dry_run": true})

	check(reply["ok"], "planned: %s" % reply)
	equal([_saved("mipmaps/generate"), _context.reimported], [false, []], "nothing written or imported")


func test_import_settings_set_refuses_what_it_should_not_change() -> void:
	_setup()

	var cases := {
		"an option the importer does not have": [{"path": SOURCE, "params": {"filter": true}}, "INVALID_ARGS"],
		"a script run on import": [{"path": SOURCE, "params": {"import_script/path": "res://evil.gd"}}, "PATH_NOT_ALLOWED"],
		"sub-resources": [{"path": SOURCE, "params": {"_subresources": {}}}, "PATH_NOT_ALLOWED"],
		"a file read during import": [{"path": SOURCE, "params": {"roughness/src_normal": "C:/secret.png"}}, "PATH_NOT_ALLOWED"],
		"a class whose script would load": [{"path": SOURCE, "params": {"nodes/root_type": "MyToolNode"}}, "PATH_NOT_ALLOWED"],
		"a list that can hold paths": [{"path": SOURCE, "params": {"fonts/fallbacks": ["res://a.ttf"]}}, "PATH_NOT_ALLOWED"],
		"a value of the wrong type": [{"path": SOURCE, "params": {"process/size_limit": "big"}}, "TYPE_MISMATCH"],
		"no options": [{"path": SOURCE, "params": {}}, "INVALID_ARGS"],
		"the .import itself": [{"path": SOURCE + ".import", "params": {"mipmaps/generate": true}}, "INVALID_ARGS"],
		"the bridge's own files": [{"path": "res://addons/gdcli/icon.png", "params": {"mipmaps/generate": true}}, "PATH_NOT_ALLOWED"],
		"a file outside the project": [{"path": "user://hero.png", "params": {"mipmaps/generate": true}}, "PATH_NOT_ALLOWED"],
	}
	for name in cases:
		equal(_code("import_settings_set", cases[name][0]), cases[name][1], name)
	equal([_saved("mipmaps/generate"), _context.reimported], [false, []], "nothing was changed")


func test_import_settings_set_waits_while_the_editor_imports() -> void:
	_setup()
	_context.scanning = true

	equal(_code("import_settings_set", {"path": SOURCE, "params": {"mipmaps/generate": true}}), "EDITOR_BUSY", "retry later")


func test_import_settings_need_an_imported_file() -> void:
	_setup("")

	equal(_code("import_settings_get", {"path": SOURCE}), "PRECONDITION_FAILED", "a file without a .import")
	equal(_code("import_settings_get", {"path": FOLDER + "/missing.png"}), "RESOURCE_NOT_FOUND", "no file at all")
