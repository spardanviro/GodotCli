extends "res://tests/suite.gd"

const AccessPolicy = preload("res://addons/gdcli/core/access_policy.gd")


func _code(risk: String, mode: String, allow_eval: bool, confirm: bool) -> String:
	var denied := AccessPolicy.decide(risk, mode, allow_eval, confirm)
	return "" if denied.is_empty() else denied["error"]["code"]


func test_access_policy_read_is_allowed_in_every_mode() -> void:
	for mode in AccessPolicy.MODES:
		equal(_code("read", mode, false, false), "", mode)


func test_access_policy_readonly_denies_everything_but_read() -> void:
	for risk in ["write", "destructive", "exec"]:
		equal(_code(risk, "readonly", true, true), "READONLY_MODE", risk)


func test_access_policy_write_is_allowed_without_confirmation() -> void:
	equal(_code("write", "standard", false, false), "", "standard")
	equal(_code("write", "full", false, false), "", "full")


func test_access_policy_destructive_needs_confirmation_in_standard() -> void:
	equal(_code("destructive", "standard", false, false), "CONFIRMATION_REQUIRED", "unconfirmed")
	equal(_code("destructive", "standard", false, true), "", "confirmed")
	equal(_code("destructive", "full", false, false), "", "full mode")


func test_access_policy_exec_needs_the_eval_switch_in_every_mode() -> void:
	equal(_code("exec", "standard", false, true), "EVAL_DISABLED", "standard")
	equal(_code("exec", "full", false, true), "EVAL_DISABLED", "full")


func test_access_policy_exec_needs_confirmation_in_standard() -> void:
	equal(_code("exec", "standard", true, false), "CONFIRMATION_REQUIRED", "unconfirmed")
	equal(_code("exec", "standard", true, true), "", "confirmed")
	equal(_code("exec", "full", true, false), "", "full mode")


func test_access_policy_unknown_risk_is_an_internal_error() -> void:
	equal(_code("harmless", "full", true, true), "INTERNAL_ERROR", "unknown tier")


func test_access_policy_unknown_mode_falls_back_to_readonly() -> void:
	equal(AccessPolicy.normalize_mode("ask"), "readonly", "reserved mode")
	equal(AccessPolicy.normalize_mode(null), "readonly", "missing")
	equal(AccessPolicy.normalize_mode(3), "readonly", "wrong type")
	equal(AccessPolicy.normalize_mode("full"), "full", "known mode")
