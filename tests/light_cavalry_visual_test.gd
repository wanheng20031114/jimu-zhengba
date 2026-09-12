extends SceneTree
## Inspect saved native art in the codex, portraits and actual batched battlefield.
const OUTPUT := "res://artifacts/model-previews/light_cavalry/"
var checks: int=0
var failures: Array[String]=[]
func _initialize() -> void:
	_run.call_deferred()
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func capture(name: String,viewport: Viewport) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	check(viewport.get_texture().get_image().save_png(OUTPUT+name+".png")==OK,"rendered "+name)
func _run() -> void:
	create_timer(80.0,true,false,true).timeout.connect(func(): quit(3))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var codex: Control=load("res://scenes/unit_codex.tscn").instantiate()
	root.add_child(codex)
	codex.open_codex()
	codex.select_entry(0,"light_cavalry")
	await create_timer(.4).timeout
	codex.set_process(false)
	check(codex._entries.size()==BalanceCatalog.UNITS.size(),"codex includes light cavalry")
	check(codex.get_node("%Stats").text.contains("90") and codex.get_node("%Stats").text.contains("6.8"),"codex uses actual health and speed")
	var model: UnitVisual=codex._model
	model.locomotion.seek(0,true)
	var triangles: int=0
	for part: MeshInstance3D in model.get_node("Rig").find_children("*","MeshInstance3D",true,false):
		triangles+=part.mesh.get_faces().size()/3
	check(triangles<=8000,"approved triangle budget")
	await capture("codex",root)
	for angle: int in [0,45,90,180,270]:
		codex._anchor.rotation.y=deg_to_rad(angle)
		codex._request_preview_redraw()
		await capture("angle-%03d" % angle,codex.get_node("CodexViewport"))
	codex._anchor.rotation.y=0
	codex._select_preview_action(2)
	codex.set_process(false)
	for phase: float in [0,.07,.145,.18,.20,.25,.40,.62,.85]:
		model.attack.seek(phase,true)
		var sword: Node3D=model.get_node("Rig/Action/BodyMotion/Waist/ArmRight/Sword")
		check(sword.position.is_equal_approx(Vector3(.09,-.42,-.22)),"blade remains attached to hand")
		codex._request_preview_redraw()
		await capture("strike-%03d" % int(roundf(phase*100)),codex.get_node("CodexViewport"))
	model.attack.seek(.20,true)
	await capture("attack",root)
	codex._select_preview_action(1)
	codex.set_process(false)
	for step: int in 60: codex._advance_preview(.008)
	for frame: int in 8:
		for step: int in 6: codex._advance_preview(.01)
		codex._request_preview_redraw()
		await capture("walk-%02d" % frame,codex.get_node("CodexViewport"))
	codex._select_preview_action(0)
	codex.set_process(false)
	codex._camera.position=Vector3(0,2.3,-6)
	codex._camera.look_at(Vector3(0,2.23,0),Vector3.UP)
	codex._camera.size=1.0
	codex._request_preview_redraw()
	await capture("rider-face",codex.get_node("CodexViewport"))
	codex._camera.position=Vector3(1,6,-1.5)
	codex._camera.look_at(Vector3(0,1.2,0),Vector3.UP)
	codex._camera.size=3.8
	codex._request_preview_redraw()
	await capture("top",codex.get_node("CodexViewport"))
	codex.queue_free()
	await process_frame
	var previews: Node=load("res://scenes/model_previews.tscn").instantiate()
	root.add_child(previews)
	await create_timer(.4).timeout
	await RenderingServer.frame_post_draw
	var portrait: Image=previews.portrait("light_cavalry").get_image()
	var bounds: Rect2i=portrait.get_used_rect()
	check(bounds.size.x>45 and bounds.size.y>60,"readable native portrait")
	check(bounds.position.x>1 and bounds.position.y>1 and bounds.end.x<191 and bounds.end.y<215,"portrait does not clip")
	check(portrait.get_pixel(0,0).a<.01,"portrait transparency")
	previews.queue_free()
	await process_frame
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	var game: Node3D=current_scene
	while not game._match_ready: await process_frame
	game.camera_rig.edge_scroll=false
	game.camera_rig.set_process(false)
	game.hud.get_node("Sidebar/Scroll/Content/Kinds/light_cavalry").pressed.emit()
	check(game.paint_kind=="light_cavalry" and game._ghost.kind=="light_cavalry","sandbox placement ghost")
	game.paint_count=1
	check(game.place_units(Vector3.ZERO)==1,"native sandbox placement")
	game.set_placing(false)
	var cavalry: BattleUnit=game.owned_entities(0,"units")[0]
	var knight: BattleUnit=game.spawn_unit("knight",0,Vector3(-3.3,0,0))
	var sword: BattleUnit=game.spawn_unit("swordsman",0,Vector3(2.6,0,0))
	check(cavalry._model.batch_parts.size()==19,"nineteen-part native battle model")
	game.select_entities([cavalry])
	check(cavalry.selected and cavalry.radius==.75 and is_equal_approx(cavalry.health_bar.position.y,3.05),"selection circle and health bar")
	game.camera_rig.camera.size=11
	game.camera_rig.camera.position=Vector3(3,7,-12)
	game.camera_rig.camera.look_at(Vector3(0,1.0,-.2),Vector3.UP)
	game.hud.hide()
	await create_timer(.35).timeout
	await capture("comparison",root)
	game.camera_rig.camera.size=27
	await capture("battle-scale",root)
	for unit: BattleUnit in [knight,sword]: unit.queue_free()
	game.camera_rig.camera.size=9
	cavalry.issue_move(Vector3(0,0,10))
	game.set_running(true)
	await create_timer(.7).timeout
	check(cavalry.position.z>2 and cavalry._model.locomotion.current_animation==&"walk","live movement plays saved gait")
	game.set_running(false)
	var stopped: Vector3=cavalry.position
	await create_timer(.2).timeout
	check(cavalry.position.is_equal_approx(stopped),"pause stops movement")
	game.set_running(true)
	await create_timer(2).timeout
	check(cavalry.position.distance_to(Vector3(0,0,10))<.75,"resume reaches destination")
	cavalry.position=Vector3.ZERO
	cavalry.reset_physics_interpolation()
	cavalry.receive_damage(90)
	await create_timer(.55).timeout
	var floor_y: float=INF
	for path: NodePath in cavalry._model.batch_parts:
		var part: Node3D=cavalry._model.get_node(path)
		for vertex: Vector3 in cavalry._model.batch_parts[path].get_faces():
			floor_y=minf(floor_y,(part.global_transform*vertex).y)
	check(floor_y>-.06 and floor_y<.18,"corpse rests on the ground")
	print("LIGHT_CORPSE_FLOOR ",floor_y)
	await capture("death",root)
	await create_timer(4).timeout
	check(game.get_node("UnitRenderBatches").registered_models==0,"death releases native batch parts")
	game.set_running(false)
	for owner: int in 3:
		game.spawn_unit("light_cavalry",owner,Vector3((owner-1)*3,0,0))
	game.camera_rig.camera.size=10
	game.camera_rig.camera.position=Vector3(2,7,-12)
	game.camera_rig.camera.look_at(Vector3(0,1.0,0),Vector3.UP)
	await create_timer(1.0).timeout
	await capture("teams",root)
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open(OUTPUT+"visual-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"triangles":triangles,"portrait_bounds":str(bounds)},"\t"))
	print("LIGHT_CAVALRY_VISUAL ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
