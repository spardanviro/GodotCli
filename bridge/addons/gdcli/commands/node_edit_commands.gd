extends RefCounted
## Commands that change nodes of the edited scene. Every change is one step on
## the editor's undo stack, so Ctrl+Z in the editor takes it back.

const AccessPolicy = preload("../core/access_policy.gd")
const Edit = preload("../core/edit.gd")
const NodeRef = preload("../core/node_ref.gd")
const PathPolicy = preload("../core/path_policy.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")
const ValueDecoder = preload("../core/value_decoder.gd")

const MAX_DEPENDENCIES := 2000
const _PATH := {"type": "string", "description": "Node path relative to the scene root; \".\" is the root."}

var _context: RefCounted


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	_add(registry, "node_create", "Add a node to the edited scene.", {
		"parent": {"type": "string", "description": "Parent node path.", "default": NodeRef.ROOT_PATH},
		"type": {"type": "string", "description": "Built-in node class, e.g. CharacterBody2D."},
		"name": {"type": "string", "description": "Node name; defaults to the class name."},
		"properties": {"type": "object", "description": "Properties to set on the new node."},
	}, ["type"], _create)
	_add(registry, "node_delete", "Remove a node and its children from the edited scene.", {"path": _PATH}, ["path"], _delete)
	_add(registry, "node_set", "Set properties of a node.", {
		"path": _PATH,
		"properties": {"type": "object", "description": "Property names and values; see docs/protocol.md 6.4 for value forms."},
	}, ["path", "properties"], _set_properties)
	_add(registry, "node_rename", "Rename a node.", {"path": _PATH, "name": {"type": "string"}}, ["path", "name"], _rename)
	_add(registry, "node_move", "Move a node under another parent and/or to another position among its siblings.", {
		"path": _PATH,
		"parent": {"type": "string", "description": "New parent; omit to keep the current one."},
		"index": {"type": "integer", "description": "Position among the siblings; omit for last.", "minimum": 0},
	}, ["path"], _move)
	_add(registry, "node_duplicate", "Duplicate a node with its children, next to the original.", {
		"path": _PATH,
		"name": {"type": "string", "description": "Name of the copy."},
	}, ["path"], _duplicate)
	_add(registry, "node_attach_script", "Attach a script file to a node, or detach with an empty path.", {
		"path": _PATH,
		"script": {"type": "string", "description": "res:// path of the script; \"\" detaches."},
	}, ["path", "script"], _attach_script)
	_add(registry, "node_connect_signal", "Connect a signal of one node to a method of another, saved with the scene.", {
		"path": _PATH,
		"signal": {"type": "string"},
		"target": {"type": "string", "description": "Node whose method is called."},
		"method": {"type": "string"},
	}, ["path", "signal", "target", "method"], _connect_signal)
	_add(registry, "node_add_to_group", "Add a node to a group, saved with the scene.", {
		"path": _PATH,
		"group": {"type": "string"},
	}, ["path", "group"], _add_to_group)
	_add(registry, "node_instantiate_scene", "Add an instance of another scene file as a child.", {
		"parent": {"type": "string", "default": NodeRef.ROOT_PATH},
		"scene": {"type": "string", "description": "res:// path of the scene to instance."},
		"name": {"type": "string"},
	}, ["scene"], _instantiate_scene)


func _add(registry: RefCounted, name: String, summary: String, properties: Dictionary, required: Array, handler: Callable) -> void:
	registry.register({
		"name": name,
		"summary": summary,
		"risk": AccessPolicy.RISK_WRITE,
		"undoable": true,
		"requires": ["scene_open"],
		"params": {"type": "object", "properties": properties, "required": required},
		"returns": "{path, type} of the affected node; meta.undo names the undo step.",
	}, handler)


func _root() -> Node:
	return _context.scene_root()


func _find(path: String) -> Node:
	return NodeRef.resolve(_root(), path)


func _missing(path: String) -> Dictionary:
	return Reply.fail(
		"NODE_NOT_FOUND", "The node does not exist.", "Use scene_tree to see the node paths of the edited scene.",
		{"path": TextSanitizer.clean_line(path)},
	)


# A node inside an instanced scene belongs to that scene's file. Removing,
# moving or copying it here would write it into this scene as well.
func _foreign(node: Node) -> Dictionary:
	if node == _root() or node.owner == _root():
		return {}
	return Reply.fail(
		"PRECONDITION_FAILED", "The node belongs to an instanced scene or was created by a script.",
		"Open the scene it comes from and change it there.", {"path": TextSanitizer.clean_line(NodeRef.path_of(_root(), node))},
	)


func _describe(node: Node) -> Dictionary:
	return {"path": TextSanitizer.clean_line(NodeRef.path_of(_root(), node)), "type": node.get_class()}


# Node names cannot contain these; Godot would silently replace them.
func _bad_name(name: String) -> Dictionary:
	if name == "" or name.validate_node_name() != name:
		return Reply.fail("INVALID_ARGS", "Not a valid node name.", "Avoid . : @ / \" and %.", {"name": TextSanitizer.clean_line(name)})
	return {}


# Nodes saved with the scene are the ones owned by its root.
func _owned_descendants(node: Node) -> Array[Node]:
	var owned: Array[Node] = []
	var pending: Array[Node] = [node]
	while not pending.is_empty():
		var current: Node = pending.pop_back()
		for child in current.get_children():
			if child.owner == _root():
				owned.append(child)
			pending.append(child)
	return owned


func _create(args: Dictionary, options: Dictionary) -> Dictionary:
	var parent := _find(args["parent"])
	if parent == null:
		return _missing(args["parent"])
	var type: String = args["type"]
	# Built-in classes only: a script class would run project code right here.
	if not (ClassDB.class_exists(type) and ClassDB.is_parent_class(type, "Node") and ClassDB.can_instantiate(type)):
		return Reply.fail(
			"INVALID_ARGS", "Not a built-in node class that can be created.",
			"For a scripted class, create its base class and use node_attach_script.", {"type": TextSanitizer.clean_line(type)},
		)
	var name: String = args.get("name", type)
	var bad := _bad_name(name)
	if not bad.is_empty():
		return bad

	var node: Node = ClassDB.instantiate(type)
	var decoded: Dictionary = ValueDecoder.new(_root()).decode_properties(node, args.get("properties", {}))
	if not decoded["ok"] or options["dry_run"]:
		node.free()
		return decoded if not decoded["ok"] else Edit.planned({"create": type, "under": args["parent"], "name": name})
	node.name = name
	for property in decoded["values"]:
		node.set(property, decoded["values"][property])

	var undo: Object = _context.undo_redo()
	var action := Edit.undo_name("node_create", name)
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	undo.add_do_method(parent, "add_child", node, true)
	undo.add_do_method(node, "set_owner", _root())
	undo.add_do_reference(node)
	_add_detach(undo, "add_undo_method", node, parent, [])
	undo.commit_action()
	return Edit.done(_describe(node), action)


# Owners are cleared before a node leaves its parent. The engine does this by
# itself only for nodes inside the tree, and warns when a node comes back with
# a stale owner; doing it explicitly keeps both directions clean.
func _add_detach(undo: Object, add: String, node: Node, parent: Node, owned: Array[Node]) -> void:
	for descendant in owned:
		undo.call(add, descendant, "set_owner", null)
	undo.call(add, node, "set_owner", null)
	undo.call(add, parent, "remove_child", node)


func _delete(args: Dictionary, options: Dictionary) -> Dictionary:
	var node := _find(args["path"])
	if node == null:
		return _missing(args["path"])
	if node == _root():
		return Reply.fail("INVALID_ARGS", "The scene root cannot be deleted.", "Delete the scene file instead.")
	var foreign := _foreign(node)
	if not foreign.is_empty():
		return foreign
	var described := _describe(node)
	var children := node.get_child_count()
	if options["dry_run"]:
		return Edit.planned({"delete": described["path"], "children_removed": children})

	var parent := node.get_parent()
	var undo: Object = _context.undo_redo()
	var action := Edit.undo_name("node_delete", str(node.name))
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	var owned := _owned_descendants(node)
	_add_detach(undo, "add_do_method", node, parent, owned)
	undo.add_undo_method(parent, "add_child", node, true)
	undo.add_undo_method(parent, "move_child", node, node.get_index())
	undo.add_undo_method(node, "set_owner", _root())
	for descendant in owned:
		undo.add_undo_method(descendant, "set_owner", _root())
	undo.add_undo_reference(node)
	undo.commit_action()
	described["children_removed"] = children
	return Edit.done(described, action)


func _set_properties(args: Dictionary, options: Dictionary) -> Dictionary:
	var node := _find(args["path"])
	if node == null:
		return _missing(args["path"])
	var properties: Dictionary = args["properties"]
	if properties.is_empty():
		return Reply.fail("INVALID_ARGS", "Give at least one property.")
	var decoded: Dictionary = ValueDecoder.new(_root()).decode_properties(node, properties)
	if not decoded["ok"]:
		return decoded
	if options["dry_run"]:
		return Edit.planned({"set": properties.keys(), "on": _describe(node)["path"]})

	var undo: Object = _context.undo_redo()
	var action := Edit.undo_name("node_set", str(node.name))
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	for property in decoded["values"]:
		undo.add_do_property(node, property, decoded["values"][property])
		undo.add_undo_property(node, property, node.get(property))
	undo.commit_action()
	var described := _describe(node)
	described["set"] = properties.keys()
	return Edit.done(described, action)


func _rename(args: Dictionary, options: Dictionary) -> Dictionary:
	var node := _find(args["path"])
	if node == null:
		return _missing(args["path"])
	var bad := _bad_name(args["name"])
	if not bad.is_empty():
		return bad
	var foreign := _foreign(node)
	if not foreign.is_empty():
		return foreign
	var parent := node.get_parent()
	if node != _root() and parent.has_node(NodePath(args["name"])) and parent.get_node(NodePath(args["name"])) != node:
		return Reply.fail("ALREADY_EXISTS", "A sibling already has this name.", "", {"name": TextSanitizer.clean_line(args["name"])})
	if options["dry_run"]:
		return Edit.planned({"rename": _describe(node)["path"], "to": args["name"]})

	var undo: Object = _context.undo_redo()
	var action := Edit.undo_name("node_rename", args["name"])
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	undo.add_do_property(node, "name", args["name"])
	undo.add_undo_property(node, "name", node.name)
	undo.commit_action()
	return Edit.done(_describe(node), action)


func _move(args: Dictionary, options: Dictionary) -> Dictionary:
	var node := _find(args["path"])
	if node == null:
		return _missing(args["path"])
	if node == _root():
		return Reply.fail("INVALID_ARGS", "The scene root cannot be moved.")
	var foreign := _foreign(node)
	if not foreign.is_empty():
		return foreign
	var old_parent := node.get_parent()
	var new_parent := _find(args["parent"]) if args.has("parent") else old_parent
	if new_parent == null:
		return _missing(args["parent"])
	if new_parent == node or node.is_ancestor_of(new_parent):
		return Reply.fail("INVALID_ARGS", "A node cannot be moved into itself or its own children.")
	if new_parent != old_parent and new_parent.has_node(NodePath(node.name)):
		return Reply.fail("ALREADY_EXISTS", "The new parent already has a child with this name.", "Rename the node first.")
	var sibling_count := new_parent.get_child_count() - (1 if new_parent == old_parent else 0)
	var index: int = mini(args.get("index", sibling_count), sibling_count)
	if options["dry_run"]:
		return Edit.planned({"move": _describe(node)["path"], "under": _describe(new_parent)["path"], "index": index})

	var owned := _owned_descendants(node)
	var undo: Object = _context.undo_redo()
	var action := Edit.undo_name("node_move", str(node.name))
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	_add_reparent(undo, "add_do_method", node, old_parent, new_parent, index, owned)
	_add_reparent(undo, "add_undo_method", node, new_parent, old_parent, node.get_index(), owned)
	undo.commit_action()
	return Edit.done(_describe(node), action)


func _add_reparent(undo: Object, add: String, node: Node, from: Node, to: Node, index: int, owned: Array[Node]) -> void:
	_add_detach(undo, add, node, from, owned)
	undo.call(add, to, "add_child", node, true)
	undo.call(add, to, "move_child", node, index)
	undo.call(add, node, "set_owner", _root())
	for descendant in owned:
		undo.call(add, descendant, "set_owner", _root())


func _duplicate(args: Dictionary, options: Dictionary) -> Dictionary:
	var node := _find(args["path"])
	if node == null:
		return _missing(args["path"])
	if node == _root():
		return Reply.fail("INVALID_ARGS", "The scene root cannot be duplicated.")
	var foreign := _foreign(node)
	if not foreign.is_empty():
		return foreign
	if args.has("name"):
		var bad := _bad_name(args["name"])
		if not bad.is_empty():
			return bad
	if options["dry_run"]:
		return Edit.planned({"duplicate": _describe(node)["path"]})

	var parent := node.get_parent()
	var copy := node.duplicate()
	if args.has("name"):
		copy.name = args["name"]
	var undo: Object = _context.undo_redo()
	var action := Edit.undo_name("node_duplicate", str(node.name))
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	undo.add_do_method(parent, "add_child", copy, true)
	undo.add_do_method(parent, "move_child", copy, node.get_index() + 1)
	undo.add_do_method(copy, "set_owner", _root())
	# duplicate() keeps the children but not their owners. Only the copies of
	# nodes this scene owned get it as owner: the inside of an instanced
	# scene must stay the instance's.
	var owned_copies := _copies_of_owned(node, copy)
	for descendant in owned_copies:
		undo.add_do_method(descendant, "set_owner", _root())
	undo.add_do_reference(copy)
	_add_detach(undo, "add_undo_method", copy, parent, owned_copies)
	undo.commit_action()
	return Edit.done(_describe(copy), action)


# Walks the original and its copy side by side; they have the same shape.
func _copies_of_owned(original: Node, copy: Node) -> Array[Node]:
	var found: Array[Node] = []
	var pending := [[original, copy]]
	while not pending.is_empty():
		var pair: Array = pending.pop_back()
		var count: int = mini(pair[0].get_child_count(), pair[1].get_child_count())
		for index in count:
			var original_child: Node = pair[0].get_child(index)
			var copied_child: Node = pair[1].get_child(index)
			if original_child.owner == _root():
				found.append(copied_child)
			pending.append([original_child, copied_child])
	return found


func _attach_script(args: Dictionary, options: Dictionary) -> Dictionary:
	var node := _find(args["path"])
	if node == null:
		return _missing(args["path"])
	var script: Script = null
	if args["script"] != "":
		var checked := PathPolicy.check(args["script"], PathPolicy.ACCESS_READ)
		if not checked["ok"]:
			return checked
		if not ResourceLoader.exists(checked["path"]):
			return Reply.fail("RESOURCE_NOT_FOUND", "The script file does not exist.", "", {"path": checked["path"]})
		# A tool script starts running in the editor once it is on a node,
		# whoever wrote the file and however. Asked before it is even loaded.
		if Edit.runs_in_editor(FileAccess.get_file_as_string(checked["path"])):
			var what := {
				"command": "node_attach_script", "reason": "tool script: it runs inside the editor as soon as it is loaded",
				"target": checked["path"], "preview": FileAccess.get_file_as_string(checked["path"]),
			}
			var gate := Edit.person_gate(_context, options, what, _attach_script.bind(args, Edit.approved(options)))
			if not gate.is_empty():
				return gate
		script = ResourceLoader.load(checked["path"]) as Script
		if script == null:
			return Reply.fail("TYPE_MISMATCH", "The file is not a script.", "", {"path": checked["path"]})
		# set_script fails without a word when the script extends something else.
		var base := str(script.get_instance_base_type())
		if base == "" or not node.is_class(base):
			return Reply.fail(
				"TYPE_MISMATCH", "The script does not extend the node's class, or does not compile.",
				"Make the script extend the node's class or one of its parents.",
				{"script_extends": base, "node_class": node.get_class()},
			)
	if options["dry_run"]:
		return Edit.planned({"attach": args["script"], "to": _describe(node)["path"]})

	var undo: Object = _context.undo_redo()
	var action := Edit.undo_name("node_attach_script", str(node.name))
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	undo.add_do_method(node, "set_script", script)
	undo.add_undo_method(node, "set_script", node.get_script())
	undo.commit_action()
	var described := _describe(node)
	described["script"] = args["script"]
	return Edit.done(described, action)


func _connect_signal(args: Dictionary, options: Dictionary) -> Dictionary:
	var node := _find(args["path"])
	var target := _find(args["target"])
	if node == null or target == null:
		return _missing(args["path"] if node == null else args["target"])
	if not node.has_signal(args["signal"]):
		return Reply.fail("INVALID_ARGS", "The node has no such signal.", "", {"signal": TextSanitizer.clean_line(args["signal"])})
	if not args["method"].is_valid_identifier():
		return Reply.fail("INVALID_ARGS", "Not a valid method name.")
	var callable := Callable(target, args["method"])
	if node.is_connected(args["signal"], callable):
		return Reply.fail("ALREADY_EXISTS", "This connection already exists.")
	if options["dry_run"]:
		return Edit.planned({"connect": args["signal"], "from": _describe(node)["path"], "to": _describe(target)["path"]})

	var undo: Object = _context.undo_redo()
	var action := Edit.undo_name("node_connect_signal", args["signal"])
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	# CONNECT_PERSIST is what makes the connection part of the saved scene.
	undo.add_do_method(node, "connect", args["signal"], callable, CONNECT_PERSIST)
	undo.add_undo_method(node, "disconnect", args["signal"], callable)
	undo.commit_action()
	var warnings := [] if target.has_method(args["method"]) else ["The target has no method of this name yet; add it to its script."]
	return Edit.done(_describe(node), action, warnings)


# True when loading `scene` would, somewhere down the line, load `target`.
func _depends_on(scene: String, target: String) -> bool:
	if target == "":
		return false
	var seen := {}
	var pending: Array[String] = [scene]
	while not pending.is_empty() and seen.size() < MAX_DEPENDENCIES:
		var current: String = pending.pop_back()
		if seen.has(current) or not ResourceLoader.exists(current):
			continue
		seen[current] = true
		for dependency in ResourceLoader.get_dependencies(current):
			# Entries are "path" or "uid::type::path".
			var path: String = dependency.get_slice("::", dependency.get_slice_count("::") - 1)
			if path == target:
				return true
			if path.get_extension() in ["tscn", "scn"]:
				pending.append(path)
	return false


func _add_to_group(args: Dictionary, options: Dictionary) -> Dictionary:
	var node := _find(args["path"])
	if node == null:
		return _missing(args["path"])
	var group: String = args["group"]
	if group == "" or group.begins_with("_"):
		return Reply.fail("INVALID_ARGS", "Not a usable group name.", "Names starting with an underscore are reserved for the editor.")
	if node.is_in_group(group):
		return Reply.fail("ALREADY_EXISTS", "The node is already in this group.")
	if options["dry_run"]:
		return Edit.planned({"add": _describe(node)["path"], "to_group": group})

	var undo: Object = _context.undo_redo()
	var action := Edit.undo_name("node_add_to_group", group)
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	undo.add_do_method(node, "add_to_group", group, true)
	undo.add_undo_method(node, "remove_from_group", group)
	undo.commit_action()
	return Edit.done(_describe(node), action)


func _instantiate_scene(args: Dictionary, options: Dictionary) -> Dictionary:
	var parent := _find(args["parent"])
	if parent == null:
		return _missing(args["parent"])
	var checked := PathPolicy.check(args["scene"], PathPolicy.ACCESS_READ)
	if not checked["ok"]:
		return checked
	if checked["path"] == _context.scene_path():
		return Reply.fail("INVALID_ARGS", "A scene cannot contain itself, directly or through other scenes.")
	if not ResourceLoader.exists(checked["path"]):
		return Reply.fail("RESOURCE_NOT_FOUND", "The scene file does not exist.", "", {"path": checked["path"]})
	if _depends_on(checked["path"], _context.scene_path()):
		return Reply.fail("INVALID_ARGS", "A scene cannot contain itself, directly or through other scenes.")
	var packed := ResourceLoader.load(checked["path"]) as PackedScene
	if packed == null:
		return Reply.fail("TYPE_MISMATCH", "The file is not a scene.", "", {"path": checked["path"]})
	if args.has("name"):
		var bad := _bad_name(args["name"])
		if not bad.is_empty():
			return bad
	if options["dry_run"]:
		return Edit.planned({"instantiate": checked["path"], "under": args["parent"]})

	var instance := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if instance == null:
		return Reply.fail("COMMAND_FAILED", "The scene could not be instantiated.", "", {"path": checked["path"]})
	if args.has("name"):
		instance.name = args["name"]
	var undo: Object = _context.undo_redo()
	var action := Edit.undo_name("node_instantiate_scene", str(instance.name))
	undo.create_action(action, UndoRedo.MERGE_DISABLE, _root())
	undo.add_do_method(parent, "add_child", instance, true)
	# Only the instance root is owned by this scene; its children belong to theirs.
	undo.add_do_method(instance, "set_owner", _root())
	undo.add_do_reference(instance)
	_add_detach(undo, "add_undo_method", instance, parent, [])
	undo.commit_action()
	var described := _describe(instance)
	described["scene"] = checked["path"]
	return Edit.done(described, action)
