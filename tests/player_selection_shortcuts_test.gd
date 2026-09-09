extends SceneTree
## Exercise the real shortcut handler, native units, selection and camera for all
## four owners. Allied and hostile idle farmers coexist throughout each case.

var game: Node3D
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	Engine.max_fps = 60
	_run.call_deferred()

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func _key(key: Key) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = key
	event.pressed = true
	game._unhandled_input(event)

func _run() -> void:
	root.get_node("Session").start_offline("2v2")
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	await physics_frame
	await physics_frame
	game.tests_running = true
	game.bots.clear()
	game.set_physics_process(false)
	game.set_process(false)
	game.camera_rig.edge_scroll = false
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	var soldiers: Array[BattleUnit] = []
	for owner in range(4):
		var soldier: BattleUnit = game.spawn_unit("swordsman", owner, Vector3(owner * 4, 0, 0))
		soldier.set_physics_process(false)
		soldier.navigation_agent.avoidance_enabled = false
		soldiers.append(soldier)
	for owner in range(4):
		game.local_owner_id = owner
		game._idle_worker_index = 0
		var workers: Array = game.owned_entities(owner, "units").filter(func(unit): return unit.unit_type == "farmer")
		_check(workers.size() == 3, "owner %d starts with three actual farmers" % owner)
		workers[2].order = BattleUnit.Order.GATHER
		for cycle in range(3):
			_key(KEY_PERIOD)
			var expected: BattleUnit = workers[cycle % 2]
			_check(game.selection == [expected] and expected.owner_id == owner, "owner %d period cycle %d selects only its own idle farmer" % [owner, cycle])
			_check(game.camera_rig.destination.is_equal_approx(game.clamp_to_map(expected.global_position)), "owner %d period cycle %d focuses its selected farmer" % [owner, cycle])
		workers[0].alive = false
		_key(KEY_PERIOD)
		_check(game.selection == [workers[1]], "owner %d skips a dead farmer" % owner)
		workers[1].order = BattleUnit.Order.GATHER
		game.select_entities([])
		var camera_before: Vector3 = game.camera_rig.destination
		_key(KEY_PERIOD)
		_check(game.selection.is_empty(), "owner %d with no idle farmer never selects an allied or hostile worker" % owner)
		_check(game.camera_rig.destination == camera_before, "owner %d with no idle farmer keeps its current camera" % owner)
		workers[0].alive = true
		for worker: BattleUnit in workers:
			worker.order = BattleUnit.Order.IDLE
		_key(KEY_G)
		_check(game.selection == [soldiers[owner]], "owner %d all-army shortcut excludes other owners and own farmers" % owner)
	game.local_owner_id = 0
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("PLAYER_SELECTION_SHORTCUTS ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
