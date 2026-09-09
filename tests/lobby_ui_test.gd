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
	for owner: int in (4 if mode == "2v2" else 2):
		slots.append({"owner_id": owner, "team_id": owner / 2 if mode == "2v2" else owner,
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
	check(Engine.max_fps == 60, "lobby limits static presentation rendering")
	check(not control("OnlinePanel").visible, "initial canvas gives the local match one clear primary action")
	check(control("Slots").get_child_count() == 4, "room owns exactly four saved native slot rows")
	await capture("lobby-home")
	await click(control("Mode2v2"))
	check(lobby.mode == "2v2" and control("MapTitle").text == "双谷争锋", "native mode input uses the authoritative map resource title")
	await click(control("Multiplayer"))
	check(control("OnlinePanel").visible and control("Setup").visible, "native multiplayer click reveals setup")
	if visual:
		await create_timer(0.25).timeout
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
	var kind: OptionButton = row.get_node("Kind")
	kind.select(1)
	kind.item_selected.emit(1)
	check(fake.relay.calls[-1] == {"op": "slot", "owner": 3, "kind": "bot", "team": 1}, "host bot selector preserves the slot alliance")
	check(kind.is_item_disabled(2), "host cannot synthesize an occupied human player")
	var team: OptionButton = control("Slots").get_child(1).get_node("Team")
	team.select(1)
	team.item_selected.emit(1)
	check(fake.relay.calls[-1] == {"op": "slot", "owner": 1, "kind": "bot", "team": 1}, "host alliance selector preserves the slot controller")
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
	var guest_readonly: bool = true
	for slot_row: HBoxContainer in control("Slots").get_children():
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
	check(not control("Slots").get_child(2).visible and not control("Slots").get_child(3).visible, "one-versus-one hides only the two unused saved slots")
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
