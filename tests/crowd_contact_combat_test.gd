extends SceneTree
## Real NavigationAgent3D RVO, production movement, timers, damage and unit scenes.
## Run with --headless --fixed-fps 120 --script res://tests/crowd_contact_combat_test.gd.
## Only test health is increased so the same front line survives the observation.

const UNIT_SCENE: PackedScene = preload("res://scenes/unit.tscn")
const COLUMNS: int = 6
const ROWS: int = 4
const SPACING: float = 1.8
const COMBAT_SECONDS: float = 12.0
const PRESSURE_SECONDS: float = 8.0

class ContactProbe extends BattleUnit:
	var attempts: int = 0
	var hits: int = 0
	var simulation_seconds: float = 0.0
	var first_hit_seconds: float = -1.0
	var last_hit_seconds: float = -1.0
	var longest_hit_gap: float = 0.0
	var damage_dealt: float = 0.0
	var track_contact: bool = false
	var contact_seconds: float = 0.0
	var contact_wait: float = 0.0
	var longest_contact_wait: float = 0.0
	var stalled_samples: Array[Dictionary] = []
	var last_stalled_sample: float = 0.0

	func _physics_process(delta: float) -> void:
		simulation_seconds += delta
		super(delta)
		if track_contact:
			var nearest_enemy: float = INF
			var has_contact: bool = false
			for unit: BattleUnit in get_tree().get_nodes_in_group("units"):
				if _valid_target(unit):
					nearest_enemy = minf(nearest_enemy, position.distance_to(unit.position))
					has_contact = has_contact or _within_attack_range(unit)
			if has_contact:
				contact_seconds += delta
				contact_wait += delta
				longest_contact_wait = maxf(longest_contact_wait, contact_wait)
			if last_hit_seconds >= 0.0 and simulation_seconds - last_hit_seconds > 2.5 and simulation_seconds - last_stalled_sample > 0.5:
				last_stalled_sample = simulation_seconds
				stalled_samples.append({"gap": simulation_seconds - last_hit_seconds, "contact_wait": contact_wait, "position": str(position), "nearest_enemy": nearest_enemy, "target_distance": position.distance_to(target.position) if is_instance_valid(target) else -1.0, "target_position": str(target.position) if is_instance_valid(target) else "none", "moving": _moving})

	func _start_attack() -> void:
		attempts += 1
		super()

	func _on_attack_windup_timeout() -> void:
		var victim: BattleUnit = _strike_target as BattleUnit
		var health_before: float = victim.hp if is_instance_valid(victim) else 0.0
		super()
		if is_instance_valid(victim) and victim.hp < health_before:
			hits += 1
			damage_dealt += health_before - victim.hp
			contact_wait = 0.0
			if first_hit_seconds < 0.0:
				first_hit_seconds = simulation_seconds
			if last_hit_seconds >= 0.0:
				longest_hit_gap = maxf(longest_hit_gap, simulation_seconds - last_hit_seconds)
			last_hit_seconds = simulation_seconds

var host: Node3D
var checks: int = 0
var failures: Array[String] = []
var cases: Array[Dictionary] = []

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

func _spawn(kind: String, owner: int, at: Vector3) -> ContactProbe:
	var unit: BattleUnit = UNIT_SCENE.instantiate()
	unit.set_script(ContactProbe)
	unit.unit_type = kind
	unit.owner_id = owner
	unit.alliance_id = host.get_player(owner).alliance_id
	unit.position = at
	host.get_node("Units").add_child(unit)
	unit.max_hp = 10000.0
	unit.hp = unit.max_hp
	unit.hold()
	return unit as ContactProbe

func _formation(kind: String, owner: int, side: float) -> Array[ContactProbe]:
	var units: Array[ContactProbe] = []
	for row: int in range(ROWS):
		for column: int in range(COLUMNS):
			units.append(_spawn(kind, owner, Vector3(side * (4.0 + row * SPACING), 0.0, (column - (COLUMNS - 1) * 0.5) * SPACING)))
	return units

func _check_separated(units: Array[ContactProbe], label: String) -> void:
	var minimum_gap: float = INF
	for index: int in range(units.size()):
		for other_index: int in range(index + 1, units.size()):
			var a: BattleUnit = units[index]
			var b: BattleUnit = units[other_index]
			minimum_gap = minf(minimum_gap, a.position.distance_to(b.position) - a.radius - b.radius)
	_check(minimum_gap >= 0.1, label + " formations begin without overlapping RVO bodies")

func _clear() -> void:
	for unit: Node in host.get_node("Units").get_children():
		unit.queue_free()
	await _sync()

func _run() -> void:
	var deadline: int = Time.get_ticks_msec() + 120000
	process_frame.connect(func():
		if Time.get_ticks_msec() >= deadline:
			printerr("CROWD_CONTACT_COMBAT watchdog")
			quit(3)
	)
	change_scene_to_file("res://tests/balance_combat_host.tscn")
	await scene_changed
	host = current_scene
	host.players.clear()
	for owner: int in range(NetworkProtocol.MAX_PLAYERS):
		host.players.append(PlayerState.new(owner, owner % 2))
	host.combat_fog.configure(host, Vector2(80.0, 80.0))
	await _sync(8)
	if "--passage-only" not in OS.get_cmdline_user_args():
		for owner: int in range(NetworkProtocol.MAX_PLAYERS):
			seed(58271)
			await _crowd_battle(owner)
			seed(58271)
			await _hold_under_friendly_pressure(owner)
	for owner: int in range(NetworkProtocol.MAX_PLAYERS):
		seed(58271)
		await _pass_and_resume(owner)
	if "--passage-only" not in OS.get_cmdline_user_args():
		await _target_selection_guards(0, false)
		await _target_selection_guards(3, true)
	var report := FileAccess.open("res://artifacts/crowd_contact_combat_results.json", FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks": checks, "failures": failures, "cases": cases, "native_rvo": true, "physics_ticks_per_second": Engine.physics_ticks_per_second}, "  "))
	report.close()
	print("CROWD_CONTACT_COMBAT ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _crowd_battle(owner: int) -> void:
	var label: String = "owner %d 24v24 " % owner
	var infantry: Array[ContactProbe] = _formation("swordsman", owner, -1.0)
	var cavalry: Array[ContactProbe] = _formation("knight", owner ^ 1, 1.0)
	var all_units: Array[ContactProbe] = infantry + cavalry
	for index: int in range(COLUMNS):
		infantry[index].track_contact = true
		cavalry[index].track_contact = true
	_check_separated(all_units, label)
	await _sync()
	for unit: ContactProbe in infantry:
		unit.issue_move(Vector3(12.0, 0.0, unit.position.z), true)
	for unit: ContactProbe in cavalry:
		unit.issue_move(Vector3(-12.0, 0.0, unit.position.z), true)
	var first_tick: int = Engine.get_physics_frames()
	while Engine.get_physics_frames() - first_tick < ceili(COMBAT_SECONDS * Engine.physics_ticks_per_second):
		await _sync(1)
	_check(all_units.all(func(unit: ContactProbe): return unit.alive and unit.is_physics_processing() and unit.navigation_agent.avoidance_enabled), label + "all 48 units retain native physics and RVO")
	var front_infantry: Array[ContactProbe] = infantry.slice(0, COLUMNS)
	var front_cavalry: Array[ContactProbe] = cavalry.slice(0, COLUMNS)
	var infantry_report: Dictionary = _combat_summary(front_infantry)
	var cavalry_report: Dictionary = _combat_summary(front_cavalry)
	_check(infantry_report.sustained_contact_units >= COLUMNS - 2 and infantry_report.minimum_contact_hit_margin >= -2 and infantry_report.hits >= 30, label + "front infantry repeatedly lands attacks during actual melee contact")
	_check(cavalry_report.sustained_contact_units >= COLUMNS - 2 and cavalry_report.minimum_contact_hit_margin >= -2 and cavalry_report.hits >= 30, label + "front cavalry repeatedly lands attacks during actual melee contact")
	_check(infantry_report.longest_contact_wait <= 3.0, label + "front infantry has no attack starvation while enemies are in reach")
	_check(cavalry_report.longest_contact_wait <= 3.0, label + "front cavalry has no attack starvation while enemies are in reach")
	_check(infantry_report.hit_rate >= 0.8 and cavalry_report.hit_rate >= 0.8, label + "contact attacks release reliably for both armies")
	cases.append({"case": "24v24", "infantry_owner": owner, "cavalry_owner": owner ^ 1, "infantry_front": infantry_report, "cavalry_front": cavalry_report})
	print("CROWD_METRICS ", JSON.stringify(cases.back()))
	await _clear()

func _combat_summary(units: Array[ContactProbe]) -> Dictionary:
	var minimum_hits: int = 100000
	var total_hits: int = 0
	var total_attempts: int = 0
	var longest_hit_gap: float = 0.0
	var total_damage: float = 0.0
	var maximum_first_hit: float = 0.0
	var longest_contact_wait: float = 0.0
	var minimum_contact_hit_margin: int = 100000
	var sustained_contact_units: int = 0
	var contact_units: Array[Dictionary] = []
	var stalled_samples: Array[Dictionary] = []
	for unit: ContactProbe in units:
		minimum_hits = mini(minimum_hits, unit.hits)
		total_hits += unit.hits
		total_attempts += unit.attempts
		total_damage += unit.damage_dealt
		maximum_first_hit = maxf(maximum_first_hit, unit.first_hit_seconds)
		longest_hit_gap = maxf(longest_hit_gap, unit.longest_hit_gap)
		# Include the unfinished final gap so a unit cannot pass by hitting once
		# and then staying unable to release another attack for the rest of the run.
		longest_hit_gap = maxf(longest_hit_gap, unit.simulation_seconds - unit.last_hit_seconds if unit.last_hit_seconds >= 0.0 else COMBAT_SECONDS)
		longest_contact_wait = maxf(longest_contact_wait, unit.longest_contact_wait)
		var contact_cycles: int = floori(unit.contact_seconds / unit._stats.cooldown)
		minimum_contact_hit_margin = mini(minimum_contact_hit_margin, unit.hits - contact_cycles)
		if unit.contact_seconds >= 4.0:
			sustained_contact_units += 1
		contact_units.append({"hits": unit.hits, "contact_seconds": unit.contact_seconds, "longest_contact_wait": unit.longest_contact_wait})
		stalled_samples.append_array(unit.stalled_samples)
	return {"minimum_hits": minimum_hits, "hits": total_hits, "attempts": total_attempts, "hit_rate": float(total_hits) / maxf(1.0, total_attempts), "longest_hit_gap": longest_hit_gap, "maximum_first_hit": maximum_first_hit, "damage": total_damage, "stalled_samples": stalled_samples, "longest_contact_wait": longest_contact_wait, "minimum_contact_hit_margin": minimum_contact_hit_margin, "sustained_contact_units": sustained_contact_units, "contact_units": contact_units}

func _hold_under_friendly_pressure(owner: int) -> void:
	var label: String = "owner %d allied rear pressure " % owner
	var front: Array[ContactProbe] = []
	var rear: Array[ContactProbe] = []
	var origins: Array[Vector3] = []
	var rear_origins: Array[Vector3] = []
	var ally: int = (owner + 2) % NetworkProtocol.MAX_PLAYERS
	for column: int in range(COLUMNS):
		var at := Vector3(0.0, 0.0, (column - (COLUMNS - 1) * 0.5) * SPACING)
		front.append(_spawn("swordsman", owner, at))
		origins.append(at)
	for row: int in range(ROWS):
		for column: int in range(COLUMNS):
			var at := Vector3(-3.0 - row * SPACING, 0.0, (column - (COLUMNS - 1) * 0.5) * SPACING)
			rear.append(_spawn("knight", ally, at))
			rear_origins.append(at)
	var all_units: Array[ContactProbe] = front + rear
	_check_separated(all_units, label)
	await _sync()
	for unit: ContactProbe in rear:
		unit.issue_move(Vector3(10.0, 0.0, unit.position.z))
	var maximum_displacement: float = 0.0
	var first_tick: int = Engine.get_physics_frames()
	while Engine.get_physics_frames() - first_tick < ceili(PRESSURE_SECONDS * Engine.physics_ticks_per_second):
		await _sync(1)
		for index: int in range(front.size()):
			maximum_displacement = maxf(maximum_displacement, front[index].position.distance_to(origins[index]))
	_check(front.all(func(unit: ContactProbe): return unit.order == BattleUnit.Order.HOLD), label + "front line keeps its HOLD order")
	_check(all_units.all(func(unit: ContactProbe): return unit.alive and unit.is_physics_processing() and unit.navigation_agent.avoidance_enabled), label + "all 30 units retain native physics and RVO")
	var advanced_riders: int = 0
	for index: int in range(rear.size()):
		if rear[index].position.x - rear_origins[index].x > 1.0:
			advanced_riders += 1
	_check(advanced_riders >= COLUMNS, label + "rear cavalry actually reaches the holding line")
	_check(maximum_displacement <= 0.35, label + "moving allied cavalry does not displace the HOLD line")
	cases.append({"case": "allied_rear_pressure", "holding_owner": owner, "moving_owner": ally, "maximum_hold_displacement": maximum_displacement, "advanced_riders": advanced_riders})
	print("CROWD_METRICS ", JSON.stringify(cases.back()))
	await _clear()

func _pass_and_resume(owner: int) -> void:
	var label: String = "owner %d stationary neighbor passage " % owner
	var waiters: Array[ContactProbe] = []
	var origins: Array[Vector3] = []
	for index: int in range(3):
		var at := Vector3(0.0, 0.0, (index - 1) * 3.0)
		var unit: ContactProbe = _spawn("swordsman", owner, at)
		if index != 1:
			unit.stop()
		waiters.append(unit)
		origins.append(at)
	var rider: ContactProbe = _spawn("knight", (owner + 2) % NetworkProtocol.MAX_PLAYERS, Vector3(-7.0, 0.0, 0.65))
	var all_units: Array[ContactProbe] = waiters.duplicate()
	all_units.append(rider)
	_check_separated(all_units, label)
	await _sync()
	var goal := Vector3(7.0, 0.0, 0.65)
	rider.issue_move(goal)
	var maximum_displacement: float = 0.0
	var first_tick: int = Engine.get_physics_frames()
	while Engine.get_physics_frames() - first_tick < ceili(8.0 * Engine.physics_ticks_per_second):
		await _sync(1)
		for index: int in range(waiters.size()):
			maximum_displacement = maxf(maximum_displacement, waiters[index].position.distance_to(origins[index]))
	_check(maximum_displacement <= 0.35, label + "isolated idle and HOLD units keep their positions")
	var arrival_distance: float = rider.position.distance_to(goal)
	_check(arrival_distance < 0.8, label + "native RVO lets a rider pass between spaced stationary allies")
	waiters[1].issue_move(Vector3(-7.0, 0.0, 0.0))
	first_tick = Engine.get_physics_frames()
	while Engine.get_physics_frames() - first_tick < ceili(3.0 * Engine.physics_ticks_per_second):
		await _sync(1)
	_check(waiters[1].position.x < -4.0, label + "a former HOLD unit resumes movement after a move command")
	_check(all_units.all(func(unit: ContactProbe): return unit.alive and unit.is_physics_processing() and unit.navigation_agent.avoidance_enabled), label + "passage and movement resumption retain native physics and RVO")
	cases.append({"case": "stationary_neighbor_passage", "owner": owner, "maximum_stationary_displacement": maximum_displacement, "rider_arrival_distance": arrival_distance, "resumed_hold_position": str(waiters[1].position)})
	print("CROWD_METRICS ", JSON.stringify(cases.back()))
	await _clear()

func _target_selection_guards(owner: int, attack_move: bool) -> void:
	var label: String = "owner %d %s targeting " % [owner, "ATTACK_MOVE" if attack_move else "IDLE"]
	var fighter: ContactProbe = _spawn("swordsman", owner, Vector3.ZERO)
	var distant: ContactProbe = _spawn("swordsman", owner ^ 1, Vector3(8.0, 0.0, 0.0))
	await _sync()
	if attack_move:
		fighter.issue_move(Vector3(12.0, 0.0, 0.0), true)
	else:
		fighter.stop()
	fighter._refresh_target()
	_check(fighter.target == distant, label + "automatically acquires a visible distant enemy")
	fighter._refresh_target()
	_check(fighter.target == distant, label + "keeps the original target when no enemy is in reach")
	var nearby: ContactProbe = _spawn("swordsman", owner ^ 1, Vector3(1.65, 0.0, 0.0))
	await _sync(2)
	fighter._refresh_target()
	_check(fighter.target == nearby, label + "switches an automatic distant target to the enemy already in reach")
	fighter.issue_attack(distant)
	fighter._refresh_target()
	_check(fighter.target == distant and fighter.order == BattleUnit.Order.ATTACK, label + "explicit focus fire keeps the commanded enemy despite nearby alternatives")
	if attack_move:
		fighter.issue_move(Vector3(12.0, 0.0, 0.0), true)
	else:
		fighter.stop()
	fighter._refresh_target()
	var first_tick: int = Engine.get_physics_frames()
	while fighter.attack_windup.is_stopped() and Engine.get_physics_frames() - first_tick < Engine.physics_ticks_per_second * 2:
		await _sync(1)
	_check(not fighter.attack_windup.is_stopped() and fighter._strike_target == nearby, label + "begins a real native windup against its automatic target")
	# Move only this target out of range during the committed swing, then let
	# the native space update before asking the regular targeting scan to run.
	nearby.position = fighter.position + Vector3(4.0, 0.0, 0.0)
	var replacement: ContactProbe = _spawn("swordsman", owner ^ 1, fighter.position + Vector3(1.65, 0.0, 0.0))
	await _sync(1)
	fighter._refresh_target()
	_check(not fighter.attack_windup.is_stopped() and fighter.target == nearby and fighter._strike_target == nearby, label + "an in-flight swing keeps its locked target when another enemy enters reach")
	await _sync(ceili(fighter._windup_seconds() * Engine.physics_ticks_per_second) + 2)
	fighter._refresh_target()
	_check(fighter.target == replacement, label + "a completed swing can acquire the replacement now in reach")
	var all_units: Array[ContactProbe] = [fighter, distant, nearby, replacement]
	_check(all_units.all(func(unit: ContactProbe): return unit.alive and unit.is_physics_processing() and unit.navigation_agent.avoidance_enabled), label + "target selection guards retain native physics and RVO")
	cases.append({"case": "target_selection_guards", "owner": owner, "order": "ATTACK_MOVE" if attack_move else "IDLE"})
	await _clear()
