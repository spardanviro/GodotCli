extends RefCounted
## Base class for unit test suites. Methods named test_* are run by run_tests.gd.

var failures: Array[String] = []


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func equal(actual: Variant, expected: Variant, message: String = "") -> void:
	if typeof(actual) != typeof(expected) or actual != expected:
		failures.append("%s: expected %s, got %s" % [message, var_to_str(expected), var_to_str(actual)])


## Called after each test so suites can free the nodes they built.
func cleanup() -> void:
	pass
