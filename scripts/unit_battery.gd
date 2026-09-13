class_name UnitBattery
extends Node
## Independent weapons share one bounded acquisition query and one native release
## Timer. Each gun owns its target, cooldown debt and pending windup across orders.
class Gun:
	extends RefCounted
	var target: Node3D
	var ready_at: float = 0.0
	var release_at: float = -1.0

var unit: BattleUnit
var enabled: bool = false
var guns: Array[Gun] = []
var last_fired := PackedFloat64Array()
var facing := Vector3.FORWARD
var pending_mask: int = 0
var winding: bool:
	get: return pending_mask != 0
var query_count: int = 0
var shots_fired: int = 0
var _next_query: float = 0.0
var _cone: float = 0.0
var _query: PhysicsShapeQueryParameters3D
var _visual: BatteryVisual

func configure(owner_unit: BattleUnit) -> void:
	unit = owner_unit
	enabled = unit._stats.independent_weapons > 1
	if not enabled: return
	_visual = unit._model as BatteryVisual
	assert(_visual != null, "Independent guns require an authored BatteryVisual")
	for i: int in unit._stats.independent_weapons:
		guns.append(Gun.new())
		last_fired.append(-1.0)
	_cone = cos(deg_to_rad(unit._stats.weapon_arc_degrees * .5))
	var shape := SphereShape3D.new()
	shape.radius = unit.attack_range + unit.radius + unit._largest_unit_radius
	_query = PhysicsShapeQueryParameters3D.new()
	_query.shape = shape
	_query.collision_mask = CombatLayers.hostile_units(unit.alliance_id)

func engage(primary: Variant) -> bool:
	if unit.order == BattleUnit.Order.MOVE:
		return false
	if not unit._valid_target(primary) or not unit._within_attack_range(primary):
		return winding
	if not winding:
		facing = primary.global_position - unit.global_position
		facing.y = 0
		facing = facing.normalized()
	var now: float = unit._game.elapsed
	var ready_mask: int = 0
	for i: int in guns.size():
		if guns[i].release_at < 0 and now + .000001 >= guns[i].ready_at:
			ready_mask |= 1 << i
	if ready_mask == 0: return true
	if unit.order == BattleUnit.Order.ATTACK or now >= _next_query:
		_assign_targets(primary, now)
	var started: bool = false
	for i: int in guns.size():
		if not (ready_mask & (1 << i)): continue
		var gun: Gun = guns[i]
		if not _eligible(gun.target, primary): continue
		if not unit._can_start_strike(gun.target):
			continue
		# The clock starts once, at preparation. Cancellation never erases debt.
		gun.ready_at = now + unit._stats.cooldown
		gun.release_at = now + unit._stats.attack_windup_seconds
		pending_mask |= 1 << i
		started = true
	if started: _schedule_release()
	return true

func _eligible(candidate: Variant, primary: Variant) -> bool:
	if not unit._valid_target(candidate) or not unit._within_attack_range(candidate): return false
	if candidate == primary: return true
	if unit.order == BattleUnit.Order.ATTACK: return false
	if not candidate is BattleUnit: return false
	var offset: Vector3 = candidate.global_position - unit.global_position
	offset.y = 0
	return offset.normalized().dot(facing) + .000001 >= _cone

func _assigned(candidate: Node3D) -> bool:
	for gun: Gun in guns:
		if gun.target == candidate: return true
	return false

func _assign_targets(primary: Node3D, now: float) -> void:
	# An explicit focus order is shared by all guns; their clocks remain separate.
	if unit.order == BattleUnit.Order.ATTACK:
		for gun: Gun in guns:
			if gun.release_at < 0: gun.target = primary
		return
	var vacant: Array[int] = []
	var retained: Array[Node3D] = []
	for i: int in guns.size():
		var gun: Gun = guns[i]
		if gun.release_at >= 0 or now + .000001 < gun.ready_at: continue
		# Automatic fire keeps distinct locks when alternatives exist. A duplicated
		# lock becomes available at its own reload, without cancelling other guns.
		if not _eligible(gun.target, primary) or gun.target in retained:
			gun.target = null
			vacant.append(i)
		else: retained.append(gun.target)
	if not _assigned(primary):
		if vacant.is_empty():
			for i: int in guns.size():
				if guns[i].release_at < 0 and now + .000001 >= guns[i].ready_at:
					vacant.append(i)
					break
		if not vacant.is_empty(): guns[vacant.pop_front()].target = primary
	if vacant.is_empty(): return
	# Empty ready guns poll together at the normal combat discovery cadence.
	# Retained locks need no broad-phase query, sorting or scene-wide unit array.
	_next_query = now + .35
	_query.transform.origin = unit.global_position + Vector3.UP
	query_count += 1
	var candidates: Array[BattleUnit] = []
	for hit: Dictionary in unit._space_state.intersect_shape(_query, unit._game.entities_by_id.size()):
		var other: BattleUnit = hit.collider
		if _assigned(other) or not _eligible(other, primary): continue
		var insert_at: int = 0
		while insert_at < candidates.size() and not _before(other, candidates[insert_at]): insert_at += 1
		if insert_at < vacant.size():
			candidates.insert(insert_at, other)
			if candidates.size() > vacant.size(): candidates.pop_back()
	for i: int in candidates.size(): guns[vacant[i]].target = candidates[i]
	# Available weapons may concentrate on the primary instead of withholding fire.
	for i: int in range(candidates.size(), vacant.size()): guns[vacant[i]].target = primary

func _before(a: BattleUnit, b: BattleUnit) -> bool:
	var a_infantry: bool = a._stats.combat_class == &"infantry"
	var b_infantry: bool = b._stats.combat_class == &"infantry"
	if a_infantry != b_infantry: return a_infantry
	var a_distance: float = unit.global_position.distance_squared_to(a.global_position)
	var b_distance: float = unit.global_position.distance_squared_to(b.global_position)
	return a_distance < b_distance if a_distance != b_distance else a.entity_id < b.entity_id

func release_due() -> void:
	if not unit.alive or not unit._game.is_authority: return
	var now: float = unit._game.elapsed
	for i: int in guns.size():
		var gun: Gun = guns[i]
		if gun.release_at < 0 or gun.release_at > now + .000001: continue
		gun.release_at = -1.0
		pending_mask &= ~(1 << i)
		if not _eligible(gun.target, unit.target): continue
		_visual.fire_barrel(i)
		last_fired[i] = now
		shots_fired += 1
		var damage := DamageResolver.snapshot(unit._stats, unit._owner_state.get_attack_bonus(), unit.owner_id, unit.alliance_id)
		unit._game.spawn_projectile(unit, gun.target, damage, unit._stats.projectile, i)
		# Launch observers may synchronously stop/kill the cannon and cancel peers.
		if not unit.alive: return
		unit._game.spawn_effect(unit.get_projectile_origin(i), "muzzle", Color("ffd898"))
	_schedule_release()

func _schedule_release() -> void:
	var next: float = INF
	for gun: Gun in guns:
		if gun.release_at >= 0: next = minf(next, gun.release_at)
	if is_inf(next): unit.attack_windup.stop()
	else: unit.attack_windup.start(maxf(.000001, next - unit._game.elapsed))

func cancel() -> void:
	pending_mask = 0
	for gun: Gun in guns:
		gun.release_at = -1.0
		if not unit.alive: gun.target = null
	# Only gun cooldowns survive commands; no banked shots and no per-target lockout.
