extends SceneTree
## Real launches and damage with asynchronous arrivals and command interruption.
var game: Node3D
var subject: BattleUnit
var shots: Array[Dictionary] = []
var checks: int = 0
var failures: Array[String] = []
func _initialize() -> void: _run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func spawn(kind: String, owner: int, at: Vector3) -> BattleUnit:
	var unit: BattleUnit = game.spawn_unit(kind,owner,at)
	unit.stop()
	unit.set_physics_process(false)
	unit.navigation_agent.avoidance_enabled = false
	return unit
func reset() -> void:
	game.set_running(false)
	game.clear_units()
	await physics_frame
	await physics_frame
	shots.clear()
	subject = spawn("triple_cannon",0,Vector3.ZERO)
func start(victim: Node3D) -> void:
	await physics_frame
	await physics_frame
	subject.hold()
	subject.target = victim
	subject.set_physics_process(true)
	game.set_running(true)
func step(seconds: float) -> void:
	var until: float = game.elapsed + seconds
	while game.elapsed < until - .000001: await physics_frame
func record(flight: ProjectileFlight) -> void:
	if flight._source != subject: return
	var barrel: int = 0
	for i: int in 3:
		if flight._start.distance_to(subject.get_projectile_origin(i)) < .001: barrel = i
	shots.append({"id":flight._target.entity_id,"barrel":barrel,"time":game.elapsed})
func shots_for(id: int) -> Array[Dictionary]:
	return shots.filter(func(shot: Dictionary): return shot.id == id)
func cadence(id: int) -> void:
	var observed := shots_for(id)
	for barrel: int in 3:
		var stream: Array[Dictionary] = observed.filter(func(shot: Dictionary): return shot.barrel == barrel)
		for i: int in range(1,stream.size()):
			var interval: float = stream[i].time - stream[i-1].time
			check(interval >= 2.399 and interval <= 2.47,"independent 2.4s gun cadence: "+str(interval))
func _run() -> void:
	create_timer(100,true,false,true).timeout.connect(func():quit(3))
	Engine.time_scale = 3.0
	DirAccess.make_dir_recursive_absolute("res://.local/triple-independent")
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	game.set_placing(false)
	game.get_node("ProjectilePool").launched.connect(record)
	var places: Array[Vector3] = [Vector3(0,0,-5),Vector3(-2,0,-5),Vector3(2,0,-5),Vector3(-3,0,-6),Vector3(3,0,-6)]
	for count: int in [1,2,3,5]:
		await reset()
		var victims: Array[BattleUnit] = []
		for i: int in count: victims.append(spawn("swordsman",1,places[i]))
		await start(victims[0])
		var began: float = game.elapsed
		await step(.18)
		check(shots.is_empty(),"no shot before .25s preparation")
		await step(.7)
		var expected: int = mini(3,count)
		check(shots.size() == 3,"all ready guns fire with "+str(count)+" available targets")
		var ids: Dictionary = {}
		var barrels: Dictionary = {}
		for shot: Dictionary in shots:
			ids[shot.id] = true
			barrels[shot.barrel] = true
			check(shot.time-began >= .249 and shot.time-began < .5,"ready guns prepare together")
		check(ids.size() == expected and barrels.size() == 3,"automatic fire spreads then concentrates spare guns")
		for i: int in count:
			var hits: int = (4-expected) if i == 0 else (1 if i<expected else 0)
			check(victims[i].hp == 110-hits*28,"per-projectile damage without splash")
	await reset()
	# A partially reloaded battery enters combat: the clocks must not resynchronize.
	subject.battery.guns[1].ready_at = game.elapsed+.9
	subject.battery.guns[2].ready_at = game.elapsed+1.65
	var primary := spawn("war_elephant",1,places[0])
	await start(primary)
	await step(.6)
	var left := spawn("war_elephant",1,places[1])
	await step(.75)
	var right := spawn("war_elephant",1,places[2])
	await step(5.0)
	check(shots_for(primary.entity_id).size() == 3,"first gun completes three cycles")
	check(shots_for(left.entity_id).size() >= 2 and shots_for(right.entity_id).size() >= 2,"late targets get independent streams")
	if not shots_for(left.entity_id).is_empty() and not shots_for(right.entity_id).is_empty():
		check(shots_for(left.entity_id)[0].time < shots[0].time+1.3,"second gun joins during first cooldown")
		check(shots_for(right.entity_id)[0].time < shots[0].time+2.2,"third gun joins before first reloads")
	for victim: BattleUnit in [primary,left,right]: cadence(victim.entity_id)
	var queries: int = subject.battery.query_count
	await step(2.5)
	check(subject.battery.query_count == queries,"stable locks need no further acquisition queries")
	for reason: String in ["freed","out_of_range","primary_death"]:
		await reset()
		primary = spawn("swordsman",1,places[0])
		left = spawn("swordsman",1,places[1])
		right = spawn("swordsman",1,places[2])
		await start(primary)
		await step(.1)
		if reason == "freed": left.queue_free()
		elif reason == "out_of_range": left.position = Vector3(-25,0,-25)
		else: primary.receive_damage(110)
		await step(.75)
		check(shots.size() == 2,"only invalid gun cancelled: "+reason)
		check(right.hp == 82,"other windup preserved: "+reason)
	for command: String in ["stop","move","hold","death"]:
		await reset()
		primary = spawn("war_elephant",1,places[0])
		await start(primary)
		await step(.1)
		if command == "stop": subject.stop()
		elif command == "move": subject.issue_move(Vector3(0,0,10))
		elif command == "hold": subject.hold()
		else: subject.receive_damage(subject.max_hp)
		await step(.7)
		check(shots.is_empty(),"cancel before release: "+command)
		if command != "death":
			subject.issue_attack(primary)
			await step(.8)
			check(shots.is_empty(),"ready gun cannot steal cooldown debt: "+command)
	await reset()
	primary = spawn("war_elephant",1,places[0])
	await start(primary)
	await step(.6)
	subject.stop()
	subject.issue_attack(primary)
	var until: float = game.elapsed+5.8
	while game.elapsed < until:
		subject.issue_attack(primary)
		await physics_frame
	check(shots.size() == 9,"explicit focus permits three shots but cannot reset gun cooldowns")
	cadence(primary.entity_id)
	await reset()
	primary = spawn("war_elephant",1,places[0])
	left = spawn("war_elephant",1,places[1])
	await start(primary)
	await step(.6)
	until = game.elapsed+3.5
	var toggle: bool = false
	while game.elapsed < until:
		toggle = not toggle
		subject.issue_attack(left if toggle else primary)
		await physics_frame
	for barrel: int in 3:
		var seen: Array[Dictionary] = shots.filter(func(shot: Dictionary): return shot.barrel == barrel)
		for i: int in range(1,seen.size()): check(seen[i].time-seen[i-1].time >= 2.399,"target switches preserve gun cooldowns")
	# Explicit focus overrides the automatic preference for distinct victims.
	await reset()
	primary = spawn("war_elephant",1,places[0])
	left = spawn("war_elephant",1,places[1])
	right = spawn("war_elephant",1,places[2])
	await start(primary)
	subject.issue_attack(primary)
	await step(.9)
	check(shots.size() == 3 and shots_for(primary.entity_id).size() == 3 and left.hp == 360 and right.hp == 360,"manual focus sends every gun at the requested enemy")
	await reset()
	var structure: BattleBuilding = game.spawn_building("barracks",1,Vector3(0,0,-6))
	var extra: BattleBuilding = game.spawn_building("barracks",1,Vector3(5,0,-6))
	for building: BattleBuilding in [structure,extra]:
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	left = spawn("swordsman",1,Vector3(-3,0,-5))
	right = spawn("swordsman",1,Vector3(3,0,-5))
	await start(structure)
	await step(.9)
	check(shots.size() == 3 and structure.hp == structure.max_hp-8 and extra.hp == extra.max_hp and left.hp == 82 and right.hp == 82,"primary building takes one shot; no secondary buildings")
	structure.queue_free()
	extra.queue_free()
	await reset()
	primary = spawn("swordsman",1,places[0])
	primary.max_hp = 20000
	primary.hp = 20000
	var pool: BattleProjectilePool = game.get_node("ProjectilePool")
	pool.launched.disconnect(record)
	var payload := DamageResolver.snapshot(subject._stats,0,0,0)
	for i: int in 400: pool.launch(subject,primary,payload,"cannon",i%3)
	check(pool.active_count() == 400 and pool.visual_count() == 256,"logical shots exceed visual capacity")
	pool._physics_process(1)
	pool._physics_process(0)
	check(primary.hp == 8800 and pool.active_count() == 0,"all 400 impacts resolve despite visual limit")
	FileAccess.open("res://.local/triple-independent/battle.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	await game.prepare_shutdown()
	print("TRIPLE_CANNON_BATTLE ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
