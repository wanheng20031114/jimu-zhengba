extends SceneTree
## Real batched battle plus an offscreen editable rig observing the same shots.
const OUTPUT := "res://artifacts/model-previews/triple-cannon/independent/"
var game: Node3D
var cannon: BattleUnit
var native: BatteryVisual
var checks: int = 0
var failures: Array[String] = []
var events: Array[Dictionary] = []
func _initialize() -> void: _run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func victim(at: Vector3) -> BattleUnit:
	var target: BattleUnit = game.spawn_unit("shield_guard",1,at)
	target.max_hp = 1000
	target.hp = 1000
	target.stop()
	target.set_physics_process(false)
	target.navigation_agent.avoidance_enabled = false
	return target
func launched(flight: ProjectileFlight) -> void:
	if flight._source != cannon: return
	for i: int in 3:
		if flight._start.distance_to(cannon.get_projectile_origin(i)) < .001:
			native.fire_barrel(i)
			events.append({"barrel":i,"time":game.elapsed,"target":flight._target.entity_id})
func _run() -> void:
	create_timer(35,true,false,true).timeout.connect(func():quit(3))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	DirAccess.make_dir_recursive_absolute(OUTPUT)
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	game.set_placing(false)
	game.hud.hide()
	game.camera_rig.set_process(false)
	game.camera_rig.camera.position = Vector3(6,8,-8)
	game.camera_rig.camera.look_at(Vector3(0,.5,-1),Vector3.UP)
	game.camera_rig.camera.size = 12
	cannon = game.spawn_unit("triple_cannon",0,Vector3(0,0,2))
	# Enter this demonstration with three different remaining reload times.
	cannon.battery.guns[1].ready_at = game.elapsed+.8
	cannon.battery.guns[2].ready_at = game.elapsed+1.6
	cannon.set_selected(true)
	native = load("res://assets/models/units/triple_cannon.tscn").instantiate()
	game.get_node("Units").add_child(native)
	native.hide()
	game.get_node("ProjectilePool").launched.connect(launched)
	var primary := victim(Vector3(0,0,-4))
	cannon.issue_attack(primary)
	game.set_running(true)
	var began: float = game.elapsed
	var next_frame: float = began
	var frame: int = 0
	var extras: int = 0
	while game.elapsed - began < 5.8:
		await process_frame
		var age: float = game.elapsed - began
		if age > .8 and extras == 0:
			victim(Vector3(-2.7,0,-3))
			extras = 1
		if age > 1.6 and extras == 1:
			victim(Vector3(2.7,0,-3))
			extras = 2
		if game.elapsed < next_frame: continue
		next_frame = game.elapsed + .10
		await RenderingServer.frame_post_draw
		native.synchronize_animation()
		cannon._model.synchronize_animation()
		for i: int in 3:
			var path: String = "Rig/Action/Barrel%d" % i
			check(native.get_node(path).position.distance_to(cannon._model.get_node(path).position) < .0001,"native/batch independent recoil frame "+str(frame))
		root.get_texture().get_image().save_png(OUTPUT+"frame-%03d.png"%frame)
		if frame == 18: root.get_texture().get_image().save_png(OUTPUT+"battle.png")
		frame += 1
	check(events.size() >= 6,"all three independent streams actually fire")
	var visual: BatteryVisual = cannon._model
	game.set_running(false)
	visual.synchronize_animation()
	var paused := visual._sampled_phases.duplicate()
	await create_timer(.4).timeout
	visual.synchronize_animation()
	check(paused == visual._sampled_phases,"pause preserves all independent clocks")
	game.set_running(true)
	await create_timer(.2).timeout
	cannon.receive_damage(cannon.max_hp)
	var dead := visual._sampled_phases.duplicate()
	await create_timer(.3).timeout
	visual.synchronize_animation()
	check(dead == visual._sampled_phases and not visual.is_physics_processing(),"death freezes all barrel tracks")
	var codex: Control = load("res://scenes/unit_codex.tscn").instantiate()
	root.add_child(codex)
	codex.open_codex()
	codex.select_entry(0,"triple_cannon")
	await create_timer(.4).timeout
	await RenderingServer.frame_post_draw
	check(codex.get_node("%Stats").text.contains("允许集火") and codex.get_node("%Stats").text.contains("每管间隔"),"codex describes independent cooldown and concentration")
	root.get_texture().get_image().save_png(OUTPUT+"codex.png")
	codex.queue_free()
	FileAccess.open("res://.local/triple-independent/visual.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"events":events,"frames":frame},"\t"))
	await game.prepare_shutdown()
	print("BATTERY_VISUAL ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
