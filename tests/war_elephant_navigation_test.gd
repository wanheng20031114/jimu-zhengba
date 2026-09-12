extends SceneTree
## Actual narrow passage, building-edge combat and queued command lifecycle.
var checks: int=0
var failures: Array[String]=[]
var game: Node3D

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)

func _run() -> void:
	create_timer(70.0,true,false,true).timeout.connect(func(): quit(3))
	seed(99133)
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game=current_scene
	while not game._match_ready:
		await process_frame
	game.set_placing(false)
	var walls: Array[BattleBuilding]=[]
	# Barracks are six metres wide, five deep. This leaves a real 4 m gap.
	for x: float in [-5,5]:
		for z: float in [-5,0,5]:
			var wall: BattleBuilding=game.spawn_building("barracks",0,Vector3(x,0,z))
			wall.set_physics_process(false)
			walls.append(wall)
	var navigation: ConstructionNavigation=game.get_node("ConstructionNavigation")
	navigation.refresh()
	while navigation.is_rebuilding():
		await process_frame
	# Publish the finished worker mesh to NavigationServer before requesting a path.
	await physics_frame
	await physics_frame
	await process_frame
	var elephant: BattleUnit=game.spawn_unit("war_elephant",0,Vector3(0,0,-11))
	game.set_running(true)
	elephant.issue_move(Vector3(0,0,11))
	elephant.queue_move(Vector3(0,0,9))
	elephant.hold(true)
	check(elephant.waypoint_queue.size()==2,"shift move and hold queue retain their sequence")
	var crossed: bool=false
	var minimum_clearance: float=INF
	for tick: int in 540:
		await physics_frame
		await process_frame
		if absf(elephant.position.z)<7.5:
			crossed=true
			minimum_clearance=minf(minimum_clearance,2.0-absf(elephant.position.x))
		if elephant.order==BattleUnit.Order.HOLD:
			break
	check(crossed and minimum_clearance>=elephant.radius*.85-.03,"elephant passes four-metre building corridor without clipping its collision body")
	print("ELEPHANT_QUEUED_ARRIVAL ",elephant.position," order=",elephant.order," remaining=",elephant.waypoint_queue.size())
	check(elephant.order==BattleUnit.Order.HOLD and elephant.waypoint_queue.is_empty() and elephant.position.distance_to(Vector3(0,0,9))<elephant.radius,"ordered waypoints and hold complete within the mount footprint")
	var held_at: Vector3=elephant.position
	await create_timer(.35).timeout
	check(elephant.position.distance_to(held_at)<.03,"hold remains stationary")
	elephant.issue_move(Vector3(0,0,-10),true)
	await create_timer(.4).timeout
	check(elephant.order==BattleUnit.Order.ATTACK_MOVE,"attack-move accepts the heavy mount")
	elephant.stop()
	check(elephant.waypoint_queue.is_empty() and elephant.target==null,"stop clears queued goals and combat target")
	var structure: BattleBuilding=walls[2]
	structure.owner_id=1
	structure.alliance_id=1
	elephant.issue_attack(structure)
	var starting_hp: float=structure.hp
	await create_timer(6.0).timeout
	check(structure.hp<starting_hp,"elephant reaches a building edge and delivers actual melee damage")
	check(elephant.position.is_finite() and not elephant.position.is_equal_approx(structure.position),"building collision prevents movement into the target centre")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open("res://artifacts/model-previews/war_elephant/navigation-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"minimum_corridor_clearance":minimum_clearance},"\t"))
	print("ELEPHANT_NAVIGATION ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
