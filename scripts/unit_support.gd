class_name UnitSupport
extends Node
## One saved component owns outgoing work and the recipient's exclusive claim.
## The BattleUnit fixed tick drives it; animations never modify health.
var unit: BattleUnit
var recipient: BattleUnit
var provider: UnitSupport
var recovery_gap: float = 0.0
var work_seconds: float = 0.0
var auto_allowed: bool = true
var _scan_seconds: float = 0.0
var _auto_anchor := Vector3.ZERO
var _auto_area_active: bool = false
var _query: PhysicsShapeQueryParameters3D

func configure(value: BattleUnit) -> void:
	unit = value
	if unit._stats.support_kind.is_empty():
		return
	_query = PhysicsShapeQueryParameters3D.new()
	var shape := SphereShape3D.new()
	shape.radius = unit._stats.support_discovery_range + unit.radius
	_query.shape = shape
	_query.collision_mask = CombatLayers.UNIT_LAYERS[unit.alliance_id]

func enabled() -> bool:
	return not unit._stats.support_kind.is_empty()

func valid_target(candidate: Variant, require_damage: bool = true) -> bool:
	return is_instance_valid(candidate) and candidate is BattleUnit and candidate != unit and candidate.alive \
		and candidate.alliance_id == unit.alliance_id and unit._stats.support_kind == &"repair" \
		and candidate._stats.combat_class == &"siege" and (not require_damage or candidate.hp < candidate.max_hp)

func edge_distance(candidate: BattleUnit, at: Vector3) -> float:
	return maxf(0.0, at.distance_to(candidate.global_position) - unit.radius - candidate.radius)

func available(candidate: BattleUnit) -> bool:
	return not is_instance_valid(candidate.support.provider) or candidate.support.provider == self

func advance_clock(delta: float) -> void:
	recovery_gap = maxf(0.0, recovery_gap - delta)
	_scan_seconds -= delta

func _choose_target() -> BattleUnit:
	_query.transform.origin = unit.global_position + Vector3.UP
	var candidates: Array[BattleUnit] = []
	for hit: Dictionary in unit._space_state.intersect_shape(_query, 512):
		var other: Variant = hit.collider
		if not valid_target(other) or not available(other):
			continue
		if _auto_area_active and edge_distance(other, _auto_anchor) > unit._stats.support_discovery_range:
			continue
		var reach: float = unit._stats.support_range if unit.order == BattleUnit.Order.HOLD else unit._stats.support_discovery_range
		if edge_distance(other, unit.global_position) <= reach:
			candidates.append(other)
	candidates.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool:
		var a_health := a.hp / a.max_hp
		var b_health := b.hp / b.max_hp
		if not is_equal_approx(a_health, b_health): return a_health < b_health
		var a_distance := unit.global_position.distance_squared_to(a.global_position)
		var b_distance := unit.global_position.distance_squared_to(b.global_position)
		return a.entity_id < b.entity_id if is_equal_approx(a_distance, b_distance) else a_distance < b_distance)
	return candidates[0] if not candidates.is_empty() else null

func select_job() -> bool:
	if not enabled(): return false
	var manual := unit.order == BattleUnit.Order.SUPPORT
	if not manual and not auto_allowed: return false
	if not manual and unit.order not in [BattleUnit.Order.IDLE, BattleUnit.Order.ATTACK_MOVE, BattleUnit.Order.HOLD]:
		release()
		return false
	# Attack-move may open another search area after actually travelling onward.
	if unit.order == BattleUnit.Order.ATTACK_MOVE and not is_instance_valid(recipient) and unit.global_position.distance_to(_auto_anchor) > unit._stats.support_discovery_range:
		_auto_area_active = false
	if manual and not valid_target(unit.work_target):
		unit._complete_waypoint()
		return false
	if is_instance_valid(recipient):
		var outside_leash: bool = not manual and edge_distance(recipient, _auto_anchor) > unit._stats.support_discovery_range
		if not valid_target(recipient) or not available(recipient) or outside_leash \
				or (unit.order == BattleUnit.Order.HOLD and edge_distance(recipient, unit.global_position) > unit._stats.support_range):
			release()
	if not is_instance_valid(recipient):
		if _scan_seconds > 0.0: return manual
		_scan_seconds = 0.35
		var requested: BattleUnit = unit.work_target as BattleUnit if manual else null
		var chosen: BattleUnit = requested if manual and available(requested) else _choose_target()
		if chosen != null:
			recipient = chosen
			recipient.support.provider = self
			if not manual and not _auto_area_active:
				_auto_anchor = unit.global_position
				_auto_area_active = true
			unit._repath_time = 0.0
	if is_instance_valid(recipient):
		unit.target = null
		unit._cancel_attack()
	return manual or is_instance_valid(recipient)

func velocity_for_job(delta: float) -> Vector3:
	if not is_instance_valid(recipient):
		unit.order_name = "等待维修目标空闲"
		unit._set_working(false)
		return Vector3.ZERO
	var distance := edge_distance(recipient, unit.global_position)
	if distance > unit._stats.support_range:
		unit._set_working(false)
		unit.order_name = "前往维修" + recipient.display_name
		if unit.order == BattleUnit.Order.HOLD: return Vector3.ZERO
		var direction := unit.global_position - recipient.global_position
		direction.y = 0.0
		var at := recipient.global_position + direction.normalized() * (unit.radius + recipient.radius + unit._stats.support_range * .65)
		if unit._path_budget.try_direct_pursuit(unit, at):
			return (at - unit.global_position).limit_length(unit.speed * delta) / delta
		if unit._repath_time <= 0.0:
			unit._repath_time = 0.35
			unit._set_navigation_target(at)
		return unit._path_velocity()
	unit._face_direction(recipient.global_position - unit.global_position, delta)
	# Plant before work starts; native avoidance/CharacterBody still owns motion.
	if unit._observed_velocity.length_squared() > .001:
		unit._set_working(false)
		return Vector3.ZERO
	var began := not unit._working
	unit._set_working(true)
	if began:
		unit._model.attack.seek(work_seconds, true)
	unit.order_name = "维修" + recipient.display_name + " · 免费 +5/秒"
	work_seconds = minf(unit._stats.support_period, work_seconds + delta)
	unit.work_progress = work_seconds / unit._stats.support_period
	unit.work_bar.set_instance_shader_parameter("health", unit.work_progress)
	if work_seconds + .000001 >= unit._stats.support_period and recipient.support.recovery_gap <= .000001:
		if recipient.restore_health(unit._stats.support_amount) > 0.0:
			recipient.support.recovery_gap = unit._stats.support_period
			work_seconds = 0.0
			unit.work_progress = 0.0
			unit._model.synchronize_animation()
			var contact := unit._model.get_projectile_origin()
			unit._game.spawn_effect(contact, "wood_hit", Color("ebbc62"))
		if recipient.hp >= recipient.max_hp:
			var finished_manual: bool = unit.order == BattleUnit.Order.SUPPORT and recipient == unit.work_target
			release()
			_auto_area_active = false
			if finished_manual: unit._complete_waypoint()
	return Vector3.ZERO

func release() -> void:
	if is_instance_valid(recipient) and recipient.support.provider == self:
		recipient.support.provider = null
	recipient = null
	if is_instance_valid(unit) and unit.is_node_ready():
		unit._set_working(false)
		if unit.order == BattleUnit.Order.ATTACK_MOVE:
			unit._set_navigation_target(unit.destination)
	# Work already spent and the target's rate limit survive cancellation.

func cancel() -> void:
	release()
	_scan_seconds = 0.0
	_auto_area_active = false

func shutdown() -> void:
	cancel()
	if is_instance_valid(provider):
		provider.cancel()
	provider = null

func _exit_tree() -> void:
	if is_instance_valid(recipient) and is_instance_valid(recipient.support) and recipient.support.provider == self:
		recipient.support.provider = null
	if is_instance_valid(provider):
		provider.recipient = null
