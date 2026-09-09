extends SceneTree
## Real production entities verify release snapshots, alliance filtering and resource slots.
const UNIT_SCENE: PackedScene = preload("res://scenes/unit.tscn")
const MINE_SCENE: PackedScene = preload("res://scenes/resource_vein.tscn")
const PROJECTILE_SCENE: PackedScene = preload("res://scenes/projectile.tscn")
var host: Node3D
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func _wait(seconds: float) -> void:
	await create_timer(seconds, true, true).timeout

func _until(predicate: Callable, seconds: float = 3.0) -> bool:
	for tick: int in range(ceili(seconds * Engine.physics_ticks_per_second)):
		if predicate.call():
			return true
		await physics_frame
	return bool(predicate.call())

func _spawn(kind: String, owner: int, at: Vector3, active: bool = false) -> BattleUnit:
	var unit: BattleUnit = UNIT_SCENE.instantiate()
	unit.unit_type = kind
	unit.owner_id = owner
	unit.alliance_id = host.get_player(owner).alliance_id
	unit.position = at
	host.get_node("Units").add_child(unit)
	unit.set_physics_process(active)
	unit.navigation_agent.avoidance_enabled = false
	unit.gathered.connect(host.on_gathered)
	return unit

func _clear() -> void:
	for name: String in ["Units", "Resources", "Effects"]:
		for node: Node in host.get_node(name).get_children():
			node.queue_free()
	await physics_frame
	await physics_frame
	for player: PlayerState in host.players:
		player.attack_level = 0
		player.defense_level = 0
	host.hidden_entities.clear()
	host.gathered_gold = 0
	host.is_authority = true

func _run() -> void:
	seed(998731)
	change_scene_to_file("res://tests/balance_combat_host.tscn")
	await scene_changed
	host = current_scene
	await physics_frame
	await physics_frame
	await _melee_and_vision()
	await _cannon_snapshot()
	await _stone_blast()
	await _minimum_ranges()
	await _mining_slots()
	await _client_authority()
	await _clear()
	var report := {"checks": checks, "failures": failures}
	var file := FileAccess.open("res://artifacts/balance_combat_results.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("BALANCE_COMBAT ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _melee_and_vision() -> void:
	var sword: BattleUnit = _spawn("swordsman", 0, Vector3.ZERO)
	var knight: BattleUnit = _spawn("knight", 1, Vector3(1.5, 0, 0))
	var ally: BattleUnit = _spawn("knight", 2, Vector3(-1.5, 0, 0))
	_check(sword.owner_id == 0 and ally.owner_id == 2 and sword.team == ally.team, "different owners share one alliance")
	_check(sword._valid_target(knight) and not sword._valid_target(ally), "selection validity filters alliance rather than owner")
	host.hidden_entities[knight.entity_id] = true
	_check(not sword._valid_target(knight), "unseen enemy cannot be acquired or attacked")
	host.hidden_entities.erase(knight.entity_id)
	sword.issue_attack(knight)
	sword._start_attack()
	for repeat: int in range(20):
		sword.issue_attack(knight)
	await _wait(0.35)
	_check(knight.hp == 96, "twenty repeated commands preserve one 24-damage strike")
	var packet: DamagePayload = DamageResolver.snapshot(sword.get_combat_definition(), 0, 0, 0)
	ally.receive_hit(packet, sword)
	_check(ally.hp == ally.max_hp, "friendly receive_hit rejects allied owner damage")
	await _clear()
	var charging_knight: BattleUnit = _spawn("knight", 0, Vector3.ZERO)
	var archer: BattleUnit = _spawn("archer", 1, Vector3(1.5, 0, 0))
	charging_knight._charge_time = 2.0
	charging_knight.issue_attack(archer)
	charging_knight._start_attack()
	await _wait(0.3)
	_check(archer.hp == 30, "visual cavalry charge does not multiply the 30-damage anti-archer strike")
	charging_knight.set_physics_process(true)
	_check(await _until(func(): return not archer.alive, 1.6), "two native cavalry strikes defeat a full-health archer")
	await _clear()

func _cannon_snapshot() -> void:
	var cannon: BattleUnit = _spawn("cannon", 0, Vector3.ZERO)
	var catapult: BattleUnit = _spawn("catapult", 1, Vector3(0, 0, -10))
	var neighbor: BattleUnit = _spawn("archer", 1, Vector3(1, 0, -10))
	host.get_player(0).attack_level = 1
	var payload: DamagePayload = DamageResolver.snapshot(cannon.get_combat_definition(), host.get_player(0).get_attack_bonus(), 0, 0)
	host.spawn_projectile(cannon, catapult, payload, "cannon")
	cannon.queue_free()
	host.get_player(0).attack_level = 3
	host.get_player(1).defense_level = 2
	await _wait(1.0)
	_check(catapult.hp == 75, "source freed after launch still deals launch attack +1 versus current defense +2")
	_check(neighbor.hp == neighbor.max_hp, "cannon explosion does not splash a neighboring archer")
	_check(host.get_node("Effects").get_child_count() == 0, "completed projectile frees itself after the interpolation tail")
	await _clear()

func _stone_blast() -> void:
	var catapult: BattleUnit = _spawn("catapult", 0, Vector3.ZERO)
	var center: BattleUnit = _spawn("swordsman", 1, Vector3(0, 0, -9))
	var core: BattleUnit = _spawn("archer", 1, Vector3(1, 0, -9))
	var edge: BattleUnit = _spawn("archer", 1, Vector3(3.02, 0, -9))
	var outside: BattleUnit = _spawn("archer", 1, Vector3(4, 0, -9))
	var ally: BattleUnit = _spawn("archer", 2, Vector3(-1, 0, -9))
	await physics_frame
	await physics_frame
	var projectile: BattleProjectile = PROJECTILE_SCENE.instantiate()
	host.get_node("Effects").add_child(projectile)
	projectile.initialize(catapult, center, DamageResolver.snapshot(catapult.get_combat_definition(), 0, 0, 0), "stone")
	var impact_point: Vector3 = projectile._end
	center.position.x += 6
	await physics_frame
	await _wait(1.6)
	_check(center.hp == 100, "stone fixed impact point can be dodged")
	_check(core.hp == 40, "stone core applies the archer class damage")
	_check(edge.hp > 40 and edge.hp < 50, "stone outer annulus attenuates damage")
	_check(outside.hp == 60 and ally.hp == 60, "stone leaves out-of-radius and allied units unharmed")
	_check(impact_point == Vector3(0, 1, -9), "stone initial landing point is fixed to commanded ground")
	await _clear()

func _minimum_ranges() -> void:
	for kind: String in ["catapult", "cannon"]:
		var siege: BattleUnit = _spawn(kind, 0, Vector3.ZERO)
		var enemy: BattleUnit = _spawn("swordsman", 1, Vector3(1.6, 0, 0))
		_check(not siege._within_attack_range(enemy), kind + " cannot fire inside minimum range")
		siege.hold()
		siege.set_physics_process(true)
		var before: int = host.projectile_count
		await _wait(0.7)
		_check(host.projectile_count == before and siege.position.length() < 0.05, kind + " hold order neither fires nor retreats from a close target")
		siege.issue_attack(enemy)
		_check(await _until(func(): return siege.global_position.distance_to(enemy.global_position) > 3.5, 2.5), kind + " explicit attack backs away to a legal firing position")
		_check(await _until(func(): return host.projectile_count > before, 3.0), kind + " resumes fire after retreating")
		await _clear()

func _mining_slots() -> void:
	var mine: ResourceVein = MINE_SCENE.instantiate()
	host.get_node("Resources").add_child(mine)
	var miners: Array[BattleUnit] = []
	for index: int in range(7):
		var worker: BattleUnit = _spawn("farmer", 0, Vector3(8 + index, 0, 0))
		worker.issue_gather(mine)
		miners.append(worker)
		if worker._claimed_mine:
			worker.global_position = mine.get_work_position(worker.global_position, worker)
		worker.set_physics_process(true)
	_check(mine.occupied_slots() == 6 and not miners[6]._claimed_mine, "six active jobs claim all slots; seventh farmer cannot claim")
	await _wait(3.15)
	_check(host.gathered_gold == 24, "only six workers earn four gold after a three-second cycle")
	_check(miners[6].work_progress == 0 and not miners[6]._working, "waiting worker receives no progress or income")
	miners[0].stop()
	_check(mine.occupied_slots() == 5, "stop immediately releases one mine slot")
	_check(await _until(func(): return miners[6]._claimed_mine, 0.8), "waiting farmer claims the newly available slot")
	miners[1].receive_damage(10000)
	_check(mine.occupied_slots() == 5, "farmer death releases its mine slot immediately")
	miners[2].queue_free()
	await physics_frame
	await physics_frame
	_check(mine.occupied_slots() == 4, "farmer deletion releases its mine slot")
	var second: ResourceVein = MINE_SCENE.instantiate()
	second.position = Vector3(15, 0, 15)
	host.get_node("Resources").add_child(second)
	miners[3].issue_gather(second, true)
	_check(second.occupied_slots() == 0, "queued mining command does not reserve a future mine slot")
	await _clear()

func _client_authority() -> void:
	var sword: BattleUnit = _spawn("swordsman", 0, Vector3.ZERO, true)
	var target: BattleUnit = _spawn("knight", 1, Vector3(1.5, 0, 0))
	host.is_authority = false
	sword.issue_attack(target)
	await _wait(0.8)
	_check(target.hp == target.max_hp and sword.position == Vector3.ZERO, "client does not simulate attacks or movement")
	await _clear()
