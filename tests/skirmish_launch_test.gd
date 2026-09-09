extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	var game := current_scene
	for tick in range(12):
		await physics_frame
	assert(game.get_player(0).gold >= 320)
	assert(game.headquarters.max_hp == 3000)
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("SKIRMISH_LAUNCH_PASS")
	quit()
