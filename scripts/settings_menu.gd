extends Control
## Saved native controls edit a draft. Apply is atomic; display changes require an in-game countdown.
var draft: Dictionary = {}
var rebinding_action := ""
var _refreshing := false
var _resolutions: Array[Vector2i] = []
@onready var settings: GameSettings = get_parent()
@onready var pages: Control = %Pages

func _ready() -> void:
	%WindowMode.add_item("窗口", 0)
	%WindowMode.add_item("无边框全屏", 1)
	%WindowMode.add_item("独占全屏", 2)
	for limit: int in GameSettings.FPS_OPTIONS:
		%FrameLimit.add_item("不限帧数" if limit == 0 else "%d FPS" % limit, limit)
	for tab: Button in %Categories.get_children():
		tab.pressed.connect(show_page.bind(String(tab.name)))
	%WindowMode.item_selected.connect(_option_changed.bind("window_mode"))
	%Resolution.item_selected.connect(_resolution_changed)
	%FrameLimit.item_selected.connect(_fps_changed)
	%Vsync.toggled.connect(_toggle_changed.bind("vsync"))
	%Mute.toggled.connect(_toggle_changed.bind("muted"))
	%EdgeScroll.toggled.connect(_toggle_changed.bind("edge_scroll_enabled"))
	%Volume.value_changed.connect(_slider_changed.bind("volume_percent"))
	%CameraSpeed.value_changed.connect(_slider_changed.bind("camera_speed"))
	%ZoomSpeed.value_changed.connect(_slider_changed.bind("zoom_speed"))
	for row: HBoxContainer in %HotkeyRows.get_children():
		row.get_node("Bind").pressed.connect(begin_rebind.bind(String(row.get_meta("action"))))
	%RestoreDefaults.pressed.connect(_restore_defaults)
	%Cancel.pressed.connect(settings.close_menu)
	%Close.pressed.connect(settings.close_menu)
	%Apply.pressed.connect(_apply.bind(false))
	%Done.pressed.connect(_apply.bind(true))
	%KeepDisplay.pressed.connect(settings.confirm_display)
	%RevertDisplay.pressed.connect(settings.revert_display)
	show_page("Graphics")

func refresh(values: Dictionary) -> void:
	_refreshing = true
	draft = values.duplicate(true)
	rebinding_action = ""
	%WindowMode.select(int(draft.window_mode))
	_resolutions = [Vector2i(1280,720), Vector2i(1600,900), Vector2i(1920,1080), Vector2i(2560,1440)]
	var current := DisplayServer.window_get_size()
	if current.x >= 960 and current.y >= 540 and current not in _resolutions: _resolutions.append(current)
	if draft.resolution not in _resolutions: _resolutions.append(draft.resolution)
	_resolutions.sort_custom(func(a: Vector2i, b: Vector2i): return a.x < b.x if a.x != b.x else a.y < b.y)
	%Resolution.clear()
	for value: Vector2i in _resolutions: %Resolution.add_item("%d × %d" % [value.x, value.y])
	%Resolution.select(_resolutions.find(draft.resolution))
	%FrameLimit.select(GameSettings.FPS_OPTIONS.find(int(draft.fps_limit)))
	%Vsync.set_pressed_no_signal(draft.vsync)
	%Mute.set_pressed_no_signal(draft.muted)
	%EdgeScroll.set_pressed_no_signal(draft.edge_scroll_enabled)
	%Volume.set_value_no_signal(draft.volume_percent)
	%CameraSpeed.set_value_no_signal(draft.camera_speed)
	%ZoomSpeed.set_value_no_signal(draft.zoom_speed)
	_update_labels()
	_update_hotkeys()
	%Status.text = "Esc 返回上层 · 对局中 %s 暂停 / 继续" % settings.hotkey_text("rts_pause")
	_refreshing = false

func _update_labels() -> void:
	%Vsync.text = "开启" if draft.vsync else "关闭"
	%Mute.text = "静音" if draft.muted else "声音开启"
	%EdgeScroll.text = "开启" if draft.edge_scroll_enabled else "关闭"
	%VolumeValue.text = "%d%%" % int(draft.volume_percent)
	%CameraValue.text = "%.2f ×" % float(draft.camera_speed)
	%ZoomValue.text = "%.2f ×" % float(draft.zoom_speed)

func _option_changed(index: int, key: String) -> void:
	if not _refreshing: draft[key] = index

func _resolution_changed(index: int) -> void:
	if not _refreshing: draft.resolution = _resolutions[index]

func _fps_changed(index: int) -> void:
	if not _refreshing: draft.fps_limit = GameSettings.FPS_OPTIONS[index]

func _toggle_changed(value: bool, key: String) -> void:
	if _refreshing: return
	draft[key] = value
	_update_labels()

func _slider_changed(value: float, key: String) -> void:
	if _refreshing: return
	draft[key] = value
	_update_labels()

func show_page(page: String) -> void:
	rebinding_action = ""
	for child: Control in pages.get_children(): child.visible = String(child.name) == page
	for category: Button in %Categories.get_children(): category.set_pressed_no_signal(String(category.name) == page)
	%SectionTitle.text = {"Graphics":"显示", "Audio":"声音", "Controls":"镜头与操作", "Hotkeys":"热键"}[page]
	%SectionHint.text = {"Graphics":"分辨率用于窗口尺寸或全屏 3D 渲染。", "Audio":"调节战场音效；当前版本不播放背景音乐。", "Controls":"镜头响应与窗口边缘移动。", "Hotkeys":"点击按键后重新绑定。Ctrl 建组，Shift 追加。"}[page]
	if not draft.is_empty(): _update_hotkeys()

func begin_rebind(action: String) -> void:
	rebinding_action = action
	_update_hotkeys()
	set_status("请按下「%s」的新按键；%s" % [GameSettings.ACTIONS[action][0], "Esc 可绑定取消，点击分类可退出捕获。" if action == "rts_cancel" else "Esc 取消绑定。"])

func _input(event: InputEvent) -> void:
	if not visible: return
	if event is InputEventKey and event.pressed and not event.echo:
		var pressed_key: Key = event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
		if rebinding_action.is_empty() and settings.resolve_key(event) == KEY_F5:
			settings.close_menu()
			get_viewport().set_input_as_handled()
			settings.pause_requested.emit()
			return
		if %DisplayConfirm.visible:
			if pressed_key == KEY_ESCAPE:
				settings.revert_display()
				get_viewport().set_input_as_handled()
			return
		if not rebinding_action.is_empty():
			if pressed_key == KEY_ESCAPE and rebinding_action != "rts_cancel":
				rebinding_action = ""
				set_status("已取消按键绑定。")
			else:
				var key: Key = event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
				var error := settings.binding_error(rebinding_action, key, draft.bindings)
				if event.ctrl_pressed or event.shift_pressed or event.alt_pressed or event.meta_pressed:
					error = "请使用单个按键，Ctrl / Shift 留作编队与连续指令。"
				if error.is_empty():
					draft.bindings[rebinding_action] = [int(key)]
					rebinding_action = ""
					set_status("按键已修改，应用后生效。")
				else: set_status(error)
			_update_hotkeys()
			get_viewport().set_input_as_handled()
			return
		if pressed_key == KEY_ESCAPE:
			settings.close_menu()
			get_viewport().set_input_as_handled()

func _update_hotkeys() -> void:
	for row: HBoxContainer in %HotkeyRows.get_children():
		var action: String = row.get_meta("action")
		var keys := PackedStringArray()
		for key: int in draft.bindings[action]: keys.append(OS.get_keycode_string(key))
		row.get_node("Bind").text = "等待按键…" if rebinding_action == action else " / ".join(keys)

func _restore_defaults() -> void:
	refresh(settings.defaults())
	set_status("默认设置已填入，应用后生效。")

func _apply(close_after: bool) -> void:
	rebinding_action = ""
	settings.apply_preferences(draft, close_after)

func set_status(message: String) -> void:
	%Status.text = message

func show_display_confirmation() -> void:
	%DisplayConfirm.show()
	%KeepDisplay.grab_focus()

func hide_display_confirmation() -> void:
	%DisplayConfirm.hide()

func _process(_delta: float) -> void:
	if %DisplayConfirm.visible:
		%DisplayCountdown.text = "是否保留当前显示设置？\n%d 秒后自动恢复。" % ceili(settings.display_timer.time_left)
