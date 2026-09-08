class_name BattleBuilding
extends StaticBody3D
## Destructible fortification with an authored model and persistent rubble.

signal died(entity: Node3D)
signal sound_requested(kind: StringName, at: Vector3)

const MODELS: Dictionary = {
	"headquarters": preload("res://assets/models/environment/headquarters.tscn"),
	"enemy_keep": preload("res://assets/models/environment/enemy_keep.tscn"),
	"barracks": preload("res://assets/models/environment/barracks.tscn"),
	"tower": preload("res://assets/models/environment/tower.tscn"),
	"house": preload("res://assets/models/environment/house.tscn"),
}

const STATS: Dictionary = {
	"headquarters": {"name": "王国大本营", "hp": 2200.0, "radius": 4.5, "size": Vector3(9, 6, 8), "bar_height": 9.1, "damage": 23.0, "range": 10.0, "cooldown": 2.0, "model": "headquarters"},
	"enemy_keep": {"name": "赤旗要塞", "hp": 1900.0, "radius": 4.5, "size": Vector3(9, 6, 8), "bar_height": 9.5, "damage": 26.0, "range": 10.0, "cooldown": 2.2, "model": "enemy_keep"},
	"barracks": {"name": "敌军兵营", "hp": 950.0, "radius": 3.0, "size": Vector3(6, 4, 5), "bar_height": 5.9, "damage": 0.0, "range": 0.0, "cooldown": 1.0, "model": "barracks"},
	"tower": {"name": "弩箭哨塔", "hp": 800.0, "radius": 2.0, "size": Vector3(4, 7, 4), "bar_height": 8.1, "damage": 28.0, "range": 12.0, "cooldown": 1.8, "model": "tower"},
	"house": {"name": "敌军补给所", "hp": 650.0, "radius": 3.0, "size": Vector3(6, 4, 5), "bar_height": 6.1, "damage": 0.0, "range": 0.0, "cooldown": 1.0, "model": "house"},
}

@export_enum("headquarters", "enemy_keep", "barracks", "tower", "house") var building_type: String = "headquarters"
@export var team: int = 0

var hp: float = 1.0
var max_hp: float = 1.0
var alive: bool = true
var selected: bool = false
var display_name: String = ""
var radius: float = 4.0
var order_name: String = "驻防"
var rally_point: Vector3

var _stats: Dictionary
var _game: Node
var _model: Node3D
var _target: Node3D
var _scan_time: float = 0.0
var _cooldown: float = 1.0
var _target_query: PhysicsShapeQueryParameters3D
var _space_state: PhysicsDirectSpaceState3D

@onready var health_bar: MeshInstance3D = $HealthBar
@onready var selection_ring: MeshInstance3D = $SelectionRing
@onready var model_pivot: Node3D = $ModelPivot

func _ready() -> void:
	_stats = STATS[building_type]
	_game = get_tree().current_scene
	display_name = _stats.name
	max_hp = _stats.hp
	hp = max_hp
	radius = _stats.radius
	collision_layer = 2 | (32 if team == 0 else 64)
	var sight_shape := SphereShape3D.new()
	sight_shape.radius = float(_stats.range) + radius
	_target_query = PhysicsShapeQueryParameters3D.new()
	_target_query.shape = sight_shape
	_target_query.collision_mask = 8 if team == 0 else 16
	_space_state = get_world_3d().direct_space_state
	add_to_group("entities")
	add_to_group("buildings")
	_model = MODELS[_stats.model].instantiate()
	model_pivot.add_child(_model)
	var shape: BoxShape3D = $CollisionShape3D.shape
	shape.size = _stats.size
	$CollisionShape3D.position.y = shape.size.y * 0.5
	selection_ring.scale = Vector3.ONE * radius * 1.45
	var ring_material: StandardMaterial3D = selection_ring.get_surface_override_material(0)
	ring_material.albedo_color = Color("74d5f2") if team == 0 else Color("f26b52")
	health_bar.set_instance_shader_parameter("bar_color", Color("86bf54") if team == 0 else Color("d85549"))
	health_bar.set_instance_shader_parameter("health", 1.0)
	health_bar.position.y = _stats.bar_height
	health_bar.scale.x = radius * 1.25
	$DamageSmoke.position.y = shape.size.y * 0.6
	$ProjectileOrigin.position.y = shape.size.y - 0.4
	$Rubble.scale = Vector3(radius * 0.7, radius * 0.5, radius * 0.7)
	rally_point = global_position + Vector3(5.5, 0, -5.5)
	_scan_time = randf_range(0.0, 0.35)
	set_selected(false)

func _physics_process(delta: float) -> void:
	if not alive or float(_stats.damage) <= 0.0:
		return
	_scan_time -= delta
	_cooldown -= delta
	if _scan_time <= 0.0:
		_scan_time = randf_range(0.3, 0.4)
		_target = null
		var closest: float = pow(float(_stats.range) + radius, 2.0)
		_target_query.transform.origin = global_position + Vector3.UP
		for hit: Dictionary in _space_state.intersect_shape(_target_query, 64):
			var entity: Node3D = hit.collider
			if not entity.alive or entity.team == team:
				continue
			var distance: float = global_position.distance_squared_to(entity.global_position)
			if distance < closest:
				closest = distance
				_target = entity
	if is_instance_valid(_target) and _target.alive and _cooldown <= 0.0:
		_cooldown = _stats.cooldown
		sound_requested.emit(&"bow_release", get_projectile_origin())
		_game.spawn_projectile(self, _target, _stats.damage, "arrow")

func set_selected(value: bool) -> void:
	selected = value and alive
	selection_ring.visible = selected
	health_bar.visible = alive and (selected or hp < max_hp)

func get_attack_position(from_position: Vector3) -> Vector3:
	var local_point: Vector3 = to_local(from_position)
	var half_size: Vector3 = _stats.size * 0.5
	return to_global(Vector3(clampf(local_point.x, -half_size.x, half_size.x), 0.0, clampf(local_point.z, -half_size.z, half_size.z)))

func get_projectile_origin() -> Vector3:
	return $ProjectileOrigin.global_position

func get_hit_effect() -> String:
	return "wood_hit" if building_type in ["tower", "house", "barracks"] else "stone_chip"

func receive_damage(amount: float, source: Node3D = null) -> void:
	if not alive or (is_instance_valid(source) and source.team == team):
		return
	hp = maxf(0.0, hp - amount)
	health_bar.set_instance_shader_parameter("health", hp / max_hp)
	health_bar.show()
	$DamageSmoke.emitting = hp < max_hp * 0.55
	if hp <= 0.0:
		_die()

func _die() -> void:
	alive = false
	order_name = "已摧毁"
	set_selected(false)
	health_bar.hide()
	collision_layer = 0
	collision_mask = 0
	$CollisionShape3D.set_deferred("disabled", true)
	$Rubble.show()
	$DamageSmoke.emitting = false
	_game.spawn_effect(global_position + Vector3.UP * 0.5, "collapse", Color("c5a97d"))
	_game.on_entity_died(self)
	died.emit(self)
	remove_from_group("entities")
	remove_from_group("buildings")
	var collapse: Tween = create_tween().set_parallel(true)
	collapse.tween_property(model_pivot, "position:y", -1.0, 1.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	collapse.tween_property(model_pivot, "scale", Vector3(1.08, 0.08, 1.08), 1.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	collapse.tween_property(model_pivot, "rotation:z", 0.11, 1.25)
	collapse.chain().tween_callback(model_pivot.hide)
