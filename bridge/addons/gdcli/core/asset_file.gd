extends RefCounted
## Loading an image or a sound of the project for a command that takes one.

const PathPolicy = preload("path_policy.gd")
const Reply = preload("reply.gd")

# Files the engine imports as textures. Anything else is not loaded to find
# out what it is: a resource file can name a script, and loading it would
# run that script in the editor.
const _IMAGE_EXTENSIONS: Array[String] = ["png", "jpg", "jpeg", "webp", "svg", "bmp", "tga", "exr", "hdr", "dds", "ktx", "ktx2"]
const _SOUND_EXTENSIONS: Array[String] = ["wav", "ogg", "mp3"]


## The texture at `path`, or a failed reply.
static func load_texture(path: Variant) -> Variant:
	var loaded: Variant = _load(path, _IMAGE_EXTENSIONS, "an image", "png, jpg, webp, svg, ...")
	if loaded is Resource and not loaded is Texture2D:
		return Reply.fail("TYPE_MISMATCH", "The engine has not imported this file as an image.", "", {"path": loaded.resource_path})
	return loaded


## The audio stream at `path`, or a failed reply.
static func load_sound(path: Variant) -> Variant:
	var loaded: Variant = _load(path, _SOUND_EXTENSIONS, "a sound", "wav, ogg, mp3")
	if loaded is Resource and not loaded is AudioStream:
		return Reply.fail("TYPE_MISMATCH", "The engine has not imported this file as a sound.", "", {"path": loaded.resource_path})
	return loaded


static func _load(path: Variant, extensions: Array[String], what: String, examples: String) -> Variant:
	if not path is String:
		return Reply.fail("INVALID_ARGS", "A file is named by its res:// path.")
	var checked := PathPolicy.check(path, PathPolicy.ACCESS_READ)
	if not checked["ok"]:
		return checked
	if not checked["path"].get_extension().to_lower() in extensions:
		return Reply.fail(
			"INVALID_ARGS", "Not %s file." % what, "Give the file itself (%s), not a resource made from it." % examples,
			{"path": checked["path"]},
		)
	if not ResourceLoader.exists(checked["path"]):
		return Reply.fail("RESOURCE_NOT_FOUND", "There is no such file at this path.", "fs_list shows the files; a new file needs fs_scan first.", {"path": checked["path"]})
	var outside := PathPolicy.refuse_outside_dependency(checked["path"])
	if not outside.is_empty():
		return outside
	var resource := ResourceLoader.load(checked["path"])
	if resource == null:
		return Reply.fail("TYPE_MISMATCH", "The engine could not load this file.", "", {"path": checked["path"]})
	return resource
