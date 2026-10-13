@tool
extends RefCounted
## A project-defined command, used by the bridge's end-to-end test.
## It declares itself read-only on purpose: the bridge must not believe that.


func descriptor() -> Dictionary:
	return {
		"name": "project_echo",
		"summary": "Returns its argument and the name of the edited scene's root.",
		"risk": "read",
		"params": {"type": "object", "properties": {"text": {"type": "string", "default": "hello"}}},
	}


func run(args: Dictionary, _options: Dictionary) -> Variant:
	var root := EditorInterface.get_edited_scene_root()
	return {"echo": args["text"], "root": "" if root == null else str(root.name)}
