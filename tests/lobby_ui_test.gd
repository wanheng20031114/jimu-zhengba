extends SceneTree
## Real native mouse input, saved controls and deterministic transport signals.
## No external connection or desktop clipboard mutation is needed by this test.

class FakeRelay extends RelayClient:
	var calls: Array[Dictionary] = []
	func _ready() -> void:
		pass
	func _process(_delta: float) -> void:
		pass
	func connect_relay(endpoint: String, endpoint_port: int = 24571) -> Error:
		address = endpoint
		port = endpoint_port
		_set_state("connecting")
		calls.append({"op": "connect", "address": endpoint})
		return OK
	func create_room(value: String, nickname: String = "指挥官") -> void:
		calls.append({"op": "create", "mode": value, "nickname": nickname})
	func join_room(code: String, nickname: String = "指挥官") -> void:
		calls.append({"op": "join", "code": code, "nickname": nickname})
	func configure_slot(owner: int, kind: String, team: int) -> void:
		calls.append({"op": "slot", "owner": owner, "kind": kind, "team": team})
	func set_ready(value: bool) -> void:
		calls.append({"op": "ready", "value": value})
	func start_match() -> void:
		calls.append({"op": "start"})
	func leave_room() -> void:
		calls.append({"op": "leave"})
		room.clear()
		_set_state("connected")
	func disconnect_relay() -> void:
		calls.append({"op": "disconnect"})
		room.clear()
		_set_state("disconnected")

class FakeSession extends Node:
	var relay: FakeRelay
	var offline_modes: Array[String] = []
	var online_matches: Array[Dictionary] = []
	func start_offline(mode: String) -> void:
		offline_modes.append(mode)
	func start_online(config: Dictionary) -> void:
		online_matches.append(config)

var checks: int = 0
var failures: Array[String] = []
var lobby: Node3D
var fake: FakeSession
var visual: bool = false

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		printerr("FAIL ", message)

func control(name: String) -> Control:
	return lobby.get_node("%" + name)

func click(target: Control) -> void:
	var center: Vector2 = target.get_global_rect().get_center()
	var move := InputEventMouseMotion.new()
	move.position = center
	root.push_input(move, true)
	for pressed: bool in [true, false]:
		var button := InputEventMouseButton.new()
		button.position = center
		button.button_index = MOUSE_BUTTON_LEFT
		button.pressed = pressed
		root.push_input(button, true)
	await process_frame

func room_state(mode: String = "2v2") -> Dictionary:
	var slots: Array = []
	for owner: int in int(NetworkProtocol.MODES[mode].slots):
		slots.append({"owner_id": owner, "team_id": NetworkProtocol.default_alliance(mode, owner),
			"kind": "human" if owner in [0, 2] else "bot", "name": "指挥官" if owner == 0 else "远征盟友" if owner == 2 else "王国将领",
			"ready": true, "connected": owner in [0, 2], "bot_takeover": false})
	return {"code": "ABCD2345", "mode": mode, "status": "lobby", "host_owner": 0, "slots": slots}

func publish_room(state: Dictionary, owner: int = 0) -> void:
	fake.relay.owner_id = owner
	fake.relay.is_host = owner == 0
	fake.relay.room = state.duplicate(true)
	fake.relay._set_state("lobby")
	fake.relay.room_changed.emit(state)
	await process_frame

func capture(name: String) -> void:
	if not visual:
		return
	await RenderingServer.frame_post_draw
	var picture: Image = root.get_texture().get_image()
	check(picture.save_png("res://artifacts/" + name + ".png") == OK, "saved native rendered " + name)

func _run() -> void:
	root.size = Vector2i(1600, 900)
	visual = "--lobby-visual" in OS.get_cmdline_user_args()
	var preference_path: String = "user://lobby_preferences.cfg"
	var had_preferences: bool = FileAccess.file_exists(preference_path)
	var preferences: String = FileAccess.get_file_as_string(preference_path) if had_preferences else ""
	var original_session: Node = root.get_node_or_null("Session")
	if original_session != null:
		original_session.name = "OriginalSession"
	fake = FakeSession.new()
	fake.name = "Session"
	fake.relay = FakeRelay.new()
	fake.add_child(fake.relay)
	root.add_child(fake)
	var previous_limit: int = Engine.max_fps
	lobby = load("res://scenes/lobby.tscn").instantiate()
	root.add_child(lobby)
	current_scene = lobby
	for index: int in 3:
		await process_frame
	if visual:
		await create_timer(0.75).timeout
	check(lobby.mode == "1v1", "default mode is the immediate one-versus-bot game")
	check(control("Version").text.begins_with("v" + NetworkProtocol.BUILD_ID), "lobby version follows the actual network build")
	check(Engine.max_fps == previous_limit, "lobby retains the player chosen frame limit")
	check(not control("OnlinePanel").visible, "initial canvas gives the local match one clear primary action")
	check(control("Slots").get_child_count() == NetworkProtocol.MAX_PLAYERS, "room owns six saved native slot rows")
	await capture("lobby-home")
	await click(control("Mode2v2"))
	check(lobby.mode == "2v2" and control("MapTitle").text == "双谷争锋", "native mode input uses the authoritative map resource title")
	check(control("OnlineMode2v2").button_pressed, "main mode selection also updates the multiplayer scale selector")
	await click(control("Multiplayer"))
	check(control("OnlinePanel").visible and control("Setup").visible, "native multiplayer click reveals setup")
	if visual:
		await create_timer(0.25).timeout
	await click(control("OnlineMode1v1"))
	check(lobby.mode == "1v1" and control("Mode1v1").button_pressed, "multiplayer panel can choose 1v1 without returning to main menu")
	await click(control("OnlineMode2v2"))
	check(lobby.mode == "2v2" and control("CreateRoom").text.contains("2v2"), "multiplayer panel can explicitly create a four seat room")
	control("ServerAddress").text = ""
	await click(control("CreateRoom"))
	check(fake.relay.calls.is_empty() and not control("Message").text.is_empty(), "missing address is actionable and does not start a connection")
	control("ServerAddress").text = "127.0.0.1"
	control("Nickname").text = "大厅测试将领"
	await capture("lobby-network")
	await click(control("CreateRoom"))
	check(fake.relay.calls.size() == 2 and fake.relay.calls[-1].mode == "2v2", "create sends the selected mode after beginning the native relay handshake")
	check(control("CreateRoom").disabled and control("JoinRoom").disabled, "pending create prevents duplicate requests")
	await click(control("CreateRoom"))
	check(fake.relay.calls.size() == 2, "repeated native click cannot create a second request")
	fake.relay.error_received.emit("capacity", "当前房间已满，请稍后重试")
	check(not control("CreateRoom").disabled and control("Message").text.contains("已满"), "relay error restores retry controls and preserves its actionable explanation")
	var state: Dictionary = room_state()
	state.slots[3].kind = "open"
	state.slots[3].ready = false
	state.slots[3].name = "空位"
	await publish_room(state)
	check(control("Room").visible and not control("Setup").visible, "room state replaces setup with actual membership")
	check(control("Mode1v1").disabled and lobby.mode == state.mode, "joined room owns its fixed mode until leaving")
	check(control("InviteCode").text == "ABCD2345", "room invitation is shown for copying")
	check(control("StartMatch").disabled and control("RoomHint").text.contains("空位"), "host cannot launch a match with an open seat")
	var row: HBoxContainer = control("Slots").get_child(3)
	var kind: Button = row.get_node("Kind")
	check(kind.text == "添加电脑" and not kind.disabled, "empty seat has a directly visible add bot action")
	await click(kind)
	check(fake.relay.calls[-1] == {"op": "slot", "owner": 3, "kind": "bot", "team": 1}, "host add bot preserves the slot alliance")
	var pending_count: int = fake.relay.calls.size()
	await click(kind)
	check(fake.relay.calls.size() == pending_count and kind.disabled, "pending add bot prevents duplicate native input")
	check(control("Slots").get_child(0).get_node("Kind").disabled, "occupied human seat cannot become a bot")
	state.slots[3].kind = "bot"
	state.slots[3].ready = true
	await publish_room(state)
	check(kind.text == "移除电脑" and not kind.disabled, "server confirmed bot has a direct remove action")
	await click(kind)
	check(fake.relay.calls[-1] == {"op": "slot", "owner": 3, "kind": "open", "team": 1}, "remove bot reopens the same seat")
	state.slots[3].kind = "open"
	state.slots[3].ready = false
	await publish_room(state)
	await click(control("FillBots"))
	check(fake.relay.calls[-1] == {"op": "slot", "owner": 3, "kind": "bot", "team": 1}, "fill bots only touches open seats and retains both humans")
	state.slots[3].kind = "bot"
	state.slots[3].ready = true
	await publish_room(state)
	check(control("FillBots").disabled and lobby._pending_slots.is_empty(), "acknowledged complete room has no pending or refill action")
	check(control("TeamSummary").text.contains("1、2") and control("TeamSummary").text.contains("3、4"), "default two versus two alliances are explicit in the room")
	var team: OptionButton = control("Slots").get_child(1).get_node("Team")
	team.select(1)
	team.item_selected.emit(1)
	check(fake.relay.calls[-1] == {"op": "slot", "owner": 1, "kind": "bot", "team": 1}, "host alliance selector preserves the slot controller")
	state.slots[1].team_id = 1
	await publish_room(state)
	state = room_state()
	state.slots[2].ready = false
	await publish_room(state)
	check(control("StartMatch").disabled and control("RoomHint").text.contains("准备"), "unready human blocks host launch")
	state.slots[2].ready = true
	state.slots[3].team_id = 0
	await publish_room(state)
	check(control("StartMatch").disabled and control("RoomHint").text.contains("相同人数"), "unbalanced alliances cannot launch")
	state.slots[3].team_id = 1
	await publish_room(state)
	check(not control("StartMatch").disabled and not control("Ready").visible, "ready balanced host room exposes the start action")
	await capture("lobby-room-host")
	await click(control("StartMatch"))
	check(fake.relay.calls[-1].op == "start", "native start forwards one authoritative room request")
	await publish_room(state, 2)
	check(control("Ready").visible and not control("StartMatch").visible, "guest receives readiness controls rather than host actions")
	check(not control("FillBots").visible, "guest cannot invoke host bulk bot controls")
	var guest_readonly: bool = true
	for slot_row: HBoxContainer in control("Slots").get_children():
		if slot_row.visible:
			guest_readonly = guest_readonly and slot_row.get_node("Kind").disabled and slot_row.get_node("Team").disabled
	check(guest_readonly, "all four guest slot configuration rows are read-only")
	await click(control("Ready"))
	check(fake.relay.calls[-1] == {"op": "ready", "value": false}, "native guest ready toggle forwards desired readiness")
	fake.relay.connection_state = "reconnecting"
	fake.relay.connection_state_changed.emit("reconnecting")
	check(control("Ready").disabled and control("ConnectionStatus").text.contains("重连"), "temporary disconnect disables stale room controls")
	fake.relay.event_received.emit({"kind": "match_aborted", "message": "房主已离开"})
	check(control("Setup").visible and control("Message").text == "房主已离开", "room closure returns to setup with the server reason")
	control("InviteInput").text = "abc"
	var previous_calls: int = fake.relay.calls.size()
	await click(control("JoinRoom"))
	check(fake.relay.calls.size() == previous_calls, "invalid invitation does not send a join")
	control("InviteInput").text = "abc23456"
	await click(control("JoinRoom"))
	check(fake.relay.calls[-1].op == "join" and fake.relay.calls[-1].code == "ABC23456", "invite join normalizes a valid lowercase code")
	lobby.get_node("%RequestTimeout").timeout.emit()
	check(not control("JoinRoom").disabled and control("Message").text.contains("暂未回应"), "request timeout stops the pending transport and restores retry")
	await publish_room(room_state("1v1"))
	check(not control("Slots").get_child(2).visible and not control("Slots").get_child(3).visible, "one-versus-one hides unused saved slots")
	# Every added mode is selected through native buttons, then driven by the
	# same authoritative room state that the real relay broadcasts.
	for new_mode: String in ["3v3", "2v2v2", "ffa"]:
		await click(control("LeaveRoom"))
		var suffix: String = "FFA" if new_mode == "ffa" else new_mode
		await click(control("OnlineMode" + suffix))
		check(lobby.mode == new_mode and control("Mode" + suffix).button_pressed, new_mode + " native selectors stay in sync")
		var config: Dictionary = load("res://scripts/session.gd").offline_config(new_mode)
		check(config.players.size() == 6 and config.players.filter(func(player): return player.controller == "bot").size() == 5, new_mode + " offline fills five Bot seats")
		check(config.players.map(func(player): return int(player.team_id)) == room_state(new_mode).slots.map(func(slot): return int(slot.team_id)), new_mode + " offline and online use the same alliances")
		state = room_state(new_mode)
		await publish_room(state)
		check(control("Slots").get_children().all(func(slot): return slot.visible), new_mode + " exposes all six native seats")
		check(not control("StartMatch").disabled, new_mode + " complete balanced roster can start")
		check(control("StartMatch").get_global_rect().end.y < root.size.y and control("Slots").get_global_rect().end.y < control("StartMatch").get_global_rect().position.y, new_mode + " sixth seat and primary start stay onscreen without overlap")
		var last_team: OptionButton = control("Slots").get_child(5).get_node("Team")
		if new_mode == "ffa":
			check(last_team.disabled and last_team.text == "无队伍" and control("TeamSummary").text.contains("无队伍"), "FFA has no editable teams")
			var before: int = fake.relay.calls.size()
			lobby._on_slot_team_selected(0, 5)
			check(fake.relay.calls.size() == before, "FFA cannot issue a team reassignment")
			state.slots[5].team_id = 4
			check(not _valid_lobby_roster(state), "FFA rejects two owners sharing an alliance")
			state = room_state(new_mode)
		else:
			check(last_team.item_count == int(NetworkProtocol.MODES[new_mode].teams), new_mode + " exposes its exact alliance count")
			state.slots[5].team_id = 0
			await publish_room(state)
			check(control("StartMatch").disabled and control("RoomHint").text.contains("相同人数"), new_mode + " rejects an unbalanced alliance")
			state = room_state(new_mode)
		state.slots[5].kind = "human"
		state.slots[5].connected = true
		await publish_room(state, 5)
		check(control("Ready").visible and control("Slots").get_child(5).get_node("Name").text.ends_with(" · 你"), new_mode + " sixth player gets local readiness and identity")
		check(control("Slots").get_children().all(func(slot): return slot.get_node("Team").disabled and slot.get_node("Kind").disabled), new_mode + " guest cannot configure any seat")
		await capture("lobby-room-" + new_mode)
		await publish_room(state)
		if new_mode == "2v2v2":
			check(control("TeamSummary").text.contains("联盟三：5、6"), "three-alliance summary clearly identifies the third team")
		state.slots[5].kind = "open"
		state.slots[5].ready = false
		await publish_room(state)
		check(control("StartMatch").disabled, new_mode + " sixth open seat blocks start")
		await click(control("FillBots"))
		check(fake.relay.calls[-1] == {"op": "slot", "owner": 5, "kind": "bot", "team": NetworkProtocol.default_alliance(new_mode, 5)}, new_mode + " fills sixth seat without changing alliance")
		state = room_state(new_mode)
		await publish_room(state)
	await click(control("LeaveRoom"))
	check(fake.relay.calls[-1].op == "leave" and control("Setup").visible, "native leave restores the setup flow")
	await click(control("CloseOnline"))
	await click(control("Mode2v2"))
	await click(control("SoloStart"))
	check(fake.offline_modes == ["2v2"], "solo action works immediately without waiting for any relay response")
	check(fake.online_matches.is_empty(), "no online transition is invented by the lobby")
	lobby.queue_free()
	await process_frame
	check(Engine.max_fps == previous_limit, "leaving the lobby restores the previous render limit")
	lobby = load("res://scenes/lobby.tscn").instantiate()
	root.add_child(lobby)
	current_scene = lobby
	await process_frame
	var match_config: Dictionary = {"mode": "2v2", "seed": 271, "players": [{"owner_id": 2, "team_id": 1}]}
	fake.relay.match_started.emit(match_config)
	fake.relay.match_started.emit(match_config)
	check(fake.online_matches == [match_config], "verified relay match starts transition exactly once with the authoritative configuration")
	lobby.queue_free()
	await process_frame
	fake.queue_free()
	await process_frame
	if original_session != null:
		original_session.name = "Session"
	if had_preferences:
		var file := FileAccess.open(preference_path, FileAccess.WRITE)
		file.store_string(preferences)
		file.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(preference_path))
	print("LOBBY_UI_RESULT ", checks, " checks / ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _valid_lobby_roster(state: Dictionary) -> bool:
	var previous: Dictionary = lobby.room
	lobby.room = state
	var valid: bool = lobby._start_block_reason().is_empty()
	lobby.room = previous
	return valid
