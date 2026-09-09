extends SceneTree
## Production main-scene boundary fixtures; long-run economics are covered separately.
var game: Node3D
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	Engine.time_scale = 6.0
	Engine.physics_ticks_per_second = 180
	Engine.max_physics_steps_per_frame = 48
	_run.call_deferred()

func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		printerr("FAIL ", message)

func _command(command: Dictionary, owner: int = 0) -> Dictionary:
	return game.command_bus.execute(command, owner)

func _wait_until(predicate: Callable, seconds: float) -> bool:
	var until: float = game.elapsed + seconds
	while game.elapsed < until:
		if predicate.call(): return true
		await physics_frame
	return bool(predicate.call())

func _freeze_workers() -> void:
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false

func _run() -> void:
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.bots.clear()
	game.camera_rig.edge_scroll = false
	game.get_node("IncomeTimer").stop()
	_freeze_workers()
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	await create_timer(0.8).timeout
	var player: PlayerState = game.get_player(0)
	player.gold = 10000
	_check(await _wait_until(func(): return game.find_recruit_position("farmer", game.headquarters).is_finite(), 30), "asynchronous native map navigation resolves headquarters exits")
	await _farmer_queue_and_mines()
	await _queued_construction()
	await _victory_and_rebuilding()
	var mode: String = game.match_config.mode
	var file := FileAccess.open("res://artifacts/skirmish_match_%s_results.json" % mode, FileAccess.WRITE)
	file.store_string(JSON.stringify({"mode": mode, "checks": checks, "failures": failures}, "  "))
	file.close()
	print("SKIRMISH_MATCH_RESULT ", mode, " ", checks, " checks; ", failures.size(), " failures")
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 30
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)

func _farmer_queue_and_mines() -> void:
	var hq: BattleBuilding = game.headquarters
	var player: PlayerState = game.get_player(0)
	for index: int in range(7):
		_check(_command({"kind": "recruit", "target": hq.entity_id, "unit_type": "farmer"}).ok, "queue farmer %d through headquarters" % (index + 4))
	var before: int = player.gold
	_check(not _command({"kind": "recruit", "target": hq.entity_id, "unit_type": "farmer"}).ok and before == player.gold, "eleventh live-or-queued farmer is rejected without charge")
	_check(player.farmers == 3 and player.reserved_farmers == 7, "seven reservations preserve the initial three living farmers")
	hq.production._physics_process(9.9)
	_check(player.farmers == 3, "first queued farmer remains unavailable at 9.9 seconds")
	hq.production._physics_process(0.2)
	_check(player.farmers == 4, "first queued farmer completes after ten seconds")
	for index: int in range(6):
		await physics_frame
		await physics_frame
		_freeze_workers()
		hq.production._physics_process(10.1)
	await physics_frame
	_freeze_workers()
	_check(player.farmers == 10 and player.reserved_farmers == 0, "all seven queued farmers complete into native production entities")
	var farmers: Array = game.owned_entities(0, "units")
	var mine: ResourceVein = game.nearest_mine(hq.position)
	var ids: Array = farmers.map(func(unit): return unit.entity_id)
	_check(_command({"kind": "gather", "units": ids, "target": mine.entity_id}).ok, "one command can direct all ten farmers to the same mine")
	_check(mine.occupied_slots() == 6, "a single mine allocates exactly six stable worker slots")
	var waiting: Array = farmers.filter(func(worker): return not worker._claimed_mine)
	_check(waiting.size() == 4, "seventh through tenth farmers wait instead of receiving extra slots")
	if waiting.is_empty(): return
	var seventh: BattleUnit = waiting[0]
	seventh.position = seventh.destination
	seventh.reset_physics_interpolation()
	before = player.gold
	seventh._work_velocity(3.1)
	_check(seventh.work_progress == 0 and player.gold == before, "a waiting seventh farmer cannot collect virtual income")
	var leaving: BattleUnit = farmers.filter(func(worker): return worker._claimed_mine)[0]
	leaving.stop()
	seventh._repath_time = 0.0
	seventh._work_velocity(0.1)
	_check(seventh._claimed_mine and mine.occupied_slots() == 6, "waiting farmer takes the precise slot released by a stopped miner")
	_freeze_workers()

func _queued_construction() -> void:
	var worker: BattleUnit = game.owned_entities(0, "units")[0]
	worker.set_physics_process(true)
	worker.navigation_agent.avoidance_enabled = true
	var at: Vector3 = game.find_build_location(0, "defense_tower", game.headquarters.position)
	_check(at.is_finite(), "new map offers legal visible construction space")
	if not at.is_finite(): return
	var response: Dictionary = _command({"kind": "build", "units": [worker.entity_id], "building_type": "defense_tower", "at": game.vector_data(at)})
	_check(response.ok, "first tower is paid for and assigned through the production command validator")
	if not response.ok: return
	var first: BattleBuilding = game.entities_by_id[response.entity_id]
	await physics_frame
	await physics_frame
	at = game.find_build_location(0, "defense_tower", game.headquarters.position)
	_check(at.is_finite(), "second legal tower does not overlap the first footprint")
	if not at.is_finite(): return
	response = _command({"kind": "build", "units": [worker.entity_id], "building_type": "defense_tower", "at": game.vector_data(at), "queued": true})
	_check(response.ok and worker.waypoint_queue.size() == 1, "Shift construction appends a paid site behind the current one")
	if not response.ok: return
	var second: BattleBuilding = game.entities_by_id[response.entity_id]
	_check(second._builder == null and second.construction_progress == 0, "queued site claims no builder or progress before arrival")
	_check(await _wait_until(func(): return first.construction_progress > 0.0, 20), "builder reaches the first site's actual collision boundary")
	_check(not first.is_constructed and second.construction_progress == 0, "construction time is consumed only at the active site")
	_check(await _wait_until(func(): return first.is_constructed, 26), "first tower completes twenty seconds of real construction")
	_check(await _wait_until(func(): return second.is_constructed, 45), "worker traverses native navigation and completes its queued second tower")
	_check(not worker._claimed_site and worker.order == BattleUnit.Order.IDLE, "final construction releases the claim and returns the worker to idle")
	_freeze_workers()

func _victory_and_rebuilding() -> void:
	var owner: int = game.players.size() - 1
	var enemy_hq: BattleBuilding = game.owned_entities(owner, "buildings")[0]
	var enemy_worker: BattleUnit = game.owned_entities(owner, "units")[0]
	var old_position: Vector3 = enemy_hq.position
	var tower: BattleBuilding = game.spawn_building("defense_tower", owner, old_position + Vector3(8, 0, 0))
	var site: BattleBuilding = game.spawn_building("academy", owner, old_position + Vector3(0, 0, 8), true)
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		if building.alliance_id == enemy_hq.alliance_id and building.building_type == "headquarters":
			building.receive_damage(building.max_hp)
	game.tests_running = false
	game.check_victory()
	_check(not game.finished, "headquarters destruction does not defeat surviving military buildings or sites")
	_check(enemy_hq.alliance_id in game._revealed_alliances, "losing the last completed core permanently exposes that alliance's buildings")
	_check(game.get_node("FogOfWar").entity_visible(0, tower) and game.get_node("FogOfWar").entity_visible(0, site), "both surviving tower and unfinished academy are exposed")
	game.tests_running = true
	game.get_player(owner).gold = 1000
	await physics_frame
	await physics_frame
	await create_timer(0.8).timeout
	var at: Vector3 = game.find_build_location(owner, "headquarters", old_position)
	_check(at.is_finite(), "an owner with a surviving worker can find a headquarters rebuilding site")
	if at.is_finite():
		var rebuilt: Dictionary = _command({"kind": "build", "units": [enemy_worker.entity_id], "building_type": "headquarters", "at": game.vector_data(at)}, owner)
		_check(rebuilt.ok and game.get_player(owner).gold == 600, "rebuilding headquarters costs the approved four hundred gold")
		_check(not _command({"kind": "build", "units": [enemy_worker.entity_id], "building_type": "headquarters", "at": game.vector_data(at + Vector3(12, 0, 0))}, owner).ok, "unfinished headquarters already occupies the one-headquarters limit")
		if rebuilt.ok:
			_check(game.get_node("FogOfWar").entity_visible(0, game.entities_by_id[rebuilt.entity_id]), "rebuilt headquarters site remains permanently exposed")
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		if building.alliance_id != game.get_player(0).alliance_id and building != site:
			building.receive_damage(building.max_hp)
	game.tests_running = false
	game.check_victory()
	_check(not game.finished, "a final unfinished military site still prevents defeat")
	site.receive_damage(site.max_hp)
	game.check_victory()
	_check(game.finished, "destroying the last military site ends the match")
