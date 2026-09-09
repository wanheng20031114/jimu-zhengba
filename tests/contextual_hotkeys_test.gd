extends SceneTree
## Native keyboard input follows the selected panel, including rebinding and destructive exclusions.

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

func _select(entities: Array) -> void:
	game.select_entities(entities)
	game.hud.refresh()

func _key(value: Key) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = value
		event.pressed = pressed
		root.push_input(event, true)
	await process_frame
	game.command_bus.tick()
	game.hud.refresh()

func _building(kind: String, at: Vector3, construction: bool = false) -> BattleBuilding:
	var building: BattleBuilding = game.spawn_building(kind, 0, at, construction)
	building.set_physics_process(false)
	building.production.set_physics_process(false)
	return building

func _run() -> void:
	create_timer(35.0, true, false, true).timeout.connect(func(): quit(3))
	root.get_node("Session").start_offline("1v1")
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	game.tests_running = true
	game.bots.clear()
	game.set_physics_process(false)
	game.set_process(false)
	game.get_node("IncomeTimer").stop()
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	var settings: GameSettings = game.settings
	var original: Dictionary = settings.snapshot()
	# Apply in memory only. The player's settings.cfg is never written by this test.
	settings._apply_values(settings.defaults(), false)
	var player: PlayerState = game.get_player(0)
	player.gold = 10000
	var hud: Control = game.hud
	var hq: BattleBuilding = game.headquarters
	_select([hq])
	check(hud.buttons[0].get_node("Hotkey").text == "Q", "HQ farmer shows Q in its corner")
	await _key(KEY_Q)
	check(hq.production.training.size() == 1 and hq.production.training[0].kind == "farmer", "physical Q trains one farmer at selected HQ")
	var barracks := _building("barracks", Vector3(-12, 0, 5))
	var factory := _building("factory", Vector3(12, 0, 5))
	var academy := _building("academy", Vector3(0, 0, 14))
	_select([barracks])
	for index in range(3):
		check(hud.buttons[index].get_node("Hotkey").text == ["Q", "W", "E"][index], "barracks slot %d has its current key" % index)
	for key: Key in [KEY_Q, KEY_W, KEY_E]:
		await _key(key)
	check(barracks.production.training.map(func(job): return job.kind) == ["swordsman", "archer", "knight"], "physical QWE creates the three barracks jobs in order")
	_select([factory])
	await _key(KEY_Q)
	await _key(KEY_W)
	check(factory.production.training.map(func(job): return job.kind) == ["catapult", "cannon"], "factory restarts at QW for both siege engines")
	check(hud.buttons[0].get_node("Hotkey").text == "Q" and hud.buttons[1].get_node("Hotkey").text == "W", "factory labels agree with dispatched input")
	_select([hq, barracks, factory])
	await _key(KEY_TAB)
	check(game.selected_production() == barracks, "real Tab input changes the building category")
	await _key(KEY_Q)
	check(barracks.production.training.size() == 4 and hq.production.training.size() == 1, "mixed building Q uses the Tab-selected barracks category")
	await _key(KEY_TAB)
	await _key(KEY_W)
	check(factory.production.training.size() == 3 and factory.production.training.back().kind == "cannon", "next mixed building category uses its own W slot")
	_select([academy])
	await _key(KEY_Q)
	await _key(KEY_W)
	check(academy.production.research_queue.map(func(job): return job.id) == ["attack_1", "defense_1"], "QW starts the displayed attack and defense research")
	check(hud.buttons[0].get_node("Hotkey").text == "Q" and hud.buttons[1].get_node("Hotkey").text == "W", "upgrade buttons display current hotkeys beside generated icons")
	await _key(KEY_Q)
	await _key(KEY_Q)
	check(hud._actions.size() == 1 and hud._actions[0].id == "defense_2", "fully reserved attack route leaves defense as the first visible action")
	await _key(KEY_Q)
	check(academy.production.research_queue.back().id == "defense_2", "Q follows the first visible research after its neighbor disappears")
	var worker: BattleUnit = game.owned_entities(0, "units")[0]
	_select([worker])
	for index in range(5):
		check(hud.buttons[index].get_node("Hotkey").text == ["Q", "W", "E", "R", "T"][index], "worker building slot %d displays its key" % index)
	await _key(KEY_Q)
	check(game.build_mode and game.build_kind == "barracks", "worker Q starts placement of first displayed building")
	game.set_build_mode(false)
	await _key(KEY_V)
	check(game.build_mode and game.build_kind == "defense_tower", "V remains the quick tower placement shortcut")
	game.set_build_mode(false)
	var tower := _building("defense_tower", Vector3(22, 0, 3))
	_select([tower])
	check(hud.buttons[0].get_node("Hotkey").text.is_empty(), "destructive tower action has no production slot key")
	await _key(KEY_Q)
	check(tower.alive and game.command_bus.pending.is_empty(), "Q cannot demolish a selected tower")
	var site := _building("barracks", Vector3(-22, 0, 3), true)
	_select([site])
	await _key(KEY_Q)
	check(site.alive and hud.buttons[0].get_node("Hotkey").text.is_empty(), "Q cannot cancel a construction site")
	_select([barracks])
	var remap: Dictionary = settings.defaults()
	remap.bindings.rts_slot_1 = [KEY_Z]
	remap.bindings.rts_group1 = [KEY_F6]
	remap.bindings.rts_attack_move = [KEY_F7]
	settings._apply_values(remap, false)
	check(hud.buttons[0].get_node("Hotkey").text == "Z" and "快捷键：Z" in hud.buttons[0].tooltip_text, "settings signal immediately refreshes slot corner and tooltip")
	check("F7" in hud.get_node("%AttackButton").text and "F6" in hud.get_node("Groups/Group1").text, "command and control-group hints follow bindings")
	check("Z / W / E" in hud.get_node("HelpOverlay/Paper/Keys").text and "F7" in hud.get_node("HelpOverlay/Paper/Keys").text, "manual shows remapped production and command keys")
	var count: int = barracks.production.training.size()
	await _key(KEY_Q)
	check(barracks.production.training.size() == count, "old physical Q stops recruiting after rebind")
	await _key(KEY_Z)
	check(barracks.production.training.size() == count + 1, "new physical Z dispatches the selected first-slot action")
	_select([game.owned_entities(1, "buildings")[0]])
	await _key(KEY_Z)
	check(hud._actions.is_empty() and game.command_bus.pending.is_empty(), "enemy building selection cannot purchase through remapped hotkeys")
	settings._apply_values(original, false)
	check(GameSettings.ACTIONS.size() == 34, "context slots retain 34 rebindable actions")
	var hotkey_rows: Node = settings.menu.get_node("%HotkeyRows")
	check(hotkey_rows.get_child_count() == 34, "native settings scene has exactly one row for every action")
	for index in range(1, 7):
		check(hotkey_rows.get_node("rts_slot_%d" % index).get_meta("action") == "rts_slot_%d" % index, "native slot binding row %d owns the matching action" % index)
	if "--capture-hotkeys" in OS.get_cmdline_user_args():
		settings._apply_values(settings.defaults(), false)
		root.size = Vector2i(1600, 900)
		_select([barracks])
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png("res://artifacts/contextual_hotkeys_barracks.png") == OK, "Vulkan panel screenshot saved")
		hud.toggle_help()
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png("res://artifacts/contextual_hotkeys_help.png") == OK, "Vulkan dynamic manual screenshot saved")
		settings._apply_values(original, false)
	print("CONTEXTUAL_HOTKEYS ", checks, " checks; ", failures.size(), " failures")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)
