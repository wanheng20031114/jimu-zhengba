extends Node3D
## Actual authored combat scenes; only the match coordinator is replaced.

const UNIT_SCENE = preload("res://scenes/unit.tscn")
const BUILDING_SCENE = preload("res://scenes/building.tscn")

var players: Array[PlayerState] = []
var entities_by_id: Dictionary = {}
var local_owner_id: int = 0
var is_authority: bool = false
var simulation_tick: int = 0
var elapsed: float = 0.0
var finished: bool = false
var visible_ids: Array[int] = []
var deaths: int = 0
var effects: int = 0
var _next_id: int = 1

func _init() -> void:
	for owner in range(4):
		players.append(PlayerState.new(owner, 0 if owner < 2 else 1))
		players[owner].gold = 700 + owner

func _enter_tree() -> void:
	get_tree().current_scene = self

func _ready() -> void:
	$FogOfWar.configure(self, Vector2(80, 80))

func get_player(owner: int) -> PlayerState:
	return players[owner]

func presentation_faction(owner: int, alliance: int) -> int:
	if owner == local_owner_id:
		return FactionPalette.SELF
	return FactionPalette.ALLY if alliance == get_player(local_owner_id).alliance_id else FactionPalette.ENEMY

func register_entity(entity: Node3D) -> void:
	if entity.entity_id == 0:
		entity.entity_id = _next_id
	_next_id = maxi(_next_id, entity.entity_id + 1)
	entities_by_id[entity.entity_id] = entity

func can_see_entity(_owner: int, entity: Node3D) -> bool:
	return entity.entity_id in visible_ids

func can_see_position(_owner: int, _at: Vector3) -> bool:
	return true

func spawn_unit(kind: String, owner: int, at: Vector3, id: int = 0) -> BattleUnit:
	var unit: BattleUnit = UNIT_SCENE.instantiate()
	unit.unit_type = kind
	unit.owner_id = owner
	unit.alliance_id = get_player(owner).alliance_id
	unit.entity_id = id
	unit.position = at
	add_child(unit)
	unit.set_physics_process(false)
	unit.navigation_agent.avoidance_enabled = false
	return unit

func spawn_building(kind: String, owner: int, at: Vector3, construction: bool = false, id: int = 0) -> BattleBuilding:
	var building: BattleBuilding = BUILDING_SCENE.instantiate()
	building.building_type = kind
	building.owner_id = owner
	building.entity_id = id
	building.position = at
	building.under_construction = construction
	add_child(building)
	building.set_physics_process(false)
	building.production.set_physics_process(false)
	return building

func on_entity_died(_entity: Node3D) -> void:
	deaths += 1

func forget_entity_selection(_entity: Node3D) -> void:
	# This transport fixture has no selection/HUD. The real-game lifecycle
	# regression covers synchronous selection, control-group and click cleanup.
	pass

func spawn_effect(_at: Vector3, _kind: String, _color: Color = Color.WHITE) -> void:
	effects += 1

func notify_owner(_owner: int, _message: String) -> void:
	pass
