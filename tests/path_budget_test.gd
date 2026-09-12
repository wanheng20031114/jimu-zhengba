extends SceneTree
## Real native agents, paths and collisions. No mocked path-result calculations.
const UNIT: PackedScene = preload("res://scenes/unit.tscn")
var host: Node3D
var budget: PathBudget
var checks: int = 0
var failures: Array[String] = []
var units: Array[BattleUnit] = []

func _initialize() -> void:
	Engine.physics_ticks_per_second = 30
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func step() -> void:
	await physics_frame
	await process_frame
	check(budget.queries_this_tick <= budget.queries_per_tick, "actual native queries obey the per-tick limit")

func spawn(index: int) -> BattleUnit:
	var unit: BattleUnit = UNIT.instantiate()
	unit.owner_id = 0
	unit.unit_type = "farmer"
	unit.position = Vector3((index % 20 - 10) * 2, 0, (index / 20 - 7) * 2)
	host.get_node("Units").add_child(unit)
	unit.set_physics_process(false)
	units.append(unit)
	return unit

func _run() -> void:
	change_scene_to_file("res://tests/balance_combat_host.tscn")
	await scene_changed
	host = current_scene
	budget = host.get_node("PathBudget")
	for i in range(3): await step()
	for i in range(280): spawn(i)
	# This fixture measures an already registered army's scheduling budget.
	# Empty startup iterations are exercised separately with delayed regions.
	await step()
	var began: int = Engine.get_physics_frames()
	for unit: BattleUnit in units:
		unit.issue_move(Vector3(30, 0, 30))
		unit.issue_move(Vector3(30, 0, 30))
		unit.issue_move(Vector3(31, 0, 31))
	check(budget.pending_count() == 280, "repeated commands keep one queue entry per entity")
	check(budget.total_queries == 0, "commands update intent without synchronous path queries")
	check(units.back().destination == Vector3(31, 0, 31), "new command intent is visible immediately")
	check(budget.next_position(units.back()) == units.back().position, "a new unit waits safely without a native corridor")
	check(not budget.is_finished(units.back()), "a pending initial path cannot consume its move order")
	while budget.pending_count() > 0 and Engine.get_physics_frames() - began < 15: await step()
	check(budget.total_queries == 280, "280 coalesced intents issue exactly 280 native queries")
	check(Engine.get_physics_frames() - began <= 12, "the worst 280-unit backlog drains within twelve ticks")
	var before: int = budget.total_queries
	for unit: BattleUnit in units: unit.stop()
	for i in range(70): units[i].issue_move(Vector3(-31, 0, 31))
	began = Engine.get_physics_frames()
	while budget.pending_count() > 0 and Engine.get_physics_frames() - began < 5: await step()
	check(Engine.get_physics_frames() - began <= 3, "a player's seventy units receive paths within 100ms at 30TPS")
	check(budget.total_queries - before == 70, "single-player batch does not retain cancelled jobs")
	var first: BattleUnit = units[0]
	var old_path: PackedVector3Array = budget.current_path(first)
	first.issue_move(Vector3(25, 0, -25))
	check(budget.current_path(first) == old_path, "a pending replacement retains the old corridor")
	check(budget.next_position(first) != first.position, "an existing path continues while a replacement waits")
	first.stop()
	before = budget.total_queries
	await step()
	check(budget.total_queries == before and not budget.has_pending(first), "stop cancels an undispatched replacement")
	first.issue_move(Vector3(30, 0, 0))
	first.receive_damage(first.hp + 1)
	await step()
	check(budget.total_queries == before, "death cancels a pending path without using a slot")
	var deleted: BattleUnit = units.pop_back()
	deleted.issue_move(Vector3(5, 0, 5))
	deleted.queue_free()
	await process_frame
	await step()
	check(budget.pending_count() == 0, "freed entities leave no pending route")
	# A displaced agent would normally replan inside get_next_path_position.
	var off_path: BattleUnit = units[1]
	off_path.global_position = Vector3(30, 0, -30)
	before = budget.total_queries
	budget.next_position(off_path)
	check(budget.total_queries == before and budget.has_pending(off_path), "off-corridor automatic repaths join the same budget")
	await step()
	check(budget.total_queries == before + 1, "off-corridor path refresh executes on the next tick")
	var mesh: NavigationMesh = host.get_node("NavigationRegion3D").navigation_mesh.duplicate()
	host.get_node("NavigationRegion3D").navigation_mesh = mesh
	for i in range(3): await step()
	before = budget.total_queries
	check(budget.next_position(off_path) == off_path.position, "map changes stop movement along an obsolete corridor")
	check(budget.total_queries == before and budget.has_pending(off_path), "map changes cannot trigger a query outside the scheduler")
	await step()
	check(budget.total_queries == before + 1, "changed map obtains one fresh native corridor")
	# Let the real unit logic follow a path; endpoint advancement stays native.
	for unit: BattleUnit in units:
		if unit.alive: unit.stop()
	var traveller: BattleUnit = units[2]
	traveller.global_position = Vector3(-35, 0, -35)
	traveller.issue_move(Vector3(-29, 0, -35))
	traveller.set_physics_process(true)
	for i in range(100):
		await step()
		if traveller.order == BattleUnit.Order.IDLE: break
	check(traveller.position.distance_to(Vector3(-29, 0, -35)) < 0.8, "native path following arrives and finishes the move")
	check(traveller.order == BattleUnit.Order.IDLE, "finished native navigation completes the command")
	print("PATH_BUDGET_RESULT ", checks, " checks; ", failures.size(), " failures; max_wait_ticks=", budget.max_wait_ticks)
	host.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)
