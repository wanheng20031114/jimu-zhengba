extends SceneTree
## Offline authoring step: GLB sculptures become direct native ArrayMesh resources.

func _initialize() -> void:
	call_deferred("_bake")

func _bake() -> void:
	var material: ShaderMaterial = load("res://assets/models/units/unit_surface.tres")
	var saved: int = 0
	var kinds: PackedStringArray = OS.get_cmdline_user_args()
	if kinds.is_empty():
		kinds = ["swordsman", "shield_guard", "spearman", "archer", "knight", "war_elephant", "light_cavalry", "catapult", "cannon", "engineer", "farmer"]
	for kind: String in kinds:
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
	# Use native 3D transform tracks for the denser authored attack poses.
	for kind: String in kinds:
		var path: String = "res://assets/models/units/" + kind + ".tscn"
		# Autoloads may have cached the scene before its new meshes were saved.
		# Reload the authored references instead of packing that incomplete rig.
		var sculpture: Node3D = ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE).instantiate()
		for player_name: String in ["Locomotion", "Attack"]:
			var player: AnimationPlayer = sculpture.get_node(player_name)
			var library: AnimationLibrary = player.get_animation_library("")
			for animation_name: StringName in library.get_animation_list():
				var old: Animation = library.get_animation(animation_name)
				var converted: Animation = convert_animation(old)
				library.remove_animation(animation_name)
				library.add_animation(animation_name, converted)
		var packed := PackedScene.new()
		assert(packed.pack(sculpture) == OK)
		assert(ResourceSaver.save(packed, path) == OK)
		sculpture.free()
	print("NATIVE_UNIT_ATTACK_TRACKS_SAVED ", kinds.size(), " scenes")
	quit()

static func convert_animation(old: Animation) -> Animation:
	var converted := Animation.new()
	converted.resource_name = old.resource_name
	converted.length = old.length
	converted.loop_mode = old.loop_mode
	for index: int in range(old.get_track_count()):
		# Re-baking an already saved scene must preserve native quaternion tracks.
		if old.track_get_type(index) != Animation.TYPE_VALUE:
			old.copy_track(index, converted)
			continue
		var old_path: NodePath = old.track_get_path(index)
		var property: String = old_path.get_subname(0)
		var type: Animation.TrackType = Animation.TYPE_VALUE
		match property:
			"position": type = Animation.TYPE_POSITION_3D
			"rotation": type = Animation.TYPE_ROTATION_3D
			"scale": type = Animation.TYPE_SCALE_3D
		var track: int = converted.add_track(type)
		converted.track_set_path(track, old_path if type == Animation.TYPE_VALUE else NodePath(old_path.get_concatenated_names()))
		converted.track_set_interpolation_type(track, old.track_get_interpolation_type(index))
		converted.track_set_interpolation_loop_wrap(track, false)
		if type == Animation.TYPE_VALUE:
			converted.value_track_set_update_mode(track, old.value_track_get_update_mode(index))
		for key: int in range(old.track_get_key_count(index)):
			var value: Variant = old.track_get_key_value(index, key)
			if type == Animation.TYPE_ROTATION_3D:
				value = Basis.from_euler(value).get_rotation_quaternion()
			converted.track_insert_key(track, old.track_get_key_time(index, key), value, old.track_get_key_transition(index, key))
	return converted
