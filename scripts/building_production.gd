class_name BuildingProduction
extends Node
## One authority-owned queue per authored building. Every paid job has a stable ID.

const TRAINING_LIMIT := 10
const RESEARCH_LIMIT := 6

var training: Array[Dictionary] = []
var research_queue: Array[Dictionary] = []
var research_id: String:
	get: return "" if research_queue.is_empty() else String(research_queue[0].id)
var research_elapsed: float:
	get: return 0.0 if research_queue.is_empty() else float(research_queue[0].elapsed)
	set(value):
		if not research_queue.is_empty():
			research_queue[0].elapsed = value
var rally_mine: ResourceVein
var _retry: float = 0.0
var _next_training_job_id: int = 1
var _next_research_job_id: int = 1
@onready var building: BattleBuilding = get_parent()
@onready var game: Node3D = get_tree().current_scene

func recruit_error(kind: String) -> String:
	if not building.is_constructed:
		return "建筑尚未完工"
	var definition := BalanceCatalog.unit(kind)
	if kind not in building.get_combat_definition().produces:
		return "请在对应生产建筑招募"
	if training.size() >= TRAINING_LIMIT:
		return "训练队列已满（每座建筑 10 项）"
	var player: PlayerState = game.get_player(building.owner_id)
	if player.gold < definition.cost:
		return "金币不足"
	if not definition.military and not player.can_reserve_farmer():
		return "农民上限 %d 人（含训练队列）" % player.get_worker_limit()
	if definition.military and player.used_military_supply() + definition.supply > PlayerState.SUPPLY_LIMIT:
		return "军事人口上限 60（含训练队列）"
	return ""

func recruit(kind: String) -> Dictionary:
	var error := recruit_error(kind)
	if not error.is_empty():
		return {"ok": false, "error": error}
	var definition := BalanceCatalog.unit(kind)
	var player: PlayerState = game.get_player(building.owner_id)
	player.gold -= definition.cost
	_reserve_training(kind, 1)
	training.append({"kind": kind, "elapsed": 0.0, "cost": definition.cost, "job_id": _next_training_job_id})
	_next_training_job_id += 1
	return {"ok": true}

func _reserve_training(kind: String, direction: int) -> void:
	var player: PlayerState = game.get_player(building.owner_id)
	var definition := BalanceCatalog.unit(kind)
	if definition.military:
		player.reserved_military_supply += definition.supply * direction
	else:
		player.reserved_farmers += direction

func cancel_training(index: int) -> Dictionary:
	if index < 0 or index >= training.size():
		return {"ok": false, "error": "训练项目不存在"}
	game.get_player(building.owner_id).gold += int(training[index].cost)
	_reserve_training(training[index].kind, -1)
	training.remove_at(index)
	return {"ok": true}

func cancel_training_job(job_id: int) -> Dictionary:
	for index: int in range(training.size()):
		if int(training[index].job_id) == job_id:
			return cancel_training(index)
	return {"ok": false, "error": "训练项目已完成或已取消"}

func research_error(id: String) -> String:
	if not building.is_constructed or building.building_type != "academy":
		return "需要已完工学院"
	if research_queue.size() >= RESEARCH_LIMIT:
		return "研究队列已满（每座学院 6 项）"
	var upgrade := BalanceCatalog.upgrade(id)
	var player: PlayerState = game.get_player(building.owner_id)
	if player.queued_research.has(id):
		return "这项科技已在研究队列中"
	if upgrade.level != player.planned_upgrade_level(upgrade.track) + 1:
		return "科技必须依次研究或加入队列"
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
	player.queued_research[id] = building.entity_id
	player.refresh_research_tracks()
	research_queue.append({"id": id, "elapsed": 0.0, "cost": upgrade.cost, "job_id": _next_research_job_id})
	_next_research_job_id += 1
	return {"ok": true}

func cancel_research(refund: bool = true) -> Dictionary:
	if research_queue.is_empty():
		return {"ok": false, "error": "没有正在研究的项目"}
	_remove_research_at(0, refund)
	_cancel_missing_prerequisites()
	return {"ok": true}

func cancel_research_job(job_id: int) -> Dictionary:
	for index in range(research_queue.size()):
		if int(research_queue[index].job_id) == job_id:
			_remove_research_at(index, true)
			_cancel_missing_prerequisites()
			return {"ok": true}
	return {"ok": false, "error": "研究项目已完成或已取消"}

func cancel_research_by_id(id: String) -> Dictionary:
	for job: Dictionary in research_queue:
		if job.id == id:
			return cancel_research_job(int(job.job_id))
	return {"ok": false, "error": "研究项目已完成或已取消"}

func _remove_research_at(index: int, refund: bool) -> void:
	var job: Dictionary = research_queue[index]
	var player: PlayerState = game.get_player(building.owner_id)
	player.queued_research.erase(String(job.id))
	if refund:
		player.gold += int(job.cost)
	research_queue.remove_at(index)
	player.refresh_research_tracks()

func _cancel_missing_prerequisites() -> void:
	# Only higher levels of the removed track become invalid. Other academies
	# refund those unstartable jobs; already completed upgrades always survive.
	var player: PlayerState = game.get_player(building.owner_id)
	var cancelled := 0
	for track: StringName in BalanceCatalog.UPGRADE_TRACKS:
		var completed: int = player.get_upgrade_level(track)
		var missing := false
		for level in range(completed + 1, int(BalanceCatalog.UPGRADE_TRACKS[track]) + 1):
			var id := "%s_%d" % [track, level]
			if not player.queued_research.has(id):
				missing = true
			elif missing:
				var academy: BattleBuilding = game.entities_by_id[int(player.queued_research[id])]
				for index in range(academy.production.research_queue.size()):
					if academy.production.research_queue[index].id == id:
						academy.production._remove_research_at(index, true)
						cancelled += 1
						break
	if cancelled > 0:
		game.notify_owner(building.owner_id, "前置科技取消，%d 项后续研究已取消并退款" % cancelled)

func destroyed() -> void:
	for job: Dictionary in training:
		_reserve_training(job.kind, -1)
	training.clear()
	while not research_queue.is_empty():
		_remove_research_at(0, false)
	_cancel_missing_prerequisites()

func research_waiting_for_prerequisite() -> bool:
	if research_queue.is_empty():
		return false
	var upgrade := BalanceCatalog.upgrade(research_id)
	var player: PlayerState = game.get_player(building.owner_id)
	var completed: int = player.get_upgrade_level(upgrade.track)
	return upgrade.level > completed + 1

func _physics_process(delta: float) -> void:
	if not game.is_authority or game.finished or not building.is_constructed:
		return
	if not training.is_empty():
		var item: Dictionary = training[0]
		var definition := BalanceCatalog.unit(item.kind)
		item.elapsed = minf(float(item.elapsed) + delta, definition.training_seconds)
		_retry -= delta
		if float(item.elapsed) + 0.00001 >= definition.training_seconds and _retry <= 0:
			_retry = 0.25
			var at: Vector3 = game.find_recruit_position(item.kind, building)
			if at.is_finite():
				_reserve_training(item.kind, -1)
				training.pop_front()
				_spawn(item.kind, at)
	if not research_queue.is_empty() and not research_waiting_for_prerequisite():
		var upgrade := BalanceCatalog.upgrade(research_id)
		research_elapsed += delta
		if research_elapsed + 0.00001 >= upgrade.research_seconds:
			var player: PlayerState = game.get_player(building.owner_id)
			player.complete_upgrade(upgrade)
			_remove_research_at(0, false)
			game.notify_owner(building.owner_id, "%s研究完成" % upgrade.name)

func _spawn(kind: String, at: Vector3) -> void:
	var unit: BattleUnit = game.spawn_unit(kind, building.owner_id, at)
	if kind == "farmer" and is_instance_valid(rally_mine):
		unit.issue_gather(rally_mine)
	else:
		unit.issue_move(building.rally_point)
	game.spawn_effect(at, "spawn", Color("84bfd9"))
	game.notify_owner(building.owner_id, "%s已出场" % unit.display_name)

func snapshot() -> Dictionary:
	return {"training": training.duplicate(true), "research_queue": research_queue.duplicate(true), "research_id": research_id, "research_elapsed": research_elapsed}
