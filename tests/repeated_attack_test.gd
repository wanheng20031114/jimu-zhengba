extends SceneTree
## Regression through the real Game.command_attack selection/command entry point.
const KINDS: Array[String] = ["swordsman", "knight", "archer", "catapult", "cannon"]
var game: Node3D
var failures: Array[String] = []
var checks: int = 0
var projectiles: int = 0
var case_units: Array[Node3D] = []
var ending: bool = false

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, label: String) -> void:
	checks += 1
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures.append(label)

func _run() -> void:
	create_timer(80.0).timeout.connect(func(): failures.append("regression deadline"); _finish())
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	seed(94123)
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.camera_rig.edge_scroll = false
	game.get_node("EnemyTimer").stop()
	game.get_node("IncomeTimer").stop()
	await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
	for unit: Node in get_nodes_in_group("units"):
		unit.queue_free()
	for building: Node in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
	await physics_frame
	await physics_frame
	game.get_node("ProjectilePool").launched.connect(func(_flight: ProjectileFlight): projectiles += 1)
	for mode: String in ["explicit", "idle", "attack_move"]:
		for kind: String in KINDS:
			await _repeat_case(kind, mode)
	await _switch_case()
	for command: String in ["stop", "hold", "move"]:
		await _cancel_case(command)
	await _death_case(false)
	await _death_case(true)
	await _finish()

func _spawn(kind: String, faction: int, at: Vector3) -> Node3D:
	var unit: Node3D = game.spawn_unit(kind, faction, at)
	case_units.append(unit)
	if faction == 1:
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	return unit

func _wait_windup(fighter: Node3D) -> void:
	var deadline: int = Time.get_ticks_msec() + 2000
	while fighter.attack_windup.is_stopped() and Time.get_ticks_msec() < deadline:
		await physics_frame
	_check(not fighter.attack_windup.is_stopped(), fighter.unit_type + " begins a real native attack windup")

func _repeat_case(kind: String, mode: String) -> void:
	var fighter: Node3D = _spawn(kind, 0, Vector3(0, 0, 6))
	var victim: Node3D = _spawn("knight", 1, Vector3(0, 0, 4.4))
	game.select_entities([fighter])
	if mode == "explicit":
		game.command_attack(victim)
	elif mode == "attack_move":
		game.command_move(Vector3(0, 0, 1), true)
	await _wait_windup(fighter)
	if mode != "idle":
		game.command_move(Vector3(4, 0, 8), false, true)
		_check(fighter.waypoint_queue.size() == 1, kind + " accepts a queued follow-up before repeat")
	var remaining: float = fighter.attack_windup.time_left
	var cooldown: float = fighter._attack_cooldown
	var animation_time: float = fighter._attack_animation.current_animation_position
	var repath_time: float = fighter._repath_time
	game.command_attack(victim)
	_check(not fighter.attack_windup.is_stopped() and is_equal_approx(fighter.attack_windup.time_left, remaining), kind + " " + mode + " repeat preserves in-flight windup")
	_check(is_equal_approx(fighter._attack_cooldown, cooldown) and is_equal_approx(fighter._attack_animation.current_animation_position, animation_time), kind + " " + mode + " repeat preserves cooldown and animation")
	_check(is_equal_approx(fighter._repath_time, repath_time), kind + " " + mode + " repeat preserves chase pacing")
	_check(fighter.order == BattleUnit.Order.ATTACK and fighter.target == victim and fighter.waypoint_queue.is_empty(), kind + " " + mode + " explicit repeat replaces the queue only")
	for click: int in range(29):
		game.command_attack(victim)
		await create_timer(0.05).timeout
	_check(victim.hp < victim.max_hp, kind + " " + mode + " repeated clicks still deal real damage")
	await _clear_case()

func _switch_case() -> void:
	var fighter: Node3D = _spawn("archer", 0, Vector3(0, 0, 6))
	var former: Node3D = _spawn("knight", 1, Vector3(0, 0, 4.4))
	var replacement: Node3D = _spawn("knight", 1, Vector3(5, 0, 4.4))
	game.select_entities([fighter])
	game.command_attack(former)
	await _wait_windup(fighter)
	game.command_attack(replacement)
	_check(fighter.attack_windup.is_stopped() and fighter.target == replacement, "a different target cancels the former windup")
	var deadline: int = Time.get_ticks_msec() + 3200
	while replacement.hp == replacement.max_hp and Time.get_ticks_msec() < deadline:
		game.command_attack(replacement)
		await create_timer(0.05).timeout
	_check(former.hp == former.max_hp and replacement.hp < replacement.max_hp, "target switching damages only the replacement despite repeated commands")
	await _clear_case()

func _cancel_case(command: String) -> void:
	var fighter: Node3D = _spawn("archer", 0, Vector3(0, 0, 6))
	var victim: Node3D = _spawn("knight", 1, Vector3(0, 0, 4.4))
	game.select_entities([fighter])
	game.command_attack(victim)
	await _wait_windup(fighter)
	var shots_before: int = projectiles
	match command:
		"stop": game.stop_selected()
		"hold": game.hold_selected()
		"move": game.command_move(Vector3(8, 0, 9))
	_check(fighter.attack_windup.is_stopped(), command + " explicitly cancels the pending shot")
	await create_timer(0.75).timeout
	_check(victim.hp == victim.max_hp and projectiles == shots_before, command + " prevents the canceled strike from releasing")
	await _clear_case()

func _death_case(attacker_dies: bool) -> void:
	var fighter: Node3D = _spawn("archer", 0, Vector3(0, 0, 6))
	var victim: Node3D = _spawn("knight", 1, Vector3(0, 0, 4.4))
	game.select_entities([fighter])
	game.command_attack(victim)
	await _wait_windup(fighter)
	var shots_before: int = projectiles
	if attacker_dies:
		fighter.receive_damage(10000.0, victim)
	else:
		victim.receive_damage(10000.0, fighter)
	for click: int in range(12):
		game.command_attack(victim)
		await create_timer(0.05).timeout
	_check(projectiles == shots_before and fighter.attack_windup.is_stopped(), ("attacker" if attacker_dies else "target") + " death prevents repeat commands from releasing a stale shot")
	await _clear_case()

func _clear_case() -> void:
	game.select_entities([])
	for unit: Node3D in case_units:
		if is_instance_valid(unit):
			unit.set_physics_process(false)
			unit.navigation_agent.avoidance_enabled = false
			unit.get_node("AttackWindup").stop()
			unit.queue_free()
	case_units.clear()
	game.get_node("ProjectilePool").reset_all()
	await physics_frame
	await physics_frame

func _finish() -> void:
	if ending:
		return
	ending = true
	var suffix := "before" if "--baseline" in OS.get_cmdline_user_args() else "after"
	var report := FileAccess.open("res://artifacts/repeated_attack_" + suffix + ".json", FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks": checks, "failures": failures}, "  "))
	report.close()
	print("REPEATED_ATTACK ", checks, " checks; ", failures.size(), " failures")
	await game.prepare_shutdown()
	quit(0 if failures.is_empty() else 1)
