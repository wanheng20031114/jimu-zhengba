class_name MatchCommands
extends RefCounted
## Every human, Bot and remote request crosses the same fixed-tick validator.

const KINDS := ["recruit", "build", "move", "attack", "gather", "work", "stop", "hold", "research", "cancel_research", "cancel_training", "cancel_site", "demolish", "rally"]
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
	var queued: bool = command.get("queued", false) == true
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
			if not own_building or not BalanceCatalog.UNITS.has(unit_type):
				return failure("需要自己的生产建筑")
			return target.get_node("Production").recruit(unit_type)
		"research":
			var upgrade: String = str(command.get("upgrade", ""))
			if not own_building or not BalanceCatalog.UPGRADES.has(upgrade):
				return failure("需要自己的学院")
			return target.get_node("Production").research(upgrade)
		"cancel_research":
			return target.get_node("Production").cancel_research() if own_building else failure("需要自己的学院")
		"cancel_training":
			if not own_building:
				return failure("需要自己的生产建筑")
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
				return failure("只能拆除自己的已完工防御塔")
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
			if not own_building:
				return failure("需要自己的生产建筑")
			var mine_id: Variant = command.get("mine", 0)
			if not NetworkProtocol.integer(mine_id, 0, MAX_INTEGER):
				return failure("无效矿脉编号")
			var mine: ResourceVein = game.entities_by_id.get(int(mine_id)) as ResourceVein
			if int(mine_id) != 0 and not is_instance_valid(mine):
				return failure("需要矿脉目标")
			target.rally_point = at
			target.get_node("Production").rally_mine = mine
		"move":
			game.move_formation(entities, at, command.get("attack_move", false) == true, queued)
		"attack":
			if not target_valid or target is ResourceVein or target.alliance_id == game.get_player(owner).alliance_id or not game.can_see_entity(owner, target):
				return failure("目标不在视野内或不是敌军")
			for unit: BattleUnit in entities:
				unit.issue_attack(target)
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
					unit.hold()
	return {"ok": true}

static func failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
