class_name BuildingProduction
extends Node
## One authority-owned production/research component per authored building scene.

var training: Array[Dictionary] = []
var research_id: String = ""
var research_elapsed: float = 0.0
var rally_mine: ResourceVein
var _retry: float = 0.0
var _next_training_job_id: int = 1
@onready var building: BattleBuilding = get_parent()
@onready var game: Node3D = get_tree().current_scene

func recruit_error(kind: String) -> String:
	if not building.is_constructed:
		return "建筑尚未完工"
	var definition := BalanceCatalog.unit(kind)
	if kind not in building.get_combat_definition().produces:
		return "请在对应生产建筑招募"
	var player: PlayerState = game.get_player(building.owner_id)
	if player.gold < definition.cost:
		return "金币不足"
	if not definition.military and not player.can_reserve_farmer():
		return "农民上限 10 人（含训练队列）"
	if definition.military and player.military_supply + definition.supply > PlayerState.SUPPLY_LIMIT:
		return "军事人口上限 60"
	return ""

func recruit(kind: String) -> Dictionary:
	var error := recruit_error(kind)
	if not error.is_empty():
		return {"ok": false, "error": error}
	var definition := BalanceCatalog.unit(kind)
	var player: PlayerState = game.get_player(building.owner_id)
	if definition.training_seconds > 0:
		player.gold -= definition.cost
		player.reserved_farmers += 1
		training.append({"kind": kind, "elapsed": 0.0, "cost": definition.cost, "job_id": _next_training_job_id})
		_next_training_job_id += 1
	else:
		var at: Vector3 = game.find_recruit_position(kind, building)
		if not at.is_finite():
			return {"ok": false, "error": "出口被堵住，请移动附近部队"}
		player.gold -= definition.cost
		_spawn(kind, at)
	return {"ok": true}

func cancel_training(index: int) -> Dictionary:
	if index < 0 or index >= training.size():
		return {"ok": false, "error": "训练项目不存在"}
	var player: PlayerState = game.get_player(building.owner_id)
	player.gold += int(training[index].cost)
	player.reserved_farmers -= 1
	training.remove_at(index)
	return {"ok": true}

func cancel_training_job(job_id: int) -> Dictionary:
	# Queue positions move when a farmer finishes or another slot is cancelled.
	# A delayed click must only cancel the paid job that the player actually saw.
	for index: int in range(training.size()):
		if training[index].has("job_id") and int(training[index].job_id) == job_id:
			return cancel_training(index)
	return {"ok": false, "error": "训练项目已完成或已取消"}

func research_error(id: String) -> String:
	if not building.is_constructed or building.building_type != "academy":
		return "需要已完工学院"
	if not research_id.is_empty():
		return "学院正在研究"
	var upgrade := BalanceCatalog.upgrade(id)
	var player: PlayerState = game.get_player(building.owner_id)
	var level: int = player.attack_level if upgrade.track == &"attack" else player.defense_level
	if upgrade.level != level + 1:
		return "科技必须依次研究"
	if player.active_research.has(upgrade.track):
		return "这条科技路线正在其他学院研究"
	if player.gold < upgrade.cost:
		return "金币不足"
	return ""

func research(id: String) -> Dictionary:
	var error := research_error(id)
	if not error.is_empty():
		return {"ok": false, "error": error}
	var upgrade := BalanceCatalog.upgrade(id)
	var player: PlayerState = game.get_player(building.owner_id)
	player.gold -= upgrade.cost
	player.active_research[upgrade.track] = building.entity_id
	research_id = id
	research_elapsed = 0
	return {"ok": true}

func cancel_research(refund: bool = true) -> Dictionary:
	if research_id.is_empty():
		return {"ok": false, "error": "没有正在研究的项目"}
	var upgrade := BalanceCatalog.upgrade(research_id)
	var player: PlayerState = game.get_player(building.owner_id)
	player.active_research.erase(upgrade.track)
	if refund:
		player.gold += upgrade.cost
	research_id = ""
	research_elapsed = 0
	return {"ok": true}

func destroyed() -> void:
	var player: PlayerState = game.get_player(building.owner_id)
	player.reserved_farmers -= training.size()
	training.clear()
	if not research_id.is_empty():
		cancel_research(false)

func _physics_process(delta: float) -> void:
	if not game.is_authority or game.finished or not building.is_constructed:
		return
	if not training.is_empty():
		var item: Dictionary = training[0]
		var definition := BalanceCatalog.unit(item.kind)
		item.elapsed = minf(float(item.elapsed) + delta, definition.training_seconds)
		_retry -= delta
		if float(item.elapsed) >= definition.training_seconds and _retry <= 0:
			_retry = 0.25
			var at: Vector3 = game.find_recruit_position(item.kind, building)
			if at.is_finite():
				game.get_player(building.owner_id).reserved_farmers -= 1
				training.pop_front()
				_spawn(item.kind, at)
	if not research_id.is_empty():
		var upgrade := BalanceCatalog.upgrade(research_id)
		research_elapsed += delta
		if research_elapsed + 0.00001 >= upgrade.research_seconds:
			var player: PlayerState = game.get_player(building.owner_id)
			if upgrade.track == &"attack":
				player.attack_level = upgrade.level
			else:
				player.defense_level = upgrade.level
			player.active_research.erase(upgrade.track)
			game.notify_owner(building.owner_id, "%s研究完成" % upgrade.name)
			research_id = ""
			research_elapsed = 0

func _spawn(kind: String, at: Vector3) -> void:
	var unit: BattleUnit = game.spawn_unit(kind, building.owner_id, at)
	if kind == "farmer" and is_instance_valid(rally_mine):
		unit.issue_gather(rally_mine)
	else:
		unit.issue_move(building.rally_point)
	game.spawn_effect(at, "spawn", Color("84bfd9"))
	game.notify_owner(building.owner_id, "%s已出场" % unit.display_name)

func snapshot() -> Dictionary:
	return {"training": training.duplicate(true), "research_id": research_id, "research_elapsed": research_elapsed}
