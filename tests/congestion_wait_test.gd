extends SceneTree
## Controlled RVO output isolates the waiting state machine; the real crowd
## regression and release benchmark exercise the native avoidance solver.
class Probe extends BattleUnit:
	var jammed := true
	var lateral := false
	var chases := 0
	var attacks := 0
	func _chase_velocity(entity: Node3D) -> Vector3:
		chases += 1
		return (entity.global_position - global_position).normalized() * speed
	func _apply_velocity(safe: Vector3) -> void:
		var sideways := Vector3(-safe.z, 0, safe.x)
		super(Vector3.ZERO if jammed else (sideways if lateral else safe))
	func _start_attack() -> void:
		attacks += 1
		super()

var game: Node3D
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func ticks(count: int) -> void:
	var end: int = Engine.get_physics_frames() + count
	while Engine.get_physics_frames() < end:
		await physics_frame
		await process_frame

func _run() -> void:
	create_timer(40.0, true, false, true).timeout.connect(func(): quit(3))
	change_scene_to_file("res://tests/balance_combat_host.tscn")
	await scene_changed
	game = current_scene
	for rate: int in [30, 60]:
		Engine.physics_ticks_per_second = rate
		var unit: BattleUnit = load("res://scenes/unit.tscn").instantiate()
		unit.set_script(Probe)
		unit.unit_type = "knight"
		unit.owner_id = 0
		game.get_node("Units").add_child(unit)
		unit.navigation_agent.avoidance_enabled = false
		var victim: BattleUnit = load("res://scenes/unit.tscn").instantiate()
		victim.unit_type = "knight"
		victim.owner_id = 1
		victim.alliance_id = 1
		victim.position = Vector3(10, 0, 0)
		game.get_node("Units").add_child(victim)
		victim.set_physics_process(false)
		victim.navigation_agent.avoidance_enabled = false
		victim.max_hp = 100000
		victim.hp = victim.max_hp
		await ticks(2)
		unit.issue_move(Vector3(20, 0, 0), true)
		unit.target = victim
		unit.chases = 0
		await ticks(rate * 2)
		check(unit.chases < rate + 10, "persistent blocked auto-pursuit stops recomputing every tick")
		check(unit.order == BattleUnit.Order.ATTACK_MOVE and unit.target == victim, "waiting preserves the order and target")
		check(not unit._moving, "retry probes do not flicker walking animation")
		unit.jammed = false
		var before: Vector3 = unit.position
		await ticks(ceili(rate * 0.4))
		check(unit.position.distance_to(before) > 0.3 and unit._congestion_seconds == 0.0, "an opening resumes progress within 0.4 seconds")
		unit.jammed = true
		unit.issue_move(Vector3(20, 0, 0))
		await ticks(rate)
		check(unit._congestion_wait == 0.0, "plain MOVE never enters combat waiting")
		unit.issue_attack(victim)
		var before_chases: int = unit.chases
		await ticks(2)
		check(unit.chases > before_chases and unit.target == victim, "explicit ATTACK begins pursuit immediately and keeps its target")
		await ticks(rate)
		check(unit._congestion_seconds == unit.CONGESTION_SECONDS and unit.target == victim, "blocked explicit focus fire yields without retargeting")
		before_chases = unit.chases
		unit.issue_attack(victim)
		await ticks(2)
		check(unit.chases > before_chases and unit._congestion_wait == 0.0, "a repeated explicit command immediately interrupts congestion waiting")
		unit.jammed = false
		unit.lateral = true
		unit.issue_move(Vector3(20, 0, 0), true)
		unit.target = victim
		await ticks(ceili(rate * 0.3))
		check(unit._congestion_wait == 0.0, "brief lateral avoidance is uninterrupted")
		await ticks(rate)
		check(unit._congestion_seconds == unit.CONGESTION_SECONDS, "persistent lateral motion without forward progress yields")
		unit.jammed = true
		unit.lateral = false
		unit.issue_move(Vector3(20, 0, 0), true)
		unit.target = victim
		await ticks(rate)
		victim.position = unit.position + Vector3(1.8, 0, 0)
		await ticks(2)
		check(unit.attacks > 0 and unit._congestion_wait == 0.0, "an enemy entering range is attacked immediately during waiting")
		unit.queue_free()
		victim.queue_free()
		await ticks(2)
	game.queue_free()
	await process_frame
	await process_frame
	print("CONGESTION_WAIT %d checks; %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
