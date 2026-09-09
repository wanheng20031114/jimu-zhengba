extends SceneTree
## Actual 2v2 Game, real command dispatch and existing private snapshot fields.
var game: Node3D
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)

func run() -> void:
	root.get_node("Session").start_offline("2v2")
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.bots.clear()
	game.camera_rig.edge_scroll = false
	await create_timer(1.0).timeout
	game.set_physics_process(false)
	for entity: BattleUnit in get_nodes_in_group("units"):
		entity.set_physics_process(false)
		entity.navigation_agent.avoidance_enabled = false
	var headquarters: BattleBuilding = game.headquarters
	var home: Vector3 = headquarters.global_position
	var factory: BattleBuilding = game.spawn_building("factory", 0, home + Vector3(10, 0, 0))
	factory.set_physics_process(false)
	var academy: BattleBuilding = game.spawn_building("academy", 0, home + Vector3(-10, 0, 0))
	academy.set_physics_process(false)
	var mine: ResourceVein = game.nearest_mine(home)
	check(headquarters.production.rally_mine == mine and headquarters.rally_point == mine.global_position, "initial_mining_flag_matches_the_actual_preferred_spawn_direction")
	var ally: BattleBuilding = game.owned_entities(1, "buildings")[0]
	var enemy: BattleBuilding = game.owned_entities(2, "buildings")[0]
	var overlay := game.get_node("OrderPlanOverlay")
	var start_target := home + Vector3(4, 0, -9)
	headquarters.production.rally_mine = null
	headquarters.rally_point = start_target
	factory.rally_point = home + Vector3(12, 0, -12)
	game.select_entities([headquarters, factory])
	overlay.refresh()
	check(overlay.rally_routes().size() == 2 and overlay.flag_count == 2 and overlay.line_count == 2, "two_owned_producers_show_two_flags_and_lines")
	check(overlay.rally_routes()[0].start == headquarters.global_position, "line_begins_at_its_own_building")
	check(overlay.rally_routes()[0].plan[0].at == data(start_target), "flag_uses_building_rally_point")
	check(overlay.get_child_count() == 3, "rally_and_unit_plans_share_three_authored_multimeshes")
	check(overlay.rally_routes()[0].marker_scale > 2.0, "building_flags_larger_than_unit_waypoints")
	var changed := home + Vector3(6, 0, -10)
	game.command_move(changed)
	game.command_bus.tick()
	overlay.refresh()
	check(overlay.rally_routes().all(func(route): return route.plan[0].at == data(changed)), "real_group_rally_command_updates_every_destination")
	check(overlay.flag_count == 1 and overlay.line_count == 2, "shared_destination_has_one_flag_two_building_lines")
	# Reverse selection order ensures mining keeps its gold flag when a
	# military producer shares exactly the same target and would not mine.
	game.select_entities([factory, headquarters])
	game.command_gather(mine)
	game.command_bus.tick()
	overlay.refresh()
	var routes: Array = overlay.rally_routes()
	check(routes[0].plan[0].kind == "rally_gather" and routes[1].plan[0].kind == "rally", "only_farmer_producer_has_mining_rally")
	check(routes.all(func(route): return route.plan[0].at == data(mine.global_position)), "mine_rally_points_to_actual_mine")
	check(overlay.flag_count == 1 and overlay.line_count == 2, "mixed_mining_rally_never_overlaps_two_flags")
	# Opening a match already sets a mine object; the initial rally_point may
	# differ because military movement and worker mining have separate intent.
	headquarters.rally_point = home
	game.select_entities([headquarters])
	overlay.refresh()
	check(overlay.rally_routes()[0].plan[0].at == data(mine.global_position), "default_farmer_mining_rally_overrides_stale_plain_point")
	game.select_entities([ally, enemy, academy])
	overlay.refresh()
	check(overlay.rally_routes().is_empty() and overlay.flag_count == 0 and overlay.line_count == 0, "no_ally_enemy_or_nonproduction_rallies")
	game.select_entities([headquarters, ally, enemy])
	overlay.refresh()
	check(overlay.rally_routes().size() == 1, "mixed_ownership_shows_only_local_player")
	game.select_entities([factory])
	factory.under_construction = true
	factory.construction_progress = 0.4
	overlay.refresh()
	check(overlay.rally_routes().size() == 1, "production_site_keeps_its_future_rally")
	factory.under_construction = false
	factory.construction_progress = 1.0
	# Exercise the same serialization/application used by ordinary clients;
	# no additional network field or client production simulation is needed.
	var replication: MatchReplication = game.replication
	replication.game = game
	var state: Dictionary = replication._entity_state(headquarters, 0)
	check(not replication._entity_state(headquarters, 1).has("rally"), "rally_coordinates_remain_owner_private")
	state = NetworkProtocol.decode(NetworkProtocol.encode(state))
	headquarters.production.rally_mine = null
	headquarters.rally_point = Vector3.ZERO
	game.is_authority = false
	replication._apply_entity(headquarters, state)
	game.select_entities([headquarters])
	overlay.refresh()
	check(headquarters.production.rally_mine == mine and overlay.rally_routes()[0].plan[0].at == data(mine.global_position), "client_renders_existing_private_mine_snapshot")
	state.rally_mine = 0
	state.rally = data(changed)
	replication._apply_entity(headquarters, state)
	overlay.refresh()
	check(overlay.rally_routes()[0].plan[0].kind == "rally" and overlay.rally_routes()[0].plan[0].at == data(changed), "client_applies_changed_plain_rally_without_simulation")
	game.is_authority = true
	var worker: BattleUnit = game.owned_entities(0, "units")[0]
	worker.issue_move(home + Vector3(-3, 0, -6))
	worker.queue_move(home + Vector3(-5, 0, -9))
	game.select_entities([headquarters, worker])
	overlay.refresh()
	check(overlay.flag_count == 3 and overlay.line_count == 3, "building_rally_and_unit_shift_routes_coexist")
	game.select_entities([])
	overlay.refresh()
	check(overlay.flag_count == 0 and overlay.line_count == 0, "deselect_removes_all_rally_geometry")
	game.select_entities([headquarters])
	headquarters.alive = false
	overlay.refresh()
	check(overlay.flag_count == 0, "destroyed_building_cannot_leave_rally_flag")
	headquarters.alive = true
	game.select_entities([factory, headquarters, worker])
	headquarters.production.rally_mine = mine
	factory.production.rally_mine = null
	factory.rally_point = home + Vector3(12, 0, -12)
	overlay.refresh()
	game.camera_rig.focus_at(home + Vector3(4, 0, -5), true)
	game.camera_rig.zoom_target = 32
	game.camera.size = 32
	if DisplayServer.get_name() != "headless":
		var miner: BattleUnit = game.owned_entities(0, "units")[1]
		miner.global_position = mine.global_position + Vector3(0, 0, 3.65)
		miner.reset_physics_interpolation()
		game.get_node("FogOfWar")._recompute()
		game.get_node("FogOfWar").apply_visibility(0)
		check(mine.visible, "capture_miner_provides_real_resource_vision")
		await create_timer(0.4).timeout
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png("res://artifacts/building-rally-overlay.png") == OK, "actual_vulkan_rally_capture_saved")
	print("BUILDING_RALLY_OVERLAY_RESULT ", JSON.stringify({"total": checks, "passed": checks - failures.size(), "failures": failures}))
	await game.prepare_shutdown()
	quit(0 if failures.is_empty() else 1)

func data(at: Vector3) -> Array:
	return [at.x, at.y, at.z]
