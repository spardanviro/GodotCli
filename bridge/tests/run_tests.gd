extends SceneTree
## Runs every tests/unit/test_*.gd suite without starting the editor:
##   godot --headless --path bridge --script res://tests/run_tests.gd

const UNIT_DIR := "res://tests/unit/"


func _initialize() -> void:
	var failed := 0
	var total := 0
	var files := Array(DirAccess.get_files_at(UNIT_DIR))
	files.sort()
	for file in files:
		if not (file.begins_with("test_") and file.ends_with(".gd")):
			continue
		var script: GDScript = load(UNIT_DIR + file)
		if script == null or not script.can_instantiate():
			print("FAIL %s: the suite does not compile" % file)
			failed += 1
			total += 1
			continue
		var suite: RefCounted = script.new()
		for method in suite.get_method_list():
			var name: String = method["name"]
			if not name.begins_with("test_"):
				continue
			total += 1
			suite.failures.clear()
			suite.call(name)
			suite.cleanup()
			if not suite.failures.is_empty():
				failed += 1
				for failure in suite.failures:
					print("FAIL %s.%s: %s" % [file.get_basename(), name, failure])
	print("gdcli unit tests: %d run, %d failed" % [total, failed])
	quit(1 if failed > 0 or total == 0 else 0)
