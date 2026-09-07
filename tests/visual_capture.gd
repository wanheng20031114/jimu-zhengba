extends SceneTree

func _initialize() -> void:
	call_deferred("capture")

func capture() -> void:
	var scene: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	scene.tests_running = true
	scene.camera_rig.edge_scroll = false
	scene.get_node("EnemyTimer").stop()
	for entity in get_nodes_in_group("entities"):
		entity.set_physics_process(false)
	await create_timer(0.6).timeout
	var camera: Camera3D = scene.camera
	var variants := [
		{"name": "camera_straight", "angle": 55.0, "yaw": 0.0, "zoom": 30.0, "center": Vector3(-10, 0, 15)},
		{"name": "camera_diagonal", "angle": 50.0, "yaw": -25.0, "zoom": 30.0, "center": Vector3(-12, 0, 14)},
		{"name": "camera_close", "angle": 48.0, "yaw": -20.0, "zoom": 27.0, "center": Vector3(-12, 0, 15)}
	]
	for variant in variants:
		var horizontal: float = 42.0 / tan(deg_to_rad(variant.angle))
		var yaw: float = deg_to_rad(variant.yaw)
		camera.position = Vector3(sin(yaw) * horizontal, 42, cos(yaw) * horizontal)
		camera.rotation_degrees = Vector3(-variant.angle, variant.yaw, 0)
		scene.camera_rig.focus_at(variant.center, true)
		scene.camera_rig.zoom_target = variant.zoom
		camera.size = variant.zoom
		await create_timer(0.6).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://artifacts/" + variant.name + ".png")
	quit()
