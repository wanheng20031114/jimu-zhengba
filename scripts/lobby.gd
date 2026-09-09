extends Node3D
## Native room controls; the persistent Session owns transport and scene changes.

const ENDPOINT_PATH: String = "res://data/relay_endpoint.json"
const PREFERENCES_PATH: String = "user://lobby_preferences.cfg"
const MODE_DESCRIPTIONS: Dictionary = {
	"1v1": "与一位电脑对手交锋。",
	"2v2": "与一位电脑盟友并肩，迎战两位对手。",
	"3v3": "三位将领组成联盟，在三条战线上协同进攻。",
	"4v4": "与三位电脑盟友协同作战，争夺四旗平原。",
	"2v2v2": "三支双人联盟争夺战场，消灭另外两个联盟。",
	"ffa": "八位将领各自为战，没有队友。成为最后的胜者。",
}
const MODE_BUTTONS: Dictionary = {
	"1v1": "Mode1v1", "2v2": "Mode2v2", "3v3": "Mode3v3",
	"4v4": "Mode4v4", "2v2v2": "Mode2v2v2", "ffa": "ModeFFA",
}
const ALLIANCE_NAMES: PackedStringArray = ["联盟一", "联盟二", "联盟三"]

var mode: String = "1v1"
var room: Dictionary = {}
var _pending_request: bool = false
var _transitioning: bool = false
var _entrance: Tween
var _panel_reveal: Tween
var _endpoint_port: int = 24571
var _pending_slots: Dictionary = {}
var _last_request: String = ""

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
		for flag: String in ["--capture", "--smoke-test", "--ui-smoke", "--2v2", "--3v3", "--4v4", "--2v2v2", "--ffa"]:
			if flag in arguments:
				var launch_mode: String = "1v1"
				for candidate: String in NetworkProtocol.MODES:
					if "--" + candidate in arguments:
						launch_mode = candidate
				call_deferred("_launch_compatibility_mode", launch_mode)
				return
	_load_preferences()
	set_mode("1v1")
	relay.room_changed.connect(_on_room_changed)
	relay.match_started.connect(_on_match_started)
	relay.connection_state_changed.connect(_on_connection_state_changed)
	relay.error_received.connect(_on_error_received)
	relay.event_received.connect(_on_relay_event)
	session.load_failed.connect(_on_load_failed)
	for owner: int in NetworkProtocol.MAX_PLAYERS:
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
	%SoloMenu.grab_focus()
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
	for candidate: String in MODE_BUTTONS:
		get_node("%" + MODE_BUTTONS[candidate]).set_pressed_no_signal(mode == candidate)
		get_node("%Online" + MODE_BUTTONS[candidate]).set_pressed_no_signal(mode == candidate)
	var map: MapDefinition = load(NetworkProtocol.map_path(mode))
	%MapTitle.text = map.display_name
	%MapDetail.text = "%d × %d   ·   %d 位将领" % [int(map.size.x), int(map.size.y), map.slots]
	%SoloDescription.text = MODE_DESCRIPTIONS[mode]
	%CreateRoom.text = "创建 %s 房间" % ("乱斗" if mode == "ffa" else mode)

func _on_mode_selected(value: String) -> void:
	if not _pending_request and room.is_empty():
		set_mode(value)

func _on_solo_start() -> void:
	if _transitioning:
		return
	_transitioning = true
	%SoloLoadMessage.text = "正在进入战场…"
	%SoloStart.disabled = true
	_save_preferences()
	# Cancel a pending handshake or leave an old room before the offline scene.
	# No network connection or reply is needed to start playing locally.
	if not room.is_empty():
		relay.leave_room()
	else:
		relay.disconnect_relay()
	if session.start_offline(mode) != OK:
		_transitioning = false
		%SoloStart.disabled = false

func _on_load_failed(detail: String) -> void:
	_transitioning = false
	%SoloStart.disabled = false
	%SoloLoadMessage.text = detail
	_set_message(detail, true)
	_refresh_request_buttons()

func _reveal_panel(panel: Control) -> void:
	if _panel_reveal != null:
		_panel_reveal.kill()
	panel.show()
	panel.modulate.a = 0.0
	_panel_reveal = create_tween()
	_panel_reveal.tween_property(panel, "modulate:a", 1.0, 0.20).set_trans(Tween.TRANS_SINE)

func _on_open_solo() -> void:
	if %OnlinePanel.visible:
		_on_close_multiplayer()
	_reveal_panel(%SoloPanel)
	%SoloStart.grab_focus()

func _on_close_solo() -> void:
	%SoloPanel.hide()
	%SoloMenu.grab_focus()

func _on_open_codex() -> void:
	%UnitCodex.open_codex()

func _on_close_codex() -> void:
	%Codex.grab_focus()

func _on_open_multiplayer() -> void:
	%SoloPanel.hide()
	_reveal_panel(%OnlinePanel)
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
	%SlotTimeout.stop()
	%OnlinePanel.hide()
	%Multiplayer.grab_focus()

func _on_create_room() -> void:
	if not _prepare_connection():
		return
	_last_request = "create"
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
	_last_request = "join"
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
	for button: String in MODE_BUTTONS.values():
		get_node("%" + button).disabled = _pending_request or not room.is_empty()
		get_node("%Online" + button).disabled = _pending_request or not room.is_empty()
	%ServerAddress.editable = not _pending_request
	%Nickname.editable = not _pending_request
	%InviteInput.editable = not _pending_request
	%CancelRequest.visible = _pending_request
	%RetryRequest.visible = not _pending_request and not _last_request.is_empty() and room.is_empty() and not message.text.is_empty()

func _on_cancel_request() -> void:
	_pending_request = false
	%RequestTimeout.stop()
	relay.disconnect_relay()
	_set_message("已取消连接，可以重新创建或加入房间。")
	_refresh_request_buttons()

func _on_retry_request() -> void:
	if _last_request == "join":
		_on_join_room()
	else:
		_on_create_room()

func _on_slot_timeout() -> void:
	if _pending_slots.is_empty():
		return
	_pending_slots.clear()
	_set_message("席位更新未获确认，请重试。", true)
	if not room.is_empty():
		_refresh_room_controls()

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
	%SlotTimeout.stop()
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
	%RoomMode.text = NetworkProtocol.MODES[room.mode].label + "   /   " + %MapTitle.text
	_set_message("")
	for owner: int in NetworkProtocol.MAX_PLAYERS:
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
		row.get_node("Name").text = ("保留空位" if slot.kind == "open" else "电脑将领 %d" % (owner + 1) if slot.kind == "bot" else slot.name) + (" · 你" if local else "")
		row.get_node("Name").tooltip_text = slot.name
		row.get_node("Kind").text = "添加电脑" if slot.kind == "open" else "移除电脑" if slot.kind == "bot" else "真人玩家"
		row.get_node("Kind").tooltip_text = "让电脑占用这个空位" if slot.kind == "open" else "腾出席位，让朋友加入" if slot.kind == "bot" else "不能替换已加入的真人"
		var team: OptionButton = row.get_node("Team")
		team.clear()
		if room.mode == "ffa":
			team.add_item("无队伍", int(slot.owner_id))
			team.select(0)
		else:
			for alliance: int in int(NetworkProtocol.MODES[room.mode].teams):
				team.add_item(ALLIANCE_NAMES[alliance], alliance)
			team.select(int(slot.team_id))
		team.disabled = not relay.is_host or room.mode == "ffa"
		var ally: bool = int(slot.team_id) == int(room.slots[relay.owner_id].team_id)
		row.get_node("Name").modulate = Color("79bcec") if local else Color("e5ca72") if ally else Color("e5a18f")
		if slot.kind == "open":
			row.get_node("Name").modulate = Color("a59a84")
		var state: Label = row.get_node("State")
		state.text = "不参战" if slot.kind == "open" else "电脑就绪" if slot.kind == "bot" else "连接中" if not slot.connected else "已就绪" if slot.ready else "未准备"
		state.modulate = Color("ddbf78") if slot.ready else Color("a59a84")
	%Ready.set_pressed_no_signal(bool(room.slots[relay.owner_id].ready))
	var participants: int = room.slots.filter(func(slot): return slot.kind != "open").size()
	var open_slots: int = room.slots.size() - participants
	if room.mode == "ffa":
		%TeamSummary.text = "%d 人乱斗 · %d 个空位 · 所有其他将领都是敌人" % [participants, open_slots]
	else:
		var alliances: PackedStringArray = []
		for alliance: int in int(NetworkProtocol.MODES[room.mode].teams):
			var members: int = 0
			for slot: Dictionary in room.slots:
				if slot.kind != "open" and int(slot.team_id) == alliance:
					members += 1
			alliances.append("%s %d 人" % [ALLIANCE_NAMES[alliance], members])
		%TeamSummary.text = "  /  ".join(alliances) + "  ·  %d 个空位" % open_slots
	if _pending_slots.is_empty():
		%SlotTimeout.stop()
	_refresh_room_controls()

func _refresh_room_controls() -> void:
	var in_lobby: bool = relay.connection_state == "lobby" and room.status == "lobby"
	%StartMatch.visible = relay.is_host
	%StartMatch.text = "正在进入战场…" if _pending_request else "开始 %s" % _actual_match_label()
	%Ready.visible = not relay.is_host
	%FillBots.visible = relay.is_host
	%FillBots.disabled = not in_lobby or not _pending_slots.is_empty() or not room.slots.any(func(slot): return slot.kind == "open")
	%Ready.disabled = not in_lobby
	%Ready.text = "取消准备" if %Ready.button_pressed else "准备就绪"
	var reason: String = _start_block_reason()
	%StartMatch.disabled = not in_lobby or not reason.is_empty() or not _pending_slots.is_empty() or _pending_request
	%RoomHint.text = reason if relay.is_host else "准备后等待房主开始。房间设置改变时需要重新准备。"
	if relay.is_host and reason.is_empty():
		%RoomHint.text = "参战玩家已就绪。空位将保留，各阵营人数可以不同。"
	if not _pending_slots.is_empty():
		%RoomHint.text = "正在更新席位…"
	for owner: int in room.slots.size():
		var row: HBoxContainer = rows.get_child(owner)
		row.get_node("Kind").disabled = not in_lobby or not relay.is_host or room.slots[owner].kind == "human" or _pending_slots.has(owner)
		row.get_node("Team").disabled = not in_lobby or not relay.is_host or room.mode == "ffa" or _pending_slots.has(owner)

func _actual_match_label() -> String:
	if room.mode == "ffa":
		return "%d 人乱斗" % room.slots.filter(func(slot): return slot.kind != "open").size()
	var numbers: PackedStringArray = []
	for alliance in int(NetworkProtocol.MODES[room.mode].teams):
		var members: int = room.slots.filter(func(slot): return slot.kind != "open" and int(slot.team_id) == alliance).size()
		if members > 0:
			numbers.append(str(members))
	return "v".join(numbers) + " 对战"

func _start_block_reason() -> String:
	var code: String = NetworkProtocol.room_start_error(room)
	var reasons: Dictionary = {
		"": "", "invalid_roster": "等待服务器更新完整席位。", "ffa_independent": "乱斗模式中每位将领独立作战。",
		"team_capacity": "单个阵营人数超过本模式上限，请调整阵营。", "human_host_required": "等待房主连接。",
		"opponents_required": "至少需要两个敌对阵营。邀请朋友，或为对手席位添加电脑。",
		"not_ready": "等待所有真人玩家准备就绪。", "disconnected": "等待断线玩家重新连接。",
	}
	assert(reasons.has(code), "Unhandled room start reason: " + code)
	return reasons[code]

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
	%SlotTimeout.start()
	_refresh_room_controls()

func _on_slot_team_selected(index: int, owner: int) -> void:
	if not _can_configure_slot(owner) or room.mode == "ffa" or index < 0 or index >= int(NetworkProtocol.MODES[room.mode].teams) or int(room.slots[owner].team_id) == index:
		return
	_request_slot_change(owner, room.slots[owner].kind, index)

func _on_ready_toggled(value: bool) -> void:
	if not room.is_empty() and not relay.is_host:
		relay.set_ready(value)

func _on_start_match() -> void:
	if not room.is_empty() and relay.connection_state == "lobby" and room.status == "lobby" and relay.is_host and _pending_slots.is_empty() and _start_block_reason().is_empty():
		%StartMatch.disabled = true
		_pending_request = true
		%RequestTimeout.start()
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
	%SlotTimeout.stop()
	%Room.hide()
	%Setup.show()
	_refresh_request_buttons()

func _on_match_started(config: Dictionary) -> void:
	if _transitioning:
		return
	_transitioning = true
	_save_preferences()
	if session.start_online(config) != OK:
		_transitioning = false

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
	if event.keycode == KEY_ESCAPE:
		if %UnitCodex.visible:
			%UnitCodex.close_codex()
		elif %OnlinePanel.visible:
			_on_close_multiplayer()
		elif %SoloPanel.visible:
			_on_close_solo()
		else:
			return
		get_viewport().set_input_as_handled()
