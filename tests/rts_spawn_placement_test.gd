extends SceneTree
## Native physics/navigation exits, exact adjacent footprints and real rally mining.
var game: Node3D
var checks: int = 0
var failures: Array[String] = []
var producer: BattleBuilding
var blockers: Array[BattleBuilding] = []

func _initialize() -> void:
	Engine.max_fps = 60
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error(label)

func freeze_building(building: BattleBuilding) -> void:
	building.set_physics_process(false)
	building.production.set_physics_process(false)

func sync_navigation() -> void:
	game.get_node("ConstructionNavigation").refresh()
	while game.get_node("ConstructionNavigation").is_rebuilding():
		await physics_frame
	for index in range(3):
		await physics_frame

func _run() -> void:
	var mode: String = "2v2" if "--2v2" in OS.get_cmdline_user_args() else "1v1"
	root.get_node("Session").start_offline(mode)
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	game.tests_running = true
	game.set_physics_process(false)
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		freeze_building(building)
	game.get_player(0).gold = 20000
	producer = game.spawn_building("barracks", 0, Vector3.ZERO)
	freeze_building(producer)
	await sync_navigation()
	game.get_node("FogOfWar")._recompute()
	_adjacency()
	await _exits()
	await _mining()
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("RTS_SPAWN_PLACEMENT_RESULTS " + JSON.stringify({"mode": mode, "checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)

func _adjacency() -> void:
	var definition := producer.get_combat_definition()
	var contact_positions: Array[Vector3] = [Vector3(definition.size.x, 0, 0), Vector3(-definition.size.x, 0, 0), Vector3(0, 0, definition.size.z), Vector3(0, 0, -definition.size.z)]
	var allowed: int = 0
	for at: Vector3 in contact_positions:
		var reason: String = game.placement_error(at, 0, "barracks")
		if reason.is_empty():
			allowed += 1
		check(reason != "这里有单位或障碍物", "touching_footprint_has_no_artificial_collision_margin_" + str(at))
	check(allowed > 0, "at_least_one_touching_building_position_is_buildable")
	check(not game.placement_error(Vector3(definition.size.x - 1, 0, 0), 0, "barracks").is_empty(), "one_grid_cell_real_overlap_rejected")
	check(not game.placement_error(Vector3.ZERO, 0, "barracks").is_empty(), "same_footprint_overlap_rejected")
	var transient: BattleBuilding = game.spawn_building("defense_tower", 0, Vector3(-7, 0, 7), true)
	freeze_building(transient)
	check(game.placement_error(transient.global_position, 0, "defense_tower") == "这里已有建筑或工地", "same_tick_new_site_reserves_exact_footprint_before_physics_sync")
	transient.cancel_construction()
	check(not game.placement_error(Vector3(game.map_size.x, 0, 0), 0, "barracks").is_empty(), "out_of_map_placement_rejected")
func _exits() -> void:
	for rally: Vector3 in [Vector3(20, 0, -20), Vector3(-20, 0, 20)]:
		producer.rally_point = rally
		var at: Vector3 = game.find_recruit_position("swordsman", producer)
		check(at.is_finite(), "both_opposite_building_sides_can_spawn_" + str(rally))
		if at.is_finite():
			var alignment: float = at.normalized().dot(rally.normalized())
			check(alignment > 0.999, "clear_rally_ray_has_first_priority_" + str(rally))
	for kind: String in ["farmer", "swordsman", "archer", "knight", "catapult", "cannon"]:
		var at: Vector3 = game.find_recruit_position(kind, producer)
		check(at.is_finite(), "all_body_sizes_find_valid_exit_" + kind)
		if at.is_finite():
			check(game.get_node("ConstructionNavigation").contains_walkable_point(at), "exit_on_current_logical_nav_" + kind)
			var closest: Vector3 = NavigationServer3D.map_get_closest_point(game.get_world_3d().navigation_map, at)
			check(closest.distance_to(at) < 0.21, "exit_on_published_native_nav_" + kind)
	var first_exit: Vector3 = game.find_recruit_position("swordsman", producer)
	var occupant: BattleUnit = game.spawn_unit("swordsman", 0, first_exit)
	occupant.set_physics_process(false)
	occupant.navigation_agent.avoidance_enabled = false
	var next_exit: Vector3 = game.find_recruit_position("swordsman", producer)
	check(next_exit.is_finite() and next_exit.distance_to(first_exit) > 0.6, "same_tick_spawn_occupancy_is_respected_by_native_physics_query")
	occupant.receive_damage(occupant.hp)
	producer.rally_point = Vector3(0, 0, 30)
	for at: Vector3 in [Vector3(0, 0, 6), Vector3(7, 0, 0), Vector3(-7, 0, 0), Vector3(6, 0, 6), Vector3(-6, 0, 6)]:
		var blocker: BattleBuilding = game.spawn_building("defense_tower", 0, at)
		freeze_building(blocker)
		blockers.append(blocker)
	await sync_navigation()
	var rear_exit: Vector3 = game.find_recruit_position("swordsman", producer)
	check(rear_exit.is_finite() and rear_exit.z < 0, "blocked_front_and_sides_fall_back_to_rear_exit")
	var rear: BattleBuilding
	for at: Vector3 in [Vector3(0, 0, -6), Vector3(6, 0, -6), Vector3(-6, 0, -6)]:
		var blocker: BattleBuilding = game.spawn_building("defense_tower", 0, at)
		freeze_building(blocker)
		blockers.append(blocker)
		if at.x == 0:
			rear = blocker
	await sync_navigation()
	check(not game.find_recruit_position("swordsman", producer).is_finite(), "fully_encircled_building_has_no_teleport_exit")
	check(producer.production.recruit("swordsman").ok, "blocked_production_can_accept_paid_training")
	var reserved: int = game.get_player(0).reserved_military_supply
	producer.production._physics_process(6.0)
	check(producer.production.training.size() == 1 and producer.production.training[0].elapsed == 6.0, "completed_training_waits_inside_blocked_building")
	check(game.get_player(0).reserved_military_supply == reserved, "waiting_completed_job_keeps_reserved_population")
	rear.demolish()
	await sync_navigation()
	producer.production._physics_process(0.3)
	check(producer.production.training.is_empty(), "opening_rear_exit_releases_completed_unit")
	check(game.get_player(0).reserved_military_supply == reserved - 1, "spawn_transfers_reserved_population_to_live_unit")
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false

func _mining() -> void:
	var hq: BattleBuilding = game.headquarters
	var mine: ResourceVein = get_nodes_in_group("resource_veins")[0]
	game.select_entities([hq])
	game.command_gather(mine)
	game.command_bus.tick()
	check(hq.production.rally_mine == mine and hq.rally_point == mine.global_position, "hq_context_mine_command_sets_both_rally_position_and_mine")
	check(hq.production.recruit("farmer").ok, "rally_farmer_training_accepted")
	var before: Array = game.owned_entities(0, "units")
	hq.production._physics_process(10.0)
	var farmer: BattleUnit
	for unit: BattleUnit in game.owned_entities(0, "units"):
		if unit not in before:
			farmer = unit
	check(farmer != null, "trained_farmer_spawns_through_real_production")
	if farmer == null:
		return
	farmer.set_physics_process(false)
	farmer.navigation_agent.avoidance_enabled = false
	check(farmer.order == BattleUnit.Order.GATHER and farmer.work_target == mine, "rallied_farmer_automatically_starts_mining_order")
	check(farmer._claimed_mine, "rallied_farmer_claims_only_when_its_job_starts")
	farmer.global_position = farmer.destination
	var gold: int = game.get_player(0).gold
	farmer._work_velocity(2.9)
	check(game.get_player(0).gold == gold, "partial_mining_cycle_does_not_pay_early")
	farmer._work_velocity(0.1)
	check(game.get_player(0).gold == gold + 4, "complete_mining_cycle_pays_new_four_gold")
	check(BalanceCatalog.ECONOMY.mining_gold == 4 and BalanceCatalog.ECONOMY.mining_seconds == 3.0, "economy_resource_is_authoritative")
	game._on_income()
	check(game.get_player(0).gold == gold + 5, "natural_income_remains_one_gold_per_second")
	var alias_hq: BattleBuilding = game.spawn_building("headquarters", 0, Vector3(-18, 0, 18))
	freeze_building(alias_hq)
	game.select_entities([hq, alias_hq])
	game.command_gather(mine)
	game.command_bus.tick()
	check(alias_hq.production.rally_mine == mine and hq.production.rally_mine == mine, "group_mine_rally_reaches_each_owned_headquarters")
	game.command_move(Vector3(-15, 0, 15))
	game.command_bus.tick()
	check(alias_hq.production.rally_mine == null and hq.production.rally_mine == null, "ordinary_group_rally_clears_old_mining_target")
