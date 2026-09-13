extends SceneTree
## Fixed, stationary 500-entity battle: same rendering, real projectiles and damage.
## Run unchanged before/after the battery rewrite; no deaths or path changes skew it.
var game: Node3D
var results: Dictionary = {}
var cannons: Array[BattleUnit] = []
var victims: Array[BattleUnit] = []
var output: String = "after"

func _initialize() -> void: _run.call_deferred()

func measure(label: String) -> void:
	await create_timer(1.5).timeout
	var samples: Array[float] = []
	var physics: Array[float] = []
	var start: int = Time.get_ticks_usec()
	var previous: int = start
	var pool: BattleProjectilePool = game.get_node("ProjectilePool")
	var shots: int = pool.launch_count
	while Time.get_ticks_usec() - start < 6000000:
		await process_frame
		var now: int = Time.get_ticks_usec()
		samples.append((now - previous) / 1000.0)
		physics.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		previous = now
	samples.sort()
	physics.sort()
	results[label] = {"median_ms": samples[samples.size()/2], "p95_ms": samples[int(samples.size()*.95)],
		# Godot refreshes this monitor with the previous second's MAXIMUM tick.
		# These are sampled monitor values, not percentiles of individual ticks.
		"physics_monitor_median_ms": physics[physics.size()/2], "physics_monitor_p95_ms": physics[int(physics.size()*.95)],
		"frames": samples.size(), "shots": pool.launch_count - shots, "peak_flights": pool.peak_active}
	results[label]["frame_p99_ms"] = samples[int(samples.size()*.99)]
	results[label]["frame_max_ms"] = samples[-1]
	print("BATTERY_PERF ", label, " ", JSON.stringify(results[label]))

func _run() -> void:
	create_timer(65, true, false, true).timeout.connect(func(): quit(3))
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
	DirAccess.make_dir_recursive_absolute("res://.local/triple-independent")
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	seed(91314)
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	game.set_placing(false)
	game.hud.hide()
	game.camera_rig.set_process(false)
	game.camera_rig.camera.position = Vector3(8, 60, -50)
	game.camera_rig.camera.look_at(Vector3.ZERO, Vector3.UP)
	game.camera_rig.camera.size = 100
	for i: int in 125:
		var at := Vector3((i % 13 - 6) * 7, 0, (i / 13 - 4.5) * 8)
		var cannon: BattleUnit = game.spawn_unit("triple_cannon", 0, at)
		cannon.hold()
		cannons.append(cannon)
		for j: int in 3:
			var target: BattleUnit = game.spawn_unit("shield_guard", 1, at + Vector3((j-1)*1.4, 0, -4))
			target.max_hp = 1000000
			target.hp = target.max_hp
			target.stop()
			target.set_physics_process(false)
			target.navigation_agent.avoidance_enabled = false
			victims.append(target)
	game.set_running(true)
	await measure("three_targets_500")
	for i: int in victims.size():
		if i % 3 != 0:
			victims[i].position.x += 300
	await measure("sparse_targets_500")
	for cannon: BattleUnit in cannons:
		cannon.stop()
	for victim: BattleUnit in victims: victim.position.x += 300
	await measure("idle_500")
	results.settings = {"entities":500, "cannons":125, "tps":Engine.physics_ticks_per_second,
		"resolution":str(root.size), "gpu":RenderingServer.get_video_adapter_name(), "msaa":root.msaa_3d}
	FileAccess.open("res://.local/triple-independent/" + output + ".json", FileAccess.WRITE).store_string(JSON.stringify(results, "\t"))
	await game.prepare_shutdown()
	quit()
