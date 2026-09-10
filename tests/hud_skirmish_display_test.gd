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
	check(NetworkProtocol.MODES[game.match_config.mode].label in hud.get_node("TopLeft/Location").text, "match mode is visible")
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
	_inspect_ownership(own, other)
	if capture_enabled:
		_select(other)
		var motion := InputEventMouseMotion.new()
		motion.position = hud.selection_caption.get_global_rect().get_center()
		motion.global_position = motion.position
		root.push_input(motion, true)
		await process_frame
		check(root.gui_get_hovered_control() == hud.selection_caption, "owner caption receives native hover for full nickname tooltip")
		await create_timer(0.75).timeout
		await _capture(game.match_config.mode + "_enemy_owner")
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

func _inspect_ownership(own: BattleUnit, other: BattleUnit) -> void:
	var hud: Control = game.hud
	var local: PlayerState = game.get_player(own.owner_id)
	var remote: PlayerState = game.get_player(other.owner_id)
	local.display_name = "本地指挥官"
	_select(own)
	check(hud.selection_caption.text == "所属：本地指挥官（玩家）" and hud.selected_role.text == "你的部队", "own unit shows exact player name alongside self relation")
	_select(game.headquarters)
	check(hud.selection_caption.text == "所属：本地指挥官（玩家）" and hud.selected_role.text == "你的建筑", "own headquarters shows player name and building relation")
	# Exercise the public snapshot application used by remote clients, including takeover.
	game.online = true
	game.is_authority = false
	var state: Dictionary = remote.public_state()
	game.replication.game = game
	state.name = "远方玩家小明"
	state.controller = "human"
	game.replication._apply_players([state])
	_select(other)
	check(hud.selection_caption.text == "所属：远方玩家小明（玩家）" and hud.selected_role.text == "敌方部队", "replica enemy unit uses public nickname and enemy relation")
	check(hud._actions.is_empty() and hud.get_node("%AttackButton").disabled, "inspecting remote ownership does not enable commands")
	var enemy_base: BattleBuilding = game.owned_entities(other.owner_id, "buildings").filter(func(building): return building.building_type == "headquarters")[0]
	_select(enemy_base)
	check(hud.selection_caption.text == "所属：远方玩家小明（玩家）" and hud.selected_role.text == "敌方建筑", "replica enemy building uses exact human nickname")
	state.controller = "bot"
	game.replication._apply_players([state])
	hud.refresh()
	check(hud.selection_caption.text == "所属：远方玩家小明（电脑）", "AI takeover updates controller while retaining the owner's name")
	_select(other)
	check(hud.selection_caption.text == "所属：远方玩家小明（电脑）", "computer-owned unit also identifies the particular owner")
	remote.bot_difficulty = "nightmare"
	var enemy_worker: BattleUnit = game.owned_entities(other.owner_id, "units").filter(func(unit): return unit.unit_type == "farmer")[0]
	_select(enemy_worker)
	check(hud.selected_stats.text.begins_with("基础 采矿 +16 / 3.00秒"), "enemy worker inspection includes public difficulty yield without revealing private mining upgrades")
	remote.bot_difficulty = "normal"
	state.name = "这是一位拥有很长中文名字的电脑王国指挥官将领"
	game.replication._apply_players([state])
	hud.refresh()
	check(hud.selection_caption.text.contains(state.name) and hud.selection_caption.tooltip_text == "所属电脑：" + state.name, "long nickname retains full text in native tooltip")
	check(hud.selection_caption.clip_text and hud.selection_caption.text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS, "long owner caption clips with ellipsis without resizing command bar")
	if game.match_config.mode == "2v2":
		var ally_base: BattleBuilding = game.owned_entities(1, "buildings").filter(func(building): return building.building_type == "headquarters")[0]
		var ally_worker: BattleUnit = game.owned_entities(1, "units")[0]
		var ally_state: Dictionary = game.get_player(1).public_state()
		for controller: String in ["human", "bot"]:
			ally_state.name = "盟友张三" if controller == "human" else "盟友电脑赵四"
			ally_state.controller = controller
			game.replication._apply_players([ally_state])
			var caption: String = "所属：%s（%s）" % [ally_state.name, "玩家" if controller == "human" else "电脑"]
			_select(ally_base)
			check(hud.selection_caption.text == caption and hud.selected_role.text == "盟友建筑", "allied building identifies its own human/bot owner independently of team: " + controller)
			_select(ally_worker)
			check(hud.selection_caption.text == caption and hud.selected_role.text == "盟友部队", "allied unit identifies its own human/bot owner independently of team: " + controller)
	game.online = false
	game.is_authority = true
	game.selection.assign([own, game.headquarters])
	hud.refresh()
	check(hud.selection_caption.text == "所属：本地指挥官（玩家）", "mixed own unit and building selection retains ownership")
	_select(get_nodes_in_group("resource_veins")[0])
	check(hud.selection_caption.text == "所选部队" and hud.selection_caption.tooltip_text.is_empty() and hud.selected_role.text == "中立资源 · 金矿", "neutral mine clears previous ownership")
	game.selection.clear()
	hud.refresh()
	check(hud.selection_caption.text == "所选部队" and hud.selection_caption.mouse_filter == Control.MOUSE_FILTER_IGNORE, "empty selection clears ownership and tooltip hit target")

func _inspect_layout(hud: Control, mode: String) -> void:
	check(root.get_visible_rect().encloses(hud.selection_caption.get_global_rect()), mode + " owner caption fits viewport")
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
