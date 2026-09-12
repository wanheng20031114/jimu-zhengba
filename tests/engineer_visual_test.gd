extends SceneTree
## Real native codex and batched battlefield renders, with authored action samples.
const OUTPUT := "res://artifacts/model-previews/engineer/"
var failures: Array[String] = []
var checks: int = 0
func _initialize() -> void: _run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)
func capture(label: String, viewport: Viewport) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	check(viewport.get_texture().get_image().save_png(OUTPUT+label+".png") == OK, label)
func _run() -> void:
	create_timer(90,true,false,true).timeout.connect(func(): quit(3))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	root.gui_disable_input = true # Keep capture poses independent of desktop input.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var codex: Control = load("res://scenes/unit_codex.tscn").instantiate()
	root.add_child(codex)
	codex.open_codex()
	codex.select_entry(0,"engineer")
	await create_timer(.4).timeout
	codex.set_process(false)
	var model: UnitVisual = codex._model
	var triangles: int = 0
	for mesh: MeshInstance3D in model.get_node("Rig").find_children("*","MeshInstance3D",true,false):
		triangles += mesh.mesh.get_faces().size()/3
	check(triangles <= 4500,"triangle budget")
	check(codex.get_node("%Stats").text.contains("3.5"),"approved movement shown")
	await capture("codex",root)
	for angle: int in [0,45,90,180,270]:
		codex._anchor.rotation.y = deg_to_rad(angle)
		codex._request_preview_redraw()
		await capture("angle-%03d" % angle,codex.get_node("CodexViewport"))
	codex._anchor.rotation.y = 0
	# Inspect the tool grip and cap at native rendering resolution before actions.
	var camera_transform: Transform3D = codex._camera.transform
	var camera_size: float = codex._camera.size
	codex._camera.position = Vector3(3,2,-5)
	codex._camera.look_at(Vector3(.36,1.17,-.30),Vector3.UP)
	codex._camera.size = .95
	codex._request_preview_redraw()
	await capture("grip-detail",codex.get_node("CodexViewport"))
	codex._camera.position = Vector3(2,2.6,-4)
	codex._camera.look_at(Vector3(0,1.77,0),Vector3.UP)
	codex._camera.size = 1.0
	codex._request_preview_redraw()
	await capture("cap-detail",codex.get_node("CodexViewport"))
	codex._camera.transform = camera_transform
	codex._camera.size = camera_size
	for action: int in [1,2,3]:
		codex._select_preview_action(action)
		codex.set_process(false)
		codex._advance_preview(.2) # Finish the real action transition before sampling.
		for frame: int in 12:
			var player: AnimationPlayer = model.locomotion if action == 1 else model.attack
			var length: float = .76 if action == 1 else (.72 if action == 2 else 1.0)
			player.seek(frame*length/12.0,true)
			if action==1 and frame==3:
				check(absf(model.get_node("Rig/Action/LegLeft").rotation.x)>.4,"saved walking clip swings the leg")
			codex._request_preview_redraw()
			await capture("%s-%02d" % [["walk","strike","repair"][action-1],frame],codex.get_node("CodexViewport"))
	check(model.attack.current_animation == "repair","codex repair entry plays saved repair")
	codex._camera.position = Vector3(1,6,-1.5)
	codex._camera.look_at(Vector3(0,1,0),Vector3.UP)
	codex._camera.size = 3.4
	codex._request_preview_redraw()
	await capture("top",codex.get_node("CodexViewport"))
	codex.queue_free()
	await process_frame
	var previews: Node = load("res://scenes/model_previews.tscn").instantiate()
	root.add_child(previews)
	await create_timer(.4).timeout
	await RenderingServer.frame_post_draw
	var portrait: Image = previews.portrait("engineer").get_image()
	var bounds := portrait.get_used_rect()
	check(bounds.size.x>40 and bounds.position.x>1 and bounds.end.x<191 and bounds.position.y>1 and bounds.end.y<215,"portrait fits")
	previews.queue_free()
	await process_frame
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	var game: Node3D = current_scene
	while not game._match_ready: await process_frame
	game.camera_rig.set_process(false)
	game.camera_rig.edge_scroll = false
	game.hud.get_node("Sidebar/Scroll/Content/Kinds/engineer").pressed.emit()
	check(game.paint_kind=="engineer" and game._ghost.kind=="engineer","sandbox placement entry")
	game.set_placing(false)
	game.hud.hide()
	game.camera_rig.camera.size = 9
	game.camera_rig.camera.position = Vector3(3,6,-10)
	game.camera_rig.camera.look_at(Vector3(0,.8,0),Vector3.UP)
	for entry: Array in [["swordsman",-3],["engineer",0],["farmer",3]]:
		game.spawn_unit(entry[0],0,Vector3(entry[1],0,0))
	await capture("comparison",root)
	game.clear_units()
	await process_frame
	var engineer: BattleUnit = game.spawn_unit("engineer",0,Vector3(0,0,-1.8))
	var cannon: BattleUnit = game.spawn_unit("cannon",0,Vector3(0,0,1))
	cannon.hp = 50
	engineer.issue_support(cannon)
	game.select_entities([engineer])
	game.set_running(true)
	await create_timer(1.8).timeout
	check(engineer._working and cannon.hp>50,"actual battlefield repair and recovery")
	await capture("repair-battle",root)
	game.camera_rig.camera.size = 26
	await capture("battle-scale",root)
	game.set_running(false)
	game.clear_units()
	await process_frame
	for owner: int in 3: game.spawn_unit("engineer",owner,Vector3((owner-1)*2,0,0))
	game.camera_rig.camera.size = 8
	await capture("teams",root)
	game.clear_units()
	await process_frame
	var corpse: BattleUnit=game.spawn_unit("engineer",0,Vector3.ZERO)
	game.set_running(true)
	corpse.receive_damage(80)
	await create_timer(.55).timeout
	for angle: float in [-1.35,1.35]:
		corpse.model_pivot.rotation.z=angle
		var floor_y: float=INF
		for path: NodePath in corpse._model.batch_parts:
			var part: Node3D=corpse._model.get_node(path)
			for vertex: Vector3 in corpse._model.batch_parts[path].get_faces():
				floor_y=minf(floor_y,(part.global_transform*vertex).y)
		print("ENGINEER_CORPSE_FLOOR angle=",angle," y=",floor_y)
		check(floor_y>-.08 and floor_y<.2,"corpse and carried tool rest on either side")
	await capture("death",root)
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open(OUTPUT+"visual-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"triangles":triangles,"failures":failures},"\t"))
	print("ENGINEER_VISUAL ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
