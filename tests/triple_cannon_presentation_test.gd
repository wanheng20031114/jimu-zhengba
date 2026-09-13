extends SceneTree
## Ordinary map with all seven authored additions and actual fire/repair/healing.
const OUTPUT := "res://artifacts/model-previews/triple-cannon/"
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
func capture(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(OUTPUT+name+".png")==OK,name)
func _run() -> void:
	create_timer(40,true,false,true).timeout.connect(func():quit(3))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	root.gui_disable_input = true
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	var game: Node3D = current_scene
	while not game._match_ready: await process_frame
	game.tests_running = true
	game.bots.clear()
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	game.hud.hide()
	game.camera_rig.set_process(false)
	for unit: BattleUnit in get_nodes_in_group("units"): unit.queue_free()
	await physics_frame
	await physics_frame
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	var at: Vector3 = game.headquarters.position+Vector3(-3,0,-12)
	var roster: Dictionary = {}
	var entries := {"triple_cannon":Vector3(0,0,1),"shield_guard":Vector3(-3,0,-1),"war_elephant":Vector3(5,0,1),"light_cavalry":Vector3(-5,0,1),"heavy_cannon":Vector3(2.5,0,4),"engineer":Vector3(2.5,0,2),"priest":Vector3(5,0,-1)}
	for kind: String in entries:
		var unit: BattleUnit = game.spawn_unit(kind,0,at+entries[kind])
		freeze(unit)
		roster[kind] = unit
	var cannon: BattleUnit = roster.triple_cannon
	var engineer: BattleUnit = roster.engineer
	var priest: BattleUnit = roster.priest
	var elephant: BattleUnit = roster.war_elephant
	var heavy: BattleUnit = roster.heavy_cannon
	elephant.hp = 260
	heavy.hp = 210
	engineer.issue_support(heavy)
	priest.issue_support(elephant)
	engineer.set_physics_process(true)
	priest.set_physics_process(true)
	game.get_player(0).gold = 0
	game.select_entities([cannon])
	game.camera_rig.camera.position = at+Vector3(8,12,-9)
	game.camera_rig.camera.look_at(at+Vector3(0,.8,0),Vector3.UP)
	game.camera_rig.camera.size = 17
	var targets: Array[BattleUnit] = []
	for x: float in [0,-2,2]:
		var target: BattleUnit = game.spawn_unit("swordsman",1,at+Vector3(x,0,-4.5))
		freeze(target)
		targets.append(target)
	game.get_node("FogOfWar").tick(.2)
	game.get_node("FogOfWar").apply_visibility(0)
	await create_timer(.2).timeout
	await capture("seven-units")
	cannon.target = targets[0]
	check(cannon._valid_target(targets[0]) and cannon._within_attack_range(targets[0]),"real map has visible targets in firing band")
	cannon._start_attack()
	await create_timer(.48).timeout
	await capture("battle-fire")
	await create_timer(.45).timeout
	check(targets.all(func(u: BattleUnit):return u.hp==82),"three real single-target hits on ordinary map")
	await create_timer(1.0).timeout
	check(heavy.hp>=220 and elephant.hp>=280 and game.get_player(0).gold==0,"heavy cannon repair and elephant healing run during combat for free")
	engineer.stop()
	priest.stop()
	engineer.set_physics_process(false)
	priest.set_physics_process(false)
	cannon.hp = 150
	engineer.position = cannon.position+Vector3(0,0,2)
	check(engineer.issue_support(cannon) and not priest.issue_support(cannon),"engineer repairs triple cannon; priest cannot heal siege")
	engineer.set_physics_process(true)
	await create_timer(1.05).timeout
	check(cannon.hp==155,"triple cannon receives five HP per effective repair second")
	engineer.stop()
	engineer.set_physics_process(false)
	for target: BattleUnit in targets: target.queue_free()
	await process_frame
	game.camera_rig.camera.size = 32
	await capture("battle-scale")
	cannon.issue_move(cannon.position+Vector3(0,0,5))
	cannon.set_physics_process(true)
	await create_timer(1.4).timeout
	cannon.stop()
	cannon._model.synchronize_animation()
	for i: int in 3:
		check(cannon._model.get_node("Rig/Action/Barrel%d"%i).position.distance_to(Vector3((i-1)*.5,1,-.1))<.002,"moving during reload returns gun to rest "+str(i))
	cannon.receive_damage(160)
	await create_timer(4.5).timeout
	check(not is_instance_valid(cannon),"three-gun wreck fades and releases all parts")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open(OUTPUT+"presentation-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	print("TRIPLE_CANNON_PRESENTATION ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
