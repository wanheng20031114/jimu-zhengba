class_name MovementPlan
extends RefCounted
## Shared macro destination. Each unit retains its own final formation slot.
## Queued orders hold this intent without reserving a field or worker task.

var goal: Vector3
var radius: float
var entry: RefCounted

func _init(at: Vector3 = Vector3.ZERO, body_radius: float = 0.5) -> void:
	goal = at
	radius = body_radius
