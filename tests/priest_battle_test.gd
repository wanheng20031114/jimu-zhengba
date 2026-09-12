extends SceneTree
## Real movement, target priority, battle healing and simultaneous native GPU effects.
var game: Node3D
var checks: int = 0
var failures: Array[String] = []
var frame_ms: Array[float] = []
func _initialize() -> void: _run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func reset() -> void:
	game.set_running(false)
	game.clear_units()
	game.get_node("EffectPool").reset_all()
	await process_frame
	await physics_frame
func spawn(kind: String, at: Vector3, owner: int = 0) -> BattleUnit:
	return game.spawn_unit(kind,owner,at)
func _run() -> void:
	create_timer(100,true,false,true).timeout.connect(func(): quit(3))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	root.gui_disable_input = true
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	game.set_placing(false)
	game.camera_rig.set_process(false)
	var p := spawn("priest",Vector3.ZERO)
	var first := spawn("swordsman",Vector3(0,0,-4))
	var second := spawn("swordsman",Vector3(0,0,4))
	var close := spawn("swordsman",Vector3(2,0,0))
	first.hp = 20
	second.hp = 20
	close.hp = 50
	await physics_frame
	await physics_frame
	p.support.select_job()
	check(p.support.recipient == first,"automatic priority uses health fraction then entity ID for equal distances")
	p.support.cancel()
	close.hp = 20
	p.support.select_job()
	check(p.support.recipient == close,"equal health prefers nearer recipient")
	await reset()
	p = spawn("priest",Vector3(0,0,-3))
	var target := spawn("swordsman",Vector3(12,0,-3))
	target.hp = 10
	target.hold()
	game.set_running(true)
	await create_timer(.8).timeout
	check(p.position.distance_to(Vector3(0,0,-3)) < .05 and target.hp == 10,"automatic healing never chases outside six range")
	p.issue_support(target)
	await create_timer(2.3).timeout
	check(p.position.x > 3 and p._working and target.hp >= 20,"manual healing approaches a distant patient then plants and casts")
	p.hold()
	var at: Vector3 = p.position
	target.issue_move(Vector3(25,0,-3))
	await create_timer(3).timeout
	check(p.position.distance_to(at) < .1 and not p._working and not is_instance_valid(p.support.recipient),"hold releases departing patient and never pursues")
	await reset()
	p = spawn("priest",Vector3(0,0,-3))
	target = spawn("light_cavalry",Vector3(2,0,-3))
	target.hp = 10
	p.issue_support(target)
	game.set_running(true)
	await create_timer(.8).timeout
	check(target.hp == 20,"manual heal begins while stationary")
	target.issue_move(Vector3(20,0,-3))
	await create_timer(2.8).timeout
	var hp: float = target.hp
	check(p.position.x > 2 and not p._working and p.order == BattleUnit.Order.SUPPORT,"manual order follows escaped patient but interrupts cast outside range")
	target.hold()
	await create_timer(3.4).timeout
	check(target.hp > hp and p._working,"manual follow resumes treatment after catching up")
	await reset()
	p = spawn("priest",Vector3(0,0,-3))
	target = spawn("swordsman",Vector3(2,0,-1))
	target.hp = target.max_hp-10
	target.hold()
	p.issue_move(Vector3(10,0,-3),true)
	game.set_running(true)
	await create_timer(4.5).timeout
	check(target.hp == target.max_hp and p.position.x > 7,"attack move heals then resumes original route")
	await reset()
	p = spawn("priest",Vector3(0,0,-3))
	target = spawn("shield_guard",Vector3(3,0,-3))
	target.hp = 60
	var enemy := spawn("swordsman",Vector3(4.8,0,-3),1)
	enemy.issue_attack(target)
	target.issue_attack(enemy)
	p.issue_support(target)
	game.set_running(true)
	await create_timer(2.1).timeout
	check(target.hp > 60 and enemy.hp < 110 and p._working,"ally fights while receiving treatment")
	p.issue_attack(enemy)
	await create_timer(.15).timeout
	check(not p._working and target.support.provider == null,"manual attack cancels healing and its claim")
	await reset()
	# GPU presentation and every single recipient's restoration run together.
	var priests: Array[BattleUnit] = []
	var patients: Array[BattleUnit] = []
	for index: int in 24:
		var cell := Vector3((index%6-3)*3.2,0,(index/6-2)*4.0)
		var healer := spawn("priest",cell)
		var patient := spawn("swordsman",cell+Vector3(0,0,-1.5))
		patient.hp = 10
		patient.hold()
		healer.issue_support(patient)
		priests.append(healer)
		patients.append(patient)
	game.camera_rig.focus_at(Vector3.ZERO,true)
	game.camera_rig.camera.size = 30
	game.set_running(true)
	await create_timer(1.9).timeout
	check(patients.all(func(unit: BattleUnit): return unit.hp == 30),"24 simultaneous channels restore independently without over-healing")
	check(priests.all(func(unit: BattleUnit): return unit._working and unit._model._support_particles[0].emitting),"all on-screen healers retain active GPU hand emitters")
	check(game.get_node("EffectPool").active_count() >= 24,"recipient GPU pulses use the bounded effect pool")
	var emitter: GPUParticles3D = priests[0]._model._support_particles[0]
	var pulse: HealingParticles = game.get_node("EffectPool")._active.back().get_node("Healing")
	game.set_running(false)
	check(emitter.speed_scale == 0 and pulse.get_node("Motes").speed_scale == 0,"sandbox pause freezes both hand and target particles")
	var before: float = patients[0].hp
	await create_timer(.7).timeout
	check(patients[0].hp == before,"sandbox pause cannot accrue healing")
	game.set_running(true)
	check(emitter.speed_scale == 1 and pulse.get_node("Motes").speed_scale == 1,"resume restores both GPU clocks")
	priests[0].hide()
	check(not emitter.emitting and not emitter.visible,"hiding a fog-occluded priest stops hand particles")
	priests[0].show()
	check(emitter.emitting,"revealed working priest resumes hand particles")
	var began: int = Time.get_ticks_usec()
	for frame: int in 120:
		await process_frame
		var now: int = Time.get_ticks_usec()
		frame_ms.append((now-began)/1000.0)
		began = now
	frame_ms.sort()
	await reset()
	check(game.get_node("UnitRenderBatches").registered_models == 0 and game.get_node("EffectPool").active_count() == 0,"clearing battle releases claims, batches and GPU effects")
	for index: int in 500:
		var healer := spawn("priest",Vector3((index%25-12)*2.5,0,(index/25-10)*2.5))
		healer.hold()
	game.set_running(true)
	await create_timer(1.2).timeout
	check(game.sandbox_unit_count == 500 and game.get_node("UnitRenderBatches").registered_models == 500,"500 priests keep all native rig registrations")
	await reset()
	check(game.get_node("UnitRenderBatches").registered_models == 0,"clearing 500 priests releases every registration")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	var metrics := {"checks":checks,"failures":failures,"simultaneous_healers":24,"gpu":"RTX 3080", "frame_median_ms":frame_ms[60],"frame_p95_ms":frame_ms[114],"scope":"24 healers and 24 recipients in sandbox, editor may coexist; observational, not isolated benchmark"}
	FileAccess.open("res://.local/priest-20260913/battle-results.json",FileAccess.WRITE).store_string(JSON.stringify(metrics,"\t"))
	print("PRIEST_BATTLE ",JSON.stringify(metrics))
	quit(0 if failures.is_empty() else 1)
