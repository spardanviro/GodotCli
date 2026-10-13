extends RefCounted
## Risk tiers against the access mode (docs/protocol.md section 4.3).
## In "ask" mode a person at the editor confirms what "standard" lets the
## caller confirm for itself.

const Reply = preload("reply.gd")

const MODE_READONLY := "readonly"
const MODE_STANDARD := "standard"
const MODE_ASK := "ask"
const MODE_FULL := "full"
const MODES: Array[String] = [MODE_READONLY, MODE_STANDARD, MODE_ASK, MODE_FULL]

const RISK_READ := "read"
const RISK_WRITE := "write"
const RISK_DESTRUCTIVE := "destructive"
const RISK_EXEC := "exec"
const RISKS: Array[String] = [RISK_READ, RISK_WRITE, RISK_DESTRUCTIVE, RISK_EXEC]


## An unrecognised value fails closed.
static func normalize_mode(value: Variant) -> String:
	if value is String and value in MODES:
		return value
	return MODE_READONLY


## Returns {} when the command may run, otherwise a failed reply.
## A dry run changes nothing, so it is never asked for a confirmation; it is
## still subject to read-only mode and to the eval switch.
## Whether the bridge has to ask a person before running the command at all.
static func asks_person(risk: String, mode: String, dry_run: bool) -> bool:
	return mode == MODE_ASK and not dry_run and risk in [RISK_DESTRUCTIVE, RISK_EXEC]


static func decide(risk: String, mode: String, allow_eval: bool, confirm: bool, dry_run: bool = false) -> Dictionary:
	if risk not in RISKS:
		return Reply.fail("INTERNAL_ERROR", "The command declares an unknown risk tier.")
	if risk == RISK_READ:
		return {}
	if mode == MODE_READONLY:
		return Reply.fail(
			"READONLY_MODE",
			"The bridge is in read-only mode.",
			"The access mode is changed in the editor settings under gdcli/access/mode.",
		)
	if risk == RISK_WRITE:
		return {}
	if risk == RISK_EXEC and not allow_eval:
		return Reply.fail(
			"EVAL_DISABLED",
			"Running code through the bridge is turned off.",
			"It is enabled in the editor settings under gdcli/access/allow_eval.",
		)
	# In ask mode the bridge puts the question to a person instead.
	if mode == MODE_STANDARD and not confirm and not dry_run:
		return Reply.fail(
			"CONFIRMATION_REQUIRED",
			"This command needs explicit confirmation.",
			"Review the effect with dry_run, then repeat with confirm set to true (gd: --yes).",
		)
	return {}
