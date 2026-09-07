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

	func spawn_projectile(source: Node3D, target: Node3D, damage: float, kind: String) -> void:
		var projectile: Node3D = PROJECTILE_SCENE.instantiate()
		add_child(projectile)
		projectile.initialize(source, target, damage, kind)
		projectiles += 1

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
		print("CAVALRY: move")
		horse.issue_attack(horse_target)
		await create_timer(1.9).timeout
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
		var ranged: Node3D = _unit(kind, 0, Vector3(-5, 0, 0))
		var enemy: Node3D = _unit("knight", 1, Vector3(5, 0, 0))
		var ally: Node3D = _unit("knight", 0, Vector3(5, 0, 1.2))
		ranged.hold()
		enemy.hold()
		ally.hold()
		# Keep the two knights passive so this checks projectile damage alone.
		enemy.set_physics_process(false)
		ally.set_physics_process(false)
		var friendly_hp: float = ally.hp
		ranged.issue_attack(enemy)
		await create_timer(2.4).timeout
		_check(enemy.hp < enemy.max_hp, "%s projectile damages its enemy" % kind)
		_check(ally.hp == friendly_hp, "%s projectile never damages allies" % kind)
	await _clear_units()

	var advancing: Node3D = _unit("swordsman", 0, Vector3(-8, 0, 0))
	var blocker: Node3D = _unit("swordsman", 1, Vector3(-3, 0, 0))
	blocker.hp = 15.0
	blocker.set_physics_process(false)
	advancing.issue_move(Vector3(3, 0, 0), true)
	await create_timer(5.5).timeout
	_check(not is_instance_valid(blocker) or not blocker.alive, "attack-move engages an enemy on route")
	_check(advancing.global_position.distance_to(Vector3(3, 0, 0)) < 1.2, "attack-move resumes its original destination")
	await _clear_units()

	var queued_attacker: Node3D = _unit("swordsman", 0, Vector3(-2, 0, 0))
	var queued_target: Node3D = _unit("swordsman", 1, Vector3(-0.5, 0, 0))
	queued_target.hp = 10.0
	queued_target.set_physics_process(false)
	queued_attacker.issue_attack(queued_target)
	queued_attacker.queue_move(Vector3(4, 0, 0))
	await create_timer(3.1).timeout
	_check(queued_attacker.global_position.distance_to(Vector3(4, 0, 0)) < 1.2, "queued movement starts after attack target dies")
	await _clear_units()

	var sentry: Node3D = _unit("swordsman", 0, Vector3.ZERO)
	var distant_enemy: Node3D = _unit("swordsman", 1, Vector3(6, 0, 0))
	sentry.hold()
	distant_enemy.set_physics_process(false)
	await create_timer(0.8).timeout
	_check(sentry.global_position.length() < 0.15, "hold never chases an out-of-range enemy")
	await _clear_units()

	var cavalry: Node3D = _unit("knight", 0, Vector3(-9, 0, 0))
	var charge_target: Node3D = _unit("knight", 1, Vector3(1, 0, 0))
	charge_target.set_physics_process(false)
	cavalry.issue_attack(charge_target)
	await create_timer(1.9).timeout
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

func _check(condition: bool, label: String) -> void:
	print("%s %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures.append(label)
