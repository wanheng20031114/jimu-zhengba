extends SceneTree
## Real main-scene assault: no direct health edits, damage calls, or desktop input.
## Godot --headless --path PROJECT --script res://tests/battle_scenario.gd

var game: Node3D
var failures: Array[String] = []
var checks: int = 0
var started_usec: int = 0
var finalizing: bool = false
var probe: Node3D
var probe_entered: bool = false
var probe_crossed: bool = false
var west_destroyed: bool = false
var initial_nav_distance: float = 0.0
var traces: Array[Dictionary] = []

func _initialize() -> void:
	started_usec = Time.get_ticks_usec()
	_run.call_deferred()

func _run() -> void:
	create_timer(60.0, true, false, true).timeout.connect(_watchdog)
	seed(24571)
	await _load_battle()
	var west: Node3D = game.get_node("Buildings/WestBarracks")
	var navigation_map: RID = game.get_world_3d().navigation_map
	initial_nav_distance = NavigationServer3D.map_get_closest_point(navigation_map, west.global_position).distance_to(west.global_position)
	_check(initial_nav_distance > 1.5, "standing barracks footprint is excluded from navigation")
	# A genuine melee assault starts at the southern wall, ahead of all artillery.
	var first_wave: Array[Node3D] = []
	for index: int in range(8):
		var sword: Node3D = game.spawn_unit("swordsman", 0, Vector3(-6.5 + float(index) * 0.75, 0, -7.4))
		first_wave.append(sword)
		sword.issue_attack(west)
	var melee_deadline: float = _elapsed() + 5.0
	while west.hp == west.max_hp and _elapsed() < melee_deadline:
		await physics_frame
	_check(west.hp < west.max_hp, "real melee attacks damage the building in the authored map")
	if west.hp == west.max_hp:
		for sword: Node3D in first_wave:
			print("MELEE_CONTACT ", sword.global_position, " destination ", sword.navigation_agent.target_position, " next ", sword.navigation_agent.get_next_path_position(), " finished ", sword.navigation_agent.is_navigation_finished(), " range ", sword._within_attack_range(west), " velocity ", sword.velocity, " target ", sword.target)
	if "--melee-only" in OS.get_cmdline_user_args():
		await _finish()
		return
	# Mixed reinforcements use normal stats and real attack-move / target acquisition.
	var composition: Array[String] = []
	for index: int in range(72):
		if index < 24:
			composition.append("swordsman")
		elif index < 40:
			composition.append("knight")
		elif index < 56:
			composition.append("archer")
		elif index < 64:
			composition.append("catapult")
		else:
			composition.append("cannon")
		var at := Vector3(-13.0 + float(index % 12) * 2.0, 0, 15.0 + float(index / 12) * 1.8)
		at = NavigationServer3D.map_get_closest_point(navigation_map, at)
		game.spawn_unit(composition[index], 0, at)
	for unit: Node3D in get_nodes_in_group("friendly_units"):
		unit.issue_move(Vector3(1, 0, -4), true)
	var last_trace: int = -1
	while _elapsed() < 51.0 and not game.finished and not finalizing:
		if not west.alive and not west_destroyed:
			west_destroyed = true
			await physics_frame
			await physics_frame
			var opened_distance: float = NavigationServer3D.map_get_closest_point(navigation_map, west.global_position).distance_to(west.global_position)
			_check(game.get_node("ClearedNavigation/WestBarracks").enabled and opened_distance < 0.3, "destroyed barracks enables a connected walkable navigation patch")
			probe = game.spawn_unit("knight", 0, west.global_position + Vector3(0, 0, 6.0))
			probe.issue_move(west.global_position)
			probe.queue_move(west.global_position + Vector3(0, 0, -6.0))
		if is_instance_valid(probe) and probe.alive:
			if probe.global_position.distance_to(west.global_position) < 1.2:
				probe_entered = true
			if probe_entered and probe.global_position.z < west.global_position.z - 3.0:
				probe_crossed = true
		for unit: Node3D in get_nodes_in_group("friendly_units"):
			if unit == probe or not unit.alive or unit.order_name != "待命":
				continue
			var nearest: Node3D
			var closest: float = INF
			for building: Node3D in get_nodes_in_group("buildings"):
				if building.team != 1 or not building.alive:
					continue
				var distance: float = unit.global_position.distance_squared_to(building.global_position)
				if distance < closest:
					closest = distance
					nearest = building
			if is_instance_valid(nearest):
				unit.issue_move(nearest.get_attack_position(unit.global_position), true)
		var trace_second: int = int(_elapsed() / 10.0)
		if trace_second > last_trace:
			last_trace = trace_second
			var state := {"elapsed_s": snappedf(_elapsed(), 0.1), "friendly": game.player_count(), "enemy": game.enemy_count(), "buildings_destroyed": game.buildings_destroyed, "kills": game.kills}
			traces.append(state)
			print("BATTLE_PROGRESS ", JSON.stringify(state))
		await create_timer(0.2).timeout
	if finalizing:
		return
	_check(west_destroyed, "assault destroys the first military building without scripted damage")
	_check(probe_entered and probe_crossed, "a cavalry scout physically crosses the cleared building footprint")
	_check(game.finished and game.buildings_destroyed == 4, "mixed-army assault reaches the real victory condition")
	if game.finished:
		var stopped: bool = true
		for unit: Node3D in get_nodes_in_group("units"):
			stopped = stopped and not unit.is_physics_processing() and unit.get_node("AttackWindup").is_stopped()
		_check(stopped, "victory stops every surviving combatant and attack windup")
	# A separate real barrage tests defeat without direct damage or stat changes.
	if _elapsed() < 53.0:
		await _load_battle()
		for index: int in range(18):
			var at: Vector3 = game.headquarters.global_position + Vector3(-7.5 + float(index % 9) * 1.8, 0, -10.0 - float(index / 9) * 1.8)
			var gun: Node3D = game.spawn_unit("cannon", 1, at)
			gun.issue_attack(game.headquarters)
		var defeat_deadline: float = minf(58.0, _elapsed() + 6.0)
		while not game.finished and _elapsed() < defeat_deadline:
			await create_timer(0.1).timeout
		_check(game.finished and not game.headquarters.alive and game.buildings_destroyed < 4, "enemy cannon fire triggers the real headquarters-defeat condition")
	await _finish()

func _load_battle() -> void:
	if is_instance_valid(game):
		await game.prepare_shutdown()
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.camera_rig.edge_scroll = false
	await physics_frame
	await physics_frame
	await physics_frame

func _elapsed() -> float:
	return float(Time.get_ticks_usec() - started_usec) / 1000000.0

func _check(condition: bool, label: String) -> void:
	checks += 1
	print("%s: %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures.append(label)

func _watchdog() -> void:
	if not finalizing:
		failures.append("scenario exceeded its 60-second safety deadline")
		_finish()

func _finish() -> void:
	if finalizing:
		return
	finalizing = true
	for entity: Node in get_nodes_in_group("entities"):
		entity.set_physics_process(false)
		if entity is BattleUnit:
			entity.navigation_agent.avoidance_enabled = false
			entity.get_node("AttackWindup").stop()
	game.get_node("ProjectilePool").reset_all()
	var result := {"checks": checks, "failures": failures, "elapsed_s": _elapsed(), "traces": traces, "probe_entered": probe_entered, "probe_crossed": probe_crossed}
	var report := FileAccess.open("res://artifacts/battle_scenario.json", FileAccess.WRITE)
	report.store_string(JSON.stringify(result, "  "))
	report.close()
	print("BATTLE_SCENARIO ", JSON.stringify(result))
	await game.prepare_shutdown()
	quit(0 if failures.is_empty() else 1)
