extends SceneTree
## Run with --headless --audio-driver Dummy --fixed-fps 120. The faster
## presentation clock leaves observable frames between both 30 and 60 TPS.
## Exercises production scenes/methods; never calls physics methods manually.

const UNIT_SCENE: PackedScene = preload("res://scenes/unit.tscn")
const MINE_SCENE: PackedScene = preload("res://scenes/resource_vein.tscn")
const BUILDING_SCENE: PackedScene = preload("res://scenes/building.tscn")

var host: Node3D
var game: Node3D
var checks: int = 0
var failures: Array[String] = []
var samples: Array[Dictionary] = []
var income_samples: Array[Dictionary] = []
var damage_outside_physics: int = 0

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures.append(label)

func _ticks(count: int) -> void:
	# Engine physics frames keep advancing while SceneTree is paused. Waiting
	# on both signals observes completed node/Timer updates, including at 120 FPS.
	var until: int = Engine.get_physics_frames() + count
	while Engine.get_physics_frames() < until:
		await physics_frame
		await process_frame

func _spawn(kind: String, team: int, at: Vector3) -> BattleUnit:
	var unit: BattleUnit = UNIT_SCENE.instantiate()
	unit.unit_type = kind
	unit.team = team
	unit.position = at
	current_scene.get_node("Units").add_child(unit)
	return unit

func _clear_host() -> void:
	for container: String in ["Units", "Buildings", "Resources", "Effects"]:
		for entity: Node in host.get_node(container).get_children():
			entity.queue_free()
	await _ticks(4)
	host.gathered_gold = 0

func _run() -> void:
	seed(93371)
	Engine.time_scale = 1.0
	var wall_deadline: int = Time.get_ticks_msec() + 60000
	process_frame.connect(func():
		if Time.get_ticks_msec() >= wall_deadline:
			print("FIXED_STEP_CONTRACT_TIMEOUT")
			quit(3)
	)
	change_scene_to_file("res://tests/worker_ai_host.tscn")
	await scene_changed
	host = current_scene
	await _ticks(8)
	for tps: int in [30, 60]:
		Engine.physics_ticks_per_second = tps
		await _ticks(4)
		await _work_contract(tps)
		await _clear_host()
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.camera_rig.edge_scroll = false
	game.get_node("EnemyTimer").stop()
	game.get_node("IncomeTimer").stop()
	for entity: Node3D in get_nodes_in_group("entities"):
		entity.set_physics_process(false)
		if entity is BattleUnit:
			entity.stop()
			entity.navigation_agent.avoidance_enabled = false
	await _ticks(8)
	game.get_node("IncomeTimer").timeout.connect(func():
		income_samples.append({"tick": game.simulation_tick, "seconds": game.elapsed, "in_physics": Engine.is_in_physics_frame()})
	)
	for tps: int in [30, 60]:
		Engine.physics_ticks_per_second = tps
		await _ticks(4)
		await _income_contract(tps)
		await _command_contract(tps)
	await game.prepare_shutdown()
	var report: FileAccess = FileAccess.open("res://artifacts/fixed_step_contract_results.json", FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks": checks, "failures": failures, "samples": samples}, "  "))
	report.close()
	print("FIXED_STEP_CONTRACT ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _work_contract(tps: int) -> void:
	var label: String = str(tps) + " TPS "
	var mine: Node3D = MINE_SCENE.instantiate()
	mine.position = Vector3(-12, 0, 0)
	host.get_node("Resources").add_child(mine)
	var site: BattleBuilding = BUILDING_SCENE.instantiate()
	site.building_type = "defense_tower"
	site.under_construction = true
	site.position = Vector3(12, 0, 0)
	host.get_node("Buildings").add_child(site)
	var miner: BattleUnit = _spawn("farmer", 0, mine.position + Vector3(0, 0, 3.65))
	var builder: BattleUnit = _spawn("farmer", 0, site.get_attack_position(Vector3(12, 0, 10)) + Vector3(0, 0, 1.7))
	miner.gathered.connect(host.on_gathered)
	await _ticks(4)
	miner.issue_gather(mine)
	builder.issue_build(site)
	var half_second: int = tps / 2
	await _ticks(half_second)
	_check(miner._working and builder._working and is_equal_approx(miner._work_seconds, 0.5) and is_equal_approx(site.construction_progress, 0.025), label + "real workers accumulate exactly half a simulation second")
	var mining_before: float = miner._work_seconds
	var build_before: float = site.construction_progress
	var hp_before: float = site.hp
	paused = true
	await _ticks(tps * 4)
	_check(is_equal_approx(miner._work_seconds, mining_before) and is_equal_approx(site.construction_progress, build_before) and site.hp == hp_before and host.gathered_gold == 0, label + "four paused seconds advance neither work, structure HP, nor mining income")
	paused = false
	await _ticks(tps * 3 - 1 - half_second)
	_check(host.gathered_gold == 0 and miner._work_seconds < 3.0, label + "mining pays nothing on the tick before three active seconds")
	await _ticks(1)
	_check(host.gathered_gold == 3 and absf(miner._work_seconds) < 0.00001, label + "the three-second physics boundary awards exactly three gold")
	miner.stop()
	await _ticks(tps * 17 - 1)
	_check(not site.is_constructed and site.construction_progress < 1.0, label + "tower remains unfinished one tick before twenty active seconds")
	await _ticks(1)
	_check(site.is_constructed and is_equal_approx(site.construction_progress, 1.0) and builder.order == BattleUnit.Order.IDLE, label + "twentieth active second completes the tower and worker order")
	samples.append({"tps": tps, "mining_gold_at_3_active_seconds": host.gathered_gold, "construction_completed_at_active_tick": tps * 20, "paused_engine_ticks": tps * 4})

func _income_contract(tps: int) -> void:
	var label: String = str(tps) + " TPS "
	var income: Timer = game.get_node("IncomeTimer")
	_check(income.process_callback == Timer.TIMER_PROCESS_PHYSICS and game.get_node("EnemyTimer").process_callback == Timer.TIMER_PROCESS_PHYSICS, label + "authored economic and enemy timers use the physics clock")
	game.gold = 0
	game.elapsed = 0.0
	game.simulation_tick = 0
	income_samples.clear()
	income.start(1.0)
	var half_second: int = tps / 2
	await _ticks(half_second)
	var before_tick: int = game.simulation_tick
	var before_elapsed: float = game.elapsed
	var before_timer: float = income.time_left
	game.toggle_pause()
	await _ticks(tps * 4)
	_check(game.simulation_tick == before_tick and is_equal_approx(game.elapsed, before_elapsed) and is_equal_approx(income.time_left, before_timer) and game.gold == 0, label + "native pause freezes battle time, income timer and gold together")
	game.toggle_pause()
	await _ticks(tps - 1 - half_second)
	_check(game.gold == 0, label + "base economy does not pay before one active second")
	# Native Timer permits its timeout on the first tick strictly after zero.
	# One tick of tolerance tests the contract without assuming float sign at 1s.
	await _ticks(tps + 2)
	_check(game.gold == 2 and income_samples.size() == 2, label + "two active seconds award two single-coin income events")
	var correct_clock: bool = game.simulation_tick == tps * 2 + 1 and absf(game.elapsed - float(game.simulation_tick) / float(tps)) < 0.00001
	for event: Dictionary in income_samples:
		correct_clock = correct_clock and event.in_physics
	if income_samples.size() == 2:
		correct_clock = correct_clock and absf(float(income_samples[1].seconds) - float(income_samples[0].seconds) - 1.0) <= 1.0 / float(tps) + 0.00001
	_check(correct_clock, label + "elapsed and income callbacks follow simulation ticks without paused-time catch-up")
	samples.append({"tps": tps, "income_events": income_samples.duplicate(true), "active_ticks": game.simulation_tick, "elapsed": game.elapsed})
	income.stop()

func _observe_render_gap(unit: BattleUnit, victim: BattleUnit = null) -> Dictionary:
	var frame: int = Engine.get_physics_frames()
	var unit_position: Vector3 = unit.global_position
	var unit_hp: float = unit.hp
	var victim_hp: float = victim.hp if victim != null else 0.0
	var windup: float = unit.attack_windup.time_left
	# MOVE has no active Attack animation. The victim identifies the explicit
	# windup phase, where a playing attack and a fixed pose are both required.
	var observe_attack: bool = victim != null
	if observe_attack and not unit._attack_animation.is_playing():
		return {"frames": 0, "unchanged": false}
	var animation_time: float = unit._attack_animation.current_animation_position if observe_attack else 0.0
	var tick: int = game.simulation_tick
	var elapsed: float = game.elapsed
	var idle_frames: int = 0
	var unchanged: bool = true
	while Engine.get_physics_frames() == frame:
		await process_frame
		if Engine.get_physics_frames() != frame:
			break
		idle_frames += 1
		unchanged = unchanged and unit.global_position == unit_position and unit.hp == unit_hp
		unchanged = unchanged and (victim == null or victim.hp == victim_hp)
		unchanged = unchanged and is_equal_approx(unit.attack_windup.time_left, windup)
		if observe_attack:
			unchanged = unchanged and unit._attack_animation.is_playing() and is_equal_approx(unit._attack_animation.current_animation_position, animation_time)
		unchanged = unchanged and game.simulation_tick == tick and is_equal_approx(game.elapsed, elapsed)
	return {"frames": idle_frames, "unchanged": unchanged}

func _command_contract(tps: int) -> void:
	var label: String = str(tps) + " TPS "
	var fighter: BattleUnit = _spawn("swordsman", 0, Vector3(0, 0, 6))
	await _ticks(4)
	game.select_entities([fighter])
	var before_position: Vector3 = fighter.global_position
	var before_tick: int = game.simulation_tick
	var before_effects: int = game.effect_container.get_child_count()
	game.command_move(Vector3(0, 0, 12))
	_check(fighter.order == BattleUnit.Order.MOVE and fighter.destination == Vector3(0, 0, 12) and game.simulation_tick == before_tick and fighter.global_position == before_position, label + "move command changes intent immediately without moving the body")
	var marker: Node3D = game.effect_container.get_child(before_effects)
	_check(marker.get_node("Ring").visible and marker.get_node("Direction").visible and marker.global_position == fighter.destination, label + "movement marker is visible before the next simulation tick")
	var gap: Dictionary = await _observe_render_gap(fighter)
	_check(gap.frames > 0 and gap.unchanged, label + "presentation frames never advance movement, HP, attack clock, or battle time")
	# Native RVO returns the submitted velocity at its next synchronization.
	await _ticks(1)
	_check(fighter.global_position.distance_to(before_position) > 0.001, label + "native physics and avoidance consume the move intent within two ticks")
	fighter.stop()
	var victim: BattleUnit = _spawn("knight", 1, fighter.global_position + Vector3(0, 0, -1.65))
	victim.set_physics_process(false)
	victim.navigation_agent.avoidance_enabled = false
	damage_outside_physics = 0
	victim.damaged.connect(func(_entity: Node3D, _amount: float):
		if not Engine.is_in_physics_frame():
			damage_outside_physics += 1
	)
	before_tick = game.simulation_tick
	var before_hp: float = victim.hp
	game.command_attack(victim)
	_check(fighter.order == BattleUnit.Order.ATTACK and fighter.target == victim and game.simulation_tick == before_tick and victim.hp == before_hp and fighter.attack_windup.is_stopped(), label + "attack command updates intent immediately but starts no windup or damage outside physics")
	await _ticks(1)
	_check(not fighter.attack_windup.is_stopped() and fighter.attack_windup.process_callback == Timer.TIMER_PROCESS_PHYSICS and fighter._attack_animation.is_playing(), label + "next fixed tick starts the authored physics windup and attack animation")
	var remaining: float = fighter.attack_windup.time_left
	var cooldown: float = fighter._attack_cooldown
	var animation_time: float = fighter._attack_animation.current_animation_position
	for repeat: int in range(12):
		game.command_attack(victim)
	_check(is_equal_approx(fighter.attack_windup.time_left, remaining) and is_equal_approx(fighter._attack_cooldown, cooldown) and is_equal_approx(fighter._attack_animation.current_animation_position, animation_time), label + "same-target command burst preserves windup, cooldown and attack pose")
	gap = await _observe_render_gap(fighter, victim)
	_check(gap.frames > 0 and gap.unchanged, label + "attack windup, pose and victim HP remain fixed between physics steps")
	var deadline: int = Engine.get_physics_frames() + tps
	while victim.hp == before_hp and Engine.get_physics_frames() < deadline:
		game.command_attack(victim)
		await process_frame
	_check(is_equal_approx(victim.hp, before_hp - maxf(1.0, fighter.attack_damage - victim.armor)) and damage_outside_physics == 0, label + "continuous presentation-rate attack orders still deliver one real hit inside physics")
	samples.append({"tps": tps, "observed_attack_gap_frames": gap.frames, "damage_outside_physics": damage_outside_physics})
	fighter.queue_free()
	victim.queue_free()
	game.select_entities([game.headquarters])
	await _ticks(4)
