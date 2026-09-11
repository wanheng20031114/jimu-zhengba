extends SceneTree

const OUT := "res://report/engagement-20260911/"

func _initialize() -> void:
	_run.call_deferred()

func capture(name: String, viewport: Viewport) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(OUT + name + ".png")

func _run() -> void:
	create_timer(45, true, false, true).timeout.connect(func(): quit(3))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	var codex: Control = load("res://scenes/unit_codex.tscn").instantiate()
	root.add_child(codex)
	codex.open_codex()
	codex.select_entry(0, "spearman")
	await create_timer(0.4).timeout
	codex.set_process(false)
	codex._camera.position = Vector3(0, 1.7, -7)
	codex._camera.look_at(Vector3(0, 1.5, 0), Vector3.UP)
	codex._camera.size = 1.15
	codex._request_preview_redraw()
	await capture("spearman-face", codex.get_node("CodexViewport"))
	codex._anchor.rotation.y = PI
	codex._request_preview_redraw()
	await capture("spearman-back", codex.get_node("CodexViewport"))
	codex.queue_free()
	await process_frame
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	var game: Node3D = current_scene
	while not game._match_ready:
		await process_frame
	game.set_placing(false)
	game.camera_rig.edge_scroll = false
	game.camera_rig.set_process(false)
	game.camera_rig.camera.size = 11.0
	game.camera_rig.camera.position = Vector3(0, 12, 18)
	game.camera_rig.camera.look_at(Vector3(0, 0.8, 0), Vector3.UP)
	game.hud.hide()
	var infantry: BattleUnit = game.spawn_unit("spearman", 0, Vector3(-6, 0, 0))
	var cavalry: BattleUnit = game.spawn_unit("knight", 1, Vector3(6, 0, 0))
	infantry.max_hp = 10000
	infantry.hp = 10000
	cavalry.max_hp = 10000
	cavalry.hp = 10000
	infantry.issue_attack(cavalry)
	cavalry.issue_attack(infantry)
	game.set_running(true)
	for index: int in range(10):
		await create_timer(0.2).timeout
		await capture("duel-%02d" % index, root)
	game.set_running(false)
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("DETAIL_AND_DUEL_CAPTURE_COMPLETE")
	quit()
