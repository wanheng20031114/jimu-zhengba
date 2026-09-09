extends SceneTree
## Measure one full player's command latency on the real carved battlefield.
## A bounded 70-unit fixture uses original models, collisions and native RVO.
var game: Node3D
var budget: PathBudget
var units: Array[BattleUnit] = []
var origins: Dictionary = {}
var first_path_ms: Dictionary = {}
var first_motion_ms: Dictionary = {}
var failures: Array[String] = []
var checks: int = 0

func _initialize() -> void:
	Engine.physics_ticks_per_second = 30
	Engine.time_scale = 1.0
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func _run() -> void:
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.bots.clear()
	game.get_node("IncomeTimer").stop()
	budget = game.get_node("PathBudget")
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.queue_free()
	await process_frame
	var navigation: ConstructionNavigation = game.get_node("ConstructionNavigation")
	while navigation.is_rebuilding(): await physics_frame
	for i in range(6): await physics_frame
	var cells: Array = navigation._walkable_cells.keys()
	var random := RandomNumberGenerator.new()
	random.seed = 827362
	var used: Dictionary = {}
	for i in range(70):
		var cell: Vector2i = cells[random.randi_range(0, cells.size() - 1)]
		while used.has(cell): cell = cells[random.randi_range(0, cells.size() - 1)]
		used[cell] = true
		var unit: BattleUnit = game.spawn_unit("farmer" if i >= 60 else ("swordsman" if i % 2 == 0 else "archer"), 0, Vector3(cell.x + 0.5, 0, cell.y + 0.5))
		units.append(unit)
		origins[unit.entity_id] = unit.position
	await physics_frame
	await process_frame
	var before: int = budget.total_queries
	var started_tick: int = Engine.get_physics_frames()
	var began: int = Time.get_ticks_usec()
	for unit: BattleUnit in units:
		var opposite: Vector3 = -unit.position
		opposite = NavigationServer3D.map_get_closest_point(game.get_world_3d().navigation_map, opposite)
		unit.issue_move(opposite)
		unit.issue_move(opposite)
	check(budget.total_queries == before, "seventy double-click orders publish intent with no immediate native query")
	check(budget.pending_count() == 70, "repeated orders deduplicate the real-map batch")
	var all_paths_tick: int = -1
	var query_ticks: Array[Dictionary] = []
	for tick in range(9):
		await physics_frame
		await process_frame
		var elapsed_ms: float = (Time.get_ticks_usec() - began) / 1000.0
		query_ticks.append({"tick": Engine.get_physics_frames() - started_tick, "queries": budget.queries_this_tick, "query_ms": budget.query_usec_this_tick / 1000.0})
		check(budget.queries_this_tick <= budget.queries_per_tick, "complex native routes obey the tick budget")
		for unit: BattleUnit in units:
			if not budget.has_pending(unit) and not first_path_ms.has(unit.entity_id):
				first_path_ms[unit.entity_id] = elapsed_ms
			if unit.position.distance_to(origins[unit.entity_id]) >= 0.005 and not first_motion_ms.has(unit.entity_id):
				first_motion_ms[unit.entity_id] = elapsed_ms
		if first_path_ms.size() == 70 and all_paths_tick < 0:
			all_paths_tick = Engine.get_physics_frames() - started_tick
		if first_motion_ms.size() == 70: break
	check(first_path_ms.size() == 70 and all_paths_tick <= 3, "a player's seventy real-map routes dispatch within three 30TPS ticks")
	check(first_motion_ms.size() == 70, "every real native unit starts moving after its scheduled path")
	var worst_path: float = first_path_ms.values().max() if not first_path_ms.is_empty() else INF
	var worst_motion: float = first_motion_ms.values().max() if not first_motion_ms.is_empty() else INF
	check(worst_path <= 150, "measured whole-map command-to-path latency remains below 150ms")
	var report := {"mode": game.match_config.mode, "units": 70, "checks": checks, "failures": failures,
		"path_latency_ms": first_path_ms.values(), "motion_latency_ms": first_motion_ms.values(),
		"max_path_ms": worst_path, "max_motion_ms": worst_motion, "all_paths_ticks": all_paths_tick,
		"native_query_count": budget.total_queries - before, "query_ticks": query_ticks,
		"compact_polygons": navigation.compact_polygon_count, "worker_mesh_ms": navigation.last_rebuild_usec / 1000.0}
	var file := FileAccess.open("res://artifacts/path_budget_map_%s.json" % game.match_config.mode, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("PATH_BUDGET_MAP_RESULT ", game.match_config.mode, " ", checks, " checks / ", failures.size(), " failures; path=", worst_path, "ms motion=", worst_motion, "ms ticks=", all_paths_tick)
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)
