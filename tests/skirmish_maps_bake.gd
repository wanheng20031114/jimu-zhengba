extends SceneTree
## Offline authoring only. Final matches load the native resources saved here.

func _initialize() -> void:
	var manifest: Array = JSON.parse_string(FileAccess.get_file_as_string("res://.local/skirmish_authoring/manifest.json"))
	var total: int = 0
	for entry: Dictionary in manifest:
		var payload: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(entry.source))
		var scene := Node3D.new()
		scene.name = payload.destination.get_file().get_basename().to_pascal_case()
		for part: Dictionary in payload.parts:
			var arrays: Array = []
			arrays.resize(Mesh.ARRAY_MAX)
			var vertices := PackedVector3Array()
			var normals := PackedVector3Array()
			var colors := PackedColorArray()
			for index: int in range(0, part.vertices.size(), 3):
				vertices.append(Vector3(part.vertices[index], part.vertices[index + 1], part.vertices[index + 2]))
				normals.append(Vector3(part.normals[index], part.normals[index + 1], part.normals[index + 2]))
			for index: int in range(0, part.colors.size(), 4):
				colors.append(Color(part.colors[index], part.colors[index + 1], part.colors[index + 2], part.colors[index + 3]))
			arrays[Mesh.ARRAY_VERTEX] = vertices
			arrays[Mesh.ARRAY_NORMAL] = normals
			arrays[Mesh.ARRAY_COLOR] = colors
			# trimesh uses counterclockwise winding; native Godot fronts are clockwise.
			var indices := PackedInt32Array(part.indices)
			for index: int in range(0, indices.size(), 3):
				var swap: int = indices[index + 1]
				indices[index + 1] = indices[index + 2]
				indices[index + 2] = swap
			arrays[Mesh.ARRAY_INDEX] = indices
			var mesh := ArrayMesh.new()
			mesh.resource_name = String(scene.name) + part.name
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			var material := StandardMaterial3D.new()
			material.resource_name = part.name
			material.vertex_color_use_as_albedo = true
			material.roughness = 0.84
			if part.name == "Metal":
				material.metallic = 0.65
				material.roughness = 0.38
			elif part.name == "Glass":
				material.metallic = 0.05
				material.roughness = 0.34
			if part.name in ["Fabric", "Foliage"]:
				material.cull_mode = BaseMaterial3D.CULL_DISABLED
			mesh.surface_set_material(0, material)
			var resource_path: String = payload.destination.trim_suffix(".tscn") + "_" + String(part.name).to_snake_case() + ".res"
			assert(ResourceSaver.save(mesh, resource_path, ResourceSaver.FLAG_COMPRESS) == OK)
			var instance := MeshInstance3D.new()
			instance.name = part.name
			instance.mesh = load(resource_path)
			if not payload.shadow:
				instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			scene.add_child(instance)
			instance.owner = scene
			total += 1
		var packed := PackedScene.new()
		assert(packed.pack(scene) == OK)
		assert(ResourceSaver.save(packed, payload.destination) == OK)
		scene.free()
	print("SKIRMISH_NATIVE_RESOURCES_SAVED ", total, " meshes / ", manifest.size(), " scenes")
	quit()
