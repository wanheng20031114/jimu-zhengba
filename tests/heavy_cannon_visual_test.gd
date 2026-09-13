extends SceneTree
## Real native and batched renders; no offline imitation of the game renderer.
const OUTPUT := "res://artifacts/model-previews/heavy-cannon/"
var checks: int = 0
var failures: Array[String] = []
func _initialize() -> void: _run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func capture(name: String, viewport: Viewport) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	check(viewport.get_texture().get_image().save_png(OUTPUT+name+".png") == OK,name)
func _run() -> void:
	create_timer(100,true,false,true).timeout.connect(func(): quit(3))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	root.gui_disable_input = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT+"motion"))
	var codex: Control = load("res://scenes/unit_codex.tscn").instantiate()
	root.add_child(codex)
	codex.open_codex()
	codex.select_entry(0,"heavy_cannon")
	await create_timer(.4).timeout
	codex.set_process(false)
	var model: UnitVisual = codex._model
	var triangles: int = 0
	for mesh: MeshInstance3D in model.get_node("Rig").find_children("*","MeshInstance3D",true,false):
		triangles += mesh.mesh.get_faces().size()/3
	check(triangles <= 7500,"triangle budget")
	check(codex.get_node("%Stats").text.contains("500") and codex.get_node("%Stats").text.contains("260"),"approved codex values")
	check(codex.get_node("%PreviewAttack").text == "开炮","fire preview entry")
	await capture("codex",root)
	for angle: int in [0,45,90,135,180,270]:
		codex._anchor.rotation.y = deg_to_rad(angle)
		codex._request_preview_redraw()
		await capture("angle-%03d"%angle,codex.get_node("CodexViewport"))
	codex._anchor.rotation.y = 0
	var camera_transform: Transform3D = codex._camera.transform
	var camera_size: float = codex._camera.size
	codex._camera.position = Vector3(2.8,2.6,-6.5)
	codex._camera.look_at(model.get_projectile_origin(),Vector3.UP)
	codex._camera.size = 2.5
	codex._request_preview_redraw()
	await capture("muzzle",codex.get_node("CodexViewport"))
	codex._camera.position = Vector3(1,7,-1.5)
	codex._camera.look_at(Vector3(0,.8,0),Vector3.UP)
	codex._camera.size = camera_size
	codex._request_preview_redraw()
	await capture("top",codex.get_node("CodexViewport"))
	codex._camera.transform = camera_transform
	codex._camera.size = camera_size
	for action: int in [1,2]:
		codex._select_preview_action(action)
		codex.set_process(false)
		codex._advance_preview(.01)
		var player: AnimationPlayer = model.locomotion if action == 1 else model.attack
		var clip: Animation = player.get_animation("walk" if action == 1 else "strike")
		for frame: int in 84 if action == 2 else 16:
			var seconds: float = frame*.05 if action == 2 else frame*clip.length/16.0
			player.seek(seconds,true)
			codex._request_preview_redraw()
			await capture("motion/fire-%03d"%frame if action == 2 else "walk-%02d"%frame,codex.get_node("CodexViewport"))
		if action == 2:
			var at: float = player.current_animation_position
			codex._toggle_preview_pause()
			await process_frame
			check(player.current_animation_position == at,"preview pause holds recoil phase")
	codex.queue_free()
	await process_frame
	var portraits: Node = load("res://scenes/model_previews.tscn").instantiate()
	root.add_child(portraits)
	await create_timer(.4).timeout
	await RenderingServer.frame_post_draw
	var bounds: Rect2i = portraits.portrait("heavy_cannon").get_image().get_used_rect()
	print("PORTRAIT_BOUNDS ",bounds)
	portraits.portrait("heavy_cannon").get_image().save_png(OUTPUT+"portrait.png")
	check(bounds.size.x > 40 and bounds.position.x > 1 and bounds.end.x < 191 and bounds.position.y > 1 and bounds.end.y < 215,"live portrait fits")
	portraits.queue_free()
	await process_frame
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	var game: Node3D = current_scene
	while not game._match_ready: await process_frame
	game.camera_rig.set_process(false)
	game.hud.get_node("Sidebar/Scroll/Content/Kinds/heavy_cannon").pressed.emit()
	check(game.paint_kind == "heavy_cannon" and game._ghost.kind == "heavy_cannon","sandbox saved placement preview")
	game.set_placing(false)
	game.hud.hide()
	game.camera_rig.camera.position = Vector3(5,7,-12)
	game.camera_rig.camera.look_at(Vector3(0,1,0),Vector3.UP)
	game.camera_rig.camera.size = 10
	for entry: Array in [["cannon",-3.2],["heavy_cannon",.2],["engineer",3.1]]:
		game.spawn_unit(entry[0],0,Vector3(entry[1],0,0))
	await capture("comparison",root)
	game.clear_units()
	await process_frame
	for owner: int in 3:
		game.spawn_unit("heavy_cannon",owner,Vector3((owner-1)*3.2,0,1.6))
		game.spawn_unit("cannon",owner,Vector3((owner-1)*3.2,0,-2.0))
	game.camera_rig.camera.size = 12
	await capture("teams",root)
	game.camera_rig.camera.size = 30
	await capture("battle-scale",root)
	game.clear_units()
	await process_frame
	var corpse: BattleUnit = game.spawn_unit("heavy_cannon",0,Vector3.ZERO)
	game.camera_rig.camera.size = 7
	game.set_running(true)
	corpse.receive_damage(260)
	await create_timer(.55).timeout
	await capture("death",root)
	check(not corpse.alive,"heavy cannon uses ordinary death lifecycle")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open(OUTPUT+"visual-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"triangles":triangles,"failures":failures},"\t"))
	print("HEAVY_CANNON_VISUAL ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
