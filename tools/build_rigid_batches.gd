extends SceneTree
## Offline conversion to editable native scenes. Never bakes animation or meshes.
## Godot --headless --path <project> --script res://tools/build_rigid_batches.gd -- <result.json>
## The source text is retained verbatim except MeshInstance3D -> Node3D and
## moving each external mesh reference into UnitVisual.batch_parts.

const KINDS: PackedStringArray = ["swordsman", "archer", "knight", "catapult", "cannon", "farmer", "spearman", "shield_guard", "war_elephant"]
const OUTPUT := "res://assets/models/units/batched/"
const MANAGER := "res://scenes/unit_render_batches.tscn"
const TOLERANCE := 0.00003
var _checks: int = 0
var _errors: Array[String] = []
var _parts: Array[Dictionary] = []
var _sources: Dictionary = {}
var _max_transform_error: float = 0.0
var _max_socket_error: float = 0.0
var _pose_comparisons: int = 0
var _socket_comparisons: int = 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("Expected a result JSON path followed by optional unit kinds to rebuild")
		quit(2)
		return
	var selected: PackedStringArray = args.slice(1) if args.size() > 1 else KINDS
	for kind: String in selected:
		if kind not in KINDS:
			printerr("Unknown unit kind: ", kind)
			quit(2)
			return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	for kind: String in KINDS:
		# Read all part metadata for the shared manager, but only write the
		# requested model. Existing editor-authored scenes retain their bytes.
		_convert(kind, kind in selected)
	if _errors.is_empty():
		_write(MANAGER, _manager_text())
		for kind: String in KINDS:
			_validate(kind)
	_check(_pose_comparisons >= _parts.size() * 6, "Every rigid part receives nonempty native animation samples")
	var result_file := FileAccess.open(args[0], FileAccess.WRITE)
	_check(result_file != null, "Result file is writable")
	var result := {"godot": Engine.get_version_info().string, "checks": _checks,
		"errors": _errors, "parts": _parts, "sources": _sources,
		"manager": MANAGER, "manager_sha256": FileAccess.get_sha256(MANAGER),
		"max_transform_error": _max_transform_error, "max_socket_error": _max_socket_error,
		"pose_comparisons": _pose_comparisons, "socket_comparisons": _socket_comparisons,
		"tolerance": TOLERANCE,
		"limitations": ["Native clip/transform sampling, not a GPU or FPS test.",
			"Original mesh resources and LODs are referenced unchanged; MultiMesh LOD selection need not match per-instance MeshInstance3D selection.",
			"Batch-wide AABB is conservative; model notifier gates submissions, while fog visibility is an independent strict gate.",
			"Corpse opacity uses opaque screen-door coverage rather than per-GeometryInstance3D transparency."]}
	if result_file != null:
		result_file.store_string(JSON.stringify(result, "\t") + "\n")
		result_file.close()
	print("RIGID_BATCH_RESULT checks=%d errors=%d parts=%d" % [_checks, _errors.size(), _parts.size()])
	quit(0 if _errors.is_empty() else 1)

func _convert(kind: String, write_model: bool = true) -> void:
	var source_path := "res://assets/models/units/%s.tscn" % kind
	var text := FileAccess.get_file_as_string(source_path).replace("\r\n", "\n")
	_sources[kind] = {"path": source_path, "sha256": FileAccess.get_sha256(source_path)}
	var section_pattern := RegEx.create_from_string("(?m)^\\[[^\\n]+\\]")
	var sections: Array[RegExMatch] = section_pattern.search_all(text)
	var mesh_resources: Dictionary = {}
	for section: RegExMatch in sections:
		var header: String = section.get_string()
		if header.begins_with("[ext_resource ") and _attribute(header, "type") == "ArrayMesh":
			mesh_resources[_attribute(header, "id")] = _attribute(header, "path")
	var edits: Array[Dictionary] = []
	var metadata := PackedStringArray()
	var root_end: int = -1
	for index: int in sections.size():
		var section: RegExMatch = sections[index]
		var header: String = section.get_string()
		if not header.begins_with("[node "):
			continue
		if root_end < 0:
			# Script-defined properties must follow the script assignment. Godot
			# cannot apply exported fields before the node has that script.
			var script_start: int = text.find("\nscript = ", section.get_end())
			root_end = text.find("\n", script_start + 1) if script_start >= 0 else -1
		if _attribute(header, "type") != "MeshInstance3D":
			continue
		var end: int = sections[index + 1].get_start() if index + 1 < sections.size() else text.length()
		var block: String = text.substr(section.get_start(), end - section.get_start())
		var mesh_property := RegEx.create_from_string("(?m)^mesh = ExtResource\\(\"([^\"]+)\"\\)\\n")
		var match_mesh: RegExMatch = mesh_property.search(block)
		if not _check(match_mesh != null, kind + " part must use one external mesh"):
			continue
		var resource_id: String = match_mesh.get_string(1)
		if not _check(mesh_resources.has(resource_id), kind + " mesh resource is an original ArrayMesh"):
			continue
		var path: String = _attribute(header, "parent") + "/" + _attribute(header, "name")
		# Refuse to lose renderer-specific authoring if future art adds it.
		for line: String in block.split("\n"):
			if line.is_empty() or line.begins_with("["):
				continue
			var property: String = line.get_slice(" = ", 0)
			_check(property in ["mesh", "transform", "position", "rotation", "rotation_degrees", "scale", "visible", "physics_interpolation_mode", "process_mode", "top_level"], kind + "/" + path + " preserves property " + property)
		var converted: String = block.replace(header, header.replace("type=\"MeshInstance3D\"", "type=\"Node3D\""))
		converted = mesh_property.sub(converted, "")
		edits.append({"start": section.get_start(), "end": end, "text": converted})
		metadata.append("NodePath(%s): ExtResource(%s)" % [JSON.stringify(path), JSON.stringify(resource_id)])
		_parts.append({"kind": kind, "path": path, "mesh": mesh_resources[resource_id],
			"mesh_sha256": FileAccess.get_sha256(mesh_resources[resource_id])})
	_check(root_end >= 0 and not metadata.is_empty(), kind + " has a native root and rigid parts")
	if not _errors.is_empty():
		return
	edits.reverse()
	for edit: Dictionary in edits:
		text = text.substr(0, edit.start) + edit.text + text.substr(edit.end)
	text = text.insert(root_end, "\nbatch_parts = Dictionary[NodePath, Mesh]({\n" + ",\n".join(metadata) + "\n})")
	if write_model:
		_write(OUTPUT + kind + ".tscn", text)

func _manager_text() -> String:
	var resources := PackedStringArray([
		"[gd_scene format=3]", "",
		"[ext_resource type=\"Script\" path=\"res://scripts/unit_render_batches.gd\" id=\"1_script\"]",
		"[ext_resource type=\"Material\" path=\"res://assets/models/units/batched/unit_batch_surface.tres\" id=\"2_material\"]"])
	for index: int in _parts.size():
		resources.append("[ext_resource type=\"ArrayMesh\" path=%s id=\"mesh_%d\"]" % [JSON.stringify(_parts[index].mesh), index])
	resources.append("")
	for index: int in _parts.size():
		resources.append("[sub_resource type=\"MultiMesh\" id=\"batch_%d\"]\nresource_local_to_scene = true\ntransform_format = 1\nuse_custom_data = true\ncustom_aabb = AABB(-128, -8, -128, 256, 32, 256)\nmesh = ExtResource(\"mesh_%d\")\n" % [index, index])
	resources.append("[node name=\"UnitRenderBatches\" type=\"Node3D\"]\nprocess_priority = 1000\nphysics_interpolation_mode = 2\nscript = ExtResource(\"1_script\")\n")
	for index: int in _parts.size():
		var part: Dictionary = _parts[index]
		var node_name: String = part.kind.capitalize() + "_" + String(part.path).replace("/", "_")
		resources.append("[node name=%s type=\"MultiMeshInstance3D\" parent=\".\"]\nphysics_interpolation_mode = 2\nmaterial_override = ExtResource(\"2_material\")\nmultimesh = SubResource(\"batch_%d\")\nmetadata/batch_key = &%s\n" % [JSON.stringify(node_name), index, JSON.stringify(part.kind + "::" + part.path)])
	return "\n".join(resources).strip_edges() + "\n"

func _validate(kind: String) -> void:
	var original: UnitVisual = load("res://assets/models/units/%s.tscn" % kind).instantiate()
	var candidate_scene: PackedScene = ResourceLoader.load(OUTPUT + kind + ".tscn", "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if not _check(candidate_scene != null, kind + " converted native scene reloads"):
		original.free()
		return
	var converted: UnitVisual = candidate_scene.instantiate()
	var part_paths: Array[NodePath] = converted.batch_parts.keys()
	_check(not part_paths.is_empty() and part_paths.size() == original.find_children("*", "MeshInstance3D", true, false).size(), kind + " every original mesh has exported proxy metadata")
	var socket_path: NodePath = original.projectile_socket
	_check(converted.projectile_socket == socket_path, kind + " projectile path unchanged")
	_check(converted.find_children("*", "MeshInstance3D", true, false).is_empty(), kind + " contains no per-part rendering instances")
	for path: NodePath in part_paths:
		var source_mesh: MeshInstance3D = original.get_node(path)
		var proxy: Node3D = converted.get_node(path)
		_check(converted.batch_parts[path] == source_mesh.mesh, kind + "/" + String(path) + " reuses original mesh resource")
		_check(source_mesh.transform.is_equal_approx(proxy.transform) and source_mesh.visible == proxy.visible, kind + "/" + String(path) + " retains authored pose and visibility")
	# Native AnimationPlayer sampling with the original paths. Remove only the
	# presentation script during this isolated data check to avoid random idle
	# starts and rendered-notifier state in a headless conversion process.
	_prepare_sampling(original)
	_prepare_sampling(converted)
	root.add_child(original)
	root.add_child(converted)
	for player_name: String in ["Locomotion", "Attack"]:
		var source_player: AnimationPlayer = original.get_node(player_name)
		var proxy_player: AnimationPlayer = converted.get_node(player_name)
		_check(source_player.get_animation_list() == proxy_player.get_animation_list(), kind + " animation names unchanged")
		for clip_name: StringName in source_player.get_animation_list():
			var clip: Animation = source_player.get_animation(clip_name)
			var copy: Animation = proxy_player.get_animation(clip_name)
			_check(clip.get_track_count() == copy.get_track_count(), kind + " track count unchanged")
			for track: int in clip.get_track_count():
				_check(clip.track_get_path(track) == copy.track_get_path(track) and clip.track_get_type(track) == copy.track_get_type(track), kind + " native track path/type unchanged")
			for fraction: float in [0.0, 0.1, 0.25, 0.5, 0.75, 1.0]:
				source_player.play(clip_name)
				proxy_player.play(clip_name)
				source_player.seek(clip.length * fraction, true)
				proxy_player.seek(copy.length * fraction, true)
				for path: NodePath in part_paths:
					var source_part: Node3D = original.get_node(path)
					var proxy: Node3D = converted.get_node(path)
					var error: float = _transform_error(source_part.global_transform, proxy.global_transform)
					_pose_comparisons += 1
					_max_transform_error = maxf(_max_transform_error, error)
					_check(error <= TOLERANCE and source_part.is_visible_in_tree() == proxy.is_visible_in_tree(), kind + " sampled part pose/visible matches")
				var error: float = _transform_error(original.get_node(socket_path).global_transform, converted.get_node(socket_path).global_transform)
				_socket_comparisons += 1
				_max_socket_error = maxf(_max_socket_error, error)
				_check(error <= TOLERANCE, kind + " sampled release socket matches")
	original.free()
	converted.free()

func _prepare_sampling(model: Node3D) -> void:
	var notifier: VisibleOnScreenNotifier3D = model.get_node("VisibilityNotifier")
	for signal_name: StringName in [&"screen_entered", &"screen_exited"]:
		for connection: Dictionary in notifier.get_signal_connection_list(signal_name):
			notifier.disconnect(signal_name, connection.callable)
	model.set_script(null)
	for player_name: String in ["Locomotion", "Attack"]:
		var player: AnimationPlayer = model.get_node(player_name)
		player.autoplay = ""
		player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL

func _transform_error(a: Transform3D, b: Transform3D) -> float:
	return maxf(a.origin.distance_to(b.origin), maxf(a.basis.x.distance_to(b.basis.x), maxf(a.basis.y.distance_to(b.basis.y), a.basis.z.distance_to(b.basis.z))))

func _attribute(header: String, name: String) -> String:
	var match_attribute: RegExMatch = RegEx.create_from_string("\\b" + name + "=\"([^\"]+)\"").search(header)
	return "" if match_attribute == null else match_attribute.get_string(1)

func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if _check(file != null, "Writable output: " + path):
		file.store_string(content)
		file.close()

func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_errors.append(message)
	return condition
