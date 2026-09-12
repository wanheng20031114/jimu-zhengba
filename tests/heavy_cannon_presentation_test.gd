extends SceneTree
## Final ordinary-match comparison and authentic batched long-barrel shot.
const OUTPUT := "res://artifacts/model-previews/heavy-cannon/"
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
func capture(name: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(OUTPUT+name+".png") == OK,name)
func _run() -> void:
	create_timer(35,true,false,true).timeout.connect(func(): quit(3))
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
	var heavy: BattleUnit = game.spawn_unit("heavy_cannon",0,at)
	freeze(heavy)
	var cannon: BattleUnit = game.spawn_unit("cannon",0,at+Vector3(-3.4,0,0))
	freeze(cannon)
	var engineer: BattleUnit = game.spawn_unit("engineer",0,at+Vector3(2.5,0,.5))
	freeze(engineer)
	game.select_entities([heavy])
	game.camera_rig.camera.position = at+Vector3(7,7,-11)
	game.camera_rig.camera.look_at(at+Vector3(0,.8,-.8),Vector3.UP)
	game.camera_rig.camera.size = 11
	await capture("battle-main")
	game.camera_rig.camera.size = 30
	await capture("battle-main-scale")
	game.camera_rig.camera.size = 11
	var target: BattleUnit = game.spawn_unit("war_elephant",1,at+Vector3(0,0,-10))
	freeze(target)
	var fog: FogOfWar = game.get_node("FogOfWar")
	fog.tick(.2)
	fog.apply_visibility(0)
	heavy.target = target
	check(heavy._valid_target(target) and heavy._within_attack_range(target),"visible real skirmish target in firing band")
	heavy._start_attack()
	await heavy.attack_windup.timeout
	check(game.get_node("ProjectilePool").launch_count == 1,"ordinary match uses the shared real cannonball pool")
	await capture("battle-main-fire")
	await create_timer(.7).timeout
	check(target.hp == 263,"ordinary-match long barrel hits for 97")
	# A stop/move during loading must let the saved recoil return to rest.
	heavy.issue_move(at+Vector3(0,0,5))
	heavy.set_physics_process(true)
	await create_timer(4).timeout
	var barrel: Node3D = heavy._model.get_node("Rig/Action/Elevation/Barrel")
	heavy._model.synchronize_animation()
	check(barrel.position.distance_to(Vector3(0,.05,0)) < .002,"movement during reload leaves no stuck recoil offset")
	heavy.stop()
	heavy.receive_damage(260)
	await create_timer(4.5).timeout
	check(not is_instance_valid(heavy),"wreck fades and releases the unit after death")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open(OUTPUT+"presentation-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	print("HEAVY_CANNON_PRESENTATION ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
