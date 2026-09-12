extends "res://tests/engagement_approach_test.gd"
## Reuse the existing intent/displacement probe with the production controller.
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.local/engineer-20260912"))
	create_timer(40,true,false,true).timeout.connect(func(): quit(3))
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game=current_scene
	while not game._match_ready: await process_frame
	game.set_placing(false)
	for rate: int in [30,60]:
		Engine.physics_ticks_per_second=rate
		await duel("engineer",true,true,0.0)
		await duel("engineer",true,true,PI*.5,"light_cavalry")
	game.set_running(false)
	game.clear_units()
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open("res://.local/engineer-20260912/approach-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"cases":cases},"\t"))
	print("ENGINEER_APPROACH ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
