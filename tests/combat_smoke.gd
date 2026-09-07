extends SceneTree
## Run: Godot --headless --path . --script res://tests/combat_smoke.gd

const UNIT_SCENE := preload("res://scenes/unit.tscn")
const BUILDING_SCENE := preload("res://scenes/building.tscn")

class CombatHost extends Node3D:
	const PROJECTILE_SCENE := preload("res://scenes/projectile.tscn")
	const EFFECT_SCENE := preload("res://scenes/battle_effect.tscn")
	var deaths: int = 0
	var unit_deaths: int = 0
	var building_deaths: int = 0
	var projectiles: int = 0
	var effects: int = 0
	var releases: Array[Dictionary] = []

	func spawn_projectile(source: Node3D, target: Node3D, damage: float, kind: String) -> void:
		var projectile: Node3D = PROJECTILE_SCENE.instantiate()
		add_child(projectile)
		projectile.initialize(source, target, damage, kind)
		projectiles += 1
		if source.is_in_group("units"):
			var model: Node3D = source._model
			var weapon_socket: Marker3D = model.get_node(model.projectile_socket)
			var retained_payload: bool = false
			if kind == "arrow":
				retained_payload = model.get_node("Rig/Action/Waist/ArmLeft/Bow/Arrow").visible
			elif kind == "stone":
				retained_payload = model.get_node("Rig/Action/ThrowArm/Payload").visible
			var shot_heading: Vector3 = -projectile.global_basis.z
			shot_heading.y = 0.0
			var target_heading: Vector3 = target.global_position - projectile.global_position
			target_heading.y = 0.0
			releases.append({"kind": kind, "origin_error": projectile._start.distance_to(weapon_socket.global_position), "animation_time": model.get_node("Attack").current_animation_position, "payload_visible": retained_payload, "launch_facing": shot_heading.normalized().dot(target_heading.normalized())})

	func spawn_effect(at: Vector3, kind: String, color: Color = Color.WHITE) -> void:
		var effect: Node3D = EFFECT_SCENE.instantiate()
		add_child(effect)
		effect.global_position = at
		effect.initialize(kind, color)
		effects += 1

	func on_entity_died(entity: Node3D) -> void:
		deaths += 1
		unit_deaths += int(entity.is_in_group("units"))
		building_deaths += int(entity.is_in_group("buildings"))

var host: CombatHost
var failures: Array[String] = []
var spawned: Array[Node3D] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	seed(81625)
	create_timer(55.0).timeout.connect(func(): quit(3))
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	host = CombatHost.new()
	root.add_child(host)
	current_scene = host
	var region := NavigationRegion3D.new()
	var navigation_mesh := NavigationMesh.new()
	navigation_mesh.vertices = PackedVector3Array([Vector3(-40, 0, -40), Vector3(-40, 0, 40), Vector3(40, 0, 40), Vector3(40, 0, -40)])
	navigation_mesh.add_polygon(PackedInt32Array([0, 1, 2, 3]))
	region.navigation_mesh = navigation_mesh
	host.add_child(region)
	await physics_frame
	await physics_frame
	await physics_frame
	if "--audio-only" in OS.get_cmdline_user_args():
		for kind: String in ["hit", "arrow_hit", "muzzle", "stone_hit", "collapse", "spawn"]:
			var audible: Node3D = CombatHost.EFFECT_SCENE.instantiate()
			host.add_child(audible)
			audible.initialize(kind)
			var sound: AudioStreamPlayer3D = audible.get_node("Sound")
			_check(sound.stream != null and sound.stream.get_length() > 0.1, "%s maps to an imported sound" % kind)
			_check(sound.volume_db <= -7.0 and sound.max_distance == 100.0, "%s uses bounded volume and distance" % kind)
			_check(audible.get_node("Lifetime").wait_time >= sound.stream.get_length() / sound.pitch_scale, "%s keeps its complete sound tail" % kind)
			var throttled: Node3D = CombatHost.EFFECT_SCENE.instantiate()
			host.add_child(throttled)
			throttled.initialize(kind)
			_check(throttled.get_node("Sound").stream == null, "%s limits simultaneous repeated sound" % kind)
			throttled.queue_free()
		await create_timer(3.2).timeout
		print("COMBAT_AUDIO: ", failures.size(), " failures")
		quit(0 if failures.is_empty() else 1)
		return
	if "--effects-only" in OS.get_cmdline_user_args():
		for kind: String in ["hit", "arrow_hit", "dust", "muzzle", "explosion", "stone_hit", "collapse", "move", "attack", "spawn", "heal", "charge"]:
			print("EFFECT: ", kind)
			host.spawn_effect(Vector3.ZERO, kind)
			await create_timer(0.15).timeout
		await create_timer(3.0).timeout
		quit()
		return
	if "--cavalry-only" in OS.get_cmdline_user_args():
		print("CAVALRY: instantiate")
		var horse: Node3D = _unit("knight", 0, Vector3(-9, 0, 0))
		var horse_target: Node3D = _unit("knight", 1, Vector3(1, 0, 0))
		horse_target.set_physics_process(false)
		horse_target.navigation_agent.avoidance_enabled = false
		print("CAVALRY: move")
		horse.issue_attack(horse_target)
		await _wait_for_damage(horse_target, 3.0)
		print("CAVALRY: damage ", horse_target.max_hp - horse_target.hp)
		quit()
		return

	var mover: Node3D = _unit("swordsman", 0, Vector3(-15, 0, 12))
	mover.issue_move(Vector3(-10, 0, 12))
	mover.queue_move(Vector3(-10, 0, 6))
	await create_timer(4.1).timeout
	_check(mover.global_position.distance_to(Vector3(-10, 0, 6)) < 1.0, "queued navigation arrives at both waypoints")
	_check(mover.waypoint_queue.is_empty(), "waypoint queue drains")
	var hp_before: float = mover.hp
	mover.receive_damage(50.0, mover)
	_check(mover.hp == hp_before, "same-team damage is ignored")
	mover.hold()
	_check(mover.order_name == "坚守阵地", "hold command is represented")
	await _clear_units()

	var sword: Node3D = _unit("swordsman", 0, Vector3(-1, 0, 0))
	var victim: Node3D = _unit("swordsman", 1, Vector3(1, 0, 0))
	victim.hold()
	sword.issue_attack(victim)
	await create_timer(1.6).timeout
	_check(victim.hp < victim.max_hp, "melee attacks apply delayed damage")
	victim.receive_damage(9999.0, sword)
	await physics_frame
	_check(not victim.alive, "lethal damage marks a unit dead")
	_check(not victim.is_in_group("entities"), "dead unit leaves target acquisition group")
	_check(host.deaths > 0, "death callback reaches game")
	await create_timer(4.5).timeout
	_check(not is_instance_valid(victim), "fallen corpse fades and is freed completely")
	await _clear_units()

	for kind: String in ["archer", "catapult", "cannon"]:
		var release_index: int = host.releases.size()
		var ranged: Node3D = _unit(kind, 0, Vector3(-5, 0, 0))
		var enemy: Node3D = _unit("knight", 1, Vector3(5, 0, 0))
		var ally: Node3D = _unit("knight", 0, Vector3(5, 0, 1.2))
		ranged.hold()
		enemy.hold()
		ally.hold()
		# Keep the two knights passive so this checks projectile damage alone.
		enemy.set_physics_process(false)
		ally.set_physics_process(false)
		enemy.navigation_agent.avoidance_enabled = false
		ally.navigation_agent.avoidance_enabled = false
		var friendly_hp: float = ally.hp
		ranged.issue_attack(enemy)
		await create_timer(2.4).timeout
		_check(enemy.hp < enemy.max_hp, "%s projectile damages its enemy" % kind)
		_check(ally.hp == friendly_hp, "%s projectile never damages allies" % kind)
		var release: Dictionary = host.releases[release_index]
		var expected_time: float = {"archer": 0.27, "catapult": 0.48, "cannon": 0.25}[kind]
		_check(release.origin_error < 0.001, "%s projectile begins at its animated weapon socket" % kind)
		_check(absf(release.animation_time - expected_time) < 0.04, "%s releases at the authored attack beat" % kind)
		_check(not release.payload_visible, "%s leaves no duplicated payload on the weapon" % kind)
		_check(release.launch_facing > 0.999, "%s faces its target on the very first projectile frame" % kind)
		print("RELEASE ", kind, " ", JSON.stringify(release))
		await _clear_units()

	var advancing: Node3D = _unit("swordsman", 0, Vector3(-8, 0, 0))
	var blocker: Node3D = _unit("swordsman", 1, Vector3(-3, 0, 0))
	blocker.hp = 15.0
	blocker.set_physics_process(false)
	blocker.navigation_agent.avoidance_enabled = false
	advancing.issue_move(Vector3(3, 0, 0), true)
	await create_timer(5.5).timeout
	_check(not is_instance_valid(blocker) or not blocker.alive, "attack-move engages an enemy on route")
	_check(advancing.global_position.distance_to(Vector3(3, 0, 0)) < 1.2, "attack-move resumes its original destination")
	await _clear_units()

	var queued_attacker: Node3D = _unit("swordsman", 0, Vector3(-2, 0, 0))
	var queued_target: Node3D = _unit("swordsman", 1, Vector3(-0.5, 0, 0))
	queued_target.hp = 10.0
	queued_target.set_physics_process(false)
	queued_target.navigation_agent.avoidance_enabled = false
	queued_attacker.issue_attack(queued_target)
	queued_attacker.queue_move(Vector3(4, 0, 0))
	await create_timer(3.1).timeout
	_check(queued_attacker.global_position.distance_to(Vector3(4, 0, 0)) < 1.2, "queued movement starts after attack target dies")
	await _clear_units()

	var sentry: Node3D = _unit("swordsman", 0, Vector3.ZERO)
	var distant_enemy: Node3D = _unit("swordsman", 1, Vector3(6, 0, 0))
	sentry.hold()
	distant_enemy.set_physics_process(false)
	distant_enemy.navigation_agent.avoidance_enabled = false
	await create_timer(0.8).timeout
	_check(sentry.global_position.length() < 0.15, "hold never chases an out-of-range enemy")
	await _clear_units()

	var cavalry: Node3D = _unit("knight", 0, Vector3(-9, 0, 0))
	var charge_target: Node3D = _unit("knight", 1, Vector3(1, 0, 0))
	charge_target.set_physics_process(false)
	charge_target.navigation_agent.avoidance_enabled = false
	cavalry.issue_attack(charge_target)
	await _wait_for_damage(charge_target, 3.0)
	_check(charge_target.max_hp - charge_target.hp > 55.0, "sustained cavalry approach delivers charge damage")
	await _clear_units()

	var structure: Node3D = BUILDING_SCENE.instantiate()
	structure.building_type = "barracks"
	structure.team = 1
	host.add_child(structure)
	spawned.append(structure)
	var siege_sword: Node3D = _unit("swordsman", 0, Vector3(5, 0, 5))
	siege_sword.issue_attack(structure)
	await create_timer(1.9).timeout
	_check(structure.hp < structure.max_hp, "melee can reach a rectangular building corner")
	structure.receive_damage(500.0)
	_check(structure.get_node("DamageSmoke").emitting, "damaged structure emits smoke")
	structure.receive_damage(9999.0)
	await create_timer(1.4).timeout
	_check(not structure.alive and structure.get_node("Rubble").visible, "destroyed structure retains rubble")
	_check(not structure.get_node("ModelPivot").visible, "collapsed building model is hidden")
	_check(structure.collision_layer == 0, "destroyed structure no longer collides")
	_check(host.unit_deaths > 0 and host.building_deaths > 0, "death callbacks preserve unit and building type groups")
	await _clear_units()

	for kind: String in ["hit", "arrow_hit", "dust", "muzzle", "explosion", "stone_hit", "collapse", "move", "attack", "spawn", "heal", "charge"]:
		host.spawn_effect(Vector3.ZERO, kind)
	await create_timer(3.2).timeout
	_check(host.projectiles >= 3, "all ranged classes created projectiles")
	print("COMBAT_SMOKE: %d failures; %d projectiles, %d effects, %d deaths" % [failures.size(), host.projectiles, host.effects, host.deaths])
	for failure: String in failures:
		push_error(failure)
	quit(0 if failures.is_empty() else 1)

func _unit(kind: String, team_number: int, at: Vector3) -> Node3D:
	var unit: Node3D = UNIT_SCENE.instantiate()
	unit.unit_type = kind
	unit.team = team_number
	unit.position = at
	host.add_child(unit)
	spawned.append(unit)
	return unit

func _clear_units() -> void:
	for entity: Node3D in spawned:
		if is_instance_valid(entity):
			entity.queue_free()
	spawned.clear()
	await process_frame
	await process_frame

func _wait_for_damage(entity: Node3D, timeout_seconds: float) -> void:
	# Native crowd avoidance changes contact time; judge the first hit, not a fixed frame.
	var deadline: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while entity.hp == entity.max_hp and Time.get_ticks_msec() < deadline:
		await physics_frame

func _check(condition: bool, label: String) -> void:
	print("%s %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures.append(label)
