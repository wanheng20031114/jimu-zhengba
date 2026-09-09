extends SceneTree
## Off-screen native-window layout and input mapping audit; no desktop input.
const SIZES: Array[Vector2i] = [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(1280, 960), Vector2i(2560, 1080)]
var game: Node3D
var reports: Array[Dictionary] = []
var failures: Array[String] = []
var checks: int = 0
var current_label: String = ""
var client_transform: Transform2D

func _initialize() -> void:
	assert(DirAccess.make_dir_recursive_absolute("res://artifacts/hud_resize") == OK)
	root.visible = false
	root.unfocusable = true
	RenderingServer.viewport_set_update_mode(root.get_viewport_rid(), RenderingServer.VIEWPORT_UPDATE_ALWAYS)
	call_deferred("_run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(current_label + " " + label)
		push_error(current_label + " " + label)

func vector_data(value: Vector2) -> Array:
	return [value.x, value.y]

func rect_data(value: Rect2) -> Dictionary:
	return {"position": vector_data(value.position), "size": vector_data(value.size)}

func click_client(logical_position: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var position: Vector2 = client_transform * logical_position
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = position
		event.global_position = position
		event.button_index = button
		event.pressed = pressed
		root.push_input(event, false)
		await process_frame

func click_control(name: String) -> void:
	await click_client(game.hud.get_node("%" + name).get_global_rect().get_center())

func capture(suffix: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://artifacts/hud_resize/%s_%s.png" % [current_label, suffix])

func inspect_controls(parent: Control, report: Dictionary) -> void:
	var visible_rect: Rect2 = root.get_visible_rect()
	var controls: Array[Control] = []
	for node: Node in parent.find_children("*", "Control", true, false):
		if node is Button or node.name == "Minimap":
			var control: Control = node
			if control.is_visible_in_tree():
				controls.append(control)
				var rect: Rect2 = control.get_global_rect()
				check(visible_rect.encloses(rect), "visible button/minimap within viewport: " + str(control.name))
				check(Rect2(Vector2.ZERO, Vector2(DisplayServer.window_get_size())).encloses(client_transform * rect), "button/minimap within native client: " + str(control.name))
				report[str(control.name)] = {"logical": rect_data(rect), "client_pixels": rect_data(client_transform * rect)}
	for first: int in range(controls.size()):
		for second: int in range(first + 1, controls.size()):
			check(not controls[first].get_global_rect().intersects(controls[second].get_global_rect()), "no clickable overlap: %s / %s" % [controls[first].name, controls[second].name])

func inspect_overlay(path: String, report: Dictionary) -> void:
	var paper: Control = game.hud.get_node(path + "/Paper")
	check(root.get_visible_rect().encloses(paper.get_global_rect()), path + " panel fits viewport")
	var rects: Array[Rect2] = []
	var names: Array[String] = []
	for node: Node in paper.get_children():
		if node is Control:
			var control: Control = node
			var rect: Rect2 = control.get_global_rect()
			check(paper.get_global_rect().encloses(rect), path + " child inside panel: " + str(node.name))
			for index: int in range(rects.size()):
				check(not rect.intersects(rects[index]), path + " child rectangles do not overlap: %s / %s" % [node.name, names[index]])
			rects.append(rect)
			names.append(str(node.name))
			report[path + "/" + str(node.name)] = rect_data(rect)

func _run() -> void:
	create_timer(55.0, true, false, true).timeout.connect(func(): quit(3))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	for target_size: Vector2i in SIZES:
		current_label = "%dx%d" % [target_size.x, target_size.y]
		root.size = target_size
		DisplayServer.window_set_position(Vector2i(10000, 10000))
		change_scene_to_file("res://scenes/main.tscn")
		await scene_changed
		game = current_scene
		game.tests_running = true
		game.camera_rig.edge_scroll = false
		game.get_node("EnemyTimer").stop()
		game.get_node("IncomeTimer").stop()
		game.get_node("Audio").set_volume_percent(0)
		for entity: Node in get_nodes_in_group("entities"):
			entity.set_physics_process(false)
		await create_timer(.5).timeout
		game.gold = 10000
		game.hud.refresh()
		var actual: Vector2i = DisplayServer.window_get_size()
		client_transform = root.get_screen_transform()
		var content: Rect2 = client_transform * root.get_visible_rect()
		var report: Dictionary = {"requested": vector_data(target_size), "window_size": vector_data(actual), "root_window_size": vector_data(root.size), "viewport": rect_data(root.get_visible_rect()), "screenshot_size": vector_data(root.get_texture().get_image().get_size()), "screenshot_scope": "Viewport content only; letterbox margins are outside the captured render target", "content_in_client_pixels": rect_data(content), "client_transform": str(client_transform), "stretch_transform": str(root.get_stretch_transform()), "final_transform": str(root.get_final_transform()), "content_scale_aspect": root.content_scale_aspect, "godot_focused": DisplayServer.window_is_focused(), "no_focus_flag": DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS), "controls": {}, "overlays": {}}
		print("RESIZE ", current_label, " ", JSON.stringify(report))
		check(actual == target_size, "native requested client size applied")
		check(DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS), "test window has native no-focus flag")
		inspect_controls(game.hud, report.controls)
		for index: int in range(6):
			var before_gold: int = game.gold
			var before_count: int = game.player_count()
			await click_control("Recruit" + str(index))
			check(game.player_count() == before_count + 1 and game.gold == before_gold - game.hud.COSTS[index], "client pixel click recruits " + game.hud.UNIT_ORDER[index])
		check(game.headquarters in game.selection, "GUI clicks preserve HQ selection")
		await click_control("ArmyButton")
		check(game.selection.size() == get_nodes_in_group("friendly_units").filter(func(unit): return unit.alive and unit.unit_type != "farmer").size(), "native client click selects military army")
		await click_control("AttackButton")
		check(game.attack_mode, "native client click activates attack mode")
		game.set_attack_mode(false)
		await click_control("HoldButton")
		check(game.selection[0].order_name == "坚守阵地", "native client click holds selected unit")
		await click_control("StopButton")
		check(game.selection[0].order_name == "待命", "native client click stops selected unit")
		await click_control("BaseButton")
		check(game.headquarters in game.selection and game.selection.size() == 1, "native client click selects headquarters")
		var minimap: Control = game.hud.get_node("%Minimap")
		var map_point: Vector2 = minimap.get_global_rect().position + minimap.size * Vector2(.62, .38)
		await click_client(map_point)
		check(game.camera_rig.destination.distance_to(Vector3(10.08, 0, -10.08)) < .05, "minimap client coordinate maps to correct world point")
		game.camera_rig.focus_at(Vector3(-10, 0, 17), true)
		await capture("hud")
		var worker: Node3D = get_nodes_in_group("friendly_units").filter(func(unit): return unit.unit_type == "farmer")[0]
		game.select_entities([worker])
		inspect_controls(game.hud, report.controls)
		await click_control("BuildButton")
		check(game.build_mode, "native client build button opens placement")
		game.set_build_mode(false)
		await capture("worker")
		game.select_entities([game.headquarters])
		await click_control("HelpButton")
		check(game.hud.help_visible(), "client click opens help")
		inspect_overlay("HelpOverlay", report.overlays)
		await capture("help")
		await click_control("CloseHelp")
		check(not game.hud.help_visible(), "client click closes help")
		await click_control("PauseButton")
		check(paused, "client click pauses game")
		inspect_overlay("PauseOverlay", report.overlays)
		await capture("pause")
		await click_control("ResumeButton")
		check(not paused, "client click resumes paused game")
		if paused:
			paused = false
		var size_pixels := Vector2(actual)
		for point: Vector2 in [Vector2(1, actual.y * .5), Vector2(actual.x - 1, actual.y * .5), Vector2(actual.x * .5, 1), Vector2(actual.x * .5, actual.y - 1)]:
			check(game.camera_rig.edge_direction(point, size_pixels).length() == 1.0, "edge scroll uses actual client edge " + str(point))
		check(game.camera_rig.edge_direction(Vector2(-1, 1), size_pixels) == Vector2(-1, -1), "outside client keeps scrolling toward the crossed corner")
		if content.position.y > 20:
			check(game.camera_rig.edge_direction(Vector2(actual.x * .5, content.position.y + 1), size_pixels) == Vector2.ZERO, "inner top content boundary is not physical window edge")
		if content.position.x > 20:
			check(game.camera_rig.edge_direction(Vector2(content.position.x + 1, actual.y * .5), size_pixels) == Vector2.ZERO, "inner left content boundary is not physical window edge")
		reports.append(report)
		await game.prepare_shutdown()
	var result := {"checks": checks, "failures": failures, "cases": reports, "renderer": RenderingServer.get_current_rendering_method(), "driver": ProjectSettings.get_setting("rendering/rendering_device/driver.windows"), "input_method": "Viewport.push_input(client_pixel_event, false); no global desktop mouse input", "edge_scroll_scope": "Pure edge_direction verified against actual client and letterbox sizes; focused OS mouse branch not driven"}
	FileAccess.open("res://artifacts/hud_resize/results.json", FileAccess.WRITE).store_string(JSON.stringify(result, "\t"))
	print("HUD_RESIZE ", checks - failures.size(), "/", checks, " passed; failures=", failures)
	quit(0 if failures.is_empty() else 2)
