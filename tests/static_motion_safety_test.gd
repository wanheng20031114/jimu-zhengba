extends SceneTree
## Differential motion against CharacterBody3D on the real map, plus cache
## invalidation at building creation, geometry changes and destruction.
var game: Node3D
var grid: StaticMotionGrid
var checks := 0
var failures: Array[String] = []
var certified_cases := 0
var native_cases := 0

func _initialize() -> void: _run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func sync_space() -> void:
	await physics_frame
	await process_frame
	await physics_frame
	await process_frame

func spawn(kind: String) -> BattleUnit:
	var unit: BattleUnit = game.spawn_unit(kind, 0, Vector3.ZERO)
	unit.navigation_agent.avoidance_enabled = false
	unit.set_physics_process(false)
	return unit

func _run() -> void:
	create_timer(90.0, true, false, true).timeout.connect(func(): quit(3))
	seed(6001309)
	var session: Node = root.get_node("Session")
	session.online = false
	session.config = session.offline_config("4v4")
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	game.tests_running = true
	game.bots.clear()
	game.set_physics_process(false)
	game.get_node("IncomeTimer").stop()
	for unit: Node in game.unit_container.get_children(): unit.queue_free()
	await sync_space()
	grid = game.get_node("StaticMotionGrid")
	grid.fast_path_enabled = true
	grid.configure(game.map_instance, game.get_node("Buildings"), Rect2(-game.map_size * 0.5, game.map_size))
	check(grid.is_current, "real map supports the optional static movement certificate")
	check(grid.obstacle_count > 0, "real map colliders are present")
	var largest_error := 0.0
	for kind: String in BalanceCatalog.UNITS:
		var cached := spawn(kind)
		var native := spawn(kind)
		await sync_space()
		await physics_frame
		check(Engine.is_in_physics_frame(), "native motion comparison uses the physics clock")
		for sample: int in 160:
			var start := Vector3(randf_range(-52, 52), 0, randf_range(-39, 39))
			var angle := randf() * TAU
			var speed := Vector3(cos(angle), 0, sin(angle)) * cached.speed
			cached.global_position = start
			native.global_position = start
			var before: int = grid.fast_steps
			grid.fast_path_enabled = true
			cached._apply_velocity(speed)
			var certified: bool = grid.fast_steps > before
			grid.fast_path_enabled = false
			native._apply_velocity(speed)
			grid.fast_path_enabled = true
			var difference: float = cached.global_position.distance_to(native.global_position)
			largest_error = maxf(largest_error, difference)
			check(difference < 0.0001, "%s sample %d matches native wall collision (%.6f)" % [kind, sample, difference])
			if certified: certified_cases += 1
			else: native_cases += 1
		cached.queue_free()
		native.queue_free()
		await sync_space()
	check(certified_cases >= 100, "comparison actually exercises at least 100 certified movement steps")
	check(native_cases >= 100, "comparison also exercises native motion around obstacles")
	check(not grid.clear_sweep(Vector3(1000, 0, 0), Vector3(1001, 0, 0), 0.6), "outside-map motion is never certified")
	check(not grid.clear_sweep(Vector3(0, 1, 0), Vector3(1, 1, 0), 0.6), "off-plane motion is never certified")
	var anchor := Vector3.INF
	for x: int in range(-45, 46, 4):
		for z: int in range(-35, 36, 4):
			var at := Vector3(x, 0, z)
			if grid.clear_sweep(at, at, 6.0):
				anchor = at
				break
		if anchor.is_finite(): break
	check(anchor.is_finite(), "fixture finds a genuinely empty construction area")
	if anchor.is_finite():
		var mover := spawn("knight")
		await physics_frame
		mover.global_position = anchor
		mover._apply_velocity(Vector3.RIGHT * mover.speed)
		check(mover._motion_region_clear, "mover owns a positive cached certificate before construction")
		var revision: int = grid.revision
		var building: BattleBuilding = game.spawn_building("house", 1, anchor + Vector3(3, 0, 0), true)
		check(not grid.is_current and grid.revision > revision, "spawning a building immediately invalidates existing certificates")
		var before: int = grid.native_steps
		mover._apply_velocity(Vector3.RIGHT * mover.speed)
		check(grid.native_steps == before + 1, "an invalid certificate immediately uses native collision")
		await sync_space()
		check(grid.is_current and not grid.clear_sweep(anchor, anchor + Vector3(5, 0, 0), mover._motion_clearance), "rebuilt grid includes the new construction body")
		grid.invalidate()
		building.rotation.y = PI * 0.25
		building.scale = Vector3(1.2, 1.0, 0.8)
		grid.schedule_rebuild.call_deferred()
		await sync_space()
		check(grid.is_current and not grid.clear_sweep(anchor, anchor + Vector3(5, 0, 0), mover._motion_clearance), "rotated and scaled static geometry remains blocked")
		building.receive_damage(100000.0)
		check(not grid.is_current, "building destruction invalidates the grid before deferred collider removal")
		await sync_space()
		check(grid.is_current and grid.clear_sweep(anchor, anchor + Vector3(5, 0, 0), mover._motion_clearance), "destruction republishes the newly open ground")
		mover.queue_free()
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("STATIC_MOTION_SAFETY %d checks; %d failures; %d certified, %d native; max error %.8f" % [checks, failures.size(), certified_cases, native_cases, largest_error])
	quit(0 if failures.is_empty() else 1)
