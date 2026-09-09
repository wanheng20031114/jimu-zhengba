extends SceneTree
## Real authored maps and native match nodes validate sparse, stable owner IDs.

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	Engine.max_fps = 60
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func _run() -> void:
	check(CombatLayers.UNIT_LAYERS.size() == NetworkProtocol.MAX_PLAYERS and CombatLayers.BUILDING_LAYERS.size() == NetworkProtocol.MAX_PLAYERS, "all_eight_alliances_have_native_collision_layers")
	for alliance in range(8):
		for other in range(8):
			check(bool(CombatLayers.hostile_units(alliance) & CombatLayers.UNIT_LAYERS[other]) == (alliance != other), "alliance_%d_unit_filter_%d" % [alliance, other])
			check(bool(CombatLayers.hostile_entities(alliance) & CombatLayers.BUILDING_LAYERS[other]) == (alliance != other), "alliance_%d_building_filter_%d" % [alliance, other])
	await _case("4v4", [0, 1, 2, 3, 4, 7])
	await _case("ffa", [0, 3, 7])
	print("EMPTY_SLOTS_MATCH_RESULTS " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)

func _case(mode: String, active: Array) -> void:
	var session: Node = root.get_node("Session")
	session.online = false
	session.config = session.offline_config(mode)
	for slot: Dictionary in session.config.players:
		if int(slot.owner_id) not in active:
			slot.controller = "open"
			slot.name = "空位"
	check(NetworkProtocol.match_config_error(session.config).is_empty(), mode + "_sparse_roster_valid")
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	var game: Node3D = current_scene
	game.tests_running = true
	game.set_physics_process(false)
	game.get_node("IncomeTimer").stop()
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	check(game.players.size() == 8 and game.bots.size() == active.size() - 1, mode + "_only_actual_bots_created")
	check(get_nodes_in_group("units").size() == active.size() * 3, mode + "_only_actual_workers_spawned")
	check(get_nodes_in_group("buildings").size() == active.size() * 2, mode + "_only_actual_headquarters_and_towers_spawned")
	var original_gold: Array[int] = []
	for player: PlayerState in game.players:
		original_gold.append(player.gold)
	game._on_income()
	var fog: FogOfWar = game.get_node("FogOfWar")
	for owner in range(8):
		var player: PlayerState = game.get_player(owner)
		check(player.owner_id == owner, mode + "_owner_%d_never_compressed" % owner)
		if owner in active:
			check(player.gold == original_gold[owner] + BalanceCatalog.ECONOMY.passive_gold_per_second, mode + "_active_income_%d" % owner)
			check(game.get_spawn_marker(owner).get_meta("alliance_id") == player.alliance_id, mode + "_spawn_respects_team_%d" % owner)
			continue
		check(player.gold == 0 and player.farmers == 0 and not player.is_participating(), mode + "_empty_has_no_economy_%d" % owner)
		check(game.owned_entities(owner, "entities").is_empty(), mode + "_empty_has_no_assets_%d" % owner)
		check(not fog.position_visible(owner, game.get_spawn_marker(0).global_position), mode + "_empty_gets_no_team_vision_%d" % owner)
		check(not game.command_bus.submit({"kind": "stop", "seq": 1}, owner).ok, mode + "_empty_cannot_issue_commands_%d" % owner)
		game._on_network_event({"kind": "bot_takeover", "owner": owner})
		game._on_network_event({"kind": "player_reconnected", "owner": owner})
		check(player.controller == "open" and not game.bots.has(owner), mode + "_empty_cannot_become_reconnect_bot_%d" % owner)
	game.replication.configure(game, session.relay)
	var snapshot: Dictionary = game.replication.build_snapshot(0)
	check(game.replication._valid_snapshot(snapshot), mode + "_sparse_snapshot_valid")
	var vacant: int = 5 if mode == "4v4" else 1
	var invalid: Dictionary = snapshot.duplicate(true)
	invalid.players[vacant].controller = "bot"
	check(not game.replication._valid_snapshot(invalid), mode + "_snapshot_cannot_activate_empty_slot")
	invalid = snapshot.duplicate(true)
	invalid.entities[0].owner = vacant
	check(not game.replication._valid_snapshot(invalid), mode + "_snapshot_cannot_spawn_empty_owner_entity")
	game.tests_running = false
	game.check_victory()
	check(not game.finished, mode + "_empty_alliances_do_not_win_or_lose_match")
	for owner in range(8):
		if owner not in active:
			check(not game.get_player(owner).eliminated, mode + "_vacancies_not_eliminated_%d" % owner)
	if mode == "ffa":
		check(game._revealed_alliances.is_empty(), "ffa_empty_factions_not_permanently_revealed")
		for building: Node3D in game.owned_entities(3, "buildings"):
			building.receive_damage(building.hp)
		game.check_victory()
		check(game.get_player(3).eliminated and not game.finished and not game.get_player(7).eliminated, "ffa_sparse_middle_faction_eliminates_without_ending")
	var enemy_alliance: int = game.get_player(7).alliance_id
	for building: Node3D in get_nodes_in_group("buildings"):
		if building.alive and building.alliance_id == enemy_alliance:
			building.receive_damage(building.hp)
	game.check_victory()
	check(game.finished and not game.get_player(0).eliminated, mode + "_last_real_enemy_defeated_ends_match")
	await game.prepare_shutdown()
	game.queue_free()
	current_scene = null
	await process_frame
	await process_frame
	session.config.clear()
