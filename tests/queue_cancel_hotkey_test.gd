extends SceneTree
## Native cancel input resolves queue tails at the authority tick, with atomic ownership checks.

var game: Node3D
var settings: GameSettings
var original_preferences: Dictionary
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func _key(value: Key) -> void:
	# Deliberately no tick/yield here: repeated presses can share one host tick.
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = value
		event.pressed = pressed
		root.push_input(event, true)

func _tick() -> void:
	game.command_bus.tick()
	game.hud.refresh()

func _select(entities: Array) -> void:
	game.select_entities(entities)
	game.hud.refresh()

func _building(kind: String, owner: int, at: Vector3) -> BattleBuilding:
	var building: BattleBuilding = game.spawn_building(kind, owner, at)
	building.set_physics_process(false)
	building.production.set_physics_process(false)
	return building

func _clear_training(buildings: Array) -> void:
	for building: BattleBuilding in buildings:
		while not building.production.training.is_empty():
			building.production.cancel_training(0)

func _economy(buildings: Array) -> String:
	var queues: Array = []
	for building: BattleBuilding in buildings:
		queues.append(building.production.snapshot())
	return JSON.stringify({"own": game.get_player(0).private_state(), "ally": game.get_player(1).private_state(), "queues": queues})

func _run() -> void:
	create_timer(30.0, true, false, true).timeout.connect(_timeout)
	settings = root.get_node("Session/Settings")
	original_preferences = settings.snapshot()
	# No persistence or display call: preserve the player's settings.cfg and desktop.
	settings._apply_values(settings.defaults(), false)
	root.get_node("Session").start_offline("2v2")
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	game.tests_running = true
	game.bots.clear()
	game.set_process(false)
	game.set_physics_process(false)
	game.camera_rig.set_process(false)
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	var player: PlayerState = game.get_player(0)
	player.gold = 10000
	var hq: BattleBuilding = game.headquarters
	for _index in range(3):
		hq.production.recruit("farmer")
	hq.production.training[0].elapsed = 4.0
	var head_id: int = hq.production.training[0].job_id
	check(hq.production.training.size() == 3 and player.reserved_farmers == 3 and player.gold == 9850, "three real paid farmer jobs reserve money and worker slots")
	_select([hq])
	_key(KEY_ESCAPE)
	_key(KEY_ESCAPE)
	check(game.command_bus.pending.size() == 2 and game.command_bus.pending.all(func(command): return command.kind == "cancel_queue"), "two physical Esc presses enqueue two authority cancellations before one tick")
	_tick()
	check(hq.production.training.size() == 1 and hq.production.training[0].job_id == head_id and hq.production.training[0].elapsed == 4.0, "same-tick cancels remove two different tails and preserve active progress")
	check(player.gold == 9950 and player.reserved_farmers == 1, "two same-tick cancels refund exactly one hundred and release two reservations")
	_key(KEY_ESCAPE)
	_tick()
	check(hq.production.training.is_empty() and player.gold == 10000 and player.reserved_farmers == 0 and player.farmers == 3, "single remaining active job can be cancelled with a full refund")
	_key(KEY_ESCAPE)
	_tick()
	check(not paused and not game._local_menu and not game.hud.get_node("%PauseOverlay").visible and player.gold == 10000, "empty-queue Esc is harmless and never opens pause/menu")
	_select([])
	_key(KEY_ESCAPE)
	check(game.command_bus.pending.is_empty() and not paused, "Esc without a selected producer does nothing")

	var first := _building("barracks", 0, Vector3(-12, 0, 4))
	var second := _building("barracks", 0, Vector3(12, 0, 4))
	var academy := _building("academy", 0, Vector3(0, 0, 16))
	for _index in range(2):
		first.production.recruit("knight")
	for _index in range(3):
		second.production.recruit("swordsman")
	# The new eight-second knight cycle still gives the shorter queue more
	# remaining time: two knights take sixteen seconds, these swordsmen fifteen.
	second.production.training[0].elapsed = 3.0
	var first_seconds: float = 0.0
	var second_seconds: float = 0.0
	for job: Dictionary in first.production.training:
		first_seconds += BalanceCatalog.unit(job.kind).training_seconds - float(job.elapsed)
	for job: Dictionary in second.production.training:
		second_seconds += BalanceCatalog.unit(job.kind).training_seconds - float(job.elapsed)
	check(first_seconds > second_seconds, "shorter item-count queue deliberately has more remaining training time")
	check(first.entity_id < second.entity_id and player.reserved_military_supply == 5, "two knights and three swordsmen reserve five military population")
	_select([second, first])
	_key(KEY_ESCAPE)
	check(game.command_bus.pending.size() == 1 and game.command_bus.pending[0].buildings == [second.entity_id, first.entity_id], "physical cancel carries selected producer IDs to the authority")
	var before_gold: int = player.gold
	_tick()
	check(first.production.training.size() == 2 and second.production.training.size() == 2, "longest item count wins even when a shorter queue takes more seconds")
	check(player.gold == before_gold + 45 and player.reserved_military_supply == 4, "longest-queue tail refund releases its exact military supply")
	before_gold = player.gold
	_key(KEY_ESCAPE)
	_tick()
	check(first.production.training.size() == 1 and second.production.training.size() == 2, "equal queue lengths choose the lower entity ID despite reversed selection order")
	check(player.gold == before_gold + 80 and player.reserved_military_supply == 3, "tie-selected knight refunds eighty and releases one population")
	_clear_training([first, second])

	academy.production.research("attack_1")
	academy.production.research("attack_2")
	academy.production.research_queue[0].elapsed = 6.0
	check(academy.production.research_queue.size() == 2, "two real prerequisite-linked technologies queued")
	_select([academy])
	before_gold = player.gold
	_key(KEY_ESCAPE)
	_tick()
	check(academy.production.research_queue.size() == 1 and academy.production.research_queue[0].id == "attack_1" and academy.production.research_elapsed == 6.0, "research tail cancellation retains the prerequisite and its progress")
	check(player.gold == before_gold + 250 and player.planned_upgrade_level(&"attack") == 1, "research tail refunds only the second level and releases that reservation")
	check(player.attack_level == 0 and player.queued_research.has("attack_1"), "cancelled tail never grants research completion or cancels active first level")
	first.production.recruit("swordsman")
	_select([first, academy])
	check(game.selected_production() == first, "mixed group initially exposes the first production category")
	_key(KEY_ESCAPE)
	check(game.command_bus.pending[0].buildings == [first.entity_id], "cancel input filters out the academy while barracks category is active")
	_tick()
	check(first.production.training.is_empty() and academy.production.research_queue.size() == 1, "barracks cancellation leaves selected academy research untouched")
	_key(KEY_TAB)
	check(game.selected_production() == academy, "native Tab input selects research category")
	_key(KEY_ESCAPE)
	check(game.command_bus.pending[0].buildings == [academy.entity_id], "cancel input follows the Tab-selected academy category")
	before_gold = player.gold
	_tick()
	check(academy.production.research_queue.is_empty() and player.gold == before_gold + 100, "Tab-selected last active research cancels and refunds")

	first.production.recruit("swordsman")
	first.production.recruit("swordsman")
	var ally := _building("barracks", 1, Vector3(-24, 0, 4))
	ally.production.recruit("swordsman")
	var before_state := _economy([first, ally])
	check(not game.command_bus.execute({"kind": "cancel_queue", "buildings": [ally.entity_id]}, 0).ok, "forged allied producer cancellation is rejected")
	check(_economy([first, ally]) == before_state, "forged allied cancellation changes no queue, gold or population")
	check(not game.command_bus.execute({"kind": "cancel_queue", "buildings": [first.entity_id, ally.entity_id]}, 0).ok, "mixed own-and-allied producer list is rejected atomically")
	check(_economy([first, ally]) == before_state, "invalid mixed list cannot partially refund the own producer")
	var command := {"kind": "cancel_queue", "buildings": [first.entity_id], "seq": game.command_bus.next_sequence(0)}
	check(game.command_bus.submit(command, 0).ok and not game.command_bus.submit(command, 0).ok, "duplicate network sequence is rejected before the tick")
	before_gold = player.gold
	_tick()
	check(first.production.training.size() == 1 and player.gold == before_gold + 45 and player.reserved_military_supply == 1, "accepted sequence cancels and refunds exactly one job")
	check(not game.command_bus.submit(command, 0).ok, "replayed sequence remains rejected after execution")
	before_gold = player.gold
	_tick()
	check(first.production.training.size() == 1 and player.gold == before_gold, "replayed sequence cannot produce a second refund")

	first.production.recruit("swordsman")
	var worker: BattleUnit = game.owned_entities(0, "units")[0]
	_select([worker, first])
	game.set_build_mode(true, "barracks")
	_key(KEY_ESCAPE)
	check(not game.build_mode and game.command_bus.pending.is_empty() and first.production.training.size() == 2, "Esc leaves building placement before touching the selected production queue")
	game.set_attack_mode(true)
	_key(KEY_ESCAPE)
	check(not game.attack_mode and game.command_bus.pending.is_empty() and first.production.training.size() == 2, "Esc leaves attack targeting before touching a production queue")
	_select([first])
	var preferences: Dictionary = settings.snapshot()
	preferences.bindings.rts_cancel = [KEY_X]
	settings._apply_values(preferences, false)
	check("X" in game.hud.get_node("%QueueStrip").get_node("Caption").text, "queue caption immediately shows the rebound cancel key")
	_key(KEY_ESCAPE)
	check(game.command_bus.pending.is_empty() and first.production.training.size() == 2 and not paused, "old Esc no longer cancels or pauses after rebinding")
	_key(KEY_X)
	check(game.command_bus.pending.size() == 1 and game.command_bus.pending[0].kind == "cancel_queue", "new physical X submits the cancel action")
	before_gold = player.gold
	_tick()
	check(first.production.training.size() == 1 and player.gold == before_gold + 45 and player.reserved_military_supply == 1, "rebound cancellation refunds once and releases population")
	_select([ally])
	_key(KEY_X)
	check(game.command_bus.pending.is_empty() and ally.production.training.size() == 1, "selecting an allied producer exposes no cancel hotkey purchase/refund path")
	settings._apply_values(original_preferences, false)
	check(settings.snapshot() == original_preferences, "initial preferences restored without saving the player's settings file")
	check(GameSettings.ACTIONS.size() == 35, "cancel action joins the thirty-five native rebindable actions")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("QUEUE_CANCEL_HOTKEY ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _timeout() -> void:
	printerr("QUEUE_CANCEL_HOTKEY timed out")
	paused = false
	if is_instance_valid(settings):
		settings._apply_values(original_preferences, false)
	if is_instance_valid(game):
		await game.prepare_shutdown()
	quit(3)
