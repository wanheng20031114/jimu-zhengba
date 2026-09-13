extends SceneTree
## Production, technology, saved rig geometry and old-roster AI on a real map.
var game: Node3D
var checks: int = 0
var failures: Array[String] = []
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
func building(kind: String) -> BattleBuilding:
	var at: Vector3 = game.find_build_location(0,kind,game.headquarters.position)
	check(at.is_finite(),"legal "+kind)
	var result: BattleBuilding = game.spawn_building(kind,0,at)
	result.set_physics_process(false)
	result.production.set_physics_process(false)
	return result
func spawn(kind: String, at: Vector3, owner: int = 0) -> BattleUnit:
	var result: BattleUnit = game.spawn_unit(kind,owner,at)
	freeze(result)
	return result
func _run() -> void:
	create_timer(90,true,false,true).timeout.connect(func(): quit(3))
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	game.tests_running = true
	game.bots.clear()
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	for unit: BattleUnit in get_nodes_in_group("units"): freeze(unit)
	for structure: BattleBuilding in get_nodes_in_group("buildings"):
		structure.set_physics_process(false)
		structure.production.set_physics_process(false)
	var player: PlayerState = game.get_player(0)
	player.gold = 20000
	var barracks := building("barracks")
	var factory := building("factory")
	var academy := building("academy")
	game.get_node("ConstructionNavigation").refresh()
	for attempt: int in 180:
		if game.find_recruit_position("heavy_cannon",factory).is_finite(): break
		await physics_frame
	check(game.find_recruit_position("heavy_cannon",factory).is_finite(),"wide four-wheel cannon has a navigable factory exit")
	game.select_entities([factory])
	game.hud._refresh_actions()
	check(game.hud._actions.any(func(a: Dictionary): return a.kind == "recruit" and a.id == "heavy_cannon"),"factory exposes clickable heavy cannon production")
	player.gold = 499
	check(not factory.production.recruit("heavy_cannon").ok and player.gold == 499,"insufficient money cannot queue or charge")
	player.gold = 20000
	var before: int = player.military_supply
	check(game.command_bus.execute({"kind":"recruit","target":factory.entity_id,"unit_type":"heavy_cannon"},0).ok,"validated recruit command")
	check(player.gold == 19500 and player.reserved_military_supply == 5,"500 gold reserves five military population")
	factory.production._physics_process(35.9)
	check(factory.production.training.size() == 1,"no spawn before thirty-six seconds")
	factory.production._physics_process(.1)
	check(factory.production.training.is_empty() and player.military_supply == before+5 and player.reserved_military_supply == 0,"training completes once and converts reservation")
	var heavy: BattleUnit
	for unit: BattleUnit in game.owned_entities(0,"units"):
		if unit.unit_type == "heavy_cannon": heavy = unit
	check(heavy != null and heavy.hp == 260 and heavy._model.batch_parts.size() == 7,"trained unit uses complete batched model")
	freeze(heavy)
	check(is_equal_approx(heavy.speed,1.8) and is_equal_approx(heavy.radius,1.15) and is_equal_approx(heavy.health_bar.position.y,2.6),"movement footprint and health bar use explicit data")
	game.select_entities([heavy])
	check(game.own_selected_units() == [heavy] and game.own_selected_workers().is_empty(),"heavy cannon selection is military")
	factory.production.recruit("heavy_cannon")
	var gold: int = player.gold
	check(factory.production.cancel_training(0).ok and player.gold == gold+500 and player.reserved_military_supply == 0,"cancellation refunds five hundred and population")
	player.military_supply = player.get_supply_limit()-4
	gold = player.gold
	check(not factory.production.recruit("heavy_cannon").ok and player.gold == gold,"four free population cannot fit a heavy cannon")
	player.military_supply = before+5
	check(not barracks.production.recruit("heavy_cannon").ok,"wrong building rejected")
	var blockers: Array[BattleUnit] = []
	for attempt: int in 180:
		var exit_at: Vector3 = game.find_recruit_position("heavy_cannon",factory)
		if not exit_at.is_finite(): break
		blockers.append(spawn("farmer",exit_at))
		await physics_frame
	check(not game.find_recruit_position("heavy_cannon",factory).is_finite(),"real blockers close wide exit")
	factory.production.recruit("heavy_cannon")
	factory.production._physics_process(36)
	check(factory.production.training.size() == 1 and player.reserved_military_supply == 5,"blocked exit preserves finished job")
	for blocker: BattleUnit in blockers: blocker.queue_free()
	await physics_frame
	await physics_frame
	factory.production._physics_process(.3)
	check(factory.production.training.is_empty() and player.reserved_military_supply == 0,"clearing exit completes exactly once")
	heavy.position = Vector3.ZERO
	var cannon := spawn("cannon",Vector3(0,0,5))
	var catapult := spawn("catapult",Vector3(0,0,10))
	var target := spawn("war_elephant",Vector3(14.5+2.3,0,0),1)
	check(heavy.attack_range == 14 and cannon.attack_range == 13 and not heavy._within_attack_range(target),"before research heavy range exceeds ordinary cannon by one")
	academy.production.research("cannon_range_1")
	academy.production._physics_process(29.99)
	check(heavy.attack_range == 14,"research requires full thirty seconds")
	academy.production._physics_process(.01)
	check(heavy.attack_range == 15 and cannon.attack_range == 14 and heavy._within_attack_range(target),"existing cannons receive declared range research")
	check(catapult.attack_range == 13 and heavy.min_attack_range == 3.5,"catapult and minimum range unchanged")
	var future := spawn("heavy_cannon",Vector3(0,0,15))
	check(future.attack_range == 15,"newly built cannon inherits research")
	target.position = Vector3(3.49+2.3,0,0)
	check(not heavy._within_attack_range(target),"minimum range uses unit edges")
	target.position.x = 3.51+2.3
	check(heavy._within_attack_range(target),"target just outside minimum is legal")
	var stats := BalanceCatalog.unit("heavy_cannon")
	var payload := DamageResolver.snapshot(stats,0,0,0)
	check(DamageResolver.resolve(payload,BalanceCatalog.building("barracks")) == 190,"190 damage against ten armor building")
	check(DamageResolver.resolve(payload,BalanceCatalog.unit("war_elephant")) == 97,"97 damage against elephant ranged armor")
	check(DamageResolver.resolve(DamageResolver.snapshot(stats,3,0,0),BalanceCatalog.building("barracks")) == 193,"attack technology increases direct damage without multiplying bonus")
	check(DamageResolver.armor_for_channel(stats,CombatDefinition.DamageChannel.MELEE,3) == 0 and DamageResolver.armor_for_channel(stats,CombatDefinition.DamageChannel.RANGED,3) == 5,"siege defense tech leaves melee armor zero")
	check(DamageResolver.resolve(DamageResolver.snapshot(BalanceCatalog.unit("catapult"),0,1,1),stats) == 44,"catapult siege bonus recognizes heavy cannon")
	check(DamageResolver.resolve(DamageResolver.snapshot(BalanceCatalog.unit("knight"),0,1,1),stats) == 20,"knight siege bonus recognizes heavy cannon")
	var bot := SkirmishBot.new(game,0)
	bot._refresh_own_army()
	check(heavy in bot._army and bot._recruitment_role("heavy_cannon") == "cannon","takeover maps heavy cannon into existing siege role")
	bot._memory = {target.entity_id:{"building":false,"kind":"heavy_cannon","seen_at":0.0}}
	check(bot._composition().siege == 1,"enemy heavy cannon contributes siege threat")
	bot._budget = 10000
	bot._recruit_army(0)
	check(game.command_bus.pending.all(func(c: Dictionary): return c.get("unit_type","") in ["","swordsman","spearman","archer","knight","catapult","cannon"]),"AI retains original purchase roster")
	game.command_bus.pending.clear()
	factory.production.recruit("heavy_cannon")
	factory.production.destroyed()
	check(factory.production.training.is_empty() and player.reserved_military_supply == 0,"factory destruction clears training reservation")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open("res://.local/heavy-cannon-20260913/integration-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	print("HEAVY_CANNON_INTEGRATION ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
