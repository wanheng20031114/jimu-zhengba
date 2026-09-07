extends SceneTree
## Independent, bounded real-scene stress review. Never sends desktop input.
## Usage: Godot --headless --path PROJECT --script res://tests/stress_test.gd
## Rendered: add --rendering-method forward_plus --rendering-driver vulkan instead.

const TYPES: Array[String] = ["swordsman", "archer", "knight", "catapult", "cannon"]
var game: Node3D
var failures: Array[String] = []
var checks: Array[String] = []
var phases: Array[Dictionary] = []
var initial_usec: int
var rendered: bool
var finished: bool = false

func _initialize() -> void:
	initial_usec = Time.get_ticks_usec()
	rendered = DisplayServer.get_name() != "headless"
	call_deferred("_run")

func _check(condition: bool, label: String) -> void:
	if condition:
		checks.append(label)
		print("PASS ", label)
	else:
		failures.append(label)
		push_error("FAIL " + label)

func _run() -> void:
	create_timer(110.0, true, false, true).timeout.connect(_watchdog)
	if rendered:
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	seed(98761)
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.camera_rig.edge_scroll = false
	game.get_node("EnemyTimer").stop()
	game.get_node("IncomeTimer").stop()
	await physics_frame
	await physics_frame
	await create_timer(0.4).timeout
	_check(game.player_count() > 0 and game.enemy_count() > 0, "main scene spawns both armies")
	if "--normal-load" in OS.get_cmdline_user_args():
		await _measure("normal_14_friendly_27_enemy_idle", 5.0)
		for index: int in range(game.player_count(), 60):
			_spawn_friendly(index)
		game.select_army()
		game.command_move(Vector3(-3, 0, 10))
		await _measure("normal_60_friendly_plus_enemy_march", 8.0)
		_write_result()
		finished = true
		quit(0 if failures.is_empty() else 2)
		return
	# Validate immediate recruitment through the production API before clearing.
	game.gold = 10000
	game.select_entities([game.headquarters])
	for kind: String in TYPES:
		var before_count: int = game.player_count()
		var before_gold: int = game.gold
		var accepted: bool = game.recruit(kind)
		_check(accepted and game.player_count() == before_count + 1, kind + " instant recruitment")
		_check(game.gold == before_gold - int(game.UNIT_COSTS[kind]), kind + " exact recruitment cost")
		var born: Node3D = game.unit_container.get_child(game.unit_container.get_child_count() - 1)
		var visual: Node3D = born._model
		_check(visual.kind == kind and visual.has_node("Locomotion") and visual.has_node("Attack"), kind + " production model and animation players")
		_check(visual._team_surfaces.size() > 0, kind + " faction surface exists")
	var cost_gold: int = game.gold
	game.select_entities([])
	_check(not game.recruit("swordsman") and game.gold == cost_gold, "production requires headquarters selection")
	game.select_entities([game.headquarters])
	game.gold = 0
	_check(not game.recruit("knight"), "insufficient gold rejects production")
	# Enemy-only selection must stay inspectable but never become commandable.
	var initial_enemy: Node3D = get_nodes_in_group("enemy_units")[0]
	game.select_entities([initial_enemy])
	_check(game.selection.size() == 1 and game.own_selected_units().is_empty(), "enemy selection is inspection only")
	await _clear_units()
	await _test_screen_selection()
	await _clear_units()
	game.gold = 100000
	game.camera_rig.focus_at(Vector3(0, 0, 4), true)
	game.camera_rig.zoom_target = 48.0
	game.camera.size = 48.0
	# Disable building attacks so army counts stay deterministic during march.
	for building: Node3D in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
	for index: int in range(100):
		_spawn_friendly(index)
	game.select_army()
	game.use_control_group(1, true)
	_check(game.selection.size() == 100 and game.control_groups[1].size() == 100, "100-unit select-all and group assignment")
	game.command_move(Vector3(7, 0, -3))
	await _measure("100_friendly_marching", 5.0)
	for index: int in range(100, 160):
		_spawn_friendly(index)
	game.select_entities([game.headquarters])
	var cap_gold: int = game.gold
	_check(not game.recruit("swordsman") and game.gold == cap_gold and game.player_count() == 160, "160 player cap rejects extra recruit without charging")
	game.select_army()
	game.use_control_group(2, true)
	game.command_move(Vector3(-5, 0, 3))
	await _measure("160_friendly_marching", 6.0)
	# Recall must prune queued/dead Object references, including fully freed corpses.
	var original_group: Array = game.control_groups[2].duplicate()
	for index: int in range(24):
		original_group[index].receive_damage(100000.0)
	game.use_control_group(2)
	_check(game.selection.size() == 136, "control group excludes freshly killed units")
	await create_timer(4.8).timeout
	for index: int in range(24):
		_check(not is_instance_valid(original_group[index]), "corpse freed %02d" % index)
	game.use_control_group(2)
	game.focus_selection()
	game.stop_selected()
	game.hold_selected()
	_check(game.selection.size() == 136 and game.control_groups[2].size() == 136, "control group recall after corpse queue_free")
	# Deliberate queue_free covers stale cached selection outside death callbacks.
	var stale: Node3D = game.selection[0]
	stale.queue_free()
	await process_frame
	game._prune_selection()
	game.use_control_group(2)
	_check(game.selection.size() == 135, "selection and groups tolerate externally freed entity")
	await _clear_units()
	# Place mixed armies close enough for real melee, ranged and siege workloads.
	for faction: int in range(2):
		for index: int in range(80):
			var x: float = -14.0 + float(index % 16) * 1.8
			var z: float = (7.0 + float(index / 16) * 1.8) if faction == 0 else (-5.0 - float(index / 16) * 1.8)
			var kind: String = TYPES[index % 10] if index % 10 < 5 else ("swordsman" if index % 2 == 0 else "archer")
			var unit: Node3D = game.spawn_unit(kind, faction, Vector3(x, 0, z))
			# More durable units maintain a representative large fight for sampling.
			unit.hp *= 5.0
			unit.max_hp *= 5.0
			unit.issue_move(Vector3(x * 0.2, 0, 0), true)
	game.select_army()
	await _measure("160_mixed_battle", 12.0)
	_check(game.effect_container.get_child_count() > 0, "large battle produces projectiles and effects")
	_check(game.player_count() > 0 and game.enemy_count() > 0, "both sides remain simulated under load")
	# Kill an enemy referenced by multiple queued attack orders during combat.
	var target: Node3D = get_nodes_in_group("enemy_units")[0]
	game.command_attack(target)
	target.receive_damage(1000000.0)
	await create_timer(4.8).timeout
	game.select_army()
	game.command_move(Vector3(0, 0, 12))
	await _measure("post_target_deletion", 3.0)
	await _clear_units()
	await create_timer(3.0).timeout
	_check(get_nodes_in_group("units").is_empty(), "all stress units released")
	_write_result()
	finished = true
	quit(0 if failures.is_empty() else 2)

func _spawn_friendly(index: int) -> void:
	var x: float = -15.0 + float(index % 16) * 1.8
	var z: float = 6.0 + float(index / 16) * 1.75
	var kind: String = TYPES[index % 10] if index % 10 < 5 else "swordsman"
	var unit: Node3D = game.spawn_unit(kind, 0, Vector3(x, 0, z))
	unit.hold()

func _test_screen_selection() -> void:
	game.camera_rig.focus_at(Vector3.ZERO, true)
	game.camera_rig.zoom_target = 37.0
	game.camera.size = 37.0
	var first: Node3D = game.spawn_unit("swordsman", 0, Vector3(-1.5, 0, 0))
	var second: Node3D = game.spawn_unit("archer", 0, Vector3(1.5, 0, 0))
	var opponent: Node3D = game.spawn_unit("knight", 1, Vector3(4, 0, 0))
	for unit: Node3D in [first, second, opponent]:
		unit.process_mode = Node.PROCESS_MODE_DISABLED
	await physics_frame
	await physics_frame
	var first_screen: Vector2 = game.camera.unproject_position(first.global_position + Vector3.UP * .8)
	var second_screen: Vector2 = game.camera.unproject_position(second.global_position + Vector3.UP * .8)
	var enemy_screen: Vector2 = game.camera.unproject_position(opponent.global_position + Vector3.UP * .8)
	game.drag_start = first_screen
	game.shift_drag = false
	game._finish_selection(first_screen)
	_check(game.selection.size() == 1 and game.selection[0] == first, "world-to-screen single selection hits correct capsule")
	game.drag_start = second_screen
	game.shift_drag = true
	game._finish_selection(second_screen)
	_check(game.selection.size() == 2, "Shift-click appends friendly unit")
	game.drag_start = first_screen
	game._finish_selection(first_screen)
	_check(game.selection.size() == 1 and game.selection[0] == second, "Shift-click toggles existing friendly unit")
	var low: Vector2 = first_screen.min(second_screen).min(enemy_screen) - Vector2(20, 20)
	var high: Vector2 = first_screen.max(second_screen).max(enemy_screen) + Vector2(20, 20)
	game.drag_start = low
	game.shift_drag = false
	game._finish_selection(high)
	_check(game.selection.size() == 2 and opponent not in game.selection, "box selection includes friendly units and excludes enemies")
	first.queue_free()
	await process_frame
	game.drag_start = second_screen
	game._finish_selection(second_screen)
	_check(game.selection.size() == 1 and game.selection[0] == second, "click survives freed last-click reference")

func _clear_units() -> void:
	game.select_entities([])
	game.control_groups.clear()
	for unit: Node in get_nodes_in_group("units"):
		unit.queue_free()
	for child: Node in game.effect_container.get_children():
		child.queue_free()
	await process_frame
	await physics_frame

func _measure(label: String, seconds: float) -> void:
	await create_timer(1.6).timeout
	var samples: Array[Dictionary] = []
	var since: int = Time.get_ticks_usec()
	var previous: int = since
	var next_sample: int = since
	var frames: int = 0
	var frame_ms: Array[float] = []
	while Time.get_ticks_usec() - since < int(seconds * 1000000.0):
		await process_frame
		var now: int = Time.get_ticks_usec()
		frames += 1
		frame_ms.append(float(now - previous) / 1000.0)
		previous = now
		if now >= next_sample:
			next_sample = now + 200000
			samples.append({"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
				"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
				"navigation_ms": Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0,
				"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				"render_objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
				"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
				"memory_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
				"orphans": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
				"live_units": get_nodes_in_group("units").size(),
				"effects": game.effect_container.get_child_count()})
	frame_ms.sort()
	var averages: Dictionary = {}
	for key: String in samples[0]:
		var sum: float = 0.0
		var maximum: float = 0.0
		for sample: Dictionary in samples:
			sum += float(sample[key])
			maximum = maxf(maximum, float(sample[key]))
		averages[key] = {"mean": sum / samples.size(), "max": maximum}
	var result: Dictionary = {"name": label, "duration_s": float(Time.get_ticks_usec() - since) / 1000000.0,
		"fps_measured": frames / seconds, "frame_p50_ms": frame_ms[int(frame_ms.size() * .5)],
		"frame_p95_ms": frame_ms[mini(frame_ms.size() - 1, int(frame_ms.size() * .95))],
		"monitors": averages}
	phases.append(result)
	print("PHASE ", JSON.stringify(result))
	if rendered and label == "160_mixed_battle":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://tests/stress_battle.png")

func _write_result() -> void:
	var data: Dictionary = {"rendered": rendered, "renderer": RenderingServer.get_current_rendering_method(),
		"godot": Engine.get_version_info().string, "elapsed_s": float(Time.get_ticks_usec() - initial_usec) / 1000000.0,
		"checks_passed": checks.size(), "failures": failures, "phases": phases}
	var prefix: String = "stress_normal_" if "--normal-load" in OS.get_cmdline_user_args() else "stress_"
	var file := FileAccess.open("res://tests/%s%s.json" % [prefix, "rendered" if rendered else "headless"], FileAccess.WRITE)
	file.store_string(JSON.stringify(data, "\t"))
	print("STRESS_RESULT ", JSON.stringify(data))

func _watchdog() -> void:
	if finished:
		return
	failures.append("110 second watchdog expired")
	_write_result()
	quit(3)
