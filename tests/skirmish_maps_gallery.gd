extends Node3D
## Short authored-scene capture; no player windows, input or audio are touched.

func register_entity(entity: Node) -> void:
	entity.entity_id = entity.get_instance_id()

func _ready() -> void:
	var camera: Camera3D = $Camera3D
	camera.position = Vector3(24,36,24)
	camera.look_at(Vector3(0,2,0))
	var capture_output: String = ""
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-output="):
			capture_output = argument.trim_prefix("--capture-output=")
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--map="):
			var map_id: String = argument.trim_prefix("--map=")
			$Models.queue_free()
			$Floor.queue_free()
			var map_scene: Node3D = load("res://scenes/maps/" + map_id + ".tscn").instantiate()
			add_child(map_scene)
			camera.position = Vector3(70,99,70)
			camera.look_at(Vector3.ZERO)
			var map_size: Vector2 = map_scene.get_meta("map_size")
			camera.size = maxf(map_size.x, map_size.y) * 1.08
			$CanvasLayer/Title.text = "积木争霸   /   " + String(map_scene.get_meta("map_title"))
			for spawn: Marker3D in map_scene.get_node("SpawnPoints").get_children():
				var visual: Node3D = load("res://assets/models/environment/headquarters.tscn").instantiate()
				add_child(visual)
				visual.position = spawn.position
				visual.rotation.y = spawn.rotation.y
				var relation: int = FactionPalette.SELF if spawn.get_meta("player_id") == 0 else (FactionPalette.ALLY if spawn.get_meta("alliance_id") == 0 else FactionPalette.ENEMY)
				FactionPalette.apply_model(visual, relation)
				var tower: Node3D = load("res://assets/models/environment/defense_tower.tscn").instantiate()
				add_child(tower)
				tower.position = spawn.get_meta("starting_tower_position")
				tower.rotation.y = spawn.rotation.y
				FactionPalette.apply_model(tower, relation)
			await _capture(capture_output if not capture_output.is_empty() else "artifacts/" + map_id + ".png")
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
