extends SceneTree
## Exercise real gathering cycles and the authoritative payout boundary.
var game: Node3D
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func _run() -> void:
	create_timer(45.0, true, false, true).timeout.connect(func(): quit(3))
	var session: Node = root.get_node("Session")
	for mode: String in NetworkProtocol.MODES:
		var config: Dictionary = session.offline_config(mode, "nightmare")
		check(NetworkProtocol.match_config_error(config).is_empty(), mode + " nightmare roster validates")
		check(config.players[0].bot_difficulty == "normal" and config.players.slice(1).all(func(slot): return slot.bot_difficulty == "nightmare"), mode + " only computers inherit solo difficulty")
	var invalid: Dictionary = session.offline_config("1v1")
	invalid.players[1].bot_difficulty = "unknown"
	check(NetworkProtocol.match_config_error(invalid) == "invalid_difficulty", "unrecognized difficulty rejected")
	invalid.players[1].bot_difficulty = "hard"
	invalid.players[0].bot_difficulty = "hard"
	check(NetworkProtocol.match_config_error(invalid) == "invalid_difficulty", "human cheat rejected in match configuration")
	session.start_offline("1v1", "hard")
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	game.tests_running = true
	game.bots.clear()
	game.set_physics_process(false)
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	var player: PlayerState = game.get_player(1)
	check(player.bot_difficulty == "hard" and player.get_gather_yield_multiplier() == 2, "selected difficulty crosses scene change into live owner state")
	var worker: BattleUnit = game.owned_entities(1, "units").filter(func(unit): return unit.unit_type == "farmer")[0]
	var mine: ResourceVein = game.nearest_mine(worker.position)
	for difficulty: String in NetworkProtocol.BOT_DIFFICULTIES:
		player.bot_difficulty = difficulty
		var multiplier: int = NetworkProtocol.BOT_DIFFICULTIES[difficulty].gather_multiplier
		for mining_level: int in [0, 3]:
			player.mining_level = mining_level
			worker.stop()
			worker.issue_gather(mine)
			worker.global_position = worker.destination
			var before: int = player.gold
			var cycle: float = BalanceCatalog.ECONOMY.mining_seconds / player.get_mining_rate_multiplier()
			worker._work_velocity(cycle * 0.5)
			check(player.gold == before, difficulty + " no partial cycle income at mining level " + str(mining_level))
			worker._work_velocity(cycle * 0.5 + 0.00001)
			check(player.gold == before + BalanceCatalog.ECONOMY.mining_gold * multiplier, difficulty + " exact full-cycle payout at mining level " + str(mining_level))
		var before: int = player.gold
		game._on_income()
		check(player.gold - before == BalanceCatalog.ECONOMY.passive_gold_per_second, difficulty + " passive income remains unmultiplied")
	player.bot_difficulty = "nightmare"
	var before: int = player.gold
	game.is_authority = false
	game._on_gathered(worker, 4)
	game.is_authority = true
	check(player.gold == before, "replica never pays gathering")
	paused = true
	game._on_gathered(worker, 4)
	paused = false
	check(player.gold == before, "paused match never pays gathering")
	game.finished = true
	game._on_gathered(worker, 4)
	game.finished = false
	check(player.gold == before, "finished match never pays gathering")
	worker.alive = false
	game._on_gathered(worker, 4)
	worker.alive = true
	check(player.gold == before, "dead worker never pays gathering")
	player.controller = "human"
	game._on_gathered(worker, 4)
	check(player.gold == before + 4, "human control ignores any computer difficulty")
	var human: PlayerState = game.get_player(0)
	game._on_network_event({"kind": "bot_takeover", "owner": 0})
	check(human.controller == "bot" and human.get_gather_yield_multiplier() == 1, "disconnected human takeover retains normal economy")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("BOT_DIFFICULTY_RESULTS " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)
