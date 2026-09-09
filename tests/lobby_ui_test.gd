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
	signal load_failed(message: String)
	var settings: GameSettings
	var fail_load: bool = false
	var relay: FakeRelay
	var offline_modes: Array[String] = []
	var online_matches: Array[Dictionary] = []
	func start_offline(mode: String) -> Error:
		if fail_load:
			load_failed.emit("无法载入战场，请重试")
			return ERR_CANT_OPEN
		offline_modes.append(mode)
		return OK
	func start_online(config: Dictionary) -> Error:
		online_matches.append(config)
		return OK
var checks: int = 0
var failures: Array[String] = []
var lobby: Node3D
var fake: FakeSession
var visual: bool = false

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func control(name: String) -> Control:
	return lobby.get_node("%" + name)

func click(target: Control) -> void:
	var parent: Node = target.get_parent()
	while parent != null:
		if parent is ScrollContainer:
			parent.ensure_control_visible(target)
			await process_frame
		parent = parent.get_parent()
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

func room_state(mode: String) -> Dictionary:
	var slots: Array = []
	for owner in int(NetworkProtocol.MODES[mode].slots):
		slots.append({"owner_id": owner, "team_id": NetworkProtocol.default_alliance(mode, owner),
			"kind": "human" if owner == 0 else "bot", "name": "本地主将" if owner == 0 else "电脑将领",
			"ready": true, "connected": owner == 0, "bot_takeover": false})
	return {"code": "ABCD2345", "mode": mode, "status": "lobby", "host_owner": 0, "slots": slots}

func publish_room(state: Dictionary, owner: int = 0) -> void:
	fake.relay.owner_id = owner
	fake.relay.is_host = owner == 0
	fake.relay.room = state.duplicate(true)
	fake.relay._set_state("lobby")
	fake.relay.room_changed.emit(state)
	for frame in 3:
		await process_frame

func capture(name: String) -> void:
	if not visual:
		return
	await create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png("res://artifacts/" + name + ".png") == OK, "native capture " + name)

func _run() -> void:
	root.size = Vector2i(1600, 900)
	visual = "--lobby-visual" in OS.get_cmdline_user_args()
	var preference_path: String = "user://lobby_preferences.cfg"
	var had_preferences: bool = FileAccess.file_exists(preference_path)
	var preferences: String = FileAccess.get_file_as_string(preference_path) if had_preferences else ""
	var original_session: Node = root.get_node("Session")
	original_session.name = "OriginalSession"
	fake = FakeSession.new()
	fake.name = "Session"
	fake.settings = original_session.settings
	fake.relay = FakeRelay.new()
	fake.add_child(fake.relay)
	root.add_child(fake)
	var previous_limit: int = Engine.max_fps
	lobby = load("res://scenes/lobby.tscn").instantiate()
	root.add_child(lobby)
	current_scene = lobby
	for frame in 4:
		await process_frame
	check(lobby.mode == "1v1" and not control("SoloPanel").visible and not control("OnlinePanel").visible, "home starts with one calm menu rather than setup panels")
	check(lobby.get_node("CanvasLayer/UI/Brand/Title").text == "积木争霸", "new brand is the native title")
	check(control("Slots").get_child_count() == 8, "all eight room rows are authored in the scene")
	check(Engine.max_fps == previous_limit, "menu respects user frame limit")
	await capture("lobby-090-home")
	await click(control("SoloMenu"))
	check(control("SoloPanel").visible, "native solo entry opens mode selection")
	for mode: String in NetworkProtocol.MODES:
		var suffix: String = "FFA" if mode == "ffa" else mode
		await click(control("Mode" + suffix))
		var definition: MapDefinition = load(NetworkProtocol.map_path(mode))
		check(lobby.mode == mode and control("MapTitle").text == definition.display_name and control("OnlineMode" + suffix).button_pressed, mode + " uses shared map data and synchronized selectors")
	await capture("lobby-090-solo")
	await click(control("Multiplayer"))
	check(not control("SoloPanel").visible and control("OnlinePanel").visible, "opening online replaces the solo panel")
	control("ServerAddress").text = ""
	await click(control("CreateRoom"))
	check(fake.relay.calls.is_empty() and not control("Message").text.is_empty(), "missing address is reported before any connection")
	control("ServerAddress").text = "127.0.0.1"
	control("Nickname").text = "大厅测试将领"
	await click(control("CreateRoom"))
	check(fake.relay.calls.size() == 2 and control("CreateRoom").disabled and control("CancelRequest").visible, "pending room creation exposes cancellation and prevents duplicate requests")
	await click(control("CancelRequest"))
	check(not lobby._pending_request and control("RetryRequest").visible and fake.relay.calls[-1].op == "disconnect", "cancel restores retry without a stuck loading state")
	await click(control("RetryRequest"))
	check(fake.relay.calls[-1].op == "create" and lobby._pending_request, "retry resubmits the previous creation intent")
	lobby.get_node("%RequestTimeout").timeout.emit()
	check(not lobby._pending_request and not control("CreateRoom").disabled and control("Message").text.contains("暂未回应"), "request timeout restores editable setup")
	control("InviteInput").text = "bad"
	var calls_before: int = fake.relay.calls.size()
	await click(control("JoinRoom"))
	check(fake.relay.calls.size() == calls_before and control("Message").text.contains("八位"), "invalid invitations never connect")
	control("InviteInput").text = "abc23456"
	await click(control("JoinRoom"))
	check(fake.relay.calls[-1].op == "join" and fake.relay.calls[-1].code == "ABC23456", "join accepts normalized eight-character invitation")
	fake.relay.error_received.emit("capacity", "房间已满，请重试")
	check(not lobby._pending_request and control("RetryRequest").visible, "relay rejection releases loading state")
	await capture("lobby-090-network")

	for mode: String in NetworkProtocol.MODES:
		var state: Dictionary = room_state(mode)
		await publish_room(state)
		var count: int = int(NetworkProtocol.MODES[mode].slots)
		check(control("Slots").get_children().filter(func(row): return row.visible).size() == count, mode + " shows exactly its actual slot capacity")
		check(not control("StartMatch").disabled and lobby._start_block_reason().is_empty(), mode + " full ready roster is legal")
		check(control("StartMatch").get_global_rect().end.x <= root.size.x + 1.0 and control("OnlinePanel").get_global_rect().end.y <= root.size.y + 1.0, mode + " panel remains inside the window")
		var last: HBoxContainer = control("Slots").get_child(count - 1)
		check(last.get_node("Team").disabled == (mode == "ffa"), mode + " exposes editable teams only in team modes")
		if count >= 4:
			state.slots[count - 1].kind = "open"
			state.slots[count - 1].ready = false
			await publish_room(state)
			check(not control("StartMatch").disabled and last.get_node("State").text == "不参战", mode + " retained empty seat does not block legitimate opponents")
			check(control("TeamSummary").text.contains("1 个空位"), mode + " summary counts actual retained empties")
			await click(last.get_node("Kind"))
			check(fake.relay.calls[-1] == {"op": "slot", "owner": count - 1, "kind": "bot", "team": NetworkProtocol.default_alliance(mode, count - 1)}, mode + " scrolled final row remains operable")
			check(last.get_node("Kind").disabled, mode + " pending slot edit suppresses duplicate input")
			lobby.get_node("%SlotTimeout").timeout.emit()
			check(not last.get_node("Kind").disabled and lobby._pending_slots.is_empty(), mode + " slot request timeout restores controls")
		state = room_state(mode)
		for owner in range(1, count):
			state.slots[owner].kind = "open"
			state.slots[owner].ready = false
		await publish_room(state)
		check(control("StartMatch").disabled and control("RoomHint").text.contains("两个敌对阵营"), mode + " host alone cannot start without an opponent")
		state = room_state(mode)
		state.slots[count - 1].kind = "human"
		state.slots[count - 1].connected = true
		state.slots[count - 1].ready = false
		await publish_room(state)
		check(control("StartMatch").disabled and control("RoomHint").text.contains("准备"), mode + " unready human blocks launch")
		state.slots[count - 1].ready = true
		await publish_room(state, count - 1)
		check(control("Ready").visible and not control("StartMatch").visible and not control("FillBots").visible, mode + " guest only controls own readiness")
		check(control("Slots").get_children().all(func(row): return not row.visible or (row.get_node("Team").disabled and row.get_node("Kind").disabled)), mode + " guests cannot configure any seat")
		await publish_room(state)
		if mode == "4v4":
			check(control("SlotScroll").get_global_rect().encloses(control("Slots").get_child(7).get_global_rect()), "desktop room displays the eighth native seat without scrolling")
			state.slots[6].kind = "open"
			state.slots[7].kind = "open"
			await publish_room(state)
			check(not control("StartMatch").disabled and control("StartMatch").text == "开始 4v2 对战" and control("TeamSummary").text.contains("联盟一 4 人") and control("TeamSummary").text.contains("联盟二 2 人"), "four-versus-two is accurately displayed in the start action and allowed")
			await capture("lobby-090-room-4v2")
			state.slots[4].team_id = 0
			await publish_room(state)
			check(control("StartMatch").disabled and control("RoomHint").text.contains("上限"), "five participants in one four-seat alliance is rejected")
		if mode == "ffa":
			await capture("lobby-090-room-ffa")
			state.slots[1].team_id = 0
			await publish_room(state)
			check(control("StartMatch").disabled and control("RoomHint").text.contains("独立"), "FFA cannot merge two factions")
	await publish_room(room_state("4v4"))
	await click(control("StartMatch"))
	check(fake.relay.calls[-1].op == "start" and control("StartMatch").disabled, "native start sends exactly one launch intent")
	await publish_room(room_state("4v4"))
	root.size = Vector2i(1024, 576)
	for frame in 4:
		await process_frame
	# Godot's canvas_items stretch keeps UI coordinates at 1600x900 while the
	# actual Window is 1024x576. Compare rectangles in the same canvas space.
	var ui_rect: Rect2 = lobby.get_node("CanvasLayer/UI").get_global_rect()
	check(ui_rect.encloses(control("OnlinePanel").get_global_rect()), "small window contains the scrollable room panel after native canvas scaling")
	if visual:
		check(root.get_texture().get_image().get_size() == Vector2i(1024, 576), "small-window validation actually renders at 1024 by 576 pixels")
	await click(control("Slots").get_child(7).get_node("Kind"))
	check(fake.relay.calls[-1].op == "slot" and fake.relay.calls[-1].owner == 7, "eighth slot is reachable in a 1024 by 576 window")
	lobby._on_slot_timeout()
	await capture("lobby-090-room-small")
	root.size = Vector2i(1600, 900)
	await click(control("LeaveRoom"))
	await click(control("CloseOnline"))
	await click(control("Codex"))
	var codex: Control = control("UnitCodex")
	check(codex.visible, "native codex entry opens the full catalogue")
	var counts: Array[int] = [6, 5, 12]
	for category in range(3):
		codex._on_category_changed(category)
		check(codex.get_node("%Entries").item_count == counts[category], "catalogue category " + str(category) + " contains every current resource")
		var entries: Array[String] = codex._entries.duplicate()
		for id: String in entries:
			codex.select_entry(category, id)
			var definition: Resource = codex._definition(id)
			check(codex.get_node("%EntryTitle").text == definition.name and not codex.get_node("%Stats").get_parsed_text().is_empty(), id + " shows exact shared resource identity and statistics")
			check(codex.get_node("%ModelAnchor").get_child_count() == 1 and is_instance_valid(codex._model), id + " owns one real preview model")
			if category == 0:
				check(codex.get_node("%Stats").get_parsed_text().contains(str(definition.cost)) and codex.get_node("%Stats").get_parsed_text().contains(str(int(definition.hp))), id + " displays real cost and health")
	codex.select_entry(0, "knight")
	await capture("codex-090-knight")
	var portrait: Control = codex.get_node("%Portrait")
	var pressed := InputEventMouseButton.new()
	pressed.button_index = MOUSE_BUTTON_LEFT
	pressed.pressed = true
	portrait.gui_input.emit(pressed)
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(80, 0)
	portrait.gui_input.emit(motion)
	check(is_equal_approx(codex.get_node("%ModelAnchor").rotation.y, 0.64), "drag input rotates the actual native model")
	var zoom := InputEventMouseButton.new()
	zoom.button_index = MOUSE_BUTTON_WHEEL_UP
	zoom.pressed = true
	portrait.gui_input.emit(zoom)
	check(codex.get_node("%PreviewCamera").size < codex._base_camera_size, "wheel input zooms preview camera")
	await click(codex.get_node("%ResetView"))
	check(codex.get_node("%ModelAnchor").rotation.y == 0 and codex.get_node("%PreviewCamera").size == codex._base_camera_size, "native reset restores framing")
	codex.select_entry(1, "headquarters")
	await capture("codex-090-headquarters")
	codex.select_entry(2, "army_capacity_2")
	check(codex.get_node("%Stats").get_parsed_text().contains("100"), "army expansion codex shows the final hundred supply cap")
	await capture("codex-090-army-research")
	codex.select_entry(2, "mining_3")
	check(codex.get_node("%Description").text.contains("30%") and codex.get_node("%Stats").get_parsed_text().contains("2.31"), "mining codex shows total thirty percent and actual shortened cycle")
	await capture("codex-090-mining")
	await click(codex.get_node("%CloseCodex"))
	check(not codex.visible and codex.get_node("%CodexViewport").render_target_update_mode == SubViewport.UPDATE_DISABLED and codex._model.process_mode == Node.PROCESS_MODE_DISABLED, "closing codex disables its rendering and animation work")
	await click(control("SoloMenu"))
	await click(control("Mode4v4"))
	fake.fail_load = true
	await click(control("SoloStart"))
	check(not lobby._transitioning and not control("SoloStart").disabled and control("SoloLoadMessage").text.contains("重试"), "load failure restores a retryable solo action")
	fake.fail_load = false
	await click(control("SoloStart"))
	check(fake.offline_modes == ["4v4"], "retried solo start uses the selected eight-player mode without relay dependency")
	lobby.queue_free()
	await process_frame
	fake.queue_free()
	await process_frame
	original_session.name = "Session"
	if had_preferences:
		var file := FileAccess.open(preference_path, FileAccess.WRITE)
		file.store_string(preferences)
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(preference_path))
	print("LOBBY_UI_RESULT " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)
