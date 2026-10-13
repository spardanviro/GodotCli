extends Node


func pick(kind: String) -> String:
	var plain := "res://tests/fixtures/notes.txt"
	var prefixed := "res://tests/fixtures/move_" + kind + ".gd"
	return "res://tests/fixtures/%s_target.gd" % kind + plain + prefixed
