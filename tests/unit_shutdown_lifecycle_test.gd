extends SceneTree
## Actual main-scene lifecycle entry points. Run headless with --fixed-fps 120.
## Checks synchronous cleanup before physics/RVO can provide another callback.
var game: Node3D
var checks: int = 0
var failures: Array[String] = []
var shutdown_completed: bool = false
var completed_modes: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures.append(label)

func _ticks(count: int) -> void:
	var until: int = Engine.get_physics_frames() + count
	while Engine.get_physics_frames() < until:
		await physics_frame
		await process_frame

func _finish_shutdown() -> void:
	await game.prepare_shutdown()
	shutdown_completed = true

func _run() -> void:
	AudioServer.set_bus_mute(0, true)
	print("LIFECYCLE_AUDIO_DRIVER ", AudioServer.get_driver_name())
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	var deadline: int = Time.get_ticks_msec() + 45000
	process_frame.connect(func():
		if Time.get_ticks_msec() >= deadline:
			print("UNIT_SHUTDOWN_LIFECYCLE_TIMEOUT")
			quit(3)
	)
	for mode: String in ["victory", "defeat", "shutdown"]:
		await _case(mode)
	_check(completed_modes == ["victory", "defeat", "shutdown"], "all three lifecycle scenarios reach their final assertions")
	var report: FileAccess = FileAccess.open("res://artifacts/unit_shutdown_lifecycle_results.json", FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks": checks, "failures": failures}, "  "))
	report.close()
	print("UNIT_SHUTDOWN_LIFECYCLE ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _case(mode: String) -> void:
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.camera_rig.edge_scroll = false
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	for entity: Node3D in get_nodes_in_group("entities"):
		if entity is BattleUnit:
			entity.stop()
			entity.navigation_agent.avoidance_enabled = false
		entity.set_physics_process(false)
	await _ticks(6)
	var heavy: Array[BattleUnit] = []
	var positions: Array[Vector3] = []
	var kinds: Array[String] = ["knight", "catapult", "cannon"]
	for index: int in range(kinds.size()):
		var at := Vector3(float(index - 1) * 4.0, 0, 8)
		var unit: BattleUnit = game.spawn_unit(kinds[index], 0, at)
		unit.issue_move(at + Vector3(0, 0, 10))
		heavy.append(unit)
	var moving_deadline: int = Engine.get_physics_frames() + Engine.physics_ticks_per_second * 2
	while not heavy.all(func(unit: BattleUnit): return unit._moving and unit.velocity.length_squared() > 0.01) and Engine.get_physics_frames() < moving_deadline:
		await _ticks(1)
	for unit: BattleUnit in heavy:
		_check(unit._moving and unit.velocity.length_squared() > 0.01 and unit._model.locomotion.current_animation == "walk", mode + " " + unit.unit_type + " begins with native movement and walking animation")
	var miner: BattleUnit = game.spawn_unit("farmer", 0, Vector3(-12, 0, 30))
	miner.issue_gather(game.nearest_mine(miner.global_position))
	miner.queue_move(Vector3(-10, 0, 28))
	var archer: BattleUnit = game.spawn_unit("archer", 0, Vector3(0, 0, 2))
	archer.set_physics_process(false)
	var victim: BattleUnit = game.spawn_unit("knight", 1, Vector3(0, 0, 0.35))
	victim.set_physics_process(false)
	victim.navigation_agent.avoidance_enabled = false
	# Current matches gate attacks on authoritative fog. Let the newly spawned
	# archer publish its sight before issuing the real attack command.
	await _ticks(ceili(FogOfWar.UPDATE_SECONDS * Engine.physics_ticks_per_second) + 1)
	archer.set_physics_process(true)
	archer.issue_attack(victim)
	await _ticks(1)
	_check(not archer.attack_windup.is_stopped() and miner.work_target != null and not miner.waypoint_queue.is_empty(), mode + " starts with a real attack windup and queued economic order")
	var before_tick: int = Engine.get_physics_frames()
	var victim_hp: float = victim.hp
	for unit: BattleUnit in heavy:
		positions.append(unit.global_position)
	if mode == "shutdown":
		shutdown_completed = false
		# This coroutine runs prepare_shutdown synchronously up to its first
		# audio-retirement await, allowing the immediate cleanup to be checked.
		_finish_shutdown()
	else:
		game.end_battle(mode == "victory")
	_check(Engine.get_physics_frames() == before_tick and game.finished, mode + " cleanup completes before another physics step")
	for unit: BattleUnit in heavy:
		_check(not unit._moving and not unit._model._moving and unit._model.locomotion.current_animation == "idle", mode + " " + unit.unit_type + " immediately restores idle animation")
		_check(not unit.is_physics_processing() and not unit.navigation_agent.avoidance_enabled and unit.velocity == Vector3.ZERO, mode + " " + unit.unit_type + " is already frozen without requiring a velocity callback")
		_check(unit._path_budget.is_finished(unit) and not unit._path_budget.has_pending(unit), mode + " " + unit.unit_type + " cancels active and pending native routes")
	_check(archer.attack_windup.is_stopped() and archer.target == null and miner.work_target == null and miner.waypoint_queue.is_empty() and not miner._working, mode + " cancels attack windup and clears worker assignment/queue")
	await _ticks(Engine.physics_ticks_per_second * 2)
	for index: int in range(heavy.size()):
		var unit: BattleUnit = heavy[index]
		_check(not unit._moving and unit._model.locomotion.current_animation == "idle", mode + " " + unit.unit_type + " remains idle after two seconds")
		_check(unit.global_position.is_equal_approx(positions[index]) and unit.velocity == Vector3.ZERO, mode + " " + unit.unit_type + " receives no delayed movement after shutdown")
	_check(victim.hp == victim_hp, mode + " canceled windup never delivers delayed damage")
	if mode == "shutdown":
		_check(shutdown_completed, "shutdown audio retirement completes normally after synchronous unit cleanup")
	else:
		await game.prepare_shutdown()
	completed_modes.append(mode)
