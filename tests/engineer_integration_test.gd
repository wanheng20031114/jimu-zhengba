extends SceneTree
var checks: int=0
var failures: Array[String]=[]
var game: Node3D
func _initialize() -> void: _run.call_deferred()
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.local/engineer-20260912"))
	create_timer(65,true,false,true).timeout.connect(func(): quit(3))
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game=current_scene
	while not game._match_ready: await process_frame
	game.tests_running=true
	game.bots.clear()
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled=false
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	var player: PlayerState=game.get_player(0)
	player.gold=10000
	var barracks_at: Vector3=game.find_build_location(0,"barracks",game.headquarters.position)
	check(barracks_at.is_finite(),"legal prerequisite barracks location")
	var barracks: BattleBuilding=game.spawn_building("barracks",0,barracks_at)
	barracks.set_physics_process(false)
	barracks.production.set_physics_process(false)
	var factory_at: Vector3=game.find_build_location(0,"factory",game.headquarters.position)
	check(factory_at.is_finite(),"legal factory location after barracks prerequisite")
	var factory: BattleBuilding=game.spawn_building("factory",0,factory_at)
	factory.set_physics_process(false)
	factory.production.set_physics_process(false)
	game.get_node("ConstructionNavigation").refresh()
	await create_timer(.5).timeout
	for attempt: int in 120:
		if game.find_recruit_position("engineer",factory).is_finite(): break
		await physics_frame
	print("ENGINEER_EXIT factory=",factory.position," exit=",game.find_recruit_position("engineer",factory)," cannon_exit=",game.find_recruit_position("cannon",factory))
	if not game.find_recruit_position("engineer",factory).is_finite():
		printerr("FAIL factory has no navigable exit in test fixture")
		await game.prepare_shutdown()
		quit(2)
		return
	var before: int=player.military_supply
	player.gold=79
	check(not factory.production.recruit("engineer").ok and player.gold==79,"gold shortage leaves resources intact")
	player.gold=10000
	check(game.command_bus.execute({"kind":"recruit","target":factory.entity_id,"unit_type":"engineer"},0).ok,"factory command recruits engineer")
	check(player.gold==9920 and player.reserved_military_supply==1,"eighty gold reserves one military population")
	factory.production._physics_process(9.9)
	check(factory.production.training.size()==1 and player.military_supply==before,"training does not finish early")
	factory.production._physics_process(.11)
	check(factory.production.training.is_empty() and player.military_supply==before+1 and player.reserved_military_supply==0,"ten second completion converts reservation")
	var engineer: BattleUnit
	for unit: BattleUnit in game.owned_entities(0,"units"):
		if unit.unit_type=="engineer": engineer=unit
	check(engineer!=null and engineer.hp==80 and engineer._model.batch_parts.size()==9,"production spawns correct native model")
	engineer.stop()
	engineer.set_physics_process(false)
	engineer.navigation_agent.avoidance_enabled=false
	game.select_entities([engineer])
	check(game.own_selected_workers().is_empty() and game.own_selected_units()==[engineer],"military selection excludes worker controls")
	game.select_entities([factory])
	game.hud._refresh_actions()
	check(game.hud._actions.any(func(a: Dictionary): return a.kind=="recruit" and a.id=="engineer"),"factory exposes engineer training button")
	check(factory.production.recruit("engineer").ok,"can queue again")
	var gold: int=player.gold
	check(factory.production.cancel_training(0).ok and player.gold==gold+80 and player.reserved_military_supply==0,"cancel refunds gold and population")
	var supply: int=player.military_supply
	player.military_supply=player.get_supply_limit()
	gold=player.gold
	check(not factory.production.recruit("engineer").ok and player.gold==gold,"population shortage rejects without charging")
	player.military_supply=supply
	check(not game.headquarters.production.recruit("engineer").ok,"headquarters cannot train engineer")
	# Filled exits retain the completed job, then spawn exactly once when cleared.
	var blockers: Array[BattleUnit]=[]
	for attempt: int in 160:
		var at: Vector3=game.find_recruit_position("engineer",factory)
		if not at.is_finite(): break
		var blocker: BattleUnit=game.spawn_unit("farmer",0,at)
		blocker.set_physics_process(false)
		blocker.navigation_agent.avoidance_enabled=false
		blockers.append(blocker)
		await physics_frame
	check(not game.find_recruit_position("engineer",factory).is_finite(),"real blockers close factory exit")
	factory.production.recruit("engineer")
	factory.production._physics_process(10)
	check(factory.production.training.size()==1 and player.reserved_military_supply==1,"blocked completion keeps reservation")
	for blocker: BattleUnit in blockers: blocker.queue_free()
	await physics_frame
	await physics_frame
	factory.production._physics_process(.3)
	check(factory.production.training.is_empty() and player.reserved_military_supply==0,"cleared exit completes once")
	factory.production.recruit("engineer")
	var bot:=SkirmishBot.new(game,0)
	bot._refresh_own_army()
	check(engineer in bot._supporters and engineer not in bot._army,"bot takeover classifies engineer as support")
	bot._memory={1:{"building":false,"kind":"engineer","seen_at":0.0}}
	check(bot._composition().support==1,"enemy support classification")
	bot._budget=10000
	bot._recruit_army(0)
	check(game.command_bus.pending.all(func(c: Dictionary): return c.get("unit_type","") not in ["engineer","light_cavalry","war_elephant","shield_guard"]),"AI retains old recruitment roster with inherited training queue")
	game.command_bus.pending.clear()
	factory.production.destroyed()
	check(factory.production.training.is_empty() and player.reserved_military_supply==0,"producer destruction releases queued engineer")
	var victim: BattleUnit=game.spawn_unit("farmer",1,Vector3(0,0,-1.4))
	victim.set_physics_process(false)
	engineer.position=Vector3.ZERO
	engineer.target=victim
	engineer._start_attack()
	await create_timer(.23).timeout
	check(victim.hp==150,"tool strike waits .30 second windup")
	await create_timer(.12).timeout
	check(victim.hp==147,"tool strike applies three melee damage")
	engineer.stop()
	check(engineer._attack_cooldown==1.5,"stop cannot refund attack cycle")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open("res://.local/engineer-20260912/integration-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	print("ENGINEER_INTEGRATION ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
