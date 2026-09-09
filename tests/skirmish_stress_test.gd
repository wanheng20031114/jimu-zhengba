extends SceneTree
## Native 1600x900 Forward+ benchmark; run only when the GPU is available exclusively.
## Frame intervals measure presentation. TIME_PHYSICS_PROCESS measures native logic time.
## https://docs.godotengine.org/en/stable/classes/class_performance.html

const MIXED_COUNTS: Dictionary = {"swordsman": 19, "archer": 10, "knight": 8, "catapult": 3, "cannon": 2}
const PROFILE_PROBE: PackedScene = preload("res://tests/skirmish_profile_probe.tscn")
const WARMUP_SECONDS: float = 6.0
const SAMPLE_SECONDS: float = 15.0
var game: Node3D
var mode: String = "1v1"
var phases: Array[Dictionary] = []
var failures: Array[String] = []
var checks: int = 0
var finalized: bool = false
var previous_physics_frame: int = 0
var began_usec: int = 0
var short_check: bool = false
var probe: Node
var configured_fps_limit: int = 0
var configured_vsync: int = -1

func _initialize() -> void:
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 30
	Engine.max_fps = 0
	short_check = "--harness-check" in OS.get_cmdline_user_args()
	_run.call_deferred()

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func _run() -> void:
	began_usec = Time.get_ticks_usec()
	create_timer(140.0, true, false, true).timeout.connect(_watchdog)
	mode = "2v2" if "--2v2" in OS.get_cmdline_user_args() else "1v1"
	var rendered: bool = DisplayServer.get_name() != "headless"
	_check(rendered or short_check, "performance measurement uses a real Vulkan window, not a headless FPS value")
	if not rendered and not short_check:
		await _finish()
		return
	seed(940712)
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	# GameSettings restores the user's cap during autoload initialization, after
	# this SceneTree's _initialize(). Override only this benchmark process once
	# scene startup has completed; never save or mutate the user's preferences.
	await physics_frame
	await physics_frame
	configured_fps_limit = Engine.max_fps
	configured_vsync = DisplayServer.window_get_vsync_mode() if rendered else -1
	Engine.max_fps = 0
	if rendered:
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		DisplayServer.window_set_size(Vector2i(1600, 900))
	_check(Engine.max_fps == 0, "benchmark explicitly removes the restored settings frame cap after startup")
	_check(not rendered or DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED, "benchmark disables vsync after all settings startup hooks")
	probe = PROFILE_PROBE.instantiate()
	game.add_child(probe)
	game.tests_running = true
	game.bots.clear()
	game.camera_rig.edge_scroll = false
	game.get_node("IncomeTimer").stop()
	game.camera_rig.focus_at(Vector3.ZERO, true)
	game.camera_rig.zoom_target = 48.0
	game.camera.size = 48.0
	# No shadow, MSAA, TAA, environment, model or audio quality override is used.
	_check(Engine.physics_ticks_per_second == 30, "native authority remains at thirty ticks per second")
	_check(game.players.size() == (4 if mode == "2v2" else 2), "benchmark map keeps its native player count")
	var ready_deadline: int = Time.get_ticks_msec() + 15000
	while not game.find_recruit_position("farmer", game.headquarters).is_finite() and Time.get_ticks_msec() < ready_deadline:
		await physics_frame
	_check(game.find_recruit_position("farmer", game.headquarters).is_finite(), "authored navigation and dynamic headquarters footprints are ready")
	await _populate("mixed")
	await _measure("mixed_roster_combat", 1.0 if short_check else SAMPLE_SECONDS)
	if not short_check:
		await _populate("maximum_light")
		await _measure("maximum_units_combat", SAMPLE_SECONDS)
		await _populate("maximum_light")
		_order_march()
		await _measure("maximum_units_marching", SAMPLE_SECONDS)
	await _finish()

func _populate(composition: String) -> void:
	game.select_entities([])
	game.control_groups.clear()
	game.get_node("EffectPool").reset_all()
	for unit: Node in game.unit_container.get_children():
		unit.queue_free()
	for effect: Node in game.effect_container.get_children():
		effect.queue_free()
	await physics_frame
	await physics_frame
	for player: PlayerState in game.players:
		player.farmers = 0
		player.military_supply = 0
		player.reserved_farmers = 0
		player.reserved_military_supply = 0
	var first_alliance: int = game.get_player(0).alliance_id
	var nav_map: RID = game.get_world_3d().navigation_map
	for player: PlayerState in game.players:
		var sign_z: float = 1.0 if player.alliance_id == first_alliance else -1.0
		var lane: float = (-12.0 if player.owner_id % 2 == 0 else 12.0) if mode == "2v2" else 0.0
		var roster: Array[String] = []
		if composition == "mixed":
			for kind: String in MIXED_COUNTS:
				for index: int in range(int(MIXED_COUNTS[kind])): roster.append(kind)
		else:
			for index: int in range(60): roster.append("swordsman" if index % 2 == 0 else "archer")
		var expected_supply: int = 0
		for index: int in range(roster.size()):
			expected_supply += BalanceCatalog.unit(roster[index]).supply
			var at := Vector3(lane + (float(index % 8) - 3.5) * 2.0, 0, sign_z * (12.0 + float(index / 8) * 2.0))
			at = NavigationServer3D.map_get_closest_point(nav_map, at)
			var unit: BattleUnit = game.spawn_unit(roster[index], player.owner_id, at)
			# Explicit benchmark-only durability keeps crowd/attack/effect load stable.
			# All damage, attack periods, movement, navigation and visual effects stay native.
			unit.hp *= 20.0
			unit.max_hp *= 20.0
			unit.issue_move(Vector3(lane * 0.45 + (index % 5 - 2) * 1.6, 0, -sign_z * 3.0), true)
		var hq: BattleBuilding = game.owned_entities(player.owner_id, "buildings")[0]
		var mines: Array[Node] = get_nodes_in_group("resource_veins")
		mines.sort_custom(func(a: Node3D, b: Node3D): return a.position.distance_squared_to(hq.position) < b.position.distance_squared_to(hq.position))
		for index: int in range(10):
			var mine: ResourceVein = mines[0 if index < 6 else 1]
			var at := mine.position + Vector3(cos(index * TAU / 6.0), 0, sin(index * TAU / 6.0)) * 4.0
			var worker: BattleUnit = game.spawn_unit("farmer", player.owner_id, NavigationServer3D.map_get_closest_point(nav_map, at))
			worker.hp *= 20.0
			worker.max_hp *= 20.0
			worker.issue_gather(mine)
		_check(player.military_supply == expected_supply and player.farmers == 10, "owner %d population follows current resources without changing the stress roster" % player.owner_id)
	_check(get_nodes_in_group("units").size() == game.players.size() * (52 if composition == "mixed" else 70), "native unit count matches the declared benchmark composition")
	game.select_army()
	await create_timer(1.0 if short_check else WARMUP_SECONDS).timeout

func _order_march() -> void:
	for player: PlayerState in game.players:
		var army: Array = game.owned_entities(player.owner_id, "units").filter(func(unit): return unit.unit_type != "farmer")
		var sign_z: float = 1.0 if player.alliance_id == game.get_player(0).alliance_id else -1.0
		game.move_formation(army, Vector3(0, 0, sign_z * 32.0), false, false)

func _measure(label: String, seconds: float) -> void:
	_check(Engine.max_fps == 0, "phase begins with an uncapped benchmark process")
	var frame_ms: Array[float] = []
	var physics_ms: Array[float] = []
	var navigation_ms: Array[float] = []
	var process_ms: Array[float] = []
	var samples: Array[Dictionary] = []
	var since: int = Time.get_ticks_usec()
	var previous: int = since
	var next_monitor_sample: int = since
	var start_units: int = get_nodes_in_group("units").size()
	var start_tick: int = game.simulation_tick
	probe.begin_sample()
	previous_physics_frame = Engine.get_physics_frames()
	while Time.get_ticks_usec() - since < int(seconds * 1000000):
		await process_frame
		var now: int = Time.get_ticks_usec()
		frame_ms.append((now - previous) / 1000.0)
		previous = now
		process_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		var current_physics_frame: int = Engine.get_physics_frames()
		if current_physics_frame != previous_physics_frame:
			# Read the engine's measured work duration, never the ~33ms callback interval.
			physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
			navigation_ms.append(Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0)
			previous_physics_frame = current_physics_frame
		if now >= next_monitor_sample:
			next_monitor_sample = now + 250000
			samples.append({"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
				"render_objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
				"memory_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
				"video_memory_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
				"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
				"orphans": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
				"active_units": get_nodes_in_group("units").size(),
				"effects": game.effect_container.get_child_count() + game.get_node("EffectPool").active_count(),
				"projectiles": game.effect_container.get_child_count(),
				"pooled_effects": game.get_node("EffectPool").active_count()})
	var duration_s: float = (Time.get_ticks_usec() - since) / 1000000.0
	_check(Engine.max_fps == 0, "phase remained uncapped during measurement")
	_check(DisplayServer.get_name() == "headless" or DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED, "phase remained independent of display vsync")
	var frame_stats: Dictionary = _distribution(frame_ms)
	var logic_samples: Array[float] = probe.end_sample()
	var physics_stats: Dictionary = _distribution(logic_samples)
	var phase: Dictionary = {"name": label, "duration_seconds": duration_s, "frame_count": frame_ms.size(),
		"measured_fps": frame_ms.size() / duration_s, "frame_ms": frame_stats, "physics_logic_ms": physics_stats,
		"engine_physics_monitor_ms": _distribution(physics_ms),
		"path_query_ms": _distribution(probe.path_query_ms), "path_query_count": _distribution(probe.path_query_count),
		"navigation_ms": _distribution(navigation_ms), "process_ms": _distribution(process_ms),
		"authority_ticks": game.simulation_tick - start_tick, "observed_tps": (game.simulation_tick - start_tick) / duration_s,
		"starting_units": start_units, "ending_units": get_nodes_in_group("units").size(), "monitor_samples": samples,
		"logic_p95_under_33ms": float(physics_stats.p95) <= 1000.0 / 30.0,
		"frame_p95_under_16ms": float(frame_stats.p95) <= 1000.0 / 60.0}
	phases.append(phase)
	print("SKIRMISH_STRESS_PHASE ", mode, " ", label, " fps=", phase.measured_fps, " frame_p95_ms=", frame_stats.p95, " physics_logic_p95_ms=", physics_stats.p95)
	_check(not physics_ms.is_empty(), "phase records actual native physics workload samples")
	_check(logic_samples.size() >= (game.simulation_tick - start_tick) - 1, "priority markers record every actual SceneTree physics tick")
	_check(float(_distribution(probe.path_query_count).max) <= game.get_node("PathBudget").queries_per_tick, "native automatic replans and command queries both stay inside the per-tick budget")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://artifacts/skirmish_stress_%s_%s.png" % [mode, label])

func _distribution(values: Array[float]) -> Dictionary:
	if values.is_empty(): return {"samples": 0, "mean": 0, "p50": 0, "p95": 0, "p99": 0, "max": 0}
	var ordered: Array[float] = values.duplicate()
	ordered.sort()
	var total: float = 0.0
	for value: float in values: total += value
	return {"samples": values.size(), "mean": total / values.size(), "p50": ordered[floori((ordered.size() - 1) * 0.50)],
		"p95": ordered[floori((ordered.size() - 1) * 0.95)], "p99": ordered[floori((ordered.size() - 1) * 0.99)], "max": ordered.back()}

func _write_report() -> void:
	var rendered: bool = DisplayServer.get_name() != "headless"
	var report: Dictionary = {"mode": mode, "rendered": rendered, "harness_check_only": short_check,
		"godot": Engine.get_version_info().string, "renderer": RenderingServer.get_current_rendering_method(),
		"physics_ticks_per_second": Engine.physics_ticks_per_second, "window_size": str(DisplayServer.window_get_size()) if rendered else "headless",
		"restored_settings_fps_limit_before_benchmark_override": configured_fps_limit,
		"restored_settings_vsync_before_benchmark_override": configured_vsync,
		"benchmark_fps_limit": Engine.max_fps,
		"benchmark_vsync": DisplayServer.window_get_vsync_mode() if rendered else -1,
		"viewport_size": str(root.get_visible_rect().size), "physics_interpolation": physics_interpolation,
		"msaa_3d": ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_3d"),
		"taa": ProjectSettings.get_setting("rendering/anti_aliasing/quality/use_taa"),
		"shadow_atlas_size": ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/size"),
		"physics_metric": "physics_logic_ms brackets SceneTree physics callbacks with saved-scene priorities -1000000/+1000000. It excludes PhysicsServer stepping outside the SceneTree. engine_physics_monitor_ms separately reports cached Performance.TIME_PHYSICS_PROCESS. Neither uses tick arrival intervals as logic cost.",
		"benchmark_conditions": "HQ/maps remain native; bots and passive income stopped; unchanged 42-unit mixed army or 60 infantry plus 10 farmers per owner, population derived from current resources; benchmark-only health x20 stabilizes combat crowds; damage, cooldowns, shadows and AA unchanged.",
		"checks": checks, "failures": failures, "phases": phases}
	if is_instance_valid(game):
		report["shadow_max_distance"] = game.get_node("Sun").directional_shadow_max_distance
		report["shadow_mode"] = game.get_node("Sun").directional_shadow_mode
	var suffix: String = "_harness" if short_check else ""
	var file := FileAccess.open("res://artifacts/skirmish_stress_%s%s.json" % [mode, suffix], FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()

func _finish() -> void:
	if finalized: return
	finalized = true
	_write_report()
	if is_instance_valid(game):
		await game.prepare_shutdown()
		game.queue_free()
		await process_frame
		await process_frame
	print("SKIRMISH_STRESS_RESULT ", mode, " ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _watchdog() -> void:
	if finalized: return
	_check(false, "benchmark exceeded its bounded 140-second run")
	await _finish()
