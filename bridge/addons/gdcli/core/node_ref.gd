extends RefCounted
## Node addressing relative to the edited scene root (docs/protocol.md section 6.2).

const ROOT_PATH := "."


## Returns the node, or null when the path is malformed or leaves the scene.
static func resolve(scene_root: Node, path: String) -> Node:
	if scene_root == null or path == "":
		return null
	if path == ROOT_PATH:
		return scene_root
	if path.begins_with("/") or path.begins_with("%"):
		return null
	for segment in path.split("/"):
		if segment == "" or segment == "." or segment == "..":
			return null
	var node := scene_root.get_node_or_null(NodePath(path))
	if node == null or not scene_root.is_ancestor_of(node):
		return null
	return node


static func path_of(scene_root: Node, node: Node) -> String:
	if node == scene_root:
		return ROOT_PATH
	return str(scene_root.get_path_to(node))
