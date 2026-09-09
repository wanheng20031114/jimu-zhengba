extends SceneTree
## Actual academy/HQ components and authority commands exercise owner-only capacity.

var game: Node3D
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	Engine.max_fps = 60
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func _academy(owner: int, near: Vector3) -> BattleBuilding:
	var at: Vector3 = game.find_build_location(owner, "academy", near)
	check(at.is_finite(), "legal academy footprint for owner %d" % owner)
	var building: BattleBuilding = game.spawn_building("academy", owner, at)
	building.set_physics_process(false)
	building.production.set_physics_process(false)
	return building

func _run() -> void:
	create_timer(45.0, true, false, true).timeout.connect(func(): quit(3))
	root.get_node("Session").start_offline("2v2")
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	game.tests_running = true
	game.bots.clear()
	game.set_physics_process(false)
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	var player: PlayerState = game.get_player(0)
	player.gold = 100000
	var definition: UpgradeDefinition = BalanceCatalog.upgrade(&"workforce_1")
	check(definition.cost == 125 and definition.research_seconds == 24.0 and definition.total_bonus == 2, "expansion resource specifies 125 gold, 24 seconds and two worker slots")
	check(PlayerState.WORKER_LIMIT == 10 and player.get_worker_limit() == 10, "base capacity remains ten before research")
	check(BalanceCatalog.UPGRADE_TRACKS[&"workforce"] == 1 and player.get_upgrade_level(&"workforce") == 0, "workforce is a one-level independent research track")
	var hq: BattleBuilding = game.headquarters
	var allied_owner := 1 if game.get_player(1).alliance_id == player.alliance_id else 2
	for owner in [0, allied_owner]:
		var near: Vector3 = game.owned_entities(owner, "buildings")[0].position
		var barracks: BattleBuilding = game.spawn_building("barracks", owner, game.find_build_location(owner, "barracks", near))
		barracks.set_physics_process(false)
		barracks.production.set_physics_process(false)
	var academy := _academy(0, hq.position)
	var other := _academy(0, hq.position + Vector3(0, 0, 10))
	var ally_academy := _academy(allied_owner, game.owned_entities(allied_owner, "buildings")[0].position)
	player.gold = 124
	check(not academy.production.research("workforce_1").ok and player.gold == 124 and player.queued_research.is_empty(), "insufficient gold neither reserves nor partially pays for expansion")
	player.gold = 100000
	academy.under_construction = true
	check(not academy.production.research("workforce_1").ok, "unfinished academy cannot admit expansion research")
	academy.under_construction = false
	for id: String in ["attack_1", "defense_1", "attack_2", "defense_2", "attack_3", "defense_3"]:
		check(academy.production.research(id).ok, "prepare full academy research queue " + id)
	var full_queue_gold: int = player.gold
	check(not academy.production.research("workforce_1").ok and player.gold == full_queue_gold, "a seventh job cannot overfill one academy or charge gold")
	check(other.production.research("workforce_1").ok and player.queued_research.size() == 7, "different academies can reserve all seven distinct technologies")
	academy.production.cancel_research_by_id("attack_1")
	check(other.production.research_id == "workforce_1" and player.planned_upgrade_level(&"workforce") == 1, "cancelled military prerequisites never cancel independent workforce research")
	while not academy.production.research_queue.is_empty():
		academy.production.cancel_research()
	other.production.cancel_research()
	check(player.queued_research.is_empty() and player.gold == 100000, "all seven cancelled projects refund their own costs and clear tracks")
	var oversized_before: Array[int] = []
	oversized_before.resize(61)
	oversized_before.fill(game.owned_entities(0, "units")[0].entity_id)
	var unupgraded_command: Dictionary = game.command_bus.execute({"kind": "stop", "units": oversized_before}, 0)
	check(not unupgraded_command.ok and unupgraded_command.error == "无效单位列表", "before research a 61-entry unit command exceeds fifty military and ten worker slots")
	var production: BuildingProduction = hq.production
	for index in range(10 - player.farmers):
		check(production.recruit("farmer").ok, "reserve initial worker slot %d" % index)
	check(player.farmers + player.reserved_farmers == 10, "living and queued workers share the ten-worker cap")
	var gold_before: int = player.gold
	check(not production.recruit("farmer").ok and player.gold == gold_before, "eleventh farmer is refused without spending")
	var sequence: int = game.next_command_sequence(0)
	var command := {"kind": "research", "target": academy.entity_id, "upgrade": "workforce_1", "seq": sequence}
	check(game.submit_command(command, 0).ok and not game.submit_command(command, 0).ok, "duplicate command sequence cannot purchase workforce twice")
	game.command_bus.tick()
	check(player.gold == gold_before - 125 and academy.production.research_id == "workforce_1", "authority debits exactly one 125-gold research")
	check(player.get_worker_limit() == 10 and player.planned_upgrade_level(&"workforce") == 1, "reserved research has a planned level but no early cap benefit")
	check(player.active_research.get(&"workforce") == academy.entity_id, "active research tracks the expansion academy")
	check(not other.production.research("workforce_1").ok, "another academy cannot reserve the same expansion")
	academy.production._physics_process(23.99)
	check(player.get_worker_limit() == 10 and not production.recruit("farmer").ok, "at 23.99 seconds the eleventh worker remains forbidden")
	gold_before = player.gold
	check(game.command_bus.execute({"kind": "cancel_queue", "buildings": [academy.entity_id]}, 0).ok, "standard Esc queue-cancel command cancels workforce research")
	check(player.gold == gold_before + 125 and player.get_worker_limit() == 10 and player.active_research.is_empty(), "cancel fully refunds 125 and releases the workforce reservation")
	game.command_bus.execute({"kind": "cancel_queue", "buildings": [academy.entity_id]}, 0)
	check(player.gold == gold_before + 125, "repeated cancel cannot create a second refund")
	check(academy.production.research("workforce_1").ok, "cancelled expansion can be ordered again")
	gold_before = player.gold
	academy.receive_damage(academy.max_hp)
	check(player.gold == gold_before and player.workforce_level == 0 and not player.queued_research.has("workforce_1"), "academy destruction loses unfinished cost and releases reservation without granting capacity")
	check(other.production.research("attack_1").ok and other.production.research("workforce_1").ok, "expansion can wait behind military research in the same visible queue")
	other.production._physics_process(20.0)
	check(player.attack_level == 1 and player.get_worker_limit() == 10 and other.production.research_elapsed == 0.0, "queued expansion starts with zero elapsed after the previous technology")
	other.production._physics_process(23.99)
	check(player.get_worker_limit() == 10 and player.get_defense_bonus() == 0, "queued expansion still waits the complete 24 seconds and never changes armor")
	other.production._physics_process(0.01)
	check(player.get_worker_limit() == 12 and player.workforce_level == 1 and player.get_attack_bonus() == 1 and player.get_defense_bonus() == 0, "24-second completion grants exactly two worker slots without changing military bonuses")
	check(player.queued_research.is_empty() and player.active_research.is_empty(), "completion releases all reservations")
	check(production.recruit("farmer").ok and production.recruit("farmer").ok and player.farmers + player.reserved_farmers == 12, "eleventh and twelfth workers reserve newly unlocked slots")
	gold_before = player.gold
	check(not production.recruit("farmer").ok and player.gold == gold_before and production.recruit_error("farmer").contains("12"), "thirteenth worker is refused with the correct capacity and no charge")
	check(not other.production.research("workforce_1").ok and player.gold == gold_before, "completed one-time expansion cannot be bought again")
	var first_job: int = production.training[0].job_id
	check(production.cancel_training_job(first_job).ok and player.can_reserve_farmer(), "cancelling training releases an expanded-capacity reservation")
	check(production.recruit("farmer").ok and not player.can_reserve_farmer(), "released expanded capacity can be reserved once again")
	var farmer: BattleUnit = game.owned_entities(0, "units").filter(func(unit): return unit.unit_type == "farmer")[0]
	farmer.receive_damage(farmer.max_hp)
	check(player.farmers + player.reserved_farmers == 11 and player.can_reserve_farmer(), "farmer death releases one slot under the expanded limit")
	check(production.recruit("farmer").ok and player.farmers + player.reserved_farmers == 12, "replacement after worker death respects twelve total reservations")
	other.receive_damage(other.max_hp)
	check(player.get_worker_limit() == 12 and player.attack_level == 1, "finished expansion and military technology survive all owned academies being destroyed")
	check(game.get_player(allied_owner).get_worker_limit() == 10, "team sharing never grants the ally the worker expansion")
	var ally_gold: int = game.get_player(allied_owner).gold
	check(not game.command_bus.execute({"kind": "research", "target": ally_academy.entity_id, "upgrade": "workforce_1"}, 0).ok and game.get_player(allied_owner).gold == ally_gold, "owner cannot buy expansion through an allied academy")
	check(ally_academy.production.research("workforce_1").ok, "ally may independently reserve their own expansion")
	check(player.workforce_level == 1 and game.get_player(allied_owner).workforce_level == 0, "an allied pending project leaves both completed levels independent")
	check(player.private_state().workforce_level == 1 and not player.public_state().has("workforce_level"), "workforce level is only exported in private owner state")
	gold_before = player.gold
	production.destroyed()
	check(player.reserved_farmers == 0 and player.gold == gold_before and player.get_worker_limit() == 12, "destroying worker queue releases every reservation while preserving paid completed expansion")
	while player.farmers < 12:
		var unit: BattleUnit = game.spawn_unit("farmer", 0, game.clamp_to_map(hq.position + Vector3(player.farmers * 1.2, 0, 8)))
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	for index in range(50):
		var unit: BattleUnit = game.spawn_unit("swordsman", 0, game.clamp_to_map(hq.position + Vector3((index % 10) * 1.2, 0, 12 + (index / 10) * 1.2)))
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	var roster: Array = game.owned_entities(0, "units")
	var ids: Array[int] = []
	for unit: BattleUnit in roster:
		ids.append(unit.entity_id)
	check(roster.size() == 62 and player.farmers == 12 and player.military_supply == 50, "expanded workforce roster contains 62 actual authored units at the base military cap")
	check(game.command_bus.execute({"kind": "move", "units": ids, "at": [0, 0, 0]}, 0).ok and roster.all(func(unit): return unit.order == BattleUnit.Order.MOVE), "one move command reaches all 62 owned units")
	check(game.command_bus.execute({"kind": "stop", "units": ids}, 0).ok and roster.all(func(unit): return unit.order == BattleUnit.Order.IDLE), "one stop command reaches all 62 owned units")
	var oversized_after: Array[int] = ids.duplicate()
	oversized_after.append(ids[0])
	var excessive: Dictionary = game.command_bus.execute({"kind": "move", "units": oversized_after, "at": [0, 0, 0]}, 0)
	check(not excessive.ok and excessive.error == "无效单位列表" and roster.all(func(unit): return unit.order == BattleUnit.Order.IDLE), "63-entry command is rejected atomically without military expansion research")
	var mixed_owners: Array[int] = ids.duplicate()
	mixed_owners[0] = game.owned_entities(allied_owner, "units")[0].entity_id
	check(not game.command_bus.execute({"kind": "move", "units": mixed_owners, "at": [0, 0, 0]}, 0).ok and roster.all(func(unit): return unit.order == BattleUnit.Order.IDLE), "expanded command capacity never permits commands to allied units")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("WORKFORCE_UPGRADE_RESULTS " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)
