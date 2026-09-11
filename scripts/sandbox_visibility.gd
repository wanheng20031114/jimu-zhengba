extends FogOfWar
## The offline sandbox has no hidden information or fog allocation.

func _ready() -> void:
	overlay.hide()

func position_visible_to_alliance(_alliance: int, _at: Vector3) -> bool:
	return true

func building_visible_to_alliance(_alliance: int, _building: BattleBuilding) -> bool:
	return true
