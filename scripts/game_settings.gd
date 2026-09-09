class_name GameSettings
extends CanvasLayer
## Native preferences shared by the lobby and battle. Opening this layer never pauses a match.
signal changed
signal opened
signal closed

const FPS_OPTIONS: Array[int] = [30, 60, 90, 120, 144, 165, 240, 0]
const ACTIONS := {
	"rts_attack_move": ["攻击前进", KEY_A, [KEY_A]], "rts_stop": ["停止", KEY_S, [KEY_S]],
	"rts_hold": ["坚守", KEY_H, [KEY_H]], "rts_select_base": ["选择大本营", KEY_B, [KEY_B, KEY_HOME]],
	"rts_select_army": ["选择全部战斗单位", KEY_F2, [KEY_F2, KEY_G]], "rts_focus": ["聚焦所选对象", KEY_SPACE, [KEY_SPACE]],
	"rts_slot_1": ["第一项生产 / 建造 / 研究", KEY_Q, [KEY_Q]], "rts_slot_2": ["第二项生产 / 建造 / 研究", KEY_W, [KEY_W]],
	"rts_slot_3": ["第三项生产 / 建造 / 研究", KEY_E, [KEY_E]], "rts_slot_4": ["第四项生产 / 建造 / 研究", KEY_R, [KEY_R]],
	"rts_slot_5": ["第五项生产 / 建造 / 研究", KEY_T, [KEY_T]], "rts_slot_6": ["第六项生产 / 建造 / 研究", KEY_Y, [KEY_Y]],
	"rts_build_tower": ["放置防御塔", KEY_V, [KEY_V]], "rts_destroy": ["删除所选己方资产", KEY_DELETE, [KEY_DELETE]],
	"rts_pause": ["暂停 / 继续", KEY_F5, [KEY_F5, KEY_P]], "rts_help": ["操作帮助", KEY_F1, [KEY_F1]],
	"rts_photo": ["隐藏 / 显示界面", KEY_F10, [KEY_F10]], "rts_fullscreen": ["切换全屏", KEY_F11, [KEY_F11]],
	"rts_mute": ["静音", KEY_M, [KEY_M]], "rts_idle_worker": ["选择空闲农民", KEY_PERIOD, [KEY_PERIOD]],
	"rts_cycle_buildings": ["切换编队中的建筑", KEY_TAB, [KEY_TAB]],
	"rts_group1": ["编队 1", KEY_1, [KEY_1]], "rts_group2": ["编队 2", KEY_2, [KEY_2]],
	"rts_group3": ["编队 3", KEY_3, [KEY_3]], "rts_group4": ["编队 4", KEY_4, [KEY_4]],
	"rts_group5": ["编队 5", KEY_5, [KEY_5]], "rts_group6": ["编队 6", KEY_6, [KEY_6]],
	"rts_group7": ["编队 7", KEY_7, [KEY_7]], "rts_group8": ["编队 8", KEY_8, [KEY_8]],
	"rts_group9": ["编队 9", KEY_9, [KEY_9]],
	"rts_pan_left": ["镜头向左", KEY_LEFT, [KEY_LEFT]], "rts_pan_right": ["镜头向右", KEY_RIGHT, [KEY_RIGHT]],
	"rts_pan_up": ["镜头向前", KEY_UP, [KEY_UP]], "rts_pan_down": ["镜头向后", KEY_DOWN, [KEY_DOWN]],
}

var settings_path := "user://settings.cfg"
var edge_scroll_enabled := true
var camera_speed := 1.0
var zoom_speed := 1.0
var volume_percent := 80.0
var muted := false
var window_mode := 0
var resolution := Vector2i(1600, 900)
var vsync := true
var fps_limit := 120
var bindings: Dictionary = {}
var _display_previous: Dictionary = {}
var _previous_window: Dictionary = {}
var _close_after_confirm := false
var _entrance: Tween

@onready var menu: Control = $Menu
@onready var display_timer: Timer = $DisplayRevertTimer

func _ready() -> void:
	menu.hide()
	var values := defaults()
	var config := ConfigFile.new()
	if config.load(settings_path) == OK:
		for key: String in values:
			if key != "bindings": values[key] = config.get_value("settings", key, values[key])
		for action: String in ACTIONS:
			values.bindings[action] = config.get_value("hotkeys", action, values.bindings[action])
	_apply_values(_sanitize(values), false)
	# Test/export automation owns its window. Real launches restore the user's display choice.
	if DisplayServer.get_name() != "headless" and not _automated_launch():
		_apply_display()
	display_timer.timeout.connect(revert_display)

func _automated_launch() -> bool:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	return args.has("--script") or args.has("--position") or args.has("--editor") or args.has("--capture") or args.has("--lobby-capture") or args.has("--network-smoke") or args.has("--match-smoke")

func defaults() -> Dictionary:
	var keys := {}
	for action: String in ACTIONS: keys[action] = ACTIONS[action][2].duplicate()
	return {"edge_scroll_enabled": true, "camera_speed": 1.0, "zoom_speed": 1.0,
		"volume_percent": 80.0, "muted": false, "window_mode": 0,
		"resolution": Vector2i(1600, 900), "vsync": true, "fps_limit": 120, "bindings": keys}

func snapshot() -> Dictionary:
	return {"edge_scroll_enabled": edge_scroll_enabled, "camera_speed": camera_speed, "zoom_speed": zoom_speed,
		"volume_percent": volume_percent, "muted": muted, "window_mode": window_mode,
		"resolution": resolution, "vsync": vsync, "fps_limit": fps_limit, "bindings": bindings.duplicate(true)}

func _sanitize(values: Dictionary) -> Dictionary:
	var result := defaults()
	for key: String in ["edge_scroll_enabled", "muted", "vsync"]:
		if values.get(key) is bool: result[key] = values[key]
	for key: String in ["camera_speed", "zoom_speed", "volume_percent"]:
		var value: Variant = values.get(key)
		if (value is float or value is int) and is_finite(float(value)):
			result[key] = clampf(float(value), 0.25 if key != "volume_percent" else 0.0, 3.0 if key != "volume_percent" else 100.0)
	if values.get("window_mode") is int and values.window_mode in [0, 1, 2]: result.window_mode = values.window_mode
	if values.get("fps_limit") is int and values.fps_limit in FPS_OPTIONS: result.fps_limit = values.fps_limit
	if values.get("resolution") is Vector2i:
		var requested: Vector2i = values.resolution
		if requested.x >= 960 and requested.y >= 540 and requested.x <= 7680 and requested.y <= 4320:
			result.resolution = requested
	# Accept a complete conflict-free key map. A corrupt preferences file uses known defaults.
	if values.get("bindings") is Dictionary:
		var candidate: Dictionary = values.bindings
		var used: Array[int] = []
		var valid := candidate.size() == ACTIONS.size()
		for action: String in ACTIONS:
			if not candidate.get(action) is Array or candidate[action].is_empty() or candidate[action].size() > 2:
				valid = false
				break
			for key: Variant in candidate[action]:
				if not key is int or key <= 0 or key in [KEY_ESCAPE, KEY_F12, KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META] or key in used:
					valid = false
					break
				used.append(key)
		if valid: result.bindings = candidate.duplicate(true)
	return result

func _apply_values(values: Dictionary, display: bool) -> void:
	for key: String in values: set(key, values[key])
	for action: String in ACTIONS:
		if not InputMap.has_action(action): InputMap.add_action(action)
		InputMap.action_erase_events(action)
		for key: int in bindings[action]:
			var event := InputEventKey.new()
			event.physical_keycode = key as Key
			InputMap.action_add_event(action, event)
	Engine.max_fps = fps_limit
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(volume_percent / 100.0, 0.0001)))
	AudioServer.set_bus_mute(0, muted)
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
		if display: _apply_display()
	changed.emit()

func _apply_display() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
	DisplayServer.window_set_size(resolution)
	var screen := DisplayServer.window_get_current_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	DisplayServer.window_set_position(usable.position + (usable.size - resolution).max(Vector2i.ZERO) / 2)
	if window_mode == 1: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif window_mode == 2: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
	# Fullscreen windows follow the monitor; this choice controls native 3D render resolution.
	var actual := DisplayServer.window_get_size()
	get_tree().root.scaling_3d_scale = minf(float(resolution.x) / maxf(actual.x, 1), float(resolution.y) / maxf(actual.y, 1)) if window_mode != 0 else 1.0

func resolve_key(event: InputEventKey) -> Key:
	var plain: InputEventKey = event.duplicate()
	if plain.physical_keycode == KEY_NONE: plain.physical_keycode = plain.keycode
	plain.ctrl_pressed = false
	plain.shift_pressed = false
	plain.alt_pressed = false
	plain.meta_pressed = false
	for action: String in ACTIONS:
		if InputMap.event_is_action(plain, action): return ACTIONS[action][1] as Key
	return KEY_NONE

func hotkey_text(action: String) -> String:
	var result := PackedStringArray()
	for key: int in bindings[action]: result.append(OS.get_keycode_string(key))
	return " / ".join(result)

func key_label(canonical: Key) -> String:
	for action: String in ACTIONS:
		if ACTIONS[action][1] == canonical: return hotkey_text(action)
	return OS.get_keycode_string(canonical)

func binding_error(action: String, key: Key, keys: Dictionary) -> String:
	if key in [KEY_ESCAPE, KEY_F12]: return "Esc 与 F12 是固定保留键。"
	if key in [KEY_NONE, KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]: return "请选择一个按键；Ctrl、Shift 保留用于组合指令。"
	for other: String in ACTIONS:
		if other != action and key in keys[other]: return "已用于「%s」，请先修改该操作的按键。" % ACTIONS[other][0]
	return ""

func open_menu() -> void:
	if is_open(): return
	menu.refresh(snapshot())
	menu.show()
	menu.modulate.a = 0.0
	_entrance = create_tween()
	_entrance.tween_property(menu, "modulate:a", 1.0, 0.16)
	opened.emit()

func close_menu() -> void:
	if not is_open(): return
	if not _display_previous.is_empty(): revert_display()
	if _entrance != null and _entrance.is_valid(): _entrance.kill()
	menu.hide()
	closed.emit()

func is_open() -> bool:
	return menu.visible

func apply_preferences(values: Dictionary, close_after: bool = false) -> void:
	if not _display_previous.is_empty(): return
	var candidate := _sanitize(values)
	var display_changed: bool = candidate.window_mode != window_mode or candidate.resolution != resolution
	_close_after_confirm = close_after
	if display_changed:
		_display_previous = snapshot()
		_previous_window = {"position": DisplayServer.window_get_position(), "size": DisplayServer.window_get_size(), "scale": get_tree().root.scaling_3d_scale}
	_apply_values(candidate, display_changed)
	if display_changed:
		display_timer.start(15.0)
		menu.show_display_confirmation()
	else:
		var error := _save()
		menu.refresh(snapshot())
		menu.set_status("设置已保存。" if error == OK else "设置保存失败，请检查目录写入权限。")
		if close_after and error == OK: close_menu()

func confirm_display() -> void:
	if _display_previous.is_empty(): return
	display_timer.stop()
	_display_previous.clear()
	_previous_window.clear()
	var error := _save()
	menu.hide_display_confirmation()
	menu.refresh(snapshot())
	if error != OK: menu.set_status("设置保存失败，请检查目录写入权限。")
	if _close_after_confirm and error == OK: close_menu()

func revert_display() -> void:
	if _display_previous.is_empty(): return
	display_timer.stop()
	_apply_values(_display_previous, true)
	if DisplayServer.get_name() != "headless" and window_mode == 0:
		DisplayServer.window_set_size(_previous_window.size)
		DisplayServer.window_set_position(_previous_window.position)
		get_tree().root.scaling_3d_scale = _previous_window.scale
	_display_previous.clear()
	_previous_window.clear()
	menu.hide_display_confirmation()
	menu.refresh(snapshot())
	menu.set_status("已恢复先前设置。")

func _save() -> Error:
	var config := ConfigFile.new()
	var values := snapshot()
	for key: String in values:
		if key != "bindings": config.set_value("settings", key, values[key])
	for action: String in bindings: config.set_value("hotkeys", action, bindings[action])
	var error := config.save(settings_path)
	if error != OK: menu.set_status("设置保存失败，请检查目录写入权限。")
	return error

func set_volume_percent(value: float) -> void:
	volume_percent = clampf(value, 0, 100)
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(volume_percent / 100.0, 0.0001)))
	_save()
	changed.emit()

func set_muted(value: bool) -> void:
	muted = value
	AudioServer.set_bus_mute(0, value)
	_save()
	changed.emit()

func toggle_fullscreen() -> void:
	# A deliberate hotkey toggles the remembered mode through the same native
	# display application as the settings page, keeping the two interfaces in sync.
	window_mode = 1 if window_mode == 0 else 0
	if DisplayServer.get_name() != "headless":
		_apply_display()
	_save()
	changed.emit()
