extends SceneTree
## Six-seat resources, authored symmetry, clear lanes and native mining paths.

class TestHost extends Node3D:
	func register_entity(entity: Node) -> void:
		entity.entity_id = entity.get_instance_id()

const MAP_IDS: Array[String] = ["three_frontiers_3v3", "triad_basin_2v2v2", "crownfall_ffa"]
var checks: int = 0
var failures: Array[String] = []
var metrics: Array[Dictionary] = []

func _initialize() -> void:
	Engine.max_fps = 60
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error(label)

func _run() -> void:
	for map_id: String in MAP_IDS:
		await _check_map(map_id)
	print("SIX_PLAYER_MAPS_RESULTS " + JSON.stringify({"checks": checks, "failures": failures, "maps": metrics}))
	quit(0 if failures.is_empty() else 1)

func _path(map_rid: RID, start: Vector3, target: Vector3) -> PackedVector3Array:
	var parameters := NavigationPathQueryParameters3D.new()
	parameters.map = map_rid
	parameters.start_position = start
	parameters.target_position = target
	parameters.path_search_max_polygons = 32768
	var result := NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(parameters, result)
	return result.path

func _check_map(map_id: String) -> void:
	var definition: MapDefinition = load("res://data/maps/" + map_id + ".tres")
	var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://scenes/maps/" + map_id + "_layout.json"))
	var host := TestHost.new()
	root.add_child(host)
	current_scene = host
	var map_scene: Node3D = definition.scene.instantiate()
	host.add_child(map_scene)
	check(definition.slots == 6 and definition.size == map_scene.get_meta("map_size"), map_id + "_six_seat_resource_and_native_bounds_agree")
	check(map_scene.get_node("SpawnPoints").get_child_count() == 6, map_id + "_all_six_native_spawn_markers")
	check(map_scene.get_node("Resources").get_child_count() == layout.mines.size(), map_id + "_native_resource_count")
	check(definition.size.x <= 192.0 and definition.size.y <= 192.0, map_id + "_bounded_fog_grid")
	var region: NavigationRegion3D = map_scene.get_node("NavigationRegion3D")
	var source: NavigationMesh = region.navigation_mesh
	var vertices: PackedVector3Array = source.get_vertices()
	var cells: Dictionary = {}
	var ordered: Array[Vector2i] = []
	for index: int in source.get_polygon_count():
		var polygon: PackedInt32Array = source.get_polygon(index)
		var center := Vector3.ZERO
		for vertex: int in polygon:
			center += vertices[vertex]
		center /= polygon.size()
		var cell := Vector2i(floori(center.x), floori(center.z))
		cells[cell] = true
		ordered.append(cell)
	check(cells.size() == source.get_polygon_count(), map_id + "_one_metre_cells_support_building_carving")
	ordered.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y if a.y != b.y else a.x < b.x)
	var started: int = Time.get_ticks_usec()
	region.navigation_mesh = ConstructionNavigation._compact_mesh(source, ordered, cells)
	var elapsed_ms: float = (Time.get_ticks_usec() - started) / 1000.0
	check(region.navigation_mesh.get_polygon_count() < source.get_polygon_count() / 2, map_id + "_native_compaction_bounds_path_queries")
	var symmetry: int = int(layout.symmetry)
	var turn: float = TAU / symmetry
	for index: int in range(layout.obstacles.size()):
		var item: Dictionary = layout.obstacles[index]
		var next: Dictionary = layout.obstacles[index - index % symmetry + (index + 1) % symmetry]
		var at := Vector3(item.position[0], 0, item.position[2]).rotated(Vector3.UP, turn)
		var target := Vector3(next.position[0], 0, next.position[2])
		check(at.distance_to(target) < 0.0001 and item.model == next.model and item.scale == next.scale, map_id + "_obstacle_%d_preserves_team_rotation" % index)
	for owner: int in range(6):
		var spawn: Marker3D = map_scene.get_node("SpawnPoints/Player%d" % owner)
		var tower: Vector3 = spawn.get_meta("starting_tower_position")
		var mine: Node3D = map_scene.get_node("Resources/GoldVein%d" % owner)
		check(spawn.get_meta("player_id") == owner and spawn.get_meta("alliance_id") == int(layout.spawns[owner][2]), map_id + "_owner_%d_native_owner_alliance" % owner)
		check(cells.has(Vector2i(floori(spawn.position.x), floori(spawn.position.z))), map_id + "_owner_%d_spawn_on_shared_navigation" % owner)
		var nearest: Node3D = mine
		for candidate: Node3D in map_scene.get_node("Resources").get_children():
			if candidate.position.distance_squared_to(spawn.position) < nearest.position.distance_squared_to(spawn.position):
				nearest = candidate
		check(nearest == mine, map_id + "_owner_%d_nearest_mine_is_own_birth_mine" % owner)
		var front: Vector3 = -spawn.position.normalized()
		var left := Vector3(front.z, 0, -front.x)
		check((mine.position - spawn.position).dot(left) > 0.0 and tower.distance_to(mine.position) <= 9.0, map_id + "_owner_%d_tower_protects_left_birth_mine" % owner)
	for frame: int in range(5):
		await physics_frame
		await process_frame
	var map_rid: RID = region.get_navigation_map()
	var origin: Vector3 = map_scene.get_node("SpawnPoints/Player0").global_position
	for spawn: Marker3D in map_scene.get_node("SpawnPoints").get_children():
		var path: PackedVector3Array = _path(map_rid, origin, spawn.global_position)
		check(not path.is_empty() and path[-1].distance_to(spawn.global_position) < 0.1, map_id + "_" + str(spawn.name) + "_connected_to_other_bases")
	var query := PhysicsShapeQueryParameters3D.new()
	var worker := SphereShape3D.new()
	worker.radius = 0.45
	query.shape = worker
	query.collision_mask = 3
	var space: PhysicsDirectSpaceState3D = host.get_world_3d().direct_space_state
	for mine: Node3D in map_scene.get_node("Resources").get_children():
		check(mine.get_node("GatherSlots").get_child_count() == 6, map_id + "_" + str(mine.name) + "_six_slots")
		for slot: Marker3D in mine.get_node("GatherSlots").get_children():
			query.transform = Transform3D(Basis.IDENTITY, slot.global_position + Vector3.UP * 0.7)
			check(space.intersect_shape(query, 1).is_empty(), map_id + "_" + str(mine.name) + "_" + str(slot.name) + "_worker_fits_native_geometry")
			var closest: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, slot.global_position)
			var path: PackedVector3Array = _path(map_rid, origin, slot.global_position)
			var accessible: bool = closest.distance_to(slot.global_position) < 0.21 and not path.is_empty() and path[-1].distance_to(slot.global_position) < 0.21
			check(accessible, map_id + "_" + str(mine.name) + "_" + str(slot.name) + "_reachable_without_navigation_snapping")
			if not accessible:
				print("MINING_PATH_DIAGNOSTIC ", map_id, " ", mine.name, "/", slot.name, " target=", slot.global_position, " nearest=", closest)
	metrics.append({"map": map_id, "mines": layout.mines.size(), "obstacles": layout.obstacles.size(), "source_polygons": source.get_polygon_count(), "compact_polygons": region.navigation_mesh.get_polygon_count(), "compact_ms": elapsed_ms})
	host.queue_free()
	await process_frame
	await process_frame
