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
# In C#: the Tool attribute, which makes a class run in the editor, and a
# module initializer, which runs when the editor loads the built assembly.
# An attribute can be spread over lines, nested in others or spelled with
# escapes, so the words themselves are looked for, wherever they stand, and
# any escaped character in an identifier counts too: a question too many,
# never one too few.
const _CSHARP_PATTERN := "\\b(?:Tool|ToolAttribute|ModuleInitializer|ModuleInitializerAttribute)\\b|\\\\[uU][0-9a-fA-F]{4}"
const CSHARP_EXTENSION := "cs"

static var _tool_regex: RegEx
static var _csharp_regex: RegEx


## Whether a text contains code that the editor would run by itself.
## `extension` is that of the file the text is for: C# marks such code in
## its own way, which in other files would be ordinary text.
static func runs_in_editor(text: String, extension: String = "") -> bool:
	if _tool_regex == null:
		_tool_regex = RegEx.create_from_string(_TOOL_PATTERN)
		_csharp_regex = RegEx.create_from_string(_CSHARP_PATTERN)
	if extension.to_lower() == CSHARP_EXTENSION:
		return _csharp_regex.search(text) != null
	return _tool_regex.search(text) != null
const NOT_UNDOABLE := "This change is not on the editor's undo stack."


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
