extends RefCounted
## Frame animations of an AnimatedSprite2D or AnimatedSprite3D, built from
## sprite sheets or from single images.

const AccessPolicy = preload("../core/access_policy.gd")
const Edit = preload("../core/edit.gd")
const NodeRef = preload("../core/node_ref.gd")
const AssetFile = preload("../core/asset_file.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")

const MAX_ANIMATIONS := 64
const MAX_FRAMES := 2048
const MAX_SHEET_DIVISIONS := 256
const MAX_FPS := 240.0
const _DEFAULT_ANIMATION := &"default"
const _NAME_PATTERN := "^[^/:,\\[\\]]+\\z"

var _context: RefCounted
var _name_regex := RegEx.create_from_string(_NAME_PATTERN)


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "sprite_frames_create",
		"group": "sprite",
		"summary": "Give an AnimatedSprite2D or AnimatedSprite3D frame animations cut from sprite sheets or made of single images.",
		"risk": AccessPolicy.RISK_WRITE,
		"undoable": true,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"node": {"type": "string", "description": "Path of the AnimatedSprite2D or AnimatedSprite3D node."},
				"animations": {
					"type": "array",
					"items": {"type": "object"},
					"description": "Each: {name, sheet: res:// image, hframes?: columns, vframes?: rows, frames?: [indices, counted row by row from 0; default all]} or {name, files: [res:// images]}; plus fps?: number (default 10) and loop?: boolean (default true). An animation of the same name is replaced.",
				},
				"replace": {"type": "boolean", "default": false, "description": "Drop the animations the node already has instead of adding to them."},
				"autoplay": {"type": "string", "default": "", "description": "Animation to play when the scene starts."},
			},
			"required": ["node", "animations"],
		},
		"returns": "{node, animations: [{name, frames, fps, loop}]} for all animations the node has afterwards; meta.undo names the undo step.",
	}, _create)


func _root() -> Node:
	return _context.scene_root()


func _create(args: Dictionary, options: Dictionary) -> Dictionary:
	var node := NodeRef.resolve(_root(), args["node"])
	if node == null:
		return Reply.fail("NODE_NOT_FOUND", "The node does not exist.", "Use scene_tree to see the node paths.", {"path": TextSanitizer.clean_line(args["node"])})
	if not (node is AnimatedSprite2D or node is AnimatedSprite3D):
		return Reply.fail(
			"TYPE_MISMATCH", "The node is not an AnimatedSprite2D or AnimatedSprite3D.", "Create one with node_create.",
			{"path": TextSanitizer.clean_line(args["node"]), "class": node.get_class()},
		)
	var wanted: Array = args["animations"]
	if wanted.is_empty() or wanted.size() > MAX_ANIMATIONS:
		return Reply.fail("INVALID_ARGS", "Give between 1 and %d animations." % MAX_ANIMATIONS)

	var previous: SpriteFrames = node.sprite_frames
	var frames: SpriteFrames = previous.duplicate() if previous != null and not args["replace"] else SpriteFrames.new()
	var first := ""
	for index in wanted.size():
		var added := _add_animation(frames, wanted[index])
		if not added["ok"]:
			added["error"]["details"] = added["error"].get("details", {})
			added["error"]["details"]["animation"] = index
			return added
		if first == "":
			first = added["name"]
	# A new SpriteFrames comes with an empty animation called "default".
	if frames.has_animation(_DEFAULT_ANIMATION) and frames.get_frame_count(_DEFAULT_ANIMATION) == 0 and frames.get_animation_names().size() > 1:
		frames.remove_animation(_DEFAULT_ANIMATION)
	var autoplay: String = args["autoplay"]
	if autoplay != "" and not frames.has_animation(autoplay):
		return Reply.fail("INVALID_ARGS", "autoplay names an animation the node will not have.", "", {"autoplay": TextSanitizer.clean_line(autoplay)})
	if options["dry_run"]:
		return Edit.planned({"animations": _describe(frames), "on": args["node"], "replaces_all": args["replace"]})

	var action := Edit.undo_name("sprite_frames_create", str(node.name))
	var undo: Object = _context.undo_redo()
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	undo.add_do_property(node, "sprite_frames", frames)
	undo.add_undo_property(node, "sprite_frames", previous)
	# What the editor shows, and what plays first.
	undo.add_do_property(node, "animation", StringName(autoplay if autoplay != "" else first))
	# Without frames there is no animation to go back to.
	if previous != null:
		undo.add_undo_property(node, "animation", node.animation)
	# An autoplay left pointing at an animation that is gone would be an error at the start of the game.
	if autoplay != "" or not frames.has_animation(node.autoplay):
		undo.add_do_property(node, "autoplay", autoplay)
		undo.add_undo_property(node, "autoplay", node.autoplay)
	undo.commit_action()
	return Edit.done({"node": TextSanitizer.clean_line(NodeRef.path_of(_root(), node)), "animations": _describe(frames)}, action)


func _describe(frames: SpriteFrames) -> Array:
	var described := []
	for name in frames.get_animation_names():
		described.append({
			"name": TextSanitizer.clean_line(str(name)), "frames": frames.get_frame_count(name),
			"fps": frames.get_animation_speed(name), "loop": frames.get_animation_loop(name),
		})
	return described


# Adds one animation to `frames`. Returns {ok, name} or a failed reply.
func _add_animation(frames: SpriteFrames, spec: Variant) -> Dictionary:
	if not (spec is Dictionary and spec.get("name") is String and _name_regex.search(spec["name"]) != null):
		return Reply.fail("INVALID_ARGS", "An animation needs a name, without / : , [ ].")
	var fps: Variant = spec.get("fps", 10.0)
	var loop: Variant = spec.get("loop", true)
	if not ((fps is float or fps is int) and fps > 0.0 and fps <= MAX_FPS and loop is bool):
		return Reply.fail("INVALID_ARGS", "fps is a number above 0 and up to %d; loop is true or false." % int(MAX_FPS))
	var textures: Variant
	if spec.get("sheet") is String:
		textures = _cut_sheet(spec)
	elif spec.get("files") is Array:
		textures = _load_files(spec["files"])
	else:
		return Reply.fail("INVALID_ARGS", "An animation needs sheet (one image cut into frames) or files (one image per frame).")
	if textures is Dictionary:
		return textures

	var name := StringName(spec["name"])
	if frames.has_animation(name):
		frames.remove_animation(name)
	frames.add_animation(name)
	frames.set_animation_speed(name, fps)
	frames.set_animation_loop(name, loop)
	for texture in textures:
		frames.add_frame(name, texture)
	if _total_frames(frames) > MAX_FRAMES:
		return Reply.fail("INVALID_ARGS", "More than %d frames in all." % MAX_FRAMES)
	return {"ok": true, "name": spec["name"]}


func _total_frames(frames: SpriteFrames) -> int:
	var total := 0
	for name in frames.get_animation_names():
		total += frames.get_frame_count(name)
	return total


# The frames of a sheet as AtlasTextures, or a failed reply.
func _cut_sheet(spec: Dictionary) -> Variant:
	var sheet: Variant = AssetFile.load_texture(spec["sheet"])
	if sheet is Dictionary:
		return sheet
	var columns: Variant = spec.get("hframes", 1)
	var rows: Variant = spec.get("vframes", 1)
	if not (_is_whole(columns) and _is_whole(rows) and columns >= 1 and rows >= 1 and columns <= MAX_SHEET_DIVISIONS and rows <= MAX_SHEET_DIVISIONS):
		return Reply.fail("INVALID_ARGS", "hframes and vframes are whole numbers from 1 to %d." % MAX_SHEET_DIVISIONS)
	var count := int(columns) * int(rows)
	var picked: Variant = spec.get("frames", range(count))
	if not picked is Array or picked.is_empty():
		return Reply.fail("INVALID_ARGS", "frames is a list of frame numbers.")
	var cell := Vector2(sheet.get_size()) / Vector2(columns, rows)
	var textures := []
	for index in picked:
		if not _is_whole(index) or index < 0 or index >= count:
			return Reply.fail("INVALID_ARGS", "A frame number lies outside the sheet.", "Frames are counted row by row from 0.", {"frame": index, "frames_in_sheet": count})
		var frame := AtlasTexture.new()
		frame.atlas = sheet
		frame.region = Rect2(Vector2(int(index) % int(columns), int(index) / int(columns)) * cell, cell)
		textures.append(frame)
	return textures


func _load_files(files: Array) -> Variant:
	if files.is_empty():
		return Reply.fail("INVALID_ARGS", "files is a list of image paths.")
	var textures := []
	for path in files:
		var texture: Variant = AssetFile.load_texture(path)
		if texture is Dictionary:
			return texture
		textures.append(texture)
	return textures


static func _is_whole(value: Variant) -> bool:
	return value is int or (value is float and value == floorf(value))
