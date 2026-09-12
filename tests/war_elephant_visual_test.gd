extends SceneTree
## Native, rendered inspection of the current approved unit and real battlefield.
const OUTPUT := "res://artifacts/model-previews/war_elephant/"
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)

func capture(name: String, viewport: Viewport) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	check(viewport.get_texture().get_image().save_png(OUTPUT+name+".png") == OK,"rendered "+name)

func _run() -> void:
	create_timer(90.0,true,false,true).timeout.connect(func(): quit(3))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var codex: Control = load("res://scenes/unit_codex.tscn").instantiate()
	root.add_child(codex)
	codex.open_codex()
	codex.select_entry(0,"war_elephant")
	await create_timer(.4).timeout
	codex.set_process(false)
	check(codex._entries.size() == BalanceCatalog.UNITS.size(),"codex includes new unit")
	check(codex.get_node("%Stats").text.contains("360") and codex.get_node("%Stats").text.contains("300"),"codex displays agreed health and cost")
	var model: UnitVisual = codex._model
	model.locomotion.seek(0,true)
	model.attack.play("strike")
	model.attack.seek(0,true)
	model.attack.pause()
	var triangles: int = 0
	for part: MeshInstance3D in model.get_node("Rig").find_children("*","MeshInstance3D",true,false):
		triangles += part.mesh.get_faces().size()/3
	check(triangles <= 10000,"triangle budget")
	await capture("codex",root)
	for angle: int in [0,45,90,180,270]:
		codex._anchor.rotation.y = deg_to_rad(angle)
		codex._request_preview_redraw()
		await capture("angle-%03d" % angle,codex.get_node("CodexViewport"))
	codex._anchor.rotation.y=0
	codex._select_preview_action(2)
	codex.set_process(false)
	for phase: float in [0,.16,.34,.48,.55,.66,.90,1.23,1.55]:
		model.attack.seek(phase,true)
		var middle: Node3D = model.get_node("Rig/Action/BodyMotion/HeadMotion/TrunkSwing/TrunkUpper/TrunkMiddle")
		check(middle.position.is_equal_approx(Vector3(0,-.54,-.125)),"trunk joint stays attached during strike")
		if is_equal_approx(phase,.55):
			check(model.get_node("Rig/Action/BodyMotion/HeadMotion").rotation.x > .2,"head drives forward at authoritative contact")
		codex._request_preview_redraw()
		await capture("strike-%03d" % int(roundf(phase*100)),codex.get_node("CodexViewport"))
	model.attack.seek(.55,true)
	await capture("attack",root)
	codex._select_preview_action(1)
	codex.set_process(false)
	var previous: float=0
	for phase: float in [0,.155,.31,.465,.62,.93,1.24]:
		var elapsed: float=phase-previous
		var steps: int=ceili(elapsed*120)
		for step: int in steps:
			codex._advance_preview(elapsed/steps)
		previous=phase
		codex._request_preview_redraw()
		await capture("walk-%03d" % int(roundf(phase*100)),codex.get_node("CodexViewport"))
	codex._select_preview_action(0)
	codex.set_process(false)
	codex._camera.position=Vector3(0,3.25,-6)
	codex._camera.look_at(Vector3(0,3.19,0),Vector3.UP)
	codex._camera.size=1.15
	codex._request_preview_redraw()
	await capture("rider-face",codex.get_node("CodexViewport"))
	codex.queue_free()
	await process_frame
	var previews: Node=load("res://scenes/model_previews.tscn").instantiate()
	root.add_child(previews)
	await create_timer(.4).timeout
	await RenderingServer.frame_post_draw
	var portrait: Image=previews.portrait("war_elephant").get_image()
	var bounds: Rect2i=portrait.get_used_rect()
	check(bounds.size.x>45 and bounds.size.y>60,"readable elephant portrait")
	check(bounds.position.x>1 and bounds.position.y>1 and bounds.end.x<191 and bounds.end.y<215,"portrait does not clip trunk, rider or tusks")
	check(portrait.get_pixel(0,0).a<.01,"native portrait transparency")
	previews.queue_free()
	await process_frame
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	var game: Node3D=current_scene
	while not game._match_ready:
		await process_frame
	game.camera_rig.edge_scroll=false
	game.camera_rig.set_process(false)
	game.hud.get_node("Sidebar/Scroll/Content/Kinds/war_elephant").pressed.emit()
	check(game.paint_kind=="war_elephant" and game._ghost.kind=="war_elephant","sandbox placement preview")
	game.paint_count=1
	check(game.place_units(Vector3.ZERO)==1,"native sandbox placement")
	game.set_placing(false)
	var elephant: BattleUnit=game.owned_entities(0,"units")[0]
	var knight: BattleUnit=game.spawn_unit("knight",0,Vector3(-3.8,0,0))
	var sword: BattleUnit=game.spawn_unit("swordsman",0,Vector3(3.0,0,0))
	check(elephant._model.batch_parts.size()==14,"native fourteen-part battle model")
	game.select_entities([elephant])
	check(elephant.selected and elephant.radius==1.15 and is_equal_approx(elephant.health_bar.position.y,3.95),"footprint, selection and height")
	game.camera_rig.camera.size=14
	game.camera_rig.camera.position=Vector3(3,8,-12)
	game.camera_rig.camera.look_at(Vector3(0,1.2,-.2),Vector3.UP)
	game.hud.hide()
	await create_timer(.35).timeout
	await capture("comparison",root)
	game.camera_rig.camera.size=27
	await capture("battle-scale",root)
	for unit: BattleUnit in [knight,sword]:
		unit.queue_free()
	game.camera_rig.camera.size=10
	elephant.issue_move(Vector3(0,0,8))
	game.set_running(true)
	await create_timer(1.0).timeout
	check(elephant.position.z>1.8 and elephant._model.locomotion.current_animation==&"walk","live movement and gait")
	game.set_running(false)
	var stopped: Vector3=elephant.position
	await create_timer(.2).timeout
	check(elephant.position.is_equal_approx(stopped),"pause stops elephant")
	game.set_running(true)
	await create_timer(2.2).timeout
	check(elephant.position.distance_to(Vector3(0,0,8))<.9,"resume navigation")
	elephant.position=Vector3.ZERO
	elephant.reset_physics_interpolation()
	elephant.receive_damage(360)
	await create_timer(.55).timeout
	var corpse_floor: float=INF
	for path: NodePath in elephant._model.batch_parts:
		var part: Node3D=elephant._model.get_node(path)
		for vertex: Vector3 in elephant._model.batch_parts[path].get_faces():
			corpse_floor=minf(corpse_floor,(part.global_transform*vertex).y)
	check(corpse_floor>-.05 and corpse_floor<.18,"fallen elephant rests on the ground without sinking or floating")
	await capture("death",root)
	await create_timer(4.0).timeout
	check(game.get_node("UnitRenderBatches").registered_models==0,"death releases all batch parts")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open(OUTPUT+"visual-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"triangles":triangles,"portrait_bounds":str(bounds)},"\t"))
	print("ELEPHANT_VISUAL ",checks," checks; ",failures.size()," failures; ",triangles," triangles")
	quit(0 if failures.is_empty() else 1)
