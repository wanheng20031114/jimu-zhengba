extends SceneTree
## Actual Game integration: native cursor contexts, bounded plans and rendering.
var game: Node3D
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	run.call_deferred()

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)

func run() -> void:
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.bots.clear()
	game.camera_rig.edge_scroll = false
	await create_timer(1.5).timeout
	game.set_physics_process(false)
	for entity: Node in get_nodes_in_group("units"):
		entity.set_physics_process(false)
		entity.navigation_agent.avoidance_enabled = false
	var workers := get_nodes_in_group("units").filter(func(unit: BattleUnit): return unit.owner_id == game.local_owner_id)
	var worker: BattleUnit = workers[0]
	var mine: ResourceVein = worker.work_target
	var cursor := game.get_node("ContextCursor")
	var overlay := game.get_node("OrderPlanOverlay")
	for kind: String in cursor.TEXTURES:
		cursor.set_cursor(kind)
		check(cursor.cursor_kind == kind, "native_cursor_installed_" + kind)
	game.settings.open_menu()
	cursor._process(0.1)
	check(cursor.cursor_kind == "normal", "settings_overlay_restores_normal_cursor")
	game.settings.close_menu()
	paused = true
	cursor.set_cursor("attack")
	cursor._process(0.1)
	check(cursor.cursor_kind == "normal", "paused_world_restores_normal_cursor")
	paused = false
	var home: Vector3 = game.headquarters.global_position
	game.select_entities([worker])
	check(cursor.context_kind(mine, mine.global_position) == "gather", "worker_mine_gather_cursor")
	check(cursor.context_kind(null, home) == "move", "worker_ground_move_cursor")
	game.select_entities([game.headquarters])
	check(cursor.context_kind(mine, mine.global_position) == "rally_gather", "headquarters_mine_rally_gather_cursor")
	check(cursor.context_kind(null, home) == "rally", "producer_ground_rally_cursor")
	var factory: BattleBuilding = game.spawn_building("factory", game.local_owner_id, home + Vector3(-10, 0, -8))
	factory.set_physics_process(false)
	factory.production.set_physics_process(false)
	game.select_entities([factory])
	check(cursor.context_kind(mine, mine.global_position) == "rally", "factory_mine_cursor_does_not_promise_mining")
	game.select_entities([worker, factory])
	check(cursor.context_kind(mine, mine.global_position) == "gather", "mixed_worker_factory_mine_prioritizes_worker_gather")
	check(cursor.context_kind(null, home) == "move", "mixed_unit_building_ground_prioritizes_unit_move")
	game.command_gather(mine)
	game.command_bus.tick()
	check(worker.order == BattleUnit.Order.GATHER and worker.work_target == mine and factory.production.rally_mine == mine, "mixed_gather_dispatches_worker_and_building_rally")
	var mixed_destination := home + Vector3(3, 0, -7)
	game.command_move(mixed_destination)
	game.command_bus.tick()
	check(worker.order == BattleUnit.Order.MOVE and factory.rally_point.distance_to(mixed_destination) < 0.01 and factory.production.rally_mine == null, "mixed_move_dispatches_unit_and_plain_rally")
	game.select_entities([worker])
	check(cursor.context_kind(game.headquarters, home) == "move", "unit_over_finished_friendly_building_is_move")
	game.select_entities([worker, game.headquarters])
	check(cursor.context_kind(mine, mine.global_position) == "gather", "worker_and_headquarters_prioritize_immediate_gather")
	game.select_entities([factory, game.headquarters])
	check(cursor.context_kind(mine, mine.global_position) == "rally_gather", "mixed_producers_include_farmer_gather_rally")
	factory.under_construction = true
	factory.construction_progress = 0.5
	game.select_entities([factory])
	check(cursor.context_kind(mine, mine.global_position) == "rally", "unfinished_production_building_can_set_future_rally")
	factory.queue_free()
	await process_frame
	game.select_entities([])
	check(cursor.context_kind(mine, mine.global_position) == "normal", "empty_selection_normal_cursor")
	var enemy: BattleUnit = game.spawn_unit("swordsman", 1, worker.global_position + Vector3(3, 0, 0))
	enemy.set_physics_process(false)
	enemy.navigation_agent.avoidance_enabled = false
	game.get_node("FogOfWar")._recompute()
	game.select_entities([worker])
	check(cursor.context_kind(enemy, enemy.global_position) == "attack", "visible_enemy_attack_cursor")
	game.select_entities([worker, game.headquarters])
	check(cursor.context_kind(enemy, enemy.global_position) == "attack", "mixed_unit_building_enemy_prioritizes_attack")
	game.select_entities([worker])
	enemy.global_position = -home
	game.get_node("FogOfWar")._recompute()
	check(cursor.context_kind(enemy, enemy.global_position) == "move", "hidden_enemy_cannot_change_cursor")
	var site: BattleBuilding = game.spawn_building("defense_tower", game.local_owner_id, home + Vector3(9, 0, -7), true)
	site.set_physics_process(false)
	check(cursor.context_kind(site, site.global_position) == "build", "worker_construction_cursor")
	game.select_entities([game.headquarters])
	check(cursor.context_kind(site, site.global_position) == "forbidden", "producer_cannot_complete_construction_cursor")
	game.select_entities([worker])
	worker.stop()
	worker.issue_move(home + Vector3(4, 0, -8))
	worker.queue_move(home + Vector3(10, 0, -9))
	worker.queue_move(home + Vector3(12, 0, -3), true)
	worker.issue_gather(mine, true)
	worker.issue_build(site, true)
	worker.hold(true)
	overlay.refresh()
	check(overlay.flag_count >= 5 and overlay.line_count >= 4, "move_attack_mine_build_hold_flags_and_lines")
	check(overlay.get_child_count() == 3, "three_saved_multimesh_nodes_only")
	var previous_count: int = overlay.flag_count
	var previous_buffer: PackedFloat32Array = overlay.flags.buffer
	overlay.refresh()
	check(overlay.flag_count == previous_count and overlay.flags.buffer == previous_buffer, "unchanged_plan_reuses_native_buffer")
	for index in 60:
		worker.queue_move(home + Vector3(4 + index % 10, 0, -8 - index % 8))
	check(UnitOrderPlan.build(worker, game).size() <= UnitOrderPlan.MAX_ENTRIES, "sixty_four_orders_have_bounded_display")
	overlay.refresh()
	check(overlay.flag_count <= 128 and overlay.line_count <= 192, "native_instances_stay_bounded")
	game.select_entities([])
	overlay.refresh()
	check(overlay.flag_count == 0 and overlay.line_count == 0, "deselect_clears_all_flags")
	game.select_entities([worker])
	worker.stop()
	overlay.refresh()
	check(overlay.flag_count == 0, "stop_clears_old_plan")
	game.is_authority = false
	worker.set_meta("replica_order_plan", [{"kind": "move", "at": [home.x + 7, 0, home.z - 5]}, {"kind": "unknown"}, {"kind": "build", "at": [home.x + 12, 0, home.z - 9]}])
	overlay.refresh()
	check(overlay.flag_count == 2 and overlay.line_count == 1, "client_metadata_only_and_no_line_through_hidden_target")
	check(worker.waypoint_queue.is_empty(), "client_display_never_invents_executable_jobs")
	game.is_authority = true
	worker.issue_move(home + Vector3(4, 0, -8))
	worker.queue_move(home + Vector3(10, 0, -9))
	worker.queue_move(home + Vector3(12, 0, -3), true)
	worker.issue_gather(mine, true)
	worker.issue_build(site, true)
	overlay.refresh()
	game.camera_rig.focus_at(home + Vector3(4, 0, -3), true)
	game.camera_rig.zoom_target = 24
	game.camera.size = 24
	if DisplayServer.get_name() != "headless":
		var palette := preload("res://tests/cursor_palette.tscn").instantiate()
		game.get_node("HUD").add_child(palette)
		await create_timer(0.4).timeout
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png("res://artifacts/world-order-feedback.png") == OK, "actual_world_capture_saved")
		palette.queue_free()
		game.select_entities([game.headquarters])
		game.camera_rig.focus_at(home + Vector3(0, 0, -1), true)
		game.camera_rig.zoom_target = 16
		game.camera.size = 16
		await create_timer(0.4).timeout
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png("res://artifacts/headquarters-raised-towers.png") == OK, "headquarters_eaves_capture_saved")
	print("WORLD_ORDER_FEEDBACK_RESULTS ", JSON.stringify({"total": checks, "passed": checks - failures.size(), "failures": failures}))
	await game.prepare_shutdown()
	quit(0 if failures.is_empty() else 1)
