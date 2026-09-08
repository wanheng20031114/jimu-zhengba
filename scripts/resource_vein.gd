class_name ResourceVein
extends StaticBody3D
## A permanent resource deposit: no military target, depletion or delivery trip.

const radius: float = 2.2
const team: int = -1
const alive: bool = true
const display_name: String = "黄金矿脉"
const order_name: String = "每位农民每3秒采集3金币 · 无需运输"
var selected: bool = false

func _ready() -> void:
	add_to_group("resource_veins")

func set_selected(value: bool) -> void:
	selected = value
	$SelectionRing.visible = value

func get_work_position(from_position: Vector3) -> Vector3:
	var outward: Vector3 = from_position - global_position
	outward.y = 0.0
	if outward.length_squared() < 0.01:
		outward = Vector3.RIGHT
	return global_position + outward.normalized() * (radius + 1.45)
