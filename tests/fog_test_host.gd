extends "res://tests/balance_combat_host.gd"

@onready var fog: Node3D = $FogOfWar

func can_see_entity(owner: int, entity: Node3D) -> bool:
	return fog.entity_visible(owner, entity)

func can_see_position(owner: int, at: Vector3) -> bool:
	return fog.position_visible(owner, at)

