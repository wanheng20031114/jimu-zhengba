extends SceneTree
## Audio shutdown lifecycle: release acknowledgment, paused restart, paused window close.
var game: Node3D
var failures: Array[String] = []
var checks: int = 0
var finished: bool = false

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, label: String) -> void:
	checks += 1
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures.append(label)

func _refs() -> Array[WeakRef]:
	var refs: Array[WeakRef] = []
	for branch: Node in game.get_node("Audio").get_children():
		for player: Node in branch.get_children():
			if player.has_stream_playback():
				refs.append(weakref(player.get_stream_playback()))
	return refs

func _run() -> void:
	create_timer(20.0).timeout.connect(func(): push_error("SHUTDOWN_LIFECYCLE deadline"); quit(3))
	# Keep the actual driver and mixer running without sending test sounds to
	# the speakers. This affects only this process and never saves preferences.
	AudioServer.set_bus_mute(0, true)
	print("LIFECYCLE_AUDIO_DRIVER ", AudioServer.get_driver_name())
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.camera_rig.edge_scroll = false
	await create_timer(0.35).timeout
	game.spawn_effect(game.headquarters.global_position, "muzzle")
	game.spawn_effect(game.headquarters.global_position + Vector3.RIGHT, "stone_hit")
	game.get_node("Audio").play_ui("coin")
	await process_frame
	var refs: Array[WeakRef] = _refs()
	_check(refs.size() >= 3, "real UI and positional playback instances are active")
	var begin: int = Time.get_ticks_usec()
	await game.prepare_shutdown()
	print("SHUTDOWN_RELEASE_MS ", float(Time.get_ticks_usec() - begin) / 1000.0)
	_check(refs.all(func(reference: WeakRef): return reference.get_ref() == null), "shutdown returns only after mixer releases every observed playback")
	_check(_refs().is_empty(), "all pool players retain no playback after stop")
	game.get_node("Audio").play_ui("coin")
	_check(_refs().is_empty(), "late UI input cannot reopen audio while closing")
	for unit: Node in get_nodes_in_group("units"):
		_check(not unit.navigation_agent.avoidance_enabled and not unit.is_physics_processing(), "shutdown halts native movement " + unit.name)
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.tests_running = true
	await create_timer(0.25).timeout
	var old_scene: WeakRef = weakref(game)
	refs = _refs()
	paused = true
	game.restart()
	await scene_changed
	game = current_scene
	await create_timer(0.3).timeout
	_check(not paused, "restart from pause resumes the scene tree")
	_check(old_scene.get_ref() == null, "restart releases the previous scene")
	_check(refs.all(func(reference: WeakRef): return reference.get_ref() == null), "restart releases the previous audio playbacks")
	_check(not game.get_node("Audio")._stopping and not game.get_node("Audio").has_node("Music"), "new scene owns fresh bounded audio pools without BGM")
	var report := FileAccess.open("res://artifacts/shutdown_lifecycle.json", FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks": checks, "failures": failures}, "  "))
	report.close()
	print("SHUTDOWN_LIFECYCLE ", checks, " checks; ", failures.size(), " failures")
	if not failures.is_empty():
		quit(1)
		return
	paused = true
	print("CLOSE_REQUEST_FROM_PAUSE")
	game.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
