class_name BattleUnit
extends CharacterBody3D
## Controllable combat entity. Geometry lives in the authored unit model scenes.

signal died(entity: Node3D)
signal damaged(entity: Node3D, amount: float)

const MODELS: Dictionary = {
	"swordsman": preload("res://assets/models/units/swordsman.tscn"),
	"archer": preload("res://assets/models/units/archer.tscn"),
	"knight": preload("res://assets/models/units/knight.tscn"),
	"catapult": preload("res://assets/models/units/catapult.tscn"),
	"cannon": preload("res://assets/models/units/cannon.tscn"),
}

const STATS: Dictionary = {
	"swordsman": {"name": "剑士", "description": "坚守阵线的近战步兵，持剑盾抵挡敌军。", "cost": 45, "hp": 155.0, "speed": 3.7, "damage": 23.0, "range": 1.0, "cooldown": 1.05, "radius": 0.48, "armor": 2.0, "sight": 10.0, "projectile": ""},
	"archer": {"name": "弓箭手", "description": "在后排抛射羽箭，适合协同近战部队作战。", "cost": 60, "hp": 85.0, "speed": 3.6, "damage": 20.0, "range": 10.0, "cooldown": 1.5, "radius": 0.42, "armor": 0.0, "sight": 13.0, "projectile": "arrow"},
	"knight": {"name": "骑士", "description": "重甲骑兵，连续奔驰后发动高伤害冲锋。", "cost": 100, "hp": 320.0, "speed": 6.1, "damage": 39.0, "range": 1.2, "cooldown": 1.35, "radius": 0.78, "armor": 5.0, "sight": 12.0, "projectile": ""},
	"catapult": {"name": "投石车", "description": "抛射巨石，对密集敌军和建筑造成范围伤害。", "cost": 140, "hp": 230.0, "speed": 2.2, "damage": 67.0, "range": 17.0, "cooldown": 4.2, "radius": 1.05, "armor": 2.0, "sight": 19.0, "projectile": "stone"},
	"cannon": {"name": "加农炮", "description": "发射爆炸炮弹，擅长轰击敌方防御建筑。", "cost": 180, "hp": 285.0, "speed": 2.0, "damage": 96.0, "range": 15.0, "cooldown": 3.5, "radius": 1.0, "armor": 3.0, "sight": 18.0, "projectile": "cannon"},
}

enum Order { IDLE, MOVE, ATTACK_MOVE, ATTACK, HOLD }

@export_enum("swordsman", "archer", "knight", "catapult", "cannon") var unit_type: String = "swordsman"
@export var team: int = 0

var hp: float = 1.0
var max_hp: float = 1.0
var alive: bool = true
var selected: bool = false
var display_name: String = ""
var radius: float = 0.5
var speed: float = 3.5
var attack_range: float = 1.0
var attack_damage: float = 20.0
var armor: float = 0.0
var order_name: String = "待命"
var order: Order = Order.IDLE
var target: Node3D
var destination: Vector3
var waypoint_queue: Array[Dictionary] = []

var _stats: Dictionary
var _model: Node3D
var _game: Node
var _attack_cooldown: float = 0.0
var _scan_time: float = 0.0
var _repath_time: float = 0.0
var _damage_bar_time: float = 0.0
var _home_position: Vector3
var _strike_target: Node3D
var _strike_damage: float = 0.0
var _charge_time: float = 0.0
var _charge_cooldown: float = 0.0
var _dust_time: float = 0.0
var _moving: bool = false
var _move_retaliation: Node3D
var _retaliation_time: float = 0.0
var _corpse_meshes: Array[GeometryInstance3D] = []
var _target_query: PhysicsShapeQueryParameters3D
var _space_state: PhysicsDirectSpaceState3D

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D
@onready var model_pivot: Node3D = $ModelPivot
@onready var health_bar: MeshInstance3D = $HealthBar
@onready var selection_ring: MeshInstance3D = $SelectionRing
@onready var attack_windup: Timer = $AttackWindup

func _ready() -> void:
	_stats = STATS[unit_type]
	display_name = _stats.name
	max_hp = _stats.hp
	hp = max_hp
	speed = _stats.speed
	radius = _stats.radius
	attack_range = _stats.range
	attack_damage = _stats.damage
	armor = _stats.armor
	# Keep the common picking layer; dedicated faction layers filter native queries.
	collision_layer = 4 | (16 if team == 0 else 8)
	var sight_shape := SphereShape3D.new()
	sight_shape.radius = float(_stats.sight) + radius
	_target_query = PhysicsShapeQueryParameters3D.new()
	_target_query.shape = sight_shape
	_target_query.collision_mask = (8 | 64) if team == 0 else (16 | 32)
	_space_state = get_world_3d().direct_space_state
	_game = get_tree().current_scene
	_home_position = global_position
	destination = global_position
	_scan_time = randf_range(0.05, 0.35)
	add_to_group("entities")
	add_to_group("units")
	add_to_group("friendly_units" if team == 0 else "enemy_units")
	_model = MODELS[unit_type].instantiate()
	_model.set_team(team)
	model_pivot.add_child(_model)
	model_pivot.rotation.y = rotation.y
	rotation.y = 0.0
	_model.set_motion(false)
	match unit_type:
		"archer": $ModelPivot/ProjectileOrigin.position = Vector3(0.0, 1.45, -0.6)
		"catapult": $ModelPivot/ProjectileOrigin.position = Vector3(0.0, 2.5, -1.0)
		"cannon": $ModelPivot/ProjectileOrigin.position = Vector3(0.0, 1.2, -1.5)
	navigation_agent.radius = radius
	navigation_agent.max_speed = speed
	navigation_agent.neighbor_distance = 5.5
	navigation_agent.avoidance_priority = 0.6 if unit_type in ["knight", "catapult", "cannon"] else 0.5
	var capsule: CapsuleShape3D = $CollisionShape3D.shape
	capsule.radius = radius * 0.85
	capsule.height = maxf(radius * 1.7, 1.8)
	$CollisionShape3D.position.y = capsule.height * 0.5
	selection_ring.scale = Vector3.ONE * radius * 1.65
	var ring_material: StandardMaterial3D = selection_ring.get_surface_override_material(0)
	ring_material.albedo_color = Color("74d5f2") if team == 0 else Color("f26b52")
	health_bar.set_instance_shader_parameter("bar_color", Color("86bf54") if team == 0 else Color("d85549"))
	health_bar.position.y = 3.45 if unit_type == "knight" else (2.8 if unit_type in ["catapult", "cannon"] else 2.45)
	health_bar.scale.x = 1.65 if radius > 0.7 else 1.25
	_update_health_bar()
	set_selected(false)

func _physics_process(delta: float) -> void:
	if not alive:
		return
	_attack_cooldown = maxf(0.0, _attack_cooldown - delta)
	_charge_cooldown = maxf(0.0, _charge_cooldown - delta)
	_damage_bar_time = maxf(0.0, _damage_bar_time - delta)
	_retaliation_time = maxf(0.0, _retaliation_time - delta)
	_scan_time -= delta
	_repath_time -= delta
	var show_health: bool = selected or _damage_bar_time > 0.0 or hp < max_hp
	if health_bar.visible != show_health:
		health_bar.visible = show_health
	# Resolve a death immediately, before a completed chase path can consume the order.
	if target != null and not _valid_target(target):
		target = null
		if order == Order.ATTACK:
			_complete_waypoint()
		elif order == Order.ATTACK_MOVE:
			_set_navigation_target(destination)
	if _scan_time <= 0.0:
		_scan_time = randf_range(0.3, 0.4)
		_refresh_target()
	var desired_velocity := Vector3.ZERO
	if _valid_target(target):
		var to_target: Vector3 = target.global_position - global_position
		to_target.y = 0.0
		if _within_attack_range(target):
			_face_direction(to_target, delta)
			if _attack_cooldown <= 0.0:
				_start_attack()
		elif order != Order.HOLD and order != Order.MOVE:
			if _repath_time <= 0.0:
				_repath_time = randf_range(0.3, 0.45)
				var attack_point: Vector3 = target.get_attack_position(global_position) if target.is_in_group("buildings") else target.global_position
				var approach: Vector3 = global_position - attack_point
				approach.y = 0.0
				if approach.length_squared() < 0.01:
					approach = Vector3.RIGHT
				var target_radius: float = 0.0 if target.is_in_group("buildings") else target.radius
				var stop_distance: float = target_radius + radius + attack_range * 0.6
				var chase_destination: Vector3 = attack_point + approach.normalized() * stop_distance
				if navigation_agent.target_position.distance_squared_to(chase_destination) > 0.09:
					_set_navigation_target(chase_destination)
			desired_velocity = _path_velocity()
	elif order in [Order.MOVE, Order.ATTACK_MOVE]:
		if global_position.distance_squared_to(destination) < pow(maxf(0.65, radius * 0.8), 2.0):
			_complete_waypoint()
		else:
			desired_velocity = _path_velocity()
			if NavigationServer3D.map_get_iteration_id(navigation_agent.get_navigation_map()) > 0 and navigation_agent.is_navigation_finished():
				_complete_waypoint()
	elif order == Order.ATTACK:
		_complete_waypoint()
	# Plain movement may strike a pursuer in melee, but never chases it.
	if order == Order.MOVE and not _valid_target(target):
		desired_velocity = _path_velocity()
	var is_moving: bool = desired_velocity.length_squared() > 0.08
	if is_moving:
		_face_direction(desired_velocity, delta)
		if unit_type == "knight" and _charge_cooldown <= 0.0:
			_charge_time = minf(_charge_time + delta, 2.0)
		_dust_time -= delta
		if _dust_time <= 0.0 and unit_type in ["knight", "catapult", "cannon"]:
			_dust_time = 0.5
			_game.spawn_effect(global_position, "dust", Color("c6a572"))
	else:
		_charge_time = maxf(0.0, _charge_time - delta * 0.25)
	if is_moving != _moving:
		_moving = is_moving
		_model.set_motion(_moving)
	if navigation_agent.avoidance_enabled:
		navigation_agent.velocity = desired_velocity
	else:
		_apply_velocity(desired_velocity)

func _path_velocity() -> Vector3:
	if NavigationServer3D.map_get_iteration_id(navigation_agent.get_navigation_map()) == 0:
		return Vector3.ZERO
	var next_position: Vector3 = navigation_agent.get_next_path_position()
	var direction: Vector3 = next_position - global_position
	direction.y = 0.0
	if direction.length_squared() < 0.01 or navigation_agent.is_navigation_finished():
		return Vector3.ZERO
	return direction.normalized() * speed

func _apply_velocity(safe_velocity: Vector3) -> void:
	if not alive:
		return
	velocity = safe_velocity
	velocity.y = 0.0
	if velocity.length_squared() < 0.001:
		velocity = Vector3.ZERO
		return
	move_and_slide()
	if absf(global_position.y) > 0.001:
		global_position.y = 0.0

func _set_navigation_target(at: Vector3) -> void:
	at.y = 0.0
	navigation_agent.target_position = at

func _face_direction(direction: Vector3, delta: float) -> void:
	if direction.length_squared() > 0.001:
		var desired_angle: float = atan2(-direction.x, -direction.z)
		if absf(angle_difference(model_pivot.rotation.y, desired_angle)) > 0.002:
			model_pivot.rotation.y = lerp_angle(model_pivot.rotation.y, desired_angle, minf(1.0, delta * 12.0))

func _valid_target(entity: Node3D) -> bool:
	return is_instance_valid(entity) and entity != self and entity.alive and entity.team != team

func _within_attack_range(entity: Node3D, extra: float = 0.0) -> bool:
	var building: bool = entity.is_in_group("buildings")
	var attack_point: Vector3 = entity.get_attack_position(global_position) if building else entity.global_position
	var distance: Vector3 = attack_point - global_position
	distance.y = 0.0
	var reach: float = attack_range + radius + (0.0 if building else entity.radius) + extra
	return distance.length_squared() <= reach * reach

func _refresh_target() -> void:
	if order == Order.MOVE:
		target = _move_retaliation if _retaliation_time > 0.0 and _valid_target(_move_retaliation) and _within_attack_range(_move_retaliation) else null
		return
	if order == Order.ATTACK and not _valid_target(target):
		_complete_waypoint()
		return
	if _valid_target(target):
		if order == Order.HOLD and not _within_attack_range(target):
			target = null
		elif order == Order.IDLE and global_position.distance_squared_to(_home_position) > pow(float(_stats.sight) + 6.0, 2.0):
			target = null
			issue_move(_home_position)
			return
		else:
			return
	else:
		if order == Order.ATTACK_MOVE and target != null:
			_set_navigation_target(destination)
		target = null
	var best_distance: float = INF
	_target_query.transform.origin = global_position + Vector3.UP
	for hit: Dictionary in _space_state.intersect_shape(_target_query, 64):
		var entity: Node3D = hit.collider
		if not _valid_target(entity):
			continue
		if order == Order.HOLD and not _within_attack_range(entity):
			continue
		var distance: float = global_position.distance_squared_to(entity.global_position)
		var sight: float = attack_range + radius + entity.radius if order == Order.HOLD else float(_stats.sight) + entity.radius
		if distance > sight * sight:
			continue
		# Troops in contact take precedence over a nearby unarmed structure.
		var priority_distance: float = distance * (1.3 if entity.is_in_group("buildings") else 1.0)
		if priority_distance < best_distance:
			best_distance = priority_distance
			target = entity
	if target != null:
		_repath_time = 0.0

func _start_attack() -> void:
	_strike_target = target
	_strike_damage = attack_damage
	_attack_cooldown = _stats.cooldown
	if unit_type == "knight" and _charge_time >= 0.95 and _charge_cooldown <= 0.0:
		_strike_damage *= 1.85
		_charge_cooldown = 6.0
		_game.spawn_effect(global_position + Vector3.UP * 0.2, "charge", Color("edd9a1"))
	_charge_time = 0.0
	_model.strike()
	var windup: float = 0.22
	match unit_type:
		"knight": windup = 0.2
		"archer": windup = 0.27
		"catapult": windup = 0.48
		"cannon": windup = 0.25
	attack_windup.start(windup)

func _on_attack_windup_timeout() -> void:
	if not alive or not _valid_target(_strike_target):
		return
	var kind: String = _stats.projectile
	if not _within_attack_range(_strike_target, 1.4):
		return
	if kind.is_empty():
		_strike_target.receive_damage(_strike_damage, self)
		_game.spawn_effect(_strike_target.global_position + Vector3.UP * 1.1, "hit", Color("f5d691"))
	else:
		_game.spawn_projectile(self, _strike_target, _strike_damage, kind)
		if kind == "cannon":
			_game.spawn_effect(get_projectile_origin(), "muzzle", Color("ffd898"))

func get_projectile_origin() -> Vector3:
	return $ModelPivot/ProjectileOrigin.global_position

func set_selected(value: bool) -> void:
	selected = value and alive
	selection_ring.visible = selected
	health_bar.visible = selected or hp < max_hp

func issue_move(at: Vector3, attack_move: bool = false) -> void:
	if not alive:
		return
	waypoint_queue.clear()
	_begin_move(at, attack_move)

func queue_move(at: Vector3, attack_move: bool = false) -> void:
	if not alive:
		return
	if order in [Order.MOVE, Order.ATTACK_MOVE, Order.ATTACK]:
		waypoint_queue.append({"position": at, "attack_move": attack_move})
	else:
		_begin_move(at, attack_move)

func _begin_move(at: Vector3, attack_move: bool) -> void:
	order = Order.ATTACK_MOVE if attack_move else Order.MOVE
	order_name = "攻击前进" if attack_move else "移动中"
	destination = Vector3(clampf(at.x, -40.0, 40.0), 0.0, clampf(at.z, -40.0, 40.0))
	target = null
	_move_retaliation = null
	attack_windup.stop()
	_scan_time = 0.0
	_set_navigation_target(destination)

func issue_attack(entity: Node3D) -> void:
	if not alive or not _valid_target(entity):
		return
	waypoint_queue.clear()
	order = Order.ATTACK
	order_name = "攻击目标"
	target = entity
	_repath_time = 0.0
	attack_windup.stop()

func stop() -> void:
	if not alive:
		return
	waypoint_queue.clear()
	_finish_order()

func hold() -> void:
	stop()
	order = Order.HOLD
	order_name = "坚守阵地"
	_scan_time = 0.0

func _complete_waypoint() -> void:
	if not waypoint_queue.is_empty():
		var next_waypoint: Dictionary = waypoint_queue.pop_front()
		_begin_move(next_waypoint.position, next_waypoint.attack_move)
	else:
		_finish_order()

func _finish_order() -> void:
	order = Order.IDLE
	order_name = "待命"
	target = null
	destination = global_position
	_home_position = global_position
	attack_windup.stop()
	_set_navigation_target(global_position)
	velocity = Vector3.ZERO
	navigation_agent.velocity = Vector3.ZERO

func receive_damage(amount: float, source: Node3D = null) -> void:
	if not alive or (is_instance_valid(source) and source.team == team):
		return
	var actual_damage: float = maxf(1.0, amount - armor)
	hp = maxf(0.0, hp - actual_damage)
	_damage_bar_time = 5.0
	_update_health_bar()
	damaged.emit(self, actual_damage)
	if hp <= 0.0:
		_die()
		return
	if _valid_target(source):
		if order == Order.MOVE:
			_move_retaliation = source
			_retaliation_time = 2.0
		elif not _valid_target(target) and (order != Order.HOLD or _within_attack_range(source)):
			target = source
			_repath_time = 0.0

func _update_health_bar() -> void:
	health_bar.set_instance_shader_parameter("health", hp / max_hp)

func _die() -> void:
	alive = false
	order_name = "阵亡"
	set_selected(false)
	health_bar.hide()
	attack_windup.stop()
	navigation_agent.avoidance_enabled = false
	velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	$CollisionShape3D.set_deferred("disabled", true)
	_model.die()
	_game.spawn_effect(global_position + Vector3.UP * 0.25, "dust", Color("be9a72"))
	_game.on_entity_died(self)
	died.emit(self)
	remove_from_group("entities")
	remove_from_group("units")
	remove_from_group("friendly_units" if team == 0 else "enemy_units")
	var fall: Tween = create_tween().set_parallel(true)
	fall.tween_property(model_pivot, "rotation:z", 1.35 if randf() > 0.5 else -1.35, 0.42).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	fall.tween_property(model_pivot, "position:y", 0.15, 0.42)
	fall.chain().tween_interval(2.0)
	for mesh: GeometryInstance3D in _model.find_children("*", "GeometryInstance3D", true, false):
		_corpse_meshes.append(mesh)
	fall.chain().tween_method(_fade_corpse, 0.0, 1.0, 1.8)
	fall.chain().tween_callback(queue_free)

func _fade_corpse(amount: float) -> void:
	for mesh: GeometryInstance3D in _corpse_meshes:
		mesh.transparency = amount
