extends SceneTree
## Verify the saved broad-phase bodies against the unchanged obstacle manifest.
## No game simulation or renderer benchmark is involved.

var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		push_error(label)

func _run() -> void:
	var environment: Node3D = load("res://scenes/environment.tscn").instantiate()
	root.add_child(environment)
	var solids: Node3D = environment.get_node("SolidEnvironment")
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/environment_obstacles.json"))
	var expected: Array = manifest.obstacles.filter(func(item: Dictionary): return not item.get("resource", false))
	_check(not solids is PhysicsBody3D, "container contributes no world-sized compound physics body")
	_check(solids.get_child_count() == expected.size(), "one saved physics body per natural obstacle")
	for frame: int in range(4):
		await physics_frame
		await process_frame
	var probe := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.02
	probe.shape = sphere
	probe.collision_mask = 1
	var space: PhysicsDirectSpaceState3D = environment.get_world_3d().direct_space_state
	for item: Dictionary in expected:
		var body: StaticBody3D = solids.get_node(str(item.name))
		var shape: CollisionShape3D = body.get_node("CollisionShape3D")
		var position_expected := Vector3(item.position[0], item.position[1], item.position[2])
		var size_expected := Vector3(item.size[0], item.size[1], item.size[2])
		var basis_expected := Basis(Vector3.UP, item.rotation_y)
		_check(body.collision_layer == 1 and body.collision_mask == 0, str(item.name) + " preserves collision layers")
		_check(body.get_child_count() == 1 and body.get_shape_owners().size() == 1 and shape.transform.is_equal_approx(Transform3D.IDENTITY), str(item.name) + " owns one untransformed primitive")
		_check(shape.shape is BoxShape3D and shape.shape.size.distance_to(size_expected) < 0.00009, str(item.name) + " preserves box dimensions")
		_check(shape.global_position.distance_to(position_expected) < 0.00009 and shape.global_basis.is_equal_approx(basis_expected), str(item.name) + " preserves world position and rotation")
		probe.transform.origin = body.global_position
		var found: bool = false
		for hit: Dictionary in space.intersect_shape(probe, 8):
			found = found or hit.collider == body
		_check(found, str(item.name) + " remains queryable at its original world-space center")
	var report := {"checks": checks, "failures": failures, "natural_bodies": expected.size(), "rendered": false}
	FileAccess.open("res://artifacts/environment_collision_audit.json", FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	print("ENVIRONMENT_COLLISION_AUDIT ", JSON.stringify(report))
	environment.queue_free()
	await process_frame
	await physics_frame
	quit(0 if failures.is_empty() else 1)
