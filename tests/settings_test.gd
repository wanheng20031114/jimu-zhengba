extends SceneTree
## Native InputMap, ConfigFile, modal cancellation and timeout while paused.
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func key_event(key: Key, physical: bool = true) -> InputEventKey:
	var event := InputEventKey.new()
	event.pressed = true
	if physical: event.physical_keycode = key
	else: event.keycode = key
	return event

func run() -> void:
	var settings: GameSettings = root.get_node("Session/Settings")
	settings.settings_path = "res://.local/settings-test.cfg"
	settings._apply_values(settings.defaults(), false)
	for action: String in GameSettings.ACTIONS:
		check(InputMap.has_action(action), action + " is a native action")
		for key: int in GameSettings.ACTIONS[action][2]:
			check(settings.resolve_key(key_event(key as Key)) == GameSettings.ACTIONS[action][1], action + " resolves physical aliases")
			check(settings.resolve_key(key_event(key as Key, false)) == GameSettings.ACTIONS[action][1], action + " resolves synthetic keycode input")
	var append := key_event(KEY_3)
	append.ctrl_pressed = true
	append.shift_pressed = true
	check(settings.resolve_key(append) == KEY_3 and append.ctrl_pressed and append.shift_pressed, "control-group modifiers survive normalization")
	check(settings.resolve_key(key_event(KEY_F12)) == KEY_NONE, "F12 remains outside rebindable gameplay actions")
	check(not settings.binding_error("rts_select_army", KEY_Q, settings.bindings).is_empty(), "duplicate keys report the conflicting action")
	check(not settings.binding_error("rts_select_army", KEY_ESCAPE, settings.bindings).is_empty(), "Esc cannot be stolen")
	check(not settings.binding_error("rts_select_army", KEY_F12, settings.bindings).is_empty(), "F12 cannot be stolen")
	check(settings.binding_error("rts_cancel", KEY_ESCAPE, settings.bindings).is_empty(), "Esc is allowed for the cancellation action")
	check(settings.resolve_key(key_event(KEY_P)) == KEY_NONE, "pause defaults to F5 without the previous P alias")
	settings.open_menu()
	check(settings.is_open() and not paused, "opening settings does not pause a match")
	settings.menu.begin_rebind("rts_select_army")
	settings.menu._input(key_event(KEY_ESCAPE, false))
	check(settings.is_open() and settings.menu.rebinding_action.is_empty(), "Esc cancels key capture before closing the menu")
	settings.menu.begin_rebind("rts_cancel")
	settings.menu._input(key_event(KEY_ESCAPE, false))
	check(settings.is_open() and settings.menu.draft.bindings.rts_cancel == [KEY_ESCAPE] and settings.menu.rebinding_action.is_empty(), "cancel action can be rebound to its native Esc key")
	settings.menu.begin_rebind("rts_select_army")
	settings.menu._input(key_event(KEY_J, false))
	check(settings.menu.draft.bindings.rts_select_army == [KEY_J], "native key capture edits the pending binding")
	check(settings.resolve_key(key_event(KEY_F2)) == KEY_F2, "draft bindings do not alter live controls before Apply")
	settings.menu.draft.volume_percent = 43.0
	settings.menu.draft.muted = true
	settings.menu.draft.camera_speed = 1.65
	settings.menu.draft.zoom_speed = 0.75
	settings.menu.draft.edge_scroll_enabled = false
	settings.menu.draft.fps_limit = 90
	settings.apply_preferences(settings.menu.draft)
	check(settings.resolve_key(key_event(KEY_J)) == KEY_F2 and settings.resolve_key(key_event(KEY_F2)) == KEY_NONE, "applied remapping replaces old aliases")
	check(Engine.max_fps == 90, "FPS preference is applied to the native engine")
	check(AudioServer.is_bus_mute(0) and absf(db_to_linear(AudioServer.get_bus_volume_db(0)) - 0.43) < 0.0001, "sound settings reach the real mixer")
	check(not settings.edge_scroll_enabled and is_equal_approx(settings.camera_speed, 1.65), "camera properties expose applied preferences")
	var saved := ConfigFile.new()
	check(saved.load(settings.settings_path) == OK and saved.get_value("settings", "fps_limit") == 90, "native preferences persist")
	check(saved.get_value("hotkeys", "rts_select_army") == [KEY_J], "hotkey list persists without losing types")
	var restored: GameSettings = load("res://scenes/settings_menu.tscn").instantiate()
	restored.settings_path = settings.settings_path
	root.add_child(restored)
	check(restored.bindings.rts_select_army == [KEY_J] and restored.muted and restored.fps_limit == 90, "a fresh native settings scene loads the saved configuration")
	restored.queue_free()
	await process_frame
	# Simulate the previous complete preferences file: keep custom controls and
	# audio, add the new cancel action, and migrate only the old pause defaults.
	saved.set_value("hotkeys", "rts_pause", [KEY_F5, KEY_P])
	saved.erase_section_key("hotkeys", "rts_cancel")
	check(saved.save(settings.settings_path) == OK, "legacy preference fixture saved in the isolated test path")
	var migrated: GameSettings = load("res://scenes/settings_menu.tscn").instantiate()
	migrated.settings_path = settings.settings_path
	root.add_child(migrated)
	check(migrated.bindings.rts_pause == [KEY_F5] and migrated.bindings.rts_cancel == [KEY_ESCAPE], "old F5/P default migrates while adding Esc cancellation")
	check(migrated.bindings.rts_select_army == [KEY_J] and migrated.muted and migrated.fps_limit == 90, "migration preserves unrelated player preferences and custom hotkeys")
	migrated.queue_free()
	await process_frame
	var before := settings.snapshot()
	var candidate := before.duplicate(true)
	candidate.resolution = Vector2i(1280, 720)
	candidate.volume_percent = 10.0
	settings.apply_preferences(candidate)
	check(not settings.display_timer.is_stopped() and settings.display_timer.wait_time == 15, "display changes start a bounded 15-second revert")
	check(settings.menu.get_node("DisplayConfirm").visible, "display confirmation blocks normal settings controls")
	paused = true
	settings.display_timer.start(0.05)
	await create_timer(0.12, true, false, true).timeout
	check(settings.resolution == before.resolution and settings.volume_percent == before.volume_percent, "timeout atomically restores previous display and other preferences")
	check(paused, "display rollback does not unpause the battle")
	paused = false
	settings.apply_preferences(candidate)
	settings.confirm_display()
	check(settings.resolution == Vector2i(1280,720) and settings.display_timer.is_stopped(), "explicit confirmation keeps new display settings")
	settings.menu.draft.camera_speed = 2.8
	settings.close_menu()
	check(not settings.is_open() and settings.camera_speed == before.camera_speed, "Cancel discards unapplied draft changes")
	settings.open_menu()
	settings.menu._restore_defaults()
	check(settings.menu.draft.bindings.rts_select_army == [KEY_F2, KEY_G] and settings.menu.draft.fps_limit == 120, "Restore Defaults restores all controls and aliases in the draft")
	settings.close_menu()
	var malformed := settings.defaults()
	malformed.camera_speed = NAN
	malformed.bindings.rts_stop = [KEY_F12]
	var sanitized := settings._sanitize(malformed)
	check(sanitized.camera_speed == 1.0 and sanitized.bindings.rts_stop == [KEY_S], "invalid config values cannot corrupt native input or camera speed")
	print("SETTINGS_RESULT ", checks, " checks / ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
