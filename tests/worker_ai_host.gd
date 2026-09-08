extends Node3D
## Isolated battlefield fixture using the production unit/building/projectile scenes.
const PROJECTILE_SCENE: PackedScene = preload("res://scenes/projectile.tscn")
const EFFECT_SCENE: PackedScene = preload("res://scenes/battle_effect.tscn")
var gathered_gold: int = 0

func spawn_projectile(source: Node3D, target: Node3D, damage: float, kind: String) -> void:
	var projectile: Node3D = PROJECTILE_SCENE.instantiate()
	$Effects.add_child(projectile)
	projectile.initialize(source, target, damage, kind)

func spawn_effect(at: Vector3, kind: String, color: Color = Color.WHITE) -> void:
	var effect: Node3D = EFFECT_SCENE.instantiate()
	$Effects.add_child(effect)
	effect.global_position = at
	effect.initialize(kind, color)

func on_entity_died(_entity: Node3D) -> void:
	pass

func on_gathered(_worker: Node3D, amount: int) -> void:
	gathered_gold += amount
