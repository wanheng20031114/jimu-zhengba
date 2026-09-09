extends SceneTree
## Saved lobby UI drives a real isolated ENet/DTLS relay and a second client.
var lobby: Node3D
var host: RelayClient
var guest: RelayClient
var checks: int = 0
var failures: Array[String] = []
var errors: Array[Dictionary] = []
var starts: Array[Dictionary] = []
var finalized: bool = false

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func until(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 7000
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return predicate.call()

func click(control: Control) -> void:
	var center: Vector2 = control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = center
	root.push_input(motion, true)
	for pressed: bool in [true, false]:
		var input := InputEventMouseButton.new()
		input.position = center
		input.button_index = MOUSE_BUTTON_LEFT
		input.pressed = pressed
		root.push_input(input, true)
	await process_frame

func _run() -> void:
	create_timer(50.0, true, false, true).timeout.connect(func(): check(false, "bounded_lobby_room_timeout"); _finish())
	var endpoint_path: String = OS.get_cmdline_user_args()[0]
	var endpoint: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(endpoint_path))
	change_scene_to_file("res://scenes/lobby.tscn")
	await scene_changed
	lobby = current_scene
	host = root.get_node("Session").relay
	host.certificate_path = endpoint.certificate
	host.auto_reconnect = false
	# This suite verifies room setup through the authoritative start configuration,
	# while the independent full-match suite owns gameplay scene validation.
	host.match_started.disconnect(lobby._on_match_started)
	host.match_started.connect(func(value: Dictionary): starts.append(value))
	host.error_received.connect(func(code: String, _detail: String): errors.append({"client": "host", "code": code}))
	lobby._endpoint_port = int(endpoint.port)
	lobby.get_node("%ServerAddress").text = endpoint.address
	lobby.get_node("%Nickname").text = "房主房间验证"
	await process_frame
	await click(lobby.get_node("%Multiplayer"))
	await click(lobby.get_node("%OnlineMode2v2"))
	check(lobby.mode == "2v2", "multiplayer_native_scale_selects_two_versus_two")
	await click(lobby.get_node("%CreateRoom"))
	check(await until(func(): return not host.room.is_empty()), "real_dtls_host_creates_room")
	if host.room.is_empty():
		await _finish()
		return
	check(host.room.mode == "2v2" and host.room.slots.size() == 4, "server_creates_four_seats")
	check(host.room.slots.map(func(slot): return int(slot.team_id)) == [0, 0, 1, 1], "default_seats_one_two_versus_three_four")
	check(lobby.get_node("%StartMatch").disabled, "open_seats_block_native_start")
	var first_bot: Button = lobby.get_node("%Slots").get_child(1).get_node("Kind")
	await click(first_bot)
	check(await until(func(): return host.room.slots[1].kind == "bot"), "native_add_bot_reaches_real_server")
	check(first_bot.text == "移除电脑", "server_acknowledged_bot_exposes_remove_button")
	await click(first_bot)
	check(await until(func(): return host.room.slots[1].kind == "open"), "native_remove_bot_reopens_real_seat")
	guest = RelayClient.new()
	guest.certificate_path = endpoint.certificate
	guest.auto_reconnect = false
	root.add_child(guest)
	guest.error_received.connect(func(code: String, _detail: String): errors.append({"client": "guest", "code": code}))
	check(guest.connect_relay(endpoint.address, int(endpoint.port)) == OK, "second_real_client_connects")
	guest.join_room(host.room.code, "真人队友验证")
	check(await until(func(): return not guest.room.is_empty() and host.room.slots[1].kind == "human"), "real_guest_joins_reopened_seat")
	check(first_bot.disabled and first_bot.text == "真人玩家", "native_controls_cannot_replace_real_human")
	host.configure_slot(1, "bot", 0)
	check(await until(func(): return errors.any(func(error): return error.client == "host" and error.code == "occupied_slot")), "server_rejects_forged_human_replacement")
	check(host.room.slots[1].kind == "human", "rejected_replacement_preserves_human_membership")
	guest.configure_slot(2, "bot", 1)
	check(await until(func(): return errors.any(func(error): return error.client == "guest" and error.code == "host_only")), "server_rejects_guest_bot_edit")
	await click(lobby.get_node("%FillBots"))
	check(await until(func(): return host.room.slots[2].kind == "bot" and host.room.slots[3].kind == "bot"), "fill_bots_populates_only_two_empty_seats")
	check(host.room.slots[0].kind == "human" and host.room.slots[1].kind == "human", "bulk_fill_preserves_both_real_players")
	check(lobby.get_node("%StartMatch").disabled, "unready_real_guest_still_blocks_start")
	guest.set_ready(true)
	check(await until(func(): return host.room.slots[1].ready), "guest_readiness_roundtrip")
	check(not lobby.get_node("%StartMatch").disabled, "balanced_ready_room_enables_start")
	await click(lobby.get_node("%Slots").get_child(3).get_node("Kind"))
	check(await until(func(): return host.room.slots[3].kind == "open" and not host.room.slots[1].ready), "changing_bot_seat_clears_other_human_readiness")
	guest.leave_room()
	check(await until(func(): return host.room.slots[1].kind == "open"), "guest_leaving_returns_seat_to_open")
	await click(lobby.get_node("%FillBots"))
	check(await until(func(): return host.room.slots.slice(1).all(func(slot): return slot.kind == "bot")), "host_alone_can_fill_three_bot_seats")
	check(not lobby.get_node("%StartMatch").disabled and lobby._pending_slots.is_empty(), "host_plus_three_bots_is_ready_without_other_humans")
	await click(lobby.get_node("%StartMatch"))
	check(await until(func(): return starts.size() == 1), "native_start_launches_real_authoritative_room")
	if not starts.is_empty():
		check(starts[0].mode == "2v2" and starts[0].players.size() == 4, "start_config_contains_four_player_two_versus_two_match")
		check(starts[0].players.map(func(player): return player.controller) == ["human", "bot", "bot", "bot"], "authoritative_configuration_runs_host_and_three_bots")
		check(starts[0].players.map(func(player): return int(player.team_id)) == [0, 0, 1, 1], "start_keeps_two_alliances")
	check(errors.size() == 2, "only_the_two_deliberate_authority_rejections_occurred")
	await _finish()

func _finish() -> void:
	if finalized:
		return
	finalized = true
	if is_instance_valid(guest):
		guest.disconnect_relay()
		guest.queue_free()
	if is_instance_valid(host):
		host.leave_room()
		host.disconnect_relay()
	if is_instance_valid(lobby):
		lobby.queue_free()
	await process_frame
	await process_frame
	print("LOBBY_ROOM_LIVE_RESULTS " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)
