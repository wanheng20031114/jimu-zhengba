extends SceneTree
## Real HUD, keyboard commands and production queues for the one-time economy research.
var game: Node3D
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		printerr("WORKFORCE_HUD_FAIL ", message)

func key(code: Key) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = code
		event.pressed = pressed
		root.push_input(event, true)
	await process_frame
	game.command_bus.tick()
	game.hud.refresh()

func _run() -> void:
	create_timer(30.0, true, false, true).timeout.connect(func(): quit(3))
	root.get_node("Session").start_offline("1v1")
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	game.tests_running = true
	game.bots.clear()
	game.set_process(false)
	game.set_physics_process(false)
	game.get_node("IncomeTimer").stop()
	game.camera_rig.edge_scroll = false
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	var saved_settings: Dictionary = game.settings.snapshot()
	game.settings._apply_values(game.settings.defaults(), false)
	var player: PlayerState = game.get_player(0)
	player.gold = 10000
	for index in 7:
		check(game.headquarters.production.recruit("farmer").ok, "reserve base farmer " + str(index))
	var academy: BattleBuilding = game.spawn_building("academy", 0, Vector3.ZERO)
	academy.set_physics_process(false)
	academy.production.set_physics_process(false)
	game.camera_rig.focus_at(Vector3.ZERO, true)
	game.select_entities([academy])
	var hud: Control = game.hud
	check(hud.farmers_label.text == "农民 10 / 10", "original cap includes real training reservations")
	check(hud._actions.map(func(action): return action.id) == [&"attack_1", &"defense_1", &"workforce_1"], "academy lists economy research after both military tracks")
	check(hud.buttons[2].get_node("Hotkey").text == "E", "workforce research shows its physical hotkey")
	check(hud.buttons[2].get_node("Portrait").texture.resource_path == "res://assets/ui/workforce_upgrade.png", "workforce uses generated dedicated icon")
	check("24 秒" in hud.buttons[2].tooltip_text and "10 → 12" in hud.buttons[2].tooltip_text, "technology tooltip states exact duration and cap")
	var before_gold: int = player.gold
	await key(KEY_E)
	check(academy.production.research_id == "workforce_1" and player.gold == before_gold - 125, "physical E queues and pays for workforce research")
	check(player.get_worker_limit() == 10, "queueing does not grant capacity early")
	check(hud.get_node("%QueueStrip").visible and hud._queue_buttons[0].get_node("Portrait").texture == hud.portraits.workforce_upgrade, "research queue displays its new icon")
	check(not hud._queue_buttons[0].get_node("Level").visible, "one-time economic research has no misleading military tier numeral")
	await key(KEY_ESCAPE)
	check(academy.production.research_queue.is_empty() and player.gold == before_gold, "physical Esc cancels and fully refunds workforce research")
	await key(KEY_E)
	academy.production._physics_process(12.0)
	hud.refresh()
	if "--capture-workforce" in OS.get_cmdline_user_args():
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://artifacts/workforce-research.png")
	academy.production._physics_process(11.99)
	check(player.get_worker_limit() == 10, "capacity stays at ten before the 24 second boundary")
	academy.production._physics_process(0.01)
	hud.refresh()
	check(hud.farmers_label.text == "农民 10 / 12" and "已完成" in hud.farmers_label.tooltip_text, "completed cap reaches the live HUD")
	check(hud._actions.all(func(action): return action.id != &"workforce_1"), "completed one-time research disappears from academy actions")
	game.select_entities([game.headquarters])
	await key(KEY_Q)
	await key(KEY_Q)
	check(hud.farmers_label.text == "农民 12 / 12" and player.reserved_farmers == 9, "two extra physical Q commands reserve exactly twelve total workers")
	before_gold = player.gold
	await key(KEY_Q)
	check(player.gold == before_gold and player.reserved_farmers == 9 and hud.buttons[0].disabled, "thirteenth worker is disabled and cannot cost gold")
	check("农民上限 12 人" in hud.buttons[0].tooltip_text, "blocked training tooltip follows upgraded cap")
	player.defense_level = 3
	var cannon: BattleUnit = game.spawn_unit("cannon", 0, Vector3(7, 0, 0))
	cannon.set_physics_process(false)
	cannon.navigation_agent.avoidance_enabled = false
	game.select_entities([cannon])
	check("近甲 0 / 远甲 10" in hud.selected_stats.text and "攻 86" in hud.selected_stats.text, "cannon HUD applies defense III only to ranged armor")
	game.settings._apply_values(saved_settings, false)
	await game.prepare_shutdown()
	var report := {"checks": checks, "failures": failures, "display": DisplayServer.get_name()}
	FileAccess.open("res://artifacts/workforce-hud-results.json", FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	print("WORKFORCE_HUD_RESULTS ", JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)
