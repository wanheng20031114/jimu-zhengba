extends SceneTree
## A fixed legacy roster measures common-code cost before and after this stage.
const LEGACY := ["swordsman","shield_guard","spearman","archer","knight","war_elephant","light_cavalry","catapult","cannon","heavy_cannon","engineer","priest"]
var game: Node3D
var results: Dictionary = {}
var output: String = "baseline"
func _initialize() -> void: _run.call_deferred()
func measure(label: String, seconds: float) -> void:
	var samples: Array[float] = []
	var began := Time.get_ticks_usec()
	var previous := began
	while Time.get_ticks_usec()-began < seconds*1000000:
		await process_frame
		var now := Time.get_ticks_usec()
		samples.append((now-previous)/1000.0)
		previous=now
	samples.sort()
	results[label]={"frames":samples.size(),"median_ms":samples[samples.size()/2],"p95_ms":samples[int(samples.size()*.95)]}
func _run() -> void:
	create_timer(70,true,false,true).timeout.connect(func():quit(3))
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output=arg.trim_prefix("--output=")
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps=0
	seed(130913)
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game=current_scene
	while not game._match_ready: await process_frame
	game.hud.hide()
	game.camera_rig.set_process(false)
	game.camera_rig.camera.position=Vector3(12,35,-35)
	game.camera_rig.camera.look_at(Vector3.ZERO,Vector3.UP)
	game.camera_rig.camera.size=76
	for i: int in 240:
		var at:=Vector3((i%20-9.5)*3.0,0,(i/20-5.5)*3.0)
		game.spawn_unit(LEGACY[i%LEGACY.size()],0,at).hold()
	game.set_running(true)
	await create_timer(2).timeout
	await measure("idle_240",6)
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.issue_move(unit.position+Vector3(0,0,20))
	await create_timer(.5).timeout
	await measure("march_240",6)
	results["settings"]={"units":240,"resolution":root.size,"msaa":root.msaa_3d,"tps":Engine.physics_ticks_per_second,"gpu":RenderingServer.get_video_adapter_name()}
	FileAccess.open("res://.local/triple-cannon-20260913/"+output+".json",FileAccess.WRITE).store_string(JSON.stringify(results,"\t"))
	print("EXPANSION_PERFORMANCE ",JSON.stringify(results))
	await game.prepare_shutdown()
	quit()
