extends RefCounted
## The per-instance discovery file (docs/protocol.md section 2).

const SCHEMA := 1
const HOME_ENV := "GDCLI_HOME"
const HOME_DIR_NAME := ".gdcli"
const INSTANCES_DIR_NAME := "instances"
const OWNER_ONLY_FILE := 384  # 0600
const OWNER_ONLY_DIR := 448  # 0700
const _GROUP_AND_OTHER := 63  # 0077

var _path := ""


static func home_dir() -> String:
	var override := OS.get_environment(HOME_ENV)
	if override != "":
		return override
	var user_home := OS.get_environment("USERPROFILE" if OS.get_name() == "Windows" else "HOME")
	return "" if user_home == "" else user_home.path_join(HOME_DIR_NAME)


## Writes the file for this instance. The token only ever reaches a file whose
## permissions are already owner-only. Returns OK or an error.
func write(fields: Dictionary) -> Error:
	var home := home_dir()
	if home == "":
		return ERR_UNCONFIGURED
	var directory := home.path_join(INSTANCES_DIR_NAME)
	var made := DirAccess.make_dir_recursive_absolute(directory)
	if made != OK:
		return made
	if not _restrict(home, OWNER_ONLY_DIR) or not _restrict(directory, OWNER_ONLY_DIR):
		return ERR_FILE_NO_PERMISSION

	var final_path := directory.path_join("%s.json" % fields["instance_id"])
	var temp_path := final_path + ".tmp"
	# Create the file empty, tighten it, and only then put the token in it.
	# READ_WRITE is used for the second open because the editor's "safe save"
	# redirects WRITE to a different temporary file, which would not carry
	# the permissions set here.
	var created := FileAccess.open(temp_path, FileAccess.WRITE)
	if created == null:
		return FileAccess.get_open_error()
	created.close()
	if not _restrict(temp_path, OWNER_ONLY_FILE):
		DirAccess.remove_absolute(temp_path)
		return ERR_FILE_NO_PERMISSION

	var file := FileAccess.open(temp_path, FileAccess.READ_WRITE)
	if file == null:
		DirAccess.remove_absolute(temp_path)
		return FileAccess.get_open_error()
	var content := fields.duplicate()
	content["schema"] = SCHEMA
	file.store_string(JSON.stringify(content, "  "))
	file.close()

	var renamed := DirAccess.rename_absolute(temp_path, final_path)
	if renamed != OK:
		DirAccess.remove_absolute(temp_path)
		return renamed
	_path = final_path
	return OK


func remove() -> void:
	if _path != "" and FileAccess.file_exists(_path):
		DirAccess.remove_absolute(_path)
	_path = ""


# Windows has no mode bits; the profile directory's access control applies.
static func _restrict(path: String, mode: int) -> bool:
	if OS.get_name() == "Windows":
		return true
	if FileAccess.set_unix_permissions(path, mode) != OK:
		return false
	return FileAccess.get_unix_permissions(path) & _GROUP_AND_OTHER == 0
