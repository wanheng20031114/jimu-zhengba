extends SceneTree
var checks := 0
var failures: Array[String] = []
var game: Node3D

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func run() -> void:
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
	await physics_frame
	await physics_frame
	await create_timer(0.6).timeout
	var player: PlayerState = game.get_player(0)
	player.gold = 10000
	var hq: BattleBuilding = game.headquarters
	var production: BuildingProduction = hq.production
	production.set_physics_process(false)
	check(not production.recruit("swordsman").ok, "HQ refuses military production")
	var start_workers := player.farmers
	for index in range(10 - start_workers):
		check(production.recruit("farmer").ok, "reserve farmer %d" % index)
	check(player.farmers + player.reserved_farmers == 10, "queue reservations count toward ten")
	var gold_before := player.gold
	check(not production.recruit("farmer").ok and player.gold == gold_before, "eleventh farmer rejected without charge")
	check(production.cancel_training(0).ok and player.gold == gold_before + 50, "cancel training full refund")
	check(player.farmers + player.reserved_farmers == 9, "cancel releases reservation")
	while not production.training.is_empty():
		production.cancel_training(0)
	check(production.recruit("farmer").ok, "new farmer queued")
	production._physics_process(9.9)
	check(player.farmers == start_workers, "farmer waits ten seconds")
	production._physics_process(0.2)
	check(player.farmers == start_workers + 1 and player.reserved_farmers == 0, "completed farmer spawns once")
	var legal: Vector3 = game.find_build_location(0, "barracks", game.headquarters.position)
	check(legal.is_finite(), "legal barracks placement exists")
	var barracks: BattleBuilding = game.spawn_building("barracks", 0, legal)
	var academy: BattleBuilding = game.spawn_building("academy", 0, Vector3(-23, 0, -12))
	var academy2: BattleBuilding = game.spawn_building("academy", 0, Vector3(-12, 0, -24))
	academy.production.set_physics_process(false)
	academy2.production.set_physics_process(false)
	game.get_node("ConstructionNavigation").refresh()
	await physics_frame
	await physics_frame
	await create_timer(0.5).timeout
	check(not barracks.production.recruit("farmer").ok, "barracks refuses farmers")
	var supply := player.military_supply
	check(barracks.production.recruit("knight").ok, "barracks instant knight")
	check(player.military_supply == supply + 2, "knight consumes two supply")
	player.military_supply = 60
	gold_before = player.gold
	check(not barracks.production.recruit("swordsman").ok and player.gold == gold_before, "supply cap rejects purchase")
	player.military_supply = supply + 2
	check(not academy.production.research("attack_2").ok, "cannot skip tech level")
	check(academy.production.research("attack_1").ok, "start attack I")
	check(not academy2.production.research("attack_1").ok, "two academies cannot duplicate research")
	check(academy2.production.research("defense_1").ok, "academies parallel different routes")
	gold_before = player.gold
	check(academy.production.cancel_research().ok and player.gold == gold_before + 100, "research cancel full refund")
	check(academy.production.research("attack_1").ok, "cancel clears reservation")
	academy.production._physics_process(20)
	check(player.attack_level == 1 and player.get_attack_bonus() == 1, "research applies owner technology")
	check(academy.production.research("attack_2").ok, "research next level")
	academy.production._physics_process(35)
	check(player.get_attack_bonus() == 2, "level II total bonus is two")
	check(academy.production.research("attack_3").ok, "research level III")
	academy.production._physics_process(50)
	check(player.get_attack_bonus() == 4, "level III total bonus is four")
	gold_before = player.gold
	academy2.receive_damage(academy2.max_hp)
	check(player.gold == gold_before and not player.active_research.has(&"defense"), "destroyed academy loses active research and releases slot")
	check(player.attack_level == 3, "completed technology survives building loss")
	var ally: PlayerState = game.get_player(1)
	ally.alliance_id = 0
	var before := ally.gold
	var forged := {"kind": "recruit", "target": hq.entity_id, "unit_type": "farmer"}
	check(not game.command_bus.execute(forged, 1).ok and ally.gold == before, "ally cannot spend on other owner production")
	var command := {"kind": "recruit", "target": hq.entity_id, "unit_type": "farmer", "seq": 500}
	check(game.submit_command(command, 0).ok, "first sequence accepted")
	check(not game.submit_command(command, 0).ok, "duplicate sequence rejected before purchase")
	game.command_bus.pending.clear()
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("PRODUCTION_RULES_RESULT ", checks, " checks, ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
