extends SceneTree
## Offline rigid-part -> native skeletal mesh conversion. Original art stays intact.
## Godot --headless --path <project> --script res://tools/build_rigid_skin.gd -- <result.json> [unit_kind]
## Visible tool/projectile props remain explicit native attachments.

var _kind: String = "swordsman"
var _source: String
var _output: String
var _mesh_output: String
var _socket_path: String
var _props: Dictionary = {}
const POSITION_TOLERANCE := 0.00003
const NORMAL_TOLERANCE := 0.001

var _checks: int = 0
var _errors: Array[String] = []
var _bone_for_path: Dictionary = {}
var _source_nodes: Array[Node3D] = []
var _source_meshes: Array[MeshInstance3D] = []
var _segments: Array[Dictionary] = []
var _max_position_error: float = 0.0
var _max_normal_error: float = 0.0
var _max_socket_error: float = 0.0
var _sample_count: int = 0
var _vertex_comparisons: int = 0
var _lod_summary: Array[Dictionary] = []
var _lod_index_checks: int = 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 1 or args.size() > 2:
		printerr("Expected an absolute result JSON path and optional unit kind.")
		quit(2)
		return
	if args.size() == 2:
		_kind = args[1]
	if _kind not in ["swordsman", "archer", "knight", "catapult", "cannon", "farmer"]:
		printerr("Unknown unit kind: " + _kind)
		quit(2)
		return
	_source = "res://assets/models/units/%s.tscn" % _kind
	_output = "res://assets/models/units/skinned/%s.tscn" % _kind
	_mesh_output = "res://assets/models/units/skinned/%s_mesh.res" % _kind
	var original: Node3D = load(_source).instantiate()
	_socket_path = String(original.get("projectile_socket"))
	_collect_props(original)
	_prepare_for_sampling(original)
	root.add_child(original)
	_collect_bones(original.get_node("Rig"), original)
	var converted: Node3D = _convert(original)
	_prepare_for_sampling(converted)
	root.add_child(converted)
	_validate(original, converted)
	# Save only after complete geometry/animation validation. Runtime selection
	# remains an independent experimental integration choice.
	if _errors.is_empty():
		root.remove_child(converted)
		_restore_runtime(converted)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_output.get_base_dir()))
		var mesh: ArrayMesh = converted.get_node("Rig/SkinnedMesh").mesh
		_check(ResourceSaver.save(mesh, _mesh_output) == OK, "Mesh resource saves")
		mesh.take_over_path(_mesh_output)
		# Packing after the mesh receives its resource path preserves external reuse.
		var packed := PackedScene.new()
		_check(packed.pack(converted) == OK, "Native scene packs external mesh")
		_check(ResourceSaver.save(packed, _output) == OK, "Editable scene saves")
		_validate_reload(original)
	var report := {
		"source": _source, "output": _output,
		"godot": Engine.get_version_info().string,
		"checks": _checks, "errors": _errors,
		"source_nodes": _count_nodes(original), "converted_nodes": _count_nodes(converted),
		"source_meshes": _source_meshes.size(), "converted_meshes": 1 + _props.size(), "visible_props": _props.keys(),
		"bones": _source_nodes.size(), "surfaces": converted.get_node("Rig/SkinnedMesh").mesh.get_surface_count(),
		"samples": _sample_count, "vertex_comparisons": _vertex_comparisons,
		"max_world_position_error": _max_position_error,
		"max_world_normal_error": _max_normal_error,
		"max_socket_error": _max_socket_error,
		"position_tolerance": POSITION_TOLERANCE, "normal_tolerance": NORMAL_TOLERANCE,
		"lod_levels": _lod_summary, "lod_index_checks": _lod_index_checks,
		"lod_scope": "Authored per-part LOD indices and scale-adjusted thresholds; equivalent for the game's orthographic views. Perspective per-part AABB distances are not identical after merging.",
		"note": "CPU skin equation using Godot sampled bone poses; not a rendered GPU or FPS benchmark."
	}
	var output := FileAccess.open(args[0], FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t") + "\n")
	output.close()
	print("RIGID_SKIN_RESULT " + JSON.stringify(report))
	original.free()
	converted.free()
	quit(0 if _errors.is_empty() else 1)

func _prepare_for_sampling(model: Node3D) -> void:
	# Pure authored data, with no UnitVisual ready/random/culling side effects.
	var notifier: VisibleOnScreenNotifier3D = model.get_node("VisibilityNotifier")
	for signal_name: StringName in [&"screen_entered", &"screen_exited"]:
		for connection: Dictionary in notifier.get_signal_connection_list(signal_name):
			notifier.disconnect(signal_name, connection.callable)
	model.set_script(null)
	model.process_mode = Node.PROCESS_MODE_DISABLED
	for player_name: String in ["Locomotion", "Attack"]:
		var player: AnimationPlayer = model.get_node(player_name)
		player.autoplay = ""
		player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL

func _collect_props(original: Node3D) -> void:
	for player_name: String in ["Locomotion", "Attack"]:
		var player: AnimationPlayer = original.get_node(player_name)
		for clip_name: StringName in player.get_animation_list():
			var clip: Animation = player.get_animation(clip_name)
			for track: int in clip.get_track_count():
				if clip.track_get_type(track) != Animation.TYPE_VALUE:
					continue
				var path: NodePath = clip.track_get_path(track)
				_check(path.get_subname_count() == 1 and path.get_subname(0) == &"visible", "Value tracks only control native prop visibility")
				var node_path: String = path.get_concatenated_names()
				var prop: MeshInstance3D = original.get_node(node_path)
				_check(prop.get_child_count() == 0, "Visible prop is a leaf mesh: " + node_path)
				_props[node_path] = {"original": prop, "visible": prop.visible}

func _prop_path(source_path: String) -> NodePath:
	return NodePath("Rig/Skeleton3D/Prop_" + String(_bone_name(source_path)) + "/Mesh")

func _collect_bones(node: Node3D, original: Node3D) -> void:
	var path: String = String(original.get_path_to(node))
	_bone_for_path[path] = _source_nodes.size()
	_source_nodes.append(node)
	if node is MeshInstance3D:
		_source_meshes.append(node)
	for child: Node in node.get_children():
		if child is Node3D:
			_collect_bones(child, original)

func _add_owned(parent: Node, node: Node, model: Node3D) -> void:
	parent.add_child(node)
	node.owner = model

func _bone_name(path: String) -> StringName:
	return StringName(path.replace("/", "__"))

func _convert(original: Node3D) -> Node3D:
	var model := Node3D.new()
	model.name = _kind.capitalize() + "Skinned"
	var rig := Node3D.new()
	rig.name = "Rig"
	_add_owned(model, rig, model)
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	_add_owned(rig, skeleton, model)
	for index: int in _source_nodes.size():
		var source_node: Node3D = _source_nodes[index]
		var path: String = String(original.get_path_to(source_node))
		skeleton.add_bone(_bone_name(path))
		if index > 0:
			skeleton.set_bone_parent(index, int(_bone_for_path[String(original.get_path_to(source_node.get_parent()))]))
		skeleton.set_bone_rest(index, source_node.transform)
		skeleton.set_bone_pose(index, source_node.transform)
	var combined := MeshInstance3D.new()
	combined.name = "SkinnedMesh"
	combined.mesh = _combine_meshes(original, skeleton)
	combined.skin = skeleton.create_skin_from_rest_transforms()
	combined.skeleton = NodePath("../Skeleton3D")
	_add_owned(rig, combined, model)
	# This attachment is visible/editable in the authored native scene. Gameplay
	# reads Skeleton.get_bone_global_pose directly to avoid deferred attachment lag.
	var attachment := BoneAttachment3D.new()
	attachment.name = "ProjectileSocket"
	attachment.bone_name = _bone_name(_socket_path)
	attachment.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_add_owned(skeleton, attachment, model)
	for source_path: String in _props:
		var prop_attachment := BoneAttachment3D.new()
		prop_attachment.name = "Prop_" + String(_bone_name(source_path))
		prop_attachment.bone_name = _bone_name(source_path)
		# SkeletonModifier already produces render-time poses. Node3D must not
		# interpolate this attachment a second time.
		prop_attachment.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_add_owned(skeleton, prop_attachment, model)
		var prop: MeshInstance3D = _props[source_path].original.duplicate()
		prop.name = "Mesh"
		prop.transform = Transform3D.IDENTITY
		_add_owned(prop_attachment, prop, model)
	for player_name: String in ["Locomotion", "Attack"]:
		var source_player: AnimationPlayer = original.get_node(player_name)
		var player := AnimationPlayer.new()
		player.name = player_name
		player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		for library_name: StringName in source_player.get_animation_library_list():
			var source_library: AnimationLibrary = source_player.get_animation_library(library_name)
			var library := AnimationLibrary.new()
			for animation_name: StringName in source_library.get_animation_list():
				var animation: Animation = source_library.get_animation(animation_name).duplicate()
				for track: int in animation.get_track_count():
					if animation.track_get_type(track) == Animation.TYPE_VALUE:
						var property_path: NodePath = animation.track_get_path(track)
						animation.track_set_path(track, NodePath(String(_prop_path(property_path.get_concatenated_names())) + ":visible"))
						continue
					var path: String = String(animation.track_get_path(track))
					_check(_bone_for_path.has(path), "Transform track has rigid bone: " + path)
					animation.track_set_path(track, NodePath("Rig/Skeleton3D:" + String(_bone_name(path))))
				library.add_animation(animation_name, animation)
			player.add_animation_library(library_name, library)
		_add_owned(model, player, model)
	var notifier := VisibleOnScreenNotifier3D.new()
	notifier.name = "VisibilityNotifier"
	notifier.aabb = original.get_node("VisibilityNotifier").aabb
	_add_owned(model, notifier, model)
	_install_interpolator(model)
	return model

func _install_interpolator(model: Node3D) -> void:
	var animated_bones: Dictionary = {}
	for player_name: String in ["Locomotion", "Attack"]:
		var player: AnimationPlayer = model.get_node(player_name)
		for clip_name: StringName in player.get_animation_list():
			var clip: Animation = player.get_animation(clip_name)
			for track: int in clip.get_track_count():
				if clip.track_get_type(track) != Animation.TYPE_VALUE:
					animated_bones[String(clip.track_get_path(track).get_subname(0))] = true
	var tracked := PackedStringArray()
	var skeleton: Skeleton3D = model.get_node("Rig/Skeleton3D")
	for bone: int in skeleton.get_bone_count():
		var bone_name: String = skeleton.get_bone_name(bone)
		if animated_bones.has(bone_name):
			tracked.append(bone_name)
	var modifier := SkeletonModifier3D.new()
	modifier.name = "PoseInterpolation"
	modifier.set_script(load("res://scripts/rigid_skin_interpolator.gd"))
	modifier.set("tracked_bones", tracked)
	_add_owned(skeleton, modifier, model)

func _combine_meshes(original: Node3D, skeleton: Skeleton3D) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var tangents := PackedFloat32Array()
	var indices := PackedInt32Array()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	var material: Material
	var source_format: int = -1
	for part: MeshInstance3D in _source_meshes:
		if _props.has(String(original.get_path_to(part))):
			continue
		var bone_index: int = _bone_for_path[String(original.get_path_to(part))]
		var bind: Transform3D = skeleton.get_bone_global_rest(bone_index)
		var normal_basis: Basis = bind.basis.inverse().transposed()
		# ArrayMesh.surface_get_arrays() omits LODs. ImporterMesh exposes the
		# native source LOD tables without depending on private serialized fields.
		var imported: ImporterMesh = ImporterMesh.from_mesh(part.mesh)
		_check(part.mesh.get_blend_shape_count() == 0, "No original blend shapes")
		for surface: int in part.mesh.get_surface_count():
			var arrays: Array = part.mesh.surface_get_arrays(surface)
			var format: int = part.mesh.surface_get_format(surface) & ((1 << Mesh.ARRAY_MAX) - 1)
			if source_format < 0:
				source_format = format
				material = part.get_active_material(surface)
			_check(format == source_format, "Compatible vertex layout for single surface")
			_check(part.get_active_material(surface) == material, "Shared material preserved")
			_check(part.mesh.surface_get_primitive_type(surface) == Mesh.PRIMITIVE_TRIANGLES, "Triangle primitive preserved")
			for slot: int in [Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3, Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS]:
				_check(arrays[slot] == null, "Unsupported input vertex channel absent: %d" % slot)
			var source_vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var source_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var source_colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
			var offset: int = vertices.size()
			var source_indices: PackedInt32Array = _base_indices(arrays)
			var lods: Dictionary = _read_lods(imported, surface)
			var lod_scale: float = _max_axis_scale(bind.basis) * part.lod_bias
			_segments.append({"part": part, "surface": surface, "start": offset, "count": source_vertices.size(), "bone": bone_index,
				"indices": source_indices, "lods": lods, "lod_scale": lod_scale})
			for vertex: int in source_vertices.size():
				vertices.append(bind * source_vertices[vertex])
				normals.append((normal_basis * source_normals[vertex]).normalized())
				colors.append(source_colors[vertex])
				bones.append_array(PackedInt32Array([bone_index, 0, 0, 0]))
				weights.append_array(PackedFloat32Array([1.0, 0.0, 0.0, 0.0]))
			if arrays[Mesh.ARRAY_TEX_UV] != null:
				uvs.append_array(arrays[Mesh.ARRAY_TEX_UV])
			if arrays[Mesh.ARRAY_TANGENT] != null:
				var source_tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
				for vertex: int in source_vertices.size():
					var tangent := Vector3(source_tangents[vertex * 4], source_tangents[vertex * 4 + 1], source_tangents[vertex * 4 + 2])
					tangent = (bind.basis * tangent).normalized()
					tangents.append_array(PackedFloat32Array([tangent.x, tangent.y, tangent.z, source_tangents[vertex * 4 + 3]]))
			if arrays[Mesh.ARRAY_INDEX] == null:
				for vertex: int in source_vertices.size():
					indices.append(offset + vertex)
			else:
				for vertex: int in arrays[Mesh.ARRAY_INDEX]:
					indices.append(offset + vertex)
	var merged: Array = []
	merged.resize(Mesh.ARRAY_MAX)
	merged[Mesh.ARRAY_VERTEX] = vertices
	merged[Mesh.ARRAY_NORMAL] = normals
	merged[Mesh.ARRAY_COLOR] = colors
	merged[Mesh.ARRAY_BONES] = bones
	merged[Mesh.ARRAY_WEIGHTS] = weights
	merged[Mesh.ARRAY_INDEX] = indices
	if not uvs.is_empty():
		merged[Mesh.ARRAY_TEX_UV] = uvs
	if not tangents.is_empty():
		merged[Mesh.ARRAY_TANGENT] = tangents
	var mesh := ArrayMesh.new()
	mesh.resource_name = _kind.capitalize() + "RigidSkin"
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, merged, [], _merge_lods())
	mesh.surface_set_material(0, material)
	return mesh

func _base_indices(arrays: Array) -> PackedInt32Array:
	if arrays[Mesh.ARRAY_INDEX] != null:
		return arrays[Mesh.ARRAY_INDEX]
	var result := PackedInt32Array()
	result.resize(arrays[Mesh.ARRAY_VERTEX].size())
	for vertex: int in result.size():
		result[vertex] = vertex
	return result

func _read_lods(imported: ImporterMesh, surface: int) -> Dictionary:
	var result: Dictionary = {}
	for level: int in imported.get_surface_lod_count(surface):
		result[imported.get_surface_lod_size(surface, level)] = imported.get_surface_lod_indices(surface, level)
	return result

func _max_axis_scale(basis: Basis) -> float:
	return maxf(basis.x.length(), maxf(basis.y.length(), basis.z.length()))

func _scaled_lod_edge(edge: float, scale: float) -> float:
	# RenderingServer stores edge_length as float32. Normalize here too so a
	# boundary cannot silently change when the resource is saved/reloaded.
	return PackedFloat32Array([edge * scale])[0]

func _segment_indices(segment: Dictionary, budget: float) -> PackedInt32Array:
	var chosen: PackedInt32Array = segment.indices
	var edges: Array = segment.lods.keys()
	edges.sort()
	for edge: float in edges:
		if _scaled_lod_edge(edge, segment.lod_scale) > budget:
			break
		chosen = segment.lods[edge]
	return chosen

func _merge_lods() -> Dictionary:
	# Native Forward+ uses edge * max_axis_scale * lod_bias / distance. For
	# orthographic views distance is 1, so all parts share the same budget.
	# Preserve every distinct transition; never choose an LOD by ordinal.
	var transitions: Dictionary = {}
	for segment: Dictionary in _segments:
		_check(segment.lod_scale > 0.0, "Positive LOD model scale/bias")
		for edge: float in segment.lods:
			transitions[_scaled_lod_edge(edge, segment.lod_scale)] = true
	var edges: Array = transitions.keys()
	edges.sort()
	var merged: Dictionary = {}
	_lod_summary.clear()
	for edge: float in edges:
		var indices := PackedInt32Array()
		var parts: Array[Dictionary] = []
		for segment: Dictionary in _segments:
			var source_indices: PackedInt32Array = _segment_indices(segment, edge)
			parts.append({"bone": segment.bone, "triangles": source_indices.size() / 3})
			for index: int in source_indices:
				indices.append(segment.start + index)
		merged[edge] = indices
		_lod_summary.append({"edge": edge, "indices": indices.size(), "triangles": indices.size() / 3, "parts": parts})
	return merged

func _validate_lods(combined: MeshInstance3D) -> void:
	var imported: ImporterMesh = ImporterMesh.from_mesh(combined.mesh)
	var actual: Dictionary = _read_lods(imported, 0)
	_check(actual.size() == _lod_summary.size(), "All merged LOD transitions survive native upload/save")
	var arrays: Array = combined.mesh.surface_get_arrays(0)
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	for level: Dictionary in _lod_summary:
		_check(actual.has(level.edge), "Exact float32 LOD threshold preserved")
		if not actual.has(level.edge):
			continue
		var indices: PackedInt32Array = actual[level.edge]
		_check(indices.size() == level.indices and indices.size() % 3 == 0, "LOD index/triangle count preserved")
		var cursor: int = 0
		for segment: Dictionary in _segments:
			_check(segment.part.get_active_material(segment.surface).resource_path == combined.mesh.surface_get_material(0).resource_path, "LOD material preserved")
			var source_indices: PackedInt32Array = _segment_indices(segment, level.edge)
			for source_index: int in source_indices:
				var expected: int = segment.start + source_index
				_check(source_index >= 0 and source_index < segment.count, "Source LOD remains within its own rigid part")
				_check(cursor < indices.size() and indices[cursor] == expected, "LOD winding/index equals authored source plus offset")
				_check(bones[expected * 4] == segment.bone, "LOD vertex retains original bone ownership")
				_lod_index_checks += 1
				cursor += 1
		_check(cursor == indices.size(), "LOD has no additional or missing part")
	# Exercise the native screen-error comparison at midpoints and on both
	# sides of every transition, including uniform root scale changes. This
	# checks the selection independently from the merged index constructor.
	var budgets: Array[float] = [0.0]
	var previous: float = 0.0
	for level: Dictionary in _lod_summary:
		budgets.append((previous + level.edge) * 0.5)
		budgets.append(level.edge)
		previous = level.edge
	budgets.append(previous * 2.0)
	var merged_edges: Array = actual.keys()
	merged_edges.sort()
	for root_scale: float in [0.5, 1.0, 1.7]:
		for budget: float in budgets:
			var expected_count: int = 0
			for segment: Dictionary in _segments:
				var count: int = segment.indices.size()
				var source_edges: Array = segment.lods.keys()
				source_edges.sort()
				for edge: float in source_edges:
					if _scaled_lod_edge(edge, segment.lod_scale) * root_scale > budget * root_scale:
						break
					count = segment.lods[edge].size()
				expected_count += count
			var actual_count: int = arrays[Mesh.ARRAY_INDEX].size()
			for edge: float in merged_edges:
				if edge * root_scale > budget * root_scale:
					break
				actual_count = actual[edge].size()
			_check(actual_count == expected_count, "Orthographic LOD selection matches all separate parts")

func _restore_pose(original: Node3D, converted: Node3D, original_transforms: Array[Transform3D]) -> void:
	for model: Node3D in [original, converted]:
		for player_name: String in ["Locomotion", "Attack"]:
			model.get_node(player_name).stop()
	var skeleton: Skeleton3D = converted.get_node("Rig/Skeleton3D")
	for index: int in _source_nodes.size():
		_source_nodes[index].transform = original_transforms[index]
		skeleton.set_bone_pose(index, skeleton.get_bone_rest(index))
	for source_path: String in _props:
		_props[source_path].original.visible = _props[source_path].visible
		converted.get_node(_prop_path(source_path)).visible = _props[source_path].visible

func _sample(model: Node3D, locomotion_name: String, locomotion_time: float, attack_time: float, attack_name: String = "strike") -> void:
	var locomotion: AnimationPlayer = model.get_node("Locomotion")
	locomotion.play(locomotion_name)
	locomotion.seek(locomotion_time, true, true)
	if attack_time >= 0.0:
		var attack: AnimationPlayer = model.get_node("Attack")
		attack.play(attack_name)
		attack.seek(attack_time, true, true)

func _validate(original: Node3D, converted: Node3D) -> void:
	var transforms: Array[Transform3D] = []
	for node: Node3D in _source_nodes:
		transforms.append(node.transform)
	var cases: Array[Dictionary] = []
	_validate_channels(converted)
	_validate_lod_animation_domain(original)
	for locomotion: String in ["idle", "walk"]:
		var clip: Animation = original.get_node("Locomotion").get_animation(locomotion)
		for step: int in 13:
			cases.append({"locomotion": locomotion, "phase": clip.length * step / 13.0, "strike": -1.0})
		for phase: float in [0.0, 0.075, 0.15, 0.195, 0.20, 0.22, 0.235, 0.26, 0.35, 0.51, 0.69, 0.85]:
			cases.append({"locomotion": locomotion, "phase": 0.17, "strike": phase})
	# Additional authored work clips and exact visibility transition boundaries.
	var attack_player: AnimationPlayer = original.get_node("Attack")
	for clip_name: StringName in attack_player.get_animation_list():
		var clip: Animation = attack_player.get_animation(clip_name)
		var phases: Dictionary = {}
		if clip_name != &"strike":
			for step: int in 13:
				phases[clip.length * step / 13.0] = true
		for track: int in clip.get_track_count():
			if clip.track_get_type(track) == Animation.TYPE_VALUE:
				for key: int in clip.track_get_key_count(track):
					var key_time: float = clip.track_get_key_time(track, key)
					for offset: float in [-0.002, 0.0, 0.002]:
						phases[clampf(key_time + offset, 0.0, clip.length)] = true
		for phase: float in phases:
			cases.append({"locomotion": "idle", "phase": 0.17, "strike": phase, "clip": String(clip_name)})
	# Non-identity parent transform checks the actual world-space equation too.
	var placement := Transform3D(Basis(Vector3.UP, 0.73), Vector3(17.0, 0.0, -9.0))
	original.transform = placement
	converted.transform = placement
	for sample: Dictionary in cases:
		_restore_pose(original, converted, transforms)
		_sample(original, sample.locomotion, sample.phase, sample.strike, sample.get("clip", "strike"))
		_sample(converted, sample.locomotion, sample.phase, sample.strike, sample.get("clip", "strike"))
		_compare_pose(original, converted)
	# Continuous native crossfades must agree too, not just isolated key poses.
	_restore_pose(original, converted, transforms)
	for model: Node3D in [original, converted]:
		model.get_node("Locomotion").play("walk")
	for tick: int in 32:
		for model: Node3D in [original, converted]:
			var locomotion: AnimationPlayer = model.get_node("Locomotion")
			var attack: AnimationPlayer = model.get_node("Attack")
			if tick == 6:
				attack.play("strike")
			if tick == 12:
				locomotion.play("idle", 0.16)
			if tick == 22:
				locomotion.play("walk", 0.16)
			locomotion.advance(1.0 / 30.0)
			attack.advance(1.0 / 30.0)
		_compare_pose(original, converted)
	_restore_pose(original, converted, transforms)
	original.transform = Transform3D.IDENTITY
	converted.transform = Transform3D.IDENTITY
	_check(_max_position_error <= POSITION_TOLERANCE, "All sampled world vertices match")
	_check(_max_normal_error <= NORMAL_TOLERANCE, "All sampled normals match")
	_check(_max_socket_error <= POSITION_TOLERANCE, "Same-tick projectile socket matches")

func _validate_channels(converted: Node3D) -> void:
	var combined: MeshInstance3D = converted.get_node("Rig/SkinnedMesh")
	var arrays: Array = combined.mesh.surface_get_arrays(0)
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	_check(combined.skin.get_bind_count() == _source_nodes.size(), "Complete native Skin bind table")
	for bone: int in _source_nodes.size():
		_check(combined.skin.get_bind_bone(bone) == bone, "Vertex indices address the matching Skin bind")
	var cursor: int = 0
	for segment: Dictionary in _segments:
		var source: Array = segment.part.mesh.surface_get_arrays(segment.surface)
		for vertex: int in segment.count:
			var offset: int = (segment.start + vertex) * 4
			_check(bones[offset] == int(segment.bone) and weights[offset] == 1.0, "Rigid vertex weight preserved")
			_check(weights[offset + 1] == 0.0 and weights[offset + 2] == 0.0 and weights[offset + 3] == 0.0, "No cross-part deformation weights")
			if source[Mesh.ARRAY_TEX_UV] != null:
				_check(source[Mesh.ARRAY_TEX_UV][vertex].is_equal_approx(arrays[Mesh.ARRAY_TEX_UV][segment.start + vertex]), "UV channel preserved")
		if source[Mesh.ARRAY_INDEX] == null:
			for vertex: int in segment.count:
				_check(indices[cursor] == vertex + int(segment.start), "Unindexed triangle winding preserved")
				cursor += 1
		else:
			for index: int in source[Mesh.ARRAY_INDEX]:
				_check(indices[cursor] == index + int(segment.start), "Triangle winding/index preserved")
				cursor += 1
	_check(cursor == indices.size(), "No additional or dropped triangles")
	_check(combined.mesh.surface_get_material(0).resource_path == _source_meshes[0].get_active_material(0).resource_path, "Native shared material path preserved after save")
	_validate_lods(combined)

func _validate_lod_animation_domain(original: Node3D) -> void:
	# A single surface has one native LOD scale. Refuse newly authored dynamic
	# scale on a LOD-bearing part rather than pretend fixed thresholds match it.
	# Current bow strings have scale tracks but no LODs and remain valid.
	for player_name: String in ["Locomotion", "Attack"]:
		var player: AnimationPlayer = original.get_node(player_name)
		for clip_name: StringName in player.get_animation_list():
			var clip: Animation = player.get_animation(clip_name)
			for track: int in clip.get_track_count():
				if clip.track_get_type(track) != Animation.TYPE_SCALE_3D:
					continue
				var scaled_path: String = String(clip.track_get_path(track))
				for segment: Dictionary in _segments:
					if segment.lods.is_empty():
						continue
					var part_path: String = String(original.get_path_to(segment.part))
					_check(part_path != scaled_path and not part_path.begins_with(scaled_path + "/"), "Animated scale does not change a LOD-bearing part's threshold")

func _compare_pose(original: Node3D, converted: Node3D) -> void:
	_sample_count += 1
	var skeleton: Skeleton3D = converted.get_node("Rig/Skeleton3D")
	var combined: MeshInstance3D = converted.get_node("Rig/SkinnedMesh")
	var merged: Array = combined.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = merged[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = merged[Mesh.ARRAY_NORMAL]
	var colors: PackedColorArray = merged[Mesh.ARRAY_COLOR]
	for segment: Dictionary in _segments:
		var part: MeshInstance3D = segment.part
		if not segment.lods.is_empty():
			var relative_scale: float = _max_axis_scale(part.global_basis) * part.lod_bias / _max_axis_scale(combined.global_basis)
			_check(absf(relative_scale - float(segment.lod_scale)) < 0.00005, "Sampled part LOD scale remains equivalent after merge")
		var arrays: Array = part.mesh.surface_get_arrays(segment.surface)
		var source_vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var source_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var source_colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var pose: Transform3D = skeleton.get_bone_global_pose(segment.bone)
		var skin_pose: Transform3D = skeleton.global_transform * pose * combined.skin.get_bind_pose(segment.bone)
		var normal_basis: Basis = skin_pose.basis.inverse().transposed()
		var source_normal_basis: Basis = part.global_basis.inverse().transposed()
		for vertex: int in segment.count:
			var index: int = segment.start + vertex
			_max_position_error = maxf(_max_position_error, (part.global_transform * source_vertices[vertex]).distance_to(skin_pose * vertices[index]))
			_max_normal_error = maxf(_max_normal_error, (source_normal_basis * source_normals[vertex]).normalized().distance_to((normal_basis * normals[index]).normalized()))
			_check(source_colors[vertex] == colors[index], "Vertex material/color preserved")
			_vertex_comparisons += 1
	# Force the native final-pose notification: BoneAttachment3D must update the
	# retained visible prop, not merely agree with a hand-computed expected pose.
	skeleton.advance(0.0)
	skeleton.notification(Skeleton3D.NOTIFICATION_UPDATE_SKELETON)
	for source_path: String in _props:
		var source_prop: MeshInstance3D = _props[source_path].original
		var retained_prop: MeshInstance3D = converted.get_node(_prop_path(source_path))
		_check(retained_prop.visible == source_prop.visible, "Native prop visibility preserved: " + source_path)
		_check(retained_prop.mesh.resource_path == source_prop.mesh.resource_path, "Native prop mesh resource preserved: " + source_path)
		for surface: int in source_prop.mesh.get_surface_count():
			var arrays: Array = source_prop.mesh.surface_get_arrays(surface)
			var prop_vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var prop_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var source_basis: Basis = source_prop.global_basis.inverse().transposed()
			var retained_basis: Basis = retained_prop.global_basis.inverse().transposed()
			for vertex: int in prop_vertices.size():
				_max_position_error = maxf(_max_position_error, (source_prop.global_transform * prop_vertices[vertex]).distance_to(retained_prop.global_transform * prop_vertices[vertex]))
				_max_normal_error = maxf(_max_normal_error, (source_basis * prop_normals[vertex]).normalized().distance_to((retained_basis * prop_normals[vertex]).normalized()))
				_vertex_comparisons += 1
	var socket_bone: int = _bone_for_path[_socket_path]
	var socket: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(socket_bone).origin
	_max_socket_error = maxf(_max_socket_error, original.get_node(_socket_path).global_position.distance_to(socket))

func _restore_runtime(model: Node3D) -> void:
	model.process_mode = Node.PROCESS_MODE_INHERIT
	model.set_script(load("res://scripts/unit_visual.gd"))
	model.set("kind", _kind)
	model.set("projectile_socket", NodePath("Rig/Skeleton3D/ProjectileSocket"))
	model.set("rigid_skin_skeleton", NodePath("Rig/Skeleton3D"))
	model.set("rigid_skin_socket_bone", _bone_name(_socket_path))
	for player_name: String in ["Locomotion", "Attack"]:
		model.get_node(player_name).callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
	model.get_node("Locomotion").autoplay = &"idle"
	model.get_node("VisibilityNotifier").connect("screen_entered", Callable(model, "_on_screen_entered"), Object.CONNECT_PERSIST)
	model.get_node("VisibilityNotifier").connect("screen_exited", Callable(model, "_on_screen_exited"), Object.CONNECT_PERSIST)

func _validate_reload(original: Node3D) -> void:
	var reloaded: Node3D = ResourceLoader.load(_output, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP).instantiate()
	_check(reloaded.get("rigid_skin_skeleton") == NodePath("Rig/Skeleton3D"), "Explicit skeleton path persists")
	_check(reloaded.get("rigid_skin_socket_bone") == _bone_name(_socket_path), "Explicit socket bone persists")
	_prepare_for_sampling(reloaded)
	root.add_child(reloaded)
	_validate(original, reloaded)
	reloaded.free()

func _count_nodes(node: Node) -> int:
	var result: int = 1
	for child: Node in node.get_children():
		result += _count_nodes(child)
	return result

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_errors.append(message)
		printerr("RIGID_SKIN_CHECK_FAILED: " + message)
