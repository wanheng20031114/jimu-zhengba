class_name UnitVolley
extends Node
## One fixed target assignment per attack cycle. The existing physics Timer
## releases each slot; damage and recoil exist only for shots actually fired.
var unit: BattleUnit
var enabled: bool = false
var active: bool = false
var facing := Vector3.FORWARD
var targets: Array[BattleUnit] = []
var primary: Node3D
var next_slot: int = 0
var fired_mask: int = 0
var started_at: float = 0.0
var _query: PhysicsShapeQueryParameters3D

func configure(owner_unit: BattleUnit) -> void:
	unit = owner_unit
	enabled = unit._stats.volley_targets > 1
	if not enabled:
		return
	var shape := SphereShape3D.new()
	shape.radius = unit.attack_range + unit.radius + unit._largest_unit_radius
	_query = PhysicsShapeQueryParameters3D.new()
	_query.shape = shape
	_query.collision_mask = CombatLayers.hostile_units(unit.alliance_id)

func begin(target: Node3D) -> void:
	primary = target
	targets.clear()
	next_slot = 0
	fired_mask = 0
	started_at = unit._game.elapsed
	facing = target.global_position - unit.global_position
	facing.y = 0
	facing = facing.normalized()
	_query.transform.origin = unit.global_position + Vector3.UP
	var candidates: Array[Dictionary] = []
	var cone: float = cos(deg_to_rad(unit._stats.volley_arc_degrees * .5))
	# Each BattleUnit has one native collision shape. The entity count bounds
	# possible hits without truncating a crowded frontage to an arbitrary cap.
	var limit: int = unit.get_tree().get_nodes_in_group("units").size()
	for hit: Dictionary in unit._space_state.intersect_shape(_query, limit):
		var other: BattleUnit = hit.collider
		if other == target or not unit._valid_target(other) or not unit._within_attack_range(other):
			continue
		var offset: Vector3 = other.global_position - unit.global_position
		offset.y = 0
		if offset.normalized().dot(facing) + .000001 < cone:
			continue
		candidates.append({"unit": other, "priority": 0 if other._stats.combat_class == &"infantry" else 1,
			"distance": offset.length_squared(), "id": other.entity_id})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary):
		if a.priority != b.priority: return a.priority < b.priority
		if a.distance != b.distance: return a.distance < b.distance
		return a.id < b.id)
	for i: int in mini(unit._stats.volley_targets - 1, candidates.size()):
		targets.append(candidates[i].unit)
	active = true

func release_next() -> void:
	if not active or not unit.alive or not unit._game.is_authority:
		return
	var slot: int = next_slot
	var target: Variant = primary if slot == 0 else targets[slot - 1]
	if unit._valid_target(target) and unit._within_attack_range(target):
		fired_mask |= 1 << slot
		unit._model.set_volley_mask(fired_mask)
		unit._model.prepare_attack_release(unit._stats.attack_windup_seconds + slot * unit._stats.volley_interval)
		var damage := DamageResolver.snapshot(unit._stats, unit._owner_state.get_attack_bonus(), unit.owner_id, unit.alliance_id)
		unit._game.spawn_projectile(unit, target, damage, unit._stats.projectile, slot)
		# A synchronous launch observer can stop or destroy the source.
		if not active or not unit.alive:
			return
		unit._game.spawn_effect(unit.get_projectile_origin(slot), "muzzle", Color("ffd898"))
	next_slot += 1
	if next_slot <= targets.size():
		# Schedule against the round's physics clock. Chaining full intervals
		# would accumulate Timer quantization at the project's 30 Hz tick rate.
		var release_at: float = started_at + unit._stats.attack_windup_seconds + next_slot * unit._stats.volley_interval
		unit.attack_windup.start(maxf(.000001, release_at - unit._game.elapsed))
	else:
		cancel()

func cancel() -> void:
	active = false
	primary = null
	targets.clear()
	unit._strike_target = null
