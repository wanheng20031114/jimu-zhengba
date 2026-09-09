class_name MatchCommands
extends RefCounted
## Every human, Bot and remote request crosses the same fixed-tick validator.

const KINDS := ["recruit", "build", "move", "attack", "gather", "work", "stop", "hold", "research", "cancel_research", "cancel_training", "cancel_site", "demolish", "destroy", "rally"]
const MAX_INTEGER: int = 2147483647
var game: Node3D
var pending: Array[Dictionary] = []
var _issued: Dictionary = {}
var _accepted: Dictionary = {}

func _init(controller: Node3D) -> void:
	game = controller

func next_sequence(owner: int) -> int:
	_issued[owner] = maxi(int(_issued.get(owner, 0)), int(_accepted.get(owner, 0))) + 1
	return _issued[owner]

func submit(command: Dictionary, owner: int) -> Dictionary:
	if owner < 0 or owner >= game.players.size() or game.finished:
		return failure("对局已结束或玩家不存在")
	var raw_sequence: Variant = command.get("seq", 0)
	if command.get("kind", "") not in KINDS:
		return failure("无效命令")
	if not NetworkProtocol.integer(raw_sequence, 1, MAX_INTEGER):
		return failure("无效命令序号")
	var sequence: int = int(raw_sequence)
	if sequence <= int(_accepted.get(owner, 0)):
		return failure("重复命令")
	if sequence > int(_accepted.get(owner, 0)) + 10000 or pending.size() >= 512:
		return failure("命令过于频繁")
	_accepted[owner] = sequence
	var copied := command.duplicate(true)
	copied["owner"] = owner
	pending.append(copied)
	return {"ok": true}

func tick() -> void:
	var requests := pending
	pending = []
	for command: Dictionary in requests:
		var result := execute(command, command.owner)
		if not result.ok:
			game.notify_owner(command.owner, result.error)

func execute(command: Dictionary, owner: int) -> Dictionary:
	if owner < 0 or owner >= game.players.size() or game.finished:
		return failure("对局已结束或玩家不存在")
	if command.get("kind", "") not in KINDS:
		return failure("无效命令")
	var kind: String = command.kind
	var entities: Array[BattleUnit] = []
	var ids: Variant = command.get("units", [])
	if not ids is Array or ids.size() > 70:
		return failure("无效单位列表")
	for id: Variant in ids:
		if not NetworkProtocol.integer(id, 1, MAX_INTEGER):
			return failure("无效单位编号")
		var unit: Node3D = game.entities_by_id.get(int(id))
		if not is_instance_valid(unit) or not unit is BattleUnit or not unit.alive or unit.owner_id != owner:
			return failure("只能命令自己的部队")
		if unit not in entities:
			entities.append(unit)
	var target_id: Variant = command.get("target", 0)
	if not NetworkProtocol.integer(target_id, 0, MAX_INTEGER):
		return failure("无效目标编号")
	var target: Node3D = game.entities_by_id.get(int(target_id))
	var target_valid: bool = is_instance_valid(target) and target.alive
	var own_building: bool = target_valid and target is BattleBuilding and target.owner_id == owner
	var buildings: Array[BattleBuilding] = []
	var building_ids: Variant = command.get("buildings", [])
	if not building_ids is Array or building_ids.size() > 128:
		return failure("无效建筑列表")
	for id: Variant in building_ids:
		if not NetworkProtocol.integer(id, 1, MAX_INTEGER):
			return failure("无效建筑编号")
		var building: Node3D = game.entities_by_id.get(int(id))
		if not is_instance_valid(building) or not building is BattleBuilding or not building.alive or building.owner_id != owner:
			return failure("只能命令自己的建筑")
		if building not in buildings:
			buildings.append(building)
	if buildings.is_empty() and own_building:
		buildings.append(target)
	var queued: bool = command.get("queued", false) == true
	if queued and kind in ["move", "attack", "gather", "work", "build", "hold"]:
		for unit: BattleUnit in entities:
			if unit.waypoint_queue.size() >= BattleUnit.MAX_QUEUED_ORDERS:
				return failure("连续指令已达上限（64 项）")
	var at_data: Variant = command.get("at", [0, 0, 0])
	if not at_data is Array or at_data.size() != 3:
		return failure("无效坐标")
	for coordinate: Variant in at_data:
		if not (coordinate is float or coordinate is int) or not is_finite(float(coordinate)):
			return failure("无效坐标")
	var at := Vector3(float(at_data[0]), 0, float(at_data[2]))
	if not at.is_finite() or at.distance_squared_to(game.clamp_to_map(at)) > 0.01:
		return failure("坐标超出地图")
	match kind:
		"recruit":
			var unit_type: String = str(command.get("unit_type", ""))
			if buildings.is_empty() or not BalanceCatalog.UNITS.has(unit_type):
				return failure("需要自己的生产建筑")
			return _enqueue_production(buildings, unit_type, false)
		"research":
			var upgrade: String = str(command.get("upgrade", ""))
			if buildings.is_empty() or not BalanceCatalog.UPGRADES.has(upgrade):
				return failure("需要自己的学院")
			return _enqueue_production(buildings, upgrade, true)
		"cancel_research":
			if not own_building:
				return failure("需要自己的学院")
			var production: BuildingProduction = target.get_node("Production")
			if command.has("job_id"):
				if not NetworkProtocol.integer(command.job_id, 1, MAX_INTEGER):
					return failure("无效研究项目编号")
				return production.cancel_research_job(int(command.job_id))
			if command.has("upgrade"):
				if not command.upgrade is String:
					return failure("无效研究项目")
				return production.cancel_research_by_id(command.upgrade)
			return production.cancel_research()
		"cancel_training":
			if not own_building:
				return failure("需要自己的生产建筑")
			if command.has("job_id"):
				if not NetworkProtocol.integer(command.job_id, 1, MAX_INTEGER):
					return failure("无效训练项目编号")
				return target.get_node("Production").cancel_training_job(int(command.job_id))
			var index: Variant = command.get("index", 0)
			if not NetworkProtocol.integer(index, 0, MAX_INTEGER):
				return failure("无效训练项目编号")
			return target.get_node("Production").cancel_training(int(index))
		"cancel_site":
			if not own_building or target.is_constructed:
				return failure("需要自己的工地")
			game.get_player(owner).gold += target.cancel_construction()
		"demolish":
			if not own_building or not target.demolish():
				return failure("只能拆除自己的已完工建筑")
		"destroy":
			var destroy_ids: Variant = command.get("targets", [])
			if not destroy_ids is Array or destroy_ids.is_empty() or destroy_ids.size() > 256:
				return failure("无效销毁列表")
			var victims: Array[Node3D] = []
			for id: Variant in destroy_ids:
				if not NetworkProtocol.integer(id, 1, MAX_INTEGER):
					return failure("无效销毁目标")
				var victim: Node3D = game.entities_by_id.get(int(id))
				if not is_instance_valid(victim) or not victim.alive or victim.owner_id != owner or not (victim is BattleUnit or victim is BattleBuilding):
					return failure("只能销毁自己的部队或建筑")
				if victim not in victims:
					victims.append(victim)
			for victim: Node3D in victims:
				if victim is BattleBuilding:
					if victim.is_constructed:
						victim.demolish()
					else:
						game.get_player(owner).gold += victim.cancel_construction()
				else:
					victim.receive_damage(victim.hp)
		"build":
			var building_type: String = str(command.get("building_type", ""))
			if building_type not in ["headquarters", "barracks", "factory", "academy", "defense_tower"]:
				return failure("无效建筑")
			var workers: Array[BattleUnit] = []
			for unit: BattleUnit in entities:
				if unit.unit_type == "farmer":
					workers.append(unit)
			if workers.is_empty():
				return failure("需要农民施工")
			return game.create_site(owner, building_type, at, workers, queued)
		"rally":
			if buildings.is_empty():
				return failure("需要自己的生产建筑")
			var mine_id: Variant = command.get("mine", 0)
			if not NetworkProtocol.integer(mine_id, 0, MAX_INTEGER):
				return failure("无效矿脉编号")
			var mine: ResourceVein = game.entities_by_id.get(int(mine_id)) as ResourceVein
			if int(mine_id) != 0 and not is_instance_valid(mine):
				return failure("需要矿脉目标")
			for building: BattleBuilding in buildings:
				building.rally_point = at
				building.get_node("Production").rally_mine = mine
		"move":
			game.move_formation(entities, at, command.get("attack_move", false) == true, queued)
		"attack":
			if not target_valid or target is ResourceVein or target.alliance_id == game.get_player(owner).alliance_id or not game.can_see_entity(owner, target):
				return failure("目标不在视野内或不是敌军")
			for unit: BattleUnit in entities:
				unit.issue_attack(target, queued)
		"gather":
			if not target_valid or not target is ResourceVein:
				return failure("需要矿脉目标")
			for unit: BattleUnit in entities:
				if unit.unit_type == "farmer":
					unit.issue_gather(target, queued)
		"work":
			if not own_building or target.is_constructed:
				return failure("需要自己的未完工工地")
			var worker: BattleUnit = game.choose_builder(entities, at, queued)
			if worker == null:
				return failure("需要农民")
			worker.issue_build(target, queued)
		"stop", "hold":
			for unit: BattleUnit in entities:
				if kind == "stop":
					unit.stop()
				else:
					unit.hold(queued)
	return {"ok": true}

func _enqueue_production(buildings: Array[BattleBuilding], id: String, research: bool) -> Dictionary:
	# Choose on the authority tick, after earlier purchases have extended queues.
	# A group hotkey makes one purchase per press, spreading work across buildings.
	var best: BuildingProduction
	var best_seconds: float = INF
	var error: String = "需要对应的已完工生产建筑"
	for building: BattleBuilding in buildings:
		var production: BuildingProduction = building.get_node("Production")
		var candidate_error: String = production.research_error(id) if research else production.recruit_error(id)
		if not candidate_error.is_empty():
			error = candidate_error
			continue
		var seconds: float = 0.0
		if research:
			for job: Dictionary in production.research_queue:
				seconds += maxf(0.0, BalanceCatalog.upgrade(job.id).research_seconds - float(job.elapsed))
		else:
			for job: Dictionary in production.training:
				seconds += maxf(0.0, BalanceCatalog.unit(job.kind).training_seconds - float(job.elapsed))
		if seconds < best_seconds:
			best_seconds = seconds
			best = production
	if best == null:
		return failure(error)
	return best.research(id) if research else best.recruit(id)

static func failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
