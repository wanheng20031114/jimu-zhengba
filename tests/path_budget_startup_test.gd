extends SceneTree
## Native empty-map startup, delayed region sync and bounded blocked-path recovery.
var host: Node3D
var budget: PathBudget
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	Engine.physics_ticks_per_second = 30
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func step(count: int = 1) -> void:
	for i in range(count):
		await physics_frame
		await process_frame

func spawn(at: Vector3) -> BattleUnit:
	var unit: BattleUnit = preload("res://scenes/unit.tscn").instantiate()
	unit.unit_type = "farmer"
	unit.owner_id = 0
	unit.position = at
	host.get_node("Units").add_child(unit)
	return unit

func _run() -> void:
	change_scene_to_file("res://tests/balance_combat_host.tscn")
	await scene_changed
	host = current_scene
	budget = host.get_node("PathBudget")
	var region: NavigationRegion3D = host.get_node("NavigationRegion3D")
	region.enabled = false
	await step(6)
	check(NavigationServer3D.map_get_iteration_id(host.get_world_3d().navigation_map) > 0, "the empty map already has a nonzero native iteration")
	var unit: BattleUnit = spawn(Vector3(-10, 0, -10))
	unit.issue_move(Vector3(10, 0, 10))
	await step(3)
	check(budget.current_path(unit).is_empty(), "disabled region returns a real empty native corridor")
	check(budget.is_blocked(unit) and budget.has_pending(unit), "empty corridor explicitly retains a blocked pending intent")
	check(not budget.is_finished(unit) and unit.order == BattleUnit.Order.MOVE, "startup cannot silently complete the move order")
	var before: int = budget.total_queries
	for i in range(8):
		budget.request(unit, Vector3(10, 0, 10))
		await step()
	check(budget.total_queries == before, "unchanged empty map and repeated orders do not poll native queries")
	region.enabled = true
	await step(6)
	check(not budget.current_path(unit).is_empty(), "late region automatically resolves the original intent")
	check(budget.total_queries == before + 1, "one new map iteration dispatches exactly one recovery query")
	check(not budget.is_blocked(unit) and not budget.has_pending(unit), "resolved corridor leaves the blocked state")
	check(unit.position.distance_to(Vector3(-10, 0, -10)) > 0.05, "real unit movement starts without another player command")
	unit.stop()
	var blocked: BattleUnit = spawn(Vector3(-20, 0, -20))
	blocked.navigation_agent.navigation_layers = 2
	blocked.issue_move(Vector3(5, 0, 5))
	await step(3)
	check(budget.is_blocked(blocked), "a persistent layer mismatch is a blocked corridor")
	before = budget.total_queries
	await step(15)
	check(budget.total_queries == before, "persistent unavailable connectivity never becomes a periodic requery loop")
	blocked.issue_move(Vector3(6, 0, 6))
	await step(2)
	check(budget.total_queries == before + 1, "an explicitly changed destination receives one new attempt")
	blocked.stop()
	before = budget.total_queries
	region.navigation_layers = 3
	await step(6)
	check(not budget.is_blocked(blocked) and not budget.has_pending(blocked), "stop clears blocked-map ownership")
	check(budget.total_queries == before, "later connectivity cannot revive a cancelled move")
	blocked.navigation_agent.navigation_layers = 4
	blocked.issue_move(Vector3(8, 0, 8))
	await step(2)
	blocked.queue_free()
	await step(2)
	check(budget._waiting_for_map.is_empty() and budget._routes.size() == 1, "freed blocked units release their weak route entries")
	print("PATH_BUDGET_STARTUP_RESULT ", checks, " checks / ", failures.size(), " failures")
	host.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)
