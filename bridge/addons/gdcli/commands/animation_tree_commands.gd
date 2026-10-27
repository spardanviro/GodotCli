extends RefCounted
## A state machine for an AnimationTree: states that each play one animation
## of an AnimationPlayer, and the transitions between them.

const AccessPolicy = preload("../core/access_policy.gd")
const Edit = preload("../core/edit.gd")
const NodeRef = preload("../core/node_ref.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")

const MAX_STATES := 64
const MAX_TRANSITIONS := 512
const MAX_EXPRESSION_LENGTH := 500
const MAX_BLEND_POINTS := 64
const MAX_BLEND_POSITION := 1.0e6
# add_blend_point(node, position, at_index) before points had names.
const _UNNAMED_POINT_ARGUMENTS := 3
const _START := "Start"
const _INACTIVE := "The tree was left inactive because a transition has an expression: set active = true in _ready() of the game's script."
const _END := "End"
const _SWITCH_MODES := {
	"immediate": AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE,
	"sync": AnimationNodeStateMachineTransition.SWITCH_MODE_SYNC,
	"at_end": AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END,
}
const _NAME_PATTERN := "^[A-Za-z_][A-Za-z0-9_]*\\z"
# Where the states appear in the editor's graph.
const _GRAPH_ORIGIN := Vector2(240, 100)
const _GRAPH_STEP := Vector2(200, 0)

var _context: RefCounted
var _name_regex := RegEx.create_from_string(_NAME_PATTERN)


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "animation_state_machine_create",
		"group": "animation",
		"summary": "Give an AnimationTree a state machine: one state per animation, with transitions between them.",
		"risk": AccessPolicy.RISK_WRITE,
		"undoable": true,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"tree": {"type": "string", "description": "Path of the AnimationTree node."},
				"player": {"type": "string", "description": "Path of the AnimationPlayer whose animations are played. Default: the one the tree already points to."},
				"states": {"type": "array", "items": {"type": "object"}, "description": "Each: {name: letters, digits and _, animation: name in the player}."},
				"transitions": {
					"type": "array",
					"items": {"type": "object"},
					"description": "Each: {from, to} plus optional switch: immediate|sync|at_end (default immediate), auto: boolean (taken by itself, e.g. after at_end), xfade: seconds, condition: name of a boolean set from code, expression: text evaluated on the tree's parent. Without auto, condition or expression, a transition is taken by travel() from code. With an expression anywhere, the tree is left inactive (see returns).",
				},
				"start": {"type": "string", "description": "State entered first. Default: the first state."},
			},
			"required": ["tree", "states"],
		},
		"returns": "{tree, states, transitions, parameters: paths to set from code, active}; meta.undo names the undo step. Replaces the tree's root. The tree is made active, except when a transition has an expression: an active tree also runs in the editor, where the expression would be evaluated too, so the game's script sets active = true in _ready().",
	}, _create)


	registry.register({
		"name": "animation_blend_space_create",
		"group": "animation",
		"summary": "Give an AnimationTree a blend space: animations placed along one axis or on a plane, mixed by a position set from code.",
		"risk": AccessPolicy.RISK_WRITE,
		"undoable": true,
		"requires": ["scene_open"],
		"params": {
			"type": "object",
			"properties": {
				"tree": {"type": "string", "description": "Path of the AnimationTree node."},
				"player": {"type": "string", "description": "Path of the AnimationPlayer whose animations are blended. Default: the one the tree already points to."},
				"points": {
					"type": "array",
					"items": {"type": "object"},
					"description": "Each: {animation: name in the player, position: a number for a blend along one axis, or [x, y] for a blend on a plane}. All points of one kind. E.g. idle at 0 and run at 1; or walking up, down, left, right at [0, -1], [0, 1], [-1, 0], [1, 0].",
				},
				"min": {"description": "Lowest position, a number or [x, y]. Default: the lowest among the points, and at most -1 or 0."},
				"max": {"description": "Highest position. Default: the highest among the points, and at least 1."},
			},
			"required": ["tree", "points"],
		},
		"returns": "{tree, kind: 1d|2d, points, min, max, parameters: [parameters/blend_position]}; meta.undo names the undo step. Replaces the tree's root and makes the tree active.",
	}, _create_blend_space)


func _root() -> Node:
	return _context.scene_root()


# The tree and the player it plays, as [tree, player], or a failed reply.
func _tree_and_player(args: Dictionary) -> Variant:
	var tree := NodeRef.resolve(_root(), args["tree"])
	if tree == null:
		return Reply.fail("NODE_NOT_FOUND", "The node does not exist.", "Use scene_tree to see the node paths.", {"path": TextSanitizer.clean_line(args["tree"])})
	if not tree is AnimationTree:
		return Reply.fail(
			"TYPE_MISMATCH", "The node is not an AnimationTree.", "Create one with node_create, next to the AnimationPlayer.",
			{"path": TextSanitizer.clean_line(args["tree"]), "class": tree.get_class()},
		)
	var player: Node = NodeRef.resolve(_root(), args["player"]) if args.has("player") else tree.get_node_or_null(tree.anim_player)
	if not player is AnimationPlayer:
		return Reply.fail("INVALID_ARGS", "player does not name an AnimationPlayer.", "Pass the path of the AnimationPlayer whose animations are played.")
	return [tree, player]


func _create_blend_space(args: Dictionary, options: Dictionary) -> Dictionary:
	var found: Variant = _tree_and_player(args)
	if found is Dictionary:
		return found
	var tree: AnimationTree = found[0]
	var player: AnimationPlayer = found[1]
	var points: Array = args["points"]
	if points.is_empty() or points.size() > MAX_BLEND_POINTS:
		return Reply.fail("INVALID_ARGS", "Give between 1 and %d points." % MAX_BLEND_POINTS)
	var flat: bool = points[0] is Dictionary and points[0].get("position") is Array
	var positions := []
	for index in points.size():
		var point: Variant = points[index]
		var position: Variant = _position(point.get("position") if point is Dictionary else null, flat)
		if position == null or not point.get("animation") is String:
			return Reply.fail("INVALID_ARGS", "A point needs animation and position; positions are all numbers or all [x, y].", "", {"point": index})
		if not player.has_animation(point["animation"]):
			return Reply.fail(
				"INVALID_ARGS", "The player has no such animation.", "animation_list shows the animations of a player.",
				{"point": index, "animation": TextSanitizer.clean_line(point["animation"])},
			)
		positions.append(position)
	var low: Variant = _bound(args.get("min"), positions, flat, true)
	var high: Variant = _bound(args.get("max"), positions, flat, false)
	if low != null and high != null and not (low.x < high.x and low.y < high.y if flat else low < high):
		low = null
	if low == null or high == null:
		return Reply.fail("INVALID_ARGS", "min and max are positions like those of the points, with min below max and every point between them.")

	var space: AnimationRootNode = AnimationNodeBlendSpace2D.new() if flat else AnimationNodeBlendSpace1D.new()
	# The bounds first: a point outside them is refused by the engine.
	space.min_space = low
	space.max_space = high
	var names_points := _argument_count(space.get_class(), "add_blend_point") > _UNNAMED_POINT_ARGUMENTS
	for index in points.size():
		var node := AnimationNodeAnimation.new()
		node.animation = StringName(points[index]["animation"])
		# Newer engines want each point named, older ones take no name.
		if names_points:
			space.callv("add_blend_point", [node, positions[index], -1, "%s_%d" % [points[index]["animation"], index]])
		else:
			space.add_blend_point(node, positions[index])
	if options["dry_run"]:
		return Edit.planned({"blend_space_on": args["tree"], "kind": "2d" if flat else "1d", "points": points.size()})

	var action := Edit.undo_name("animation_blend_space_create", str(tree.name))
	var undo: Object = _context.undo_redo()
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	for change in [["anim_player", tree.get_path_to(player)], ["tree_root", space], ["active", true]]:
		undo.add_do_property(tree, change[0], change[1])
		undo.add_undo_property(tree, change[0], tree.get(change[0]))
	undo.commit_action()
	return Edit.done({
		"tree": TextSanitizer.clean_line(NodeRef.path_of(_root(), tree)), "kind": "2d" if flat else "1d", "points": points.size(),
		"min": [low.x, low.y] if flat else low, "max": [high.x, high.y] if flat else high, "parameters": ["parameters/blend_position"],
	}, action)


# How many arguments a method of an engine class takes.
static func _argument_count(owner_class: String, method: String) -> int:
	for described in ClassDB.class_get_method_list(owner_class, true):
		if described["name"] == method:
			return described["args"].size()
	return 0


# A position from JSON: a float, or a Vector2 when `flat`. Null when it is neither.
static func _position(value: Variant, flat: bool) -> Variant:
	if flat:
		var is_pair: bool = value is Array and value.size() == 2 and _is_number(value[0]) and _is_number(value[1])
		return Vector2(value[0], value[1]) if is_pair else null
	return float(value) if _is_number(value) else null


static func _is_number(value: Variant) -> bool:
	return (value is float or value is int) and absf(value) <= MAX_BLEND_POSITION


# The lower or upper bound of the space: the one given, or one that holds
# every point and the usual range of -1 (or 0) to 1. Null when it does not fit.
static func _bound(given: Variant, positions: Array, flat: bool, lower: bool) -> Variant:
	var bound: Variant = Vector2(-1, -1) if flat else 0.0
	if not lower:
		bound = Vector2.ONE if flat else 1.0
	for position in positions:
		if flat:
			bound = bound.min(position) if lower else bound.max(position)
		else:
			bound = minf(bound, position) if lower else maxf(bound, position)
	if given == null:
		return bound
	var wanted: Variant = _position(given, flat)
	if wanted == null:
		return null
	# Every point has to lie inside what was asked for.
	if flat:
		var inside: bool = (wanted.x <= bound.x and wanted.y <= bound.y) if lower else (wanted.x >= bound.x and wanted.y >= bound.y)
		return wanted if inside else null
	return wanted if (wanted <= bound if lower else wanted >= bound) else null


func _create(args: Dictionary, options: Dictionary) -> Dictionary:
	var found: Variant = _tree_and_player(args)
	if found is Dictionary:
		return found
	var tree: AnimationTree = found[0]
	var player: AnimationPlayer = found[1]

	var machine := AnimationNodeStateMachine.new()
	var names: Variant = _add_states(machine, player, args["states"])
	if names is Dictionary:
		return names
	var start: Variant = args.get("start", names[0])
	if not (start is String and start in names):
		return Reply.fail("INVALID_ARGS", "start names no state.", "", {"start": TextSanitizer.clean_line(str(start))})
	var conditions: Variant = _add_transitions(machine, names, args.get("transitions", []))
	if conditions is Dictionary:
		return conditions
	var entry := AnimationNodeStateMachineTransition.new()
	entry.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	machine.add_transition(_START, start, entry)
	if options["dry_run"]:
		return Edit.planned({"state_machine_on": args["tree"], "states": names, "transitions": machine.get_transition_count() - 1})

	var action := Edit.undo_name("animation_state_machine_create", str(tree.name))
	var undo: Object = _context.undo_redo()
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	# An active tree runs in the editor as well, and would evaluate the
	# expressions there: text of the caller, run in the editor unasked.
	var active := not _has_expression(machine)
	# Expressions are evaluated on advance_expression_base_node, by default the
	# tree itself; the parent (the character) is the node they are written for.
	var changes := [["anim_player", tree.get_path_to(player)], ["tree_root", machine], ["active", active]]
	if tree.get_parent() != null and tree != _root() and tree.advance_expression_base_node == NodePath("."):
		changes.append(["advance_expression_base_node", NodePath("..")])
	for change in changes:
		undo.add_do_property(tree, change[0], change[1])
		undo.add_undo_property(tree, change[0], tree.get(change[0]))
	undo.commit_action()
	var parameters := ["parameters/playback"]
	for condition in conditions:
		parameters.append("parameters/conditions/%s" % condition)
	return Edit.done({
		"tree": TextSanitizer.clean_line(NodeRef.path_of(_root(), tree)),
		"states": names, "transitions": machine.get_transition_count() - 1, "parameters": parameters, "active": active,
	}, action, [] if active else [_INACTIVE])


func _has_expression(machine: AnimationNodeStateMachine) -> bool:
	for index in machine.get_transition_count():
		if machine.get_transition(index).advance_expression != "":
			return true
	return false


# Adds the states. Returns their names, or a failed reply.
func _add_states(machine: AnimationNodeStateMachine, player: AnimationPlayer, states: Array) -> Variant:
	if states.is_empty() or states.size() > MAX_STATES:
		return Reply.fail("INVALID_ARGS", "Give between 1 and %d states." % MAX_STATES)
	var names: Array[String] = []
	for index in states.size():
		var state: Variant = states[index]
		if not (state is Dictionary and state.get("name") is String and state.get("animation") is String):
			return Reply.fail("INVALID_ARGS", "A state needs name and animation.", "", {"state": index})
		var name: String = state["name"]
		if _name_regex.search(name) == null or name in names or name in [_START, _END]:
			return Reply.fail("INVALID_ARGS", "State names are distinct, made of letters, digits and _, and not Start or End.", "", {"state": index})
		if not player.has_animation(state["animation"]):
			return Reply.fail(
				"INVALID_ARGS", "The player has no such animation.", "animation_list shows the animations of a player.",
				{"state": index, "animation": TextSanitizer.clean_line(state["animation"])},
			)
		var node := AnimationNodeAnimation.new()
		node.animation = StringName(state["animation"])
		machine.add_node(name, node, _GRAPH_ORIGIN + _GRAPH_STEP * index)
		names.append(name)
	return names


# Adds the transitions. Returns the condition names they use, or a failed reply.
func _add_transitions(machine: AnimationNodeStateMachine, names: Array, transitions: Variant) -> Variant:
	if not transitions is Array or transitions.size() > MAX_TRANSITIONS:
		return Reply.fail("INVALID_ARGS", "transitions is a list of at most %d." % MAX_TRANSITIONS)
	var conditions: Array[String] = []
	for index in transitions.size():
		var spec: Variant = transitions[index]
		var transition: Variant = _transition(spec, names)
		if transition is Dictionary:
			transition["error"]["details"] = {"transition": index}
			return transition
		if machine.has_transition(spec["from"], spec["to"]):
			return Reply.fail("INVALID_ARGS", "Two transitions lead from the same state to the same state.", "", {"transition": index})
		machine.add_transition(spec["from"], spec["to"], transition)
		var condition := str(transition.advance_condition)
		if condition != "" and not condition in conditions:
			conditions.append(condition)
	return conditions


# One transition object, or a failed reply.
func _transition(spec: Variant, names: Array) -> Variant:
	if not (spec is Dictionary and spec.get("from") is String and spec.get("to") is String):
		return Reply.fail("INVALID_ARGS", "A transition needs from and to.")
	if not (spec["from"] in names and (spec["to"] in names or spec["to"] == _END)) or spec["from"] == spec["to"]:
		return Reply.fail("INVALID_ARGS", "from and to name two different states (to may be End).")
	var switch: Variant = spec.get("switch", "immediate")
	var xfade: Variant = spec.get("xfade", 0.0)
	var auto: Variant = spec.get("auto", false)
	var condition: Variant = spec.get("condition", "")
	var expression: Variant = spec.get("expression", "")
	if not (_SWITCH_MODES.has(switch) and (xfade is float or xfade is int) and xfade >= 0.0 and auto is bool):
		return Reply.fail("INVALID_ARGS", "switch is immediate, sync or at_end; xfade is seconds; auto is true or false.")
	if not (condition is String and (condition == "" or _name_regex.search(condition) != null)):
		return Reply.fail("INVALID_ARGS", "condition is a name made of letters, digits and _.")
	if not (expression is String and expression.length() <= MAX_EXPRESSION_LENGTH):
		return Reply.fail("INVALID_ARGS", "expression is text of at most %d characters." % MAX_EXPRESSION_LENGTH)

	var transition := AnimationNodeStateMachineTransition.new()
	transition.switch_mode = _SWITCH_MODES[switch]
	transition.xfade_time = xfade
	# Automatic transitions wait for their condition or expression, if any;
	# the others are taken when code asks for the state with travel().
	var decides_itself: bool = auto or condition != "" or expression != ""
	transition.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO if decides_itself else AnimationNodeStateMachineTransition.ADVANCE_MODE_ENABLED
	transition.advance_condition = StringName(condition)
	transition.advance_expression = expression
	return transition
