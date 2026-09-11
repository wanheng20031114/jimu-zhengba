extends SceneTree
## Real sandbox geometry/PathBudget/RVO. Record intent separately from safe motion.
const UNIT := preload("res://scenes/unit.tscn")
const KINDS: Array[String] = ["swordsman", "shield_guard", "spearman", "farmer", "knight", "archer"]

class ApproachProbe extends BattleUnit:
	var attack_starts: int = 0
	var retreat_distance: float = 0.0
	var backwards_intents: int = 0
	var turned_away_near_contact: int = 0
	var samples: Array[Dictionary] = []
	var intent := Vector3.ZERO
	var path_calls: int = 0
	var maximum_path_calls: int = 0

	func _physics_process(delta: float) -> void:
		intent = Vector3.ZERO
		path_calls = 0
		super(delta)
		maximum_path_calls = maxi(maximum_path_calls, path_calls)

	func _path_velocity() -> Vector3:
		path_calls += 1
		return super()

	func _chase_velocity(entity: Node3D) -> Vector3:
		var result: Vector3 = super(entity)
		intent = result
		var forward: Vector3 = (entity.global_position - global_position).normalized()
		if result.dot(forward) < -0.1 and min_attack_range == 0:
			backwards_intents += 1
		return result

	func _start_attack() -> void:
		attack_starts += 1
		super()

	func _apply_velocity(safe_velocity: Vector3) -> void:
		var before: Vector3 = global_position
		var valid: bool = is_instance_valid(target) and target.alive
		var toward: Vector3 = (target.global_position - before).normalized() if valid else Vector3.ZERO
		var gap: float = before.distance_to(target.global_position) if valid else 0.0
		super(safe_velocity)
		var radial_step: float = (global_position - before).dot(toward)
		if valid and min_attack_range == 0:
			retreat_distance += maxf(0.0, -radial_step)
			var facing_dot: float = (-model_pivot.global_basis.z).dot(toward)
			if gap < 6.0 and facing_dot < 0.0 and attack_starts == 0:
				turned_away_near_contact += 1
			if samples.size() < 360:
				samples.append({"tick": Engine.get_physics_frames(), "gap": gap,
					"intent_radial": intent.dot(toward), "safe_radial": safe_velocity.dot(toward),
					"step_radial": radial_step, "facing_dot": facing_dot,
					"attacks": attack_starts, "target_speed": target._observed_velocity.dot(toward)})

var game: Node3D
var checks: int = 0
var failures: Array[String] = []
var cases: Array[Dictionary] = []

func _initialize() -> void:
	_run.call_deferred()

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

func spawn(kind: String, owner: int, at: Vector3, avoidance: bool) -> ApproachProbe:
	var unit: BattleUnit = UNIT.instantiate()
	unit.set_script(ApproachProbe)
	unit.unit_type = kind
	unit.owner_id = owner
	unit.alliance_id = owner
	unit.position = at
	game.get_node("Units").add_child(unit)
	unit.max_hp = 10000
	unit.hp = unit.max_hp
	unit.navigation_agent.avoidance_enabled = avoidance
	return unit

func _run() -> void:
	var deadline: int = Time.get_ticks_msec() + 90000
	process_frame.connect(func():
		if Time.get_ticks_msec() > deadline:
			quit(3))
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	game.set_placing(false)
	game.camera_rig.edge_scroll = false
	for rate: int in [30, 60]:
		Engine.physics_ticks_per_second = rate
		for direct: bool in [true, false]:
			game.get_node("PathBudget").set_walkability(game.get_node("ConstructionNavigation") if direct else null)
			for kind: String in KINDS:
				await duel(kind, direct, true, 0.0)
			await duel("swordsman", direct, false, 0.0)
			await duel("spearman", direct, true, PI * 0.5)
			if direct:
				await pursuit("knight", "archer", 5.0)
				await pursuit("spearman", "archer", 1.95)
	game.set_running(false)
	game.clear_units()
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	var result := {"checks": checks, "failures": failures, "cases": cases}
	var args := OS.get_cmdline_user_args()
	var output: String = args[0] if not args.is_empty() else "res://artifacts/engagement_approach.json"
	FileAccess.open(output, FileAccess.WRITE).store_string(JSON.stringify(result, "\t") + "\n")
	print("ENGAGEMENT_APPROACH %d checks; %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func duel(kind: String, direct: bool, avoidance: bool, angle: float) -> void:
	game.set_running(false)
	game.clear_units()
	await ticks(3)
	seed(99133)
	var axis: Vector3 = Vector3.FORWARD.rotated(Vector3.UP, angle)
	var infantry: ApproachProbe = spawn(kind, 0, -axis * 6.0, avoidance)
	var cavalry: ApproachProbe = spawn("knight", 1, axis * 6.0, avoidance)
	await ticks(3)
	infantry.issue_attack(cavalry)
	cavalry.issue_attack(infantry)
	game.set_running(true)
	await ticks(Engine.physics_ticks_per_second * 5)
	game.set_running(false)
	var label := "%d TPS %s vs cavalry %s avoidance=%s angle=%.2f" % [Engine.physics_ticks_per_second, kind, "direct" if direct else "native", avoidance, angle]
	check(infantry.attack_starts >= 2 and cavalry.attack_starts >= 2, label + " both units sustain attacks")
	check(infantry.backwards_intents == 0, label + " pursuit never orders retreat from an approaching enemy")
	check(infantry.retreat_distance < 0.05, label + " no visible reverse displacement")
	check(cavalry.backwards_intents == 0 and cavalry.retreat_distance < 0.05, label + " cavalry also approaches without reversing")
	check(infantry.hp < infantry.max_hp and cavalry.hp < cavalry.max_hp, label + " both units deliver real damage")
	check(infantry.turned_away_near_contact == 0 and cavalry.turned_away_near_contact == 0, label + " no turn away before contact")
	check(infantry.maximum_path_calls <= 1 and cavalry.maximum_path_calls <= 1, label + " at most one native path update per unit tick")
	cases.append({"label": label, "retreat_distance": infantry.retreat_distance,
		"backwards_intents": infantry.backwards_intents, "attacks": infantry.attack_starts,
		"cavalry_attacks": cavalry.attack_starts, "cavalry_retreat": cavalry.retreat_distance,
		"turned_away": infantry.turned_away_near_contact, "cavalry_turned_away": cavalry.turned_away_near_contact,
		"samples": infantry.samples})
	print("APPROACH_CASE ", label, " reverse=", infantry.retreat_distance, " intents=", infantry.backwards_intents)

func pursuit(kind: String, victim_kind: String, gap: float) -> void:
	game.set_running(false)
	game.clear_units()
	await ticks(3)
	var pursuer: ApproachProbe = spawn(kind, 0, Vector3(0, 0, 24), true)
	var victim: ApproachProbe = spawn(victim_kind, 1, Vector3(0, 0, 24 - gap), true)
	await ticks(3)
	pursuer.issue_attack(victim)
	game.set_running(true)
	var end: int = Engine.get_physics_frames() + Engine.physics_ticks_per_second * 8
	while Engine.get_physics_frames() < end:
		victim.issue_move(Vector3(0, 0, -38))
		await physics_frame
		await process_frame
	game.set_running(false)
	var label := "%d TPS direct %s pursues fleeing %s" % [Engine.physics_ticks_per_second, kind, victim_kind]
	check(victim.hp < victim.max_hp, label + " deals real damage")
	check(victim.position.z < 24 - gap - 10.0, label + " target actually retreats")
	check(pursuer.maximum_path_calls <= 1, label + " at most one native path update per tick")
	print("APPROACH_PURSUIT ", label, " damage=", victim.max_hp - victim.hp)
