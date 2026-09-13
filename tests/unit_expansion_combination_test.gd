extends SceneTree
## Full rendering and real damage for a normal army and a 500-unit mixed battle.
const NEW_UNITS := ["shield_guard","war_elephant","light_cavalry","engineer","priest","heavy_cannon","triple_cannon"]
const MIXED := ["shield_guard","war_elephant","light_cavalry","engineer","priest","heavy_cannon","triple_cannon","swordsman","spearman","knight","archer","catapult","cannon"]
var game: Node3D
var checks: int = 0
var failures: Array[String] = []
var results: Dictionary = {}
var observed: Dictionary = {}
var damage_events: int = 0
func _initialize() -> void: _run.call_deferred()
func check(ok: bool,label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func scenario(count: int,seconds: float) -> void:
	game.set_running(false)
	game.clear_units()
	await physics_frame
	await physics_frame
	damage_events = 0
	observed.clear()
	var original: Array[BattleUnit] = []
	var cols: int = 25 if count==500 else 7
	var each: int = count/2
	for owner: int in 2:
		var sign: float = 1 if owner==0 else -1
		for i: int in each:
			var kind: String = MIXED[i%MIXED.size()] if count==500 else NEW_UNITS[i%7]
			var at := Vector3((i%cols-(cols-1)*.5)*2.3,0,sign*(5.5+(i/cols)*2.2))
			var unit: BattleUnit = game.spawn_unit(kind,owner,at)
			unit.hp = unit.max_hp*.7
			unit.damaged.connect(func(_u: Node3D,_n: float):damage_events+=1)
			unit.issue_move(Vector3(at.x,0,-sign*14),true)
			original.append(unit)
	check(original.size()==count,"spawn exact mixed army size "+str(count))
	if count==28:
		var population: int = 0
		for i: int in each: population+=original[i]._stats.supply
		check(population==36,"normal army uses 36 military population per side")
	game.set_running(true)
	await create_timer(1).timeout
	var samples: Array[float] = []
	var begin: int = Time.get_ticks_usec()
	var previous: int = begin
	var last_scan: int = begin
	while Time.get_ticks_usec()-begin<seconds*1000000:
		await process_frame
		var now: int = Time.get_ticks_usec()
		samples.append((now-previous)/1000.0)
		previous = now
		if now-last_scan<100000: continue
		last_scan=now
		for unit: BattleUnit in original:
			if not is_instance_valid(unit) or not unit.alive: continue
			if unit._attack_cooldown>0 or unit.battery.shots_fired>0 or is_instance_valid(unit.support.recipient): observed[unit.unit_type]=true
		await RenderingServer.frame_post_draw
	samples.sort()
	var pool: BattleProjectilePool = game.get_node("ProjectilePool")
	var survivors: Array[Node] = get_nodes_in_group("units")
	check(damage_events>10,"real incoming damage continues "+str(count))
	check(survivors.all(func(u: BattleUnit):return u.position.is_finite() and u.hp>0 and u.hp<=u.max_hp),"finite positions and health "+str(count))
	check(observed.has("engineer") and observed.has("priest") and observed.has("triple_cannon"),"support and independent guns work in mixed battle "+str(count))
	results[str(count)]={"median_ms":samples[samples.size()/2],"p95_ms":samples[int(samples.size()*.95)],"frames":samples.size(),"damage_events":damage_events,"active_types":observed.keys(),"survivors":survivors.size(),"projectiles":pool.launch_count,"peak_flights":pool.peak_active,"peak_visuals":pool.peak_visuals}
	print("COMBINATION_MEASURE ",count," ",JSON.stringify(results[str(count)]))
	if count==500:
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://artifacts/model-previews/triple-cannon/stress-500.png")
	game.set_running(false)
	game.clear_units()
	await physics_frame
	await physics_frame
	check(pool.active_count()==0 and pool.visual_count()==0 and get_nodes_in_group("units").is_empty(),"clear battle recycles projectiles and units "+str(count))
func _run() -> void:
	create_timer(90,true,false,true).timeout.connect(func():quit(3))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	seed(130913)
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	game.set_placing(false)
	game.hud.hide()
	game.camera_rig.set_process(false)
	game.camera_rig.camera.position = Vector3(10,35,-35)
	game.camera_rig.camera.look_at(Vector3.ZERO,Vector3.UP)
	game.camera_rig.camera.size = 30
	await scenario(28,10)
	game.camera_rig.camera.size = 80
	await scenario(500,12)
	results.settings={"resolution":root.size,"msaa":root.msaa_3d,"gpu":RenderingServer.get_video_adapter_name(),"tps":Engine.physics_ticks_per_second}
	results.checks = checks
	results.failures = failures
	FileAccess.open("res://.local/triple-cannon-20260913/combination.json",FileAccess.WRITE).store_string(JSON.stringify(results,"\t"))
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("UNIT_EXPANSION_COMBINATION ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
