extends Node3D
## Native room controls; the persistent Session owns transport and scene changes.

const ENDPOINT_PATH: String = "res://data/relay_endpoint.json"
const PREFERENCES_PATH: String = "user://lobby_preferences.cfg"
const MAPS := {
	"1v1": preload("res://data/maps/amber_crossroads_1v1.tres"),
	"2v2": preload("res://data/maps/twin_valleys_2v2.tres"),
}
const MODE_INFO: Dictionary = {
	"1v1": ["琥珀十字路", "与一位电脑对手交锋。", "96 × 96   ·   六座矿脉"],
	"2v2": ["双谷盟约", "与电脑盟友并肩，迎战两位对手。", "128 × 112   ·   十座矿脉"],
}

var mode: String = "1v1"
var room: Dictionary = {}
var _pending_request: bool = false
var _transitioning: bool = false
var _entrance: Tween
var _panel_reveal: Tween
var _endpoint_port: int = 24571
var _pending_slots: Dictionary = {}

@onready var session: Node = get_node("/root/Session")
@onready var relay: RelayClient = session.relay
@onready var connection_status: Label = %ConnectionStatus
@onready var message: Label = %Message
@onready var rows: VBoxContainer = %Slots

func _ready() -> void:
	get_tree().auto_accept_quit = true
	%Version.text = "v%s   /   即时战略" % NetworkProtocol.BUILD_ID
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	if "--lobby-capture" not in arguments:
		for flag: String in ["--capture", "--smoke-test", "--ui-smoke", "--2v2"]:
			if flag in arguments:
				call_deferred("_launch_compatibility_mode", "2v2" if "--2v2" in arguments else "1v1")
				return
	_load_preferences()
	set_mode("1v1")
	relay.room_changed.connect(_on_room_changed)
	relay.match_started.connect(_on_match_started)
	relay.connection_state_changed.connect(_on_connection_state_changed)
	relay.error_received.connect(_on_error_received)
	relay.event_received.connect(_on_relay_event)
	for owner: int in 4:
		var row: HBoxContainer = rows.get_child(owner)
		row.get_node("Kind").pressed.connect(_on_slot_bot_pressed.bind(owner))
		row.get_node("Team").item_selected.connect(_on_slot_team_selected.bind(owner))
	if not relay.room.is_empty():
		_on_room_changed(relay.room)
	_on_connection_state_changed(relay.connection_state)
	%Brand.modulate.a = 0.0
	%MainMenu.modulate.a = 0.0
	_entrance = create_tween().set_parallel(true)
	_entrance.tween_property(%Brand, "modulate:a", 1.0, 0.48).set_trans(Tween.TRANS_SINE)
	_entrance.tween_property(%MainMenu, "modulate:a", 1.0, 0.48).set_delay(0.12).set_trans(Tween.TRANS_SINE)
	%SoloStart.grab_focus()
	if "--lobby-capture" in arguments:
		call_deferred("_capture_lobby")

func _launch_compatibility_mode(value: String) -> void:
	_transitioning = true
	session.start_offline(value)

func _capture_lobby() -> void:
	await get_tree().create_timer(0.85).timeout
	await RenderingServer.frame_post_draw
	var target: String = "res://artifacts/lobby.png" if OS.has_feature("editor") else "user://lobby.png"
	var capture: Image = get_viewport().get_texture().get_image()
	var error: Error = capture.save_png(target)
	if error != OK:
		push_error("Lobby capture failed: %s" % error_string(error))
		get_tree().quit(1)
		return
	print("LOBBY_CAPTURE ", target)
	get_tree().quit()

func set_mode(value: String) -> void:
	mode = value
	%Mode1v1.set_pressed_no_signal(mode == "1v1")
	%Mode2v2.set_pressed_no_signal(mode == "2v2")
	%OnlineMode1v1.set_pressed_no_signal(mode == "1v1")
	%OnlineMode2v2.set_pressed_no_signal(mode == "2v2")
	%MapTitle.text = MAPS[mode].display_name
	%MapDetail.text = MODE_INFO[mode][2]
	%SoloDescription.text = MODE_INFO[mode][1]
	%CreateRoom.text = "创建 " + mode + " 房间"

func _on_mode_1v1() -> void:
	if not _pending_request and room.is_empty():
		set_mode("1v1")

func _on_mode_2v2() -> void:
	if not _pending_request and room.is_empty():
		set_mode("2v2")

func _on_solo_start() -> void:
	if _transitioning:
		return
	_transitioning = true
	_save_preferences()
	# Cancel a pending handshake or leave an old room before the offline scene.
	# No network connection or reply is needed to start playing locally.
	if not room.is_empty():
		relay.leave_room()
	else:
		relay.disconnect_relay()
	session.start_offline(mode)

func _on_open_multiplayer() -> void:
	%OnlinePanel.show()
	if _panel_reveal != null:
		_panel_reveal.kill()
	%OnlinePanel.modulate.a = 0.0
	_panel_reveal = create_tween()
	_panel_reveal.tween_property(%OnlinePanel, "modulate:a", 1.0, 0.20)
	if room.is_empty():
		%Nickname.grab_focus()

func _on_close_multiplayer() -> void:
	if not room.is_empty() or _pending_request:
		relay.leave_room()
		relay.disconnect_relay()
		room.clear()
		_pending_request = false
		%RequestTimeout.stop()
		_show_setup()
	%OnlinePanel.hide()
	%Multiplayer.grab_focus()

func _on_create_room() -> void:
	if not _prepare_connection():
		return
	relay.create_room(mode, %Nickname.text)
	_set_message("正在创建房间…")

func _on_join_room() -> void:
	var code: String = %InviteInput.text.strip_edges().to_upper()
	if code.length() != 8:
		_set_message("请输入八位房间邀请码。", true)
		%InviteInput.grab_focus()
		return
	for character: String in code:
		if not "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".contains(character):
			_set_message("邀请码由八位大写字母和数字组成。", true)
			return
	if not _prepare_connection():
		return
	%InviteInput.text = code
	relay.join_room(code, %Nickname.text)
	_set_message("正在加入房间…")

func _on_invite_submitted(_text: String) -> void:
	_on_join_room()

func _on_setup_edited(_text: String) -> void:
	if not _pending_request:
		_set_message("")

func _prepare_connection() -> bool:
	if _pending_request or not room.is_empty():
		return false
	var address: String = %ServerAddress.text.strip_edges()
	if address.is_empty():
		_set_message("请填写房间服务器地址。", true)
		%ServerAddress.grab_focus()
		return false
	if %Nickname.text.strip_edges().is_empty():
		%Nickname.text = "指挥官"
	_save_preferences()
	if relay.connection_state != "connected" or relay.address != address or relay.port != _endpoint_port:
		var error: Error = relay.connect_relay(address, _endpoint_port)
		if error != OK:
			_set_message("无法连接房间服务器，请检查地址后重试。", true)
			return false
	_pending_request = true
	%RequestTimeout.start()
	_refresh_request_buttons()
	return true

func _on_request_timeout() -> void:
	if not _pending_request:
		return
	_pending_request = false
	relay.disconnect_relay()
	_set_message("服务器暂未回应。可以重试，或立即开始单人对战。", true)
	_refresh_request_buttons()

func _refresh_request_buttons() -> void:
	%CreateRoom.disabled = _pending_request
	%JoinRoom.disabled = _pending_request
	%Mode1v1.disabled = _pending_request or not room.is_empty()
	%Mode2v2.disabled = _pending_request or not room.is_empty()
	%OnlineMode1v1.disabled = %Mode1v1.disabled
	%OnlineMode2v2.disabled = %Mode2v2.disabled
	%ServerAddress.editable = not _pending_request
	%Nickname.editable = not _pending_request
	%InviteInput.editable = not _pending_request

func _on_connection_state_changed(state: String) -> void:
	var labels: Dictionary = {
		"disconnected": "尚未连接", "connecting": "连接中…", "connected": "服务器已连接",
		"lobby": "房间已连接", "reconnecting": "正在重连…", "match": "正在进入战场…",
		"host_paused": "等待房主重连", "finished": "对局已结束", "error": "连接失败",
	}
	connection_status.text = labels.get(state, "连接中…")
	if state in ["disconnected", "error", "finished"]:
		_pending_request = false
		%RequestTimeout.stop()
		if not room.is_empty() and relay.room.is_empty():
			room.clear()
			_show_setup()
	_refresh_request_buttons()
	if not room.is_empty():
		_refresh_room_controls()

func _on_error_received(_code: String, detail: String) -> void:
	_pending_request = false
	_pending_slots.clear()
	%RequestTimeout.stop()
	_set_message(detail, true)
	_refresh_request_buttons()
	if not room.is_empty():
		_refresh_room_controls()

func _on_relay_event(event: Dictionary) -> void:
	if event.get("kind") == "match_aborted" and not _transitioning:
		relay.leave_room()
		room.clear()
		_show_setup()
		_set_message(event.get("message", "房间已关闭。"), true)

func _on_room_changed(value: Dictionary) -> void:
	room = value.duplicate(true)
	_pending_request = false
	%RequestTimeout.stop()
	_refresh_request_buttons()
	%Setup.hide()
	%Room.show()
	%OnlinePanel.show()
	set_mode(room.mode)
	%InviteCode.text = room.code
	%RoomMode.text = room.mode + "   /   " + MAPS[room.mode].display_name
	_set_message("")
	for owner: int in 4:
		var row: HBoxContainer = rows.get_child(owner)
		row.visible = owner < room.slots.size()
		if not row.visible:
			continue
		var slot: Dictionary = room.slots[owner]
		if _pending_slots.has(owner):
			var desired: Dictionary = _pending_slots[owner]
			if slot.kind == desired.kind and int(slot.team_id) == int(desired.team):
				_pending_slots.erase(owner)
		var local: bool = int(slot.owner_id) == relay.owner_id
		row.get_node("Name").text = ("电脑将领 %d" % (owner + 1) if slot.kind == "bot" else slot.name) + (" · 你" if local else "")
		row.get_node("Name").tooltip_text = slot.name
		row.get_node("Kind").text = "添加电脑" if slot.kind == "open" else "移除电脑" if slot.kind == "bot" else "真人玩家"
		row.get_node("Kind").tooltip_text = "让电脑占用这个空位" if slot.kind == "open" else "腾出席位，让朋友加入" if slot.kind == "bot" else "不能替换已加入的真人"
		row.get_node("Team").select(int(slot.team_id))
		row.get_node("Team").disabled = not relay.is_host
		var state: Label = row.get_node("State")
		state.text = "等待加入" if slot.kind == "open" else "电脑就绪" if slot.kind == "bot" else "连接中" if not slot.connected else "已就绪" if slot.ready else "未准备"
		state.modulate = Color("ddbf78") if slot.ready else Color("a59a84")
	%Ready.set_pressed_no_signal(bool(room.slots[relay.owner_id].ready))
	var team_seats: Array[PackedStringArray] = [PackedStringArray(), PackedStringArray()]
	for slot: Dictionary in room.slots:
		team_seats[int(slot.team_id)].append(str(int(slot.owner_id) + 1))
	%TeamSummary.text = "联盟一：席位 %s    对阵    联盟二：席位 %s" % ["、".join(team_seats[0]), "、".join(team_seats[1])]
	_refresh_room_controls()

func _refresh_room_controls() -> void:
	var in_lobby: bool = relay.connection_state == "lobby" and room.status == "lobby"
	%StartMatch.visible = relay.is_host
	%StartMatch.text = "开始 %s 对战" % room.mode
	%Ready.visible = not relay.is_host
	%FillBots.visible = relay.is_host
	%FillBots.disabled = not in_lobby or not _pending_slots.is_empty() or not room.slots.any(func(slot): return slot.kind == "open")
	%Ready.disabled = not in_lobby
	%Ready.text = "取消准备" if %Ready.button_pressed else "准备就绪"
	var reason: String = _start_block_reason()
	%StartMatch.disabled = not in_lobby or not reason.is_empty() or not _pending_slots.is_empty()
	%RoomHint.text = reason if relay.is_host else "准备后等待房主开始。房间设置改变时需要重新准备。"
	if relay.is_host and reason.is_empty():
		%RoomHint.text = "所有席位已就绪，可以开始对战。电脑由房主模拟，无需其他真人加入。"
	if not _pending_slots.is_empty():
		%RoomHint.text = "正在更新席位…"
	for owner: int in room.slots.size():
		var row: HBoxContainer = rows.get_child(owner)
		row.get_node("Kind").disabled = not in_lobby or not relay.is_host or room.slots[owner].kind == "human" or _pending_slots.has(owner)
		row.get_node("Team").disabled = not in_lobby or not relay.is_host or _pending_slots.has(owner)

func _start_block_reason() -> String:
	var teams: Array[int] = [0, 0]
	for slot: Dictionary in room.slots:
		if slot.kind == "open":
			return "等待朋友加入，或点击空位的“添加电脑”。也可以一键补齐电脑。"
		teams[int(slot.team_id)] += 1
		if slot.kind == "human" and (not slot.connected or not slot.ready):
			return "等待所有玩家准备就绪。"
	if teams[0] != teams[1]:
		return "请将两个联盟设置为相同人数。"
	return ""

func _on_slot_bot_pressed(owner: int) -> void:
	if not _can_configure_slot(owner) or room.slots[owner].kind == "human":
		return
	_request_slot_change(owner, "bot" if room.slots[owner].kind == "open" else "open", int(room.slots[owner].team_id))

func _on_fill_bots() -> void:
	if room.is_empty() or not relay.is_host or not _pending_slots.is_empty():
		return
	for owner: int in room.slots.size():
		if room.slots[owner].kind == "open" and _can_configure_slot(owner):
			_request_slot_change(owner, "bot", int(room.slots[owner].team_id))

func _can_configure_slot(owner: int) -> bool:
	return relay.is_host and not room.is_empty() and relay.connection_state == "lobby" and room.status == "lobby" and owner >= 0 and owner < room.slots.size() and not _pending_slots.has(owner)

func _request_slot_change(owner: int, kind: String, team: int) -> void:
	_pending_slots[owner] = {"kind": kind, "team": team}
	relay.configure_slot(owner, kind, team)
	_refresh_room_controls()

func _on_slot_team_selected(index: int, owner: int) -> void:
	if not _can_configure_slot(owner) or index not in [0, 1] or int(room.slots[owner].team_id) == index:
		return
	_request_slot_change(owner, room.slots[owner].kind, index)

func _on_ready_toggled(value: bool) -> void:
	if not room.is_empty() and not relay.is_host:
		relay.set_ready(value)

func _on_start_match() -> void:
	if not room.is_empty() and relay.connection_state == "lobby" and room.status == "lobby" and relay.is_host and _pending_slots.is_empty() and _start_block_reason().is_empty():
		%StartMatch.disabled = true
		relay.start_match()

func _on_copy_invite() -> void:
	if not room.is_empty():
		DisplayServer.clipboard_set(room.code)
		_set_message("邀请码已复制。")

func _on_leave_room() -> void:
	relay.leave_room()
	room.clear()
	_show_setup()
	_set_message("已离开房间。")

func _show_setup() -> void:
	_pending_slots.clear()
	%Room.hide()
	%Setup.show()
	_refresh_request_buttons()

func _on_match_started(config: Dictionary) -> void:
	if _transitioning:
		return
	_transitioning = true
	_save_preferences()
	session.start_online(config)

func _set_message(text: String, error: bool = false) -> void:
	message.text = text
	message.modulate = Color("e7b89b") if error else Color("d8c99f")

func _load_preferences() -> void:
	if FileAccess.file_exists(ENDPOINT_PATH):
		var endpoint: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(ENDPOINT_PATH))
		%ServerAddress.text = endpoint.address
		_endpoint_port = int(endpoint.port)
	var preferences := ConfigFile.new()
	if preferences.load(PREFERENCES_PATH) == OK:
		%Nickname.text = preferences.get_value("lobby", "nickname", "指挥官")
		%ServerAddress.text = preferences.get_value("lobby", "address", %ServerAddress.text)

func _save_preferences() -> void:
	var preferences := ConfigFile.new()
	preferences.set_value("lobby", "nickname", %Nickname.text.strip_edges())
	preferences.set_value("lobby", "address", %ServerAddress.text.strip_edges())
	preferences.save(PREFERENCES_PATH)

func _on_settings() -> void:
	session.settings.open_menu()

func _on_quit_game() -> void:
	if _transitioning: return
	_transitioning = true
	_save_preferences()
	relay.leave_room()
	relay.disconnect_relay()
	get_tree().quit()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo or session.settings.is_open(): return
	if event.keycode == KEY_ESCAPE and %OnlinePanel.visible:
		_on_close_multiplayer()
		get_viewport().set_input_as_handled()
