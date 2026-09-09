extends SceneTree
## Vulkan captures and a real window-size change with rollback. Test preferences stay private.
var settings: GameSettings
var failures := 0

func _initialize() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	run.call_deferred()

func run() -> void:
	change_scene_to_file("res://scenes/lobby.tscn")
	await scene_changed
	settings = root.get_node("Session/Settings")
	settings.settings_path = "res://.local/settings-visual.cfg"
	await create_timer(0.75).timeout
	await capture("main-menu")
	settings.open_menu()
	for page: String in ["Graphics", "Audio", "Controls", "Hotkeys"]:
		settings.menu.show_page(page)
		await create_timer(0.2).timeout
		await capture("settings-" + page.to_lower())
	var previous := DisplayServer.window_get_size()
	var values := settings.snapshot()
	values.window_mode = 0
	values.resolution = Vector2i(1280, 720)
	settings.apply_preferences(values)
	# Prevent this verification window from obscuring or focusing another application.
	DisplayServer.window_set_position(Vector2i(-20000, -20000))
	await create_timer(0.2).timeout
	if DisplayServer.window_get_size() != Vector2i(1280, 720): failures += 1
	await capture("settings-display-confirm")
	settings.revert_display()
	DisplayServer.window_set_position(Vector2i(-20000, -20000))
	await create_timer(0.2).timeout
	if DisplayServer.window_get_size() != previous: failures += 1
	settings.close_menu()
	print("SETTINGS_VISUAL_RESULT 6 captures, real resize / rollback, ", failures, " failures")
	quit(0 if failures == 0 else 1)

func capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png("res://artifacts/" + name + ".png")
	if error != OK: failures += 1
