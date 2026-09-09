class_name BattleUnit
extends CharacterBody3D
## Controllable combat entity. Geometry lives in the authored unit model scenes.

signal died(entity: Node3D)
signal damaged(entity: Node3D, amount: float)
signal sound_requested(kind: StringName, at: Vector3)
signal gathered(worker: Node3D, amount: int)

const MODELS: Dictionary = {
	"swordsman": preload("res://assets/models/units/swordsman.tscn"),
	"archer": preload("res://assets/models/units/archer.tscn"),
	"knight": preload("res://assets/models/units/knight.tscn"),
	"catapult": preload("res://assets/models/units/catapult.tscn"),
	"cannon": preload("res://assets/models/units/cannon.tscn"),
	"farmer": preload("res://assets/models/units/farmer.tscn"),
}

const STATS: Dictionary = BalanceCatalog.UNITS

enum Order { IDLE, MOVE, ATTACK_MOVE, ATTACK, HOLD, GATHER, BUILD }
const GATHER_SECONDS: float = 3.0
const GATHER_GOLD: int = 3
const MAX_QUEUED_ORDERS: int = 64

@export_enum("swordsman", "archer", "knight", "catapult", "cannon", "farmer") var unit_type: String = "swordsman"
@export var owner_id: int = -1
@export var alliance_id: int = 0
# Saved 0.5 scenes encode two alliances as team. New matches set owner_id explicitly.
@export var team: int:
	get:
		return alliance_id
	set(value):
		alliance_id = value
		if owner_id < 0:
			owner_id = value

var entity_id: int = 0

var hp: float = 1.0
var max_hp: float = 1.0
var alive: bool = true
var selected: bool = false
var display_name: String = ""
var radius: float = 0.5
var speed: float = 3.5
var attack_range: float = 1.0
var attack_damage: float = 20.0
var min_attack_range: float = 0.0
var order_name: String = "待命"
var order: Order = Order.IDLE
var target: Node3D
var destination: Vector3
var waypoint_queue: Array[Dictionary] = []
var work_target: Node3D
var work_progress: float = 0.0

var _stats: UnitDefinition
var _model: Node3D
var _attack_animation: AnimationPlayer
var _game: Node
var _path_budget: PathBudget
var _attack_cooldown: float = 0.0
var _scan_time: float = 0.0
var _repath_time: float = 0.0
var _damage_bar_time: float = 0.0
var _home_position: Vector3
var _strike_target: Node3D
var _charge_time: float = 0.0
var _charge_cooldown: float = 0.0
var _moving: bool = false
var _move_retaliation: Node3D
var _retaliation_time: float = 0.0
var _corpse_meshes: Array[GeometryInstance3D] = []
var _target_query: PhysicsShapeQueryParameters3D
var _space_state: PhysicsDirectSpaceState3D
var _foley_distance: float = 0.0
var _working: bool = false
var _work_seconds: float = 0.0
var _work_sound_time: float = 0.45
var _claimed_site: bool = false
var _claimed_mine: bool = false

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D
@onready var model_pivot: Node3D = $ModelPivot
@onready var health_bar: MeshInstance3D = $HealthBar
@onready var selection_ring: MeshInstance3D = $SelectionRing
@onready var attack_windup: Timer = $AttackWindup
@onready var work_bar: MeshInstance3D = $WorkBar

func _ready() -> void:
	if owner_id < 0:
		owner_id = alliance_id
	_stats = BalanceCatalog.unit(unit_type)
	display_name = _stats.name
	max_hp = _stats.hp
	hp = max_hp
	speed = _stats.speed
	radius = _stats.radius
	attack_range = _stats.range
	attack_damage = _stats.damage
	min_attack_range = _stats.min_range
	# Keep the common picking layer; dedicated faction layers filter native queries.
	collision_layer = 4 | (16 if team == 0 else 8)
	var sight_shape := SphereShape3D.new()
	sight_shape.radius = float(_stats.sight) + radius
	_target_query = PhysicsShapeQueryParameters3D.new()
	_target_query.shape = sight_shape
	_target_query.collision_mask = (8 | 64) if team == 0 else (16 | 32)
	_space_state = get_world_3d().direct_space_state
	_game = get_tree().current_scene
	_path_budget = _game.get_node("PathBudget")
	_home_position = global_position
	destination = global_position
	_scan_time = randf_range(0.05, 0.35)
	_foley_distance = randf_range(0.0, 0.7)
	add_to_group("entities")
	add_to_group("units")
	add_to_group("friendly_units" if team == 0 else "enemy_units")
	_model = MODELS[unit_type].instantiate()
	var relation: int = FactionPalette.relation(owner_id, alliance_id, _game)
	_model.set_team(relation)
	model_pivot.add_child(_model)
	_attack_animation = _model.get_node("Attack")
	model_pivot.rotation.y = rotation.y
	rotation.y = 0.0
	_model.set_motion(false)
	navigation_agent.radius = radius
	navigation_agent.max_speed = speed
	navigation_agent.neighbor_distance = 5.5
	navigation_agent.avoidance_priority = 0.6 if unit_type in ["knight", "catapult", "cannon"] else 0.5
	var capsule: CapsuleShape3D = $CollisionShape3D.shape
	capsule.radius = radius * 0.85
	capsule.height = maxf(radius * 1.7, 1.8)
	$CollisionShape3D.position.y = capsule.height * 0.5
	selection_ring.scale = Vector3.ONE * radius * 1.65
	selection_ring.set_instance_shader_parameter("ring_color", FactionPalette.ui_color(relation))
	health_bar.set_instance_shader_parameter("bar_color", FactionPalette.ui_color(relation))
	health_bar.position.y = 3.45 if unit_type == "knight" else (2.8 if unit_type in ["catapult", "cannon"] else 2.45)
	health_bar.scale.x = 1.65 if radius > 0.7 else 1.25
	_update_health_bar()
	set_selected(false)
	# The unit is instantiated at its actual spawn position. Synchronize the
	# completed hierarchy so render interpolation never blends from the origin.
	reset_physics_interpolation()
	_game.register_entity(self)
	_path_budget.register(self)

func _physics_process(delta: float) -> void:
	if not alive or not _game.is_authority:
		return
	# Keep the fractional tick at expiry for continuous attacks (e.g. 1.05 s
	# at 30 physics ticks). An already-ready unit never banks idle attack time.
	_attack_cooldown = _attack_cooldown - delta if _attack_cooldown > 0.0 else 0.0
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
	var path_velocity_requested: bool = false
	if order in [Order.GATHER, Order.BUILD]:
		desired_velocity = _work_velocity(delta)
	elif _valid_target(target):
		var to_target: Vector3 = target.global_position - global_position
		to_target.y = 0.0
		if _within_attack_range(target):
			_face_direction(to_target, delta)
			if _attack_cooldown <= 0.000001:
				_start_attack()
		elif order != Order.HOLD and order != Order.MOVE:
			if _repath_time <= 0.0 or _path_budget.is_finished(self):
				_repath_time = randf_range(0.4, 0.55)
				var attack_point: Vector3 = target.get_attack_position(global_position) if target.is_in_group("buildings") else target.global_position
				var approach: Vector3 = global_position - attack_point
				approach.y = 0.0
				if approach.length_squared() < 0.01:
					approach = Vector3.RIGHT
				var target_radius: float = 0.0 if target.is_in_group("buildings") else target.radius
				var stop_distance: float = target_radius + radius + attack_range * 0.6
				var chase_destination: Vector3 = attack_point + approach.normalized() * stop_distance
				# Small target motion keeps the current corridor. A finished route
				# refreshes immediately instead of waiting for the chase interval.
				if _path_budget.is_finished(self) or _path_budget.target_position(self).distance_squared_to(chase_destination) > 1.44:
					_set_navigation_target(chase_destination)
			desired_velocity = _path_velocity()
			path_velocity_requested = true
			if target.is_in_group("buildings") and String(_stats.projectile).is_empty() and _path_budget.is_finished(self):
				# A padded navigation mesh ends before the physical wall. Complete the
				# last contact step through CharacterBody3D so swords can reach it.
				var contact_direction: Vector3 = target.get_attack_position(global_position) - global_position
				contact_direction.y = 0.0
				var contact_distance: float = attack_range + radius + 1.0
				if contact_direction.length_squared() <= contact_distance * contact_distance:
					desired_velocity = contact_direction.normalized() * speed
	elif order in [Order.MOVE, Order.ATTACK_MOVE]:
		if global_position.distance_squared_to(destination) < pow(maxf(0.65, radius * 0.8), 2.0):
			_complete_waypoint()
		else:
			desired_velocity = _path_velocity()
			path_velocity_requested = true
			if _path_budget.is_finished(self):
				_complete_waypoint()
	elif order == Order.ATTACK:
		_complete_waypoint()
	# Plain movement may strike a pursuer in melee, but never chases it.
	# A completed work/attack order can enter MOVE during this tick. Ordinary
	# MOVE already followed its path above and must not update the agent twice.
	if order == Order.MOVE and not _valid_target(target) and not path_velocity_requested:
		desired_velocity = _path_velocity()
	var is_moving: bool = desired_velocity.length_squared() > 0.08
	if is_moving:
		_face_direction(desired_velocity, delta)
		if unit_type == "knight" and _charge_cooldown <= 0.0:
			_charge_time = minf(_charge_time + delta, 2.0)
	else:
		_charge_time = maxf(0.0, _charge_time - delta * 0.25)
	if is_moving != _moving:
		_moving = is_moving
		_model.set_motion(_moving)
	if navigation_agent.avoidance_enabled:
		# NavigationAgent stops forwarding velocity after its path completes.
		# Drive the same native RVO agent directly, including the final wall step.
		NavigationServer3D.agent_set_velocity(navigation_agent.get_rid(), desired_velocity)
	else:
		_apply_velocity(desired_velocity)

func _path_velocity() -> Vector3:
	var next_position: Vector3 = _path_budget.next_position(self)
	var direction: Vector3 = next_position - global_position
	direction.y = 0.0
	if direction.length_squared() < 0.01 or _path_budget.is_finished(self):
		if _path_budget.has_pending(self):
			_face_direction(_path_budget.target_position(self) - global_position, get_physics_process_delta_time())
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
	var previous_position: Vector3 = global_position
	move_and_slide()
	if absf(global_position.y) > 0.001:
		global_position.y = 0.0
	# Footsteps follow actual displacement, including RVO and walls.
	var travelled: float = global_position.distance_to(previous_position)
	_foley_distance += travelled
	var stride: float = 1.65 if unit_type == "knight" else (1.8 if unit_type in ["catapult", "cannon"] else 1.0)
	if _foley_distance >= stride:
		_foley_distance = fmod(_foley_distance, stride)
		var foot_sound: StringName = &"horse_hoof" if unit_type == "knight" else (&"cart_wheel" if unit_type in ["catapult", "cannon"] else &"footstep_dirt")
		sound_requested.emit(foot_sound, global_position)

func _set_navigation_target(at: Vector3) -> void:
	at.y = 0.0
	_path_budget.request(self, at)

func _face_direction(direction: Vector3, delta: float) -> void:
	if direction.length_squared() > 0.001:
		var desired_angle: float = atan2(-direction.x, -direction.z)
		if absf(angle_difference(model_pivot.rotation.y, desired_angle)) > 0.002:
			model_pivot.rotation.y = lerp_angle(model_pivot.rotation.y, desired_angle, minf(1.0, delta * 12.0))

func _valid_target(entity: Variant) -> bool:
	# Freed cached targets must reach the validity guard before object-type checks.
	return is_instance_valid(entity) and entity != self and entity.is_in_group("entities") and entity.alive and _game.are_hostile(self, entity) and _game.can_see_entity(owner_id, entity)

func _within_attack_range(entity: Node3D, extra: float = 0.0) -> bool:
	var building: bool = entity.is_in_group("buildings")
	var attack_point: Vector3 = entity.get_attack_position(global_position) if building else entity.global_position
	var distance: Vector3 = attack_point - global_position
	distance.y = 0.0
	var reach: float = attack_range + radius + (0.0 if building else entity.radius) + extra
	var minimum: float = min_attack_range + radius + (0.0 if building else entity.radius) if min_attack_range > 0.0 else 0.0
	return distance.length_squared() <= reach * reach and distance.length_squared() >= minimum * minimum

func _refresh_target() -> void:
	# Workers finish economic orders even under fire. An explicit attack still
	# lets the player use a pickaxe for self-defence.
	if unit_type == "farmer" and order != Order.ATTACK:
		target = null
		return
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
	_attack_cooldown = float(_stats.cooldown) + minf(0.0, _attack_cooldown)
	if unit_type == "knight" and _charge_time >= 0.95 and _charge_cooldown <= 0.0:
		_charge_cooldown = 6.0
		_game.spawn_effect(global_position + Vector3.UP * 0.2, "charge", Color("edd9a1"))
	_charge_time = 0.0
	_model.strike()
	if unit_type in ["swordsman", "knight"]:
		sound_requested.emit(&"sword_swing", global_position + Vector3.UP)
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
	# The Timer can run a few milliseconds before AnimationPlayer in the same frame.
	# Apply the authored release pose before reading the moving weapon socket.
	var pose_delay: float = attack_windup.wait_time - _attack_animation.current_animation_position
	if pose_delay > 0.0:
		_attack_animation.advance(pose_delay + 0.000001)
	var upgrade_bonus: float = _game.get_player(owner_id).get_attack_bonus() if _stats.military else 0.0
	var payload: DamagePayload = DamageResolver.snapshot(_stats, upgrade_bonus, owner_id, alliance_id)
	if kind.is_empty():
		var effect_kind: String = _strike_target.get_hit_effect() if _strike_target.is_in_group("buildings") else "hit"
		var contact: Vector3 = _strike_target.get_attack_position(global_position) if _strike_target.is_in_group("buildings") else _strike_target.global_position
		_strike_target.receive_hit(payload, self)
		_game.spawn_effect(contact + Vector3.UP * 1.1, effect_kind, Color("f5d691"))
	else:
		if kind != "cannon":
			sound_requested.emit(&"bow_release" if kind == "arrow" else &"catapult_release", get_projectile_origin())
		_game.spawn_projectile(self, _strike_target, payload, kind)
		if kind == "cannon":
			_game.spawn_effect(get_projectile_origin(), "muzzle", Color("ffd898"))

func get_projectile_origin() -> Vector3:
	return _model.get_projectile_origin()

func set_selected(value: bool) -> void:
	selected = value and alive
	selection_ring.visible = selected
	health_bar.visible = selected or hp < max_hp

func issue_gather(mine: Node3D, queued: bool = false) -> bool:
	if not alive or unit_type != "farmer" or not is_instance_valid(mine) or not mine.is_in_group("resource_veins"):
		return false
	return _issue_work(mine, Order.GATHER, queued)

func issue_build(site: Node3D, queued: bool = false) -> bool:
	if not alive or unit_type != "farmer" or not is_instance_valid(site) or not site.is_in_group("buildings") or not site.alive or site.owner_id != owner_id or site.is_constructed:
		return false
	return _issue_work(site, Order.BUILD, queued)

func _issue_work(entity: Node3D, work_order: Order, queued: bool) -> bool:
	if queued and order in [Order.MOVE, Order.ATTACK_MOVE, Order.ATTACK, Order.GATHER, Order.BUILD]:
		if waypoint_queue.is_empty() and order == work_order and work_target == entity:
			return true
		if not waypoint_queue.is_empty():
			var last_order: Dictionary = waypoint_queue.back()
			if last_order.kind == "work" and last_order.entity == entity and last_order.order == work_order:
				return true
		if waypoint_queue.size() >= MAX_QUEUED_ORDERS:
			return false
		waypoint_queue.append({"kind": "work", "entity": entity, "order": work_order})
		return true
	waypoint_queue.clear()
	# A repeated mine/site command must not reset progress or release a builder.
	if order == work_order and work_target == entity:
		return true
	_begin_work(entity, work_order)
	return true

func _begin_work(entity: Node3D, work_order: Order) -> void:
	_interrupt_work()
	order = work_order
	work_target = entity
	target = null
	_move_retaliation = null
	attack_windup.stop()
	_repath_time = 0.0
	order_name = "前往矿脉" if order == Order.GATHER else "前往工地"
	_update_work_destination()

func _update_work_destination() -> void:
	if order == Order.GATHER:
		_claimed_mine = work_target.try_claim(self)
		destination = work_target.get_work_position(global_position, self if _claimed_mine else null)
	else:
		var edge: Vector3 = work_target.get_attack_position(global_position)
		var outward: Vector3 = global_position - edge
		outward.y = 0.0
		if outward.length_squared() < 0.01:
			outward = Vector3.RIGHT
		destination = edge + outward.normalized() * (radius + 1.15)
	_set_navigation_target(destination)

func _work_velocity(delta: float) -> Vector3:
	if not is_instance_valid(work_target) or not work_target.alive:
		_complete_waypoint()
		return Vector3.ZERO
	if order == Order.BUILD and work_target.is_constructed:
		_complete_waypoint()
		return Vector3.ZERO
	if order == Order.GATHER and not _claimed_mine and _repath_time <= 0.0:
		_repath_time = 0.6
		_update_work_destination()
	var contact: Vector3 = destination if order == Order.GATHER else work_target.get_attack_position(global_position)
	var reach: float = 0.65 if order == Order.GATHER else 1.85
	var distance: Vector3 = contact - global_position
	distance.y = 0.0
	if distance.length_squared() > reach * reach:
		_set_working(false)
		if order == Order.GATHER:
			_work_seconds = 0.0
			work_progress = 0.0
		if _repath_time <= 0.0:
			_repath_time = 0.6
			_update_work_destination()
		var approach_velocity: Vector3 = _path_velocity()
		if _path_budget.is_finished(self) and distance.length_squared() <= pow(reach + 1.25, 2.0):
			# The baked clearance band can end just outside a worker's reach.
			# CharacterBody3D supplies the final collision-safe contact step.
			approach_velocity = distance.normalized() * speed
		return approach_velocity
	if order == Order.GATHER and not _claimed_mine:
		_set_working(false)
		order_name = "矿脉满员 · 等待空位"
		return Vector3.ZERO
	_face_direction(work_target.global_position - global_position if order == Order.GATHER else distance, delta)
	if order == Order.BUILD:
		# A worker pushed away can have its site taken over. Revalidate ownership
		# before contributing so the former builder waits instead of animating work.
		_claimed_site = work_target.try_claim_builder(self)
		if not _claimed_site:
			_set_working(false)
			order_name = "等待工地空闲"
			return Vector3.ZERO
	_set_working(true)
	if order == Order.GATHER:
		order_name = "采集黄金 · +3 / 3秒"
		_work_seconds += delta
		work_progress = minf(_work_seconds / GATHER_SECONDS, 1.0)
		if _work_seconds + 0.000001 >= GATHER_SECONDS:
			_work_seconds -= GATHER_SECONDS
			work_progress = maxf(0.0, _work_seconds / GATHER_SECONDS)
			gathered.emit(self, GATHER_GOLD)
			# A queued order follows this completed cycle; the last mining order
			# continues indefinitely without transporting resources to a depot.
			if not waypoint_queue.is_empty():
				_complete_waypoint()
				return Vector3.ZERO
	else:
		order_name = "建造" + work_target.display_name
		work_target.contribute_work(self, delta)
		work_progress = work_target.construction_progress
		if work_target.is_constructed:
			_complete_waypoint()
			return Vector3.ZERO
	work_bar.set_instance_shader_parameter("health", work_progress)
	_work_sound_time -= delta
	if _work_sound_time <= 0.0:
		_work_sound_time += 1.5 if order == Order.GATHER else 1.0
		sound_requested.emit(&"stone_chip" if order == Order.GATHER else &"wood_hit", global_position + Vector3.UP)
	return Vector3.ZERO

func _set_working(value: bool) -> void:
	if _working == value:
		return
	_working = value
	work_bar.visible = value
	_model.set_working(value, "gather" if order == Order.GATHER else "build")
	if value:
		_work_sound_time = 0.45
		work_bar.set_instance_shader_parameter("bar_color", Color("e9bf5c") if order == Order.GATHER else Color("72c6d8"))

func _interrupt_work() -> void:
	if _claimed_mine and is_instance_valid(work_target):
		work_target.release(self)
	_claimed_mine = false
	if _claimed_site and is_instance_valid(work_target):
		work_target.release_builder(self)
	_claimed_site = false
	_set_working(false)
	work_target = null
	work_progress = 0.0
	_work_seconds = 0.0

func _exit_tree() -> void:
	# During full scene shutdown the sibling scheduler may already be gone.
	if is_instance_valid(_path_budget):
		_path_budget.unregister(self)
	if _claimed_mine and is_instance_valid(work_target):
		work_target.release(self)
	if _claimed_site and is_instance_valid(work_target):
		work_target.release_builder(self)

func issue_move(at: Vector3, attack_move: bool = false) -> void:
	if not alive:
		return
	waypoint_queue.clear()
	_begin_move(at, attack_move)

func queue_move(at: Vector3, attack_move: bool = false) -> void:
	if not alive:
		return
	if order in [Order.MOVE, Order.ATTACK_MOVE, Order.ATTACK, Order.GATHER, Order.BUILD]:
		if waypoint_queue.size() >= MAX_QUEUED_ORDERS:
			return
		if not waypoint_queue.is_empty():
			var last: Dictionary = waypoint_queue.back()
			if last.kind == "move" and last.attack_move == attack_move and last.position.distance_squared_to(at) < 0.01:
				return
		waypoint_queue.append({"kind": "move", "position": at, "attack_move": attack_move})
	else:
		_begin_move(at, attack_move)

func _begin_move(at: Vector3, attack_move: bool) -> void:
	_interrupt_work()
	order = Order.ATTACK_MOVE if attack_move else Order.MOVE
	order_name = "攻击前进" if attack_move else "移动中"
	destination = _game.clamp_to_map(at)
	target = null
	_move_retaliation = null
	attack_windup.stop()
	_scan_time = 0.0
	_set_navigation_target(destination)

func issue_attack(entity: Node3D, queued: bool = false) -> void:
	if not alive or not _valid_target(entity):
		return
	if queued and order in [Order.MOVE, Order.ATTACK_MOVE, Order.ATTACK, Order.GATHER, Order.BUILD]:
		if waypoint_queue.is_empty() and order == Order.ATTACK and target == entity:
			return
		if not waypoint_queue.is_empty() and waypoint_queue.back().kind == "attack" and waypoint_queue.back().entity == entity:
			return
		if waypoint_queue.size() < MAX_QUEUED_ORDERS:
			waypoint_queue.append({"kind": "attack", "entity": entity})
		return
	waypoint_queue.clear()
	_begin_attack(entity)

func _begin_attack(entity: Node3D) -> void:
	var same_attack: bool = target == entity and (attack_windup.is_stopped() or _strike_target == entity)
	_interrupt_work()
	order = Order.ATTACK
	order_name = "攻击目标"
	# Repeated focus fire replaces queued orders without canceling the current strike.
	# This also promotes an automatic engagement to an explicit attack on that target.
	if same_attack:
		return
	target = entity
	_repath_time = 0.0
	attack_windup.stop()

func stop() -> void:
	if not alive:
		return
	waypoint_queue.clear()
	_finish_order()

func hold(queued: bool = false) -> void:
	if not alive:
		return
	if queued and order in [Order.MOVE, Order.ATTACK_MOVE, Order.ATTACK, Order.GATHER, Order.BUILD]:
		if waypoint_queue.size() < MAX_QUEUED_ORDERS and (waypoint_queue.is_empty() or waypoint_queue.back().kind != "hold"):
			waypoint_queue.append({"kind": "hold"})
		return
	stop()
	order = Order.HOLD
	order_name = "坚守阵地"
	_scan_time = 0.0

func _complete_waypoint() -> void:
	_interrupt_work()
	while not waypoint_queue.is_empty():
		var next_waypoint: Dictionary = waypoint_queue.pop_front()
		if next_waypoint.kind == "hold":
			hold()
			return
		if next_waypoint.kind == "move":
			_begin_move(next_waypoint.position, next_waypoint.attack_move)
			return
		var next_entity: Variant = next_waypoint.entity
		if not is_instance_valid(next_entity) or not next_entity.alive:
			continue
		if next_waypoint.kind == "attack":
			if _valid_target(next_entity):
				_begin_attack(next_entity)
				return
			continue
		if next_waypoint.order == Order.BUILD and next_entity.is_constructed:
			continue
		_begin_work(next_entity, next_waypoint.order)
		return
	_finish_order()

func _finish_order() -> void:
	_interrupt_work()
	order = Order.IDLE
	order_name = "待命"
	target = null
	destination = global_position
	_home_position = global_position
	_scan_time = 0.0
	attack_windup.stop()
	# Stop presentation state synchronously: battle completion may disable
	# physics and avoidance before another velocity callback can arrive.
	_moving = false
	_model.set_motion(false)
	_path_budget.cancel(self)
	velocity = Vector3.ZERO
	NavigationServer3D.agent_set_velocity(navigation_agent.get_rid(), Vector3.ZERO)

func get_combat_definition() -> CombatDefinition:
	return _stats

func receive_hit(payload: DamagePayload, source: Node3D = null, falloff: float = 1.0) -> void:
	if not alive or payload.alliance_id == alliance_id:
		return
	var defense_bonus: float = _game.get_player(owner_id).get_defense_bonus() if _stats.military else 0.0
	_apply_damage(DamageResolver.resolve(payload, _stats, defense_bonus, falloff), source)

func receive_damage(amount: float, source: Node3D = null) -> void:
	# Explicit direct damage for scenario scripts and debugging. Combat uses receive_hit.
	if not alive or (is_instance_valid(source) and not _game.are_hostile(self, source)):
		return
	_apply_damage(maxf(0.0, amount), source)

func _apply_damage(actual_damage: float, source: Node3D) -> void:
	hp = maxf(0.0, hp - actual_damage)
	_damage_bar_time = 5.0
	_update_health_bar()
	damaged.emit(self, actual_damage)
	if hp <= 0.0:
		_die()
		return
	if unit_type != "farmer" and _valid_target(source):
		if order == Order.MOVE:
			_move_retaliation = source
			_retaliation_time = 2.0
		elif not _valid_target(target) and (order != Order.HOLD or _within_attack_range(source)):
			target = source
			_repath_time = 0.0

func _update_health_bar() -> void:
	health_bar.set_instance_shader_parameter("health", hp / max_hp)

func _die() -> void:
	_interrupt_work()
	_path_budget.cancel(self)
	waypoint_queue.clear()
	alive = false
	sound_requested.emit(&"death_fall", global_position)
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
	var fall: Tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS).set_parallel(true)
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
