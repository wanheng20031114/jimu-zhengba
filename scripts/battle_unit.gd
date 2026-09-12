class_name BattleUnit
extends CharacterBody3D
## Controllable combat entity. Geometry lives in the authored unit model scenes.

signal died(entity: Node3D)
signal damaged(entity: Node3D, amount: float)
signal sound_requested(kind: StringName, at: Vector3)
signal gathered(worker: Node3D, amount: int)

const MODELS: Dictionary = {
	"swordsman": preload("res://assets/models/units/swordsman.tscn"),
	"shield_guard": preload("res://assets/models/units/shield_guard.tscn"),
	"spearman": preload("res://assets/models/units/spearman.tscn"),
	"archer": preload("res://assets/models/units/archer.tscn"),
	"knight": preload("res://assets/models/units/knight.tscn"),
	"light_cavalry": preload("res://assets/models/units/light_cavalry.tscn"),
	"war_elephant": preload("res://assets/models/units/war_elephant.tscn"),
	"catapult": preload("res://assets/models/units/catapult.tscn"),
	"cannon": preload("res://assets/models/units/cannon.tscn"),
	"farmer": preload("res://assets/models/units/farmer.tscn"),
}

const STATS: Dictionary = BalanceCatalog.UNITS

enum Order { IDLE, MOVE, ATTACK_MOVE, ATTACK, HOLD, GATHER, BUILD }
const MAX_QUEUED_ORDERS: int = 64
const CHASE_PREDICTION_SECONDS: float = 0.55
const RECOVERY_DELAY: float = 10.0
# A small contact tolerance (about one knight step at the authoritative 30 TPS),
# rather than the former 1.4-meter extension. Faster targets can still escape.
const MELEE_CONTACT_TOLERANCE: float = 0.2

@export_enum("swordsman", "shield_guard", "spearman", "archer", "knight", "war_elephant", "light_cavalry", "catapult", "cannon", "farmer") var unit_type: String = "swordsman"
@export var model_scene_override: PackedScene
# Presentation and RVO choices are fixed before this unit enters
# the tree. Network replicas retain the same authority gate as native models.
var render_batches: UnitRenderBatches
@export var prune_stationary_avoidance: bool = false
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
var defeated_by_owner: int = -1
var selected: bool = false
var display_name: String = ""
var radius: float = 0.5
var speed: float = 3.5
var _base_or_replicated_range: float = 1.0
var attack_range: float:
	get:
		# Before _ready this property has its authored base. After binding, only
		# the authority derives combat values; clients receive the visible result.
		return _base_or_replicated_range + (_owner_state.get_cannon_range_bonus() if unit_type == "cannon" and _game != null and _game.is_authority else 0.0)
	set(value):
		_base_or_replicated_range = value
var attack_damage: float = 20.0
var min_attack_range: float = 0.0
var order_name: String = "待命"
var order: Order = Order.IDLE
var target: Node3D
var destination: Vector3
var waypoint_queue: Array[Dictionary] = []
var _movement_plan: MovementPlan
var work_target: Node3D
var work_progress: float = 0.0

var _stats: UnitDefinition
var _model: UnitVisual
var _attack_animation: AnimationPlayer
var _game: Node
var _owner_state: PlayerState
var _fog: FogOfWar
var _recovery_quiet_seconds: float = 0.0
var _recovery_progress: float = 0.0
var _path_budget: PathBudget
var _motion_grid: StaticMotionGrid
var _motion_clearance: float = 0.0
var _motion_region := Rect2()
var _motion_region_revision: int = -1
var _motion_region_clear: bool = false
var _attack_cooldown: float = 0.0
var _scan_time: float = 0.0
var _repath_time: float = 0.0
var _damage_bar_time: float = 0.0
var _home_position: Vector3
var _strike_target: Node3D
var _charge_time: float = 0.0
var _charge_cooldown: float = 0.0
var _moving: bool = false
var _avoidance_moving: bool = false
var _moving_neighbor_limit: int = 10
var _observed_velocity := Vector3.ZERO
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
	collision_layer = 4 | CombatLayers.UNIT_LAYERS[alliance_id]
	var sight_shape := SphereShape3D.new()
	sight_shape.radius = float(_stats.sight) + radius
	_target_query = PhysicsShapeQueryParameters3D.new()
	_target_query.shape = sight_shape
	_target_query.collision_mask = CombatLayers.hostile_entities(alliance_id)
	_space_state = get_world_3d().direct_space_state
	_game = get_tree().current_scene
	_owner_state = _game.get_player(owner_id)
	_fog = _game.get_node("FogOfWar")
	_path_budget = _game.get_node("PathBudget")
	_motion_grid = _game.get_node("StaticMotionGrid")
	_home_position = global_position
	destination = global_position
	_scan_time = randf_range(0.05, 0.35)
	_foley_distance = randf_range(0.0, 0.7)
	add_to_group("entities")
	add_to_group("units")
	add_to_group("friendly_units" if team == 0 else "enemy_units")
	var model_scene: PackedScene = model_scene_override if model_scene_override != null else MODELS[unit_type]
	_model = model_scene.instantiate()
	var relation: int = FactionPalette.relation(owner_id, alliance_id, _game)
	_model.set_team(relation)
	model_pivot.add_child(_model)
	if render_batches != null:
		_model.bind_render_batches(render_batches)
	_attack_animation = _model.get_node("Attack")
	model_pivot.rotation.y = rotation.y
	rotation.y = 0.0
	_model.set_motion(false)
	navigation_agent.radius = radius
	navigation_agent.max_speed = 0.0
	navigation_agent.neighbor_distance = 5.5
	navigation_agent.avoidance_priority = 1.0
	_moving_neighbor_limit = navigation_agent.max_neighbors
	if prune_stationary_avoidance:
		navigation_agent.max_neighbors = 0
	var capsule: CapsuleShape3D = $CollisionShape3D.shape
	capsule.radius = radius * 0.85
	capsule.height = maxf(radius * 1.7, _stats.collision_height)
	_motion_clearance = capsule.radius + capsule.margin + safe_margin
	$CollisionShape3D.position.y = capsule.height * 0.5
	selection_ring.scale = Vector3.ONE * radius * 1.65
	selection_ring.set_instance_shader_parameter("ring_color", FactionPalette.ui_color(relation))
	health_bar.set_instance_shader_parameter("bar_color", FactionPalette.ui_color(relation))
	health_bar.position.y = _stats.health_bar_height
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
	_tick_recovery(delta)
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
	# Reuse validity only within this synchronous unit tick. Order completion
	# and scanning may replace the target; a different reference is checked
	# before use. The attack Timer independently revalidates at actual release.
	var checked_target: Variant = target
	var target_valid: bool = _valid_target(checked_target)
	# Resolve a death immediately, before a completed chase path can consume the order.
	if not target_valid and (order == Order.ATTACK or target != null):
		target = null
		if order == Order.ATTACK:
			_complete_waypoint()
		elif order == Order.ATTACK_MOVE:
			_set_navigation_target(destination)
	if _scan_time <= 0.0:
		_scan_time = randf_range(0.3, 0.4)
		_refresh_target()
	if target != checked_target:
		checked_target = target
		target_valid = _valid_target(checked_target)
	var desired_velocity := Vector3.ZERO
	var facing_direction := Vector3.ZERO
	var path_velocity_requested: bool = false
	if order == Order.GATHER or order == Order.BUILD:
		desired_velocity = _work_velocity(delta)
	elif target_valid:
		var windup_active: bool = not attack_windup.is_stopped()
		var can_start_strike: bool = _can_start_strike(target)
		if can_start_strike:
			facing_direction = target.global_position - global_position
			facing_direction.y = 0.0
			if _attack_cooldown <= 0.000001 and not windup_active:
				_start_attack()
				windup_active = true
		var melee_windup: bool = windup_active and _stats.projectile.is_empty()
		var can_chase: bool = order != Order.HOLD and order != Order.MOVE
		# Windup owns its locked target and release time. Melee may take a
		# pursuit step during that swing; ranged weapons plant until release.
		# Recovery can pursue again without restarting the attack cooldown.
		var chase_needed: bool = not can_start_strike
		if melee_windup:
			chase_needed = not _within_attack_range(target, -attack_range * 0.4)
		if can_chase and chase_needed and (not windup_active or melee_windup):
			desired_velocity = _chase_velocity(target)
			path_velocity_requested = true
	elif order == Order.MOVE or order == Order.ATTACK_MOVE:
		var arrival_distance: float = maxf(0.65, radius * 0.8)
		if global_position.distance_squared_to(destination) < arrival_distance * arrival_distance:
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
	if order == Order.MOVE and not path_velocity_requested:
		if target != checked_target:
			target_valid = _valid_target(target)
		if not target_valid:
			desired_velocity = _path_velocity()
	var is_moving: bool = desired_velocity.length_squared() > 0.08
	if is_moving:
		facing_direction = desired_velocity
		if unit_type == "knight" and _charge_cooldown <= 0.0:
			_charge_time = minf(_charge_time + delta, 2.0)
	else:
		_charge_time = maxf(0.0, _charge_time - delta * 0.25)
	if facing_direction.length_squared() > 0.001:
		_face_direction(facing_direction, delta)
	if is_moving != _moving:
		_moving = is_moving
		_model.set_motion(_moving)
	if navigation_agent.avoidance_enabled:
		_set_avoidance_moving(is_moving)
		# NavigationAgent stops forwarding velocity after its path completes.
		# Drive the same native RVO agent directly, including the final wall step.
		NavigationServer3D.agent_set_velocity(navigation_agent.get_rid(), desired_velocity)
	else:
		_apply_velocity(desired_velocity)

func _chase_velocity(entity: Node3D) -> Vector3:
	var building: bool = entity.is_in_group("buildings")
	var attack_point: Vector3 = entity.get_attack_position(global_position) if building else entity.global_position
	var approach: Vector3 = global_position - attack_point
	approach.y = 0.0
	if approach.length_squared() < 0.01:
		approach = Vector3.RIGHT
	var target_radius: float = 0.0 if building else entity.radius
	var spacing: float = maxf(attack_range * 0.6, min_attack_range + 0.35)
	var contact_distance: float = target_radius + radius + spacing
	if entity is BattleUnit:
		# Lead only as far as the remaining approach permits. A fixed time lead
		# can cross behind us when a fast enemy approaches, ordering a retreat.
		# Include incoming radial speed in the closing time, but keep the full
		# replan horizon for distant or fleeing targets. Use actual planar motion.
		var target_velocity: Vector3 = entity._observed_velocity
		target_velocity.y = 0.0
		var remaining: float = maxf(0.0, approach.length() - contact_distance)
		var closing_speed: float = speed + target_velocity.dot(approach.normalized())
		var lead_time: float = CHASE_PREDICTION_SECONDS
		if closing_speed > 0.0:
			lead_time = minf(lead_time, remaining / closing_speed)
		attack_point += target_velocity * lead_time
		# Rebuild the contact offset around the predicted center. Translating
		# yesterday's offset also gives the wrong approach side on crossing paths.
		approach = global_position - attack_point
		approach.y = 0.0
	var chase_destination: Vector3 = attack_point + approach.normalized() * contact_distance
	if _path_budget.try_direct_pursuit(self, chase_destination):
		# The authoritative cell cache certifies the whole body corridor on
		# this tick. Native RVO and CharacterBody collision still resolve motion.
		var direction: Vector3 = chase_destination - global_position
		direction.y = 0.0
		# Arrive at the contact point without stepping past it on a coarse tick.
		return direction.limit_length(speed * get_physics_process_delta_time()) / get_physics_process_delta_time()
	if _repath_time <= 0.0 or _path_budget.is_finished(self):
		_repath_time = randf_range(0.4, CHASE_PREDICTION_SECONDS)
		if _path_budget.is_finished(self) or _path_budget.target_position(self).distance_squared_to(chase_destination) > 1.44:
			_set_navigation_target(chase_destination)
	var desired_velocity: Vector3 = _path_velocity()
	if building and _stats.projectile.is_empty() and _path_budget.is_finished(self):
		# Finish contact with physical walls beyond a padded navigation edge.
		var wall_contact_distance: float = attack_range + radius + 1.0
		if approach.length_squared() <= wall_contact_distance * wall_contact_distance:
			desired_velocity = -approach.normalized() * speed
	return desired_velocity

func _path_velocity() -> Vector3:
	var next_position: Vector3 = _path_budget.next_position(self)
	var direction: Vector3 = next_position - global_position
	direction.y = 0.0
	if direction.length_squared() < 0.01 or _path_budget.is_finished(self):
		if _path_budget.has_pending(self):
			_face_direction(_path_budget.target_position(self) - global_position, get_physics_process_delta_time())
		return Vector3.ZERO
	return direction.normalized() * speed

func _set_avoidance_moving(moving: bool) -> void:
	if _avoidance_moving == moving:
		return
	_avoidance_moving = moving
	# RVO must route moving troops around units that have planted to attack,
	# hold or work. A zero desired velocity alone still permits lateral shoves.
	navigation_agent.max_speed = speed if moving else 0.0
	navigation_agent.avoidance_priority = 0.5 if moving else 1.0
	if prune_stationary_avoidance:
		# A zero-speed agent cannot choose a different velocity. Keep it in the
		# native neighbor tree for approaching troops, but omit its own search.
		navigation_agent.max_neighbors = _moving_neighbor_limit if moving else 0

func _apply_velocity(safe_velocity: Vector3) -> void:
	if not alive:
		return
	velocity = safe_velocity
	velocity.y = 0.0
	if velocity.length_squared() < 0.001:
		velocity = Vector3.ZERO
		_observed_velocity = Vector3.ZERO
		return
	var previous_position: Vector3 = global_position
	var delta: float = get_physics_process_delta_time()
	var proposed: Vector3 = previous_position + velocity * delta
	var certified: bool = false
	if _motion_grid.fast_path_enabled and _motion_grid.is_current and previous_position.is_finite() and proposed.is_finite() and absf(previous_position.y - _motion_grid.movement_plane_y) <= StaticMotionGrid.PLANE_EPSILON and absf(proposed.y - _motion_grid.movement_plane_y) <= StaticMotionGrid.PLANE_EPSILON:
		if _motion_region_revision != _motion_grid.revision or not _motion_region.has_point(Vector2(previous_position.x, previous_position.z)) or not _motion_region.has_point(Vector2(proposed.x, proposed.z)):
			_motion_region = _motion_grid.center_region_for_sweep(previous_position, proposed)
			_motion_region_clear = _motion_grid.certify_center_region(_motion_region, _motion_clearance)
			_motion_region_revision = _motion_grid.revision
		# Both positive and negative certificates are reused until the unit leaves
		# the region. A teleport must pass the starting-point check as well.
		certified = _motion_region_clear
	if certified:
		global_position = proposed
		_motion_grid.fast_steps += 1
	else:
		move_and_slide()
		_motion_grid.native_steps += 1
	var current_position: Vector3 = global_position
	if absf(current_position.y) > 0.001:
		current_position.y = 0.0
		global_position = current_position
	# Actual displacement preserves wall contact and pursuit on both paths.
	var displacement: Vector3 = current_position - previous_position
	displacement.y = 0.0
	_observed_velocity = displacement / delta
	# Footsteps follow actual displacement, including RVO and walls.
	var travelled: float = displacement.length()
	_foley_distance += travelled
	var horse_mounted: bool = unit_type in ["knight", "light_cavalry"]
	var stride: float = 1.65 if horse_mounted else (1.8 if unit_type in ["catapult", "cannon"] else 1.0)
	if _foley_distance >= stride:
		_foley_distance = fmod(_foley_distance, stride)
		var foot_sound: StringName = &"horse_hoof" if horse_mounted else (&"cart_wheel" if unit_type in ["catapult", "cannon"] else &"footstep_dirt")
		sound_requested.emit(foot_sound, global_position)

func _set_navigation_target(at: Vector3) -> void:
	at.y = 0.0
	if _movement_plan != null and target == null and order in [Order.MOVE, Order.ATTACK_MOVE] and at.distance_squared_to(destination) < 0.0025:
		_path_budget.request_shared(self, at, _movement_plan)
	else:
		_path_budget.request(self, at)

func _face_direction(direction: Vector3, delta: float) -> void:
	if direction.length_squared() > 0.001:
		var desired_angle: float = atan2(-direction.x, -direction.z)
		if absf(angle_difference(model_pivot.rotation.y, desired_angle)) > 0.002:
			model_pivot.rotation.y = lerp_angle(model_pivot.rotation.y, desired_angle, minf(1.0, delta * 12.0))

func _valid_target(entity: Variant) -> bool:
	# Freed cached targets must reach the validity guard before object-type checks.
	if not is_instance_valid(entity):
		return false
	# Combat has two concrete entity types. Typed reads avoid repeated dynamic
	# property lookup, scene-path lookup and owner-to-alliance conversion in the
	# hot pursuit loop. Visibility still uses the target's current position.
	if entity is BattleUnit:
		var unit: BattleUnit = entity
		return unit.alive and unit.alliance_id != alliance_id and _fog.position_visible_to_alliance(alliance_id, unit.global_position)
	if entity is BattleBuilding:
		var building: BattleBuilding = entity
		return building.alive and building.alliance_id != alliance_id and _fog.building_visible_to_alliance(alliance_id, building)
	return false

func _within_attack_range(entity: Node3D, extra: float = 0.0) -> bool:
	var attack_point: Vector3
	var target_radius: float = 0.0
	if entity is BattleUnit:
		var unit: BattleUnit = entity
		attack_point = unit.global_position
		target_radius = unit.radius
	else:
		var building: BattleBuilding = entity
		attack_point = building.get_attack_position(global_position)
	var distance: Vector3 = attack_point - global_position
	distance.y = 0.0
	var reach: float = attack_range + radius + target_radius + extra
	var minimum: float = min_attack_range + radius + target_radius if min_attack_range > 0.0 else 0.0
	var distance_squared: float = distance.length_squared()
	return distance_squared <= reach * reach and distance_squared >= minimum * minimum

func _can_start_strike(entity: Node3D) -> bool:
	if not _within_attack_range(entity):
		return false
	if _stats.projectile.is_empty() or not entity is BattleUnit:
		return true
	# Ranged weapons plant during windup. Enter a release window before
	# stopping so a steadily retreating target does not cause endless misses
	# at maximum range. Only radial motion changes that window: extending a
	# tangent vector would invent retreat for a target circling within reach
	# and leave HOLD units waiting forever. Real release still checks distance.
	var unit: BattleUnit = entity
	var direction: Vector3 = unit.global_position - global_position
	direction.y = 0.0
	var radial_speed: float = unit._observed_velocity.dot(direction.normalized())
	var release_distance: float = direction.length() + radial_speed * (_windup_seconds() + get_physics_process_delta_time())
	var reach: float = attack_range + radius + unit.radius
	var minimum: float = min_attack_range + radius + unit.radius if min_attack_range > 0.0 else 0.0
	return release_distance <= reach and release_distance >= minimum

func _refresh_target() -> void:
	var keep_current_target: bool = false
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
		elif order in [Order.IDLE, Order.ATTACK_MOVE] and attack_windup.is_stopped() and not _within_attack_range(target):
			# Crowded fronts can block the original automatic target while another
			# enemy is already in reach. Preserve explicit orders and active swings.
			keep_current_target = true
		else:
			return
	else:
		if order == Order.ATTACK_MOVE and target != null:
			_set_navigation_target(destination)
		target = null
	var previous_target: Variant = target
	var best_distance: float = INF
	_target_query.transform.origin = global_position + Vector3.UP
	for hit: Dictionary in _space_state.intersect_shape(_target_query, 64):
		var entity: Node3D = hit.collider
		if not _valid_target(entity):
			continue
		if (order == Order.HOLD or keep_current_target) and not _within_attack_range(entity):
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
	if target != null and target != previous_target:
		_repath_time = 0.0

func _start_attack() -> void:
	_strike_target = target
	_attack_cooldown = float(_stats.cooldown) + minf(0.0, _attack_cooldown)
	if unit_type == "knight" and _charge_time >= 0.95 and _charge_cooldown <= 0.0:
		_charge_cooldown = 6.0
		_game.spawn_effect(global_position + Vector3.UP * 0.2, "charge", Color("edd9a1"))
	_charge_time = 0.0
	_model.strike()
	if unit_type in ["swordsman", "shield_guard", "spearman", "knight"]:
		sound_requested.emit(&"sword_swing", global_position + Vector3.UP)
	attack_windup.start(_windup_seconds())

func _windup_seconds() -> float:
	return _stats.attack_windup_seconds

func _cancel_attack() -> void:
	attack_windup.stop()
	_strike_target = null
	# Cancellation consumes the existing cycle. Orders cannot skip recovery.

func _on_attack_windup_timeout() -> void:
	var strike_target: Variant = _strike_target
	_strike_target = null
	if not alive or not _valid_target(strike_target):
		return
	var kind: String = _stats.projectile
	if not _within_attack_range(strike_target, MELEE_CONTACT_TOLERANCE if kind.is_empty() else 0.0):
		return
	# The Timer can run a few milliseconds before AnimationPlayer in the same frame.
	# Apply the authored release pose before reading the moving weapon socket.
	_model.prepare_attack_release(attack_windup.wait_time)
	var upgrade_bonus: float = _game.get_player(owner_id).get_attack_bonus() if _stats.military else 0.0
	var payload: DamagePayload = DamageResolver.snapshot(_stats, upgrade_bonus, owner_id, alliance_id)
	if kind.is_empty():
		var effect_kind: String = strike_target.get_hit_effect() if strike_target.is_in_group("buildings") else "hit"
		var contact: Vector3 = strike_target.get_attack_position(global_position) if strike_target.is_in_group("buildings") else strike_target.global_position
		strike_target.receive_hit(payload, self)
		if unit_type == "war_elephant":
			_game.spawn_effect(global_position + model_pivot.global_basis * Vector3(.56,.08,-.77), "dust", Color("be9a72"))
		_game.spawn_effect(contact + Vector3.UP * 1.1, effect_kind, Color("f5d691"))
	else:
		if kind != "cannon":
			sound_requested.emit(&"bow_release" if kind == "arrow" else &"catapult_release", get_projectile_origin())
		_game.spawn_projectile(self, strike_target, payload, kind)
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
	_movement_plan = null
	_interrupt_work()
	order = work_order
	work_target = entity
	target = null
	_move_retaliation = null
	_cancel_attack()
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
	var reach: float = ResourceVein.WORK_REACH if order == Order.GATHER else 1.85
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
		var reached_approach: bool = _path_budget.is_finished(self)
		if order == Order.GATHER and not _path_budget.has_pending(self) and not _path_budget.is_blocked(self):
			# A contact just outside the shared navigation mesh may be within the
			# agent's target tolerance while its last path waypoint remains short
			# of that contact. Hand over at the actual final waypoint, so the
			# path follower's 10 cm stop band cannot strand a miner 24 cm away.
			# These native const getters do not issue another path query.
			var path: PackedVector3Array = navigation_agent.get_current_navigation_path()
			reached_approach = reached_approach or (not path.is_empty()
				and navigation_agent.get_current_navigation_path_index() >= path.size() - 1
				and global_position.distance_squared_to(path[-1]) <= pow(navigation_agent.path_desired_distance, 2.0))
		if reached_approach and distance.length_squared() <= pow(reach + ResourceVein.MAX_CONTACT_APPROACH, 2.0):
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
		var mining_rate: float = _game.get_player(owner_id).get_mining_rate_multiplier()
		order_name = "采集黄金 · +%d / %.2f秒" % [BalanceCatalog.ECONOMY.mining_gold, BalanceCatalog.ECONOMY.mining_seconds / mining_rate]
		# Progress stores completed base work, so researching mid-cycle preserves
		# the work already done. Fractional ticks carry into the next payout.
		_work_seconds += delta * mining_rate
		work_progress = minf(_work_seconds / BalanceCatalog.ECONOMY.mining_seconds, 1.0)
		if _work_seconds + 0.000001 >= BalanceCatalog.ECONOMY.mining_seconds:
			_work_seconds -= BalanceCatalog.ECONOMY.mining_seconds
			work_progress = maxf(0.0, _work_seconds / BalanceCatalog.ECONOMY.mining_seconds)
			gathered.emit(self, BalanceCatalog.ECONOMY.mining_gold)
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

func issue_move(at: Vector3, attack_move: bool = false, plan: MovementPlan = null) -> void:
	if not alive:
		return
	waypoint_queue.clear()
	_begin_move(at, attack_move, plan)

func queue_move(at: Vector3, attack_move: bool = false, plan: MovementPlan = null) -> void:
	if not alive:
		return
	if order in [Order.MOVE, Order.ATTACK_MOVE, Order.ATTACK, Order.GATHER, Order.BUILD]:
		if waypoint_queue.size() >= MAX_QUEUED_ORDERS:
			return
		if not waypoint_queue.is_empty():
			var last: Dictionary = waypoint_queue.back()
			if last.kind == "move" and last.attack_move == attack_move and last.position.distance_squared_to(at) < 0.01:
				return
		var step: Dictionary = {"kind": "move", "position": at, "attack_move": attack_move}
		if plan != null: step["plan"] = plan
		waypoint_queue.append(step)
	else:
		_begin_move(at, attack_move, plan)

func _begin_move(at: Vector3, attack_move: bool, plan: MovementPlan = null) -> void:
	_interrupt_work()
	_movement_plan = plan
	order = Order.ATTACK_MOVE if attack_move else Order.MOVE
	order_name = "攻击前进" if attack_move else "移动中"
	destination = _game.clamp_to_map(at)
	target = null
	_move_retaliation = null
	_cancel_attack()
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
	_movement_plan = null
	_path_budget.release_shared_plan(self)
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
	_cancel_attack()

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
			_begin_move(next_waypoint.position, next_waypoint.attack_move, next_waypoint.get("plan"))
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
	_movement_plan = null
	order = Order.IDLE
	order_name = "待命"
	target = null
	destination = global_position
	_home_position = global_position
	_scan_time = 0.0
	_cancel_attack()
	# Stop presentation state synchronously: battle completion may disable
	# physics and avoidance before another velocity callback can arrive.
	_moving = false
	_set_avoidance_moving(false)
	_model.set_motion(false)
	_path_budget.cancel(self)
	velocity = Vector3.ZERO
	_observed_velocity = Vector3.ZERO
	NavigationServer3D.agent_set_velocity(navigation_agent.get_rid(), Vector3.ZERO)

func get_combat_definition() -> CombatDefinition:
	return _stats

func receive_hit(payload: DamagePayload, source: Node3D = null) -> void:
	if not alive or payload.alliance_id == alliance_id:
		return
	var defense_bonus: float = _game.get_player(owner_id).get_defense_bonus() if _stats.military else 0.0
	_apply_damage(DamageResolver.resolve(payload, _stats, defense_bonus), source, payload.owner_id)

func receive_damage(amount: float, source: Node3D = null) -> void:
	# Explicit direct damage for scenario scripts and debugging. Combat uses receive_hit.
	if not alive or (is_instance_valid(source) and not _game.are_hostile(self, source)):
		return
	_apply_damage(maxf(0.0, amount), source, source.owner_id if is_instance_valid(source) else -1)

func _apply_damage(actual_damage: float, source: Node3D, attacker_owner: int = -1) -> void:
	if actual_damage > 0.0:
		_recovery_quiet_seconds = 0.0
		_recovery_progress = 0.0
	hp = maxf(0.0, hp - actual_damage)
	_damage_bar_time = 5.0
	_update_health_bar()
	damaged.emit(self, actual_damage)
	if hp <= 0.0:
		# Keep the lethal hit's identity, not a source-node reference or a prior
		# attacker. A projectile can outlive its shooter; self-destruction has -1.
		defeated_by_owner = attacker_owner
		_die()
		return
	if unit_type != "farmer" and _valid_target(source):
		if order == Order.MOVE:
			_move_retaliation = source
			_retaliation_time = 2.0
		elif not _valid_target(target) and (order != Order.HOLD or _within_attack_range(source)):
			target = source
			_repath_time = 0.0

func _tick_recovery(delta: float) -> void:
	if not alive or not _game.is_authority or hp >= max_hp:
		return
	var waiting: float = maxf(0.0, RECOVERY_DELAY - _recovery_quiet_seconds)
	_recovery_quiet_seconds = minf(RECOVERY_DELAY, _recovery_quiet_seconds + delta)
	var rate: float = _owner_state.get_recovery_per_second()
	if rate <= 0.0:
		_recovery_progress = 0.0
		return
	# Only time after the quiet window accrues healing, retaining fractional
	# simulation ticks at both boundaries. No wall clock, Timer or global scan.
	_recovery_progress += maxf(0.0, delta - waiting)
	if _recovery_progress + 0.000001 < 1.0:
		return
	var pulses: int = floori(_recovery_progress + 0.000001)
	_recovery_progress = maxf(0.0, _recovery_progress - pulses)
	hp = minf(max_hp, hp + pulses * rate)
	if hp >= max_hp:
		_recovery_progress = 0.0
	_update_health_bar()

func _update_health_bar() -> void:
	health_bar.set_instance_shader_parameter("health", hp / max_hp)

func _die() -> void:
	_movement_plan = null
	_interrupt_work()
	_path_budget.cancel(self)
	waypoint_queue.clear()
	alive = false
	sound_requested.emit(&"death_fall", global_position)
	order_name = "阵亡"
	set_selected(false)
	health_bar.hide()
	_cancel_attack()
	navigation_agent.avoidance_enabled = false
	velocity = Vector3.ZERO
	_observed_velocity = Vector3.ZERO
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
	fall.tween_property(model_pivot, "position:y", _stats.death_rest_height, 0.42)
	fall.chain().tween_interval(2.0)
	for mesh: GeometryInstance3D in _model.find_children("*", "GeometryInstance3D", true, false):
		_corpse_meshes.append(mesh)
	fall.chain().tween_method(_fade_corpse, 0.0, 1.0, 1.8)
	fall.chain().tween_callback(queue_free)

func _fade_corpse(amount: float) -> void:
	_model.set_batch_fade(amount)
	for mesh: GeometryInstance3D in _corpse_meshes:
		mesh.transparency = amount
