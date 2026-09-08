extends SceneTree
## Real physics, NavigationAgent movement, attack windups and work accumulation.
const UNIT_SCENE: PackedScene = preload("res://scenes/unit.tscn")
const MINE_SCENE: PackedScene = preload("res://scenes/resource_vein.tscn")
const BUILDING_SCENE: PackedScene = preload("res://scenes/building.tscn")
const MILITARY: Array[String] = ["swordsman", "archer", "knight", "catapult", "cannon"]
var host: Node3D
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures.append(label)

func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout

func _until(predicate: Callable, seconds: float = 5.0) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0 / Engine.time_scale) + 600
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await physics_frame
	return bool(predicate.call())

func _spawn(kind: String, faction: int, at: Vector3, stationary: bool = false) -> Node3D:
	var unit: Node3D = UNIT_SCENE.instantiate()
	unit.unit_type = kind
	unit.team = faction
	unit.position = at
	host.get_node("Units").add_child(unit)
	unit.gathered.connect(host.on_gathered)
	if stationary:
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	return unit

func _mine(at: Vector3) -> Node3D:
	var mine: Node3D = MINE_SCENE.instantiate()
	mine.position = at
	host.get_node("Resources").add_child(mine)
	return mine

func _site(at: Vector3) -> Node3D:
	var site: Node3D = BUILDING_SCENE.instantiate()
	site.building_type = "defense_tower"
	site.team = 0
	site.under_construction = true
	site.position = at
	host.get_node("Buildings").add_child(site)
	return site

func _clear() -> void:
	for container: String in ["Units", "Buildings", "Resources", "Effects"]:
		for child: Node in host.get_node(container).get_children():
			child.queue_free()
	await physics_frame
	await physics_frame
	host.gathered_gold = 0

func _run() -> void:
	seed(71129)
	Engine.time_scale = 3.0
	create_timer(110.0, true, false, true).timeout.connect(func(): print("WORKER_AI_TIMEOUT"); quit(3))
	change_scene_to_file("res://tests/worker_ai_host.tscn")
	await scene_changed
	host = current_scene
	await physics_frame
	await physics_frame
	for faction: int in [0, 1]:
		for kind: String in MILITARY:
			await _idle_case(kind, faction)
	await _hold_case()
	await _move_case()
	await _gather_case()
	await _worker_interruption_case()
	await _construction_queue_case()
	await _clear()
	var report: FileAccess = FileAccess.open("res://artifacts/worker_ai_results.json", FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks": checks, "failures": failures}, "  "))
	report.close()
	print("WORKER_AI ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _idle_case(kind: String, faction: int) -> void:
	var fighter: Node3D = _spawn(kind, faction, Vector3(0, 0, 5))
	var victim: Node3D = _spawn("knight", 1 - faction, Vector3(0, 0, -2), true)
	var label: String = kind + " team " + str(faction)
	_check(await _until(func(): return fighter.target == victim, 0.8), label + " idle scan acquires an enemy entering sight")
	_check(fighter.order == BattleUnit.Order.IDLE, label + " automatic engagement preserves the idle leash")
	var damaged: bool = await _until(func(): return victim.hp < victim.max_hp, 4.5)
	if not damaged:
		print("IDLE_DIAG ", label, " position=", fighter.global_position, " target_position=", fighter.navigation_agent.target_position, " finished=", fighter.navigation_agent.is_navigation_finished(), " reachable=", fighter.navigation_agent.is_target_reachable(), " velocity=", fighter.velocity, " range=", fighter._within_attack_range(victim))
	_check(damaged, label + " idle engagement causes real combat damage")
	var replacement: Node3D = _spawn("knight", 1 - faction, victim.global_position + Vector3(2, 0, 0), true)
	victim.receive_damage(10000, fighter)
	_check(await _until(func(): return fighter.target == replacement, 0.8), label + " target death triggers a new scan")
	await _clear()

func _hold_case() -> void:
	for kind: String in MILITARY:
		var fighter: Node3D = _spawn(kind, 1, Vector3.ZERO)
		var far: float = fighter.attack_range + fighter.radius + 0.78 + 2.0
		var victim: Node3D = _spawn("knight", 0, Vector3(0, 0, far), true)
		fighter.hold()
		await _wait(0.55)
		_check(fighter.target == null and fighter.global_position.length() < 0.05, kind + " explicit Hold never chases outside firing range")
		victim.position = Vector3(0, 0, 1.65)
		_check(await _until(func(): return victim.hp < victim.max_hp, 2.0), kind + " Hold attacks an enemy that enters firing range")
		await _clear()

func _move_case() -> void:
	var fighter: Node3D = _spawn("swordsman", 0, Vector3.ZERO)
	var victim: Node3D = _spawn("knight", 1, Vector3(0, 0, 3), true)
	fighter.issue_move(Vector3(-6, 0, 0))
	await _wait(0.5)
	_check(fighter.order == BattleUnit.Order.MOVE and fighter.target == null, "explicit movement ignores nearby unprovoked enemies")
	_check(await _until(func(): return fighter.order == BattleUnit.Order.IDLE and fighter.target == victim, 4.0), "arrival resumes idle acquisition automatically")
	await _clear()

func _gather_case() -> void:
	var mine: Node3D = _mine(Vector3.ZERO)
	var worker: Node3D = _spawn("farmer", 0, Vector3(0, 0, 8))
	_check(worker.issue_gather(mine), "a farmer accepts a mineral command")
	await _wait(0.5)
	_check(host.gathered_gold == 0 and not worker.work_bar.visible, "walking to a mine neither shows work progress nor pays gold")
	_check(await _until(func(): return worker._working, 4.0), "worker navigates to the actual mineral perimeter")
	_check(worker.global_position.distance_to(mine.global_position) <= 3.76, "mining begins only within reach")
	await _wait(1.1)
	var retained: float = worker.work_progress
	for click: int in range(25):
		worker.issue_gather(mine)
	_check(is_equal_approx(worker.work_progress, retained), "repeated mineral clicks preserve the current cycle")
	paused = true
	await _wait(3.4)
	_check(is_equal_approx(worker.work_progress, retained) and host.gathered_gold == 0, "native game pause freezes work and never grants mining income")
	paused = false
	await _wait(1.55)
	_check(host.gathered_gold == 0 and worker.work_progress > 0.85, "a partial three-second cycle pays nothing")
	_check(await _until(func(): return host.gathered_gold == 3, 0.6), "one completed cycle awards exactly three gold")
	_check(await _until(func(): return host.gathered_gold == 6, 3.4), "permanent mine repeats without a return journey")
	var second_worker: Node3D = _spawn("farmer", 0, Vector3(0, 0, -3.65))
	second_worker.issue_gather(mine)
	await _wait(3.2)
	_check(host.gathered_gold == 12, "two workers independently gather three gold each from the same permanent mine")
	_check(mine.alive and not mine.is_in_group("entities") and not mine.is_in_group("buildings"), "permanent deposit is excluded from all military targets")
	var soldier: Node3D = _spawn("swordsman", 0, Vector3(5, 0, 0))
	soldier.issue_attack(mine)
	_check(soldier.target == null, "explicit attack rejects a neutral mineral deposit")
	await _clear()

func _worker_interruption_case() -> void:
	var mine: Node3D = _mine(Vector3.ZERO)
	var other_mine: Node3D = _mine(Vector3(10, 0, 0))
	var worker: Node3D = _spawn("farmer", 0, Vector3(0, 0, 3.65))
	var enemy: Node3D = _spawn("swordsman", 1, Vector3(0, 0, 6), true)
	worker.issue_gather(mine)
	await _wait(2.5)
	_check(worker.work_progress > 0.7 and worker.target == null, "worker keeps mining without automatically attacking a nearby enemy")
	worker.issue_gather(other_mine)
	_check(worker.work_progress == 0.0 and not worker.work_bar.visible, "changing deposits cancels the partial mining cycle")
	await _wait(0.7)
	_check(host.gathered_gold == 0, "a canceled cycle never pays after the worker leaves")
	worker.issue_gather(mine)
	await _until(func(): return worker._working, 4.0)
	await _wait(1.2)
	worker.stop()
	_check(worker.work_progress == 0.0 and worker.work_target == null and not worker.work_bar.visible, "Stop clears mining progress and work animation")
	worker.issue_gather(mine)
	await _wait(1.0)
	worker.receive_damage(10000, enemy)
	await _wait(2.2)
	_check(host.gathered_gold == 0, "worker death cannot finish a pending mining cycle")
	await _clear()

func _construction_queue_case() -> void:
	var mine: Node3D = _mine(Vector3.ZERO)
	var worker: Node3D = _spawn("farmer", 0, Vector3(0, 0, 3.65))
	var site: Node3D = _site(Vector3(8, 0, 3))
	worker.issue_gather(mine)
	await _wait(1.0)
	worker.issue_build(site, true)
	worker.queue_move(Vector3(8, 0, 10))
	_check(worker.order == BattleUnit.Order.GATHER and worker.waypoint_queue.size() == 2, "Shift mixes mining, construction and movement in one ordered queue")
	_check(await _until(func(): return worker.order == BattleUnit.Order.BUILD, 2.5), "queued construction begins after the current mining cycle")
	_check(host.gathered_gold == 3, "leaving a mine through its queue pays only the completed cycle")
	_check(await _until(func(): return worker._working, 5.0), "builder walks to the construction edge before progressing")
	await _wait(9.0)
	_check(site.construction_progress > 0.42 and site.construction_progress < 0.49 and not site.is_constructed, "construction advances by real work time toward twenty seconds")
	var progress: float = site.construction_progress
	for click: int in range(20):
		worker.issue_build(site, true)
	_check(is_equal_approx(site.construction_progress, progress), "repeated queued construction never resets site progress")
	worker.stop()
	await _wait(1.0)
	_check(is_equal_approx(site.construction_progress, progress), "stopping the builder preserves but does not advance construction")
	var successor: Node3D = _spawn("farmer", 0, worker.global_position + Vector3(1.0, 0, 0))
	successor.issue_build(site)
	successor.queue_move(Vector3(8, 0, 10))
	_check(await _until(func(): return successor._working, 3.0), "another farmer claims the paused construction")
	await _wait(9.0)
	_check(not site.is_constructed, "interrupted construction still requires twenty accumulated work seconds")
	_check(await _until(func(): return site.is_constructed, 3.0), "successor completes the remaining construction work")
	_check(successor.order == BattleUnit.Order.MOVE, "completed building releases its worker into the next Shift order")
	_check(await _until(func(): return successor.order == BattleUnit.Order.IDLE, 5.0), "mixed worker queue eventually drains")
	var doomed: Node3D = _site(Vector3(-8, 0, 3))
	successor.issue_move(Vector3(6, 0, 8))
	successor.issue_build(doomed, true)
	successor.queue_move(Vector3(4, 0, 8))
	doomed.queue_free()
	_check(await _until(func(): return successor.order == BattleUnit.Order.IDLE, 5.0), "a removed queued construction site is skipped without trapping the worker")
	await _clear()
