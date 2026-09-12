extends SceneTree
## Real authored map, native queries, RVO and collision; regression metrics for
## straight paths, passed waypoints, mixed formations and topology publication.

var game: Node3D
var navigation: ConstructionNavigation
var budget: PathBudget
var checks: int = 0
var failures: Array[String] = []
var metrics: Dictionary = {}

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func step(count: int = 1) -> void:
	for i in count:
		await physics_frame
		await process_frame
		check(budget.resolved_this_tick <= budget.queries_per_tick, "route resolutions stay inside the tick budget")

func sync() -> void:
	while navigation.is_rebuilding(): await step()
	NavigationServer3D.map_force_update(game.get_world_3d().navigation_map)
	await step(6)

func _run() -> void:
	create_timer(100.0, true, false, true).timeout.connect(func(): quit(3))
	seed(91821)
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	game.set_placing(false)
	navigation = game.get_node("ConstructionNavigation")
	budget = game.get_node("PathBudget")
	await sync()
	game.set_running(true)
	_open_routes()
	_passed_waypoint()
	await _topology_changes()
	await _march("infantry", ["swordsman", "shield_guard"])
	await _march("cavalry", ["knight", "light_cavalry"])
	await _march("mixed", ["swordsman", "knight", "archer", "light_cavalry"])
	metrics["checks"] = checks
	metrics["failures"] = failures
	FileAccess.open("res://artifacts/movement_navigation.json", FileAccess.WRITE).store_string(JSON.stringify(metrics, "\t"))
	print("MOVEMENT_NAVIGATION ", JSON.stringify(metrics))
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)

func _open_routes() -> void:
	var unit: BattleUnit = game.spawn_unit("knight", 0, Vector3.ZERO)
	unit.set_physics_process(false)
	unit.navigation_agent.avoidance_enabled = false
	var cells: Array = navigation._walkable_cells.keys()
	var rng := RandomNumberGenerator.new()
	rng.seed = 55431
	var count: int = 0
	var native_detours: int = 0
	var resolved_detours: int = 0
	var worst_native: float = 1.0
	var before: int = budget.total_queries
	for sample in 1600:
		var a: Vector2i = cells[rng.randi_range(0, cells.size() - 1)]
		var b: Vector2i = cells[rng.randi_range(0, cells.size() - 1)]
		var start := Vector3(a.x + .5, 0, a.y + .5)
		var goal := Vector3(b.x + .5, 0, b.y + .5)
		if start.distance_to(goal) < 5 or not navigation.has_clear_corridor(start, goal, unit.radius): continue
		count += 1
		var native := NavigationServer3D.map_get_path(game.get_world_3d().navigation_map, start, goal, true)
		var length: float = 0.0
		for i in range(1, native.size()): length += native[i - 1].distance_to(native[i])
		var ratio: float = length / start.distance_to(goal)
		worst_native = maxf(worst_native, ratio)
		if ratio > 1.01: native_detours += 1
		unit.position = start
		budget.cancel(unit)
		budget.request(unit, goal)
		budget._physics_process(1.0 / 30.0)
		var path := budget.current_path(unit)
		var straight: bool = path.size() == 2 and path[0].is_equal_approx(start) and path[-1].is_equal_approx(goal)
		if not straight: resolved_detours += 1
		check(straight, "certified open route %d is the exact straight segment" % count)
		check(budget.next_position(unit).is_equal_approx(goal), "open route %d immediately steers towards its destination" % count)
	check(count > 150 and native_detours > 0, "real-map sample reproduces native polygon-route detours")
	check(budget.total_queries == before, "certified straight movement consumes no native search")
	metrics["open_routes"] = {"samples": count, "native_detours": native_detours, "native_worst_ratio": worst_native, "resolved_detours": resolved_detours}
	unit.queue_free()

func _passed_waypoint() -> void:
	var corridor := PathCorridor.new()
	corridor.reset(PackedVector3Array([Vector3(0,0,-6), Vector3(0,0,-1), Vector3(0,0,6)]), Vector3(0,0,-6))
	var at := Vector3(.9,0,1)
	check(navigation.has_clear_corridor(at, Vector3(0,0,6), .78), "displaced-waypoint fixture has body clearance")
	var next := corridor.next_position(at, .4, .22, 1.6, navigation, .78)
	check(next.z > at.z, "a laterally displaced unit never returns to a passed open waypoint")
	var previous_index := corridor.index
	next = corridor.next_position(Vector3(.7,0,2), .4, .22, 1.6, navigation, .78)
	check(corridor.index >= previous_index and next.z > 2, "the route cursor advances monotonically")

func _topology_changes() -> void:
	var unit: BattleUnit = game.spawn_unit("knight", 0, Vector3(-8,0,0))
	unit.set_physics_process(false)
	unit.navigation_agent.avoidance_enabled = false
	unit.issue_move(Vector3(8,0,0))
	await step(2)
	check(budget.current_path(unit).size() == 2, "construction fixture initially takes the direct route")
	budget.next_position(unit) # Prime this tick's sample before changing topology.
	var tower: BattleBuilding = game.spawn_building("defense_tower", 0, Vector3.ZERO)
	tower.set_physics_process(false)
	navigation.refresh()
	check(budget.next_position(unit).is_equal_approx(unit.position), "a new footprint stops an old path in the same tick")
	budget._physics_process(1.0 / 30.0)
	check(budget.has_pending(unit) and budget.resolved_this_tick == 0, "search waits for mesh and server publication")
	await sync()
	var next := budget.next_position(unit)
	check(not next.is_equal_approx(unit.destination) and not budget.has_pending(unit), "published obstacle produces a real detour")
	var corridor := PathCorridor.new()
	corridor.reset(PackedVector3Array([Vector3(-5,0,0), Vector3(-4,0,-4), Vector3(4,0,-4), Vector3(8,0,0)]), Vector3(-5,0,0))
	var bend := corridor.next_position(Vector3(-5,0,0), .4, .22, 1.6, navigation, .78)
	check(bend.z < -1 and not bend.is_equal_approx(Vector3(8,0,0)), "shortcut certification preserves a required turn around a wall")
	tower.receive_damage(tower.hp + 1)
	navigation.refresh()
	budget.next_position(unit)
	await sync()
	check(budget.next_position(unit).is_equal_approx(unit.destination), "demolition restores direct movement without another command")
	unit.queue_free()
	await step(2)

func _march(label: String, kinds: Array) -> void:
	var units: Array[BattleUnit] = []
	var lengths: Dictionary = {}
	var previous: Dictionary = {}
	var goals: Dictionary = {}
	for row in 4:
		for col in 4:
			var at := Vector3((col - 1.5) * 1.9, 0, -6.0 - row * 1.9)
			var unit: BattleUnit = game.spawn_unit(kinds[col % kinds.size()], 0, at)
			units.append(unit)
			lengths[unit.entity_id] = 0.0
			previous[unit.entity_id] = at
	game.move_formation(units, Vector3(0,0,13), false, false)
	for unit: BattleUnit in units: goals[unit.entity_id] = unit.destination
	var reversed: Array[BattleUnit] = units.duplicate()
	reversed.reverse()
	game.move_formation(reversed, Vector3(0,0,13), false, false)
	for unit: BattleUnit in units:
		check(unit.destination == goals[unit.entity_id], label + " slots are independent of selection order")
	var total_direct: float = 0.0
	for unit: BattleUnit in units: total_direct += unit.position.distance_to(unit.destination)
	var path_reversals: int = 0
	var ticks: int = 0
	var before: int = budget.total_queries
	for tick in 420:
		await step()
		ticks += 1
		var active: int = 0
		for unit: BattleUnit in units:
			lengths[unit.entity_id] += unit.position.distance_to(previous[unit.entity_id])
			previous[unit.entity_id] = unit.position
			if unit.order == BattleUnit.Order.IDLE: continue
			active += 1
			var to_goal: Vector3 = goals[unit.entity_id] - unit.position
			var route = budget._routes[unit.get_instance_id()]
			if to_goal.length() > 2.0 and navigation.has_clear_corridor(unit.position, goals[unit.entity_id], unit.radius) and (route.next - unit.position).dot(to_goal) < -0.1:
				path_reversals += 1
		if active == 0: break
	var arrived: int = 0
	var total_length: float = 0.0
	for unit: BattleUnit in units:
		total_length += lengths[unit.entity_id]
		if unit.order == BattleUnit.Order.IDLE and unit.position.distance_to(goals[unit.entity_id]) < .8: arrived += 1
	check(arrived == units.size(), label + " entire group reaches its own slots")
	check(path_reversals == 0, label + " has no backwards waypoint on a clear route")
	check(total_length / total_direct < 1.15, label + " group travel stays within fifteen percent of direct slot distances")
	# Queued formation assignment uses the preceding destination, even while
	# this command has not begun moving yet. Reordering selection stays stable.
	game.move_formation(units, Vector3(0,0,6), false, false)
	game.move_formation(units, Vector3(-10,0,6), false, true)
	for unit: BattleUnit in units:
		check(unit.waypoint_queue.size() == 1 and game._formation_origin(unit, true) == unit.waypoint_queue[0].position, label + " queued origin follows the last planned move")
	metrics[label] = {"units":units.size(),"arrived":arrived,"ticks":ticks,"path_reversals":path_reversals,"travel_ratio":total_length / total_direct,"native_queries":budget.total_queries-before}
	for unit: BattleUnit in units:
		unit.stop()
		unit.queue_free()
	await step(2)
