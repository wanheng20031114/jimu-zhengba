extends Node3D
## Native authored model gallery. Does not change player settings or match state.
func _ready() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	DisplayServer.window_set_position(Vector2i(-20000, -20000))
	get_viewport().size = Vector2i(1600, 900)
	for relation: int in [FactionPalette.SELF, FactionPalette.ALLY, FactionPalette.ENEMY]:
		for model: Node3D in $Models.get_children():
			FactionPalette.apply_model(model, relation)
		await get_tree().create_timer(0.7).timeout
		await RenderingServer.frame_post_draw
		var error := get_viewport().get_texture().get_image().save_png("res://artifacts/world-models-%d.png" % relation)
		if error != OK:
			push_error("World gallery capture failed")
			get_tree().quit(1)
			return
	print("WORLD_MODEL_GALLERY_SAVED 3 observer color views")
	get_tree().quit()
