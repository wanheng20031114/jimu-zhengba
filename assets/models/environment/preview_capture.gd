extends Node3D

func _ready() -> void:
	var camera: Camera3D = $Camera3D
	await get_tree().process_frame
	camera.look_at(Vector3(0, 0, 0))
	for frame in range(24):
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("res://assets/models/environment/preview_battlefield.png")
	camera.size = 19
	camera.position = Vector3(-10, 17, 39)
	camera.look_at(Vector3(-22, 3.4, 23))
	for frame in range(10):
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("res://assets/models/environment/preview_headquarters.png")
	camera.size = 17
	camera.position = Vector3(34, 16, -7)
	camera.look_at(Vector3(22, 3.6, -24))
	for frame in range(10):
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("res://assets/models/environment/preview_keep.png")
	print("ENVIRONMENT_PREVIEW_COMPLETE")
	get_tree().quit()
