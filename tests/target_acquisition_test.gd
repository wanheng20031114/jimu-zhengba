extends SceneTree
## Compare native intent-bounded queries to exhaustive combat eligibility.
var game: Node3D
var checks := 0
var failures: Array[String] = []

class SelectiveFog extends FogOfWar:
	func position_visible_to_alliance(_alliance: int, at: Vector3) -> bool:
		return at.z >= 0.0
	func building_visible_to_alliance(_alliance: int, building: BattleBuilding) -> bool:
		return building.global_position.z >= 0.0

func _initialize() -> void: _run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func spawn(kind: String, at: Vector3, owner: int = 1) -> BattleUnit:
	var unit: BattleUnit = game.spawn_unit(kind, owner, at)
	unit.navigation_agent.avoidance_enabled = false
	unit.set_physics_process(false)
	return unit

func sync_space() -> void:
	await physics_frame
	await process_frame
	await physics_frame
	await process_frame

func reference(unit: BattleUnit, contact: bool) -> Node3D:
	var best: Node3D
	var score := INF
	for entity: Node3D in get_nodes_in_group("entities"):
		if not unit._valid_target(entity): continue
		var distance := unit.global_position.distance_squared_to(entity.global_position)
		if contact:
			if not unit._within_attack_range(entity): continue
		elif distance > pow(unit._stats.sight + entity.radius, 2.0):
			continue
		var value := distance * (1.3 if entity is BattleBuilding else 1.0)
		if value < score or (value == score and best != null and entity.entity_id < best.entity_id):
			best = entity
			score = value
	return best

func _run() -> void:
	create_timer(90.0, true, false, true).timeout.connect(func(): quit(3))
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	game.set_placing(false)
	seed(6001309)
	var attackers: Array[BattleUnit] = []
	for kind: String in BalanceCatalog.UNITS:
		attackers.append(spawn(kind, Vector3.ZERO, 0))
	# More than 64 enemies inside one view, with many outside weapon reach.
	for index: int in 96:
		var kinds: Array = BalanceCatalog.UNITS.keys()
		spawn(kinds[index % kinds.size()], Vector3(randf_range(-15, 15), 0, randf_range(-15, 15)))
	game.spawn_building("headquarters", 1, Vector3(8, 0, 0))
	game.spawn_building("house", 1, Vector3(-10, 0, 8))
	await sync_space()
	for layout: int in 12:
		for attacker: BattleUnit in attackers:
			attacker.global_position = Vector3(randf_range(-6, 6), 0, randf_range(-6, 6))
		await sync_space()
		for attacker: BattleUnit in attackers:
			for contact: bool in [false, true]:
				check(attacker._find_auto_target(contact) == reference(attacker, contact), "%s layout %d contact %s matches exhaustive selection" % [attacker.unit_type, layout, contact])
	var selective_fog := SelectiveFog.new()
	for attacker: BattleUnit in attackers:
		var previous: FogOfWar = attacker._fog
		attacker._fog = selective_fog
		for contact: bool in [true, false]:
			check(attacker._find_auto_target(contact) == reference(attacker, contact), "hidden nearer enemies cannot mask visible targets: " + attacker.unit_type)
		attacker._fog = previous
	selective_fog.free()
	game.clear_units()
	for building: Node in game.get_node("Buildings").get_children(): building.queue_free()
	await sync_space()
	# Test every body size at angular weapon boundaries, including dead zones.
	for kind: String in BalanceCatalog.UNITS:
		var attacker := spawn(kind, Vector3.ZERO, 0)
		var victim := spawn("war_elephant", Vector3(2, 0, 0))
		for angle: float in [0.0, PI / 4, PI / 2, PI * 1.25]:
			for margin: float in [-0.01, 0.01]:
				var distance: float = attacker.attack_range + attacker.radius + victim.radius + margin
				victim.global_position = Vector3(cos(angle), 0, sin(angle)) * distance
				await sync_space()
				check(attacker._find_auto_target(true) == reference(attacker, true), kind + " exact weapon boundary")
		victim.global_position = Vector3(0.1, 0, 0)
		await sync_space()
		check(attacker._find_auto_target(true) == reference(attacker, true), kind + " minimum range")
		game.clear_units()
		await sync_space()
	var soldier := spawn("swordsman", Vector3.ZERO, 0)
	var distant := spawn("knight", Vector3(10, 0, 0))
	var nearby := spawn("knight", Vector3(1.9, 0, 0))
	await sync_space()
	soldier.issue_attack(distant)
	soldier._refresh_target()
	check(soldier.target == distant, "explicit attack keeps its assigned target")
	soldier.issue_move(Vector3(20, 0, 0))
	soldier._refresh_target()
	check(soldier.target == null, "MOVE never becomes automatic pursuit")
	soldier._move_retaliation = nearby
	soldier._retaliation_time = 1.0
	soldier._refresh_target()
	check(soldier.target == nearby, "MOVE preserves contact retaliation")
	soldier.issue_move(Vector3(20, 0, 0), true)
	soldier.target = distant
	soldier._refresh_target()
	check(soldier.target == nearby, "ATTACK_MOVE switches a blocked chase to an enemy in reach")
	soldier.target = distant
	soldier.attack_windup.start(2.0)
	soldier._refresh_target()
	check(soldier.target == distant, "an active swing retains its target")
	soldier.attack_windup.stop()
	game.clear_units()
	await sync_space()
	var building: BattleBuilding = game.spawn_building("headquarters", 1, Vector3.ZERO)
	soldier = spawn("swordsman", Vector3(building._stats.size.x * 0.5 + 1.0, 0, 0), 0)
	soldier.hold()
	await sync_space()
	soldier._refresh_target()
	check(soldier.target == building, "HOLD uses a large building's edge, not center distance")
	game.clear_units()
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("TARGET_ACQUISITION %d checks; %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
