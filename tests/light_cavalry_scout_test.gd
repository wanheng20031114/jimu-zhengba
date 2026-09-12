extends SceneTree
## Real navigation speed, pursuit and authoritative fog beyond the knight's sight.
var checks: int=0
var failures: Array[String]=[]
var game: Node3D
var speeds: Dictionary={}
func _initialize() -> void:
	_run.call_deferred()
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func _run() -> void:
	create_timer(60.0,true,false,true).timeout.connect(func(): quit(3))
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game=current_scene
	while not game._match_ready: await process_frame
	game.tests_running=true
	game.bots.clear()
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	for unit: BattleUnit in get_nodes_in_group("units"): unit.queue_free()
	# Keep the map and buildings intact; only exclude their sight from this
	# isolated fog measurement, so it comes from one real scout at a time.
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
		building.remove_from_group("entities")
	await physics_frame
	await process_frame
	for kind: String in ["knight","light_cavalry"]:
		var mount: BattleUnit=game.spawn_unit(kind,0,Vector3(0,0,-12))
		mount.issue_move(Vector3(0,0,14))
		await create_timer(.45).timeout
		var start: Vector3=mount.position
		var start_frame: int=Engine.get_physics_frames()
		for frame: int in 60: await physics_frame
		await process_frame
		var elapsed: float=float(Engine.get_physics_frames()-start_frame)/Engine.physics_ticks_per_second
		var speed: float=mount.position.distance_to(start)/elapsed
		speeds[kind]=speed
		check(absf(speed-BalanceCatalog.unit(kind).speed)<.12,kind+" actual steady travel matches data")
		mount.stop()
		mount.position=Vector3.ZERO
		mount.set_physics_process(false)
		mount.navigation_agent.avoidance_enabled=false
		var fog: FogOfWar=game.get_node("FogOfWar")
		fog._recompute()
		check(fog.position_visible(0,Vector3(15,0,1)),kind+" reveals inner vision cell")
		check(fog.position_visible(0,Vector3(19,0,1))==(kind=="light_cavalry"),kind+" actual nineteen-metre cell distinguishes sight 20 from 16")
		check(not fog.position_visible(0,Vector3(21,0,1)),kind+" does not reveal beyond sight 20")
		mount.queue_free()
		await physics_frame
		await process_frame
	check(speeds.light_cavalry>speeds.knight+.5,"light cavalry is measurably faster on identical route")
	var runner: BattleUnit=game.spawn_unit("archer",1,Vector3(0,0,2))
	var scout: BattleUnit=game.spawn_unit("light_cavalry",0,Vector3(0,0,-7))
	runner.issue_move(Vector3(0,0,15))
	scout.issue_attack(runner)
	await create_timer(3.3).timeout
	check(runner.hp<runner.max_hp,"fast scout catches moving archer and lands actual attack")
	check(scout.position.is_finite() and scout._charge_cooldown==0,"pursuit does not trigger knight charge")
	scout.stop()
	runner.stop()
	scout.issue_move(Vector3(-7,0,-5))
	scout.hold(true)
	for frame: int in 240:
		await physics_frame
		await process_frame
		if scout.order==BattleUnit.Order.HOLD: break
	# Queue HOLD so this measures arrival, rather than auto-acquisition after
	# completing a plain MOVE with an enemy still nearby.
	check(scout.order==BattleUnit.Order.HOLD and scout.position.distance_to(Vector3(-7,0,-5))<.8,"scout turns and reaches queued hold after pursuit")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open("res://artifacts/model-previews/light_cavalry/scout-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"actual_speeds":speeds},"\t"))
	print("LIGHT_CAVALRY_SCOUT ",checks," checks; ",failures.size()," failures; ",JSON.stringify(speeds))
	quit(0 if failures.is_empty() else 1)
