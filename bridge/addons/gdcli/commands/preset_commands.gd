extends RefCounted
## Ready-made effects: a 2D particle effect, a short animation of a node, a
## following camera. Each is made with node_create or animation_create, so it
## is one undo step and goes through the same checks; a preset only saves
## working out a dozen values that look right together.

const AccessPolicy = preload("../core/access_policy.gd")
const NodeRef = preload("../core/node_ref.gd")
const Reply = preload("../core/reply.gd")
const Schema = preload("../core/schema.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")

const NAME := "preset_create"
const _EMISSION_SHAPE_BOX := 3

# A particle effect: the node's own properties, then its process material's.
# Colours fade along the particle's life (a gradient from first to last).
const _PARTICLES := {
	"explosion": {
		"node": {"amount": 48, "lifetime": 0.6, "one_shot": true, "explosiveness": 1.0},
		"material": {"spread": 180.0, "initial_velocity_min": 150.0, "initial_velocity_max": 300.0, "gravity": [0, 98, 0], "damping_min": 80.0, "damping_max": 120.0, "scale_min": 3.0, "scale_max": 6.0},
		"colors": ["#fff6a0", "#ff9a2e", "#c0302000"],
	},
	"fire": {
		"node": {"amount": 64, "lifetime": 0.8},
		"material": {"direction": [0, -1, 0], "spread": 15.0, "initial_velocity_min": 40.0, "initial_velocity_max": 80.0, "gravity": [0, -60, 0], "scale_min": 4.0, "scale_max": 8.0},
		"colors": ["#ffe066", "#ff5a1f", "#40100000"],
	},
	"smoke": {
		"node": {"amount": 24, "lifetime": 2.0},
		"material": {"direction": [0, -1, 0], "spread": 25.0, "initial_velocity_min": 15.0, "initial_velocity_max": 30.0, "gravity": [0, -20, 0], "scale_min": 8.0, "scale_max": 16.0},
		"colors": ["#80808099", "#60606066", "#40404000"],
	},
	"sparks": {
		"node": {"amount": 32, "lifetime": 0.4, "one_shot": true, "explosiveness": 0.9},
		"material": {"direction": [0, -1, 0], "spread": 60.0, "initial_velocity_min": 200.0, "initial_velocity_max": 350.0, "gravity": [0, 400, 0], "scale_min": 1.0, "scale_max": 2.0},
		"colors": ["#ffffff", "#ffb347", "#ff660000"],
	},
	"rain": {
		"node": {"amount": 200, "lifetime": 1.0},
		"material": {"direction": [0, 1, 0], "spread": 3.0, "initial_velocity_min": 500.0, "initial_velocity_max": 600.0, "emission_shape": _EMISSION_SHAPE_BOX, "emission_box_extents": [400, 1, 1], "scale_min": 1.0, "scale_max": 2.0},
		"colors": ["#a8c8ff99", "#a8c8ff99"],
	},
	"dust": {
		"node": {"amount": 12, "lifetime": 0.5, "one_shot": true, "explosiveness": 0.8},
		"material": {"direction": [0, -1, 0], "spread": 70.0, "initial_velocity_min": 30.0, "initial_velocity_max": 60.0, "gravity": [0, 50, 0], "scale_min": 2.0, "scale_max": 4.0},
		"colors": ["#d8c8a8cc", "#d8c8a800"],
	},
}
const _ANIMATIONS: Array[String] = ["fade_in", "fade_out", "pulse", "shake", "bob", "blink"]
const _CAMERAS: Array[String] = ["camera_follow"]

var _context: RefCounted
var _registry: RefCounted


func _init(context: RefCounted, registry: RefCounted) -> void:
	_context = context
	_registry = registry


func register(registry: RefCounted) -> void:
	registry.register({
		"name": NAME,
		"summary": "Add a ready-made effect: 2D particles (explosion, fire, smoke, sparks, rain, dust), a short animation of a node (fade_in, fade_out, pulse, shake, bob, blink), or a camera that follows a node (camera_follow).",
		"risk": AccessPolicy.RISK_WRITE,
		"undoable": true,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"preset": {"type": "string", "enum": _PARTICLES.keys() + _ANIMATIONS + _CAMERAS},
				"target": {"type": "string", "description": "Particles and camera: the parent node. Animations: the Node2D or Control to animate."},
				"player": {"type": "string", "description": "Animations: the AnimationPlayer that gets the animation."},
				"name": {"type": "string", "description": "Name of the new node or animation; defaults to the preset's."},
				"color": {"type": "string", "description": "Particles: tint the effect, e.g. #66ccff."},
			},
			"required": ["preset", "target"],
		},
		"returns": "What node_create or animation_create returns; meta.undo names the undo step. One-shot particles (explosion, sparks, dust) play when emitting is set to true, e.g. from a script: $Explosion.restart(). shake and bob move a Sprite2D or AnimatedSprite2D by its offset, so the node can be moved later; on other nodes they key the position it has now.",
	}, _create)


func _create(args: Dictionary, options: Dictionary) -> Dictionary:
	var preset: String = args["preset"]
	if _PARTICLES.has(preset):
		return _particles(preset, args, options)
	if preset in _ANIMATIONS:
		return _animation(preset, args, options)
	return _camera(args, options)


# Through the command's own schema, so its defaults are filled in as for any request.
func _call(command: String, args: Dictionary, options: Dictionary) -> Dictionary:
	var validated := Schema.validate(args, _registry.descriptor_of(command)["params"])
	if not validated["ok"]:
		return validated
	return _registry.handler_of(command).call(validated["args"], options)


func _particles(preset: String, args: Dictionary, options: Dictionary) -> Dictionary:
	var spec: Dictionary = _PARTICLES[preset]
	var colors: Array = spec["colors"].duplicate()
	if args.has("color"):
		if not Color.html_is_valid(str(args["color"])):
			return Reply.fail("INVALID_ARGS", "color is #rrggbb or #rrggbbaa.")
		var tint := Color.html(str(args["color"]))
		for index in colors.size():
			var base := Color.html(colors[index])
			colors[index] = Color(tint.r, tint.g, tint.b, base.a).to_html(true)
	var offsets := []
	for index in colors.size():
		offsets.append(float(index) / max(1, colors.size() - 1))
	var material: Dictionary = spec["material"].duplicate()
	material["color_ramp"] = {"$new": "GradientTexture1D", "properties": {"gradient": {"$new": "Gradient", "properties": {"offsets": offsets, "colors": colors}}}}
	var properties: Dictionary = spec["node"].duplicate()
	properties["process_material"] = {"$new": "ParticleProcessMaterial", "properties": material}
	if properties.get("one_shot", false):
		# Made ready, not fired: the game starts it when the effect should happen.
		properties["emitting"] = false
	return _call("node_create", {"type": "GPUParticles2D", "parent": args["target"], "name": args.get("name", preset.capitalize().replace(" ", "")), "properties": properties}, options)


func _animation(preset: String, args: Dictionary, options: Dictionary) -> Dictionary:
	if not args.get("player") is String:
		return Reply.fail("INVALID_ARGS", "An animation preset needs player: the AnimationPlayer that gets it.", "Create one with node_create --type AnimationPlayer.")
	var root: Node = _context.scene_root()
	var target := NodeRef.resolve(root, args["target"])
	if target == null:
		return Reply.fail("NODE_NOT_FOUND", "The node does not exist.", "Use scene_tree to see the node paths.", {"path": TextSanitizer.clean_line(args["target"])})
	if not (target is Node2D or target is Control):
		return Reply.fail("TYPE_MISMATCH", "Animation presets move, scale or fade a Node2D or a Control.", "", {"class": target.get_class()})
	var node := TextSanitizer.clean_line(args["target"])
	var color: Color = target.modulate
	# A sprite moves by its offset, which is relative to where the node is:
	# the node can be moved later and the animation still plays around it.
	var moved := "offset" if (target is Sprite2D or target is AnimatedSprite2D) else "position"
	var position: Vector2 = target.get(moved)
	var scale: Vector2 = target.scale
	var hidden := Color(color.r, color.g, color.b, 0.0)
	var shown := Color(color.r, color.g, color.b, color.a if color.a > 0.0 else 1.0)
	var plan := {}
	match preset:
		"fade_in":
			plan = {"length": 0.5, "loop": "none", "tracks": [_track(node, "modulate", [[0.0, hidden], [0.5, shown]])]}
		"fade_out":
			plan = {"length": 0.5, "loop": "none", "tracks": [_track(node, "modulate", [[0.0, shown], [0.5, hidden]])]}
		"pulse":
			plan = {"length": 0.6, "loop": "linear", "tracks": [_track(node, "scale", [[0.0, scale], [0.3, scale * 1.15], [0.6, scale]], "cubic")]}
		"shake":
			plan = {"length": 0.3, "loop": "none", "tracks": [_track(node, moved, [[0.0, position], [0.06, position + Vector2(6, 0)], [0.12, position - Vector2(6, 0)], [0.18, position + Vector2(0, 4)], [0.24, position - Vector2(3, 0)], [0.3, position]])]}
		"bob":
			plan = {"length": 1.2, "loop": "linear", "tracks": [_track(node, moved, [[0.0, position], [0.6, position - Vector2(0, 8)], [1.2, position]], "cubic")]}
		"blink":
			var dim := Color(color.r, color.g, color.b, color.a * 0.2)
			plan = {"length": 0.4, "loop": "none", "tracks": [_track(node, "modulate", [[0.0, color], [0.1, dim], [0.2, color], [0.3, dim], [0.4, color]], "nearest")]}
	var create := {"player": args["player"], "name": args.get("name", preset), "length": plan["length"], "loop": plan["loop"], "tracks": plan["tracks"]}
	var reply := _call("animation_create", create, options)
	if reply.get("ok", false) and not reply.has("later") and moved == "position" and preset in ["shake", "bob"]:
		reply["warnings"] = reply.get("warnings", []) + ["The animation moves the node's position from where it is now: if the node is placed elsewhere later, make the preset again, or put it on a child that does not move (a Sprite2D child animates its offset instead)."]
	return reply


func _track(node: String, property: String, keys: Array, interpolation: String = "linear") -> Dictionary:
	var encoded := []
	for key in keys:
		var value: Variant = key[1]
		if value is Color:
			value = value.to_html(true)
		elif value is Vector2:
			value = [value.x, value.y]
		encoded.append({"time": key[0], "value": value})
	return {"node": node, "property": property, "keys": encoded, "interpolation": interpolation}


func _camera(args: Dictionary, options: Dictionary) -> Dictionary:
	var properties := {"position_smoothing_enabled": true, "position_smoothing_speed": 6.0, "drag_horizontal_enabled": true, "drag_vertical_enabled": true, "drag_top_margin": 0.3, "drag_bottom_margin": 0.3}
	return _call("node_create", {"type": "Camera2D", "parent": args["target"], "name": args.get("name", "Camera2D"), "properties": properties}, options)
