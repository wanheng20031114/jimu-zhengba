extends SceneTree
## Visual audit only: exact same frozen battlefield, two native shadow configurations.
## Run with a real renderer: --script res://tests/shadow_camera_audit.gd
const OUTPUT := "res://artifacts/shadow_camera_audit"
const CANDIDATE_FAR := 110.0
const FOCUS := Vector3(-13, 0, 18)
const CORNERS: Dictionary = {"northwest": Vector3(-35, 0, -34), "northeast": Vector3(35, 0, -34),
	"southwest": Vector3(-35, 0, 35), "southeast": Vector3(35, 0, 35)}
const POSES: Dictionary = {"swordsman": .22, "archer": .24, "knight": .20,
	"catapult": .44, "cannon": .285, "farmer": .65}
var game: Node3D
var camera: Camera3D
var sun: DirectionalLight3D
var failures: Array[String] = []
var checks: int = 0
var report: Dictionary = {"captures": [], "camera_cases": []}
var actor_meshes: Array[Dictionary] = []
var initial_actor_signature: Array[Transform3D] = []
var finishing: bool = false

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, label: String) -> void:
	checks += 1
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures.append(label)

func _run() -> void:
	create_timer(70.0, true, false, true).timeout.connect(func():
		_check(false, "shadow camera audit deadline")
		_finish())
	_check(DisplayServer.get_name() != "headless", "real renderer is available for shadow comparison captures")
	if not failures.is_empty():
		await _finish()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	Engine.max_fps = 120
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	# Test-only viewport sizing: projection really changes to the requested aspect ratio.
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1600, 900)
	seed(4603110)
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	camera = game.camera
	sun = game.get_node("Sun")
	game.tests_running = true
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	game.camera_rig.edge_scroll = false
	game.camera_rig.set_process(false)
	game.select_entities([])
	game.get_node("HUD").hide()
	game.get_node("RallyMarker").hide()
	await physics_frame
	# Retain all authored map objects and units; freeze each at a repeatable native pose.
	for unit: Node3D in get_nodes_in_group("units"):
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
		unit.attack_windup.stop()
		var locomotion: AnimationPlayer = unit._model.get_node("Locomotion")
		var attack: AnimationPlayer = unit._model.get_node("Attack")
		locomotion.stop()
		locomotion.play("idle")
		locomotion.advance(0.0)
		locomotion.pause()
		attack.stop()
		attack.play("gather" if unit.unit_type == "farmer" else "strike")
		attack.advance(POSES[unit.unit_type])
		attack.pause()
		unit.reset_physics_interpolation()
	for building: Node3D in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
	# Disable remaining processing throughout this frozen fixture, including portrait timers.
	game.process_mode = Node.PROCESS_MODE_DISABLED
	game.get_node("ProjectilePool").reset_all()
	for effect: Node in game.effect_container.get_children():
		effect.queue_free()
	await process_frame
	_cache_actor_meshes()
	initial_actor_signature = _actor_signature()
	_check(camera.projection == Camera3D.PROJECTION_ORTHOGONAL and camera.keep_aspect == Camera3D.KEEP_HEIGHT,
		"authored camera uses orthographic projection with preserved vertical extent")
	_check(int(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/size")) == 4096,
		"shadow atlas retains the authored 4096 resolution")
	report["engine"] = Engine.get_version_info()
	report["fixed_actor_meshes"] = actor_meshes.size()
	report["preserved_shadow_settings"] = {"atlas_size": 4096, "normal_bias": sun.shadow_normal_bias,
		"bias": sun.shadow_bias, "angular_distance": sun.light_angular_distance,
		"soft_filter_quality": ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality")}

	_set_view(FOCUS, 31.0)
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_blend_splits = true
	camera.far = 220.0
	await _capture("01_old_four_splits_far220_zoom31")
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	camera.far = CANDIDATE_FAR
	await _capture("02_candidate_single_far110_zoom31")
	_set_view(FOCUS, 16.0)
	await _capture("03_candidate_single_far110_zoom16")
	_set_view(FOCUS, 62.0)
	await _capture("04_candidate_single_far110_zoom62")
	for corner: String in CORNERS:
		_set_view(CORNERS[corner], 31.0)
		await _capture("05_candidate_corner_" + corner)

	var positions: Dictionary = {"focus": FOCUS}
	positions.merge(CORNERS)
	for dimensions: Vector2i in [Vector2i(1600, 900), Vector2i(1680, 720), Vector2i(1600, 450)]:
		root.size = dimensions
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var viewport_size: Vector2 = root.get_visible_rect().size
		_check(absf(viewport_size.x / viewport_size.y - float(dimensions.x) / dimensions.y) < .001,
			"native viewport exposes the requested %dx%d aspect ratio" % [dimensions.x, dimensions.y])
		for zoom: float in [16.0, 31.0, 62.0]:
			for position_name: String in positions:
				_set_view(positions[position_name], zoom)
				_audit_frustum(dimensions, zoom, position_name)
		if dimensions.y != 900:
			_set_view(FOCUS, 62.0)
			await _capture("06_candidate_ultrawide_%dx%d_zoom62" % [dimensions.x, dimensions.y])
	_check(initial_actor_signature == _actor_signature(), "all comparison captures retain exactly the same actor transforms and attack poses")
	await _finish()

func _set_view(at: Vector3, zoom: float) -> void:
	game.camera_rig.position = at
	game.camera_rig.destination = at
	game.camera_rig.zoom_target = zoom
	camera.size = zoom
	camera.force_update_transform()

func _capture(label: String) -> void:
	# Settle native temporal AA and shadow history after each static camera/configuration change.
	for frame: int in range(16):
		await RenderingServer.frame_post_draw
	var path: String = OUTPUT + "/" + label + ".png"
	var error: Error = root.get_texture().get_image().save_png(path)
	_check(error == OK, "saved " + label)
	report.captures.append({"path": path, "shadow_mode": sun.directional_shadow_mode,
		"camera_far": camera.far, "zoom": camera.size, "focus": _vector(game.camera_rig.position),
		"viewport": _vector2(root.get_visible_rect().size)})

func _audit_frustum(dimensions: Vector2i, zoom: float, position_name: String) -> void:
	var viewport_size: Vector2 = root.get_visible_rect().size
	var screen_corners: Array[Vector2] = [Vector2.ZERO, Vector2(viewport_size.x, 0), viewport_size, Vector2(0, viewport_size.y)]
	var world_ground := Plane(Vector3.UP, 0.0)
	var camera_inverse: Transform3D = camera.get_camera_transform().affine_inverse()
	var ground: Array[Dictionary] = []
	var minimum_ground_far_margin: float = INF
	var minimum_ground_near_margin: float = INF
	for screen: Vector2 in screen_corners:
		var intersection: Variant = world_ground.intersects_ray(camera.project_ray_origin(screen), camera.project_ray_normal(screen))
		if intersection == null:
			_check(false, "orthographic corner ray intersects the ground")
			return
		var at: Vector3 = intersection
		# Clipping uses camera-local forward depth, not Euclidean camera distance.
		var depth: float = -(camera_inverse * at).z
		minimum_ground_far_margin = minf(minimum_ground_far_margin, camera.far - depth)
		minimum_ground_near_margin = minf(minimum_ground_near_margin, depth - camera.near)
		ground.append({"world": _vector(at), "forward_depth_m": depth, "far_margin_m": camera.far - depth})
	var label: String = "%dx%d zoom %.0f %s" % [dimensions.x, dimensions.y, zoom, position_name]
	_check(minimum_ground_far_margin >= 15.0 and minimum_ground_near_margin >= 10.0,
		label + " all four ground corners retain clip-plane clearance (far %.3f m)" % minimum_ground_far_margin)

	var relevant_meshes: int = 0
	var clipped_meshes: Array[String] = []
	var minimum_actor_far_margin: float = INF
	var minimum_actor_near_margin: float = INF
	var worst_actor: String = ""
	for entry: Dictionary in actor_meshes:
		var projected_min := Vector2(INF, INF)
		var projected_max := Vector2(-INF, -INF)
		var min_depth: float = INF
		var max_depth: float = -INF
		for vertex: Vector3 in entry.corners:
			var screen: Vector2 = camera.unproject_position(vertex)
			projected_min = projected_min.min(screen)
			projected_max = projected_max.max(screen)
			var depth: float = -(camera_inverse * vertex).z
			min_depth = minf(min_depth, depth)
			max_depth = maxf(max_depth, depth)
		# Use screen-plane overlap independently of near/far; already-clipped geometry must not be excluded.
		var projected_rect := Rect2(projected_min, projected_max - projected_min)
		if not projected_rect.intersects(Rect2(Vector2.ZERO, viewport_size), true):
			continue
		relevant_meshes += 1
		var far_margin: float = camera.far - max_depth
		var near_margin: float = min_depth - camera.near
		if far_margin < minimum_actor_far_margin:
			minimum_actor_far_margin = far_margin
			worst_actor = entry.path
		minimum_actor_near_margin = minf(minimum_actor_near_margin, near_margin)
		if far_margin < 1.0 or near_margin < 1.0:
			clipped_meshes.append(entry.path)
	_check(clipped_meshes.is_empty(), label + " every screen-overlapping unit/building AABB retains at least 1 m clip margin")
	report.camera_cases.append({"viewport": [dimensions.x, dimensions.y], "zoom": zoom,
		"focus_name": position_name, "ground_corners": ground, "minimum_ground_far_margin_m": minimum_ground_far_margin,
		"minimum_ground_near_margin_m": minimum_ground_near_margin, "screen_overlapping_actor_meshes": relevant_meshes,
		"minimum_actor_far_margin_m": minimum_actor_far_margin if relevant_meshes > 0 else null,
		"minimum_actor_near_margin_m": minimum_actor_near_margin if relevant_meshes > 0 else null,
		"worst_actor_mesh": worst_actor, "clipped_meshes": clipped_meshes})

func _cache_actor_meshes() -> void:
	for actor: Node3D in get_nodes_in_group("entities"):
		if not actor.is_in_group("units") and not actor.is_in_group("buildings"):
			continue
		for mesh: MeshInstance3D in actor._model.find_children("*", "MeshInstance3D", true, false):
			if not mesh.is_visible_in_tree():
				continue
			var corners: Array[Vector3] = []
			var bounds: AABB = mesh.get_aabb()
			for index: int in range(8):
				corners.append(mesh.global_transform * bounds.get_endpoint(index))
			actor_meshes.append({"path": String(mesh.get_path()), "mesh": mesh, "corners": corners})

func _actor_signature() -> Array[Transform3D]:
	var signature: Array[Transform3D] = []
	for entry: Dictionary in actor_meshes:
		signature.append(entry.mesh.global_transform)
	return signature

func _vector(value: Vector3) -> Array[float]:
	return [value.x, value.y, value.z]

func _vector2(value: Vector2) -> Array[float]:
	return [value.x, value.y]

func _finish() -> void:
	if finishing:
		return
	finishing = true
	if is_instance_valid(game):
		await game.prepare_shutdown()
	report.checks = checks
	report.failures = failures
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var file := FileAccess.open(OUTPUT + "/results.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	print("SHADOW_CAMERA_AUDIT_RESULT ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 2)
