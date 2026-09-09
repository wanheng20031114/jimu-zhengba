extends Node3D
## Minimal authoritative fixture; all entities and projectiles use production scenes.
const PROJECTILE_SCENE: PackedScene = preload("res://scenes/projectile.tscn")
var is_authority: bool = true
var players: Array[PlayerState] = [PlayerState.new(0, 0), PlayerState.new(1, 1), PlayerState.new(2, 0), PlayerState.new(3, 1)]
var hidden_entities: Dictionary = {}
var next_id: int = 1
var gathered_gold: int = 0
var projectile_count: int = 0

func register_entity(entity: Node3D) -> void:
	entity.entity_id = next_id
	next_id += 1

func get_player(owner: int) -> PlayerState:
	return players[owner]

func are_hostile(a: Node3D, b: Node3D) -> bool:
	return a.alliance_id != b.alliance_id

func can_see_entity(_owner: int, entity: Node3D) -> bool:
	return not hidden_entities.has(entity.entity_id)

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
