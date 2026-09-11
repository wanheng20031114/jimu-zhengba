extends Node3D
## Minimal authoritative fixture; all entities and projectiles use production scenes.
const PROJECTILE_SCENE: PackedScene = preload("res://scenes/projectile.tscn")
var is_authority: bool = true
var local_owner_id: int = 0
var finished: bool = false
var players: Array[PlayerState] = [PlayerState.new(0, 0), PlayerState.new(1, 1), PlayerState.new(2, 0), PlayerState.new(3, 1)]
var automatic_vision: bool = true
var next_id: int = 1
var gathered_gold: int = 0
var projectile_count: int = 0

@onready var combat_fog: FogOfWar = $FogOfWar

func _ready() -> void:
	combat_fog.configure(self, Vector2(80, 80))

func _physics_process(delta: float) -> void:
	if automatic_vision:
		combat_fog.tick(delta)

func register_entity(entity: Node3D) -> void:
	entity.entity_id = next_id
	next_id += 1
	if automatic_vision:
		combat_fog._recompute()

func get_player(owner: int) -> PlayerState:
	return players[owner]

func presentation_faction(owner: int, alliance: int) -> int:
	if owner == local_owner_id:
		return FactionPalette.SELF
	return FactionPalette.ALLY if alliance == get_player(local_owner_id).alliance_id else FactionPalette.ENEMY

func are_hostile(a: Node3D, b: Node3D) -> bool:
	return a.alliance_id != b.alliance_id

func can_see_entity(owner: int, entity: Node3D) -> bool:
	return combat_fog.entity_visible(owner, entity)

func can_see_position(owner: int, at: Vector3) -> bool:
	return combat_fog.position_visible(owner, at)

func suspend_alliance_vision(alliance: int) -> void:
	# Publish a remembered-only native mask, then freeze its update while a
	# committed windup tests loss of vision independently of target distance.
	automatic_vision = false
	var remembered: PackedByteArray = combat_fog._cells[alliance]
	remembered.fill(1)
	combat_fog._cells[alliance] = remembered

func resume_vision() -> void:
	automatic_vision = true
	combat_fog._recompute()

func clamp_to_map(at: Vector3) -> Vector3:
	return Vector3(clampf(at.x, -40.0, 40.0), 0.0, clampf(at.z, -40.0, 40.0))

func spawn_projectile(source: Node3D, target: Node3D, payload: DamagePayload, kind: String) -> void:
	var projectile: Node3D = PROJECTILE_SCENE.instantiate()
	$Effects.add_child(projectile)
	projectile.initialize(source, target, payload, kind)
	projectile_count += 1

func spawn_effect(_at: Vector3, _kind: String, _color: Color = Color.WHITE) -> void:
	pass

func on_entity_died(_entity: Node3D) -> void:
	pass

func on_gathered(_worker: Node3D, amount: int) -> void:
	gathered_gold += amount
