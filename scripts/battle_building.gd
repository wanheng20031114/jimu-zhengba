class_name BattleBuilding
extends StaticBody3D
## Destructible fortification with an authored model and persistent rubble.

signal died(entity: Node3D)
signal sound_requested(kind: StringName, at: Vector3)
signal construction_completed(site: Node3D)

const CONSTRUCTION_SECONDS: float = 20.0
const CONSTRUCTION_COST: int = 100
const BUILD_REACH: float = 1.9

const MODELS: Dictionary = {
	"headquarters": preload("res://assets/models/environment/headquarters.tscn"),
	"enemy_keep": preload("res://assets/models/environment/enemy_keep.tscn"),
	"barracks": preload("res://assets/models/environment/player_barracks.tscn"),
	"factory": preload("res://assets/models/environment/factory.tscn"),
	"academy": preload("res://assets/models/environment/academy.tscn"),
	"tower": preload("res://assets/models/environment/tower.tscn"),
	"house": preload("res://assets/models/environment/house.tscn"),
}

@export_enum("headquarters", "enemy_keep", "barracks", "tower", "house", "defense_tower", "factory", "academy") var building_type: String = "headquarters"
@export var team: int = 0
@export var owner_id: int = -1
var alliance_id: int = 0
var entity_id: int = 0
@export var under_construction: bool = false

var hp: float = 1.0
var max_hp: float = 1.0
var alive: bool = true
var selected: bool = false
var display_name: String = ""
var radius: float = 4.0
var order_name: String = "驻防"
var rally_point: Vector3
var construction_progress: float = 0.0
var is_constructed: bool:
	get:
		return alive and not under_construction

var _stats: BuildingDefinition
var _game: Node
var _model: Node3D
var _target: Node3D
var _scan_time: float = 0.0
var _cooldown: float = 1.0
var _target_query: PhysicsShapeQueryParameters3D
var _space_state: PhysicsDirectSpaceState3D
var _builder: WeakRef
var _construction_meshes: Array[MeshInstance3D] = []

@onready var health_bar: MeshInstance3D = $HealthBar
@onready var selection_ring: MeshInstance3D = $SelectionRing
@onready var model_pivot: Node3D = $ModelPivot
@onready var construction_bar: MeshInstance3D = $ConstructionBar
@onready var scaffolding: Node3D = $ModelPivot/Scaffolding
@onready var production: BuildingProduction = $Production

func _ready() -> void:
	_stats = BalanceCatalog.building(building_type)
	_game = get_tree().current_scene
	if owner_id < 0:
		owner_id = team
	alliance_id = _game.get_player(owner_id).alliance_id
	team = alliance_id
	_game.register_entity(self)
	display_name = _stats.name
	max_hp = _stats.hp
	hp = max_hp
	radius = _stats.radius
	collision_layer = 2 | (32 if team == 0 else 64)
	var sight_shape := SphereShape3D.new()
	var half_diagonal: float = Vector2(_stats.size.x, _stats.size.z).length() * 0.5
	sight_shape.radius = float(_stats.range) + half_diagonal
	_target_query = PhysicsShapeQueryParameters3D.new()
	_target_query.shape = sight_shape
	_target_query.collision_mask = 8 if team == 0 else 16
	_space_state = get_world_3d().direct_space_state
	add_to_group("entities")
	add_to_group("buildings")
	if building_type == "defense_tower":
		_model = $ModelPivot/DefenseTower
		_model.show()
		for mesh: MeshInstance3D in _model.find_children("*", "MeshInstance3D", true, false):
			_construction_meshes.append(mesh)
	else:
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
	construction_progress = 0.0 if under_construction else 1.0
	if under_construction:
		hp = max_hp * 0.1
		order_name = "等待施工"
	else:
		order_name = "自动防御" if float(_stats.damage) > 0.0 else "待命"
	construction_bar.position.y = float(_stats.bar_height) - 0.4
	construction_bar.scale.x = radius * 1.25
	construction_bar.set_instance_shader_parameter("bar_color", Color("e5b94d"))
	_update_construction_visuals()
	set_selected(false)
	reset_physics_interpolation()

func _physics_process(delta: float) -> void:
	if not _game.is_authority or not alive or under_construction or float(_stats.damage) <= 0.0:
		return
	_scan_time -= delta
	_cooldown -= delta
	if _scan_time <= 0.0:
		_scan_time = randf_range(0.3, 0.4)
		_target = null
		var closest: float = INF
		_target_query.transform.origin = global_position + Vector3.UP
		for hit: Dictionary in _space_state.intersect_shape(_target_query, 64):
			var entity: Node3D = hit.collider
			if not _can_shoot_target(entity):
				continue
			var distance: float = global_position.distance_squared_to(entity.global_position)
			if distance < closest:
				closest = distance
				_target = entity
	# A target may walk out between the staggered scan and the next shot.
	# Match unit attacks: range starts at the wall and ends at the target's
	# outside edge. Recheck this exact range and faction on every release.
	if _can_shoot_target(_target) and _cooldown <= 0.0:
		_cooldown = _stats.cooldown
		sound_requested.emit(&"bow_release", get_projectile_origin())
		_game.spawn_projectile(self, _target, DamageResolver.snapshot(_stats, 0, owner_id, alliance_id), "arrow")

func _can_shoot_target(entity: Node3D) -> bool:
	if not is_instance_valid(entity) or not entity.alive or entity.alliance_id == alliance_id:
		return false
	var offset: Vector3 = entity.global_position - get_attack_position(entity.global_position)
	offset.y = 0.0
	return offset.length_squared() <= pow(float(_stats.range) + entity.radius, 2.0)

func try_claim_builder(worker: Node3D) -> bool:
	if not alive or not under_construction or not is_instance_valid(worker):
		return false
	if not worker.alive or worker.owner_id != owner_id or worker.unit_type != "farmer":
		return false
	var assigned: Node3D = _builder.get_ref() if _builder != null else null
	if is_instance_valid(assigned) and assigned.alive and assigned != worker:
		var separation: Vector3 = assigned.global_position - get_attack_position(assigned.global_position)
		separation.y = 0.0
		if separation.length_squared() <= pow(BUILD_REACH + 0.5, 2.0):
			return false
	_builder = weakref(worker)
	return true

func release_builder(worker: Node3D) -> void:
	if _builder != null and _builder.get_ref() == worker:
		_builder = null
		if alive and under_construction:
			order_name = "等待施工"

func contribute_work(worker: Node3D, delta: float) -> void:
	if not alive or not under_construction or delta <= 0.0 or _builder == null:
		return
	if _builder.get_ref() != worker or not is_instance_valid(worker) or not worker.alive:
		return
	if worker.owner_id != owner_id or worker.unit_type != "farmer":
		return
	var contact: Vector3 = get_attack_position(worker.global_position)
	var offset: Vector3 = worker.global_position - contact
	offset.y = 0.0
	if offset.length_squared() > BUILD_REACH * BUILD_REACH:
		order_name = "等待农民抵达"
		return
	var previous: float = construction_progress
	construction_progress = minf(1.0, construction_progress + delta / _stats.build_seconds)
	# Construction adds the remaining structural HP, preserving enemy damage.
	hp = minf(max_hp, hp + (construction_progress - previous) * max_hp * 0.9)
	if hp >= max_hp * 0.55:
		$DamageSmoke.emitting = false
	order_name = "建造中 · %d%%" % int(construction_progress * 100.0)
	_update_construction_visuals()
	if construction_progress >= 1.0 - 0.00001:
		construction_progress = 1.0
		under_construction = false
		_builder = null
		order_name = "自动防御"
		_cooldown = 0.25
		_scan_time = 0.0
		_update_construction_visuals()
		construction_completed.emit(self)

func cancel_construction() -> int:
	if not alive or not under_construction:
		return 0
	var refund: int = floori(_stats.cost * (1.0 - construction_progress) + 0.00001)
	_die()
	return refund

func demolish() -> bool:
	if not alive or building_type != "defense_tower" or under_construction:
		return false
	_die()
	return true

func _update_construction_visuals() -> void:
	scaffolding.visible = alive and under_construction
	construction_bar.visible = alive and under_construction
	construction_bar.set_instance_shader_parameter("health", construction_progress)
	health_bar.set_instance_shader_parameter("health", hp / max_hp)
	health_bar.visible = alive and (selected or hp < max_hp)
	for mesh: MeshInstance3D in _construction_meshes:
		mesh.set_instance_shader_parameter("construction_progress", construction_progress)
	if building_type != "defense_tower":
		_model.scale.y = 0.08 + construction_progress * 0.92
	scaffolding.scale = Vector3(_stats.size.x / 4, 1, _stats.size.z / 4)

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
	return "wood_hit" if building_type in ["tower", "house", "barracks", "defense_tower"] else "stone_chip"

func get_combat_definition() -> CombatDefinition:
	return _stats

func receive_hit(payload: DamagePayload, source: Node3D = null, falloff: float = 1.0) -> void:
	if payload.alliance_id == alliance_id:
		return
	receive_damage(DamageResolver.resolve(payload, _stats, 0, falloff), source)

func receive_damage(amount: float, source: Node3D = null) -> void:
	if not alive or (is_instance_valid(source) and source.alliance_id == alliance_id):
		return
	hp = maxf(0.0, hp - amount)
	health_bar.set_instance_shader_parameter("health", hp / max_hp)
	health_bar.show()
	$DamageSmoke.emitting = hp < max_hp * 0.55
	if hp <= 0.0:
		_die()

func _die() -> void:
	alive = false
	production.destroyed()
	_builder = null
	order_name = "已摧毁"
	set_selected(false)
	health_bar.hide()
	construction_bar.hide()
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
	# The five authored ruins belong to the map. Player-created sites are
	# unbounded, so retire their full node hierarchy after the debris settles.
	$DebrisLifetime.start()
	var collapse: Tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS).set_parallel(true)
	collapse.tween_property(model_pivot, "position:y", -1.0, 1.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	collapse.tween_property(model_pivot, "scale", Vector3(1.08, 0.08, 1.08), 1.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	collapse.tween_property(model_pivot, "rotation:z", 0.11, 1.25)
	collapse.chain().tween_callback(model_pivot.hide)

func _on_debris_timeout() -> void:
	queue_free()
