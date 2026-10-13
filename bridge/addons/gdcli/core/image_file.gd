extends RefCounted
## Loading an image of the project for a command that takes one.

const PathPolicy = preload("path_policy.gd")
const Reply = preload("reply.gd")

# Files the engine imports as textures. Anything else is not loaded to find
# out what it is: a resource file can name a script, and loading it would
# run that script in the editor.
const _EXTENSIONS: Array[String] = ["png", "jpg", "jpeg", "webp", "svg", "bmp", "tga", "exr", "hdr", "dds", "ktx", "ktx2"]


## The texture at `path`, or a failed reply.
static func load_texture(path: Variant) -> Variant:
	if not path is String:
		return Reply.fail("INVALID_ARGS", "An image is named by its res:// path.")
	var checked := PathPolicy.check(path, PathPolicy.ACCESS_READ)
	if not checked["ok"]:
		return checked
	if not checked["path"].get_extension().to_lower() in _EXTENSIONS:
		return Reply.fail(
			"INVALID_ARGS", "Not an image file.", "Give the image itself (png, jpg, webp, svg, ...), not a resource made from it.",
			{"path": checked["path"]},
		)
	if not ResourceLoader.exists(checked["path"]):
		return Reply.fail("RESOURCE_NOT_FOUND", "There is no image at this path.", "fs_list shows the files; a new file needs fs_scan first.", {"path": checked["path"]})
	var texture := ResourceLoader.load(checked["path"]) as Texture2D
	if texture == null:
		return Reply.fail("TYPE_MISMATCH", "The engine has not imported this file as an image.", "", {"path": checked["path"]})
	return texture
