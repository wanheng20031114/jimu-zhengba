extends SceneTree
## Real factory commands, military population, research, targeting boundaries and AI.
var game: Node3D
var checks: int = 0
var failures: Array[String] = []
func _initialize() -> void: _run.call_deferred()
func check(ok: bool,label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func freeze(unit: BattleUnit) -> void:
	unit.stop()
	unit.set_physics_process(false)
	unit.navigation_agent.avoidance_enabled = false
func spawn(kind: String,at: Vector3,owner: int = 0) -> BattleUnit:
	var unit: BattleUnit = game.spawn_unit(kind,owner,at)
	freeze(unit)
	return unit
func building(kind: String) -> BattleBuilding:
	var at: Vector3 = game.find_build_location(0,kind,game.headquarters.position)
	check(at.is_finite(),"legal "+kind)
	var result: BattleBuilding = game.spawn_building(kind,0,at)
	result.set_physics_process(false)
	result.production.set_physics_process(false)
	return result
func _run() -> void:
	create_timer(90,true,false,true).timeout.connect(func():quit(3))
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
		if game.find_recruit_position("triple_cannon",factory).is_finite(): break
		await physics_frame
	game.select_entities([factory])
	game.hud._refresh_actions()
	check(game.hud._actions.any(func(a: Dictionary):return a.kind=="recruit" and a.id=="triple_cannon"),"clickable fifth factory production entry")
	player.gold = 279
	check(not factory.production.recruit("triple_cannon").ok and player.gold==279,"insufficient gold rejected without charge")
	player.gold = 20000
	var before: int = player.military_supply
	check(game.command_bus.execute({"kind":"recruit","target":factory.entity_id,"unit_type":"triple_cannon"},0).ok,"validated recruit command")
	check(player.gold==19720 and player.reserved_military_supply==3,"280 gold and three military slots reserved")
	factory.production._physics_process(21.99)
	check(factory.production.training.size()==1,"requires complete twenty-two seconds")
	factory.production._physics_process(.01)
	check(factory.production.training.is_empty() and player.military_supply==before+3 and player.reserved_military_supply==0,"training converts reservation once")
	var cannon: BattleUnit
	for unit: BattleUnit in game.owned_entities(0,"units"):
		if unit.unit_type=="triple_cannon": cannon=unit
	check(cannon!=null and cannon.hp==160 and cannon._model.batch_parts.size()==6,"production instantiates six-part batched model")
	freeze(cannon)
	check(cannon.speed==2.4 and cannon.radius==.95 and cannon.health_bar.position.y==2.0,"speed footprint and health bar match authored data")
	game.select_entities([cannon])
	check(game.own_selected_units()==[cannon] and game.own_selected_workers().is_empty(),"military selection excludes farmer operations")
	factory.production.recruit("triple_cannon")
	var gold: int = player.gold
	check(factory.production.cancel_training(0).ok and player.gold==gold+280 and player.reserved_military_supply==0,"full cancellation refund and population release")
	player.military_supply = player.get_supply_limit()-2
	gold = player.gold
	check(not factory.production.recruit("triple_cannon").ok and player.gold==gold,"two free slots cannot fit cannon")
	player.military_supply = before+3
	check(not barracks.production.recruit("triple_cannon").ok,"wrong production building rejected")
	var blockers: Array[BattleUnit] = []
	for attempt: int in 180:
		var at: Vector3 = game.find_recruit_position("triple_cannon",factory)
		if not at.is_finite(): break
		blockers.append(spawn("farmer",at))
		await physics_frame
	check(not game.find_recruit_position("triple_cannon",factory).is_finite(),"real blockers close factory exit")
	factory.production.recruit("triple_cannon")
	factory.production._physics_process(22)
	check(factory.production.training.size()==1 and player.reserved_military_supply==3,"blocked completion stays queued")
	for blocker: BattleUnit in blockers: blocker.queue_free()
	await physics_frame
	await physics_frame
	factory.production._physics_process(.3)
	check(factory.production.training.is_empty() and player.reserved_military_supply==0,"cleared exit spawns once")
	cannon.position = Vector3.ZERO
	var ordinary := spawn("cannon",Vector3(0,0,5))
	var heavy := spawn("heavy_cannon",Vector3(0,0,10))
	academy.production.research("cannon_range_1")
	academy.production._physics_process(30)
	var future := spawn("triple_cannon",Vector3(0,0,15))
	check(cannon.attack_range==7 and future.attack_range==7 and ordinary.attack_range==14 and heavy.attack_range==15,"range research affects only declared cannons")
	var target := spawn("swordsman",Vector3.ZERO,1)
	var radii: float = cannon.radius+target.radius
	for edge: float in [.99,1.01,6.99,7.01]:
		target.position = Vector3(0,0,-edge-radii)
		check(cannon._within_attack_range(target)==(edge>1 and edge<7),"edge distance boundary "+str(edge))
	var stats := BalanceCatalog.unit("triple_cannon")
	var payload := DamageResolver.snapshot(stats,0,0,0)
	var expected := {"swordsman":28,"spearman":29,"shield_guard":23,"knight":11,"archer":13}
	for kind: String in expected:
		check(DamageResolver.resolve(payload,BalanceCatalog.unit(kind))==expected[kind],"single shot damage "+kind)
	check(DamageResolver.resolve(payload,BalanceCatalog.building("barracks"))==8,"no building bonus or infantry bonus on buildings")
	check(DamageResolver.resolve(DamageResolver.snapshot(stats,3,0,0),BalanceCatalog.unit("swordsman"))==31,"attack tech adds direct damage only")
	check(DamageResolver.armor_for_channel(stats,CombatDefinition.DamageChannel.MELEE,3)==0 and DamageResolver.armor_for_channel(stats,CombatDefinition.DamageChannel.RANGED,3)==5,"siege defense preserves zero melee armor")
	check(DamageResolver.resolve(DamageResolver.snapshot(BalanceCatalog.unit("catapult"),0,1,1),stats)==44,"catapult siege bonus")
	check(DamageResolver.resolve(DamageResolver.snapshot(BalanceCatalog.unit("knight"),0,1,1),stats)==20,"knight siege bonus")
	var bot := SkirmishBot.new(game,0)
	bot._refresh_own_army()
	check(cannon in bot._army and bot._recruitment_role("triple_cannon")=="cannon","takeover handles triple cannon as existing siege role")
	bot._memory = {target.entity_id:{"building":false,"kind":"triple_cannon","seen_at":0.0}}
	check(bot._composition().siege==1,"new cannon contributes siege threat")
	bot._budget = 10000
	bot._recruit_army(0)
	check(game.command_bus.pending.all(func(c: Dictionary):return c.get("unit_type","") in ["","swordsman","spearman","archer","knight","catapult","cannon"]),"AI purchase roster unchanged")
	game.command_bus.pending.clear()
	factory.production.recruit("triple_cannon")
	factory.production.destroyed()
	check(factory.production.training.is_empty() and player.reserved_military_supply==0,"factory death clears reservation")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open("res://.local/triple-cannon-20260913/integration.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	print("TRIPLE_CANNON_INTEGRATION ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
