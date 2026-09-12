extends SceneTree
## Real motion, claim lifetimes, concurrent gunfire, avoidance and batch capacity.
var game: Node3D
var checks: int=0
var failures: Array[String]=[]
func _initialize() -> void: _run.call_deferred()
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func reset() -> void:
	game.set_running(false)
	game.clear_units()
	await process_frame
	await process_frame
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.local/engineer-20260912"))
	create_timer(115,true,false,true).timeout.connect(func(): quit(3))
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game=current_scene
	while not game._match_ready: await process_frame
	game.set_placing(false)
	var e: BattleUnit=game.spawn_unit("engineer",0,Vector3(-4,0,-3))
	var c: BattleUnit=game.spawn_unit("cannon",0,Vector3(0,0,-3))
	c.hp=50
	c.hold()
	game.set_running(true)
	await create_timer(2.5).timeout
	check(e._working and c.hp>=55,"automatically discovers and approaches damaged siege")
	var at: Vector3=e.position
	e.issue_move(Vector3(-6,0,-7))
	await create_timer(.8).timeout
	check(not e._working and e.position.distance_to(at)>1,"normal move interrupts work and takes priority")
	e.hold()
	at=e.position
	await create_timer(.5).timeout
	check(e.position.distance_to(at)<.05 and not e._working,"hold never chases distant machine")
	e.issue_support(c)
	await create_timer(2).timeout
	check(e._working,"manual order returns to machine")
	c.issue_move(Vector3(7,0,-3))
	var hp: float=c.hp
	await create_timer(.8).timeout
	check(c.hp<=hp+5,"moving machine cannot receive out-of-range ticks")
	await create_timer(4.5).timeout
	check(e.position.x>3 and c.hp>hp,"manual repair follows and resumes beyond original discovery area")
	# Start automatic work, then move machine outside that fixed discovery area.
	await reset()
	e=game.spawn_unit("engineer",0,Vector3(0,0,-3))
	c=game.spawn_unit("cannon",0,Vector3(3,0,-3))
	c.hp=30
	c.issue_move(Vector3(17,0,-3))
	game.set_running(true)
	await create_timer(6).timeout
	check(not is_instance_valid(e.support.recipient) and e.position.x<9,"automatic chase ends at discovery boundary without reacquisition drift")
	await reset()
	e=game.spawn_unit("engineer",0,Vector3(0,0,-3))
	c=game.spawn_unit("cannon",0,Vector3(2,0,-1))
	c.hp=c.max_hp-5
	c.hold()
	e.issue_move(Vector3(10,0,-3),true)
	game.set_running(true)
	await create_timer(5).timeout
	print("ENGINEER_ATTACK_MOVE hp=",c.hp," pos=",e.position," order=",e.order," destination=",e.destination," recipient=",e.support.recipient)
	check(c.hp==c.max_hp and e.position.x>7,"attack move repairs then continues its route")
	await reset()
	e=game.spawn_unit("engineer",0,Vector3(0,0,-3))
	c=game.spawn_unit("cannon",0,Vector3(2,0,-3))
	c.hp=50
	var target: BattleUnit=game.spawn_unit("war_elephant",1,Vector3(9,0,-3))
	target.hold()
	c.issue_attack(target)
	e.issue_support(c)
	game.set_running(true)
	await create_timer(2).timeout
	check(c.hp>50 and target.hp<360 and e._working,"cannon fires while being repaired")
	var previous: float=target.hp
	e.issue_attack(target)
	await create_timer(.4).timeout
	check(not e._working and c.support.provider==null,"manual attack switches out of support")
	c.receive_damage(999)
	e.issue_move(Vector3(0,0,-6))
	await create_timer(.2).timeout
	check(c.support.provider==null and target.hp<=previous,"death leaves no stale repair")
	await reset()
	e=game.spawn_unit("engineer",0,Vector3(0,0,-3))
	c=game.spawn_unit("cannon",0,Vector3(2,0,-3))
	c.hp=50
	e.issue_support(c)
	game.set_running(true)
	await create_timer(.7).timeout
	c.receive_damage(999)
	await create_timer(.1).timeout
	check(not is_instance_valid(e.support.recipient) and e.order==BattleUnit.Order.IDLE,"target death completes invalid manual job")
	e.receive_damage(999)
	await create_timer(4.5).timeout
	check(game.get_node("UnitRenderBatches").registered_models==0,"death and fade release all part registrations")
	await reset()
	for i: int in 500:
		var unit: BattleUnit=game.spawn_unit("engineer",0,Vector3((i%25-12)*2.5,0,(i/25-10)*2.5))
		unit.hold()
	game.set_running(true)
	await create_timer(2).timeout
	check(game.sandbox_unit_count==500 and game.get_node("UnitRenderBatches").registered_models==500,"500 engineers retain complete native batch registrations")
	await reset()
	check(game.get_node("UnitRenderBatches").registered_models==0,"clear releases 500 support components and visuals")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open("res://.local/engineer-20260912/battle-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	print("ENGINEER_BATTLE ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
