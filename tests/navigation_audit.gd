extends SceneTree
## Godot --headless --path . --script res://tests/navigation_audit.gd
## Uses only the authored NavigationMesh resources: no game simulation, models,
## project runtime logic, geometry baking, or synthetic test-only nav polygons.

var failures: Array[String] = []
var checks: int = 0
var navigation_map: RID
var fixture: Node3D
var base_region: NavigationRegion3D
var patch_regions: Dictionary = {}
var patch_cells: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/navigation/audit_manifest.json"))
	fixture = Node3D.new()
	fixture.name = "NavigationAuditFixture"
	root.add_child(fixture)
	navigation_map = NavigationServer3D.map_create()
	NavigationServer3D.map_set_active(navigation_map, true)
	NavigationServer3D.map_set_cell_size(navigation_map, 0.25)
	NavigationServer3D.map_set_cell_height(navigation_map, 0.25)
	# Shared vertices must connect without relying on a large fuzzy merge radius.
	NavigationServer3D.map_set_edge_connection_margin(navigation_map, 0.001)
	NavigationServer3D.map_set_use_edge_connections(navigation_map, true)
	NavigationServer3D.map_set_use_async_iterations(navigation_map, false)
	base_region = _region("Base", "res://assets/battle_navigation.tres", true)
	var ownership: Dictionary = {}
	_audit_mesh(base_region.navigation_mesh, "Base", ownership)
	for patch: Dictionary in data["patches"]:
		var region: NavigationRegion3D = _region(str(patch["name"]), str(patch["mesh"]), false)
		patch_regions[str(patch["name"])] = region
		patch_cells[str(patch["name"])] = _audit_mesh(region.navigation_mesh, str(patch["name"]), ownership)
		_check(not region.enabled, str(patch["name"]) + " starts disabled")
	await _sync(0)
	for route: Dictionary in data["routes"]:
		var start: Vector3 = _vector(route["start"])
		var end: Vector3 = _vector(route["end"])
		var path: PackedVector3Array = NavigationServer3D.map_get_path(navigation_map, start, end, true)
		_check(_reaches(path, end), str(route["name"]) + " reachable on the intact battlefield")
	for patch: Dictionary in data["patches"]:
		await _audit_demolition(patch, _vector(data["anchor"]))
	var previous: int = NavigationServer3D.map_get_iteration_id(navigation_map)
	for region: NavigationRegion3D in patch_regions.values():
		region.enabled = true
	await _sync(previous)
	for patch: Dictionary in data["patches"]:
		var probe: Vector3 = _vector(patch["probe"])
		var path: PackedVector3Array = NavigationServer3D.map_get_path(navigation_map, _vector(data["anchor"]), probe, true)
		_check(_reaches(path, probe), str(patch["name"]) + " stays reachable with all demolition patches enabled")
	fixture.queue_free()
	await process_frame
	await physics_frame
	NavigationServer3D.free_rid(navigation_map)
	await physics_frame
	print("NAVIGATION_AUDIT ", JSON.stringify({"checks": checks, "failures": failures, "regions": 6, "edge_connection_margin": 0.001}))
	quit(0 if failures.is_empty() else 1)


func _region(region_name: String, mesh_path: String, enabled: bool) -> NavigationRegion3D:
	var region := NavigationRegion3D.new()
	# Deterministic fixture setup: large-region geometry must finish uploading
	# before the first map iteration is used for assertions.
	NavigationServer3D.region_set_use_async_iterations(region.get_rid(), false)
	region.name = region_name
	region.enabled = enabled
	region.use_edge_connections = true
	region.navigation_layers = 1
	region.navigation_mesh = load(mesh_path) as NavigationMesh
	fixture.add_child(region)
	region.set_navigation_map(navigation_map)
	return region


func _sync(previous: int) -> void:
	await physics_frame
	await physics_frame
	NavigationServer3D.map_force_update(navigation_map)
	for frame in range(120):
		await physics_frame
		await process_frame
		if NavigationServer3D.map_get_iteration_id(navigation_map) > previous:
			return
	_check(false, "navigation server synchronizes within 120 physics frames")


func _audit_mesh(mesh: NavigationMesh, owner_name: String, ownership: Dictionary) -> Dictionary:
	var vertices: PackedVector3Array = mesh.get_vertices()
	var canonical: bool = true
	for vertex: Vector3 in vertices:
		canonical = canonical and is_equal_approx(vertex.x, roundf(vertex.x)) and is_equal_approx(vertex.z, roundf(vertex.z)) and absf(vertex.y - 0.03) < 0.00001
	_check(canonical, owner_name + " uses the canonical integer lattice at Y=0.03")
	var cells: Dictionary = {}
	var disjoint: bool = true
	var squares: bool = true
	for index in range(mesh.get_polygon_count()):
		var polygon: PackedInt32Array = mesh.get_polygon(index)
		if polygon.size() != 4:
			squares = false
			continue
		var midpoint := Vector3.ZERO
		for point_index: int in polygon:
			midpoint += vertices[point_index]
		midpoint /= 4.0
		var key := Vector2i(floori(midpoint.x), floori(midpoint.z))
		if ownership.has(key):
			disjoint = false
		ownership[key] = owner_name
		cells[key] = true
		for edge in range(4):
			var start: Vector3 = vertices[polygon[edge]]
			var end: Vector3 = vertices[polygon[(edge + 1) % 4]]
			squares = squares and is_equal_approx(start.distance_to(end), 1.0)
	_check(squares, owner_name + " has only one-metre shared polygon edges")
	_check(disjoint, owner_name + " does not overlap any other region's cells")
	return cells


func _audit_demolition(patch: Dictionary, anchor: Vector3) -> void:
	var patch_name: String = str(patch["name"])
	var region: NavigationRegion3D = patch_regions[patch_name]
	var probe: Vector3 = _vector(patch["probe"])
	var start: Vector3 = _vector(patch["crossing_start"])
	var end: Vector3 = _vector(patch["crossing_end"])
	# Closest-point queries include disabled regions in Godot 4.6. Only the
	# actual path result proves whether an agent can enter a disabled footprint.
	var inaccessible_path: PackedVector3Array = NavigationServer3D.map_get_path(navigation_map, anchor, probe, true)
	_check(not _reaches(inaccessible_path, probe), patch_name + " footprint is unavailable before demolition")
	var before_path: PackedVector3Array = NavigationServer3D.map_get_path(navigation_map, start, end, true)
	_check(_reaches(before_path, end), patch_name + " can be bypassed while intact")
	var previous: int = NavigationServer3D.map_get_iteration_id(navigation_map)
	region.enabled = true
	await _sync(previous)
	var closest_after: Vector3 = NavigationServer3D.map_get_closest_point(navigation_map, probe)
	_check(closest_after.distance_to(probe) < 0.025, patch_name + " footprint becomes navigable after enabling its native region")
	var inside_path: PackedVector3Array = NavigationServer3D.map_get_path(navigation_map, anchor, probe, true)
	_check(_reaches(inside_path, probe), patch_name + " patch connects to the main region through exact shared edges")
	var after_path: PackedVector3Array = NavigationServer3D.map_get_path(navigation_map, start, end, true)
	_check(_reaches(after_path, end), patch_name + " cross-building route reaches the opposite side")
	_check(_path_uses_cells(after_path, patch_cells[patch_name]), patch_name + " route actually traverses the cleared building cells")
	_check(_path_length(after_path) + 0.20 < _path_length(before_path), patch_name + " demolition opens a shorter route through its former footprint")
	print("DEMOLITION_ROUTE ", patch_name, " ", JSON.stringify({"intact_length": _path_length(before_path), "cleared_length": _path_length(after_path)}))
	previous = NavigationServer3D.map_get_iteration_id(navigation_map)
	region.enabled = false
	await _sync(previous)
	var disabled_path: PackedVector3Array = NavigationServer3D.map_get_path(navigation_map, anchor, probe, true)
	_check(not _reaches(disabled_path, probe), patch_name + " disabled patch no longer exposes its cells to pathfinding")


func _path_uses_cells(path: PackedVector3Array, cells: Dictionary) -> bool:
	for index in range(path.size() - 1):
		var start: Vector3 = path[index]
		var end: Vector3 = path[index + 1]
		var steps: int = maxi(1, ceili(start.distance_to(end) / 0.15))
		for sample in range(steps + 1):
			var point: Vector3 = start.lerp(end, float(sample) / float(steps))
			if cells.has(Vector2i(floori(point.x), floori(point.z))):
				return true
	return false


func _reaches(path: PackedVector3Array, target: Vector3) -> bool:
	return not path.is_empty() and path[path.size() - 1].distance_to(target) < 0.025


func _path_length(path: PackedVector3Array) -> float:
	var total: float = 0.0
	for index in range(path.size() - 1):
		total += path[index].distance_to(path[index + 1])
	return total


func _vector(values: Array) -> Vector3:
	return Vector3(float(values[0]), float(values[1]), float(values[2]))


func _check(condition: bool, description: String) -> void:
	checks += 1
	if condition:
		print("PASS: ", description)
	else:
		failures.append(description)
		push_error("FAIL: " + description)
