extends SceneTree
## Real GUI input, command dispatch and production refund, with optional Vulkan captures.

var game: Node3D
var checks: int = 0
var failures: Array[String] = []
var capture: bool = false

func _initialize() -> void:
	Engine.max_fps = 60
	capture = "--capture-queue" in OS.get_cmdline_user_args()
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func _select(entity: Node3D) -> void:
	game.select_entities([entity])
	game.hud.refresh()

func _click(button: Button) -> void:
	var at := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	root.push_input(motion, true)
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = at
		event.global_position = at
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)
	await process_frame

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
	var hud: Control = game.hud
	var hq: BattleBuilding = game.headquarters
	var player: PlayerState = game.get_player(0)
	player.gold = 1000
	for index in range(4):
		check(hq.production.recruit("farmer").ok, "paid queue item %d created" % index)
	hq.production.training[0].elapsed = 2.6
	_select(hq)
	await process_frame
	await process_frame
	var strip: Control = hud.get_node("%QueueStrip")
	check(strip.visible and hud._queue_actions.size() == 4, "all four queued farmers are directly visible")
	check(hud._actions.size() == 1 and hud._actions[0].kind == "recruit", "recruitment panel no longer duplicates a large cancel action")
	check(not hud.get_node("CommandBar/Recruitment/RecruitTitle").visible and not hud.get_node("%RecruitHint").visible, "queue replaces captions in the same narrow space")
	check(hud._queue_buttons[0].get_node("Status").text == "8s", "active slot shows remaining time")
	check(is_equal_approx(hud._queue_buttons[0].get_node("Progress").value, 0.26), "active slot shows real progress")
	for index in range(4):
		check(hud._queue_buttons[index].visible, "queued slot %d visible" % index)
		check(hud._queue_buttons[index].get_node("Portrait").texture == hud.portraits.farmer, "slot %d reuses the native game-model texture" % index)
		check("返还 50 金币" in hud._queue_buttons[index].tooltip_text, "slot %d explains exact refund" % index)
	check(hud._queue_buttons[2].get_node("Status").text == "3", "waiting slots expose queue order")
	for size: Vector2i in [Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080)]:
		root.size = size
		await process_frame
		await process_frame
		_inspect_layout()
		if capture:
			await _capture("training_%dx%d" % [size.x, size.y])
	var first_id: int = hq.production.training[0].job_id
	var third_id: int = hq.production.training[2].job_id
	var last_id: int = hq.production.training[3].job_id
	var gold_before: int = player.gold
	await _click(hud._queue_buttons[2])
	check(game.command_bus.pending.size() == 1 and game.command_bus.pending[0].job_id == third_id, "native click targets the displayed middle job identity")
	check(game.selection == [hq], "queue above the panel consumes input without selecting terrain")
	game.command_bus.tick()
	hud.refresh()
	check(hq.production.training.size() == 3 and player.gold == gold_before + 50 and player.reserved_farmers == 3, "middle cancellation refunds once and releases one reservation")
	check(hq.production.training[0].job_id == first_id and is_equal_approx(hq.production.training[0].elapsed, 2.6), "middle cancellation preserves current training progress")
	check(hq.production.training[2].job_id == last_id, "last job keeps its identity when shifted left")
	await _click(hud._queue_buttons[0])
	game.command_bus.tick()
	hud.refresh()
	check(hq.production.training.size() == 2 and is_zero_approx(hq.production.training[0].elapsed), "cancelling the current slot promotes the next waiting job")
	hq.production.training[0].elapsed = 10.0
	hud.refresh()
	check(hud._queue_buttons[0].get_node("Status").text == "待出场" and "等待出口空位" in hud._queue_buttons[0].tooltip_text, "completed blocked training remains visible and cancellable")
	while not hq.production.training.is_empty():
		hq.production.cancel_training(0)
	hud.refresh()
	check(not strip.visible and hud.get_node("CommandBar/Recruitment/RecruitTitle").visible and hud.get_node("%RecruitHint").visible, "empty queue restores original production captions")
	var academy: BattleBuilding = game.spawn_building("academy", 0, Vector3(0, 0, 10))
	academy.set_physics_process(false)
	academy.production.set_physics_process(false)
	check(academy.production.research("attack_1").ok, "paid research starts")
	academy.production.research_elapsed = 5.0
	_select(academy)
	await process_frame
	check(strip.visible and hud._queue_actions.size() == 1 and hud._queue_actions[0].upgrade == "attack_1", "research has its own directly cancellable identity")
	check(hud._queue_buttons[0].get_node("Status").text == "15s" and is_equal_approx(hud._queue_buttons[0].get_node("Progress").value, 0.25), "research slot displays actual time and progress")
	check(hud._actions.all(func(action): return action.kind in ["research", "research_page"]), "research and page buttons remain in main panel without a large cancel tile")
	if capture:
		await _capture("research")
	gold_before = player.gold
	await _click(hud._queue_buttons[0])
	game.command_bus.tick()
	hud.refresh()
	check(academy.production.research_id.is_empty() and player.gold == gold_before + 100 and not strip.visible, "research click cancels the current project and returns full cost")
	player.gold = 10000
	for id: String in ["attack_1", "defense_1", "attack_2", "defense_2", "attack_3", "defense_3"]:
		check(academy.production.research(id).ok, "queued technology " + id)
	_select(academy)
	await process_frame
	check(hud._queue_actions.size() == 6 and hud._actions.all(func(action): return action.kind == "research" and not String(action.id).begins_with("attack_") and not String(action.id).begins_with("defense_")), "six paid military technologies remain visible while independent research routes stay available")
	check(hud._queue_buttons[0].get_node("Portrait").texture == hud.portraits.attack_upgrade and hud._queue_buttons[1].get_node("Portrait").texture == hud.portraits.defense_upgrade, "queue uses separate attack and shield icons")
	check(hud._queue_buttons[4].get_node("Level").text == "III", "research queue exposes its technology level")
	var late_id: int = academy.production.research_queue[2].job_id
	gold_before = player.gold
	await _click(hud._queue_buttons[2])
	check(game.command_bus.pending[0].job_id == late_id, "waiting research click carries stable job identity")
	game.command_bus.tick()
	hud.refresh()
	check(academy.production.research_queue.size() == 4 and player.gold == gold_before + 750, "waiting attack II cancels and refunds attack III dependency")
	check(academy.production.research_queue[1].id == "defense_1" and academy.production.research_queue.back().id == "defense_3", "cancellation preserves unrelated queued defense levels")
	if capture:
		await _capture("research_queue")
	var barracks: BattleBuilding = game.spawn_building("barracks", 0, Vector3(-10, 0, 8))
	var barracks2: BattleBuilding = game.spawn_building("barracks", 0, Vector3(10, 0, 8))
	for building: BattleBuilding in [barracks, barracks2]:
		building.set_physics_process(false)
		building.production.set_physics_process(false)
		for index in range(10):
			check(building.production.recruit("swordsman").ok, "multi building paid queue " + str(index))
	game.select_entities([barracks, barracks2])
	hud.refresh()
	await process_frame
	check(hud._queue_page_count == 2 and hud._queue_actions.size() == 10, "twenty military jobs use two pages of ten native slots")
	check(hud._queue_buttons.all(func(button): return button.visible), "all ten queue slots fit on first page")
	check(hud.get_node("%QueueNext").visible and hud.get_node("%QueuePrevious").disabled, "native paging controls expose the remaining queue")
	if capture:
		await _capture("military_multi_queue")
	await _click(hud.get_node("%QueueNext"))
	check(hud._queue_page == 1 and hud._queue_actions[0].target == barracks2.entity_id, "next page displays second selected building jobs")
	gold_before = player.gold
	await _click(hud._queue_buttons[7])
	game.command_bus.tick()
	hud.refresh()
	check(barracks.production.training.size() == 10 and barracks2.production.training.size() == 9 and player.gold == gold_before + 45, "second page cancellation targets correct building and refunds once")
	check(player.reserved_military_supply == 19, "military queue HUD reflects reserved population")
	check("19 / 50" in hud.army_label.text and "训练中 19" in hud.army_label.tooltip_text, "military population includes training reservations against the fifty-supply baseline")
	for size: Vector2i in [Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080)]:
		root.size = size
		await process_frame
		await process_frame
		_inspect_layout()
	await _click(hud.get_node("%QueuePrevious"))
	check(hud._queue_page == 0 and hud._queue_actions[0].target == barracks.entity_id, "previous page restores first building queue")
	check(not hud.buttons[2].disabled, "full representative barracks does not disable knight production in another selected barracks with space")
	gold_before = player.gold
	await _click(hud.buttons[2])
	check(game.command_bus.pending.size() == 1 and game.command_bus.pending[0].buildings == [barracks.entity_id, barracks2.entity_id], "native recruit button submits selected producer identities to authority")
	game.command_bus.tick()
	hud.refresh()
	check(barracks.production.training.size() == 10 and barracks2.production.training.size() == 10, "authority routes native recruit click to available selected producer")
	check(player.gold == gold_before - 80 and player.reserved_military_supply == 20 and barracks2.production.training.back().kind == "knight", "multi producer click purchases exactly one knight and reserves only one population")
	game.select_entities([hq, barracks, academy])
	hud.refresh()
	check(hud._actions.size() == 1 and hud._actions[0].id == "farmer", "mixed building group starts with headquarters production")
	game.cycle_production_group()
	check(game.selected_production() == barracks and hud._actions.size() == 3, "Tab exposes barracks subgroup actions")
	check(hud.selected_portrait.texture == hud.portraits.barracks and "兵营" in hud.selected_role.text, "active building subgroup has a visible model and label")
	game.cycle_production_group()
	check(game.selected_production() == academy and hud._actions.all(func(action): return action.kind in ["research", "research_page"]), "Tab exposes academy subgroup research and its page control")
	hq.production.recruit("farmer")
	_select(hq)
	game.finished = true
	hud.refresh()
	check(hud._queue_buttons[0].disabled, "finished matches disable queue cancellation")
	game.finished = false
	var enemy: BattleBuilding = game.owned_entities(1, "buildings")[0]
	_select(enemy)
	check(not strip.visible and hud._queue_actions.is_empty(), "enemy selection never exposes a private queue")
	_select(game.owned_entities(0, "units")[0])
	check(not strip.visible and hud._actions.all(func(action): return action.kind == "build"), "worker construction commands keep the queue strip hidden")
	print("HUD_PRODUCTION_QUEUE ", checks, " checks; ", failures.size(), " failures")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)

func _inspect_layout() -> void:
	var hud: Control = game.hud
	var strip: Control = hud.get_node("%QueueStrip")
	check(root.get_visible_rect().encloses(strip.get_global_rect()), "queue strip fits viewport")
	check(strip.get_global_rect().end.y <= hud.get_node("CommandBar").get_global_rect().position.y, "queue stays wholly above command panel")
	for button: Button in hud._queue_buttons:
		if not button.visible:
			continue
		check(strip.get_global_rect().encloses(button.get_global_rect()), "queue tile stays within reserved strip")
		for index in range(1, 10):
			check(not button.get_global_rect().intersects(hud.get_node("Groups/Group%d" % index).get_global_rect()), "queue tile does not overlap control-group buttons")

func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png("res://artifacts/production_queue_%s.png" % label) == OK, "saved Vulkan capture " + label)
