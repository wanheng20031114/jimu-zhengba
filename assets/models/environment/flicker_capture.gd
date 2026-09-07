extends Node3D
## Saved-scene GPU review: tight roof/sidewall views and a moving-camera sweep.

func _ready() -> void:
	var label := "after"
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		label = args[0]
	var folder := "res://artifacts/environment_flicker/" + label
	DirAccess.make_dir_recursive_absolute(folder)
	var camera: Camera3D = $Camera3D
	var views := [
		["headquarters", Vector3(-22, 3.2, 23), 14.0, Vector3(12, 12, 18)],
		["keep", Vector3(22, 3.6, -24), 15.0, Vector3(14, 12, 18)],
		["house", Vector3(-29, 2.5, 9), 11.0, Vector3(13, 10, 15)],
		["ruin", Vector3(-16, 1.8, -2), 10.0, Vector3(-12, 11, 17)],
		["tower", Vector3(25, 4.4, -7), 9.0, Vector3(11, 14, 15)],
		["road", Vector3(-12, 0, 12), 16.0, Vector3(11, 18, 14)],
	]
	for view in views:
		camera.size = view[2]
		var target: Vector3 = view[1]
		var offset: Vector3 = view[3]
		camera.position = target + offset
		camera.look_at(target)
		for frame in range(24):
			await get_tree().process_frame
		for frame in range(12):
			var shift := Vector3((frame - 5.5) * 0.006, 0, 0)
			camera.position = target + offset + shift
			camera.look_at(target + shift)
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(folder + "/%s_micro_%02d.png" % [view[0], frame])
		for frame in range(12):
			camera.position = target + offset.rotated(Vector3.UP, (frame - 5.5) * 0.018)
			camera.look_at(target)
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(folder + "/%s_orbit_%02d.png" % [view[0], frame])
	print("ENVIRONMENT_FLICKER_REVIEW_COMPLETE ", label)
	get_tree().quit()
