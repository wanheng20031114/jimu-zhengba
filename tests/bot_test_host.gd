extends Node3D
## Transactional fixture: production prices and timers come from the actual catalog.
const ENTITY: PackedScene = preload("res://tests/bot_test_entity.tscn")
const MINE: PackedScene = preload("res://scenes/resource_vein.tscn")
var is_authority: bool = true
var map_size: float = 120.0
var players: Array[PlayerState] = [PlayerState.new(0, 0), PlayerState.new(1, 1), PlayerState.new(2, 0), PlayerState.new(3, 1)]
var commands: Array[Dictionary] = []
var visibility: Dictionary = {}
var clear_positions: bool = false
var defer_commands: bool = false
var elapsed: float = 0.0
var total_spent: int = 0
var next_id: int = 1
var sequences: Dictionary = {}
var entities: Dictionary = {}
var construction: Dictionary = {}
var training: Dictionary = {}

func register_entity(entity: Node3D) -> void:
	entity.entity_id = next_id
	next_id += 1
	entities[entity.entity_id] = entity

func get_player(owner: int) -> PlayerState:
	return players[owner]

func get_spawn_marker(owner: int) -> Marker3D:
	return get_node("SpawnPoints/Player%d" % owner)

func owned_entities(owner: int, group: String) -> Array:
	var result: Array = []
	for entity: Node3D in get_tree().get_nodes_in_group(group):
		if entity.owner_id == owner and entity.alive:
			result.append(entity)
	return result

func can_see_entity(owner: int, entity: Node3D) -> bool:
	if visibility.has(entity.entity_id):
		return bool(visibility[entity.entity_id])
	if entity.alliance_id == players[owner].alliance_id:
		return true
	for player: PlayerState in players:
		if player.alliance_id != players[owner].alliance_id:
			continue
		for viewer: Node3D in owned_entities(player.owner_id, "entities"):
			if viewer.global_position.distance_to(entity.global_position) <= 15.0:
				return true
	return false

func can_see_position(_owner: int, _at: Vector3) -> bool:
	return clear_positions

func clamp_to_map(at: Vector3) -> Vector3:
	return Vector3(clampf(at.x, -58, 58), 0, clampf(at.z, -58, 58))

func find_build_location(_owner: int, _kind: String, near: Vector3) -> Vector3:
	return clamp_to_map(near)

func nearest_mine(at: Vector3) -> ResourceVein:
	var best: ResourceVein
	var distance: float = INF
	for mine: ResourceVein in get_tree().get_nodes_in_group("resource_veins"):
		var candidate: float = mine.global_position.distance_squared_to(at)
		if candidate < distance:
			distance = candidate
			best = mine
	return best

func next_command_sequence(owner: int) -> int:
	sequences[owner] = int(sequences.get(owner, 0)) + 1
	return sequences[owner]

func add_unit(kind: String, owner: int, at: Vector3) -> Node3D:
	var unit: Node3D = ENTITY.instantiate()
	unit.owner_id = owner
	unit.alliance_id = players[owner].alliance_id
	unit.unit_type = kind
	unit.position = at
	unit.hp = BalanceCatalog.unit(kind).hp
	unit.max_hp = unit.hp
	$Units.add_child(unit)
	unit.add_to_group("units")
	unit.add_to_group("entities")
	register_entity(unit)
	if kind == "farmer": players[owner].farmers += 1
	else: players[owner].military_supply += BalanceCatalog.unit(kind).supply
	return unit

func add_building(kind: String, owner: int, at: Vector3, completed: bool = true) -> Node3D:
	var building: Node3D = ENTITY.instantiate()
	building.owner_id = owner
	building.alliance_id = players[owner].alliance_id
	building.building_type = kind
	building.position = at
	building.is_constructed = completed
	building.hp = BalanceCatalog.building(kind).hp
	building.max_hp = building.hp
	$Buildings.add_child(building)
	building.add_to_group("buildings")
	building.add_to_group("entities")
	register_entity(building)
	return building

func add_mine(at: Vector3) -> ResourceVein:
	var mine: ResourceVein = MINE.instantiate()
	mine.position = at
	$Resources.add_child(mine)
	return mine

func _set_worker_order(worker: Node3D, order: int, target: Node3D) -> void:
	if worker._claimed_mine and is_instance_valid(worker.work_target):
		worker.work_target.release(worker)
	worker._claimed_mine = false
	worker.order = order
	worker.work_target = target
	worker.gathering_seconds = 0.0

func submit_command(command: Dictionary, owner: int = -1) -> Dictionary:
	var cost: int = 0
	var player: PlayerState = players[owner]
	var target: Node3D = entities.get(int(command.get("target", 0)))
	match String(command.kind):
		"build": cost = player.get_building_cost(command.building_type)
		"recruit":
			var definition: UnitDefinition = BalanceCatalog.unit(command.unit_type)
			if target == null or not target.is_constructed or not BalanceCatalog.building(target.building_type).produces.has(command.unit_type):
				return {"ok": false}
			if definition.military and player.used_military_supply() + definition.supply > player.get_supply_limit():
				return {"ok": false}
			if not definition.military and not player.can_reserve_farmer(): return {"ok": false}
			cost = definition.cost
		"research":
			if not player.active_research.is_empty(): return {"ok": false}
			var upgrade: UpgradeDefinition = BalanceCatalog.upgrade(command.upgrade)
			if target == null or target.owner_id != owner or target.building_type != "academy" or not target.is_constructed:
				return {"ok": false}
			if upgrade.level != player.get_upgrade_level(upgrade.track) + 1: return {"ok": false}
			cost = upgrade.cost
	if cost > player.gold: return {"ok": false}
	var recorded: Dictionary = command.duplicate(true)
	recorded["cost"] = cost
	recorded["at_time"] = elapsed
	commands.append(recorded)
	if defer_commands: return {"ok": true}
	player.gold -= cost
	total_spent += cost
	match String(command.kind):
		"gather":
			for id: int in command.units:
				var worker: Node3D = entities[id]
				_set_worker_order(worker, BattleUnit.Order.GATHER, target)
				worker._claimed_mine = target.try_claim(worker)
				if worker._claimed_mine: worker.global_position = target.get_work_position(worker.global_position, worker)
		"build":
			var at := Vector3(float(command.at[0]), 0, float(command.at[2]))
			var site: Node3D = add_building(command.building_type, owner, at, false)
			player.record_building_placement(command.building_type)
			construction[site.entity_id] = BalanceCatalog.building(command.building_type).build_seconds
			_set_worker_order(entities[command.units[0]], BattleUnit.Order.BUILD, site)
		"work": _set_worker_order(entities[command.units[0]], BattleUnit.Order.BUILD, target)
		"recruit":
			if command.unit_type == "farmer":
				player.reserved_farmers += 1
				training[target.entity_id] = {"remaining": 10.0, "owner": owner}
			else: add_unit(command.unit_type, owner, target.global_position + Vector3(0, 0, 6))
		"research": player.active_research = {"id": command.upgrade, "remaining": BalanceCatalog.upgrade(command.upgrade).research_seconds}
		"move":
			for id: int in command.units:
				entities[id].global_position = Vector3(float(command.at[0]), 0, float(command.at[2]))
	return {"ok": true}

func advance(seconds: float) -> void:
	elapsed += seconds
	for player: PlayerState in players:
		player.gold += int(seconds)
		if not player.active_research.is_empty():
			player.active_research.remaining -= seconds
			if player.active_research.remaining <= 0:
				var upgrade: UpgradeDefinition = BalanceCatalog.upgrade(player.active_research.id)
				player.complete_upgrade(upgrade)
				player.active_research.clear()
	for worker: Node3D in get_tree().get_nodes_in_group("units"):
		if worker.unit_type != "farmer" or worker.order != BattleUnit.Order.GATHER or not worker._claimed_mine: continue
		worker.gathering_seconds += seconds * players[worker.owner_id].get_mining_rate_multiplier()
		while worker.gathering_seconds >= BalanceCatalog.ECONOMY.mining_seconds:
			worker.gathering_seconds -= BalanceCatalog.ECONOMY.mining_seconds
			players[worker.owner_id].gold += BalanceCatalog.ECONOMY.mining_gold
	for id: int in construction.keys():
		var site: Node3D = entities[id]
		for worker: Node3D in owned_entities(site.owner_id, "units"):
			if worker.order == BattleUnit.Order.BUILD and worker.work_target == site:
				construction[id] -= seconds
				if construction[id] <= 0:
					site.is_constructed = true
					worker.order = BattleUnit.Order.IDLE
					worker.work_target = null
					construction.erase(id)
				break
	for id: int in training.keys():
		training[id].remaining -= seconds
		if training[id].remaining <= 0:
			var owner: int = training[id].owner
			players[owner].reserved_farmers -= 1
			add_unit("farmer", owner, entities[id].global_position + Vector3(5, 0, 0))
			training.erase(id)
