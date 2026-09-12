class_name UnitOrderPlan
extends RefCounted
## Presentation data only: never executable commands or hidden entity handles.
const MAX_FUTURE := 8
const MAX_ENTRIES := MAX_FUTURE + 1
const KINDS := ["move", "attack", "gather", "build", "support", "hold", "unknown"]

static func build(unit: BattleUnit, game: Node) -> Array:
	var plan: Array = []
	match unit.order:
		BattleUnit.Order.MOVE, BattleUnit.Order.ATTACK_MOVE:
			plan.append(_point("attack" if unit.order == BattleUnit.Order.ATTACK_MOVE else "move", unit.destination))
		BattleUnit.Order.ATTACK:
			plan.append(_entity("attack", unit.target, unit.owner_id, game))
		BattleUnit.Order.GATHER, BattleUnit.Order.BUILD:
			plan.append(_entity("gather" if unit.order == BattleUnit.Order.GATHER else "build", unit.work_target, unit.owner_id, game))
		BattleUnit.Order.SUPPORT:
			plan.append(_entity("support", unit.support.recipient if is_instance_valid(unit.support.recipient) else unit.work_target, unit.owner_id, game))
		BattleUnit.Order.HOLD:
			plan.append(_point("hold", unit.global_position))
	for job: Dictionary in unit.waypoint_queue.slice(0, MAX_FUTURE):
		match job.kind:
			"move":
				plan.append(_point("attack" if job.attack_move else "move", job.position))
			"attack":
				plan.append(_entity("attack", job.entity, unit.owner_id, game))
			"work":
				plan.append(_entity("gather" if job.order == BattleUnit.Order.GATHER else "build", job.entity, unit.owner_id, game))
			"support":
				plan.append(_entity("support", job.entity, unit.owner_id, game))
			"hold":
				# A terminal hold happens wherever the previous order completes.
				if not plan.is_empty() and plan.back().has("at"):
					plan.append({"kind": "hold", "at": plan.back().at.duplicate()})
				else:
					plan.append({"kind": "unknown"})
	return plan

static func _entity(kind: String, target: Variant, owner: int, game: Node) -> Dictionary:
	if not is_instance_valid(target) or not target.alive or not game.can_see_entity(owner, target):
		return {"kind": "unknown"}
	return _point(kind, target.global_position)

static func _point(kind: String, at: Vector3) -> Dictionary:
	return {"kind": kind, "at": [snappedf(float(at.x), 0.01), snappedf(float(at.y), 0.01), snappedf(float(at.z), 0.01)]}

static func valid(value: Variant) -> bool:
	if not value is Array or value.size() > MAX_ENTRIES:
		return false
	for entry: Variant in value:
		if not entry is Dictionary or not entry.get("kind") is String or not entry.kind in KINDS:
			return false
		if entry.kind == "unknown":
			if entry.size() != 1:
				return false
			continue
		if entry.size() != 2 or not entry.get("at") is Array or entry.at.size() != 3:
			return false
		for coordinate: Variant in entry.at:
			if not (coordinate is float or coordinate is int) or not is_finite(float(coordinate)) or absf(float(coordinate)) > 4096.0:
				return false
	return true
