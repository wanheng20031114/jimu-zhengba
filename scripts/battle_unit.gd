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
	"heavy_cannon": preload("res://assets/models/units/heavy_cannon.tscn"),
	"triple_cannon": preload("res://assets/models/units/triple_cannon.tscn"),
	"farmer": preload("res://assets/models/units/farmer.tscn"),
	"engineer": preload("res://assets/models/units/engineer.tscn"),
	"priest": preload("res://assets/models/units/priest.tscn"),
}

const STATS: Dictionary = BalanceCatalog.UNITS

enum Order { IDLE, MOVE, ATTACK_MOVE, ATTACK, HOLD, GATHER, BUILD, SUPPORT }
const MAX_QUEUED_ORDERS: int = 64
const CHASE_PREDICTION_SECONDS: float = 0.55
const RECOVERY_DELAY: float = 10.0
# A small contact tolerance (about one knight step at the authoritative 30 TPS),
# rather than the former 1.4-meter extension. Faster targets can still escape.
const MELEE_CONTACT_TOLERANCE: float = 0.2
const CONGESTION_SECONDS: float = 0.6
const BODY_RADIUS_SCALE: float = 0.85

@export_enum("swordsman", "shield_guard", "spearman", "archer", "knight", "war_elephant", "light_cavalry", "catapult", "cannon", "heavy_cannon", "triple_cannon", "engineer", "priest", "farmer") var unit_type: String = "swordsman"
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
		return _base_or_replicated_range + (_owner_state.get_cannon_range_bonus() if _game != null and _game.is_authority and _stats.cannon_range_upgrades else 0.0)
	set(value):
		_base_or_replicated_range = value
var attack_damage: float = 20.0
var min_attack_range: float = 0.0
var order_name: String = "待命"
var order: Order = Order.IDLE
var target: Node3D:
	set(value):
		if target == value:
			return
		_release_melee_claim()
		target = value
		_sync_melee_claim()
var melee_pressure := MeleePressure.new()
var passage := FriendlyPassage.new()
var _melee_fighter: bool = false
var _claimed_pressure: MeleePressure
var _claim_sector: int = 0
var _claim_arc: float = 0.0
var _claim_alliance: int = 0
var _next_rebalance_frame: int = 0
var melee_rebalances: int = 0
var _approach_queued: bool = false
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
var _navigation_route: PathBudget.Route
var _avoidance_rid: RID
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
var _avoidance_speed_limit: float = 0.0
var _moving_neighbor_limit: int = 10
var _observed_velocity := Vector3.ZERO
var _congestion_seconds: float = 0.0
var _congestion_wait: float = 0.0
var _congestion_target: Node3D
var _congestion_probe: bool = false
var _blocked_intent := Vector3.ZERO
var _preferred_speed_squared: float = 0.0
var _preferred_velocity := Vector3.ZERO
var _move_retaliation: Node3D
var _retaliation_time: float = 0.0
var _corpse_meshes: Array[GeometryInstance3D] = []
var _target_query: PhysicsShapeQueryParameters3D
var _target_shape := BoxShape3D.new()
var _target_extent: float = -1.0
var _largest_unit_radius: float = 0.0
var _unit_query_padding: float = 0.001
var _sight_query_padding: float = 0.001
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
@onready var support: UnitSupport = $Support
@onready var battery: UnitBattery = $Battery

func _ready() -> void:
	if owner_id < 0:
		owner_id = alliance_id
	_stats = BalanceCatalog.unit(unit_type)
	_melee_fighter = _stats.military and _stats.projectile.is_empty()
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
	for definition: UnitDefinition in BalanceCatalog.UNITS.values():
		_largest_unit_radius = maxf(_largest_unit_radius, definition.radius)
		_unit_query_padding = maxf(_unit_query_padding, definition.radius * (1.0 - BODY_RADIUS_SCALE) + 0.001)
	_sight_query_padding = _unit_query_padding
	for definition: BuildingDefinition in BalanceCatalog.BUILDINGS.values():
		# intersect_shape already includes the target's physical footprint.
		# A building contains a disk of this radius at every planar rotation.
		var inscribed_radius: float = minf(definition.size.x, definition.size.z) * 0.5
		_sight_query_padding = maxf(_sight_query_padding, definition.radius - inscribed_radius + 0.001)
	_target_query = PhysicsShapeQueryParameters3D.new()
	_target_query.shape = _target_shape
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
		_model.bind_render_batches(render_batches, _game.is_authority)
	_attack_animation = _model.get_node("Attack")
	model_pivot.rotation.y = rotation.y
	rotation.y = 0.0
	_model.set_motion(false)
	navigation_agent.radius = radius
	_avoidance_rid = navigation_agent.get_rid()
	navigation_agent.max_speed = 0.0
	navigation_agent.neighbor_distance = 5.5
	navigation_agent.avoidance_priority = 1.0
	_moving_neighbor_limit = navigation_agent.max_neighbors
	if prune_stationary_avoidance:
		navigation_agent.max_neighbors = 0
	var capsule: CapsuleShape3D = $CollisionShape3D.shape
	capsule.radius = radius * BODY_RADIUS_SCALE
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
	battery.configure(self)
	support.configure(self)

func _physics_process(delta: float) -> void:
	if not alive or not _game.is_authority:
		return
	_tick_recovery(delta)
	# Recipient healing deadlines use the match clock. Only actual providers
	# need a discovery timer and job selection; ordinary troops do neither.
	if support.is_supporter:
		support.advance_clock(delta)
	# Keep the fractional tick at expiry for continuous attacks (e.g. 1.05 s
	# at 30 physics ticks). An already-ready unit never banks idle attack time.
	_attack_cooldown = _attack_cooldown - delta if _attack_cooldown > 0.0 else 0.0
	_charge_cooldown = maxf(0.0, _charge_cooldown - delta)
	_damage_bar_time = maxf(0.0, _damage_bar_time - delta)
	_retaliation_time = maxf(0.0, _retaliation_time - delta)
	_scan_time -= delta
	_repath_time -= delta
	_congestion_wait = maxf(0.0, _congestion_wait - delta)
	_congestion_probe = false
	var show_health: bool = selected or _damage_bar_time > 0.0 or hp < max_hp
	if health_bar.visible != show_health:
		health_bar.visible = show_health
	# Reuse validity only within this synchronous unit tick. Order completion
	# and scanning may replace the target; a different reference is checked
	# before use. The attack Timer independently revalidates at actual release.
	var checked_target: Variant = target
	var target_valid: bool = _valid_target(checked_target)
	# Resolve a death immediately, before a completed chase path can consume the order.
	if not target_valid and not battery.winding and (order == Order.ATTACK or target != null):
		target = null
		if order == Order.ATTACK:
			_complete_waypoint()
		elif order == Order.ATTACK_MOVE:
			_set_navigation_target(destination)
	if _scan_time <= 0.0 and not battery.winding:
		_scan_time = randf_range(0.3, 0.4)
		_refresh_target()
		if target == _congestion_target and _congestion_seconds >= CONGESTION_SECONDS:
			_path_budget.combat_approaches.enqueue(self)
	if target != checked_target:
		checked_target = target
		target_valid = _valid_target(checked_target)
	if target != _congestion_target:
		if target_valid and _congestion_seconds >= CONGESTION_SECONDS:
			# A new automatic target gets one immediate movement probe. Only
			# actual forward progress wakes sustained RVO work in a blocked rank.
			_congestion_wait = 0.0
		else:
			_reset_congestion()
		_congestion_target = target
	var desired_velocity := Vector3.ZERO
	var facing_direction := Vector3.ZERO
	var path_velocity_requested: bool = false
	if passage.remaining > 0.0 and target_valid and _can_start_strike(target):
		passage.cancel()
	if battery.enabled and battery.engage(target):
		facing_direction = battery.facing
	elif passage.remaining > 0.0:
		desired_velocity = passage.velocity(self, delta)
	elif support.is_supporter and support.select_job():
		desired_velocity = support.velocity_for_job(delta)
	elif order == Order.GATHER or order == Order.BUILD:
		desired_velocity = _work_velocity(delta)
	elif target_valid:
		var windup_active: bool = not attack_windup.is_stopped()
		var can_start_strike: bool = _can_start_strike(target)
		if can_start_strike:
			_congestion_wait = 0.0
			_congestion_seconds = 0.0
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
			if _congestion_wait <= 0.0:
				desired_velocity = _chase_velocity(target)
				path_velocity_requested = true
				_congestion_probe = not can_start_strike and min_attack_range == 0.0 and order in [Order.IDLE, Order.ATTACK_MOVE, Order.ATTACK]
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
	_preferred_speed_squared = desired_velocity.length_squared()
	_preferred_velocity = desired_velocity
	if is_moving:
		facing_direction = desired_velocity
		if unit_type == "knight" and _charge_cooldown <= 0.0:
			_charge_time = minf(_charge_time + delta, 2.0)
	else:
		_charge_time = maxf(0.0, _charge_time - delta * 0.25)
	if facing_direction.length_squared() > 0.001:
		_face_direction(facing_direction, delta)
	# A one-tick congestion probe must not restart walking animation on a unit
	# that is still unable to move. Successful motion releases this state below.
	var visually_moving: bool = is_moving and _congestion_seconds < CONGESTION_SECONDS
	if visually_moving != _moving:
		_moving = visually_moving
		_model.set_motion(_moving)
	if navigation_agent.avoidance_enabled:
		_set_avoidance_moving(is_moving)
		# Feed the native RVO agent directly: route progression is owned by
		# PathBudget, including direct movement and the final wall-contact step.
		NavigationServer3D.agent_set_velocity(_avoidance_rid, desired_velocity)
	else:
		_apply_velocity(desired_velocity)

func _chase_velocity(entity: Node3D) -> Vector3:
	var origin: Vector3 = global_position
	var building: bool = entity is BattleBuilding
	var attack_point: Vector3
	var target_radius: float = 0.0
	var target_velocity := Vector3.ZERO
	if building:
		var structure: BattleBuilding = entity
		attack_point = structure.get_attack_position(origin)
	else:
		var unit: BattleUnit = entity
		attack_point = unit.global_position
		target_radius = unit.radius
		target_velocity = unit._observed_velocity
		target_velocity.y = 0.0
	var approach: Vector3 = origin - attack_point
	approach.y = 0.0
	if approach.length_squared() < 0.01:
		approach = Vector3.RIGHT
	var spacing: float = maxf(attack_range * 0.6, min_attack_range + 0.35)
	var contact_distance: float = target_radius + radius + spacing
	var approach_length: float = approach.length()
	var approach_direction: Vector3 = approach / approach_length
	if not target_velocity.is_zero_approx():
		# Lead only as far as the remaining approach permits. A fixed time lead
		# can cross behind us when a fast enemy approaches, ordering a retreat.
		# Include incoming radial speed in the closing time, but keep the full
		# replan horizon for distant or fleeing targets. Use actual planar motion.
		var remaining: float = maxf(0.0, approach_length - contact_distance)
		var closing_speed: float = speed + target_velocity.dot(approach_direction)
		var lead_time: float = CHASE_PREDICTION_SECONDS
		if closing_speed > 0.0:
			lead_time = minf(lead_time, remaining / closing_speed)
		attack_point += target_velocity * lead_time
		# Rebuild the contact offset around the predicted center. Translating
		# yesterday's offset also gives the wrong approach side on crossing paths.
		approach = origin - attack_point
		approach.y = 0.0
		approach_direction = approach.normalized()
	var chase_destination: Vector3 = attack_point + approach_direction * contact_distance
	if _path_budget.try_direct_pursuit(self, chase_destination):
		# The authoritative cell cache certifies the whole body corridor on
		# this tick. Native RVO and CharacterBody collision still resolve motion.
		var direction: Vector3 = chase_destination - origin
		direction.y = 0.0
		# Arrive at the contact point without stepping past it on a coarse tick.
		var delta: float = get_physics_process_delta_time()
		return direction.limit_length(speed * delta) / delta
	var route_finished: bool = _path_budget.is_finished(self)
	if _repath_time <= 0.0 or route_finished:
		_repath_time = randf_range(0.4, CHASE_PREDICTION_SECONDS)
		if route_finished or _path_budget.target_position(self).distance_squared_to(chase_destination) > 1.44:
			_set_navigation_target(chase_destination)
	var desired_velocity: Vector3 = _path_velocity()
	if building and _stats.projectile.is_empty() and _path_budget.is_finished(self):
		# Finish contact with physical walls beyond a padded navigation edge.
		var wall_contact_distance: float = attack_range + radius + 1.0
		if approach.length_squared() <= wall_contact_distance * wall_contact_distance:
			desired_velocity = -approach_direction * speed
	return desired_velocity

func _path_velocity() -> Vector3:
	var next_position: Vector3 = _path_budget.next_position(self)
	var direction: Vector3 = next_position - global_position
	direction.y = 0.0
	if direction.length_squared() < 0.01 or _path_budget.is_finished(self):
		return Vector3.ZERO
	# Never overshoot a short waypoint on a coarse physics tick. Waiting for
	# a route keeps the existing heading; the final goal may be behind a wall.
	var delta: float = get_physics_process_delta_time()
	return direction.limit_length(speed * delta) / delta

func _set_avoidance_moving(moving: bool) -> void:
	var maximum_speed: float = (minf(speed, FriendlyPassage.STEP_SPEED) if passage.remaining > 0.0 else speed) if moving else 0.0
	if _avoidance_moving == moving and _avoidance_speed_limit == maximum_speed:
		return
	_avoidance_moving = moving
	_avoidance_speed_limit = maximum_speed
	# RVO must route moving troops around units that have planted to attack,
	# hold or work. A zero desired velocity alone still permits lateral shoves.
	# Bound the RVO solution itself during a sidestep; clipping its returned
	# velocity afterwards could violate the collision-avoidance constraints.
	navigation_agent.max_speed = maximum_speed
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
	if _congestion_probe and _preferred_speed_squared > speed * speed * 0.25:
		# Observe RVO's permitted forward progress, not wall collision or distance
		# to a fleeing target. Brief side steps remain uninterrupted; a pursuit
		# with less than 20% forward progress for 0.6 s briefly yields. Every new
		# order clears this wait, including an explicit attack on the same target.
		if velocity.dot(_preferred_velocity) < _preferred_speed_squared * 0.2:
			_blocked_intent = _preferred_velocity
			_congestion_seconds += get_physics_process_delta_time()
			if _congestion_seconds + 0.000001 >= CONGESTION_SECONDS:
				_congestion_seconds = CONGESTION_SECONDS
				_congestion_wait = 0.18 + (entity_id % 4) * 0.033
		else:
			_congestion_seconds = 0.0
			_congestion_wait = 0.0
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
	var stride: float = 1.65 if horse_mounted else (1.8 if _stats.combat_class == &"siege" else 1.0)
	if _foley_distance >= stride:
		_foley_distance = fmod(_foley_distance, stride)
		var foot_sound: StringName = &"horse_hoof" if horse_mounted else (&"cart_wheel" if _stats.combat_class == &"siege" else &"footstep_dirt")
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
		# Read the native Basis-to-Euler conversion once. Assigning rotation.y
		# would read the complete native property again for the component write.
		var facing: Vector3 = model_pivot.rotation
		if absf(angle_difference(facing.y, desired_angle)) > 0.002:
			facing.y = lerp_angle(facing.y, desired_angle, minf(1.0, delta * 12.0))
			model_pivot.rotation = facing

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
	_sync_melee_claim()
	var keep_current_target: bool = false
	# Workers finish economic orders even under fire. An explicit attack still
	# lets the player use a pickaxe for self-defence.
	if unit_type == "farmer" and order != Order.ATTACK:
		target = null
		return
	if support.enabled() and order != Order.ATTACK:
		# Supporters defend only in contact when no work owns their action.
		if order == Order.SUPPORT or is_instance_valid(support.recipient):
			target = null
			return
		if not _valid_target(target) or not _within_attack_range(target):
			target = null
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
	var nearby: Node3D = _find_auto_target(order == Order.HOLD or keep_current_target or support.enabled(), _melee_fighter)
	if nearby != null:
		target = nearby
	if target != null and target != previous_target:
		_repath_time = 0.0

func _resolve_combat_congestion() -> void:
	# Queued work revalidates the current order; death, player commands and
	# contact can all happen while waiting for the shared budget.
	if not alive or not _game.is_authority or _congestion_seconds < CONGESTION_SECONDS or passage.remaining > 0.0 or order not in [Order.IDLE, Order.ATTACK_MOVE, Order.ATTACK] or not attack_windup.is_stopped() or not _valid_target(target) or _within_attack_range(target):
		return
	var frame: int = Engine.get_physics_frames()
	if frame < _next_rebalance_frame:
		return
	_next_rebalance_frame = frame + ceili((1.0 + (entity_id % 4) * 0.1) * Engine.physics_ticks_per_second)
	if _melee_fighter and order != Order.ATTACK:
		_sync_melee_claim()
		# Congestion is a local problem. A rear rank without an enemy nearby
		# keeps its existing route instead of scanning the whole enemy army.
		var search_radius: float = minf(8.0, minf(float(_stats.sight), global_position.distance_to(target.global_position) + 3.0))
		melee_rebalances += 1
		var nearby: Node3D = _find_auto_target(false, true, search_radius)
		if nearby != null and nearby != target:
			# Preserve an approach unless the new score is materially better.
			var current_score: float = _melee_target_score(target, global_position.distance_squared_to(target.global_position))
			var next_score: float = _melee_target_score(nearby, global_position.distance_squared_to(nearby.global_position))
			if _within_attack_range(nearby) or next_score < current_score * 0.75:
				target = nearby
				_repath_time = 0.0
				return
	passage.request(self)

func _find_auto_target(contact_only: bool, coordinate_melee: bool = false, search_radius: float = -1.0) -> Node3D:
	# The broad phase follows the decision being made. Rear ranks with a valid
	# chase target only need a replacement already in weapon reach, not all the
	# enemies in their sight. Keep native collision-space indexing and the exact
	# range/visibility checks; do not reduce the scan rate or truncate candidates.
	var reach: float = attack_range + radius
	var sight_radius: float = float(_stats.sight) if search_radius < 0.0 else search_radius
	# The native query intersects volumes, not centers. Add only the gap
	# between combat radius and physical radius; adding the entire enemy
	# radius counts its body twice and returns much of the rear enemy army.
	var extent: float = reach + _unit_query_padding if contact_only else sight_radius + _sight_query_padding
	if extent != _target_extent:
		_target_extent = extent
		# Combat is planar. The box covers the bases of every authored ground
		# body, including large units and building edges at the range boundary.
		_target_shape.size = Vector3(extent * 2.0, 2.0, extent * 2.0)
	var origin: Vector3 = global_position
	_target_query.transform.origin = origin + Vector3.UP
	var best_distance: float = INF
	var best: Node3D
	var best_in_contact: bool = false
	# intersect_shape does not promise nearest-first results. A fixed 64-result
	# cap can hide the nearest eligible enemy in a dense battle. Each combat
	# entity owns one body shape, so the native group count bounds all results
	# without copying the group or depending on a particular match fixture.
	for hit: Dictionary in _space_state.intersect_shape(_target_query, get_tree().get_node_count_in_group(&"entities")):
		var entity: Node3D = hit.collider
		var building: bool = entity is BattleBuilding
		var distance: float = origin.distance_squared_to(entity.global_position)
		if not contact_only:
			var sight: float = sight_radius + entity.radius
			if distance > sight * sight:
				continue
		var priority_distance: float = distance * (1.3 if building else 1.0)
		var in_contact: bool = coordinate_melee and not contact_only and (distance <= (reach + entity.radius) * (reach + entity.radius) if not building else _within_attack_range(entity))
		if best_in_contact and not in_contact:
			continue
		# Geometric distance is a lower bound: occupancy can only add cost.
		# Reject it before angle/footprint scoring, just as the contact query
		# rejects distant bodies before visibility and exact shape checks.
		if in_contact == best_in_contact and priority_distance > best_distance:
			continue
		if coordinate_melee and not contact_only and not in_contact:
			priority_distance = _melee_target_score(entity, distance)
		if in_contact == best_in_contact and priority_distance > best_distance:
			continue
		if contact_only:
			if not _within_attack_range(entity):
				continue
		# Reject distance and weapon dead zones before fog queries. Usually only
		# a handful of closer candidates need authoritative visibility checks.
		if not _valid_target(entity):
			continue
		if in_contact == best_in_contact and priority_distance == best_distance and best != null and entity.entity_id >= best.entity_id:
			continue
		best_distance = priority_distance
		best = entity
		best_in_contact = in_contact
	return best

func _release_melee_claim() -> void:
	if _claimed_pressure == null:
		return
	_claimed_pressure.add(_claim_alliance, _claim_sector, -_claim_arc)
	_claimed_pressure = null

func _sync_melee_claim() -> void:
	if not _melee_fighter or not alive or not is_instance_valid(target) or not target is BattleUnit or _game == null or not _game.is_authority:
		_release_melee_claim()
		return
	var victim: BattleUnit = target
	if not victim.alive or victim.alliance_id == alliance_id:
		_release_melee_claim()
		return
	var approach: int = MeleePressure.sector(global_position - victim.global_position)
	if _claimed_pressure == victim.melee_pressure and _claim_sector == approach and _claim_alliance == alliance_id:
		return
	_release_melee_claim()
	_claimed_pressure = victim.melee_pressure
	_claim_alliance = alliance_id
	_claim_sector = approach
	_claim_arc = MeleePressure.footprint(radius, radius + victim.radius + attack_range * 0.6)
	_claimed_pressure.add(_claim_alliance, _claim_sector, _claim_arc)

func _melee_target_score(entity: Node3D, distance_squared: float) -> float:
	if not entity is BattleUnit:
		return distance_squared * 1.3
	var victim: BattleUnit = entity
	var contact: float = radius + victim.radius + attack_range * 0.6
	var approach: int = MeleePressure.sector(global_position - victim.global_position)
	var incoming: float = 0.0 if _claimed_pressure == victim.melee_pressure else MeleePressure.footprint(radius, contact)
	var queue_distance: float = victim.melee_pressure.excess(alliance_id, approach, incoming) * contact
	return pow(sqrt(distance_squared) + queue_distance, 2.0)

func _start_attack() -> void:
	if battery.enabled:
		battery.engage(target)
		return
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
	battery.cancel()
	_strike_target = null
	# Cancellation consumes the existing cycle. Orders cannot skip recovery.

func _on_attack_windup_timeout() -> void:
	if battery.enabled:
		battery.release_due()
		return
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

func get_projectile_origin(barrel_index: int = 0) -> Vector3:
	return _model.get_projectile_origin(barrel_index)

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
	if queued and order in [Order.MOVE, Order.ATTACK_MOVE, Order.ATTACK, Order.GATHER, Order.BUILD, Order.SUPPORT]:
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
			# Reading the owned route cursor cannot issue another path query.
			reached_approach = reached_approach or _path_budget.at_path_end(self, navigation_agent.path_desired_distance)
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
	_model.set_working(value, String(_stats.support_kind) if support.enabled() else ("gather" if order == Order.GATHER else "build"))
	if value:
		_work_sound_time = 0.45
		work_bar.set_instance_shader_parameter("bar_color", Color("e9bf5c") if order == Order.GATHER else Color("72c6d8"))

func _interrupt_work() -> void:
	passage.cancel()
	support.cancel()
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
	_release_melee_claim()
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
	if order in [Order.MOVE, Order.ATTACK_MOVE, Order.ATTACK, Order.GATHER, Order.BUILD, Order.SUPPORT]:
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
	_reset_congestion()
	_interrupt_work()
	support.auto_allowed = true
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
	if queued and order in [Order.MOVE, Order.ATTACK_MOVE, Order.ATTACK, Order.GATHER, Order.BUILD, Order.SUPPORT]:
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
	_reset_congestion()
	_movement_plan = null
	_path_budget.release_shared_plan(self)
	var same_attack: bool = target == entity and (battery.enabled or attack_windup.is_stopped() or _strike_target == entity)
	_interrupt_work()
	support.auto_allowed = true
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
	_reset_congestion()
	_finish_order()
	support.auto_allowed = false

func _reset_congestion() -> void:
	_congestion_seconds = 0.0
	_congestion_wait = 0.0
	_congestion_probe = false
	_blocked_intent = Vector3.ZERO

func hold(queued: bool = false) -> void:
	if not alive:
		return
	if queued and order in [Order.MOVE, Order.ATTACK_MOVE, Order.ATTACK, Order.GATHER, Order.BUILD, Order.SUPPORT]:
		if waypoint_queue.size() < MAX_QUEUED_ORDERS and (waypoint_queue.is_empty() or waypoint_queue.back().kind != "hold"):
			waypoint_queue.append({"kind": "hold"})
		return
	stop()
	support.auto_allowed = true
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
		if next_waypoint.kind == "support":
			if support.valid_target(next_entity):
				_begin_support(next_entity)
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

func issue_support(entity: Node3D, queued: bool = false) -> bool:
	if not alive or not _game.is_authority or not support.valid_target(entity):
		return false
	if queued and order in [Order.MOVE, Order.ATTACK_MOVE, Order.ATTACK, Order.GATHER, Order.BUILD, Order.SUPPORT]:
		if waypoint_queue.is_empty() and order == Order.SUPPORT and work_target == entity:
			return true
		if not waypoint_queue.is_empty() and waypoint_queue.back().kind == "support" and waypoint_queue.back().entity == entity:
			return true
		if waypoint_queue.size() >= MAX_QUEUED_ORDERS: return false
		waypoint_queue.append({"kind": "support", "entity": entity})
		return true
	waypoint_queue.clear()
	if order != Order.SUPPORT or work_target != entity:
		_begin_support(entity)
	return true

func _begin_support(entity: BattleUnit) -> void:
	_interrupt_work()
	support.auto_allowed = true
	_movement_plan = null
	_path_budget.release_shared_plan(self)
	order = Order.SUPPORT
	work_target = entity
	target = null
	_move_retaliation = null
	_cancel_attack()
	order_name = "前往" + support.action_name() + entity.display_name

func restore_health(amount: float) -> float:
	if not alive or not _game.is_authority or not is_finite(amount) or amount <= 0.0:
		return 0.0
	var restored: float = minf(max_hp - hp, amount)
	hp += restored
	_update_health_bar()
	return restored

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
	if unit_type != "farmer" and _valid_target(source) and (not support.enabled() or (not is_instance_valid(support.recipient) and order != Order.SUPPORT and _within_attack_range(source))):
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
	target = null
	support.shutdown()
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
