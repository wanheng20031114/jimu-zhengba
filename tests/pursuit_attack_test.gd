extends SceneTree
## Real native corridors, RVO, Timer windups, release poses and damage.
## --fixed-fps 120 accelerates wall time without changing the fixed physics delta.

const UNIT_SCENE: PackedScene = preload("res://scenes/unit.tscn")
const KINDS: Array[String] = ["knight", "swordsman", "farmer", "archer", "catapult", "cannon"]

class Fighter extends BattleUnit:
	var attack_ticks: Array[int] = []
	var path_calls: int = 0
	var maximum_path_calls: int = 0
	var orbit_radius: float = 0.0
	var orbit_angle: float = 0.0

	func _physics_process(delta: float) -> void:
		if orbit_radius > 0.0:
			# Follow a circular input trajectory with real CharacterBody movement.
			# This isolates tangential motion without teleporting a target or
			# replacing the attacker's navigation/Timer/projectile implementation.
			orbit_angle += speed / orbit_radius * delta
			var next := Vector3(cos(orbit_angle), 0, sin(orbit_angle)) * orbit_radius
			_apply_velocity((next - global_position) / delta)
			return
		path_calls = 0
		super(delta)
		maximum_path_calls = maxi(maximum_path_calls, path_calls)

	func _path_velocity() -> Vector3:
		path_calls += 1
		return super()

	func _start_attack() -> void:
		attack_ticks.append(Engine.get_physics_frames())
		super()

var host: Node3D
var checks: int = 0
var failures: Array[String] = []
var samples: Array[Dictionary] = []

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures.append(label)

func _sync(frames: int = 3) -> void:
	for frame in frames:
		await physics_frame
		await process_frame

func _ticks(count: int, retreating: BattleUnit = null) -> void:
	var end: int = Engine.get_physics_frames() + count
	while Engine.get_physics_frames() < end:
		# The user continuously orders retreat. A normal MOVE can retaliate;
		# replacing it every tick deliberately suppresses that stationary duel.
		if is_instance_valid(retreating) and retreating.alive:
			retreating.issue_move(Vector3(38, 0, retreating.position.z))
		await physics_frame
		await process_frame

func _spawn(kind: String, faction: int, at: Vector3, stationary: bool = false) -> Fighter:
	var unit: Node3D = UNIT_SCENE.instantiate()
	unit.set_script(Fighter)
	unit.unit_type = kind
	unit.team = faction
	unit.position = at
	host.get_node("Units").add_child(unit)
	if stationary:
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	return unit

func _clear() -> void:
	for entity: BattleUnit in host.get_node("Units").get_children():
		entity.set_physics_process(false)
		entity.navigation_agent.avoidance_enabled = false
		entity._cancel_attack()
		entity.queue_free()
	for effect: Node in host.get_node("Effects").get_children():
		effect.queue_free()
	host.resume_vision()
	host.get_node("Blocker").position = Vector3(0, -100, 0)
	await _sync()

func _run() -> void:
	seed(87301)
	var deadline: int = Time.get_ticks_msec() + 45000
	process_frame.connect(func():
		if Time.get_ticks_msec() > deadline:
			print("PURSUIT_ATTACK_TIMEOUT")
			quit(3)
	)
	change_scene_to_file("res://tests/pursuit_attack_host.tscn")
	await scene_changed
	host = current_scene
	await _sync(8)
	for tps: int in [30, 60]:
		Engine.physics_ticks_per_second = tps
		await _sync()
		await _pursuit("knight", "archer", 5.0, 8.0, 3)
		await _pursuit("swordsman", "archer", 1.95, 8.0, 2)
		await _pursuit("farmer", "catapult", 3.0, 8.0, 2)
		await _pursuit("archer", "catapult", 11.8, 8.0, 2)
		await _pursuit("catapult", "cannon", 14.0, 8.0, 1)
		await _pursuit("cannon", "cannon", 13.5, 8.0, 1)
		for order_kind: String in ["hold", "attack"]:
			await _tangential_target(order_kind)
			await _blocked_target(order_kind)
		for kind: String in ["catapult", "cannon"]:
			await _minimum_range(kind)
		await _outrun_swing()
		for kind: String in KINDS:
			for change: String in ["repeat", "move", "stop", "hold", "switch", "hide", "death", "attacker_death", "free", "escape"]:
				await _windup_change(kind, change)
	await _clear()
	var result: Dictionary = {"build": NetworkProtocol.BUILD_ID, "checks": checks, "failures": failures, "pursuits": samples}
	var report := FileAccess.open("res://artifacts/pursuit_attack_results.json", FileAccess.WRITE)
	report.store_string(JSON.stringify(result, "  "))
	report.close()
	print("PURSUIT_ATTACK_RESULTS " + JSON.stringify(result))
	quit(0 if failures.is_empty() else 1)

func _pursuit(kind: String, victim_kind: String, gap: float, seconds: float, minimum_hits: int) -> void:
	var fighter := _spawn(kind, 0, Vector3(-27, 0, 0))
	var victim := _spawn(victim_kind, 1, Vector3(-27 + gap, 0, 0))
	if kind in ["catapult", "cannon"]:
		# Siege vision is now 14. An inactive allied scout reveals the initial
		# maximum-range target without changing its trajectory or attack reach.
		_spawn("knight", 0, Vector3(-27 + gap * 0.5, 0, 10), true)
	victim.hp = 10000.0
	victim.max_hp = victim.hp
	var hits: Array[int] = []
	victim.damaged.connect(func(_who, _amount): hits.append(Engine.get_physics_frames()))
	var start_tick: int = Engine.get_physics_frames()
	victim.issue_move(Vector3(38, 0, 0))
	fighter.issue_attack(victim)
	await _ticks(roundi(seconds * Engine.physics_ticks_per_second), victim)
	var label: String = "%d TPS %s pursues continuously retreating %s" % [Engine.physics_ticks_per_second, kind, victim_kind]
	_check(hits.size() >= minimum_hits, label + " deals real damage (%d hits)" % hits.size())
	_check(victim.position.x > -27 + gap + 10.0, label + " target actually keeps retreating")
	_check(fighter.maximum_path_calls <= 1, label + " follows at most one native corridor per tick")
	var minimum_interval: float = INF
	for index in range(1, fighter.attack_ticks.size()):
		minimum_interval = minf(minimum_interval, float(fighter.attack_ticks[index] - fighter.attack_ticks[index - 1]) / Engine.physics_ticks_per_second)
	_check(minimum_interval + 1.0 / Engine.physics_ticks_per_second + 0.00001 >= fighter._stats.cooldown,
		label + " never accelerates the original cooldown")
	samples.append({"tps": Engine.physics_ticks_per_second, "attacker": kind, "target": victim_kind, "hits": hits.size(),
		"first_hit_seconds": float(hits[0] - start_tick) / Engine.physics_ticks_per_second if not hits.is_empty() else -1,
		"attack_starts": fighter.attack_ticks.size(), "minimum_start_interval_seconds": minimum_interval if minimum_interval != INF else -1})
	await _clear()

func _tangential_target(order_kind: String) -> void:
	var fighter := _spawn("archer", 0, Vector3.ZERO)
	var victim := _spawn("archer", 1, Vector3.ZERO)
	var orbit: float = fighter.attack_range + fighter.radius + victim.radius - 0.01
	victim.position = Vector3(orbit, 0, 0)
	victim.orbit_radius = orbit
	victim.navigation_agent.avoidance_enabled = false
	victim.hp = 10000.0
	victim.max_hp = victim.hp
	fighter.set_physics_process(false)
	await _ticks(4)
	if order_kind == "hold":
		fighter.hold()
		fighter.target = victim
	else:
		fighter.issue_attack(victim)
	var label: String = "%d TPS %s ranged target follows a real circular trajectory" % [Engine.physics_ticks_per_second, order_kind]
	_check(fighter._within_attack_range(victim), label + " stays inside current range")
	_check(fighter._can_start_strike(victim), label + " does not mistake tangential movement for retreat")
	fighter.set_physics_process(true)
	await _ticks(Engine.physics_ticks_per_second * 5)
	_check(victim.hp < victim.max_hp and fighter.attack_ticks.size() >= 3, label + " releases repeatedly and deals real projectile damage")
	_check(fighter.position.length() < 0.1, label + " does not require an artificial approach step")
	await _clear()

func _blocked_target(order_kind: String) -> void:
	var fighter := _spawn("archer", 0, Vector3.ZERO, true)
	var victim := _spawn("archer", 1, Vector3(10.0, 0, 0))
	victim.navigation_agent.avoidance_enabled = false
	victim.hp = 10000.0
	victim.max_hp = victim.hp
	var reach: float = fighter.attack_range + fighter.radius + victim.radius
	# The fixed wall arrests the fleeing CharacterBody just inside range.
	# Floating CharacterBody velocity retains the requested movement while
	# pressing into the wall; only native real displacement describes retreat.
	host.get_node("Blocker").position = Vector3(reach - 0.04 + victim.radius * 0.85 + 0.5, 0, 0)
	await _sync()
	victim.issue_move(Vector3(38, 0, 0))
	await _ticks(Engine.physics_ticks_per_second, victim)
	var label: String = "%d TPS %s ranged target is physically stopped by a wall" % [Engine.physics_ticks_per_second, order_kind]
	_check(victim.get_slide_collision_count() > 0 and victim._observed_velocity.length() < 0.01, label + " has native zero radial velocity")
	_check(fighter._within_attack_range(victim) and fighter._can_start_strike(victim), label + " uses collision-corrected motion for its release window")
	if order_kind == "hold":
		fighter.hold()
		fighter.target = victim
	else:
		fighter.issue_attack(victim)
	fighter.set_physics_process(true)
	await _ticks(Engine.physics_ticks_per_second * 4, victim)
	_check(victim.hp < victim.max_hp and fighter.position.length() < 0.1, label + " fires without needing to approach or penetrate the wall")
	await _clear()

func _minimum_range(kind: String) -> void:
	var fighter := _spawn(kind, 0, Vector3.ZERO)
	var victim := _spawn("farmer", 1, Vector3(1.6, 0, 0), true)
	fighter.issue_attack(victim)
	_check(not fighter._within_attack_range(victim), kind + " rejects a target inside minimum range")
	await _ticks(Engine.physics_ticks_per_second * 5)
	_check(victim.hp < victim.max_hp, kind + " moves out to a legal firing distance then deals damage")
	_check(fighter.attack_ticks.size() > 0, kind + " native siege windup starts after gaining separation")
	await _clear()

func _outrun_swing() -> void:
	var fighter := _spawn("swordsman", 0, Vector3.ZERO, true)
	var victim := _spawn("knight", 1, Vector3(2.25, 0, 0))
	fighter.navigation_agent.avoidance_enabled = false
	victim.navigation_agent.avoidance_enabled = false
	victim.issue_move(Vector3(38, 0, 0))
	await _ticks(4, victim)
	fighter.position = victim.position - Vector3(2.25, 0, 0)
	fighter.set_physics_process(true)
	# Start inside real reach; then the faster target bolts while the original
	# native windup is active. A pursuit step must not imply a guaranteed hit.
	fighter.issue_attack(victim)
	_check(fighter._within_attack_range(victim), "faster escape starts within real melee reach")
	fighter._start_attack()
	await _ticks(Engine.physics_ticks_per_second, victim)
	_check(victim.hp == victim.max_hp, "faster target escapes a committed swing without a phantom hit")
	_check(fighter.attack_ticks.size() == 1, "escaped swing is consumed once and cannot restart during recovery")
	await _clear()

func _windup_change(kind: String, change: String) -> void:
	var fighter := _spawn(kind, 0, Vector3.ZERO)
	var gap: float = 5.0 if kind in ["archer", "catapult", "cannon"] else 1.6
	var victim := _spawn("farmer", 1, Vector3(gap, 0, 0), true)
	fighter.issue_attack(victim)
	var deadline: int = Engine.get_physics_frames() + Engine.physics_ticks_per_second
	while fighter.attack_windup.is_stopped() and Engine.get_physics_frames() < deadline:
		await _sync(1)
	var label: String = "%d TPS %s %s" % [Engine.physics_ticks_per_second, kind, change]
	_check(not fighter.attack_windup.is_stopped(), label + " begins a native windup")
	var hits: Array[float] = []
	victim.damaged.connect(func(_who, amount): hits.append(amount))
	var projectiles_before: int = host.projectile_count
	var cooldown: float = fighter._attack_cooldown
	var remaining: float = fighter.attack_windup.time_left
	var animation: float = fighter._attack_animation.current_animation_position
	match change:
		"repeat":
			for click in 40:
				fighter.issue_attack(victim)
			_check(is_equal_approx(fighter.attack_windup.time_left, remaining) and is_equal_approx(fighter._attack_cooldown, cooldown)
				and is_equal_approx(fighter._attack_animation.current_animation_position, animation), label + " preserves release, cooldown and pose")
		"move": fighter.issue_move(Vector3(0, 0, 20))
		"stop": fighter.stop()
		"hold": fighter.hold()
		"switch": fighter.issue_attack(_spawn("farmer", 1, Vector3(0, 0, gap), true))
		"hide": host.suspend_alliance_vision(fighter.alliance_id)
		"death":
			victim.receive_damage(victim.hp)
			hits.clear()
		"attacker_death": fighter.receive_damage(fighter.hp)
		"free": victim.free()
		"escape": victim.position.x += 25.0
	var observation_seconds: float = 1.5 if kind == "catapult" else 0.7
	await _ticks(ceili(observation_seconds * Engine.physics_ticks_per_second))
	if change == "repeat":
		_check(hits.size() == 1, label + " still delivers exactly one real hit")
	else:
		_check(hits.is_empty() and host.projectile_count == projectiles_before, label + " produces no canceled or out-of-range hit/projectile")
	_check(fighter.attack_ticks.size() == 1, label + " cannot restart before original cooldown")
	await _clear()
