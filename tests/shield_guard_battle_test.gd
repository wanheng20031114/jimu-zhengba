extends SceneTree
## Actual rendered combat, corpse lifecycle and 100/500-unit batch capacity.
const OUTPUT := "res://artifacts/model-previews/shield_guard/"
var checks: int = 0
var failures: Array[String] = []
var samples: Array[Dictionary] = []
var game: Node3D

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func capture(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(OUTPUT + name + ".png") == OK, "rendered " + name)

func clear_armies() -> void:
	game.set_running(false)
	game.clear_units()
	await process_frame
	await process_frame
	check(game.get_node("UnitRenderBatches").registered_models == 0, "all batch registrations released")

func _run() -> void:
	create_timer(100.0, true, false, true).timeout.connect(func(): quit(3))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	seed(121209)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	game.camera_rig.edge_scroll = false
	game.camera_rig.set_process(false)
	game.camera_rig.camera.size = 14
	game.camera_rig.camera.position = Vector3(4,10,-12)
	game.camera_rig.camera.look_at(Vector3(0,0.7,0),Vector3.UP)
	game.set_placing(false)
	game.hud.hide()
	for i: int in 5:
		game.spawn_unit("shield_guard", 0, Vector3((i-2)*1.6, 0, -2.8))
		game.spawn_unit("knight", 1, Vector3((i-2)*1.6, 0, 2.8))
	game.set_running(true)
	await create_timer(3.2).timeout
	check(game.owned_entities(0,"units").any(func(u: BattleUnit): return u.hp < u.max_hp), "shield guards take real combat damage")
	check(game.owned_entities(1,"units").any(func(u: BattleUnit): return u.hp < u.max_hp), "shield guard attacks damage enemy cavalry")
	await capture("combat")
	await clear_armies()
	var corpse: BattleUnit = game.spawn_unit("shield_guard", 0, Vector3.ZERO)
	var corpse_id: int = corpse.get_instance_id()
	game.camera_rig.camera.size = 6
	game.set_running(true)
	corpse.receive_damage(145)
	await create_timer(.55).timeout
	check(not corpse.alive and not corpse._model.attack.is_playing(), "real death cancels attacks")
	await capture("death")
	await create_timer(4.1).timeout
	check(not is_instance_id_valid(corpse_id), "corpse is freed after its authored fall and fade")
	check(game.get_node("UnitRenderBatches").registered_models == 0, "death releases all shield batch slots")
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	for total: int in [100, 500]:
		game.set_running(false)
		var army_size: int = total / 2
		for i: int in army_size:
			var row: int = i / 20
			var x: float = (i % 20 - 9.5) * 1.5
			game.spawn_unit("shield_guard", 0, Vector3(x, 0, -2.5-row*1.5))
			game.spawn_unit("knight" if i % 2 == 0 else "archer", 1, Vector3(x, 0, 2.5+row*1.5))
		check(game.sandbox_unit_count == total, "spawn complete %d-unit armies" % total)
		check(game.get_node("UnitRenderBatches").registered_models == total, "register complete %d-unit armies" % total)
		game.camera_rig.camera.size = 48
		game.set_running(true)
		await create_timer(2.0).timeout
		var frames: Array[float] = []
		var previous := Time.get_ticks_usec()
		var deadline := previous + 6000000
		while Time.get_ticks_usec() < deadline:
			await process_frame
			var now := Time.get_ticks_usec()
			frames.append((now-previous)/1000.0)
			previous = now
		frames.sort()
		samples.append({"initial_units":total,"remaining_units":game.sandbox_unit_count,"frame_median_ms":frames[frames.size()/2],"frame_p95_ms":frames[int(frames.size()*.95)]})
		check(game.sandbox_unit_count < total or game.owned_entities(0,"units").any(func(u: BattleUnit): return u.hp < u.max_hp), "damage remains active in %d-unit battle" % total)
		check(game.get_node("UnitRenderBatches").visible_models > 0, "battle remains rendered at %d units" % total)
		await clear_armies()
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open(OUTPUT + "battle-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"samples":samples,"limitation":"User editor/game remain open; frame times are observational."},"\t"))
	print("SHIELD_BATTLE ",checks," checks; ",failures.size()," failures; ",JSON.stringify(samples))
	quit(0 if failures.is_empty() else 1)
