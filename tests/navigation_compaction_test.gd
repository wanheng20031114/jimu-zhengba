extends SceneTree
## Verify exact cell coverage, T-junctions, native routes and live mine access.
var game: Node3D
var navigation: ConstructionNavigation
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func sync() -> void:
	while navigation.is_rebuilding():
		await physics_frame
		await process_frame
	# A fixture needs the latest replacement, not an earlier async iteration.
	# Force synchronization only at explicit test boundaries, never in gameplay.
	NavigationServer3D.map_force_update(game.get_world_3d().navigation_map)
	for i in range(6):
		await physics_frame
		await process_frame

func mesh_coverage(label: String) -> void:
	var mesh: NavigationMesh = game.map_instance.get_node("NavigationRegion3D").navigation_mesh
	var vertices: PackedVector3Array = mesh.vertices
	var covered: Dictionary = {}
	var edges: Dictionary = {}
	var total_area: float = 0.0
	var polygons_valid: bool = true
	for index in mesh.get_polygon_count():
		var polygon := mesh.get_polygon(index)
		var plane_normal: Vector3 = (vertices[polygon[1]] - vertices[polygon[0]]).cross(vertices[polygon[2]] - vertices[polygon[0]])
		if plane_normal.y < 0.0001: polygons_valid = false
		var min_at := Vector2(10000, 10000)
		var max_at := Vector2(-10000, -10000)
		var outline := PackedVector2Array()
		var area: float = 0
		for p in range(polygon.size()):
			var a := vertices[polygon[p]]
			var b := vertices[polygon[(p + 1) % polygon.size()]]
			var c := vertices[polygon[(p + 2) % polygon.size()]]
			if (b - a).cross(c - b).y < -0.0001: polygons_valid = false
			min_at = min_at.min(Vector2(a.x, a.z))
			max_at = max_at.max(Vector2(a.x, a.z))
			outline.append(Vector2(a.x, a.z))
			area += a.x * b.z - b.x * a.z
			var key := Vector2i(mini(polygon[p], polygon[(p + 1) % polygon.size()]), maxi(polygon[p], polygon[(p + 1) % polygon.size()]))
			edges[key] = int(edges.get(key, 0)) + 1
		total_area += absf(area) * 0.5
		for x in range(floori(min_at.x), ceili(max_at.x)):
			for z in range(floori(min_at.y), ceili(max_at.y)):
				var cell := Vector2i(x, z)
				if Geometry2D.is_point_in_polygon(Vector2(x + 0.5, z + 0.5), outline): covered[cell] = true
	check(polygons_valid and is_equal_approx(total_area, navigation._walkable_cells.size()), label + " contains convex polygons with a valid projection plane and exactly the original walkable area")
	check(covered == navigation._walkable_cells, label + " preserves the exact authored walkable-cell union")
	var connected_edges: bool = true
	for key: Vector2i in edges:
		if int(edges[key]) > 2:
			connected_edges = false
			break
		if int(edges[key]) == 2: continue
		var a := vertices[key.x]
		var b := vertices[key.y]
		var midpoint: Vector3 = (a + b) * 0.5
		var normal := Vector3(0.25, 0, 0) if is_equal_approx(a.x, b.x) else Vector3(0, 0, 0.25)
		var left := Vector2i(floori((midpoint - normal).x), floori((midpoint - normal).z))
		var right := Vector2i(floori((midpoint + normal).x), floori((midpoint + normal).z))
		if covered.has(left) and covered.has(right):
			connected_edges = false
			break
	check(connected_edges, label + " splits every internal T-junction into matching native shared edges")
	check(mesh.get_polygon_count() < navigation._walkable_cells.size() / 2, label + " removes at least half of path-search polygons")

func query(from: Vector3, at: Vector3) -> PackedVector3Array:
	var parameters := NavigationPathQueryParameters3D.new()
	parameters.map = game.get_world_3d().navigation_map
	parameters.path_search_max_polygons = 16384
	parameters.start_position = from
	parameters.target_position = at
	var result := NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(parameters, result)
	return result.path

func safe_path(path: PackedVector3Array) -> bool:
	for index in range(1, path.size()):
		var steps := maxi(1, ceili(path[index].distance_to(path[index - 1]) / 0.2))
		for step in range(steps + 1):
			var at: Vector3 = path[index - 1].lerp(path[index], float(step) / steps)
			# Native funnel intersections can differ by a few float ulps at an
			# exact grid edge; canonicalize only that numerical boundary.
			if absf(at.x - roundf(at.x)) < 0.0001: at.x = roundf(at.x)
			if absf(at.z - roundf(at.z)) < 0.0001: at.z = roundf(at.z)
			if not navigation.contains_walkable_point(at):
				print("UNSAFE_ROUTE_POINT ", at, " segment ", path[index - 1], " -> ", path[index])
				return false
	return true

func _run() -> void:
	seed(99821)
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.bots.clear()
	game.get_node("IncomeTimer").stop()
	navigation = game.get_node("ConstructionNavigation")
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
	while not game.find_recruit_position("farmer", game.headquarters).is_finite(): await sync()
	await sync()
	mesh_coverage("Initial headquarters carving")
	var source_count: int = navigation._sources[0].mesh.get_polygon_count()
	var cells: Array = navigation._walkable_cells.keys()
	var elapsed_queries: Array[int] = []
	var random := RandomNumberGenerator.new()
	random.seed = 9819273
	var route_count: int = 2000 if "--soak" in OS.get_cmdline_user_args() else 280
	for i in range(route_count):
		var a: Vector2i = cells[random.randi_range(0, cells.size() - 1)]
		var b: Vector2i = cells[random.randi_range(0, cells.size() - 1)]
		var offset := Vector3(0.5, 0, 0.5)
		if i % 3 == 1: offset = Vector3(0.001, 0, 0.001)
		if i % 3 == 2: offset = Vector3(random.randf_range(0.01, 0.99), 0, random.randf_range(0.01, 0.99))
		var destination := Vector3(b.x, 0, b.y) + offset
		var began := Time.get_ticks_usec()
		var path := query(Vector3(a.x, 0, a.y) + offset, destination)
		elapsed_queries.append(Time.get_ticks_usec() - began)
		check(not path.is_empty() and path[-1].distance_to(destination) < 0.01, "random route %d reaches its original endpoint" % i)
		check(safe_path(path), "random route %d never cuts through an excluded cell" % i)
	var start: Vector3 = game.find_recruit_position("farmer", game.headquarters)
	for mine: ResourceVein in get_nodes_in_group("resource_veins"):
		for slot: Marker3D in mine.get_node("GatherSlots").get_children():
			var path := query(start, slot.global_position)
			check(not path.is_empty() and path[-1].distance_to(slot.global_position) < ResourceVein.MAX_CONTACT_APPROACH, "all six mine work positions remain reachable with a short collision-safe contact step")
	var at: Vector3 = game.find_build_location(0, "defense_tower", game.headquarters.position + Vector3(10, 0, 0))
	check(at.is_finite(), "dynamic tower fixture has a legal building position")
	var tower: BattleBuilding = game.spawn_building("defense_tower", 0, at, true)
	navigation.refresh()
	var carved_cells: Dictionary = navigation._walkable_cells.duplicate()
	check(not navigation.contains_walkable_point(at), "the same-frame grid excludes a new building foundation")
	await sync()
	mesh_coverage("New tower foundation")
	var rebuilds: int = navigation.rebuild_count
	for i in range(10): navigation.refresh()
	check(navigation.rebuild_count == rebuilds, "unchanged footprints do not rerun mesh compaction")
	tower.receive_damage(tower.hp + 100)
	navigation.refresh()
	await sync()
	mesh_coverage("Destroyed tower reopening")
	check(navigation.contains_walkable_point(at) and navigation._walkable_cells.size() > carved_cells.size(), "demolition restores the original passage")
	# Build and destroy again before the first worker has finished: stale jobs
	# must never overwrite the latest placement revision or lose its inputs.
	var transient: BattleBuilding = game.spawn_building("defense_tower", 0, at, true)
	navigation.refresh()
	var pending_revision: int = navigation._revision
	transient.receive_damage(transient.hp + 100)
	navigation.refresh()
	check(navigation._revision > pending_revision, "rapid demolition supersedes a pending construction revision")
	await sync()
	mesh_coverage("Coalesced construction and demolition")
	check(navigation.contains_walkable_point(at), "the newest asynchronous revision reopens a transient foundation")
	check(navigation._sources[0].mesh.get_polygon_count() == source_count, "the authored one-metre source mesh remains immutable")
	var report := {"mode": game.match_config.mode, "checks": checks, "failures": failures, "source_polygons": source_count, "compact_polygons": navigation.compact_polygon_count, "last_request_usec": navigation.last_request_usec, "worker_rebuild_usec": navigation.last_rebuild_usec, "query_usec": elapsed_queries}
	var file := FileAccess.open("res://artifacts/navigation_compaction_%s.json" % game.match_config.mode, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("NAVIGATION_COMPACTION_RESULT ", game.match_config.mode, " ", checks, " checks / ", failures.size(), " failures; polygons ", source_count, " -> ", navigation.compact_polygon_count)
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)
