class_name SkirmishBot
extends RefCounted
## One-Hz authority AI. It spends through the same commands as a human and remembers
## only information observed through its alliance's current vision.

const DECISION_SECONDS: float = 1.0
const UNIT_MEMORY_SECONDS: float = 25.0
const COMMAND_REFRESH_SECONDS: float = 4.0
const MINIMUM_RAID_SIZE: int = 3

var army_state: StringName = &"muster"
var _game: Node
var _owner: int
var _clock: float = 0.0
var _decision_time: float = 0.0
var _budget: int = 0
var _home: Vector3 = Vector3.ZERO
var _allied_center: Vector3 = Vector3.ZERO
var _home_known: bool = false
var _front: Vector3 = Vector3.RIGHT
var _workers: Array[Node3D] = []
var _army: Array[Node3D] = []
var _buildings: Array[Node3D] = []
var _mines: Array[Node3D] = []
var _visible_enemies: Array[Node3D] = []
var _memory: Dictionary = {}
var _busy_workers: Dictionary = {}
var _pending_builds: Dictionary = {}
var _farmer_pending_until: float = 0.0
var _last_army_order: String = ""
var _last_army_order_at: float = -10.0
var _retreat_until: float = 0.0
var _scout_step: int = 0
var _next_scout_at: float = 0.0
var _search_lane: int = 0
var _investment_kind: String = ""
var _investment_location: Vector3 = Vector3.ZERO
var _next_research_at: float = 0.0

func _init(game: Node, owner: int) -> void:
	_game = game
	_owner = owner

func tick(delta: float) -> void:
	if not _game.is_authority or _game.get_player(_owner).eliminated:
		return
	_clock += delta
	_decision_time += delta
	if _decision_time + 0.000001 < DECISION_SECONDS:
		return
	# Late frames make one current decision, rather than replaying stale AI orders.
	_decision_time = maxf(0.0, fmod(_decision_time - DECISION_SECONDS, DECISION_SECONDS))
	_decide()

func _decide() -> void:
	_budget = _game.get_player(_owner).gold
	_busy_workers.clear()
	_refresh_own_army()
	if not _home_known:
		return
	_observe()
	_resume_sites()
	_assign_miners()
	var reserve: int = _develop_base()
	_recruit_farmer(reserve)
	_recruit_army(reserve)
	_command_army()

func _refresh_own_army() -> void:
	_workers.clear()
	_army.clear()
	_buildings.assign(_game.owned_entities(_owner, "buildings"))
	for unit: Node3D in _game.owned_entities(_owner, "units"):
		if unit.unit_type == "farmer":
			_workers.append(unit)
		else:
			_army.append(unit)
	for building: Node3D in _buildings:
		if building.building_type == "headquarters":
			_home = building.global_position
			_home_known = true
			break
	# A fresh disconnect takeover has no remembered headquarters. Anchor recovery
	# to surviving own assets; allied bases must never become its owned home.
	if not _home_known:
		var anchor: Node3D
		if not _buildings.is_empty():
			anchor = _buildings[0]
		elif not _workers.is_empty():
			anchor = _workers[0]
		elif not _army.is_empty():
			anchor = _army[0]
		if anchor != null:
			_home = anchor.global_position
			_home_known = true
	var allied_center: Vector3 = _home
	var bases: int = 1
	for player: PlayerState in _game.players:
		if player.owner_id == _owner or player.alliance_id != _game.get_player(_owner).alliance_id:
			continue
		for building: Node3D in _game.owned_entities(player.owner_id, "buildings"):
			if building.building_type == "headquarters":
				allied_center += building.global_position
				bases += 1
	allied_center /= bases
	_allied_center = allied_center
	_front = (-allied_center).normalized()
	if _front.length_squared() < 0.01:
		_front = (-_home).normalized() if _home.length_squared() >= 0.01 else Vector3.FORWARD

func _observe() -> void:
	_visible_enemies.clear()
	_mines.clear()
	var seen: Dictionary = {}
	for entity: Node3D in _game.get_tree().get_nodes_in_group("entities"):
		# Never read enemy identity, health or transforms before visibility succeeds.
		if not _game.can_see_entity(_owner, entity):
			continue
		if not entity.alive or entity.alliance_id == _game.get_player(_owner).alliance_id:
			continue
		var building: bool = entity.is_in_group("buildings")
		var kind: String = entity.building_type if building else entity.unit_type
		var value: float = 90.0 if building else float(BalanceCatalog.unit(kind).cost)
		_visible_enemies.append(entity)
		seen[entity.entity_id] = true
		_memory[entity.entity_id] = {"kind": kind, "building": building, "position": entity.global_position,
			"seen_at": _clock, "power": value * clampf(entity.hp / entity.max_hp, 0.15, 1.0)}
	for id: int in _memory.keys():
		var record: Dictionary = _memory[id]
		if seen.has(id):
			continue
		if (not record.building and _clock - float(record.seen_at) > UNIT_MEMORY_SECONDS) or (record.building and _game.can_see_position(_owner, record.position)):
			_memory.erase(id)
	for mine: Node3D in _game.get_tree().get_nodes_in_group("resource_veins"):
		if _game.can_see_entity(_owner, mine):
			_mines.append(mine)
	_mines.sort_custom(func(a: Node3D, b: Node3D) -> bool: return a.global_position.distance_squared_to(_home) < b.global_position.distance_squared_to(_home))

func _building(kind: String, complete: bool = false) -> Node3D:
	for building: Node3D in _buildings:
		if building.building_type == kind and (not complete or building.is_constructed):
			return building
	return null

func _submit(command: Dictionary, cost: int = 0) -> bool:
	if cost > _budget:
		return false
	command["seq"] = _game.next_command_sequence(_owner)
	var result: Dictionary = _game.submit_command(command, _owner)
	if not result.ok:
		return false
	_budget -= cost
	return true

func _worker_for(at: Vector3) -> Node3D:
	var best: Node3D
	var best_distance: float = INF
	for worker: Node3D in _workers:
		if _busy_workers.has(worker.entity_id) or worker.order == BattleUnit.Order.BUILD:
			continue
		var distance: float = worker.global_position.distance_squared_to(at)
		if distance < best_distance:
			best_distance = distance
			best = worker
	return best

func _resume_sites() -> void:
	for site: Node3D in _buildings:
		if site.is_constructed:
			continue
		var staffed: bool = false
		for worker: Node3D in _workers:
			if worker.order == BattleUnit.Order.BUILD and worker.work_target == site:
				staffed = true
				break
		if staffed:
			continue
		var builder: Node3D = _worker_for(site.global_position)
		if builder != null and _submit({"kind": "work", "units": [builder.entity_id], "target": site.entity_id, "queued": false}):
			_busy_workers[builder.entity_id] = true

func _assign_miners() -> void:
	var claimed: Dictionary = {}
	for mine: Node3D in _mines:
		claimed[mine.entity_id] = mine.occupied_slots()
	for worker: Node3D in _workers:
		if _busy_workers.has(worker.entity_id) or worker.order == BattleUnit.Order.BUILD:
			continue
		if worker.order == BattleUnit.Order.GATHER and worker._claimed_mine:
			continue
		var chosen: Node3D
		var distance: float = INF
		for mine: Node3D in _mines:
			if int(claimed[mine.entity_id]) >= ResourceVein.CAPACITY:
				continue
			var candidate_distance: float = worker.global_position.distance_squared_to(mine.global_position)
			if candidate_distance < distance:
				distance = candidate_distance
				chosen = mine
		if chosen != null and _submit({"kind": "gather", "units": [worker.entity_id], "target": chosen.entity_id, "queued": false}):
			claimed[chosen.entity_id] += 1

func _try_build(kind: String, near: Vector3) -> bool:
	if _building(kind) != null or float(_pending_builds.get(kind, 0.0)) > _clock:
		return true
	var definition: BuildingDefinition = BalanceCatalog.building(kind)
	if _budget < definition.cost:
		return false
	var position: Vector3 = _game.find_build_location(_owner, kind, near)
	if not position.is_finite():
		return false
	var builder: Node3D = _worker_for(position)
	if builder == null:
		return false
	if _submit({"kind": "build", "building_type": kind, "units": [builder.entity_id], "at": [position.x, 0, position.z], "queued": false}, definition.cost):
		_busy_workers[builder.entity_id] = true
		_pending_builds[kind] = _clock + 3.0
		return true
	return false

func _develop_base() -> int:
	var flank: Vector3 = _front.cross(Vector3.UP)
	if _building("headquarters") == null:
		if _workers.is_empty():
			return 0
		return 0 if _try_build("headquarters", _home) else BalanceCatalog.building(&"headquarters").cost
	if _building("barracks") == null:
		return 0 if _try_build("barracks", _home + _front * 9.0) else BalanceCatalog.building(&"barracks").cost
	# Front-line attrition must not erase every saved infrastructure budget. Keep an
	# already chosen project while two defenders and the headquarters can hold home.
	if not _investment_kind.is_empty():
		if _building(_investment_kind) != null:
			_investment_kind = ""
		elif _army.size() >= 2 and _enemy_power_near(_home, 17.0) < 150.0:
			return 0 if _try_build(_investment_kind, _investment_location) else BalanceCatalog.building(_investment_kind).cost
	# Keep the first three combatants ahead of expensive infrastructure and technology.
	if _army.size() < MINIMUM_RAID_SIZE:
		return 0
	if _enemy_power_near(_home, 17.0) > 120.0:
		if _building("defense_tower") == null:
			return 0 if _try_build("defense_tower", _home + _front * 11.0) else BalanceCatalog.building(&"defense_tower").cost
		return 0
	if _building("factory") == null and _clock >= 75.0:
		_investment_kind = "factory"
		_investment_location = _home + flank * 10.0 + _front * 4.0
		return 0 if _try_build(_investment_kind, _investment_location) else BalanceCatalog.building(&"factory").cost
	if _building("academy") == null and _workers.size() >= 6 and _clock >= 100.0:
		_investment_kind = "academy"
		_investment_location = _home - _front * 6.0 - flank * 8.0
		return 0 if _try_build(_investment_kind, _investment_location) else BalanceCatalog.building(&"academy").cost
	var academy: Node3D = _building("academy", true)
	var player: PlayerState = _game.get_player(_owner)
	if academy == null or not player.active_research.is_empty() or _clock < _next_research_at:
		return 0
	# Population is a paid research limit shared with human production. Save for
	# expansion only near the current cap, when more recruitment is almost blocked.
	if player.army_capacity_level < int(BalanceCatalog.UPGRADE_TRACKS[&"army_capacity"]) and player.used_military_supply() >= player.get_supply_limit() - 5:
		var expansion := BalanceCatalog.upgrade("army_capacity_%d" % (player.army_capacity_level + 1))
		return 0 if _start_research(academy, expansion) else expansion.cost
	if _can_expand_workforce(player):
		var workforce := BalanceCatalog.upgrade(&"workforce_1")
		if _start_research(academy, workforce):
			return 0
	# Economic research uses spare income after a viable army exists. Always leave
	# enough gold for two swordsmen instead of halting reinforcements to save for it.
	if player.mining_level < int(BalanceCatalog.UPGRADE_TRACKS[&"mining"]) and _workers.size() >= 6 and _army.size() >= 6:
		var mining := BalanceCatalog.upgrade("mining_%d" % (player.mining_level + 1))
		if _budget >= mining.cost + BalanceCatalog.unit(&"swordsman").cost * 2 and _start_research(academy, mining):
			return 0
	var track: String = "defense" if player.defense_level <= player.attack_level else "attack"
	var level: int = player.get_upgrade_level(StringName(track)) + 1
	if level > int(BalanceCatalog.UPGRADE_TRACKS[track]):
		return 0
	var upgrade: UpgradeDefinition = BalanceCatalog.upgrade(StringName("%s_%d" % [track, level]))
	if _start_research(academy, upgrade):
		return 0
	return upgrade.cost

func _start_research(academy: Node3D, upgrade: UpgradeDefinition) -> bool:
	if not _submit({"kind": "research", "target": academy.entity_id, "upgrade": String(upgrade.id)}, upgrade.cost):
		return false
	# A small fighting army gets a reinforcement window between upgrades;
	# an established eight-unit army can sustain consecutive research.
	_next_research_at = _clock + upgrade.research_seconds + (25.0 if _army.size() < 8 else 0.0)
	return true

func _can_expand_workforce(player: PlayerState) -> bool:
	if player.get_upgrade_level(&"workforce") > 0 or _budget < BalanceCatalog.upgrade(&"workforce_1").cost:
		return false
	if player.farmers + player.reserved_farmers < PlayerState.WORKER_LIMIT or _mines.size() < 2:
		return false
	var available_slots := 0
	for mine: Node3D in _mines:
		available_slots += ResourceVein.CAPACITY - mine.occupied_slots()
	return available_slots >= BalanceCatalog.upgrade(&"workforce_1").total_bonus

func _recruit_farmer(reserve: int) -> void:
	var hq: Node3D = _building("headquarters", true)
	var player: PlayerState = _game.get_player(_owner)
	var desired: int = player.get_worker_limit() if _mines.size() >= 2 and _army.size() >= MINIMUM_RAID_SIZE else 6
	if hq == null or _clock < _farmer_pending_until or player.reserved_farmers > 0 or player.farmers >= desired or not player.can_reserve_farmer():
		return
	if _budget - reserve < 50 or (_enemy_power_near(_home, 15.0) > 150.0 and _army.size() < 3):
		return
	if _submit({"kind": "recruit", "target": hq.entity_id, "unit_type": "farmer"}, 50):
		_farmer_pending_until = _clock + 3.0

func _composition() -> Dictionary:
	var counts: Dictionary = {"swordsman": 0.0, "archer": 0.0, "knight": 0.0, "siege": 0.0}
	for record: Dictionary in _memory.values():
		if record.building or record.kind == "farmer":
			continue
		var kind: String = "siege" if record.kind in ["catapult", "cannon"] else String(record.kind)
		counts[kind] += maxf(0.0, 1.0 - (_clock - float(record.seen_at)) / UNIT_MEMORY_SECONDS)
	return counts

func _known_fortifications() -> int:
	var count: int = 0
	for record: Dictionary in _memory.values():
		if record.building and record.kind in ["headquarters", "defense_tower", "tower"]:
			count += 1
	return count

func _choose_recruit(counts: Dictionary) -> String:
	var factory: Node3D = _building("factory", true)
	var enemy: Dictionary = _composition()
	var total: int = int(counts.swordsman + counts.archer + counts.knight + counts.catapult + counts.cannon)
	if factory != null and total >= MINIMUM_RAID_SIZE:
		if _known_fortifications() > 0 and int(counts.cannon) < maxi(1, total / 10):
			return "cannon"
		if float(enemy.swordsman) + float(enemy.archer) >= 3.0 and int(counts.catapult) < maxi(1, total / 12):
			return "catapult"
	var ratios: Dictionary = {"swordsman": 0.45, "archer": 0.30, "knight": 0.25}
	if float(enemy.knight) > float(enemy.archer) + float(enemy.swordsman):
		ratios = {"swordsman": 0.45, "archer": 0.45, "knight": 0.10}
	elif float(enemy.archer) > float(enemy.knight) + float(enemy.swordsman):
		ratios = {"swordsman": 0.30, "archer": 0.20, "knight": 0.50}
	elif float(enemy.siege) >= 2.0:
		ratios = {"swordsman": 0.45, "archer": 0.10, "knight": 0.45}
	var choice: String = "swordsman"
	var deficit: float = -INF
	var troops: int = int(counts.swordsman + counts.archer + counts.knight)
	for kind: String in ["swordsman", "archer", "knight"]:
		var wanted: float = float(ratios[kind]) * (troops + 1) - int(counts[kind])
		if wanted > deficit:
			choice = kind
			deficit = wanted
	return choice

func _recruit_army(reserve: int) -> void:
	var factory_only: bool = _building("barracks", true) == null
	# With neither headquarters nor builders, use the surviving factory instead
	# of saving forever for infrastructure that this player can no longer build.
	if factory_only and (_building("headquarters") != null or not _workers.is_empty() or _building("factory", true) == null):
		return
	var counts: Dictionary = {"swordsman": 0, "archer": 0, "knight": 0, "catapult": 0, "cannon": 0}
	for unit: Node3D in _army:
		counts[unit.unit_type] += 1
	var queued_counts: Dictionary = {}
	var queued_seconds: Dictionary = {}
	for building: Node3D in _buildings:
		queued_counts[building.entity_id] = building.production.training.size()
		queued_seconds[building.entity_id] = 0.0
		for job: Dictionary in building.production.training:
			queued_seconds[building.entity_id] += maxf(0.0, BalanceCatalog.unit(job.kind).training_seconds - float(job.elapsed))
			if job.kind != "farmer":
				counts[job.kind] += 1
	var player: PlayerState = _game.get_player(_owner)
	var supply: int = player.used_military_supply()
	for purchase: int in range(3):
		var kind: String = _choose_recruit(counts)
		if factory_only:
			kind = "cannon" if _known_fortifications() > 0 else "catapult"
		var definition: UnitDefinition = BalanceCatalog.unit(kind)
		var producer: Node3D
		var shortest: float = INF
		for building: Node3D in _buildings:
			if building.is_constructed and building.building_type == String(definition.production_building) and int(queued_counts[building.entity_id]) < BuildingProduction.TRAINING_LIMIT and float(queued_seconds[building.entity_id]) < shortest:
				producer = building
				shortest = float(queued_seconds[building.entity_id])
		if producer == null or _budget - reserve < definition.cost or supply + definition.supply > player.get_supply_limit():
			return
		if not _submit({"kind": "recruit", "target": producer.entity_id, "unit_type": kind}, definition.cost):
			return
		counts[kind] += 1
		supply += definition.supply
		queued_counts[producer.entity_id] += 1
		queued_seconds[producer.entity_id] += definition.training_seconds

func _enemy_power_near(at: Vector3, reach: float) -> float:
	var power: float = 0.0
	for entity: Node3D in _visible_enemies:
		var record: Dictionary = _memory[entity.entity_id]
		if not record.building and record.kind != "farmer" and at.distance_squared_to(record.position) <= reach * reach:
			power += float(record.power)
	return power

func _threatened_base() -> Node3D:
	var best: Node3D
	var greatest: float = 0.0
	for player: PlayerState in _game.players:
		if player.alliance_id != _game.get_player(_owner).alliance_id:
			continue
		for building: Node3D in _game.owned_entities(player.owner_id, "buildings"):
			if building.building_type != "headquarters":
				continue
			var threat: float = _enemy_power_near(building.global_position, 17.0)
			if threat > greatest:
				greatest = threat
				best = building
	return best

func _attack_target(from: Vector3, reach: float) -> Node3D:
	var best: Node3D
	var priority: float = INF
	for entity: Node3D in _visible_enemies:
		var record: Dictionary = _memory[entity.entity_id]
		var distance: float = from.distance_to(record.position)
		if distance > reach:
			continue
		var score: float = distance + (18.0 if record.building else 0.0)
		if record.kind in ["catapult", "cannon"]:
			score *= 0.65
		elif record.kind == "farmer":
			score += 8.0
		if score < priority:
			priority = score
			best = entity
	return best

func _strategic_objective() -> Vector3:
	var goal := Vector3.ZERO
	var distance: float = INF
	for record: Dictionary in _memory.values():
		if not record.building:
			continue
		var candidate: float = _allied_center.distance_squared_to(record.position)
		if candidate < distance:
			distance = candidate
			goal = record.position
	if not is_inf(distance):
		return goal
	# Start locations are public map data. Search each opposing territory rather
	# than mirroring our own base, which misses factions on three/six-way maps.
	# Never inspect hidden enemy entities to choose the next scouting destination.
	var starts: Array[Vector3] = []
	for player: PlayerState in _game.players:
		if player.alliance_id != _game.get_player(_owner).alliance_id and not player.eliminated:
			starts.append(_game.get_spawn_marker(player.owner_id).global_position)
	starts.sort_custom(func(a: Vector3, b: Vector3): return _allied_center.distance_squared_to(a) < _allied_center.distance_squared_to(b))
	if starts.is_empty():
		return goal
	_search_lane %= starts.size()
	goal = starts[_search_lane]
	for unit: Node3D in _army:
		if unit.global_position.distance_squared_to(goal) < 36.0:
			_search_lane = (_search_lane + 1) % starts.size()
			goal = starts[_search_lane]
			break
	return goal

func _order_army(kind: String, at: Vector3, target: int = 0, attack_move: bool = false) -> void:
	var ids: Array[int] = []
	for unit: Node3D in _army:
		ids.append(unit.entity_id)
	var point: Vector3 = _game.clamp_to_map(at)
	var signature: String = "%s/%s/%d/%s/%s" % [army_state, kind, target, point.snapped(Vector3(2, 2, 2)), ids]
	if signature == _last_army_order and _clock - _last_army_order_at < COMMAND_REFRESH_SECONDS:
		return
	var command := {"kind": kind, "units": ids, "queued": false}
	if target != 0:
		command["target"] = target
	else:
		command["at"] = [point.x, 0, point.z]
		command["attack_move"] = attack_move
	if _submit(command):
		_last_army_order = signature
		_last_army_order_at = _clock

func _command_army() -> void:
	if _army.is_empty():
		return
	var center := Vector3.ZERO
	var strength: float = 0.0
	for unit: Node3D in _army:
		center += unit.global_position
		strength += BalanceCatalog.unit(unit.unit_type).cost * clampf(unit.hp / unit.max_hp, 0.0, 1.0)
	center /= _army.size()
	var nearby: float = _enemy_power_near(center, 16.0)
	if nearby > strength * 1.5 and center.distance_to(_home) > 10.0:
		_retreat_until = _clock + 7.0
	if _clock < _retreat_until:
		army_state = &"retreat"
		_order_army("move", _home - _front * 3.0)
		return
	var threatened: Node3D = _threatened_base()
	if threatened != null:
		army_state = &"defend" if threatened.owner_id == _owner else &"ally_rescue"
		var intruder: Node3D = _attack_target(threatened.global_position, 19.0)
		if intruder != null:
			_order_army("attack", intruder.global_position, intruder.entity_id)
		return
	if _army.size() >= MINIMUM_RAID_SIZE and _clock >= 30.0:
		army_state = &"attack"
		var enemy: Node3D = _attack_target(center, 22.0)
		if enemy != null:
			_order_army("attack", enemy.global_position, enemy.entity_id)
		else:
			_order_army("move", _strategic_objective(), 0, true)
		return
	if _clock >= 90.0:
		# After the opening scout, a depleted army rebuilds at home instead of
		# donating each replacement to the enemy before a viable squad forms.
		army_state = &"muster"
		_order_army("move", _home + _front * 6.0, 0, true)
	elif _clock >= 18.0 and _clock >= _next_scout_at:
		army_state = &"scout"
		var flank: Vector3 = _front.cross(Vector3.UP)
		var waypoint: Vector3 = _home + _front * (18.0 + _scout_step * 13.0) + flank * (8.0 if _scout_step % 2 == 0 else -8.0)
		_order_army("move", waypoint, 0, true)
		_scout_step = (_scout_step + 1) % 3
		_next_scout_at = _clock + 9.0
	elif _clock < 18.0:
		army_state = &"muster"
		_order_army("move", _home + _front * 7.0, 0, true)
