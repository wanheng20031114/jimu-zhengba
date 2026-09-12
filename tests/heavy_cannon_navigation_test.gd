extends SceneTree
## Full-size carriage through real building geometry, then a wall-side cannon shot.
var checks: int = 0
var failures: Array[String] = []
func _initialize() -> void: _run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func _run() -> void:
	create_timer(45,true,false,true).timeout.connect(func(): quit(3))
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	var game: Node3D = current_scene
	while not game._match_ready: await process_frame
	game.set_placing(false)
	var walls: Array[BattleBuilding] = []
	for x: float in [-5,5]:
		for z: float in [-5,0,5]:
			var wall: BattleBuilding = game.spawn_building("barracks",0,Vector3(x,0,z))
			wall.set_physics_process(false)
			walls.append(wall)
	var navigation: ConstructionNavigation = game.get_node("ConstructionNavigation")
	navigation.refresh()
	while navigation.is_rebuilding(): await process_frame
	await physics_frame
	await physics_frame
	var cannon: BattleUnit = game.spawn_unit("heavy_cannon",0,Vector3(0,0,-11))
	game.set_running(true)
	cannon.issue_move(Vector3(0,0,10))
	cannon.queue_move(Vector3(0,0,9))
	cannon.hold(true)
	var minimum_clearance: float = INF
	for tick: int in 700:
		await physics_frame
		if absf(cannon.position.z) < 7.5:
			minimum_clearance = minf(minimum_clearance,2.0-absf(cannon.position.x))
		if cannon.order == BattleUnit.Order.HOLD: break
	check(minimum_clearance < INF and minimum_clearance > cannon.radius*.85-.03,"four metre corridor clears the actual collision capsule")
	check(cannon.order == BattleUnit.Order.HOLD and cannon.waypoint_queue.is_empty() and cannon.position.distance_to(Vector3(0,0,9)) < cannon.radius,"carriage finishes queued corridor crossing and turn")
	var at: Vector3 = cannon.position
	await create_timer(.4).timeout
	check(cannon.position.distance_to(at) < .03,"held four-wheel chassis remains still")
	var target: BattleBuilding = walls[0]
	target.owner_id = 1
	target.alliance_id = 1
	var hp: float = target.hp
	cannon.issue_attack(target)
	for tick: int in 150:
		await physics_frame
		if target.hp < hp: break
	check(target.hp == hp-190,"real cannonball deals exactly 190 to ten-armor building")
	cannon.stop()
	check(cannon.position.distance_to(target.position) > 5 and cannon.position.is_finite(),"wall-side shot retains valid standoff position")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open("res://.local/heavy-cannon-20260913/navigation-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"minimum_clearance":minimum_clearance},"\t"))
	print("HEAVY_CANNON_NAVIGATION ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
