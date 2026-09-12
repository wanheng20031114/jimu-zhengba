class_name Battle600Performance
extends "res://tests/skirmish_stress_test.gd"
## Export this custom SceneTree as application/run/main_loop_type for release runs.
## Wall-clock samples, never --fixed-fps; the existing saved probe brackets logic.

const ROSTER := {"swordsman": 22, "spearman": 12, "shield_guard": 8, "archer": 10,
	"knight": 8, "light_cavalry": 5, "catapult": 4, "cannon": 2, "war_elephant": 2, "engineer": 2}
var run_id := "mixed"
var cavalry_only := false
var focus_fire := false
var mixed_roster: Dictionary = ROSTER.duplicate()
var natural_health := false
var damage_events := 0
var damage_amount := 0.0
var unique_victims: Dictionary = {}
var orders: Array[Dictionary] = []
var watching: Array[Dictionary] = []
var camera_samples: Array[float] = []
var camera_started := 0
var camera_origin := Vector3.ZERO
var camera_release_at := 0
var benchmark_output := ""
var quality: Dictionary = {}
var sustained_seconds := 30.0
var health_multiplier := 100.0

func _run() -> void:
	began_usec = Time.get_ticks_usec()
	create_timer(180.0, true, false, true).timeout.connect(_watchdog)
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--run-id="): run_id = argument.trim_prefix("--run-id=")
		if argument.begins_with("--output="): benchmark_output = argument.trim_prefix("--output=")
		if argument.begins_with("--sustained-seconds="): sustained_seconds = argument.trim_prefix("--sustained-seconds=").to_float()
	_check(sustained_seconds >= 30.0 and sustained_seconds <= 120.0, "sustained observation is 30 to 120 seconds")
	cavalry_only = "--cavalry" in OS.get_cmdline_user_args()
	focus_fire = "--focus-fire" in OS.get_cmdline_user_args()
	if "--priests" in OS.get_cmdline_user_args():
		_check(not cavalry_only, "priest variation uses the mixed roster")
		mixed_roster.archer = 8
		mixed_roster.priest = 2
	natural_health = "--natural-health" in OS.get_cmdline_user_args()
	# Preserve the original 30-second fixture. Longer observations need enough
	# health reserve to keep all 600 bodies present while damage remains real.
	health_multiplier = 1.0 if natural_health else 100.0 * sustained_seconds / 30.0
	if benchmark_output.is_empty(): benchmark_output = ProjectSettings.globalize_path("res://artifacts/battle-600")
	DirAccess.make_dir_recursive_absolute(benchmark_output)
	var rendered := DisplayServer.get_name() != "headless"
	_check(rendered or short_check, "playability measurements require a rendered window")
	_check(not OS.get_cmdline_args().has("--fixed-fps"), "wall-clock benchmark never forces simulation delta")
	if not rendered and not short_check:
		await _finish()
		return
	seed(1309600)
	mode = "4v4"
	var session: Node = root.get_node("Session")
	session.online = false
	session.config = session.offline_config(mode)
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	game.tests_running = true
	game.bots.clear()
	game.get_node("IncomeTimer").stop()
	game.camera_rig.edge_scroll = false
	await physics_frame
	await physics_frame
	configured_fps_limit = Engine.max_fps
	configured_vsync = DisplayServer.window_get_vsync_mode() if rendered else -1
	Engine.max_fps = 0
	if rendered:
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Vector2i(1600, 900))
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	probe = PROFILE_PROBE.instantiate()
	game.add_child(probe)
	_check(game.players.size() == 8, "eight native owners each receive 75 units")
	_check(Engine.physics_ticks_per_second == 30 and Engine.time_scale == 1.0, "normal thirty-tick simulation and time scale")
	while not game.get_node("ConstructionNavigation").paths_ready(): await physics_frame
	var recruitment_deadline := Time.get_ticks_msec() + 15000
	while not game.find_recruit_position("farmer", game.headquarters).is_finite() and Time.get_ticks_msec() < recruitment_deadline:
		await physics_frame
	_check(game.find_recruit_position("farmer", game.headquarters).is_finite(), "native navigation accepts a real recruitment position")
	quality = {"msaa_3d": root.msaa_3d, "taa": root.use_taa, "render_scale": root.scaling_3d_scale,
		"shadow_enabled": game.get_node("Sun").shadow_enabled,
		"shadow_distance": game.get_node("Sun").directional_shadow_max_distance,
		"physics_interpolation": physics_interpolation,
		"max_physics_steps_per_frame": Engine.max_physics_steps_per_frame,
		"batching_enabled": game.unit_batches_enabled,
		"shared_paths": game.get_node("PathBudget").shared_paths_enabled,
		"static_motion": game.get_node("StaticMotionGrid").fast_path_enabled}
	await _populate("cavalry" if cavalry_only else "mixed")
	if not failures.is_empty():
		await _finish()
		return
	game.camera_rig.focus_at(Vector3.ZERO, true)
	game.camera_rig.zoom_target = 62.0
	game.camera.size = 62.0
	await create_timer(1.0 if short_check else 6.0).timeout
	_command_armies()
	await _measure("opening_orders", 1.5 if short_check else 5.0)
	await _measure("sustained_overview", 2.0 if short_check else sustained_seconds)
	game.camera_rig.focus_at(Vector3(0, 0, -6.5), true)
	game.camera_rig.zoom_target = 37.0
	game.camera.size = 37.0
	await _measure("interactive_close", 2.0 if short_check else 20.0)
	await _finish()

func _populate(_composition: String) -> void:
	game.select_entities([])
	game.control_groups.clear()
	game.get_node("EffectPool").reset_all()
	game.get_node("ProjectilePool").reset_all()
	for unit: Node in game.unit_container.get_children(): unit.queue_free()
	await physics_frame
	await physics_frame
	var nav_map: RID = game.get_world_3d().navigation_map
	var occupied: Array[Dictionary] = []
	print("BATTLE_600_NAV iteration=", NavigationServer3D.map_get_iteration_id(nav_map),
		" polygons=", game.get_node("ConstructionNavigation").compact_polygon_count,
		" probe=", NavigationServer3D.map_get_closest_point(nav_map, Vector3(-30, 0, -20)))
	for player: PlayerState in game.players:
		player.farmers = 0
		player.military_supply = 0
		player.reserved_farmers = 0
		player.reserved_military_supply = 0
		player.complete_upgrade(BalanceCatalog.upgrade("army_capacity_2"))
		var roster: Array[String] = []
		if cavalry_only:
			for index: int in 75: roster.append("knight" if index % 2 == 0 else "light_cavalry")
		else:
			for kind: String in mixed_roster:
				for index: int in int(mixed_roster[kind]): roster.append(kind)
		roster.shuffle()
		var sign_x := -1.0 if player.alliance_id == game.get_player(0).alliance_id else 1.0
		var lane := (float(player.owner_id % 4) - 1.5) * 13.0
		for index: int in roster.size():
			@warning_ignore("integer_division")
			var at := Vector3(sign_x * (7.0 + (index / 5) * 2.6), 0, lane + (index % 5 - 2) * 2.6)
			at = _spawn_position(at, BalanceCatalog.unit(roster[index]).radius, occupied)
			if not at.is_finite():
				_check(false, "fixture cannot fit separated units on walkable ground")
				return
			var unit: BattleUnit = game.spawn_unit(roster[index], player.owner_id, at)
			_check(unit.global_position.distance_squared_to(at) < 0.001, "spawn retains its validated position")
			occupied.append({"at": at, "radius": unit.radius})
			unit.hp *= health_multiplier
			unit.max_hp *= health_multiplier
			unit.hold()
			unit.damaged.connect(_record_damage)
		_check(game.owned_entities(player.owner_id, "units").size() == 75, "owner %d has 75 live units" % player.owner_id)
		_check(player.military_supply <= player.get_supply_limit(), "owner %d roster fits production supply cap" % player.owner_id)
	_check(get_nodes_in_group("units").size() == 600, "exactly 600 native units spawned")
	game.select_army()
	print("BATTLE_600_SPAWN first=", occupied.front().at, " last=", occupied.back().at)

func _spawn_position(desired: Vector3, radius: float, occupied: Array[Dictionary]) -> Vector3:
	# Fixture placement: search a bounded ring of full-body-clear, separated sites.
	# Never silently project an army to the same nearest point on an unready map.
	var navigation: ConstructionNavigation = game.get_node("ConstructionNavigation")
	for ring: int in 9:
		for slot: int in (1 if ring == 0 else ring * 8):
			var angle := slot * TAU / maxf(1.0, ring * 8.0)
			var at := desired + Vector3(cos(angle), 0, sin(angle)) * ring * 1.3
			if not navigation.has_clear_corridor(at, at, radius): continue
			var clear := true
			for existing: Dictionary in occupied:
				if at.distance_squared_to(existing.at) < pow(radius + float(existing.radius) + 0.1, 2.0):
					clear = false
					break
			if clear: return at
	return Vector3.INF

func _record_damage(entity: Node3D, amount: float) -> void:
	damage_events += 1
	damage_amount += amount
	unique_victims[entity.entity_id] = true

func _command_armies() -> void:
	for player: PlayerState in game.players:
		var sign_x := -1.0 if player.alliance_id == game.get_player(0).alliance_id else 1.0
		var lane := (float(player.owner_id % 4) - 1.5) * 13.0
		var army: Array = game.owned_entities(player.owner_id, "units")
		var focused: BattleUnit
		if focus_fire:
			var nearest := INF
			for candidate: BattleUnit in get_nodes_in_group("units"):
				if candidate.alliance_id == player.alliance_id: continue
				var distance: float = candidate.position.distance_squared_to(army[0].position)
				if distance < nearest:
					nearest = distance
					focused = candidate
		_submit_move(army, Vector3(-sign_x * 4.0, 0, lane), true, "opening_focus" if focus_fire else "opening", focused)

func _submit_move(army: Array, at: Vector3, assault: bool, label: String, focused: BattleUnit = null) -> void:
	if army.is_empty(): return
	var owner: int = army[0].owner_id
	var command := {"kind": "move", "units": army.map(func(u: BattleUnit): return u.entity_id),
		"seq": game.next_command_sequence(owner), "at": game.vector_data(at), "attack_move": assault}
	if focused != null:
		command.kind = "attack"
		command.target = focused.entity_id
	var since := Time.get_ticks_usec()
	var response: Dictionary = game.submit_command(command, owner)
	_check(response.ok, "native command submission accepted for " + label)
	var record := {"label": label, "owner": owner, "units": army.size(), "submitted_usec": since,
		"submit_call_ms": (Time.get_ticks_usec() - since) / 1000.0, "intent_ms": -1.0,
		"first_motion_ms": -1.0, "all_routes_ready_ms": -1.0, "tick_submitted": game.simulation_tick}
	orders.append(record)
	var origins: Array[Vector3] = []
	for unit: BattleUnit in army: origins.append(unit.global_position)
	watching.append({"record": record, "army": army, "origins": origins})

func _observe_interaction(now: int) -> void:
	for watch: Dictionary in watching.duplicate():
		var record: Dictionary = watch.record
		var elapsed_ms := (now - int(record.submitted_usec)) / 1000.0
		if record.intent_ms < 0.0 and game.simulation_tick > int(record.tick_submitted) and game.command_bus.pending.is_empty():
			record.intent_ms = elapsed_ms
		var ready: bool = record.intent_ms >= 0.0
		for index: int in watch.army.size():
			if not is_instance_valid(watch.army[index]): continue
			var unit: BattleUnit = watch.army[index]
			if not unit.alive: continue
			if record.first_motion_ms < 0.0 and unit.global_position.distance_squared_to(watch.origins[index]) > 0.0025:
				record.first_motion_ms = elapsed_ms
			var budget: PathBudget = game.get_node("PathBudget")
			ready = ready and not budget.has_pending(unit)
		if ready and record.all_routes_ready_ms < 0.0: record.all_routes_ready_ms = elapsed_ms
		if (ready and record.first_motion_ms >= 0.0) or elapsed_ms > 5000.0: watching.erase(watch)
	if camera_started > 0 and game.camera_rig.position.distance_squared_to(camera_origin) > 0.0001:
		camera_samples.append((now - camera_started) / 1000.0)
		camera_started = 0
	if camera_release_at > 0 and now >= camera_release_at:
		Input.action_release("rts_pan_right")
		Input.action_release("rts_pan_left")
		camera_release_at = 0

func _measure(label: String, seconds: float) -> void:
	var frame_ms: Array[float] = []
	var render_cpu: Array[float] = []
	var render_gpu: Array[float] = []
	var setup_cpu: Array[float] = []
	var tick_steps: Array[float] = []
	var monitors: Array[Dictionary] = []
	var since := Time.get_ticks_usec()
	var previous := since
	var start_tick: int = game.simulation_tick
	var previous_tick := start_tick
	var start_units := get_nodes_in_group("units").size()
	var start_damage := damage_events
	var start_amount := damage_amount
	var next_monitor := since
	var next_interaction := since + (400000 if short_check else 2000000)
	var interaction_index := 0
	var sample_cost_usec := 0
	var window_started := since
	var window_frames := 0
	probe.begin_sample()
	while Time.get_ticks_usec() - since < int(seconds * 1000000.0):
		await process_frame
		var now := Time.get_ticks_usec()
		frame_ms.append((now - previous) / 1000.0)
		window_frames += 1
		previous = now
		tick_steps.append(float(game.simulation_tick - previous_tick))
		previous_tick = game.simulation_tick
		render_cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid()))
		render_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
		setup_cpu.append(RenderingServer.get_frame_setup_time_cpu())
		_observe_interaction(now)
		if label == "interactive_close" and now >= next_interaction:
			next_interaction = now + (600000 if short_check else 2500000)
			var army: Array = game.owned_entities(game.local_owner_id, "units").slice(0, 24)
			var attack := interaction_index % 2 == 1
			_submit_move(army, Vector3(1 if attack else -9, 0, -19.5 if attack else -28), attack, "interactive_%d" % interaction_index)
			camera_origin = game.camera_rig.position
			camera_started = Time.get_ticks_usec()
			camera_release_at = camera_started + 200000
			Input.action_press("rts_pan_right" if interaction_index % 2 == 0 else "rts_pan_left")
			interaction_index += 1
		if now >= next_monitor:
			next_monitor = now + 1000000
			var units: Array = get_nodes_in_group("units")
			var alive := 0
			var visible := 0
			var moving := 0
			var winding_up := 0
			var congestion_waiting := 0
			for unit: BattleUnit in units:
				if not unit.alive: continue
				alive += 1
				if unit.visible and game.camera.is_position_in_frustum(unit.global_position + Vector3.UP): visible += 1
				if unit.velocity.length_squared() > 0.01: moving += 1
				if not unit.attack_windup.is_stopped(): winding_up += 1
				if unit._congestion_wait > 0.0: congestion_waiting += 1
			monitors.append({"seconds": (now - since) / 1000000.0, "alive": alive, "visible": visible,
				"window_seconds": (now - window_started) / 1000000.0, "window_fps": window_frames * 1000000.0 / maxi(1, now - window_started),
				"moving": moving, "winding_up": winding_up, "damage_events": damage_events - start_damage,
				"congestion_waiting": congestion_waiting,
				"projectiles": game.get_node("ProjectilePool").active_count(),
				"effects": game.get_node("EffectPool").active_count(),
				"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
				"motion_fast_steps": game.get_node("StaticMotionGrid").fast_steps,
				"motion_native_steps": game.get_node("StaticMotionGrid").native_steps,
				"corridor_cache_hits": game.get_node("ConstructionNavigation").corridor_cache_hits,
				"physics_monitor_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
				"navigation_monitor_ms": Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0})
			window_started = now
			window_frames = 0
			sample_cost_usec += Time.get_ticks_usec() - now
	var duration := (Time.get_ticks_usec() - since) / 1000000.0
	var logic: Array[float] = probe.end_sample()
	var stats := _distribution(frame_ms)
	var observed_tps: float = (game.simulation_tick - start_tick) / duration
	var stalled_100 := frame_ms.filter(func(ms: float): return ms > 100.0).size()
	var phase := {"name": label, "duration_s": duration, "frames": frame_ms.size(), "fps": frame_ms.size() / duration,
		"frame_ms": stats, "physics_logic_ms": _distribution(logic), "path_query_ms": _distribution(probe.path_query_ms),
		"path_queries_per_tick": _distribution(probe.path_query_count), "root_render_cpu_ms": _distribution(render_cpu),
		"root_render_gpu_ms": _distribution(render_gpu), "render_setup_cpu_ms": _distribution(setup_cpu),
		"physics_steps_per_frame": _distribution(tick_steps), "ticks": game.simulation_tick - start_tick,
		"tps": observed_tps, "simulation_speed_ratio": observed_tps / 30.0,
		"frames_over_50ms": frame_ms.filter(func(ms: float): return ms > 50.0).size(), "frames_over_100ms": stalled_100,
		"frames_over_250ms": frame_ms.filter(func(ms: float): return ms > 250.0).size(),
		"starting_units": start_units, "ending_units": get_nodes_in_group("units").size(),
		"damage_events": damage_events - start_damage, "damage_amount": damage_amount - start_amount,
		"monitor_sampling_total_ms": sample_cost_usec / 1000.0, "monitors": monitors,
		"acceptance": {"minimum_fps_at_least_10": frame_ms.size() / duration >= 10.0,
			"target_fps_at_least_20": frame_ms.size() / duration >= 20.0,
			"minimum_frame_p95_at_most_100ms": stats.p95 <= 100.0, "target_frame_p95_at_most_50ms": stats.p95 <= 50.0,
			"tps_at_least_29": observed_tps >= 29.0, "no_250ms_stall": stats.max <= 250.0}}
	phases.append(phase)
	_check(not logic.is_empty() and logic.size() >= game.simulation_tick - start_tick - 1, "every physics tick has a logic sample: " + label)
	_check(damage_events > start_damage, "real damage occurred during " + label)
	_check(Engine.max_fps == 0, "measurement stays uncapped")
	if not natural_health:
		_check(monitors.all(func(s: Dictionary): return s.alive == 600), "600 units stay alive throughout " + label)
	print("BATTLE_600_PHASE ", run_id, " ", label, " fps=", phase.fps, " p95_ms=", stats.p95,
		" max_ms=", stats.max, " tps=", observed_tps, " logic_p95_ms=", phase.physics_logic_ms.p95,
		" gpu_p95_ms=", phase.root_render_gpu_ms.p95, " damage=", phase.damage_events)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(benchmark_output.path_join(run_id + "-" + label + ".png"))

func _write_report() -> void:
	Input.action_release("rts_pan_right")
	Input.action_release("rts_pan_left")
	var report := {"schema": 1, "run_id": run_id, "rendered": DisplayServer.get_name() != "headless",
		"harness_check": short_check, "debug_build": OS.is_debug_build(), "editor_feature": OS.has_feature("editor"),
		"godot": Engine.get_version_info().string, "renderer": RenderingServer.get_current_rendering_method(),
		"gpu": RenderingServer.get_video_adapter_name(), "viewport": str(root.get_visible_rect().size),
		"quality": quality, "seed": 1309600, "mode": mode, "roster_per_owner": {"knight": 38, "light_cavalry": 37} if cavalry_only else mixed_roster,
		"health_multiplier": health_multiplier, "bots": false, "networked": false, "workers": 0,
		"focus_fire": focus_fire,
		"sustained_seconds": sustained_seconds, "fps_minimum": 10, "fps_target": 20,
		"configured_fps_limit": configured_fps_limit, "configured_vsync": configured_vsync,
		"benchmark_fps_limit": Engine.max_fps, "checks": checks, "failures": failures, "phases": phases,
		"orders": orders, "camera_response_ms": _distribution(camera_samples), "unique_damaged_units": unique_victims.size(),
		"metric_notes": "Frame intervals are wall time between rendered process frames; physics_logic brackets SceneTree callbacks only, excluding PhysicsServer work outside them. Root viewport render CPU/GPU and frame setup use native RenderingServer timing and are not additive with the physics monitor. Input response is synthetic action/command submission to an observed updated frame, excluding OS mouse/keyboard and display latency. Route-ready means no pending request after command consumption; attack pursuit can directly steer instead. Opening first motion can be combat movement. Acceptance thresholds are declared benchmark criteria, not universal playability guarantees. Harness assertions validate evidence integrity, not FPS acceptance."}
	FileAccess.open(benchmark_output.path_join(run_id + ".json"), FileAccess.WRITE).store_string(JSON.stringify(report, "  "))

func _watchdog() -> void:
	if finalized: return
	_check(false, "600-unit benchmark exceeded 180 seconds of wall time")
	await _finish()
