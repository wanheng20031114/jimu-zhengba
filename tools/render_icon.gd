extends SceneTree
## Renders the authored headquarters directly, preserving native transparency.

func _initialize() -> void:
	call_deferred("render_icon")

func render_icon() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	var previews: Node = load("res://scenes/model_previews.tscn").instantiate()
	root.add_child(previews)
	var viewport: SubViewport = previews.get_node("headquarters")
	viewport.size = Vector2i(256, 256)
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await process_frame
	await RenderingServer.frame_post_draw
	var result := viewport.get_texture().get_image().save_png("res://assets/icon.png")
	print("ICON_RENDER: ", error_string(result))
	previews.queue_free()
	await process_frame
	await process_frame
	quit(result)
