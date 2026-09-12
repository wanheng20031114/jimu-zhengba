extends "res://tests/engagement_approach_test.gd"
## Real intent and displacement regression for the unarmed infantry rig.
func _run() -> void:
	create_timer(40,true,false,true).timeout.connect(func(): quit(3))
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	game.set_placing(false)
	for rate: int in [30,60]:
		Engine.physics_ticks_per_second = rate
		await duel("priest",true,true,0.0)
		await duel("priest",true,true,PI*.5,"light_cavalry")
	game.set_running(false)
	game.clear_units()
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open("res://.local/priest-20260913/approach-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"cases":cases},"\t"))
	print("PRIEST_APPROACH ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
