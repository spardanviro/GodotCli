extends RefCounted
## Animations of an AnimationPlayer in the edited scene: listing them, and
## building one from keyframes. Without this, an animation can only be made by
## running code in the editor.

const AccessPolicy = preload("../core/access_policy.gd")
const AssetFile = preload("../core/asset_file.gd")
const Edit = preload("../core/edit.gd")
const NodeRef = preload("../core/node_ref.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")
const ValueDecoder = preload("../core/value_decoder.gd")

const MAX_TRACKS := 64
const MAX_KEYS := 2000
const MAX_LENGTH_SECONDS := 3600.0
const _LOOP_MODES := {"none": Animation.LOOP_NONE, "linear": Animation.LOOP_LINEAR, "pingpong": Animation.LOOP_PINGPONG}
const _INTERPOLATIONS := {
	"nearest": Animation.INTERPOLATION_NEAREST, "linear": Animation.INTERPOLATION_LINEAR, "cubic": Animation.INTERPOLATION_CUBIC,
}
const _UPDATE_MODES := {"continuous": Animation.UPDATE_CONTINUOUS, "discrete": Animation.UPDATE_DISCRETE}
# Values that cannot be blended; they change at the keyframe.
const _STEPPED_TYPES: Array[int] = [TYPE_BOOL, TYPE_INT, TYPE_STRING, TYPE_STRING_NAME, TYPE_OBJECT, TYPE_NODE_PATH]
const _STRUCTURAL_USAGE := PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP
const _NAME_PATTERN := "^[^/:,\\[\\]]+\\z"
const _METHOD_PATTERN := "^[A-Za-z_][A-Za-z0-9_]*\\z"
# Methods that run something else than themselves.
const _INDIRECT_METHODS: Array[String] = [
	"call", "callv", "call_deferred", "call_thread_safe", "call_deferred_thread_group", "call_thread_group", "propagate_call", "propagate_notification",
	"set", "set_deferred", "set_indexed", "set_thread_safe", "set_script", "set_meta",
	"connect", "emit_signal", "add_user_signal", "rpc", "rpc_id", "rpc_config", "notification",
]

var _context: RefCounted
var _name_regex := RegEx.create_from_string(_NAME_PATTERN)
var _method_regex := RegEx.create_from_string(_METHOD_PATTERN)


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "animation_list",
		"summary": "Animations of an AnimationPlayer in the edited scene.",
		"risk": AccessPolicy.RISK_READ,
		"requires": ["scene_open"],
		"params": {"type": "object", "properties": {"player": {"type": "string", "description": "Path of the AnimationPlayer node."}}, "required": ["player"]},
		"returns": "{player, autoplay, animations: [{name, library, length, loop, tracks: [path]}]}",
	}, _list)
	registry.register({
		"name": "animation_create",
		"summary": "Create an animation on an AnimationPlayer from property keyframes, method calls and sounds.",
		"risk": AccessPolicy.RISK_WRITE,
		"undoable": true,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"player": {"type": "string", "description": "Path of the AnimationPlayer node."},
				"name": {"type": "string"},
				"library": {"type": "string", "default": "", "description": "Animation library; the default one has an empty name."},
				"length": {"type": "number", "minimum": 0.001, "maximum": MAX_LENGTH_SECONDS, "description": "Seconds."},
				"loop": {"type": "string", "enum": _LOOP_MODES.keys(), "default": "none"},
				"tracks": {
					"type": "array",
					"description": "Each: {node: path in the scene, property: name, keys: [{time: seconds, value}], interpolation?: nearest|linear|cubic, update?: continuous|discrete}; values are converted to the property's type. Or, to call a method at given times: {node, method: name, keys: [{time, args?: [values]}]}. Or, to play sounds on an AudioStreamPlayer: {node, audio: true, keys: [{time, stream: res:// sound file, start_offset?: seconds, end_offset?: seconds}]}.",
					"items": {"type": "object"},
				},
				"overwrite": {"type": "boolean", "default": false},
				"autoplay": {"type": "boolean", "default": false, "description": "Play this animation when the scene starts."},
			},
			"required": ["player", "name", "length", "tracks"],
		},
		"returns": "{player, name, library, length, tracks}; meta.undo names the undo step.",
	}, _create)


func _root() -> Node:
	return _context.scene_root()


# The AnimationPlayer, or a failed reply.
func _player(path: String) -> Variant:
	var node := NodeRef.resolve(_root(), path)
	if node == null:
		return Reply.fail("NODE_NOT_FOUND", "The node does not exist.", "Use scene_tree to see the node paths.", {"path": TextSanitizer.clean_line(path)})
	if not node is AnimationPlayer:
		return Reply.fail(
			"TYPE_MISMATCH", "The node is not an AnimationPlayer.", "Create one with node_create.",
			{"path": TextSanitizer.clean_line(path), "class": node.get_class()},
		)
	return node


func _list(args: Dictionary) -> Dictionary:
	var player: Variant = _player(args["player"])
	if player is Dictionary:
		return player
	var animations := []
	for library_name in player.get_animation_library_list():
		var library: AnimationLibrary = player.get_animation_library(library_name)
		for animation_name in library.get_animation_list():
			var animation: Animation = library.get_animation(animation_name)
			var tracks := []
			for index in animation.get_track_count():
				tracks.append(TextSanitizer.clean_line(str(animation.track_get_path(index))))
			animations.append({
				"name": TextSanitizer.clean_line(str(animation_name)),
				"library": TextSanitizer.clean_line(str(library_name)),
				"length": animation.length,
				"loop": _LOOP_MODES.find_key(animation.loop_mode),
				"tracks": tracks,
			})
	return Reply.ok({
		"player": TextSanitizer.clean_line(NodeRef.path_of(_root(), player)),
		"autoplay": TextSanitizer.clean_line(str(player.autoplay)),
		"animations": animations,
	})


func _create(args: Dictionary, options: Dictionary) -> Dictionary:
	var player: Variant = _player(args["player"])
	if player is Dictionary:
		return player
	var name: String = args["name"]
	var library_name: String = args["library"]
	if _name_regex.search(name) == null or (library_name != "" and _name_regex.search(library_name) == null):
		return Reply.fail("INVALID_ARGS", "Animation and library names cannot be empty or contain / : , [ ].")
	var tracks: Array = args["tracks"]
	if tracks.is_empty() or tracks.size() > MAX_TRACKS:
		return Reply.fail("INVALID_ARGS", "Give between 1 and %d tracks." % MAX_TRACKS)
	var library: AnimationLibrary = player.get_animation_library(library_name) if player.has_animation_library(library_name) else null
	var previous: Animation = library.get_animation(name) if library != null and library.has_animation(name) else null
	if previous != null and not args["overwrite"]:
		return Reply.fail("ALREADY_EXISTS", "The player already has an animation with this name.", "Pass overwrite to replace it.", {"name": name})

	var animation := Animation.new()
	animation.length = args["length"]
	animation.loop_mode = _LOOP_MODES[args["loop"]]
	var described := []
	for index in tracks.size():
		var added := _add_track(animation, player, tracks[index])
		if not added["ok"]:
			added["error"]["details"] = added["error"].get("details", {})
			added["error"]["details"]["track"] = index
			return added
		described.append(added["path"])
	if options["dry_run"]:
		return Edit.planned({"create_animation": name, "on": args["player"], "tracks": described, "replaces": previous != null})

	var action := Edit.undo_name("animation_create", name)
	_commit(action, player, library, library_name, name, animation, previous, args["autoplay"])
	return Edit.done({
		"player": TextSanitizer.clean_line(NodeRef.path_of(_root(), player)),
		"name": name, "library": library_name, "length": animation.length, "tracks": described,
	}, action)


func _commit(action: String, player: AnimationPlayer, library: AnimationLibrary, library_name: String, name: String, animation: Animation, previous: Animation, autoplay: bool) -> void:
	var undo: Object = _context.undo_redo()
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	var target := library
	if target == null:
		target = AnimationLibrary.new()
		undo.add_do_method(player, "add_animation_library", library_name, target)
	if previous != null:
		undo.add_do_method(target, "remove_animation", name)
	undo.add_do_method(target, "add_animation", name, animation)
	undo.add_undo_method(target, "remove_animation", name)
	if previous != null:
		undo.add_undo_method(target, "add_animation", name, previous)
	if library == null:
		undo.add_undo_method(player, "remove_animation_library", library_name)
	if autoplay:
		var full_name := name if library_name == "" else "%s/%s" % [library_name, name]
		undo.add_do_property(player, "autoplay", full_name)
		undo.add_undo_property(player, "autoplay", player.autoplay)
	undo.commit_action()


# Adds one track. Returns {ok, path} or a failed reply.
func _add_track(animation: Animation, player: AnimationPlayer, track: Variant) -> Dictionary:
	var kinds := 0
	if track is Dictionary:
		kinds = int(track.get("property") is String) + int(track.get("method") is String) + int(track.get("audio") == true)
	if not (kinds == 1 and track.get("node") is String and track.get("keys") is Array):
		return Reply.fail("INVALID_ARGS", "A track needs node, keys, and one of property, method or audio: true.")
	var target := NodeRef.resolve(_root(), track["node"])
	if target == null:
		return Reply.fail("NODE_NOT_FOUND", "The animated node does not exist.", "", {"path": TextSanitizer.clean_line(track["node"])})
	if track.get("method") is String:
		return _add_method_track(animation, player, target, track)
	if track.get("audio") == true:
		return _add_audio_track(animation, player, target, track)
	var info := _property_info(target, track["property"])
	if info.is_empty():
		return Reply.fail(
			"INVALID_ARGS", "The node has no such property.", "node_get lists the properties of a node.",
			{"property": TextSanitizer.clean_line(track["property"]), "class": target.get_class()},
		)
	var keys: Array = track["keys"]
	if keys.is_empty() or keys.size() > MAX_KEYS:
		return Reply.fail("INVALID_ARGS", "A track needs between 1 and %d keys." % MAX_KEYS)
	var interpolation: Variant = track.get("interpolation", "linear")
	var default_update := "discrete" if info["type"] in _STEPPED_TYPES else "continuous"
	var update: Variant = track.get("update", default_update)
	if not _INTERPOLATIONS.has(interpolation) or not _UPDATE_MODES.has(update):
		return Reply.fail("INVALID_ARGS", "interpolation is nearest, linear or cubic; update is continuous or discrete.")

	# Track paths are relative to the node the player animates from.
	var base: Node = player.get_node_or_null(player.root_node)
	if base == null or not (base == _root() or _root().is_ancestor_of(base)):
		return Reply.fail(
			"PRECONDITION_FAILED", "The player's root_node does not point to a node of this scene.",
			"An AnimationPlayer that is the scene root needs root_node set to \".\" (node_set).",
		)
	var path := "%s:%s" % [base.get_path_to(target), track["property"]]
	var index := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(index, NodePath(path))
	animation.track_set_interpolation_type(index, _INTERPOLATIONS[interpolation])
	animation.value_track_set_update_mode(index, _UPDATE_MODES[update])
	var decoder := ValueDecoder.new(_root())
	for key in keys:
		if not (key is Dictionary and (key.get("time") is float or key.get("time") is int) and key.has("value")):
			return Reply.fail("INVALID_ARGS", "A key needs time and value.")
		if key["time"] < 0.0 or key["time"] > animation.length:
			return Reply.fail("INVALID_ARGS", "A key lies outside the length of the animation.", "", {"time": key["time"]})
		var decoded: Dictionary = decoder.decode(key["value"], info["type"], info)
		if not decoded["ok"]:
			return decoded
		if decoded["value"] is Node:
			return Reply.fail("INVALID_ARGS", "A node cannot be a keyframe value.", "Animate a NodePath property with the path as text.")
		animation.track_insert_key(index, key["time"], decoded["value"])
	return {"ok": true, "path": TextSanitizer.clean_line(path)}


# The node the player's track paths start from, or null when it is not in this scene.
func _base_of(player: AnimationPlayer) -> Node:
	var base: Node = player.get_node_or_null(player.root_node)
	return base if base != null and (base == _root() or _root().is_ancestor_of(base)) else null


# A track that calls a method of `target` at its keys.
func _add_method_track(animation: Animation, player: AnimationPlayer, target: Node, track: Dictionary) -> Dictionary:
	var method: String = track["method"]
	# The method need not exist yet: the script may be attached later. The
	# ones that do something other than what their name says are left out.
	if method in _INDIRECT_METHODS or _method_regex.search(method) == null:
		return Reply.fail("INVALID_ARGS", "This method cannot be called from a track.", "Call a method of the node's own script.", {"method": TextSanitizer.clean_line(method)})
	var keys: Array = track["keys"]
	if keys.is_empty() or keys.size() > MAX_KEYS:
		return Reply.fail("INVALID_ARGS", "A track needs between 1 and %d keys." % MAX_KEYS)
	var base := _base_of(player)
	if base == null:
		return Reply.fail(
			"PRECONDITION_FAILED", "The player's root_node does not point to a node of this scene.",
			"An AnimationPlayer that is the scene root needs root_node set to \".\" (node_set).",
		)
	var path := str(base.get_path_to(target))
	var index := animation.add_track(Animation.TYPE_METHOD)
	animation.track_set_path(index, NodePath(path))
	var decoder := ValueDecoder.new(_root())
	for key in keys:
		if not (key is Dictionary and (key.get("time") is float or key.get("time") is int) and key.get("args", []) is Array):
			return Reply.fail("INVALID_ARGS", "A key of a method track needs time, and args as a list when the method takes any.")
		if key["time"] < 0.0 or key["time"] > animation.length:
			return Reply.fail("INVALID_ARGS", "A key lies outside the length of the animation.", "", {"time": key["time"]})
		var decoded: Dictionary = decoder.decode(key.get("args", []), TYPE_ARRAY)
		if not decoded["ok"]:
			return decoded
		animation.track_insert_key(index, key["time"], {"method": StringName(method), "args": decoded["value"]})
	return {"ok": true, "path": TextSanitizer.clean_line("%s:%s()" % [path, method])}


# A track that plays sounds on `target`, an audio player.
func _add_audio_track(animation: Animation, player: AnimationPlayer, target: Node, track: Dictionary) -> Dictionary:
	if not (target is AudioStreamPlayer or target is AudioStreamPlayer2D or target is AudioStreamPlayer3D):
		return Reply.fail(
			"TYPE_MISMATCH", "An audio track plays on an AudioStreamPlayer, AudioStreamPlayer2D or AudioStreamPlayer3D.", "Create one with node_create.",
			{"path": TextSanitizer.clean_line(track["node"]), "class": target.get_class()},
		)
	var keys: Array = track["keys"]
	if keys.is_empty() or keys.size() > MAX_KEYS:
		return Reply.fail("INVALID_ARGS", "A track needs between 1 and %d keys." % MAX_KEYS)
	var base := _base_of(player)
	if base == null:
		return Reply.fail(
			"PRECONDITION_FAILED", "The player's root_node does not point to a node of this scene.",
			"An AnimationPlayer that is the scene root needs root_node set to \".\" (node_set).",
		)
	var path := str(base.get_path_to(target))
	var index := animation.add_track(Animation.TYPE_AUDIO)
	animation.track_set_path(index, NodePath(path))
	for key in keys:
		var offsets_ok: bool = key is Dictionary and _is_offset(key.get("start_offset", 0.0)) and _is_offset(key.get("end_offset", 0.0))
		if not (offsets_ok and (key.get("time") is float or key.get("time") is int)):
			return Reply.fail("INVALID_ARGS", "A key of an audio track needs time and stream; start_offset and end_offset are seconds, 0 or more.")
		if key["time"] < 0.0 or key["time"] > animation.length:
			return Reply.fail("INVALID_ARGS", "A key lies outside the length of the animation.", "", {"time": key["time"]})
		var stream: Variant = AssetFile.load_sound(key.get("stream"))
		if stream is Dictionary:
			return stream
		animation.audio_track_insert_key(index, key["time"], stream, key.get("start_offset", 0.0), key.get("end_offset", 0.0))
	return {"ok": true, "path": TextSanitizer.clean_line("%s (audio)" % path)}


static func _is_offset(value: Variant) -> bool:
	return (value is float or value is int) and value >= 0.0


func _property_info(target: Node, property: String) -> Dictionary:
	for info in target.get_property_list():
		if info["name"] == property and not info["usage"] & _STRUCTURAL_USAGE and property != "script":
			return info
	return {}
