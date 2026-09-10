extends SceneTree
## Stability, not a frame-rate benchmark. Native maps, damage, HP, 30 TPS and audio.
## Reuses the fixed army compositions and placement of skirmish_stress_test.
const STRESS_FIXTURE = preload("res://tests/skirmish_stress_test.gd")
const ROUNDS: Array[Dictionary] = [
	{"mode": "1v1", "composition": "mixed", "units": 104},
	{"mode": "2v2", "composition": "mixed", "units": 208},
	{"mode": "2v2", "composition": "maximum_light", "units": 280},
	{"mode": "2v2", "composition": "maximum_light", "units": 280},
]
var game: Node3D
var checks: int = 0
var failures: Array[String] = []
var rounds: Array[Dictionary] = []
var lobby_samples: Array[Dictionary] = []
var dead_units: int = 0
var damage_events: int = 0
var projectiles_seen: Dictionary = {}
var started_msec: int
var completed: bool = false
var session: Node

func _initialize() -> void:
	_run.call_deferred()

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("CRASH_STABILITY_FAIL ", label)

func _ticks(count: int) -> void:
	var until: int = Engine.get_physics_frames() + count
	while Engine.get_physics_frames() < until:
		await physics_frame
		await process_frame

func _run() -> void:
	started_msec = Time.get_ticks_msec()
	create_timer(170.0, true, false, true).timeout.connect(func():
		if not completed:
			printerr("CRASH_STABILITY_TIMEOUT")
			quit(3)
	)
	session = root.get_node("Session")
	AudioServer.set_bus_mute(0, true)
	_check(AudioServer.get_driver_name() == "WASAPI", "real Windows WASAPI mixer remains active under process-local mute")
	_check(DisplayServer.get_name() != "headless", "stability run uses native rendered scenes")
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	_check(Engine.physics_ticks_per_second == 30 and Engine.time_scale == 1.0, "production thirty-Hz clock and unscaled time")
	seed(940712)
	change_scene_to_file("res://scenes/lobby.tscn")
	await scene_changed
	await _ticks(20)
	lobby_samples.append(_sample_lobby())
	for index: int in range(ROUNDS.size()):
		await _round(index, ROUNDS[index])
	_check(rounds.size() == ROUNDS.size(), "all declared rounds reached release and lobby assertions")
	_check(dead_units > 0 and damage_events > 0, "native combat inflicted damage and cumulative casualties")
	_check(projectiles_seen.has("arrow") and projectiles_seen.has("stone") and projectiles_seen.has("cannon"), "real combat launched all three projectile kinds")
	if lobby_samples.size() == ROUNDS.size() + 1:
		var warm: Dictionary = lobby_samples[-2]
		var last: Dictionary = lobby_samples[-1]
		_check(last.nodes == warm.nodes, "repeated 2v2 teardown returns to identical lobby node count")
		_check(last.orphans == 0 and warm.orphans == 0, "no orphan nodes remain after either 2v2 teardown")
		_check(last.resources == warm.resources, "identical warmed 280-unit rounds return to the same resource count")
		# Native renderer/allocator caches can retain capacity even after all
		# nodes and resources are released. Report bytes without calling a
		# permissive memory threshold proof that no leak exists.
	completed = true
	var report := {"ok": failures.is_empty(), "checks": checks, "failures": failures, "rounds": rounds,
		"lobby_samples": lobby_samples, "deaths": dead_units, "damage_events": damage_events,
		"projectile_kinds": projectiles_seen.keys(), "wall_seconds": (Time.get_ticks_msec() - started_msec) / 1000.0,
		"audio": AudioServer.get_driver_name(), "renderer": RenderingServer.get_current_rendering_method(),
		"physics_tps": Engine.physics_ticks_per_second, "time_scale": Engine.time_scale,
		"conditions": "Real maps; unchanged 42-unit mixed army or 60 infantry plus 10 farmers per owner, population derived from current resources; fixture units/gold only; no health/damage/cooldown changes; no FPS claims with another player process active."}
	var output := FileAccess.open("res://artifacts/crash_stability_results.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "  "))
	output.close()
	print("CRASH_STABILITY_RESULT ", JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)

func _round(index: int, config: Dictionary) -> void:
	print("CRASH_STABILITY_ROUND_START ", index, " ", config.mode, " ", config.composition)
	session.start_offline(config.mode)
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.bots.clear()
	game.camera_rig.edge_scroll = false
	game.camera_rig.focus_at(Vector3.ZERO, true)
	game.camera_rig.zoom_target = 48.0
	game.camera.size = 48.0
	_check(game.players.size() == (4 if config.mode == "2v2" else 2), "round %d loads native %s owners" % [index, config.mode])
	var nav: ConstructionNavigation = game.get_node("ConstructionNavigation")
	var deadline: int = Time.get_ticks_msec() + 10000
	while (nav.is_rebuilding() or not game.find_recruit_position("farmer", game.headquarters).is_finite()) and Time.get_ticks_msec() < deadline:
		await _ticks(1)
	_check(not nav.is_rebuilding(), "round %d finishes initial authored navigation publication" % index)
	var site_at: Vector3 = game.find_build_location(0, "barracks", game.headquarters.position)
	_check(site_at.is_finite(), "round %d has legal native barracks placement" % index)
	if not site_at.is_finite(): return
	await _populate(config, site_at)
	var worker: BattleUnit = game.owned_entities(0, "units").filter(func(unit): return unit.unit_type == "farmer")[0]
	var before_gold: int = game.gold
	var placed: Dictionary = game.command_bus.execute({"kind": "build", "building_type": "barracks",
		"units": [worker.entity_id], "at": game.vector_data(site_at)}, 0)
	_check(placed.ok and game.gold == before_gold - BalanceCatalog.building("barracks").cost, "round %d pays for native worker construction" % index)
	if not placed.ok: return
	var building: BattleBuilding = game.entities_by_id[placed.entity_id]
	var begin_tick: int = game.simulation_tick
	var begin_time: float = game.elapsed
	var begin_deaths: int = dead_units
	var begin_damage: int = damage_events
	var begin_rebuilds: int = nav.rebuild_count
	var peak_projectiles: int = 0
	var fight_end: float = game.elapsed + 22.0
	while game.elapsed < fight_end:
		await _ticks(1)
		peak_projectiles = maxi(peak_projectiles, game.get_node("ProjectilePool").active_count())
		for projectile: ProjectileFlight in game.get_node("ProjectilePool").active_flights:
			projectiles_seen[projectile._kind] = true
	_check(building.is_constructed and building.construction_progress == 1.0, "round %d completes fifteen seconds of actual worker construction" % index)
	_check(damage_events > begin_damage and dead_units > begin_deaths, "round %d has native mixed battle damage and deaths" % index)
	_check(absf((game.elapsed - begin_time) / (game.simulation_tick - begin_tick) - 1.0 / 30.0) < 0.000001, "round %d preserves one-thirtieth-second authoritative steps" % index)
	if building.is_constructed:
		var removed: Dictionary = game.command_bus.execute({"kind": "demolish", "target": building.entity_id}, 0)
		_check(removed.ok and not building.alive, "round %d removes constructed building through native demolition" % index)
	else:
		game.command_bus.execute({"kind": "cancel_site", "target": building.entity_id}, 0)
	await _ticks(2)
	_check(nav.rebuild_count > begin_rebuilds, "round %d rebuilds dynamic navigation after demolition" % index)
	var exit_at: Vector3 = game.find_build_location(0, "defense_tower", game.headquarters.position)
	_check(exit_at.is_finite(), "round %d reserves a legal new site for teardown-during-build" % index)
	var attack_deadline: float = game.elapsed + 4.0
	while game.get_node("ProjectilePool").active_count() == 0 and game.elapsed < attack_deadline:
		await _ticks(1)
	var in_flight: int = game.get_node("ProjectilePool").active_count()
	var audio_refs: Array[WeakRef] = game.get_node("Audio")._playbacks.duplicate()
	_check(in_flight > 0 and audio_refs.any(func(ref): return ref.get_ref() != null), "round %d starts teardown with real projectiles and audio playbacks active" % index)
	var exit_site: Dictionary = game.command_bus.execute({"kind": "build", "building_type": "defense_tower",
		"units": [worker.entity_id], "at": game.vector_data(exit_at)}, 0) if exit_at.is_finite() else {"ok": false}
	_check(exit_site.ok and nav.is_rebuilding(), "round %d starts teardown with construction worker task in flight" % index)
	var retired: Array[WeakRef] = _capture_battle_references()
	if nav._job != null: retired.append(weakref(nav._job))
	var summary := {"index": index, "mode": config.mode, "composition": config.composition, "starting_units": config.units,
		"ending_units": get_nodes_in_group("units").size(), "deaths": dead_units - begin_deaths,
		"damage_events": damage_events - begin_damage, "peak_projectiles": peak_projectiles, "projectiles_at_exit": in_flight,
		"construction_complete": building.construction_progress == 1.0, "navigation_rebuilds": nav.rebuild_count,
		"worker_task_at_exit": nav.is_rebuilding(), "release_watch_count": retired.size()}
	game.return_to_menu()
	await scene_changed
	game = null
	await _ticks(20)
	_check(current_scene.scene_file_path == "res://scenes/lobby.tscn", "round %d returns through production main-menu flow" % index)
	_check(retired.all(func(ref): return ref.get_ref() == null), "round %d releases game, units, agents, buildings, projectiles and navigation job" % index)
	_check(audio_refs.all(func(ref): return ref.get_ref() == null), "round %d releases every observed native audio playback" % index)
	lobby_samples.append(_sample_lobby())
	if index == 0:
		# Exercise the real pause/restart path in addition to changing maps via lobby.
		session.start_offline("1v1")
		await scene_changed
		var prior: WeakRef = weakref(current_scene)
		current_scene.tests_running = true
		await _ticks(3)
		paused = true
		current_scene.restart()
		await scene_changed
		_check(not paused and prior.get_ref() == null, "pause and native restart release the previous battlefield")
		await _ticks(3)
		current_scene.return_to_menu()
		await scene_changed
		await _ticks(3)
	rounds.append(summary)
	print("CRASH_STABILITY_ROUND_DONE ", JSON.stringify(summary))

func _populate(config: Dictionary, site_at: Vector3) -> void:
	game.select_entities([])
	game.control_groups.clear()
	for unit: Node in game.unit_container.get_children(): unit.queue_free()
	await _ticks(2)
	for player: PlayerState in game.players:
		player.farmers = 0
		player.military_supply = 0
		player.reserved_farmers = 0
		player.reserved_military_supply = 0
		player.gold = 5000
	var map: RID = game.get_world_3d().navigation_map
	for player: PlayerState in game.players:
		var sign_z: float = 1.0 if player.alliance_id == 0 else -1.0
		var lane: float = (-12.0 if player.owner_id % 2 == 0 else 12.0) if config.mode == "2v2" else 0.0
		var roster: Array[String] = []
		if config.composition == "mixed":
			for kind: String in STRESS_FIXTURE.MIXED_COUNTS:
				for count: int in range(STRESS_FIXTURE.MIXED_COUNTS[kind]): roster.append(kind)
		else:
			for count: int in range(60): roster.append("swordsman" if count % 2 == 0 else "archer")
		var expected_supply: int = 0
		for index: int in range(roster.size()):
			expected_supply += BalanceCatalog.unit(roster[index]).supply
			var at := Vector3(lane + (float(index % 8) - 3.5) * 2.0, 0, sign_z * (12.0 + float(index / 8) * 2.0))
			var unit: BattleUnit = game.spawn_unit(roster[index], player.owner_id, NavigationServer3D.map_get_closest_point(map, at))
			unit.died.connect(_on_death)
			unit.damaged.connect(_on_damage)
			unit.issue_move(Vector3(lane * 0.45 + (index % 5 - 2) * 1.6, 0, -sign_z * 3.0), true)
		var hq: BattleBuilding = game.owned_entities(player.owner_id, "buildings")[0]
		var mines: Array[Node] = get_nodes_in_group("resource_veins")
		mines.sort_custom(func(a: Node3D, b: Node3D): return a.position.distance_squared_to(hq.position) < b.position.distance_squared_to(hq.position))
		for index: int in range(10):
			var mine: ResourceVein = mines[0 if index < 6 else 1]
			var at: Vector3 = mine.position + Vector3(cos(index * TAU / 6.0), 0, sin(index * TAU / 6.0)) * 4.0
			if player.owner_id == 0 and index == 0:
				at = site_at + Vector3(BalanceCatalog.building("barracks").size.x * 0.5 + 1.5, 0, 0)
			var worker: BattleUnit = game.spawn_unit("farmer", player.owner_id, NavigationServer3D.map_get_closest_point(map, at))
			worker.died.connect(_on_death)
			worker.damaged.connect(_on_damage)
			if player.owner_id != 0 or index != 0: worker.issue_gather(mine)
		_check(player.farmers == 10 and player.military_supply == expected_supply, "fixture owner %d accounts for the unchanged roster using current population data" % player.owner_id)
	_check(get_nodes_in_group("units").size() == int(config.units), "fixture native unit count is %d" % config.units)
	_check(get_nodes_in_group("units").all(func(unit): return unit.max_hp == BalanceCatalog.unit(unit.unit_type).hp), "fixture retains original unit HP without durability multipliers")
	game.select_army()

func _on_death(_unit: Node3D) -> void:
	dead_units += 1

func _on_damage(_unit: Node3D, _amount: float) -> void:
	damage_events += 1

func _capture_battle_references() -> Array[WeakRef]:
	var references: Array[WeakRef] = [weakref(game), weakref(game.get_node("PathBudget")), weakref(game.get_node("ConstructionNavigation")), weakref(game.get_node("Audio"))]
	for unit: BattleUnit in game.unit_container.get_children():
		references.append(weakref(unit))
		references.append(weakref(unit.navigation_agent))
	for branch: Node in [game.get_node("Buildings"), game.effect_container, game.get_node("ProjectilePool")]:
		for child: Node in branch.get_children(): references.append(weakref(child))
	for flight: ProjectileFlight in game.get_node("ProjectilePool").active_flights:
		references.append(weakref(flight))
	return references

func _sample_lobby() -> Dictionary:
	return {"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"memory_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"video_memory_bytes": int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))}
