extends RefCounted
## Helpers shared by the commands that change something.

const AccessPolicy = preload("access_policy.gd")
const Approval = preload("approval.gd")
const Reply = preload("reply.gd")

const UNDO_PREFIX := "gdcli: "
# The tool annotation anywhere in a text: in a script wherever it stands (it
# may share a line with other annotations), or in the source of a script
# embedded in a scene or resource file. A mention in a comment matches too;
# the cost of that is one question too many, never one too few.
const _TOOL_PATTERN := "@[\\s\\\\]*tool\\b"
# Any C# at all: once built, the editor runs more of it than the marks say.
# Tried on a .NET editor (scripts/dotnet-probe.mjs): besides a [Tool] class
# and a [ModuleInitializer], the field initializer of an ordinary class runs
# there too, when the editor reads the class's exported defaults. A build
# needs nothing but `editor_play`, so every C# file waits for a person.
const CSHARP_EXTENSION := "cs"
# A script embedded in a scene or resource file. Its source is a string the
# text parser unescapes (`@\u0074ool`), so the pattern above may not see a
# tool annotation in it: any embedded script counts.
const _EMBEDDED_SCRIPT_PATTERN := "script/source\\s*=|type\\s*=\\s*\"(?:GDScript|CSharpScript)\""
const _TEXT_RESOURCE_EXTENSIONS: Array[String] = ["tscn", "tres", "escn"]

static var _tool_regex: RegEx


## Whether a text contains code that the editor would run by itself.
## `extension` is that of the file the text is for: every C# file counts.
static func runs_in_editor(text: String, extension: String = "") -> bool:
	if extension.to_lower() == CSHARP_EXTENSION:
		return true
	if extension.to_lower() in _TEXT_RESOURCE_EXTENSIONS and RegEx.create_from_string(_EMBEDDED_SCRIPT_PATTERN).search(text) != null:
		return true
	if _tool_regex == null:
		_tool_regex = RegEx.create_from_string(_TOOL_PATTERN)
	return _tool_regex.search(text) != null
const NOT_UNDOABLE := "This change is not on the editor's undo stack."
# ClassDB.APIType.API_CORE (the method that tells it is newer than 4.3).
const _API_CORE := 0
# ClassDB.APIType.API_EXTENSION: node classes of a GDExtension the game ships.
const _API_EXTENSION := 2
const ACTIVE_EXPRESSIONS := "an active animation tree evaluates its transitions' expressions in the editor too"
# State machines and blend trees nest; deeper than this no tree goes.
const _MAX_TREE_DEPTH := 16


## A built-in node class a game scene can hold. Editor classes (EditorPlugin,
## EditorInspector, ...) can be made inside the editor, but a scene saved with
## one does not load in the exported game.
static func is_game_node_class(type: String) -> bool:
	if not (ClassDB.class_exists(type) and ClassDB.is_parent_class(type, "Node") and ClassDB.can_instantiate(type)):
		return false
	if ClassDB.has_method("class_get_api_type"):
		return ClassDB.call("class_get_api_type", type) in [_API_CORE, _API_EXTENSION]
	return not type.begins_with("Editor")


## The transition expressions anywhere in an animation tree (nested state
## machines and blend trees included). Each is code evaluated by the tree.
static func animation_expressions(root: Object, depth: int = 0) -> PackedStringArray:
	var found := PackedStringArray()
	if root == null:
		return found
	# Deeper than can be looked at: taken as holding an expression, never as clean.
	if depth > _MAX_TREE_DEPTH:
		found.append("(nested deeper than can be checked)")
		return found
	if root is AnimationNodeStateMachine:
		for index in root.get_transition_count():
			var expression: String = root.get_transition(index).advance_expression
			if expression != "":
				found.append(expression)
	for property in root.get_property_list():
		var value: Variant = root.get(property["name"])
		if value is AnimationRootNode and value != root:
			found.append_array(animation_expressions(value, depth + 1))
	return found


## For a node about to be (or become) an active animation tree with
## expressions: a person allows it. {} when the change may go on.
static func expression_gate(context: RefCounted, options: Dictionary, active: bool, root: Variant, target: String, retry: Callable, command: String) -> Dictionary:
	if not active or not root is Object:
		return {}
	var expressions := animation_expressions(root)
	if expressions.is_empty():
		return {}
	var what := {"command": command, "reason": ACTIVE_EXPRESSIONS, "target": target, "preview": "\n".join(expressions)}
	return person_gate(context, options, what, retry)


## The reply to a dry run: what the command would do, with nothing done.
static func planned(would: Dictionary) -> Dictionary:
	return Reply.ok({"dry_run": true, "would": would})


## For targets that are sensitive whatever the command's own tier is
## (docs/protocol.md section 4.4). Returns {} when the request may proceed.
static func confirmation_gate(options: Dictionary, what: String) -> Dictionary:
	if options.get("mode", AccessPolicy.MODE_STANDARD) == AccessPolicy.MODE_FULL or options.get("confirm", false):
		return {}
	if options.get("approved", false):
		return {}
	# A dry run is the way to look before confirming.
	if options.get("dry_run", false):
		return {}
	return Reply.fail(
		"CONFIRMATION_REQUIRED",
		"This target needs explicit confirmation.",
		"Review the effect with dry_run, then repeat with confirm set to true (gd: --yes).",
		{"reason": what},
	)


## For changes that can run code in the editor or change what it loads: a
## tool script, a file under addons/, an autoload, code to evaluate. Outside
## full mode a person at the editor has to allow them; `confirm` from the
## caller is not enough, because the caller can always send it.
## Returns {} when the command may go on. Otherwise returns a reply that
## waits for the person and then calls `retry`, which is the same handler bound
## to its arguments and to `approved(options)`.
static func person_gate(context: RefCounted, options: Dictionary, what: Dictionary, retry: Callable) -> Dictionary:
	if options.get("mode", AccessPolicy.MODE_STANDARD) == AccessPolicy.MODE_FULL:
		return {}
	# A dry run changes nothing; a person who has said yes is not asked again.
	if options.get("dry_run", false) or options.get("approved", false):
		return {}
	# A batch runs without stopping for anyone: the step is refused, and the batch undoes what it did.
	if options.get("in_batch", false):
		return Reply.fail("PRECONDITION_FAILED", "This step needs a person's approval, which a batch does not ask for.", "Run that command on its own.")
	return Reply.later(Approval.new(context, what, retry), true)


## The options for the second run of a handler, after a person said yes.
static func approved(options: Dictionary) -> Dictionary:
	var allowed := options.duplicate()
	allowed["approved"] = true
	return allowed


## A successful reply that names the undo step it created.
static func done(data: Variant, undo_name: String, warnings: Array = []) -> Dictionary:
	var reply := Reply.ok(data, warnings)
	reply["undo"] = undo_name
	return reply


static func undo_name(command: String, subject: String) -> String:
	return "%s%s %s" % [UNDO_PREFIX, command, subject]
