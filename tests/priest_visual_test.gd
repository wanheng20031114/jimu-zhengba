extends SceneTree
## Native codex, GPU healing and real batched battlefield verification.
const OUTPUT := "res://artifacts/model-previews/priest/"
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
	check(viewport.get_texture().get_image().save_png(OUTPUT+label+".png") == OK,label)
func _run() -> void:
	create_timer(100,true,false,true).timeout.connect(func(): quit(3))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	root.gui_disable_input = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var codex: Control = load("res://scenes/unit_codex.tscn").instantiate()
	root.add_child(codex)
	codex.open_codex()
	codex.select_entry(0,"priest")
	await create_timer(.4).timeout
	codex.set_process(false)
	var model: UnitVisual = codex._model
	var triangles: int = 0
	for mesh: MeshInstance3D in model.get_node("Rig").find_children("*","MeshInstance3D",true,false):
		triangles += mesh.mesh.get_faces().size()/3
	check(triangles <= 4500,"triangle budget")
	check(codex.get_node("%Stats").text.contains("3.5") and codex.get_node("%Stats").text.contains("180"),"approved values shown")
	check(codex.get_node("%PreviewGather").text == "治疗","treatment preview entry")
	await capture("codex",root)
	for angle: int in [0,45,90,180,270]:
		codex._anchor.rotation.y=deg_to_rad(angle)
		codex._request_preview_redraw()
		await capture("angle-%03d"%angle,codex.get_node("CodexViewport"))
	codex._anchor.rotation.y=0
	var camera_transform: Transform3D=codex._camera.transform
	var camera_size: float=codex._camera.size
	codex._camera.position=Vector3(3,2.8,-5)
	codex._camera.look_at(Vector3(0,1.65,0),Vector3.UP)
	codex._camera.size=1.15
	codex._request_preview_redraw()
	await capture("face",codex.get_node("CodexViewport"))
	codex._camera.transform=camera_transform
	codex._camera.size=camera_size
	for action: int in [1,2]:
		codex._select_preview_action(action)
		codex.set_process(false)
		codex._advance_preview(.2)
		for frame: int in 12:
			var player: AnimationPlayer=model.locomotion if action==1 else model.attack
			player.seek(frame*(.78 if action==1 else .7)/12.0,true)
			codex._request_preview_redraw()
			await capture("%s-%02d"%["walk" if action==1 else "strike",frame],codex.get_node("CodexViewport"))
	codex._select_preview_action(3)
	codex.set_process(false)
	check(codex.get_node("%SupportPreview").visible,"visible treatment recipient")
	check((-model.global_basis.z).dot((codex.get_node("%SupportPreview").global_position-model.global_position).normalized())>.99,"palms face the actual recipient")
	for frame: int in 12:
		codex._advance_preview(1.0/12.0)
		codex._request_preview_redraw()
		await capture("heal-%02d"%frame,codex.get_node("CodexViewport"))
	check(model.attack.current_animation=="heal","saved heal animation")
	check(model._support_particles.size()==2 and model._support_particles[0].emitting,"hand GPU emitters active")
	check(codex.get_node("%Healing/Motes") is GPUParticles3D and codex.get_node("%Healing").visible,"recipient GPU pulse")
	codex._toggle_preview_pause()
	check(model._support_particles[0].speed_scale==0 and codex.get_node("%Healing/Motes").speed_scale==0,"pausing freezes every healing emitter")
	codex._toggle_preview_pause()
	codex.set_process(false)
	codex._select_preview_action(0)
	codex.set_process(false)
	check(not codex.get_node("%SupportPreview").visible and not model._support_particles[0].emitting,"leaving treatment stops particles")
	codex._camera.position=Vector3(1,6,-1.5)
	codex._camera.look_at(Vector3(0,1,0),Vector3.UP)
	codex._camera.size=3.4
	codex._request_preview_redraw()
	await capture("top",codex.get_node("CodexViewport"))
	codex.queue_free()
	await process_frame
	var portraits: Node=load("res://scenes/model_previews.tscn").instantiate()
	root.add_child(portraits)
	await create_timer(.3).timeout
	await RenderingServer.frame_post_draw
	var bounds: Rect2i=portraits.portrait("priest").get_image().get_used_rect()
	check(bounds.size.x>40 and bounds.position.x>1 and bounds.end.x<191 and bounds.position.y>1 and bounds.end.y<215,"live portrait fits")
	portraits.queue_free()
	await process_frame
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	var game: Node3D=current_scene
	while not game._match_ready: await process_frame
	game.camera_rig.set_process(false)
	game.camera_rig.edge_scroll=false
	game.hud.get_node("Sidebar/Scroll/Content/Kinds/priest").pressed.emit()
	check(game.paint_kind=="priest" and game._ghost.kind=="priest","sandbox placement")
	game.set_placing(false)
	game.hud.hide()
	game.camera_rig.camera.size=8
	game.camera_rig.camera.position=Vector3(3,6,-10)
	game.camera_rig.camera.look_at(Vector3(0,.8,0),Vector3.UP)
	for entry: Array in [["engineer",-2.5],["priest",0],["swordsman",2.5]]:
		game.spawn_unit(entry[0],0,Vector3(entry[1],0,0))
	await capture("comparison",root)
	game.clear_units()
	await process_frame
	var priest: BattleUnit=game.spawn_unit("priest",0,Vector3(.7,0,1.8))
	var patient: BattleUnit=game.spawn_unit("swordsman",0,Vector3(-.8,0,-.5))
	patient.hp=30
	priest.issue_support(patient)
	game.select_entities([priest])
	game.set_running(true)
	await create_timer(.85).timeout
	check(priest._working and patient.hp==40,"actual first healing pulse")
	check(priest._model._support_particles[0].emitting,"batched rig also emits GPU hand particles")
	await capture("heal-battle",root)
	await create_timer(2).timeout
	for emitter: GPUParticles3D in priest._model._support_particles:
		print("HAND_GPU visible=",emitter.is_visible_in_tree()," speed=",emitter.speed_scale," emitting=",emitter.emitting," bounds=",emitter.capture_aabb())
	for effect: BattleEffect in game.get_node("EffectPool")._active:
		if effect.get_node("Healing").visible:
			var emitter: GPUParticles3D=effect.get_node("Healing/Motes")
			print("TARGET_GPU visible=",emitter.is_visible_in_tree()," speed=",emitter.speed_scale," emitting=",emitter.emitting," bounds=",emitter.capture_aabb())
	await capture("heal-battle",root)
	game.camera_rig.camera.size=26
	await capture("battle-scale",root)
	game.set_running(false)
	game.clear_units()
	await process_frame
	for owner: int in 3: game.spawn_unit("priest",owner,Vector3((owner-1)*2,0,0))
	game.camera_rig.camera.size=8
	await capture("teams",root)
	game.clear_units()
	await process_frame
	var corpse: BattleUnit=game.spawn_unit("priest",0,Vector3.ZERO)
	game.set_running(true)
	corpse.receive_damage(70)
	await create_timer(.55).timeout
	check(not corpse._model._support_particles[0].emitting,"death stops hand particles")
	await capture("death",root)
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open(OUTPUT+"visual-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"triangles":triangles,"failures":failures},"\t"))
	print("PRIEST_VISUAL ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
