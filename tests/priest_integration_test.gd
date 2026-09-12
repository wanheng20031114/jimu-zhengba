extends SceneTree
## Academy production/research, real command entry points, AI takeover and punch timing.
var checks: int = 0
var failures: Array[String] = []
var game: Node3D
func _initialize() -> void: _run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func freeze(unit: BattleUnit) -> void:
	unit.stop()
	unit.set_physics_process(false)
	unit.navigation_agent.avoidance_enabled = false
func _run() -> void:
	create_timer(80,true,false,true).timeout.connect(func(): quit(3))
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	game.tests_running = true
	game.bots.clear()
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	for unit: BattleUnit in get_nodes_in_group("units"): freeze(unit)
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	var player: PlayerState = game.get_player(0)
	player.gold = 10000
	var barracks: BattleBuilding = game.spawn_building("barracks",0,game.find_build_location(0,"barracks",game.headquarters.position))
	barracks.set_physics_process(false)
	barracks.production.set_physics_process(false)
	var at: Vector3 = game.find_build_location(0,"academy",game.headquarters.position)
	check(at.is_finite(),"valid academy location")
	var academy: BattleBuilding = game.spawn_building("academy",0,at)
	academy.set_physics_process(false)
	academy.production.set_physics_process(false)
	game.get_node("ConstructionNavigation").refresh()
	await create_timer(.5).timeout
	for attempt: int in 120:
		if game.find_recruit_position("priest",academy).is_finite(): break
		await physics_frame
	check(game.find_recruit_position("priest",academy).is_finite(),"academy has navigable priest exit")
	game.select_entities([academy])
	game.hud._refresh_actions()
	check(game.hud._actions[0].kind == "recruit" and game.hud._actions[0].id == "priest","priest is first academy action")
	var research: Array[String] = []
	for page: int in 2:
		for action: Dictionary in game.hud._actions:
			if action.kind == "research": research.append(String(action.id))
		check(game.hud._actions.back().kind == "action_page","academy actions expose page navigation")
		game.hud._on_recruit(game.hud._actions.size()-1)
	check(research.size() == BalanceCatalog.UPGRADE_TRACKS.size() and research.has("recovery_1") and research.has("cannon_range_1"),"every research track remains accessible across pages")
	check(game.hud._actions[0].id == "priest","second page returns to priest first page")
	player.gold = 179
	check(not academy.production.recruit("priest").ok and player.gold == 179,"insufficient gold does not charge")
	player.gold = 10000
	var before: int = player.military_supply
	check(game.command_bus.execute({"kind":"recruit","target":academy.entity_id,"unit_type":"priest"},0).ok,"academy command recruits priest")
	check(player.gold == 9820 and player.reserved_military_supply == 2,"180 gold reserves two military population")
	check(academy.production.research("recovery_1").ok,"research starts alongside priest training")
	academy.production._physics_process(17.9)
	check(academy.production.training.size() == 1 and academy.production.research_elapsed == 17.9,"both independent queues advance together without early training")
	academy.production._physics_process(.1)
	check(academy.production.training.is_empty() and player.military_supply == before+2 and player.reserved_military_supply == 0,"18 seconds completes priest and converts reservation")
	check(academy.production.research_id == "recovery_1" and is_equal_approx(academy.production.research_elapsed,18),"training completion leaves research running")
	var priest: BattleUnit
	for unit: BattleUnit in game.owned_entities(0,"units"):
		if unit.unit_type == "priest": priest = unit
	check(priest != null and priest.hp == 70 and priest._model.batch_parts.size() == 10,"production uses complete saved priest model")
	freeze(priest)
	game.select_entities([priest])
	check(game.own_selected_workers().is_empty() and game.own_selected_units() == [priest],"priest selection counts as military")
	academy.production._physics_process(2)
	check(academy.production.research_queue.is_empty() and player.get_recovery_per_second() == 1,"independent research finishes at twenty seconds")
	academy.production.recruit("priest")
	var gold: int = player.gold
	check(academy.production.cancel_training(0).ok and player.gold == gold+180 and player.reserved_military_supply == 0,"cancel refunds 180 and releases two population")
	player.military_supply = player.get_supply_limit()-1
	gold = player.gold
	check(not academy.production.recruit("priest").ok and player.gold == gold,"one free population cannot fit a priest")
	player.military_supply = before+2
	check(not barracks.production.recruit("priest").ok,"wrong building cannot recruit priest")
	var blockers: Array[BattleUnit] = []
	for attempt: int in 180:
		var exit_at: Vector3 = game.find_recruit_position("priest",academy)
		if not exit_at.is_finite(): break
		var blocker: BattleUnit = game.spawn_unit("farmer",0,exit_at)
		freeze(blocker)
		blockers.append(blocker)
		await physics_frame
	check(not game.find_recruit_position("priest",academy).is_finite(),"real units can block academy exit")
	academy.production.recruit("priest")
	academy.production._physics_process(18)
	check(academy.production.training.size() == 1 and player.reserved_military_supply == 2,"blocked exit retains completed job and reservation")
	for blocker: BattleUnit in blockers: blocker.queue_free()
	await physics_frame
	await physics_frame
	academy.production._physics_process(.3)
	check(academy.production.training.is_empty() and player.reserved_military_supply == 0,"cleared exit spawns once")
	var soldier: BattleUnit = game.spawn_unit("swordsman",0,priest.position+Vector3(0,0,2))
	freeze(soldier)
	soldier.hp -= 40
	soldier.issue_move(priest.position+Vector3(0,0,5))
	game.select_entities([priest,soldier])
	check(game.can_support_selected(soldier),"right click recognizes injured friendly organic target")
	var command: Dictionary = {"kind":"support","units":[priest.entity_id,soldier.entity_id],"target":soldier.entity_id}
	check(game.command_bus.execute(command,0).ok and priest.order == BattleUnit.Order.SUPPORT and soldier.order == BattleUnit.Order.MOVE,"mixed selection redirects only capable healer")
	command["amount"] = 99999
	game.command_bus.execute(command,0)
	check(priest._stats.support_amount == 10 and soldier.hp == 70,"extraneous client amount cannot alter healing values or health")
	var bot := SkirmishBot.new(game,0)
	bot._refresh_own_army()
	check(priest in bot._supporters and priest not in bot._army,"takeover separates healer from front line")
	bot._memory = {1:{"building":false,"kind":"priest","seen_at":0.0}}
	check(bot._composition().support == 1,"enemy healer recognized as support")
	bot._budget = 10000
	bot._recruit_army(0)
	check(game.command_bus.pending.all(func(c: Dictionary): return c.get("unit_type","") not in ["priest","engineer","light_cavalry","war_elephant","shield_guard"]),"AI still recruits only original roster")
	game.command_bus.pending.clear()
	priest.stop()
	priest.position = Vector3.ZERO
	var victim: BattleUnit = game.spawn_unit("farmer",1,Vector3(0,0,-1.4))
	freeze(victim)
	priest.target = victim
	priest._start_attack()
	await create_timer(.18).timeout
	check(victim.hp == 150 and priest._model.attack.current_animation == "strike" and not priest._working,"punch winds up without healing")
	await create_timer(.11).timeout
	check(victim.hp == 147,"punch deals three melee damage after .25 seconds")
	priest.stop()
	check(priest._attack_cooldown == 1.5,"stop cannot refund punch cooldown")
	academy.production.recruit("priest")
	academy.production.research("attack_1")
	academy.production.destroyed()
	check(academy.production.training.is_empty() and academy.production.research_queue.is_empty() and player.reserved_military_supply == 0 and player.queued_research.is_empty(),"academy destruction clears both queues and reservations")
	for future: String in ["heavy_cannon","triple_cannon"]:
		check(not BalanceCatalog.UNITS.has(future),"later unit has not been started: "+future)
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open("res://.local/priest-20260913/integration-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	print("PRIEST_INTEGRATION ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
