extends SceneTree
## Real Session/main UI routing, isolated preferences, native camera input, and orderly lobby return.
## Online cases exercise Game authority/event handling without opening an external relay connection.

var game: Node3D
var settings: GameSettings
var checks: int = 0
var failures: Array[String] = []
var original_preferences: Dictionary
var original_path: String
var original_user_file: PackedByteArray
var user_file_existed: bool = false

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func _key(value: Key) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = value
		event.pressed = pressed
		root.push_input(event, true)
	await process_frame

func _click(button: BaseButton) -> void:
	var at := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	root.push_input(motion, true)
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = at
		event.global_position = at
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)

func _capture(label: String) -> void:
	if "--capture-battle-settings" not in OS.get_cmdline_user_args():
		return
	await create_timer(0.22, true, false, true).timeout
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png("res://artifacts/battle_%s.png" % label) == OK, "Vulkan " + label + " screenshot saved")

func _run() -> void:
	create_timer(40.0, true, false, true).timeout.connect(_timeout)
	settings = root.get_node("Session/Settings")
	original_preferences = settings.snapshot()
	original_path = settings.settings_path
	user_file_existed = FileAccess.file_exists(original_path)
	if user_file_existed:
		original_user_file = FileAccess.get_file_as_bytes(original_path)
	settings.settings_path = "res://.local/battle-settings-integration.cfg"
	# No display changes: the automation window and desktop pointer remain untouched.
	var defaults: Dictionary = settings.defaults()
	defaults.window_mode = settings.window_mode
	defaults.resolution = settings.resolution
	settings._apply_values(defaults, false)
	root.get_node("Session").start_offline("1v1")
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	game.tests_running = true
	game.bots.clear()
	game.set_process(false)
	game.set_physics_process(false)
	game.get_node("IncomeTimer").stop()
	game.camera_rig.set_process(false)
	game.camera_rig.edge_scroll = false
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	var hud: Control = game.hud
	var audio: Node = game.get_node("Audio")
	game.select_entities([game.headquarters])
	var initial_gold: int = game.gold
	await _key(KEY_F5)
	check(paused and hud.get_node("%PauseOverlay").visible and audio._world_paused, "F5 pauses the live game, world voices and shows battle menu")
	check(hud.can_process() and not game.can_process(), "paused input belongs to always-processing HUD while Game is paused")
	await _capture("pause_menu")
	_click(hud.get_node("%SettingsButton"))
	await process_frame
	check(settings.is_open() and paused, "native SettingsButton opens preferences over paused battle")
	await _capture("settings_menu")
	await _key(KEY_Q)
	await _key(KEY_F5)
	check(paused and settings.is_open() and game.command_bus.pending.is_empty() and game.gold == initial_gold, "settings modal blocks production and pause input")
	await _key(KEY_ESCAPE)
	check(not settings.is_open() and paused and hud.get_node("%PauseOverlay").visible, "Esc closes settings without unpausing or closing underlying battle menu")
	await _key(KEY_F5)
	check(not paused and not hud.get_node("%PauseOverlay").visible and not audio._world_paused, "paused HUD F5 path resumes exactly once")
	await _key(KEY_P)
	check(paused, "P alias pauses")
	await _key(KEY_P)
	check(not paused, "P alias resumes through HUD")
	var preferences: Dictionary = settings.snapshot()
	preferences.bindings.rts_pause = [KEY_F8]
	settings.apply_preferences(preferences)
	await _key(KEY_F5)
	check(not paused, "old F5 no longer pauses after rebinding")
	await _key(KEY_F8)
	check(paused and "F8" in hud.get_node("%PauseButton").tooltip_text, "custom pause key pauses and updates visible control hint")
	await _key(KEY_F5)
	check(paused, "old F5 cannot resume a paused game after rebinding")
	await _key(KEY_F8)
	check(not paused, "custom pause key resumes through the HUD path")
	preferences.bindings.rts_pause = [KEY_F5, KEY_P]
	settings.apply_preferences(preferences)
	await _key(KEY_ESCAPE)
	_click(hud.get_node("%SettingsButton"))
	await process_frame
	var child_bus_gains: Dictionary = {}
	for index in range(1, AudioServer.bus_count):
		child_bus_gains[AudioServer.get_bus_name(index)] = AudioServer.get_bus_volume_db(index)
	settings.menu.show_page("Audio")
	settings.menu.get_node("%Volume").value = 43.0
	settings.menu.get_node("%Mute").button_pressed = true
	_click(settings.menu.get_node("%Apply"))
	await process_frame
	check(settings.muted and audio.muted and AudioServer.is_bus_mute(0), "native settings mute synchronizes AudioDirector and Master")
	check(is_equal_approx(settings.volume_percent, 43.0) and absf(audio.volume_percent() - 43.0) < 0.001, "settings volume and AudioDirector read the same Master gain")
	check(absf(hud.get_node("%SoundVolume").value - 43.0) < 0.001 and hud.get_node("%SoundMute").button_pressed, "paused battle audio controls follow settings changes")
	for index in range(1, AudioServer.bus_count):
		check(is_equal_approx(AudioServer.get_bus_volume_db(index), child_bus_gains[AudioServer.get_bus_name(index)]), "child bus gain remains independent of Master: " + str(AudioServer.get_bus_name(index)))
	var saved := ConfigFile.new()
	check(saved.load(settings.settings_path) == OK and saved.get_value("settings", "muted") == true and is_equal_approx(saved.get_value("settings", "volume_percent"), 43.0), "settings UI persists volume and mute to isolated native ConfigFile")
	await _key(KEY_ESCAPE)
	hud.get_node("%SoundVolume").value = 62.0
	check(is_equal_approx(settings.volume_percent, 62.0) and not settings.muted and not audio.muted and not AudioServer.is_bus_mute(0), "battle slider updates the shared preferences and unmutes")
	await _key(KEY_M)
	check(settings.muted and audio.muted and AudioServer.is_bus_mute(0), "paused M key changes the same persistent mute flag")
	check(saved.load(settings.settings_path) == OK and saved.get_value("settings", "muted") == true and is_equal_approx(saved.get_value("settings", "volume_percent"), 62.0), "battle audio controls persist to the same settings file")
	await _key(KEY_F5)
	await _test_camera()
	# The production network suite covers actual forwarding; here the real Game paths
	# are exercised with online ownership flags and real received-event application.
	game.online = true
	game.is_authority = false
	await _key(KEY_ESCAPE)
	check(game._local_menu and not paused, "online Esc opens local menu without pausing simulation")
	_click(hud.get_node("%SettingsButton"))
	await process_frame
	await _key(KEY_Q)
	await _key(KEY_F5)
	check(settings.is_open() and not paused and game.command_bus.pending.is_empty(), "online settings prevents production and global pause input")
	await _key(KEY_ESCAPE)
	check(not settings.is_open() and game._local_menu and not paused, "online settings Esc preserves local menu and running match")
	await _key(KEY_ESCAPE)
	check(not game._local_menu and not paused, "second online Esc returns to battle")
	await _key(KEY_F5)
	check(not paused and game._local_menu and not game._network_paused, "ordinary client F5 cannot pause the match")
	await _key(KEY_ESCAPE)
	game._on_network_event({"kind": "pause", "paused": true})
	check(paused and game._network_paused and audio._world_paused, "client applies host pause event to simulation and world audio")
	await _key(KEY_F5)
	check(paused and game._network_paused, "ordinary client cannot resume host pause through HUD input")
	game._on_network_event({"kind": "pause", "paused": false})
	check(not paused and not game._network_paused and not audio._world_paused, "client applies host resume event")
	if game._local_menu:
		await _key(KEY_ESCAPE)
	game.is_authority = true
	await _key(KEY_F5)
	check(paused and game._network_paused and audio._world_paused, "host F5 enters shared-pause authority path")
	await _key(KEY_F5)
	check(not paused and not game._network_paused and not audio._world_paused, "host F5 resumes shared pause through HUD")
	game.online = false
	await _key(KEY_ESCAPE)
	var game_reference: WeakRef = weakref(game)
	_click(hud.get_node("%MenuButton"))
	check(game._closing and game.finished and audio._stopping and game.get_node("IncomeTimer").is_stopped(), "native MenuButton enters prepare_shutdown before changing scenes")
	await scene_changed
	await process_frame
	check(current_scene.scene_file_path == "res://scenes/lobby.tscn" and not paused, "menu return reaches real lobby with tree unpaused")
	check(game_reference.get_ref() == null and get_nodes_in_group("units").is_empty(), "old battle and live unit nodes are released")
	check(not root.get_node("Session").online and root.get_node("Session").config.is_empty() and not settings.is_open(), "lobby return clears match membership and leaves settings closed")
	check(settings.muted and is_equal_approx(settings.volume_percent, 62.0), "persistent Session retains battle audio preference across lobby transition")
	_restore_preferences()
	check(FileAccess.file_exists(original_path) == user_file_existed, "user settings file existence is unchanged")
	if user_file_existed:
		check(FileAccess.get_file_as_bytes(original_path) == original_user_file, "user settings.cfg bytes remain untouched")
	check(settings.snapshot() == original_preferences, "initial global preferences restored after integration test")
	print("BATTLE_SETTINGS_INTEGRATION ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _test_camera() -> void:
	var camera: Node3D = game.camera_rig
	var size := Vector2(1280, 720)
	var samples := {
		Vector2(-80, 360): Vector2.LEFT, Vector2(1400, 360): Vector2.RIGHT,
		Vector2(-20, -30): Vector2(-1, -1), Vector2(1300, -30): Vector2(1, -1),
		Vector2(-20, 760): Vector2(-1, 1), Vector2(1300, 760): Vector2(1, 1),
		Vector2(640, 360): Vector2.ZERO,
	}
	for point: Vector2 in samples:
		check(camera.edge_direction(point, size) == samples[point], "outside-window / corner / center direction " + str(point))
	game.open_settings()
	settings.menu.show_page("Controls")
	settings.menu.get_node("%EdgeScroll").button_pressed = false
	settings.menu.get_node("%CameraSpeed").value = 2.0
	settings.menu.get_node("%ZoomSpeed").value = 1.5
	_click(settings.menu.get_node("%Apply"))
	await process_frame
	check(not settings.edge_scroll_enabled and is_equal_approx(settings.camera_speed, 2.0) and is_equal_approx(settings.zoom_speed, 1.5), "native control settings apply edge switch and camera multipliers")
	var before: Vector3 = camera.destination
	Input.action_press("rts_pan_right")
	camera._process(0.1)
	Input.action_release("rts_pan_right")
	check(camera.destination == before, "settings modal blocks native camera direction input")
	await _key(KEY_ESCAPE)
	camera.edge_scroll = true
	camera._process(0.1)
	check(camera.destination == before, "disabled edge-scrolling preference suppresses desktop-pointer panning")
	camera.edge_scroll = false
	camera.position = Vector3.ZERO
	camera.destination = Vector3.ZERO
	camera.zoom_target = 37.0
	Input.action_press("rts_pan_right")
	camera._process(0.1)
	Input.action_release("rts_pan_right")
	check(is_equal_approx(camera.destination.length(), camera.pan_speed * 2.0 * 0.1), "native InputMap axis uses configured pan-speed multiplier")
	camera.zoom_by(2.0)
	check(is_equal_approx(camera.zoom_target, 40.0), "scroll zoom uses configured multiplier")
	camera.destination = Vector3.ZERO
	camera.drag_by(Vector2(10, 0))
	var fast_drag: float = camera.destination.length()
	settings.camera_speed = 1.0
	camera.destination = Vector3.ZERO
	camera.drag_by(Vector2(10, 0))
	check(is_equal_approx(fast_drag, camera.destination.length() * 2.0), "middle-drag response uses the same camera multiplier")
	var preference: Dictionary = settings.snapshot()
	preference.bindings.rts_pan_right = [KEY_J]
	settings.apply_preferences(preference)
	var event := InputEventKey.new()
	event.physical_keycode = KEY_J
	event.pressed = true
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	check(Input.get_axis("rts_pan_left", "rts_pan_right") == 1.0, "remapped physical camera key feeds native InputMap axis")
	var release: InputEventKey = event.duplicate()
	release.pressed = false
	Input.parse_input_event(release)
	Input.flush_buffered_events()
	var saved := ConfigFile.new()
	check(saved.load(settings.settings_path) == OK and saved.get_value("settings", "edge_scroll_enabled") == false and saved.get_value("hotkeys", "rts_pan_right") == [KEY_J], "camera edge switch and native key binding persist")
	camera.focus_at(game.headquarters.position, true)

func _restore_preferences() -> void:
	paused = false
	settings.close_menu()
	settings._apply_values(original_preferences, false)
	settings.settings_path = original_path

func _timeout() -> void:
	printerr("BATTLE_SETTINGS_INTEGRATION timed out")
	if is_instance_valid(settings):
		_restore_preferences()
	if is_instance_valid(game):
		game.online = false
		await game.prepare_shutdown()
	quit(3)
