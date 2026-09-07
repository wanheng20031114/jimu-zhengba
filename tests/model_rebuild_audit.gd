extends SceneTree
## Read-only checks against a fresh, temporary offline model authoring output.
const BAKER = preload("res://assets/models/units/bake_native_meshes.gd")
var failures: Array[String] = []
var checks: int = 0
var scenes: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error(label)

func same_value(a: Variant, b: Variant) -> bool:
	if a is Vector3:
		return a.distance_to(b) < .00002
	if a is Quaternion:
		return absf(absf(a.dot(b)) - 1.0) < .000002
	if a is float:
		return absf(a - b) < .00002
	return a == b

func compare_animations(a: Animation, b: Animation) -> bool:
	if a.length != b.length or a.loop_mode != b.loop_mode or a.get_track_count() != b.get_track_count():
		return false
	for track: int in range(a.get_track_count()):
		if a.track_get_type(track) != b.track_get_type(track) or a.track_get_path(track) != b.track_get_path(track):
			return false
		if a.track_get_key_count(track) != b.track_get_key_count(track):
			return false
		if a.track_get_interpolation_type(track) != b.track_get_interpolation_type(track):
			return false
		if a.track_get_interpolation_loop_wrap(track) != b.track_get_interpolation_loop_wrap(track):
			return false
		for key: int in range(a.track_get_key_count(track)):
			if not is_equal_approx(a.track_get_key_time(track, key), b.track_get_key_time(track, key)):
				return false
			if not is_equal_approx(a.track_get_key_transition(track, key), b.track_get_key_transition(track, key)):
				return false
			if not same_value(a.track_get_key_value(track, key), b.track_get_key_value(track, key)):
				return false
	return true

func _run() -> void:
	create_timer(25.0, true, false, true).timeout.connect(func(): quit(3))
	var temporary: String = OS.get_cmdline_user_args()[0].replace("\\", "/")
	for kind: String in ["swordsman", "archer", "knight", "catapult", "cannon"]:
		var saved: Node3D = load("res://assets/models/units/" + kind + ".tscn").instantiate()
		var source: Node3D = load(temporary + "/" + kind + ".tscn").instantiate()
		var nodes: Array[Node] = source.find_children("*", "Node", true, false)
		check(nodes.size() == saved.find_children("*", "Node", true, false).size(), kind + " node count")
		var mesh_count: int = 0
		var triangles: int = 0
		for node: Node in nodes:
			var path: NodePath = source.get_path_to(node)
			check(saved.has_node(path), kind + " saved node: " + str(path))
			var actual: Node = saved.get_node(path)
			check(actual.get_class() == node.get_class(), kind + " node type: " + str(path))
			if node is Node3D:
				check(node.transform.is_equal_approx(actual.transform), kind + " authored rest: " + str(path))
			if node is MeshInstance3D:
				mesh_count += 1
				check(actual.mesh is ArrayMesh and actual.mesh.get_surface_count() == 1, kind + " one native surface: " + node.name)
				check(actual.mesh.surface_get_material(0).resource_path == "res://assets/models/units/unit_surface.tres", kind + " shared shader: " + node.name)
				var imported: Node3D = load("res://assets/models/units/" + kind + "/" + node.name + ".glb").instantiate()
				var geometry: MeshInstance3D = imported.find_children("*", "MeshInstance3D", true, false)[0]
				check(actual.mesh.surface_get_arrays(0) == geometry.mesh.surface_get_arrays(0), kind + " saved native geometry matches source: " + node.name)
				triangles += actual.mesh.surface_get_array_index_len(0) / 3
				imported.free()
		check(source.projectile_socket == saved.projectile_socket and saved.has_node(saved.projectile_socket), kind + " weapon socket")
		var track_count: int = 0
		for player_name: String in ["Locomotion", "Attack"]:
			var expected_player: AnimationPlayer = source.get_node(player_name)
			var actual_player: AnimationPlayer = saved.get_node(player_name)
			for animation_name: StringName in expected_player.get_animation_list():
				var authored: Animation = BAKER.convert_animation(expected_player.get_animation(animation_name))
				var native: Animation = actual_player.get_animation(animation_name)
				track_count += native.get_track_count()
				check(compare_animations(authored, native), kind + " rebuilt keys match saved " + animation_name)
				check(compare_animations(BAKER.convert_animation(native), native), kind + " repeat baking preserves " + animation_name)
		scenes.append({"kind": kind, "nodes": nodes.size() + 1, "meshes": mesh_count, "triangles": triangles, "animation_tracks": track_count})
		source.free()
		saved.free()
	var report := {"checks": checks, "failures": failures, "scenes": scenes, "rendered": false, "purpose": "Native resources and offline authoring consistency; not a performance benchmark"}
	FileAccess.open("res://tests/model_rebuild_audit.json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("MODEL_REBUILD_AUDIT ", checks - failures.size(), "/", checks, " passed; ", failures.size(), " failed")
	quit(0 if failures.is_empty() else 2)
