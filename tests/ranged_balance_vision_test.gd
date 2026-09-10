extends SceneTree
## Native arrows, real HP/armor and FogOfWar validate ranged output and cavalry scouting.

const UNIT: PackedScene = preload("res://scenes/unit.tscn")
var host: Node3D
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func _unit(kind: String, owner: int, at: Vector3) -> BattleUnit:
	var unit: BattleUnit = UNIT.instantiate()
	unit.unit_type = kind
	unit.owner_id = owner
	unit.alliance_id = host.get_player(owner).alliance_id
	unit.position = at
	host.get_node("Units").add_child(unit)
	unit.set_physics_process(false)
	unit.navigation_agent.avoidance_enabled = false
	return unit

func _clear() -> void:
	for branch: String in ["Units", "Effects"]:
		for node: Node in host.get_node(branch).get_children():
			node.queue_free()
	await physics_frame
	await physics_frame

func _run() -> void:
	change_scene_to_file("res://tests/fog_test_host.tscn")
	await scene_changed
	host = current_scene
	await physics_frame
	await physics_frame
	var archer := BalanceCatalog.unit("archer")
	var knight := BalanceCatalog.unit("knight")
	var swordsman := BalanceCatalog.unit("swordsman")
	check(archer.damage == 11 and archer.ranged_armor == 5 and archer.bonuses.is_empty(), "archer has eleven base damage and five ranged armor with no anti-cavalry bonus")
	check(knight.sight == 16 and archer.sight == 14, "cavalry sees two world units farther than archers")
	check(archer.range == 10 and is_equal_approx(archer.cooldown, 1.5), "archer reach and cadence stay at their approved values")
	check(knight.ranged_armor == 7 and knight.melee_armor == 2 and knight.cost == 80, "cavalry has seven ranged armor and costs eighty gold")
	check(knight.bonuses[&"archer"] == 3 and knight.damage == 9, "anti-archer damage is a class bonus, not extra damage against all units")
	check(swordsman.ranged_armor == 1 and swordsman.melee_armor == 2 and swordsman.cost == 45 and swordsman.hp == 100 and swordsman.sight == 14, "swordsman has one ranged armor and fourteen-unit vision")
	for pair: Array in [["knight", 4, 30], ["swordsman", 10, 10], ["archer", 6, 10]]:
		await _shoot_to_defeat(pair[0], pair[1], pair[2])
	await _vision_case()
	await _clear()
	var file := FileAccess.open("res://artifacts/ranged_balance_vision_results.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures}, "  "))
	file.close()
	print("RANGED_BALANCE_VISION ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _shoot_to_defeat(kind: String, per_hit: int, hit_count: int) -> void:
	var archer := _unit("archer", 0, Vector3(-1, 0, -1))
	var target := _unit(kind, 1, Vector3(-1, 0, -7))
	host.fog.configure(host, Vector2(80, 80))
	var start_hp: float = target.hp
	for shot in range(hit_count):
		var payload := DamageResolver.snapshot(archer.get_combat_definition(), 0, 0, 0)
		host.spawn_projectile(archer, target, payload, "arrow")
		var expected: float = maxf(0, start_hp - per_hit * (shot + 1))
		for tick in range(35):
			await physics_frame
			if target.hp <= expected:
				break
		check(is_equal_approx(target.hp, expected), "%s real arrow hit %d removes %d after armor" % [kind, shot + 1, per_hit])
		check(target.alive == (shot < hit_count - 1), "%s survives exactly until arrow %d" % [kind, hit_count])
	await _clear()

func _vision_case() -> void:
	# Native two-meter cell centers with a (14, 6) offset are about 15.23 units
	# apart: inside cavalry sight (16), outside archer sight (14), away from edges.
	var knight := _unit("knight", 0, Vector3(-1, 0, -1))
	var archer := _unit("archer", 1, Vector3(13, 0, 5))
	host.fog.configure(host, Vector2(80, 80))
	host.fog.apply_visibility(0)
	check(host.can_see_entity(0, archer) and archer.visible, "knight discovers and displays archer between fourteen and sixteen units away")
	check(not host.can_see_entity(1, knight), "archer cannot see the farther-sighted knight at the same separation")
	check(host.can_see_entity(2, archer), "allied owner shares cavalry scouting vision")
	check(knight._valid_target(archer) and not archer._valid_target(knight), "combat target validity obeys asymmetric current visibility")
	check(not knight._within_attack_range(archer), "greater vision does not give cavalry a ranged attack")
	check(is_equal_approx(knight._target_query.shape.radius, BalanceCatalog.unit("knight").sight + knight.radius), "native target sphere follows cavalry sight resource")
	knight.position = Vector3(-9, 0, -1)
	host.fog.tick(0.2)
	host.fog.apply_visibility(0)
	check(not host.can_see_entity(0, archer) and not archer.visible, "withdrawing cavalry loses live archer visibility")
	check(host.fog.cell_state(0, archer.position) == 1, "withdrawal leaves explored terrain without live target information")
	knight.position = Vector3(-1, 0, -1)
	host.fog.tick(0.2)
	check(host.can_see_entity(0, archer), "returning cavalry reacquires the enemy")
	knight.receive_damage(10000)
	host.fog.tick(0.2)
	check(not host.can_see_entity(0, archer) and not host.can_see_entity(2, archer), "fallen scout releases vision for its entire alliance")
