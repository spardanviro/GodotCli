extends Node

var ticks := 0
var last := 0


func _process(_delta: float) -> void:
	ticks += 1
	_tick(ticks)


func _tick(count: int) -> void:
	var doubled := count * 2
	last = doubled


func add(a: int, b: int) -> int:
	return a + b


func complain() -> void:
	push_error("ticker complains on purpose")


func crash() -> void:
	var nothing: Node = null
	nothing.queue_free()


func _ready() -> void:
	print("ticker ready")
