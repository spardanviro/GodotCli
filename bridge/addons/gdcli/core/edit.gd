extends RefCounted
## Helpers shared by the commands that change something.

const AccessPolicy = preload("access_policy.gd")
const Reply = preload("reply.gd")

const UNDO_PREFIX := "gdcli: "
const NOT_UNDOABLE := "This change is not on the editor's undo stack."


## The reply to a dry run: what the command would do, with nothing done.
static func planned(would: Dictionary) -> Dictionary:
	return Reply.ok({"dry_run": true, "would": would})


## For targets that are sensitive whatever the command's own tier is
## (docs/protocol.md section 4.4). Returns {} when the request may proceed.
static func confirmation_gate(options: Dictionary, what: String) -> Dictionary:
	if options.get("mode", AccessPolicy.MODE_STANDARD) == AccessPolicy.MODE_FULL or options.get("confirm", false):
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


## A successful reply that names the undo step it created.
static func done(data: Variant, undo_name: String, warnings: Array = []) -> Dictionary:
	var reply := Reply.ok(data, warnings)
	reply["undo"] = undo_name
	return reply


static func undo_name(command: String, subject: String) -> String:
	return "%s%s %s" % [UNDO_PREFIX, command, subject]
