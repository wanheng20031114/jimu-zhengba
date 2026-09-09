extends SceneTree
## Real Game entities, faction collision layers and native stone flight/impact.

const BUILDINGS: Array[String] = ["headquarters", "barracks", "factory", "academy", "defense_tower"]
var game: Node3D
var initial_headquarters: BattleBuilding
var checks: int = 0
var failures: Array[String] = []
var case_entities: Array[Node3D] = []
var damage_samples: Array[Dictionary] = []

func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()

func _run() -> void:
	root.get_node("Session").start_offline("2v2")
	await scene_changed
	game = current_scene
	initial_headquarters = game.headquarters
	while not game._match_ready:
		await process_frame
	game.tests_running = true
	game.bots.clear()
	game.set_physics_process(false)
	game.camera_rig.edge_scroll = false
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	for unit: BattleUnit in get_nodes_in_group("units"):
		_freeze(unit)
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		_freeze(building)
	_check(game.players.map(func(p): return p.alliance_id) == [0, 0, 1, 1], "real 2v2 has four owners and two alliances")
	var definition := BalanceCatalog.unit("catapult")
	_check(definition.damage == 35 and definition.bonuses == {&"building": 50} and definition.range == 13,
		"production catapult matches approved damage and range")
	for legacy: bool in [true, false]:
		for owner in 4:
			await _target_batch(owner, legacy)
	await _edge_and_allies()
	await _source_death()
	await _native_attack_release()
	await _clear_case()
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("CATAPULT_IMPACT_RESULTS " + JSON.stringify({"checks": checks, "failures": failures, "samples": damage_samples}))
	quit(0 if failures.is_empty() else 1)

func _freeze(entity: Node3D) -> void:
	entity.set_physics_process(false)
	if entity is BattleUnit:
		entity.stop()
		entity.navigation_agent.avoidance_enabled = false
	else:
		entity.production.set_physics_process(false)

func _unit(kind: String, owner: int, at: Vector3) -> BattleUnit:
	var entity: BattleUnit = game.spawn_unit(kind, owner, at)
	_freeze(entity)
	case_entities.append(entity)
	return entity

func _building(kind: String, owner: int, at: Vector3, site: bool = false) -> BattleBuilding:
	var entity: BattleBuilding = game.spawn_building(kind, owner, at, site)
	_freeze(entity)
	case_entities.append(entity)
	return entity

func _payload(source: BattleUnit, legacy: bool = false) -> DamagePayload:
	var definition: UnitDefinition = source.get_combat_definition()
	if legacy:
		# Preserve the historical attack in an isolated resource. The production
		# definition and every target's actual armor stay unchanged.
		definition = definition.duplicate(true)
		definition.damage = 20
		definition.bonuses = {&"infantry": 18, &"cavalry": 22, &"building": 50}
	return DamageResolver.snapshot(definition, game.get_player(source.owner_id).get_attack_bonus(), source.owner_id, source.alliance_id)

func _fire(source: BattleUnit, target: Node3D, legacy: bool = false) -> BattleProjectile:
	game.spawn_projectile(source, target, _payload(source, legacy), "stone")
	return game.effect_container.get_child(game.effect_container.get_child_count() - 1) as BattleProjectile

func _target_batch(owner: int, legacy: bool) -> void:
	var defender: int = (owner + 2) % 4
	var pending: Array[Dictionary] = []
	for index in 12:
		var at := Vector3(-28 + (index % 3) * 28, 0, -30 + (index / 3) * 20)
		var target: Node3D
		var kind: String
		var expected: float
		if index < 10:
			kind = BUILDINGS[index % 5]
			target = _building(kind, defender, at, index >= 5)
			expected = 60.0 if legacy else 75.0
		else:
			kind = "catapult" if index == 10 else "cannon"
			target = _unit(kind, defender, at)
			expected = (16.0 if index == 10 else 14.0) if legacy else (31.0 if index == 10 else 29.0)
		var source := _unit("catapult", owner, at + Vector3(-10, 0, 0))
		pending.append({"source": source, "target": target, "before": target.hp, "expected": expected,
			"kind": kind, "site": index >= 5 and index < 10})
	await physics_frame
	await physics_frame
	for sample: Dictionary in pending:
		var shot := _fire(sample.source, sample.target, legacy)
		_check((shot._blast_query.collision_mask & sample.target.collision_layer) != 0,
			"native blast mask includes owner %d %s" % [defender, sample.kind])
	await create_timer(2.5, true, true).timeout
	for sample: Dictionary in pending:
		var actual: float = sample.before - sample.target.hp
		_check(is_equal_approx(actual, sample.expected), "%s owner %d hits %s%s: %.2f expected %.2f" %
			["legacy" if legacy else "current", owner, sample.kind, " site" if sample.site else "", actual, sample.expected])
		damage_samples.append({"legacy": legacy, "owner": owner, "target_owner": defender,
			"target": sample.kind, "site": sample.site, "actual": actual})
	await _clear_case()

func _edge_and_allies() -> void:
	var source := _unit("catapult", 0, Vector3(-12, 0, 0))
	var center := _unit("archer", 2, Vector3.ZERO)
	var friendly_unit := _unit("catapult", 1, Vector3(0, 0, 1))
	var friendly_building := _building("headquarters", 1, Vector3.ZERO)
	# Stay 0.05 inside the boundary so float32 world positions cannot round an
	# exact mathematical edge onto the outside of the three-meter damage disk.
	var edge := _unit("catapult", 2, Vector3(0, 0, 4.0))
	var outside := _unit("catapult", 2, Vector3(0, 0, -4.2))
	var building := _building("factory", 3, Vector3.ZERO)
	building.rotation.y = PI / 4.0
	var size: Vector3 = building.get_combat_definition().size
	building.position.x = (size.x + size.z) * 0.5 / sqrt(2.0) + 3.0
	await physics_frame
	await physics_frame
	var point: Vector3 = building.get_attack_position(Vector3.UP)
	_check(is_equal_approx(Vector2(point.x, point.z).length(), 3.0), "rotated large building footprint touches blast edge despite distant center")
	_fire(source, center)
	await create_timer(2.5, true, true).timeout
	_check(center.hp == 25, "stone center damages infantry through native impact")
	_check(is_equal_approx(edge.hp, edge.max_hp - 13.9861111),
		"outer siege at footprint distance 2.95 takes 13.9861 after falloff and armor (actual %.6f)" % (edge.max_hp - edge.hp))
	_check(is_equal_approx(building.hp, building.max_hp - 32.5), "rotated factory receives edge splash at footprint instead of center")
	_check(outside.hp == outside.max_hp, "siege outside true three-meter footprint radius takes no damage")
	_check(friendly_unit.hp == friendly_unit.max_hp and friendly_building.hp == friendly_building.max_hp,
		"different allied owner unit and building both reject splash")
	await _clear_case()

func _source_death() -> void:
	var source := _unit("catapult", 3, Vector3(-12, 0, 0))
	var target := _building("headquarters", 0, Vector3.ZERO)
	game.get_player(3).attack_level = 1
	await physics_frame
	await physics_frame
	_fire(source, target)
	source.receive_damage(source.max_hp)
	source.queue_free()
	game.get_player(3).attack_level = 3
	await create_timer(2.5, true, true).timeout
	_check(target.hp == target.max_hp - 76, "freed attacker retains launch +1 snapshot and building bonus on landing")
	game.get_player(3).attack_level = 0
	await _clear_case()

func _native_attack_release() -> void:
	for kind: String in ["factory", "catapult", "cannon"]:
		var source := _unit("catapult", 0, Vector3(-12, 0, 0))
		var target: Node3D = _building(kind, 2, Vector3.ZERO) if kind == "factory" else _unit(kind, 2, Vector3.ZERO)
		game.get_node("FogOfWar").tick(0.3)
		await physics_frame
		await physics_frame
		_check(source._valid_target(target) and source._within_attack_range(target), "native catapult can acquire and fire at " + kind)
		source.issue_attack(target)
		source._start_attack()
		await create_timer(0.65, true, true).timeout
		var shots: Array = game.effect_container.get_children().filter(func(effect): return effect is BattleProjectile)
		_check(shots.size() == 1, "authored attack windup creates a real stone against " + kind)
		await create_timer(2.5, true, true).timeout
		var expected := 75.0 if kind == "factory" else 31.0 if kind == "catapult" else 29.0
		_check(is_equal_approx(target.max_hp - target.hp, expected), "native animation-release-flight-impact damages " + kind)
		await _clear_case()

func _clear_case() -> void:
	game.headquarters = initial_headquarters
	for entity: Node3D in case_entities:
		if is_instance_valid(entity):
			game.entities_by_id.erase(entity.entity_id)
			entity.queue_free()
	case_entities.clear()
	await physics_frame
	await physics_frame

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)
