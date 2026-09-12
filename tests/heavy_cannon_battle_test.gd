extends SceneTree
## Real timers, cannon flights, free repairs, movement and rendered fire effects.
const OUTPUT := "res://artifacts/model-previews/heavy-cannon/"
var game: Node3D
var checks: int = 0
var failures: Array[String] = []
var launches: Array[Dictionary] = []
var subject: BattleUnit
func _initialize() -> void: _run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func freeze(unit: BattleUnit) -> void:
	unit.stop()
	unit.set_physics_process(false)
	unit.navigation_agent.avoidance_enabled = false
func reset() -> void:
	game.set_running(false)
	game.clear_units()
	game.get_node("ProjectilePool").reset_all()
	game.get_node("EffectPool").reset_all()
	await process_frame
	await physics_frame
	launches.clear()
func launched(flight: ProjectileFlight) -> void:
	if flight._source == subject:
		launches.append({"time":game.elapsed,"from":flight._start,"phase":subject._model.attack.current_animation_position})
func capture(name: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	get_root().get_texture().get_image().save_png(OUTPUT+name+".png")
func _run() -> void:
	create_timer(95,true,false,true).timeout.connect(func(): quit(3))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	root.gui_disable_input = true
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	game.set_placing(false)
	game.camera_rig.set_process(false)
	game.hud.hide()
	game.camera_rig.camera.position = Vector3(8,9,11)
	game.camera_rig.camera.look_at(Vector3(0,.7,-3),Vector3.UP)
	game.camera_rig.camera.size = 15
	game.get_node("ProjectilePool").launched.connect(launched)
	subject = game.spawn_unit("heavy_cannon",0,Vector3.ZERO)
	var elephant: BattleUnit = game.spawn_unit("war_elephant",1,Vector3(0,0,-12))
	freeze(elephant)
	var bystander: BattleUnit = game.spawn_unit("swordsman",1,Vector3(1.8,0,-12))
	freeze(bystander)
	var engineer: BattleUnit = game.spawn_unit("engineer",0,Vector3(2.4,0,.5))
	subject.hp = 210
	engineer.issue_support(subject)
	var priest: BattleUnit = game.spawn_unit("priest",0,Vector3(-3,0,0))
	check(not priest.support.valid_target(subject),"priest cannot heal heavy cannon")
	freeze(priest)
	game.get_player(0).gold = 0
	subject.issue_attack(elephant)
	game.select_entities([subject])
	game.set_running(true)
	for frame: int in 120:
		if not subject.attack_windup.is_stopped(): break
		await physics_frame
	var began: float = game.elapsed
	await create_timer(.36).timeout
	check(launches.is_empty() and elephant.hp == 360,"no launch or damage before .45 windup")
	await subject.attack_windup.timeout
	check(launches.size() == 1 and launches[0].phase >= .45,"exact one cannonball after release pose")
	check(absf(game.elapsed-began-.45) < .07,"windup timer releases after .45 seconds")
	check(game.get_node("EffectPool").active_count() > 0,"real firing creates muzzle flash and smoke")
	await capture("battle-fire")
	await create_timer(.8).timeout
	check(elephant.hp == 263 and bystander.hp == 110,"actual flight deals 97 only to its locked target")
	check(subject.hp == 215 and game.get_player(0).gold == 0,"free five HP repair while the cannon fires")
	# Repeated attack commands must not shorten the full 4.2-second cycle.
	for attempt: int in 20:
		subject.issue_attack(elephant)
		await create_timer(.025).timeout
	for frame: int in 600:
		if elephant.hp == 69: break
		await physics_frame
	check(launches.size() == 3 and elephant.hp == 69,"three real single-target hits across two full reload cycles")
	if launches.size() == 3:
		for index: int in [1,2]:
			var gap: float = launches[index].time-launches[index-1].time
			check(absf(gap-4.2) < .08,"firing cadence remains 4.2 seconds: "+str(gap))
	check(bystander.hp == 110,"nearby enemy remains unharmed after repeated explosions")
	check(subject.hp >= 250 and subject.hp <= 260 and game.get_player(0).gold == 0,"repair continues without payment during sustained fire")
	var cadence: Array[Dictionary] = launches.duplicate(true)
	await reset()
	subject = game.spawn_unit("heavy_cannon",0,Vector3.ZERO)
	elephant = game.spawn_unit("war_elephant",1,Vector3(0,0,-4))
	freeze(elephant)
	subject.hold()
	game.set_running(true)
	await create_timer(1.1).timeout
	check(launches.is_empty() and elephant.hp == 360 and subject.position.length() < .02,"hold cannot fire at a target inside minimum range")
	elephant.position = Vector3(0,0,-10)
	subject.issue_attack(elephant)
	await create_timer(.2).timeout
	subject.stop()
	await create_timer(.7).timeout
	check(launches.is_empty() and elephant.hp == 360,"stop cancels unlaunched shot")
	check(subject._attack_cooldown > 2.9,"stop retains consumed cooldown")
	await reset()
	subject = game.spawn_unit("heavy_cannon",0,Vector3.ZERO)
	elephant = game.spawn_unit("war_elephant",1,Vector3(0,0,-12))
	freeze(elephant)
	subject.issue_attack(elephant)
	game.set_running(true)
	await create_timer(.17).timeout
	subject.receive_damage(260)
	await create_timer(.65).timeout
	check(launches.is_empty() and elephant.hp == 360,"source death cancels unlaunched shot")
	await reset()
	subject = game.spawn_unit("heavy_cannon",0,Vector3(-8,0,-3))
	var start: Vector3 = subject.position
	subject.issue_move(Vector3(8,0,-3))
	game.set_running(true)
	await create_timer(3).timeout
	var travelled: float = subject.position.distance_to(start)
	check(travelled > 4.8 and travelled < 5.6,"real straight travel agrees with speed 1.8: "+str(travelled))
	var wheel: Node3D = subject._model.get_node("Rig/Action/WheelFrontLeftKick/WheelFrontLeft")
	var clip: Animation = subject._model.locomotion.get_animation("walk")
	check(is_equal_approx(clip.length,TAU*.6/1.8),"wheel revolution matches ground speed and radius")
	check(wheel.basis != Basis.IDENTITY,"rendered movement drives saved wheel animation")
	subject.issue_move(Vector3(-6,0,5))
	await create_timer(1).timeout
	check(subject.velocity.is_finite() and subject.position.x < start.x+travelled,"turning updates movement without invalid velocities")
	subject.issue_move(subject.position+Vector3(1,0,0))
	subject.queue_move(subject.position+Vector3(1,0,2))
	check(subject.waypoint_queue.size() == 1,"Shift route accepts queued move")
	subject.stop()
	check(subject.waypoint_queue.is_empty(),"stop clears queued route")
	subject.hold()
	check(subject.order == BattleUnit.Order.HOLD,"hold command")
	subject.issue_move(Vector3(0,0,0),true)
	check(subject.order == BattleUnit.Order.ATTACK_MOVE,"attack-move command")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open("res://.local/heavy-cannon-20260913/battle-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"cadence":cadence,"travelled_in_3s":travelled},"\t"))
	print("HEAVY_CANNON_BATTLE ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
