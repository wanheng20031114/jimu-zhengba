extends SceneTree
## Final presentation frames come from the codex and the real match renderer.
const OUTPUT := "res://artifacts/model-previews/priest/"
var checks: int = 0
var failures: Array[String] = []
func _initialize() -> void: _run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func capture(name: String, viewport: Viewport) -> void:
	await RenderingServer.frame_post_draw
	check(viewport.get_texture().get_image().save_png(OUTPUT+name+".png") == OK,name)
func _run() -> void:
	create_timer(45,true,false,true).timeout.connect(func(): quit(3))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	root.gui_disable_input = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT+"motion"))
	var codex: Control = load("res://scenes/unit_codex.tscn").instantiate()
	root.add_child(codex)
	codex.open_codex()
	codex.select_entry(0,"priest")
	codex._select_preview_action(3)
	await create_timer(1.9).timeout
	var frames: Array[Dictionary] = []
	for index: int in 48:
		await create_timer(1.0/24).timeout
		var stamp: int = Time.get_ticks_msec()
		await capture("motion/heal-%03d"%index,codex.get_node("CodexViewport"))
		frames.append({"file":"heal-%03d.png"%index,"time_ms":stamp})
	FileAccess.open(OUTPUT+"motion/frames.json",FileAccess.WRITE).store_string(JSON.stringify(frames))
	await capture("healing-codex",root)
	codex.queue_free()
	await process_frame
	root.get_node("Session").config = root.get_node("Session").offline_config("2v2")
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
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	game.get_player(0).gold = 10000
	var barracks: BattleBuilding = game.spawn_building("barracks",0,game.find_build_location(0,"barracks",game.headquarters.position))
	barracks.set_physics_process(false)
	barracks.production.set_physics_process(false)
	var academy_at: Vector3 = game.find_build_location(0,"academy",game.headquarters.position)
	var center: Vector3 = academy_at+Vector3(0,0,-6.2)
	var academy: BattleBuilding = game.spawn_building("academy",0,academy_at)
	academy.set_physics_process(false)
	academy.production.set_physics_process(false)
	var priest: BattleUnit = game.spawn_unit("priest",0,center+Vector3(-1.7,0,0))
	var patient: BattleUnit = game.spawn_unit("swordsman",0,center+Vector3(1.0,0,-1))
	var engineer: BattleUnit = game.spawn_unit("engineer",0,center+Vector3(4.2,0,1))
	engineer.hold()
	patient.hp = 20
	patient.hold()
	priest.issue_support(patient)
	game.select_entities([priest])
	game.camera_rig.camera.global_position = center+Vector3(7,8,-12)
	game.camera_rig.camera.look_at(center+Vector3(0,1.2,1.5),Vector3.UP)
	game.camera_rig.camera.size = 12
	await create_timer(2.9).timeout
	check(patient.hp >= 40 and priest._working,"healing works on ordinary skirmish terrain")
	await capture("battle-main",root)
	game.camera_rig.camera.size = 30
	await capture("battle-main-scale",root)
	# The real fog gate suppresses unseen restoration effects, not only the model.
	var enemy: BattleUnit = game.spawn_unit("priest",2,Vector3(38,0,-25))
	var enemy_patient: BattleUnit = game.spawn_unit("swordsman",2,Vector3(35,0,-25))
	enemy_patient.hp = 30
	enemy_patient.hold()
	enemy.issue_support(enemy_patient)
	var fog: FogOfWar = game.get_node("FogOfWar")
	fog.tick(.2)
	fog.apply_visibility(0)
	check(not game.can_see_position(0,enemy_patient.position),"test enemy treatment is outside own vision")
	var count: int = game.get_node("EffectPool").active_count()
	game.spawn_effect(enemy_patient.position,"heal",Color("f2cd79"))
	check(game.get_node("EffectPool").active_count() == count,"unseen recipient pulse never reaches local effect pool")
	await create_timer(.85).timeout
	check(enemy_patient.hp == 40 and not enemy._model._support_particles[0].emitting,"unseen enemy heals authoritatively with no visible hand effect")
	game.get_node("EffectPool").reset_all()
	for index: int in 150: game.get_node("EffectPool").play(center,"heal",Color("f2cd79"))
	check(game.get_node("EffectPool").active_count() == 128,"healing burst respects saved visual pool capacity")
	var hp: float = patient.hp
	await create_timer(1.2).timeout
	check(patient.hp > hp,"effect pool saturation never suppresses health restoration")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open(OUTPUT+"presentation-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	print("PRIEST_PRESENTATION ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
