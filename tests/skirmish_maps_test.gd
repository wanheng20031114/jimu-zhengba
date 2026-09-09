extends SceneTree
## Native resource, strategic symmetry and real NavigationServer reachability.

class TestHost extends Node3D:
	func register_entity(entity: Node) -> void:
		entity.entity_id = entity.get_instance_id()

var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		printerr("FAIL ", message)

func native_path(map_rid: RID, start: Vector3, target: Vector3) -> PackedVector3Array:
	var parameters := NavigationPathQueryParameters3D.new()
	parameters.map = map_rid
	parameters.start_position = start
	parameters.target_position = target
	# The 128 x 112 battlefield contains more cells than Godot's 4096 default.
	# A finite bound that covers the authored source avoids truncated long orders.
	parameters.path_search_max_polygons = 16384
	var result := NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(parameters, result)
	return result.path

func _run() -> void:
	for kind: String in ["factory", "academy", "player_barracks"]:
		var sculpture: Node3D = load("res://assets/models/environment/" + kind + ".tscn").instantiate()
		var bounds := AABB()
		var meshes: Array[Node] = sculpture.find_children("*", "MeshInstance3D", true, false)
		check(meshes.size() >= 5 and meshes.size() <= 7, kind + " consolidates details into bounded native material groups")
		for index: int in meshes.size():
			var mesh: ArrayMesh = meshes[index].mesh
			check(mesh != null and mesh.resource_path.ends_with(".res"), kind + " uses a directly editable native mesh resource")
			bounds = mesh.get_aabb() if index == 0 else bounds.merge(mesh.get_aabb())
		check(bounds.size.x <= 6.001 and bounds.size.z <= 6.001, kind + " fits six metre construction footprint")
		check(absf(bounds.position.y) < 0.001 and bounds.size.y > 5.0, kind + " is floor aligned and has a distinct architectural silhouette")
		sculpture.free()
	for map_id: String in ["amber_crossroads_1v1", "twin_valleys_2v2"]:
		await _check_map(map_id)
	print("SKIRMISH_MAPS_RESULT ", checks, " checks / ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _check_map(map_id: String) -> void:
	var host := TestHost.new()
	root.add_child(host)
	current_scene = host
	var map_scene: Node3D = load("res://scenes/maps/" + map_id + ".tscn").instantiate()
	host.add_child(map_scene)
	var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://scenes/maps/" + map_id + "_layout.json"))
	check(map_scene.get_meta("map_id") == map_id, map_id + " carries its stable selection id")
	check(map_scene.get_meta("map_size") == Vector2(layout.size[0], layout.size[1]), map_id + " carries exact camera and placement bounds")
	check(map_scene.get_node("Resources").get_child_count() == layout.mines.size(), map_id + " has all authored permanent mines")
	check(map_scene.get_node("SpawnPoints").get_child_count() == layout.spawns.size(), map_id + " has every player spawn")
	var region: NavigationRegion3D = map_scene.get_node("NavigationRegion3D")
	var mesh: NavigationMesh = region.navigation_mesh
	var vertices: PackedVector3Array = mesh.get_vertices()
	var cells: Dictionary = {}
	for index: int in mesh.get_polygon_count():
		var polygon: PackedInt32Array = mesh.get_polygon(index)
		var center := Vector3.ZERO
		for vertex: int in polygon:
			center += vertices[vertex]
		center /= polygon.size()
		cells[Vector2i(floori(center.x), floori(center.z))] = true
	check(cells.size() == mesh.get_polygon_count(), map_id + " retains one metre source cells for dynamic building navigation")
	var symmetric: bool = true
	for cell: Vector2i in cells:
		if not cells.has(Vector2i(-cell.x - 1, -cell.y - 1)):
			symmetric = false
			break
	check(symmetric, map_id + " navigable terrain is exactly symmetric under a half turn")
	for index: int in layout.spawns.size():
		var spawn: Marker3D = map_scene.get_node("SpawnPoints/Player" + str(index))
		check(spawn.get_meta("alliance_id") == layout.spawns[index][2], map_id + " assigns the intended neighboring allies")
		check(cells.has(Vector2i(spawn.position.x, spawn.position.z)), map_id + " starts every player on the main navigation component")
		var development_clear: bool = true
		for collider: StaticBody3D in map_scene.get_node("Environment/NaturalObstacles").get_children():
			var shape: BoxShape3D = collider.get_node("CollisionShape3D").shape
			var clearance: float = Vector2(collider.position.x, collider.position.z).distance_to(Vector2(spawn.position.x, spawn.position.z)) - Vector2(shape.size.x, shape.size.z).length() * 0.5
			if clearance < 11.45:
				development_clear = false
		check(development_clear, map_id + " keeps each base development circle unobstructed")
	# Native server synchronization needs both boundaries, not catch-up physics
	# ticks within the same render frame.
	for frame: int in 5:
		await physics_frame
		await process_frame
	var map_rid: RID = region.get_navigation_map()
	var start: Vector3 = map_scene.get_node("SpawnPoints/Player0").global_position
	for marker: Marker3D in map_scene.get_node("SpawnPoints").get_children():
		if marker.global_position.is_equal_approx(start):
			continue
		var path: PackedVector3Array = native_path(map_rid, start, marker.global_position)
		if path.is_empty() or path[-1].distance_to(marker.global_position) >= 0.10:
			print("BASE_PATH_DIAGNOSTIC ", marker.name, " size=", path.size(), " target=", marker.global_position, " last=", Vector3.INF if path.is_empty() else path[-1])
		check(not path.is_empty() and path[-1].distance_to(marker.global_position) < 0.10, map_id + " native navigation connects all player bases")
	for mine: Node3D in map_scene.get_node("Resources").get_children():
		check(mine.get_node("GatherSlots").get_child_count() == 6, map_id + " preserves six physical mining places")
		var all_slots_clear: bool = true
		var all_slots_reachable: bool = true
		for slot: Marker3D in mine.get_node("GatherSlots").get_children():
			var query := PhysicsShapeQueryParameters3D.new()
			var sphere := SphereShape3D.new()
			sphere.radius = 0.45
			query.shape = sphere
			query.transform = Transform3D(Basis.IDENTITY, slot.global_position + Vector3.UP * 0.7)
			query.collision_mask = 3
			if not host.get_world_3d().direct_space_state.intersect_shape(query).is_empty():
				all_slots_clear = false
			var nearest: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, slot.global_position)
			var path: PackedVector3Array = native_path(map_rid, start, slot.global_position)
			if nearest.distance_to(slot.global_position) > 0.50 or path.is_empty() or path[-1].distance_to(slot.global_position) > 0.50:
				all_slots_reachable = false
				print("SLOT_PATH_DIAGNOSTIC ", mine.name, "/", slot.name, " size=", path.size(), " target=", slot.global_position, " nearest=", nearest, " last=", Vector3.INF if path.is_empty() else path[-1])
		check(all_slots_clear, map_id + "/" + mine.name + " all six miners fit without hitting natural obstacles")
		check(all_slots_reachable, map_id + "/" + mine.name + " all six mining places connect to the main battlefield")
	map_scene.queue_free()
	await process_frame
	host.queue_free()
	await process_frame
