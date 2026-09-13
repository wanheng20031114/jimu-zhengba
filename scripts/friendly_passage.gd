class_name FriendlyPassage
extends RefCounted
## Event-driven, one-neighbour sidestep. Native RVO and body collision move it.
## This is a temporary velocity, never a replacement order or a recursive push.
const RETRY_SECONDS: float = 1.2
const STEP_SPEED: float = 2.5
const STEP_SECONDS: float = 1.5

var remaining: float = 0.0
var destination := Vector3.ZERO
var next_request_frame: int = 0
var next_yield_frame: int = 0
var requests: int = 0
var accepted: int = 0
var _query: PhysicsShapeQueryParameters3D

func cancel() -> void:
	remaining = 0.0

static func _available(unit: BattleUnit) -> bool:
	if not unit.alive or unit.order not in [BattleUnit.Order.IDLE, BattleUnit.Order.ATTACK_MOVE, BattleUnit.Order.ATTACK]:
		return false
	if not unit.attack_windup.is_stopped() or unit._working or is_instance_valid(unit.support.recipient):
		return false
	return not is_instance_valid(unit.target) or not unit._within_attack_range(unit.target)

func velocity(unit: BattleUnit, delta: float) -> Vector3:
	if not _available(unit):
		cancel()
		return Vector3.ZERO
	remaining = maxf(0.0, remaining - delta)
	var offset: Vector3 = destination - unit.global_position
	if offset.length_squared() < 0.0064:
		cancel()
		return Vector3.ZERO
	return offset.limit_length(minf(unit.speed, STEP_SPEED) * delta) / delta

func request(unit: BattleUnit) -> bool:
	var frame: int = Engine.get_physics_frames()
	if frame < next_request_frame or remaining > 0.0 or unit._blocked_intent.length_squared() < 0.08:
		return false
	next_request_frame = frame + ceili(RETRY_SECONDS * Engine.physics_ticks_per_second)
	requests += 1
	if _query == null:
		_query = PhysicsShapeQueryParameters3D.new()
		var shape := BoxShape3D.new()
		var extent: float = unit.radius + unit._largest_unit_radius * 4.0 + 1.0
		shape.size = Vector3(extent * 2.0, 2.0, extent * 2.0)
		_query.shape = shape
		_query.collision_mask = CombatLayers.ALL_UNITS
	var origin: Vector3 = unit.global_position
	_query.transform.origin = origin + Vector3.UP
	var neighbours: Array[Dictionary] = unit._space_state.intersect_shape(_query, unit.get_tree().get_node_count_in_group(&"units"))
	var forward: Vector3 = unit._blocked_intent.normalized()
	var side := Vector3(-forward.z, 0.0, forward.x)
	var blocker: BattleUnit
	var nearest: float = INF
	for hit: Dictionary in neighbours:
		var other: BattleUnit = hit.collider
		if other == unit or other.alliance_id != unit.alliance_id:
			continue
		var offset: Vector3 = other.global_position - origin
		var ahead: float = offset.dot(forward)
		var clearance: float = unit.radius + other.radius + 0.25
		if ahead <= 0.05 or ahead > clearance + 0.6 or absf(offset.dot(side)) >= clearance or ahead >= nearest:
			continue
		if other.passage.remaining > 0.0 or frame < other.passage.next_yield_frame or not _available(other):
			continue
		if other._preferred_speed_squared > 0.08 and other._congestion_seconds < BattleUnit.CONGESTION_SECONDS:
			continue
		nearest = ahead
		blocker = other
	if blocker == null:
		return false
	var lateral: float = (blocker.global_position - origin).dot(side)
	var first_side: float = signf(lateral) if absf(lateral) > 0.08 else (1.0 if blocker.entity_id % 2 == 0 else -1.0)
	for sign_value: float in [first_side, -first_side]:
		var distance: float = unit.radius + blocker.radius + 0.3 - lateral * sign_value
		if distance > minf(blocker.speed, STEP_SPEED) * STEP_SECONDS:
			continue
		var motion: Vector3 = side * sign_value * maxf(0.35, distance)
		var at: Vector3 = blocker.global_position + motion
		if not at.is_equal_approx(unit._game.clamp_to_map(at)) or blocker.test_move(blocker.global_transform, motion):
			continue
		var clear: bool = true
		for hit: Dictionary in neighbours:
			var other: BattleUnit = hit.collider
			if other == blocker or not other.alive:
				continue
			var clearance: float = blocker.radius + other.radius + 0.1
			if at.distance_squared_to(other.global_position) < clearance * clearance or (other.passage.remaining > 0.0 and at.distance_squared_to(other.passage.destination) < clearance * clearance):
				clear = false
				break
		if not clear:
			continue
		blocker.passage.destination = at
		blocker.passage.remaining = STEP_SECONDS
		blocker.passage.next_yield_frame = frame + ceili((STEP_SECONDS + RETRY_SECONDS) * Engine.physics_ticks_per_second)
		blocker._reset_congestion()
		accepted += 1
		return true
	return false
