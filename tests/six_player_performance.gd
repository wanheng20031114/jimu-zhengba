extends "res://tests/skirmish_stress_test.gd"
## Six/eight-player source benchmark using the saved SceneTree priority probe.
## No production settings, balance or match scripts are changed by this harness.
const SIX_PLAYER_MIX: Dictionary = {"swordsman": 10, "archer": 6, "knight": 4, "catapult": 2, "cannon": 2}
var _damage_events: int = 0
var _population_kind: String = "mixed"
var _player_count: int = 6

func _run() -> void:
	began_usec = Time.get_ticks_usec()
	create_timer(140.0, true, false, true).timeout.connect(_watchdog)
	mode = "3v3"
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--mode="):
			mode = argument.trim_prefix("--mode=")
	_check(mode in ["3v3", "4v4"], "benchmark mode is an authored 3v3 or 4v4 battlefield")
	if mode not in ["3v3", "4v4"]:
		await _finish()
		return
	_player_count = 8 if mode == "4v4" else 6
	var rendered: bool = DisplayServer.get_name() != "headless"
	_check(rendered or short_check, "performance values require a real Forward+ window")
	if not rendered and not short_check:
		await _finish()
		return
	seed(803036)
	var session: Node = root.get_node("Session")
	session.online = false
	session.config = session.offline_config(mode)
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	game.tests_running = true
	game.bots.clear()
	game.camera_rig.edge_scroll = false
	game.get_node("IncomeTimer").stop()
	await physics_frame
	await physics_frame
	configured_fps_limit = Engine.max_fps
	configured_vsync = DisplayServer.window_get_vsync_mode() if rendered else -1
	Engine.max_fps = 0
	if rendered:
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		DisplayServer.window_set_size(Vector2i(1600, 900))
	probe = PROFILE_PROBE.instantiate()
	game.add_child(probe)
	game.camera_rig.focus_at(Vector3.ZERO, true)
	game.camera_rig.zoom_target = 58.0
	game.camera.size = 58.0
	_check(Engine.physics_ticks_per_second == 30, "authority physics frequency remains 30 TPS")
	_check(game.players.size() == _player_count, "native %s map has %d independent owners" % [mode, _player_count])
	var deadline: int = Time.get_ticks_msec() + 15000
	while not game.find_recruit_position("farmer", game.headquarters).is_finite() and Time.get_ticks_msec() < deadline:
		await physics_frame
	_check(game.find_recruit_position("farmer", game.headquarters).is_finite(), "navigation publication completed before population")
	var maximum_only: bool = "--max-only" in OS.get_cmdline_user_args()
	if not maximum_only:
		await _populate("mixed")
		await _measure("standard_%d_military_%d_workers" % [_player_count * 24, _player_count * 10], 1.0 if short_check else SAMPLE_SECONDS)
	if not short_check or maximum_only:
		await _populate("maximum_light")
		await _measure("maximum_%d_military_%d_workers" % [_player_count * 100, _player_count * 12], 1.0 if short_check else SAMPLE_SECONDS)
	await _finish()

func _populate(composition: String) -> void:
	_population_kind = composition
	game.select_entities([])
	game.control_groups.clear()
	game.get_node("EffectPool").reset_all()
	game.get_node("ProjectilePool").reset_all()
	for unit: Node in game.unit_container.get_children():
		unit.queue_free()
	for effect: Node in game.effect_container.get_children():
		effect.queue_free()
	await physics_frame
	await physics_frame
	var nav_map: RID = game.get_world_3d().navigation_map
	var expected_population: int = 0
	for player: PlayerState in game.players:
		player.farmers = 0
		player.military_supply = 0
		player.reserved_farmers = 0
		player.reserved_military_supply = 0
		player.workforce_level = 0
		player.army_capacity_level = 0
		if composition != "mixed":
			player.complete_upgrade(BalanceCatalog.upgrade("workforce_1"))
			player.complete_upgrade(BalanceCatalog.upgrade("army_capacity_2"))
		var worker_count: int = player.get_worker_limit()
		var expected_supply: int = player.get_supply_limit()
		if composition == "mixed":
			expected_supply = 0
			for kind: String in SIX_PLAYER_MIX:
				expected_supply += SIX_PLAYER_MIX[kind] * BalanceCatalog.unit(kind).supply
		_check(player.get_supply_limit() == (50 if composition == "mixed" else 100), "owner %d has the real researched population limit" % player.owner_id)
		var sign_x: float = -1.0 if player.alliance_id == 0 else 1.0
		# Preserve the original 3v3 fixture exactly. Four-player teams instead use
		# all four actual authored front lines, paired by their native spawn Z.
		var lane: float = game.get_spawn_marker(player.owner_id).position.z if mode == "4v4" else -22.0 + float(player.owner_id % 3) * 22.0
		var roster: Array[String] = []
		if composition == "mixed":
			for kind: String in SIX_PLAYER_MIX:
				for index: int in range(int(SIX_PLAYER_MIX[kind])):
					roster.append(kind)
		else:
			for index: int in range(expected_supply):
				roster.append("swordsman" if index % 2 == 0 else "archer")
		expected_population += roster.size() + worker_count
		for index: int in range(roster.size()):
			var at := Vector3(sign_x * (13.0 + float(index / 8) * 2.4), 0, lane + (float(index % 8) - 3.5) * 2.0)
			at = NavigationServer3D.map_get_closest_point(nav_map, at)
			var unit: BattleUnit = game.spawn_unit(roster[index], player.owner_id, at)
			# Keep measured crowds at their declared population. Damage, attack
			# timing, target acquisition, pathfinding and effects remain native.
			unit.hp *= 100.0
			unit.max_hp *= 100.0
			unit.damaged.connect(_record_damage)
			unit.issue_move(Vector3(-sign_x * 3.0, 0, lane + (index % 5 - 2) * 1.6), true)
		var home: Vector3 = game.get_spawn_marker(player.owner_id).global_position
		var mines: Array[Node] = get_nodes_in_group("resource_veins")
		if mode == "4v4":
			# The nearest expansion can be a neighbour's birth mine. Use the map's
			# independently authored birth/expansion pair so all 96 workers have
			# six real mineral slots each, with no fixture-only slot contention.
			var resources: Node3D = game.get_node("MapContainer").get_child(0).get_node("Resources")
			mines.assign([resources.get_node("GoldVein%d" % player.owner_id), resources.get_node("GoldVein%d" % (player.owner_id + _player_count))])
		else:
			mines.sort_custom(func(a: Node3D, b: Node3D): return a.global_position.distance_squared_to(home) < b.global_position.distance_squared_to(home))
		for index: int in range(worker_count):
			var mine: ResourceVein = mines[0 if index < 6 else 1]
			var at: Vector3 = mine.global_position + Vector3(cos(index * TAU / 6.0), 0, sin(index * TAU / 6.0)) * 4.0
			var worker: BattleUnit = game.spawn_unit("farmer", player.owner_id, NavigationServer3D.map_get_closest_point(nav_map, at))
			worker.hp *= 100.0
			worker.max_hp *= 100.0
			worker.issue_gather(mine)
		_check(player.military_supply == expected_supply and player.farmers == worker_count, "owner %d has the declared military supply and worker count" % player.owner_id)
	_check(expected_population == _player_count * (34 if composition == "mixed" else 112), "live research resources produce the intended standard or maximum roster")
	_check(get_nodes_in_group("units").size() == expected_population, "population matches the declared %d-player load" % _player_count)
	game.select_army()
	await create_timer(1.0 if short_check else WARMUP_SECONDS).timeout

func _record_damage(_unit: Node3D, _amount: float) -> void:
	_damage_events += 1

func _measure(label: String, seconds: float) -> void:
	var damage_before: int = _damage_events
	var visible_start: int = _visible_units()
	await super._measure(label, seconds)
	var phase: Dictionary = phases.back()
	phase["damage_events"] = _damage_events - damage_before
	phase["visible_units_in_camera_at_start"] = visible_start
	phase["visible_units_in_camera_at_end"] = _visible_units()
	phase["workers_per_player"] = game.get_player(0).get_worker_limit()
	phase["military_supply_limit_per_player"] = game.get_player(0).get_supply_limit()
	phase["army_capacity_level"] = game.get_player(0).army_capacity_level
	phase["workforce_level"] = game.get_player(0).workforce_level
	phase["military_roster_per_player"] = SIX_PLAYER_MIX.duplicate() if _population_kind == "mixed" else {"swordsman": 50, "archer": 50}
	_check(short_check or int(phase.damage_events) > 0, "sample includes real combat damage events")
	_check(phase.starting_units == phase.ending_units, "durability override keeps sample population stable")

func _visible_units() -> int:
	var count: int = 0
	for unit: BattleUnit in get_nodes_in_group("units"):
		if unit.visible and game.camera.is_position_in_frustum(unit.global_position + Vector3.UP):
			count += 1
	return count

func _write_report() -> void:
	var rendered: bool = DisplayServer.get_name() != "headless"
	var report: Dictionary = {"build": NetworkProtocol.BUILD_ID, "mode": mode, "rendered": rendered,
		"harness_check_only": short_check, "godot": Engine.get_version_info().string,
		"renderer": RenderingServer.get_current_rendering_method(), "gpu": RenderingServer.get_video_adapter_name() if rendered else "headless",
		"physics_ticks_per_second": Engine.physics_ticks_per_second, "window_size": str(DisplayServer.window_get_size()) if rendered else "headless",
		"viewport_size": str(root.get_visible_rect().size), "physics_interpolation": physics_interpolation,
		"restored_settings_fps_limit_before_override": configured_fps_limit, "restored_settings_vsync_before_override": configured_vsync,
		"benchmark_fps_limit": Engine.max_fps, "benchmark_vsync": DisplayServer.window_get_vsync_mode() if rendered else -1,
		"msaa_3d": ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_3d"),
		"taa": ProjectSettings.get_setting("rendering/anti_aliasing/quality/use_taa"),
		"shadow_atlas_size": ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/size"),
		"shadow_max_distance": game.get_node("Sun").directional_shadow_max_distance if is_instance_valid(game) else 0,
		"actualbuffer_size": ProjectSettings.get_setting("rendering/limits/global_shader_variables/buffer_size"),
		"geometry_with_instance_uniforms": _shader_instance_geometry_count(),
		"camera_size": 58.0, "sample_seconds_per_phase": SAMPLE_SECONDS, "warmup_seconds_per_phase": WARMUP_SECONDS,
		"physics_metric": "physics_logic_ms brackets actual SceneTree physics callbacks with native priority markers; it excludes PhysicsServer work outside SceneTree. Cached engine physics monitor is reported separately. Neither substitutes 33.3 ms tick arrival spacing for logic cost.",
		"render_metric": "frame_ms is measured process-frame wall-clock spacing at uncapped Forward+ 1600x900, not GPU timestamp duration. Native fog/culling remains enabled; visible in-camera unit counts are reported separately from total simulated units.",
		"conditions": "Native %s map, starting HQs/towers, model detail, shadows, AA, audio, fog, gathering, attacks and navigation are unchanged. Bots/passive income are stopped to keep roster fixed. HP x100 stabilizes population only. Standard is %d mixed military +%d workers; researched cap is %d light military +%d upgraded workers. Each maximum owner completes army_capacity_2 and workforce_1 through PlayerState and reads the resulting live capacity. No network clients run in this sample. Camera remains centered at zoom 58; all four native 4v4 lanes are simulated, not necessarily all visible in that view." % [mode, _player_count * 24, _player_count * 10, _player_count * 100, _player_count * 12],
		"limitations": "Short local performance sample; no claim of an isolated workstation, GPU-exclusive timing, complete multiplayer/Bot load, or regression delta against a previous build.",
		"checks": checks, "failures": failures, "phases": phases}
	var suffix: String = "-harness" if short_check else ""
	var version_suffix: String = NetworkProtocol.BUILD_ID.replace(".", "")
	var player_label: String = "eight" if mode == "4v4" else "six"
	var file := FileAccess.open("res://artifacts/%s-player-performance-%s%s.json" % [player_label, version_suffix, suffix], FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  ") + "\n")
	file.close()

func _shader_instance_geometry_count() -> int:
	var count: int = 0
	if not is_instance_valid(game):
		return count
	for geometry: GeometryInstance3D in game.find_children("*", "GeometryInstance3D", true, false):
		for property: Dictionary in geometry.get_property_list():
			if String(property.name).begins_with("instance_shader_parameters/"):
				count += 1
				break
	return count
