extends SceneTree
## Real main-scene economy and combat. No spawned units, free buildings or gold subsidies.
## Ten-times wall-clock speed still uses the production 1/30-second simulation step.
const SPEED: int = 10
var duration: float = 360.0
var game: Node3D
var mode: String = "1v1"
var checks: int = 0
var failures: Array[String] = []
var statistics: Dictionary = {}
var samples: Array[Dictionary] = []
var known_entities: Dictionary = {}
var known_hp: Dictionary = {}
var seen_commands: Dictionary = {}
var first_damage: float = -1.0
var last_damage: float = -1.0
var damage_events: int = 0
var started_at: int = 0
var invariant_failures: Dictionary = {}

func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--duration="):
			duration = clampf(float(argument.trim_prefix("--duration=")), 360.0, 1800.0)
	Engine.physics_ticks_per_second = 30 * SPEED
	Engine.max_physics_steps_per_frame = 64
	Engine.time_scale = SPEED
	_run.call_deferred()

func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		printerr("FAIL ", message)

func _invariant(value: bool, message: String) -> void:
	if not value:
		invariant_failures[message] = true

func _run() -> void:
	seed(947103)
	mode = "2v2" if "--2v2" in OS.get_cmdline_user_args() else "1v1"
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.camera_rig.edge_scroll = false
	for player: PlayerState in game.players:
		player.controller = "bot"
		game.bots[player.owner_id] = SkirmishBot.new(game, player.owner_id)
		statistics[player.owner_id] = {"first_barracks_site": -1.0, "first_barracks_complete": -1.0,
			"first_military": -1.0, "first_raid": -1.0, "first_factory": -1.0, "first_academy": -1.0,
			"first_research": -1.0, "first_expansion_mining": -1.0, "gathered_gold": 0, "max_workers": 0,
			"max_supply": 0, "produced": {}, "completed": {}, "commands": {}, "main_mine": game.nearest_mine(game.owned_entities(player.owner_id, "buildings")[0].position).entity_id}
	_check(game.players.size() == (4 if mode == "2v2" else 2), "%s loads the expected independent owners" % mode)
	_check(game.bots.size() == game.players.size(), "all owners use the same production Bot")
	for player: PlayerState in game.players:
		_check(player.gold == 320 and player.farmers == 3 and player.military_supply == 0, "owner %d starts with only the approved economy" % player.owner_id)
	started_at = Time.get_ticks_msec()
	var next_sample: float = 0.0
	while game.elapsed < duration and not game.finished:
		await physics_frame
		_watch_commands()
		_observe_entities()
		if game.elapsed >= next_sample:
			_sample()
			next_sample += 30.0
		if Time.get_ticks_msec() - started_at > 300000:
			_check(false, "long-run exceeded the five-minute wall-clock guard")
			break
	_sample()
	for message: String in invariant_failures:
		_check(false, message)
	_check(invariant_failures.is_empty(), "all ticks preserve economy, worker, supply, mine and builder invariants")
	_check(first_damage > 0 and first_damage < 100, "real opposing armies deal damage within 100 simulation seconds")
	_check(game.elapsed >= duration - 0.1 or game.finished, "match simulates the requested duration or reaches a legitimate victory")
	_check(statistics.values().any(func(stat): return float(stat.first_research) > 0), "active combat does not permanently starve all technology research")
	_check(statistics.values().any(func(stat): return int(stat.completed.get("factory", 0)) > 0), "a real paid military factory completes during the match")
	for owner: int in statistics:
		var stat: Dictionary = statistics[owner]
		_check(float(stat.first_barracks_site) > 0 and float(stat.first_barracks_site) < 8, "owner %d starts its first barracks promptly" % owner)
		_check(float(stat.first_military) > 0 and float(stat.first_military) < 45, "owner %d trains combat troops before 45 seconds" % owner)
		_check(int(stat.gathered_gold) >= 300, "owner %d sustains real mining income" % owner)
		_check(stat.produced.size() >= 4, "owner %d develops farmers and all three basic military roles" % owner)
	var report: Dictionary = {"mode": mode, "simulated_seconds": game.elapsed, "wall_seconds": (Time.get_ticks_msec() - started_at) / 1000.0,
		"requested_seconds": duration, "victory_within_six_to_ten_minutes": game.finished and game.elapsed >= 360.0 and game.elapsed <= 600.0,
		"simulation_step": game.elapsed / maxi(game.simulation_tick, 1), "finished": game.finished,
		"first_damage": first_damage, "last_damage": last_damage, "damage_events": damage_events,
		"checks": checks, "failures": failures, "players": statistics, "samples": samples, "final_entities": _diagnostics()}
	var suffix: String = "_%ds" % int(duration) if duration != 360.0 else ""
	var file := FileAccess.open("res://artifacts/skirmish_longrun_%s%s.json" % [mode, suffix], FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("SKIRMISH_LONGRUN_RESULT ", mode, " ", checks, " checks; ", failures.size(), " failures; simulated=", game.elapsed, " first_damage=", first_damage)
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 30
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)

func _watch_commands() -> void:
	for command: Dictionary in game.command_bus.pending:
		var key: String = "%d/%d" % [command.owner, command.seq]
		if seen_commands.has(key):
			continue
		seen_commands[key] = true
		var stat: Dictionary = statistics[int(command.owner)]
		stat.commands[command.kind] = int(stat.commands.get(command.kind, 0)) + 1

func _observe_entities() -> void:
	for entity: Node3D in get_nodes_in_group("entities"):
		var stat: Dictionary = statistics[entity.owner_id]
		if not known_entities.has(entity.entity_id):
			known_entities[entity.entity_id] = true
			if entity is BattleUnit:
				stat.produced[entity.unit_type] = int(stat.produced.get(entity.unit_type, 0)) + 1
				if entity.unit_type == "farmer":
					entity.gathered.connect(_on_gathered)
				elif float(stat.first_military) < 0:
					stat.first_military = game.elapsed
			else:
				entity.construction_completed.connect(_on_building_completed)
				var field: String = "first_%s" % entity.building_type
				if entity.building_type == "barracks": field = "first_barracks_site"
				if stat.has(field) and float(stat[field]) < 0: stat[field] = game.elapsed
		if known_hp.has(entity.entity_id) and entity.hp < float(known_hp[entity.entity_id]) - 0.1:
			if first_damage < 0: first_damage = game.elapsed
			last_damage = game.elapsed
			damage_events += 1
		known_hp[entity.entity_id] = entity.hp
		if entity is BattleUnit and entity.unit_type == "farmer":
			_invariant(not entity._claimed_site or (entity.order == BattleUnit.Order.BUILD and is_instance_valid(entity.work_target) and not entity.work_target.is_constructed), "builder claim survives only while actively building an unfinished site")
	for player: PlayerState in game.players:
		var stat: Dictionary = statistics[player.owner_id]
		stat.max_workers = maxi(int(stat.max_workers), player.farmers)
		stat.max_supply = maxi(int(stat.max_supply), player.military_supply)
		if (player.attack_level + player.defense_level) > 0 and float(stat.first_research) < 0: stat.first_research = game.elapsed
		if game.bots[player.owner_id].army_state == &"attack" and float(stat.first_raid) < 0: stat.first_raid = game.elapsed
		_invariant(player.gold >= 0, "gold never becomes negative")
		_invariant(player.farmers + player.reserved_farmers <= player.get_worker_limit(), "live and queued farmers never exceed the owner's researched worker limit")
		_invariant(player.military_supply <= 60, "military supply never exceeds sixty per owner")
		var actual_workers: int = 0
		var actual_supply: int = 0
		for unit: BattleUnit in game.owned_entities(player.owner_id, "units"):
			if unit.unit_type == "farmer": actual_workers += 1
			else: actual_supply += BalanceCatalog.unit(unit.unit_type).supply
		_invariant(actual_workers == player.farmers and actual_supply == player.military_supply, "owner population counters agree with living production entities")
	for mine: ResourceVein in get_nodes_in_group("resource_veins"):
		_invariant(mine.occupied_slots() <= 6, "no mine grants a seventh worker slot")

func _on_gathered(worker: BattleUnit, amount: int) -> void:
	var stat: Dictionary = statistics[worker.owner_id]
	stat.gathered_gold += amount
	if worker.work_target.entity_id != int(stat.main_mine) and float(stat.first_expansion_mining) < 0:
		stat.first_expansion_mining = game.elapsed

func _on_building_completed(building: BattleBuilding) -> void:
	var stat: Dictionary = statistics[building.owner_id]
	stat.completed[building.building_type] = int(stat.completed.get(building.building_type, 0)) + 1
	if building.building_type == "barracks" and float(stat.first_barracks_complete) < 0:
		stat.first_barracks_complete = game.elapsed

func _sample() -> void:
	var row: Dictionary = {"at": snappedf(game.elapsed, 0.1), "players": []}
	for player: PlayerState in game.players:
		row.players.append({"owner": player.owner_id, "gold": player.gold, "workers": player.farmers,
			"supply": player.military_supply, "army": game.owned_entities(player.owner_id, "units").filter(func(unit): return unit.unit_type != "farmer").size(),
			"buildings": game.owned_entities(player.owner_id, "buildings").size(), "attack": player.attack_level,
			"defense": player.defense_level, "state": String(game.bots[player.owner_id].army_state)})
	samples.append(row)
	print("SKIRMISH_LONGRUN_SAMPLE ", mode, " ", JSON.stringify(row))

func _diagnostics() -> Array:
	var entities: Array = []
	for entity: Node3D in get_nodes_in_group("entities"):
		var row: Dictionary = {"id": entity.entity_id, "owner": entity.owner_id, "hp": snappedf(entity.hp, 0.1), "position": [entity.position.x, entity.position.z]}
		if entity is BattleUnit:
			row["kind"] = entity.unit_type
			row["order"] = entity.order_name
			row["work_target"] = entity.work_target.entity_id if is_instance_valid(entity.work_target) else 0
			row["claimed_mine"] = entity._claimed_mine
			row["claimed_site"] = entity._claimed_site
		else:
			row["kind"] = entity.building_type
			row["construction"] = entity.construction_progress
		entities.append(row)
	return entities
