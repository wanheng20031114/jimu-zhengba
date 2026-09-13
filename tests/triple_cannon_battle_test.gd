extends SceneTree
var game: Node3D
var subject: BattleUnit
var shots: Array[Dictionary] = []
var checks: int = 0
var failures: Array[String] = []
func _initialize() -> void: _run.call_deferred()
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func freeze(unit: BattleUnit) -> void:
	unit.stop()
	unit.set_physics_process(false)
	unit.navigation_agent.avoidance_enabled=false
func spawn(kind: String,owner: int,at: Vector3) -> BattleUnit:
	var unit: BattleUnit=game.spawn_unit(kind,owner,at)
	freeze(unit)
	return unit
func reset() -> void:
	game.set_running(false)
	game.clear_units()
	await physics_frame
	await physics_frame
	shots.clear()
	subject=spawn("triple_cannon",0,Vector3.ZERO)
func start(target: Node3D) -> void:
	await physics_frame
	await physics_frame
	subject.target=target
	game.set_running(true)
	subject._start_attack()
func record(flight: ProjectileFlight) -> void:
	if flight._source==subject:
		shots.append({"id":flight._target.entity_id,"from":flight._start,"time":game.elapsed,"phase":subject._model.attack.current_animation_position})
func _run() -> void:
	create_timer(90,true,false,true).timeout.connect(func():quit(3))
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game=current_scene
	while not game._match_ready: await process_frame
	game.set_placing(false)
	game.get_node("ProjectilePool").launched.connect(record)
	var places: Array[Vector3]=[Vector3(0,0,-5),Vector3(-2,0,-5),Vector3(2,0,-5),Vector3(-3,0,-6),Vector3(3,0,-6)]
	for count: int in [1,2,3,5]:
		await reset()
		var victims: Array[BattleUnit]=[]
		for i: int in count: victims.append(spawn("swordsman",1,places[i]))
		await start(victims[0])
		var began: float=game.elapsed
		check(subject._model.attack.current_animation=="volley_0","unfired barrels start still: "+str(count))
		await create_timer(.18).timeout
		check(shots.is_empty(),"no premature launch: "+str(count))
		await create_timer(.65).timeout
		var expected: int=mini(3,count)
		check(shots.size()==expected,"distinct shot count for "+str(count)+" enemies")
		var ids: Dictionary={}
		for i: int in shots.size():
			ids[shots[i].id]=true
			check(absf(shots[i].time-began-(.25+.1*i))<.055,"scheduled release: "+str(shots[i].time-began))
		check(ids.size()==expected,"targets never duplicated")
		for i: int in count: check(victims[i].hp==(82 if i<expected else 110),"single 28 hit with no splash: "+str(i))
		subject._model.synchronize_animation()
		for i: int in range(expected,3):
			check(subject._model.get_node("Rig/Action/Barrel%d"%i).position.is_equal_approx(Vector3((i-1)*.5,1,-.1)),"unused barrel stays at rest")
	await reset()
	var primary:=spawn("war_elephant",1,Vector3(0,0,-5))
	var near_archer:=spawn("archer",1,Vector3(-2,0,-3))
	var left:=spawn("spearman",1,Vector3(-3,0,-5))
	var right:=spawn("shield_guard",1,Vector3(3,0,-5))
	var rear:=spawn("swordsman",1,Vector3(0,0,4))
	await start(primary)
	check(subject.volley.targets==[left,right],"infantry preferred to nearer archer, stable equal-distance IDs")
	await create_timer(.8).timeout
	check(primary.hp==345 and left.hp==46 and right.hp==122 and near_archer.hp==60 and rear.hp==110,"class damage and front-only extra targets")
	await reset()
	primary=spawn("swordsman",1,Vector3(0,0,-5))
	left=spawn("swordsman",1,Vector3(-2,0,-5))
	right=spawn("swordsman",1,Vector3(2,0,-5))
	await start(primary)
	await create_timer(.29).timeout
	left.queue_free()
	await create_timer(.6).timeout
	check(shots.size()==2 and shots[0].id==primary.entity_id and shots[1].id==right.entity_id,"freed middle target cancels its slot without retargeting")
	check(subject._model.attack.current_animation=="volley_5","only successfully fired outer barrels recoil")
	await reset()
	primary=spawn("swordsman",1,Vector3(0,0,-5))
	left=spawn("swordsman",1,Vector3(-2,0,-5))
	right=spawn("swordsman",1,Vector3(2,0,-5))
	await start(primary)
	subject.set_physics_process(true)
	primary.receive_damage(110)
	await create_timer(.8).timeout
	check(shots.size()==2 and left.hp==82 and right.hp==82,"primary death preserves other assigned shots")
	for die: bool in [false,true]:
		await reset()
		primary=spawn("swordsman",1,Vector3(0,0,-5))
		left=spawn("swordsman",1,Vector3(-2,0,-5))
		right=spawn("swordsman",1,Vector3(2,0,-5))
		await start(primary)
		await create_timer(.29).timeout
		if die: subject.receive_damage(160)
		else: subject.stop()
		await create_timer(.6).timeout
		check(shots.size()==1 and primary.hp==82 and left.hp==110 and right.hp==110,"stop/death cancels pending shots, in-flight shot resolves: "+str(die))
	await reset()
	primary=spawn("war_elephant",1,Vector3(0,0,-5))
	subject.issue_attack(primary)
	subject.set_physics_process(true)
	game.set_running(true)
	for frame: int in 185:
		subject.issue_attack(primary)
		await physics_frame
	check(shots.size()==3,"repeated commands preserve whole 2.4-second cycle")
	if shots.size()==3:
		check(absf(shots[1].time-shots[0].time-2.4)<.07 and absf(shots[2].time-shots[1].time-2.4)<.07,"actual salvo cadence remains 2.4 seconds")
	await reset()
	var structure: BattleBuilding=game.spawn_building("barracks",1,Vector3(0,0,-6))
	structure.set_physics_process(false)
	structure.production.set_physics_process(false)
	var untouched: BattleBuilding=game.spawn_building("barracks",1,Vector3(5,0,-6))
	untouched.set_physics_process(false)
	untouched.production.set_physics_process(false)
	var hp: float=structure.hp
	left=spawn("swordsman",1,Vector3(-3,0,-5))
	right=spawn("swordsman",1,Vector3(3,0,-5))
	await start(structure)
	await create_timer(.8).timeout
	check(shots.size()==3 and structure.hp==hp-8 and untouched.hp==untouched.max_hp and left.hp==82 and right.hp==82,"building primary takes one shot, extras only units")
	structure.queue_free()
	untouched.queue_free()
	await reset()
	primary=spawn("swordsman",1,Vector3(0,0,-5))
	left=spawn("swordsman",1,Vector3(-2,0,-5))
	right=spawn("swordsman",1,Vector3(2,0,-5))
	await start(primary)
	await create_timer(.29).timeout
	left.position=Vector3(-20,0,-20)
	await create_timer(.6).timeout
	check(shots.size()==2 and left.hp==110 and right.hp==82,"assigned target leaving range cancels only its shot")
	await reset()
	primary=spawn("swordsman",1,Vector3(0,0,-5))
	primary.max_hp=20000
	primary.hp=20000
	var pool: BattleProjectilePool=game.get_node("ProjectilePool")
	pool.launched.disconnect(record)
	var payload:=DamageResolver.snapshot(subject._stats,0,0,0)
	for i: int in 400:
		pool.launch(subject,primary,payload,"cannon",i%3)
	check(pool.active_count()==400 and pool.visual_count()==256 and pool.omitted_visuals>=144,"logical flights exceed visual pool capacity")
	pool._physics_process(1)
	pool._physics_process(0) # Completed records retire on the following pool tick.
	check(primary.hp==8800 and pool.active_count()==0 and pool.visual_count()==0,"all four hundred hits resolve and retire despite visual cap")
	check(pool._available_flights.all(func(f: ProjectileFlight):return f._source==null and f._target==null),"pooled records release entity references")
	FileAccess.open("res://.local/triple-cannon-20260913/battle.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"pool_peak":pool.peak_active,"pool_visual_peak":pool.peak_visuals},"\t"))
	await game.prepare_shutdown()
	print("TRIPLE_CANNON_BATTLE ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
