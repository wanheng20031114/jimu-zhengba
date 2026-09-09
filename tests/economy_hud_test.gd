extends SceneTree
## Exercise the authored academy panel, visible queue and dynamic local economy.
var game: Node3D
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	Engine.max_fps = 60
	if DisplayServer.get_name() != "headless":
		root.set_flag(Window.FLAG_NO_FOCUS, true)
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func _run() -> void:
	create_timer(45.0, true, false, true).timeout.connect(func(): quit(3))
	root.get_node("Session").start_offline("1v1")
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
	var player: PlayerState = game.get_player(0)
	player.gold = 10000
	var near: Vector3 = game.owned_entities(0, "buildings")[0].position
	var barracks_at: Vector3 = game.find_build_location(0, "barracks", near)
	check(barracks_at.is_finite(), "native barracks has legal footprint")
	if not barracks_at.is_finite():
		quit(1)
		return
	game.spawn_building("barracks", 0, barracks_at)
	var at: Vector3 = game.find_build_location(0, "academy", near)
	check(at.is_finite(), "native academy has legal footprint")
	if not at.is_finite():
		quit(1)
		return
	var academy: BattleBuilding = game.spawn_building("academy", 0, at)
	academy.set_physics_process(false)
	academy.production.set_physics_process(false)
	game.select_entities([academy])
	game.hud.refresh()
	var hud: Control = game.hud
	check(hud._actions.size() == 5, "five independent academy tracks are visible")
	for index in range(5):
		var button: Button = hud.buttons[index]
		check(button.visible and not button.disabled and not button.get_node("Hotkey").text.is_empty(), "academy action %d is accessible and has a hotkey" % index)
		check(button.get_node("Portrait").texture != null, "academy action %d has an actual portrait" % index)
	check(hud._actions[3].id == &"army_capacity_1" and hud.buttons[3].tooltip_text.contains("75"), "expansion action shows actual next cap")
	check(hud._actions[4].id == &"mining_1" and hud.buttons[4].tooltip_text.contains("10%"), "mining action shows cumulative percentage")
	check(hud.army_label.text.ends_with("/ 50"), "baseline military HUD is fifty")
	check(academy.production.research("army_capacity_1").ok and academy.production.research("mining_1").ok, "both new tracks enter native academy queue")
	academy.production.research_elapsed = 12.0
	hud.refresh()
	check(hud._queue_actions.size() == 2 and hud._queue_buttons[0].visible and hud._queue_buttons[1].visible, "both research jobs are visible as queue cells")
	check(hud._queue_buttons[0].get_node("Level").text == "I" and is_equal_approx(hud._queue_buttons[0].get_node("Progress").value, 0.4), "queue displays level and real research progress")
	var gold_before: int = player.gold
	hud._queue_buttons[1].pressed.emit()
	game.command_bus.tick()
	check(academy.production.research_queue.size() == 1 and player.gold == gold_before + 50, "clicking a visible mining queue cell cancels exactly that job and refunds")
	check(academy.production.research("mining_1").ok, "cancelled mining research may be requeued")
	hud.refresh()
	if "--capture-economy" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless":
		game.camera_rig.focus_at(academy.global_position, true)
		game.get_node("FogOfWar")._recompute()
		game.get_node("FogOfWar").apply_visibility(0)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png("res://report/economy-academy-0.8.2.png") == OK, "actual academy and research queue screenshot saved")
	player.complete_upgrade(BalanceCatalog.upgrade("army_capacity_1"))
	hud.refresh()
	check(hud.army_label.text.ends_with("/ 75"), "completed expansion updates HUD immediately")
	player.complete_upgrade(BalanceCatalog.upgrade("army_capacity_2"))
	player.complete_upgrade(BalanceCatalog.upgrade("mining_3"))
	hud.refresh()
	check(hud.army_label.text.ends_with("/ 100"), "second expansion updates HUD to one hundred")
	var worker: BattleUnit = game.owned_entities(0, "units")[0]
	game.select_entities([worker])
	hud.refresh()
	check(hud.selected_stats.text.contains("2.31"), "selected farmer shows upgraded personal mining cycle")
	print("ECONOMY_HUD_RESULTS " + JSON.stringify({"build": NetworkProtocol.BUILD_ID, "checks": checks, "failures": failures}))
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	game = null
	await process_frame
	quit.call_deferred(0 if failures.is_empty() else 1)
