extends SceneTree
## Offline authoring step: GLB sculptures become direct native ArrayMesh resources.

func _initialize() -> void:
	call_deferred("_bake")

func _bake() -> void:
	var material: ShaderMaterial = load("res://assets/models/units/unit_surface.tres")
	var saved: int = 0
	for kind: String in ["swordsman", "archer", "knight", "catapult", "cannon"]:
		var folder: String = "res://assets/models/units/" + kind + "/"
		var parts: Array = JSON.parse_string(FileAccess.get_file_as_string(folder + "parts.json"))
		for part: String in parts:
			var imported: Node3D = load(folder + part + ".glb").instantiate()
			var meshes: Array[Node] = imported.find_children("*", "MeshInstance3D", true, false)
			assert(meshes.size() == 1, "Every joint must have one consolidated mesh")
			var mesh: ArrayMesh = meshes[0].mesh.duplicate()
			assert(mesh.get_surface_count() == 1, "Every joint must have one surface")
			mesh.surface_set_material(0, material)
			mesh.resource_name = kind + "_" + part
			var result: Error = ResourceSaver.save(mesh, folder + part + ".res", ResourceSaver.FLAG_COMPRESS)
			assert(result == OK, "Native unit mesh save failed")
			imported.free()
			saved += 1
	print("NATIVE_UNIT_MESHES_SAVED ", saved)
	quit()
