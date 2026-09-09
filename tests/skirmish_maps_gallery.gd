extends Node3D
## Short authored-scene capture; no player windows, input or audio are touched.

func register_entity(entity: Node) -> void:
	entity.entity_id = entity.get_instance_id()

func _ready() -> void:
	var camera: Camera3D = $Camera3D
	camera.position = Vector3(24,36,24)
	camera.look_at(Vector3(0,2,0))
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--map="):
			var map_id: String = argument.trim_prefix("--map=")
			$Models.queue_free()
			$Floor.queue_free()
			var map_scene: Node3D = load("res://scenes/maps/" + map_id + ".tscn").instantiate()
			add_child(map_scene)
			camera.position = Vector3(70,99,70)
			camera.look_at(Vector3.ZERO)
			camera.size = 126.0 if map_id.ends_with("2v2") else 100.0
			$CanvasLayer/Title.text = "灰烬王国   /   " + String(map_scene.get_meta("map_title"))
			for spawn: Marker3D in map_scene.get_node("SpawnPoints").get_children():
				var visual: Node3D = load("res://assets/models/environment/headquarters.tscn").instantiate()
				add_child(visual)
				visual.position = spawn.position
				visual.rotation.y = spawn.rotation.y
			await _capture("artifacts/" + map_id + ".png")
			get_tree().quit()
			return
	await _capture("artifacts/skirmish-buildings.png")
	get_tree().quit()

func _capture(path: String) -> void:
	for frame: int in 20:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	assert(image.save_png(path) == OK)
	print("SKIRMISH_CAPTURE ", path)
