extends SceneTree
## Observer-relative native model colors and visual-derived obstacle collisions.

class TestHost extends Node3D:
	var is_authority := false
	var local_owner_id := 0
	var players: Array[PlayerState] = []
	func get_player(owner: int) -> PlayerState:
		return players[owner]
	func register_entity(entity: Node) -> void:
		entity.entity_id = entity.get_instance_id()

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func run() -> void:
	var host := TestHost.new()
	for owner in 4:
		host.players.append(PlayerState.new(owner, owner / 2))
	root.add_child(host)
	current_scene = host
	for observer in 4:
		host.local_owner_id = observer
		for owner in 4:
			var expected := FactionPalette.SELF if owner == observer else (FactionPalette.ALLY if owner / 2 == observer / 2 else FactionPalette.ENEMY)
			check(FactionPalette.relation(owner, owner / 2, host) == expected, "observer %d sees owner %d by relationship" % [observer, owner])
			for kind: String in ["headquarters", "barracks", "factory", "academy", "defense_tower"]:
				var building: BattleBuilding = load("res://scenes/building.tscn").instantiate()
				building.owner_id = owner
				building.building_type = kind
				host.add_child(building)
				check(building.owner_id == owner and building.alliance_id == owner / 2, kind + " preserves authority ownership")
				check(building.health_bar.get_instance_shader_parameter("bar_color") == FactionPalette.ui_color(expected), kind + " health bar follows observer")
				var dyed_vertices := 0
				var total_vertices := 0
				for mesh: MeshInstance3D in building._model.find_children("*", "MeshInstance3D", true, false):
					check(mesh.get_instance_shader_parameter("team_color") == FactionPalette.model_color(expected), kind + " applies native per-instance color")
					if mesh.mesh is ArrayMesh:
						var material: ShaderMaterial = mesh.mesh.surface_get_material(0)
						check(material.shader.resource_path.ends_with("building_surface.gdshader"), kind + " uses the shared heraldry material")
						var arrays := mesh.mesh.surface_get_arrays(0)
						for color: Color in arrays[Mesh.ARRAY_COLOR]:
							total_vertices += 1
							if color.a > 0.5: dyed_vertices += 1
				check(dyed_vertices > 50 and dyed_vertices < total_vertices, kind + " has broad explicit paint regions and unpainted masonry")
				building.queue_free()
			await process_frame
	for kind: String in ["swordsman", "archer", "knight", "catapult", "cannon", "farmer"]:
		var unit_model: Node3D = BattleUnit.MODELS[kind].instantiate()
		host.add_child(unit_model)
		for relation in 3:
			unit_model.set_team(relation)
			var all_correct := true
			for mesh: MeshInstance3D in unit_model.get_node("Rig").find_children("*", "MeshInstance3D", true, false):
				all_correct = all_correct and mesh.get_instance_shader_parameter("team_color") == FactionPalette.model_color(relation)
			check(all_correct, kind + " supports three relationship colors")
		unit_model.queue_free()
	for map_id: String in ["amber_crossroads_1v1", "twin_valleys_2v2"]:
		var map: Node3D = load("res://scenes/maps/" + map_id + ".tscn").instantiate()
		host.add_child(map)
		for frame in 3:
			await physics_frame
			await process_frame
		var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://scenes/maps/" + map_id + "_layout.json"))
		var checked_empty_corner := false
		for item: Dictionary in layout.obstacles:
			var body: StaticBody3D = map.get_node("Environment/NaturalObstacles/" + item.name)
			var shape: Shape3D = body.get_node("CollisionShape3D").shape
			if item.collision.type == "convex":
				check(shape is ConvexPolygonShape3D, item.name + " uses the modeled rock hull")
				check(shape.points.size() == item.collision.points.size(), item.name + " collider matches saved authoring points")
				check(is_zero_approx(body.position.y), item.name + " rock hull keeps the model origin")
				if not checked_empty_corner:
					var footprint := PackedVector2Array()
					for point: Array in item.collision.footprint:
						footprint.append(Vector2(point[0], point[1]))
					for sign_x in [-1, 1]:
						for sign_z in [-1, 1]:
							var old_corner := Vector2(float(item.size[0]) * 0.46 * sign_x, float(item.size[2]) * 0.46 * sign_z)
							if Geometry2D.is_point_in_polygon(old_corner, footprint): continue
							var sphere := SphereShape3D.new()
							sphere.radius = 0.03
							var query := PhysicsShapeQueryParameters3D.new()
							query.shape = sphere
							query.collision_mask = 1
							query.transform.origin = body.to_global(Vector3(old_corner.x, 0.6, old_corner.y))
							check(host.get_world_3d().direct_space_state.intersect_shape(query).is_empty(), item.name + " former invisible box corner is physically open")
							checked_empty_corner = true
			else:
				check(shape is CylinderShape3D, item.name + " blocks only the trunk")
				check(absf(shape.radius - item.collision.radius) < 0.00001 and shape.radius < item.size[0] * 0.5, item.name + " has no square canopy collider")
		map.queue_free()
		await process_frame
	var unit_scene: Node = load("res://scenes/unit.tscn").instantiate()
	check(not unit_scene.has_node("MovementDust"), "no persistent movement particle emitter per unit")
	unit_scene.free()
	host.queue_free()
	await process_frame
	await process_frame
	print("WORLD_READABILITY_RESULT ", checks, " checks / ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
