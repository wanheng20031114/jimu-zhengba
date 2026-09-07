extends SceneTree
## Compares the same native scene and camera with several shadow offsets.

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	var game: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await process_frame
	game.tests_running = true
	game.camera_rig.edge_scroll = false
	game.get_node("EnemyTimer").stop()
	for entity in get_nodes_in_group("entities"):
		entity.set_physics_process(false)
	game.get_node("HUD").hide()
	var sun: DirectionalLight3D = game.get_node("Sun")
	var settings := [Vector2(0.035, 0.7), Vector2(0.035, 1.5), Vector2(0.06, 2.0), Vector2(0.1, 2.0)]
	for index in settings.size():
		sun.shadow_bias = settings[index].x
		sun.shadow_normal_bias = settings[index].y
		await create_timer(0.5).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://artifacts/shadow_" + str(index) + ".png")
	print("SHADOW_COMPARISON_SAVED")
	await game.prepare_shutdown()
	game.queue_free()
	current_scene = null
	await process_frame
	await process_frame
	quit()
