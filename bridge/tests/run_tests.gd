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
		var names: Array[String] = []
		var listing: RefCounted = script.new()
		for method in listing.get_method_list():
			if str(method["name"]).begins_with("test_"):
				names.append(method["name"])
		for name in names:
			total += 1
			# A fresh suite for every test: nothing one test leaves behind reaches the next.
			var suite: RefCounted = script.new()
			suite.call(name)
			suite.cleanup()
			if not suite.failures.is_empty():
				failed += 1
				for failure in suite.failures:
					print("FAIL %s.%s: %s" % [file.get_basename(), name, failure])
	print("gdcli unit tests: %d run, %d failed" % [total, failed])
	quit(1 if failed > 0 or total == 0 else 0)
