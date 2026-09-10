extends SceneTree
## Native HUD display contracts. Optional --capture-hud writes multi-size Vulkan images.
var game: Node3D
var checks: int = 0
var failures: Array[String] = []
var capture_enabled: bool = false

func _initialize() -> void:
	capture_enabled = "--capture-hud" in OS.get_cmdline_user_args()
	_run.call_deferred()

func check(value: bool, description: String) -> void:
	checks += 1
	if not value:
		failures.append(description)
		printerr("FAIL ", description)

func _select(entity: Node3D) -> void:
	game.selection.assign([entity])
	game.hud.refresh()

func _run() -> void:
	create_timer(45.0, true, false, true).timeout.connect(func(): quit(3))
	get_root().get_node("Session").start_offline("2v2" if "--2v2" in OS.get_cmdline_user_args() else "1v1")
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.bots.clear()
	game.set_physics_process(false)
	game.set_process(false)
	game.camera_rig.edge_scroll = false
	game.get_node("IncomeTimer").stop()
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	await process_frame
	await process_frame
	var hud: Control = game.hud
	var player: PlayerState = game.get_player(0)
	player.gold = 999999
	var army_limit: int = player.get_supply_limit()
	player.military_supply = army_limit - 3
	player.reserved_military_supply = 3
	player.farmers = 3
	player.reserved_farmers = 7
	hud.refresh()
	check(hud.get_node("%ArmyValue").text == "军事 %d / %d" % [army_limit, army_limit], "military supply label includes three reserved trainees at the current cap")
	check("训练中 3 人口" in hud.get_node("%ArmyValue").tooltip_text, "military tooltip identifies queued supply reservations")
	check(hud.get_node("%FarmersValue").text == "农民 10 / 10", "farmer supply includes seven pending trainees")
	check("训练中 7 人" in hud.get_node("%FarmersValue").tooltip_text, "farmer tooltip explains training reservations")
	check(game.map_definition.display_name in hud.get_node("TopLeft/Location").text, "top-left title uses active map resource")
	check(("2v2 队伍战" if game.match_config.mode == "2v2" else "1v1 遭遇战") in hud.get_node("TopLeft/Location").text, "match mode is visible")
	check(hud.get_node("MapFrame/MapTitle").text == game.map_definition.display_name, "minimap uses active map name")
	var own: BattleUnit = game.spawn_unit("swordsman", 0, Vector3.ZERO)
	var other: BattleUnit = game.spawn_unit("swordsman", game.players.size() - 1, Vector3(2, 0, 0))
	for unit: BattleUnit in [own, other]:
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	player.attack_level = 3
	player.defense_level = 2
	game.get_player(other.owner_id).attack_level = 3
	game.get_player(other.owner_id).defense_level = 3
	var definition := BalanceCatalog.unit("swordsman")
	_select(own)
	check(hud.selected_stats.text.begins_with("攻 %d" % (definition.damage + 4)) and "近甲 %d" % (definition.melee_armor + 2) in hud.selected_stats.text, "own military shows actual upgrade bonuses")
	_select(other)
	check(hud.selected_stats.text.begins_with("基础 攻 %d" % definition.damage) and "近甲 %d" % definition.melee_armor in hud.selected_stats.text, "other player's unknown private upgrades are explicitly base statistics")
	var worker: BattleUnit = game.owned_entities(0, "units").filter(func(unit): return unit.unit_type == "farmer")[0]
	game.online = true
	game.is_authority = false
	worker.set_meta("replica_queue_count", 4)
	_select(worker)
	check("队列 4" in hud.selected_stats.text and "攻 " not in hud.selected_stats.text, "replica farmer reads queue metadata and does not claim military upgrades")
	hud.show_pause(true)
	check(hud.get_node("PauseOverlay/Paper/Title").text == "战场菜单" and "不会暂停" in hud.get_node("PauseOverlay/Paper/Eyebrow").text, "online menu clearly states that opening it does not pause battle")
	check(hud.get_node("%RestartButton").text == "返回大厅", "online menu offers return to lobby")
	hud.show_pause(false)
	game.online = false
	game.is_authority = true
	game.local_owner_id = other.owner_id
	hud.refresh()
	check(hud.get_node("ModelPreviews")._models.swordsman._team == game.get_player(other.owner_id).alliance_id, "portrait material uses local owner's alliance")
	game.local_owner_id = 0
	var tower: BattleBuilding = game.spawn_building("defense_tower", 0, Vector3(0, 0, 10))
	_select(tower)
	check(hud._actions.size() == 1 and hud._actions[0].kind == "demolish" and hud.buttons[0].get_node("Cost").text == "无退款", "completed tower keeps a clear demolition action")
	var site: BattleBuilding = game.spawn_building("defense_tower", 0, Vector3(10, 0, 0), true)
	_select(site)
	check(hud._actions.size() == 1 and hud._actions[0].kind == "cancel_site" and not hud.buttons[0].disabled, "unfinished tower keeps usable cancellation action")
	_select(worker)
	check(hud._actions.size() == 5 and hud._actions.all(func(action): return action.kind == "build"), "native model building action panel remains intact")
	game.selection.assign([game.headquarters])
	player.military_supply = 60
	for size: Vector2i in [Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080)]:
		root.size = size
		hud.refresh()
		await process_frame
		await process_frame
		_inspect_layout(hud, str(size))
		if capture_enabled:
			await _capture("%s_%dx%d" % [game.match_config.mode, size.x, size.y])
	hud.get_node("%HelpOverlay").show()
	await process_frame
	_inspect_help(hud)
	if capture_enabled:
		await _capture(game.match_config.mode + "_help")
	hud.get_node("%HelpOverlay").hide()
	var report := {"checks": checks, "failures": failures, "mode": game.match_config.mode, "captured": capture_enabled}
	FileAccess.open("res://artifacts/hud_skirmish_%s_results.json" % game.match_config.mode, FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	print("HUD_SKIRMISH_RESULT ", checks, " checks; ", failures.size(), " failures")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)

func _inspect_layout(hud: Control, mode: String) -> void:
	var panel: Control = hud.get_node("Resources")
	check(is_equal_approx(panel.size.x, 350.0), mode + " resources retain 350px total width")
	check(root.get_visible_rect().encloses(panel.get_global_rect()), mode + " resources fit viewport")
	var controls: Array[Control] = []
	for child: Control in panel.get_children():
		check(panel.get_global_rect().encloses(child.get_global_rect()), mode + " resource text inside panel: " + str(child.name))
		for other: Control in controls:
			check(not child.get_global_rect().intersects(other.get_global_rect()), mode + " resource text does not overlap: " + str(child.name) + "/" + str(other.name))
		controls.append(child)
		if child is Label:
			var font: Font = child.get_theme_font("font")
			check(font.get_string_size(child.text, HORIZONTAL_ALIGNMENT_LEFT, -1, child.get_theme_font_size("font_size")).x <= child.size.x, mode + " complete resource text fits authored width: " + str(child.name))

func _inspect_help(hud: Control) -> void:
	var paper: Control = hud.get_node("HelpOverlay/Paper")
	check(root.get_visible_rect().encloses(paper.get_global_rect()), "help panel fits viewport")
	var controls: Array[Control] = []
	for child: Control in paper.get_children():
		check(paper.get_global_rect().encloses(child.get_global_rect()), "help child within panel: " + str(child.name))
		for other: Control in controls:
			check(not child.get_global_rect().intersects(other.get_global_rect()), "help labels do not overlap: " + str(child.name) + "/" + str(other.name))
		controls.append(child)
	check("联机仅房主" in paper.get_node("Actions").text and "单机金币" in paper.get_node("Actions").text, "help distinguishes host-controlled online pause and offline-only gold cheat")
	check("研究" in paper.get_node("Economy").text and "Shift" in paper.get_node("Keys").text and "窗口边缘" in paper.get_node("Keys").text, "help covers production research groups and window edge scrolling")
	check("125金/24秒扩农民10→12" in paper.get_node("Economy").text and "攻城近甲固定0" in paper.get_node("Economy").text, "help explains the new economy upgrade and siege armor rule")

func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png("res://artifacts/hud_skirmish_%s.png" % label) == OK, "Vulkan screenshot saved: " + label)
