extends RefCounted
## Describing nodes: the tree below a node, and one node with its properties.
## Shared by the commands for the edited scene and by the helper inside a
## running game, so it uses nothing that exists only in the editor.

const NodeRef = preload("node_ref.gd")
const Reply = preload("reply.gd")
const TextSanitizer = preload("text_sanitizer.gd")
const ValueCodec = preload("value_codec.gd")

const MAX_NODES := 2000
const _STRUCTURAL_USAGE := PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP
const _SCRIPT_PROPERTY := "script"


## Returns {tree, truncated}: nested {name, type, path, script?, instance?,
## groups?, children}, at most MAX_NODES nodes.
static func tree(root: Node, start: Node, max_depth: int) -> Dictionary:
	var budget := {"remaining": MAX_NODES, "truncated": false}
	var described := _describe(root, start, max_depth, budget)
	return {"tree": described, "truncated": budget["truncated"]}


## One node: {path, type, script?, groups, properties}. `wanted` is the list of
## property names, or null for the default set: what the inspector shows, and
## with `script_variables` the variables of the node's script too. A property
## the inspector does not show (velocity, global_position, the offsets of a
## control laid out by a preset) can always be asked for by name.
## Returns a reply (see reply.gd).
static func node(root: Node, target: Node, wanted: Variant, script_variables: bool) -> Dictionary:
	var listed := {}
	var defaults := []
	for property in target.get_property_list():
		var usage: int = property["usage"]
		var name: String = property["name"]
		if usage & _STRUCTURAL_USAGE or name == _SCRIPT_PROPERTY:
			continue
		var shown := usage & PROPERTY_USAGE_EDITOR != 0
		listed[name] = true
		if shown or (script_variables and usage & PROPERTY_USAGE_SCRIPT_VARIABLE != 0):
			defaults.append(name)

	var names: Array = defaults if wanted == null else wanted
	var properties := {}
	var budget := ValueCodec.new_budget()
	for name in names:
		if not listed.has(name):
			return Reply.fail(
				"INVALID_ARGS", "The node has no such property.",
				"Ask without `properties` to list them.", {"property": TextSanitizer.clean_line(str(name))},
			)
		properties[TextSanitizer.clean_line(name)] = ValueCodec.encode(target.get(name), root, budget)

	var result := {
		"path": TextSanitizer.clean_line(NodeRef.path_of(root, target)),
		"type": target.get_class(),
		"groups": visible_groups(target),
		"properties": properties,
	}
	var script: Script = target.get_script()
	if script != null and script.resource_path != "":
		result["script"] = TextSanitizer.clean_line(script.resource_path)
	return Reply.ok(result)


## Groups starting with an underscore are the engine's own bookkeeping.
static func visible_groups(target: Node) -> Array:
	var groups := []
	for group in target.get_groups():
		var name := str(group)
		if not name.begins_with("_"):
			groups.append(TextSanitizer.clean_line(name))
	return groups


static func _describe(root: Node, target: Node, depth_left: int, budget: Dictionary) -> Dictionary:
	budget["remaining"] -= 1
	var described := {
		"name": TextSanitizer.clean_line(str(target.name)),
		"type": target.get_class(),
		"path": TextSanitizer.clean_line(NodeRef.path_of(root, target)),
	}
	var script: Script = target.get_script()
	if script != null and script.resource_path != "":
		described["script"] = TextSanitizer.clean_line(script.resource_path)
	if target != root and target.scene_file_path != "":
		described["instance"] = TextSanitizer.clean_line(target.scene_file_path)
	var groups := visible_groups(target)
	if not groups.is_empty():
		described["groups"] = groups

	var children := []
	var omitted := 0
	for child in target.get_children():
		if depth_left > 0 and budget["remaining"] > 0:
			children.append(_describe(root, child, depth_left - 1, budget))
		else:
			omitted += 1
			if budget["remaining"] <= 0:
				budget["truncated"] = true
	described["children"] = children
	if omitted > 0:
		described["children_omitted"] = omitted
	return described
