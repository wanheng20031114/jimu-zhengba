extends SceneTree
## Native fixed-tick regression. Run headless with --fixed-fps 120 for fast
## simulation; the production physics delta remains exactly 1 / 30 or 1 / 60.

const UNIT_SCENE: PackedScene = preload("res://scenes/unit.tscn")
const MINE_SCENE: PackedScene = preload("res://scenes/resource_vein.tscn")
const KINDS: Array[String] = ["swordsman", "archer", "knight", "catapult", "cannon"]

class MotionProbe extends BattleUnit:
	var path_calls: int = 0
	var path_calls_max: int = 0
	var path_calls_total: int = 0
	var simulated_seconds: float = 0.0
	var attack_times: Array[float] = []
	var attack_debt: Array[float] = []

	func _physics_process(delta: float) -> void:
		path_calls = 0
		simulated_seconds += delta
		super(delta)
		path_calls_max = maxi(path_calls_max, path_calls)

	func _path_velocity() -> Vector3:
		path_calls += 1
		path_calls_total += 1
		return super()

	func _start_attack() -> void:
		attack_times.append(simulated_seconds)
		attack_debt.append(_attack_cooldown)
		super()

var host: Node3D
var checks: int = 0
var failures: Array[String] = []
var timings: Array[Dictionary] = []

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures.append(label)

func _sync(frames: int = 4) -> void:
	for frame: int in range(frames):
		await physics_frame
		await process_frame

func _run_ticks(count: int) -> void:
	var until: int = Engine.get_physics_frames() + count
	while Engine.get_physics_frames() < until:
		await physics_frame
		await process_frame

func _spawn(kind: String, faction: int, at: Vector3, stationary: bool = false) -> MotionProbe:
	var unit: Node3D = UNIT_SCENE.instantiate()
	unit.set_script(MotionProbe)
	unit.unit_type = kind
	unit.team = faction
	unit.position = at
	host.get_node("Units").add_child(unit)
	unit.gathered.connect(host.on_gathered)
	if stationary:
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	return unit as MotionProbe

func _clear() -> void:
	for container: String in ["Units", "Resources", "Effects"]:
		for entity: Node in host.get_node(container).get_children():
			entity.queue_free()
	await _sync()
	host.gathered_gold = 0

func _run() -> void:
	seed(63922)
	var wall_deadline: int = Time.get_ticks_msec() + 45000
	process_frame.connect(func():
		if Time.get_ticks_msec() >= wall_deadline:
			print("MOTION_TIMING_TIMEOUT")
			quit(3)
	)
	change_scene_to_file("res://tests/worker_ai_host.tscn")
	await scene_changed
	host = current_scene
	await _sync(8)
	for ticks: int in [30, 60]:
		Engine.physics_ticks_per_second = ticks
		await _sync()
		await _movement(ticks)
		await _combat_timing(ticks)
		await _mining_timing(ticks)
	await _clear()
	var report := FileAccess.open("res://artifacts/unit_motion_timing_results.json", FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks": checks, "failures": failures, "timing": timings}, "  "))
	report.close()
	print("UNIT_MOTION_TIMING ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _movement(ticks: int) -> void:
	var label: String = str(ticks) + " TPS "
	var mover: MotionProbe = _spawn("swordsman", 0, Vector3.ZERO)
	mover.issue_move(Vector3(6, 0, 0))
	await _run_ticks(ticks)
	_check(mover.path_calls_total > 0 and mover.path_calls_max == 1, label + "ordinary MOVE follows its native path once per physics tick")
	_check(mover.global_position.x > 2.5 and mover.order == BattleUnit.Order.MOVE, label + "single path lookup still advances normal movement")
	await _clear()
	mover = _spawn("swordsman", 0, Vector3.ZERO)
	mover.issue_move(Vector3(0.2, 0, 0))
	mover.queue_move(Vector3(6, 0, 0))
	await _run_ticks(1)
	_check(mover.waypoint_queue.is_empty() and mover.order == BattleUnit.Order.MOVE and mover.destination.x == 6.0, label + "arrival dispatches the next queued move")
	await _run_ticks(ticks * 3)
	_check(mover.order == BattleUnit.Order.IDLE and mover.global_position.distance_to(Vector3(6, 0, 0)) < 0.7 and mover.path_calls_max == 1, label + "queued movement completes without duplicate agent updates")
	await _clear()
	mover = _spawn("swordsman", 0, Vector3.ZERO)
	var pursuer: MotionProbe = _spawn("knight", 1, Vector3(0, 0, 1.65), true)
	mover.issue_move(Vector3(6, 0, 0))
	mover.receive_damage(1.0, pursuer)
	await _run_ticks(ticks)
	_check(pursuer.hp < pursuer.max_hp and mover.order == BattleUnit.Order.MOVE, label + "plain MOVE retains close-range retaliation")
	pursuer.position = Vector3(0, 0, 18)
	await _run_ticks(ticks * 3)
	_check(mover.order == BattleUnit.Order.IDLE and mover.global_position.distance_to(Vector3(6, 0, 0)) < 0.7 and mover.path_calls_max <= 1, label + "retaliation ends and original movement resumes without chasing")
	await _clear()

func _combat_timing(ticks: int) -> void:
	var fighters: Array[MotionProbe] = []
	var victims: Array[MotionProbe] = []
	for index: int in range(KINDS.size()):
		var x: float = -28.0 + float(index) * 14.0
		var fighter: MotionProbe = _spawn(KINDS[index], 0, Vector3(x, 0, 8))
		var victim: MotionProbe = _spawn("knight", 1, Vector3(x, 0, 6.35), true)
		victim.hp = 100000.0
		victim.max_hp = victim.hp
		fighter.issue_attack(victim)
		fighters.append(fighter)
		victims.append(victim)
	await _run_ticks(ticks * 60)
	for index: int in range(fighters.size()):
		var fighter: MotionProbe = fighters[index]
		var cooldown: float = BattleUnit.STATS[fighter.unit_type].cooldown
		var error: float = 0.0
		if not fighter.attack_times.is_empty():
			for strike: int in range(fighter.attack_times.size()):
				var ideal: float = fighter.attack_times[0] + cooldown * float(strike)
				error = maxf(error, absf(fighter.attack_times[strike] - ideal))
		var label: String = str(ticks) + " TPS " + fighter.unit_type
		_check(fighter.attack_times.size() >= floori(59.0 / cooldown), label + " sustains its full attack frequency for sixty simulation seconds")
		_check(error <= 1.0 / float(ticks) + 0.00001, label + " cooldown phase remains within one tick without cumulative rounding drift")
		_check(victims[index].hp < victims[index].max_hp, label + " native attack windups still deliver real damage")
		timings.append({"tps": ticks, "kind": fighter.unit_type, "attack_starts": fighter.attack_times.size(), "maximum_phase_error_seconds": error})
	# Ready time is not a debt: waiting a long time for a new target must not
	# allow the first newly issued attack to create a burst of overdue attacks.
	var ready: MotionProbe = fighters[0]
	ready.stop()
	ready.hold()
	victims[0].position = Vector3(-28, 0, -20)
	await _run_ticks(ticks * 4)
	victims[0].position = Vector3(-28, 0, 6.35)
	var before: int = ready.attack_times.size()
	ready.issue_attack(victims[0])
	await _run_ticks(2)
	_check(ready.attack_times.size() == before + 1 and absf(ready.attack_debt.back()) < 0.00001, str(ticks) + " TPS idle waiting does not accumulate attack credit")
	await _clear()

func _mining_timing(ticks: int) -> void:
	var mine: Node3D = MINE_SCENE.instantiate()
	host.get_node("Resources").add_child(mine)
	var worker: MotionProbe = _spawn("farmer", 0, Vector3(0, 0, 3.65))
	worker.issue_gather(mine)
	await _run_ticks(ticks * 60)
	_check(host.gathered_gold == 60, str(ticks) + " TPS mining preserves fractional ticks and pays twenty complete three-second cycles")
	await _clear()
