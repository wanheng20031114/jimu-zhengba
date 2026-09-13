extends SceneTree
## Matched gameplay probe: real A-move, RVO, collision, windups and damage.
## Also runs unchanged against the frozen pre-change source for comparison.
const UNIT: PackedScene = preload("res://scenes/unit.tscn")
const SECONDS: float = 20.0

class Probe extends BattleUnit:
	var landed: int = 0
	var switches: int = 0
	var previous_enemy: int = 0
	var damage_dealt: float = 0.0

	func _physics_process(delta: float) -> void:
		super(delta)
		if is_instance_valid(target):
			if previous_enemy != 0 and previous_enemy != target.entity_id:
				switches += 1
			previous_enemy = target.entity_id

	func _on_attack_windup_timeout() -> void:
		var victim: Variant = _strike_target
		var before: float = victim.hp if is_instance_valid(victim) else 0.0
		super()
		if is_instance_valid(victim) and victim.hp < before:
			landed += 1
			damage_dealt += before - victim.hp

var host: Node3D
var checks: int = 0
var failures: Array[String] = []
var cases: Array[Dictionary] = []

func _initialize() -> void: _run.call_deferred()

func sync(frames: int = 3) -> void:
	for frame: int in frames:
		await physics_frame
		await process_frame

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func _run() -> void:
	create_timer(120.0, true, false, true).timeout.connect(func(): quit(3))
	change_scene_to_file("res://tests/balance_combat_host.tscn")
	await scene_changed
	host = current_scene
	await sync(8)
	for kind: String in ["swordsman", "knight"]:
		for angle: float in [0.0, PI * 0.5]:
			seed(138600)
			await battle(kind, angle)
	print("MELEE_FRONTAGE_BATTLE %d checks; %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func battle(kind: String, angle: float) -> void:
	var troops: Array[Probe] = []
	for owner: int in 2:
		var side: float = -1.0 if owner == 0 else 1.0
		for row: int in 6:
			for column: int in 8:
				var unit: BattleUnit = UNIT.instantiate()
				unit.set_script(Probe)
				unit.unit_type = kind
				unit.owner_id = owner
				unit.alliance_id = owner
				unit.position = Vector3(side * (4.0 + row * 1.9), 0.0, (column - 3.5) * 1.9).rotated(Vector3.UP, angle)
				unit.prune_stationary_avoidance = true
				host.get_node("Units").add_child(unit)
				unit.max_hp = 100000.0
				unit.hp = unit.max_hp
				unit.hold()
				troops.append(unit)
	await sync()
	for unit: Probe in troops:
		var side: float = 1.0 if unit.owner_id == 0 else -1.0
		unit.issue_move(Vector3(side * 18, 0, 0).rotated(Vector3.UP, angle), true)
	var start: int = Engine.get_physics_frames()
	while Engine.get_physics_frames() - start < ceili(SECONDS * Engine.physics_ticks_per_second): await sync(1)
	var participants: int = 0
	var total_hits: int = 0
	var switches: int = 0
	var damage: float = 0.0
	var maximum_switches: int = 0
	for unit: Probe in troops:
		participants += int(unit.landed > 0)
		total_hits += unit.landed
		switches += unit.switches
		maximum_switches = maxi(maximum_switches, unit.switches)
		damage += unit.damage_dealt
	check(troops.all(func(unit: Probe): return unit.alive and unit.order == BattleUnit.Order.ATTACK_MOVE and unit.navigation_agent.avoidance_enabled), "all 96 retain A-move and native RVO")
	check(participants >= 16 and total_hits > 100, "both fronts repeatedly land real attacks")
	check(maximum_switches < 20, "no unit changes enemies continuously at scan frequency")
	var result := {"kind": kind, "angle": angle, "seconds": SECONDS, "participants": participants, "hits": total_hits, "damage": damage, "target_switches": switches, "maximum_switches": maximum_switches}
	cases.append(result)
	print("COOPERATION_METRICS ", JSON.stringify(result))
	for unit: Probe in troops: unit.queue_free()
	await sync()
