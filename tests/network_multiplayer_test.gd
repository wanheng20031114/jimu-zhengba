extends SceneTree
## Eight native DTLS peers; room rules, ownership binding and private routing.

const Server = preload("res://server/relay_server.gd")
const Client = preload("res://scripts/network/relay_client.gd")
const Protocol = preload("res://scripts/network/network_protocol.gd")
var relay: Node
var clients: Array = []
var checks := 0
var failures: Array[String] = []
var errors: Array[Dictionary] = []
var snapshots: Array[Dictionary] = []
var commands: Array[Dictionary] = []
var starts: Array[Dictionary] = []
var certificate_path := ""
var key_path := ""

func _initialize() -> void:
	_run.call_deferred()

func check(passed: bool, label: String) -> void:
	checks += 1
	if not passed:
		failures.append(label)

func until(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 5000
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return condition.call()

func _run() -> void:
	var crypto := Crypto.new()
	var key := crypto.generate_rsa(2048)
	var certificate := crypto.generate_self_signed_certificate(key, "CN=" + Protocol.TLS_NAME)
	certificate_path = "user://multiplayer-%d.crt" % Time.get_ticks_usec()
	key_path = certificate_path.trim_suffix(".crt") + ".key"
	check(key.save(key_path) == OK and certificate.save(certificate_path) == OK, "isolated_certificate_created")
	relay = Server.new()
	root.add_child(relay)
	check(relay.max_humans == 8 and Protocol.CHANNEL_COUNT == 10, "eight_player_native_transport_limits")
	check(relay.start("127.0.0.1", 0, key_path, certificate_path) == OK, "dtls_server_started")
	for index in range(8):
		var client := Client.new()
		client.auto_reconnect = false
		client.certificate_path = certificate_path
		root.add_child(client)
		clients.append(client)
		client.error_received.connect(func(code: String, _message: String): errors.append({"client": index, "code": code}))
		client.snapshot_received.connect(func(payload: Dictionary): snapshots.append({"client": index, "payload": payload}))
		client.command_received.connect(func(owner: int, payload: Dictionary): commands.append({"client": index, "owner": owner, "payload": payload}))
		client.match_started.connect(func(config: Dictionary): starts.append({"client": index, "config": config}))
		check(client.connect_relay("127.0.0.1", relay.connection.get_local_port()) == OK, "native_client_connect_%d" % index)
	if not await until(func(): return clients.all(func(client): return client.connection_state == "connected")):
		check(false, "eight_authenticated_dtls_connections")
		_finish()
		return
	check(true, "eight_authenticated_dtls_connections")
	for mode: String in ["3v3", "2v2v2", "4v4", "ffa"]:
		await _room(mode, false)
		await _room(mode, true)
	await _sparse_room()
	_finish()

func _room(mode: String, bots: bool) -> void:
	var count: int = Protocol.MODES[mode].slots
	var last: int = count - 1
	var prefix := mode + ("_bots_" if bots else "_humans_")
	starts.clear()
	errors.clear()
	snapshots.clear()
	commands.clear()
	clients[0].create_room(mode, "房主")
	if not await until(func(): return clients[0].connection_state == "lobby"):
		check(false, prefix + "room_created")
		return
	check(clients[0].room.slots.size() == count, prefix + "mode_seats")
	check(not JSON.stringify(clients[0].room).contains("token"), prefix + "no_public_credentials")
	for owner in range(1, count):
		if bots:
			clients[0].configure_slot(owner, "bot", Protocol.default_alliance(mode, owner))
			check(await until(func(): return clients[0].room.slots[owner].kind == "bot"), prefix + "bot_slot_%d" % owner)
		else:
			clients[owner].join_room(clients[0].room.code, "玩家%d" % owner)
			check(await until(func(): return clients[owner].owner_id == owner), prefix + "stable_owner_%d" % owner)
	if mode == "4v4" and not bots:
		var extra: Node = Client.new()
		extra.auto_reconnect = false
		extra.certificate_path = certificate_path
		root.add_child(extra)
		extra.error_received.connect(func(code: String, _message: String): errors.append({"client": 8, "code": code}))
		extra.connect_relay("127.0.0.1", relay.connection.get_local_port())
		check(await until(func(): return extra.connection_state == "connected"), "ninth_transport_authenticates_but_has_no_seat")
		extra.join_room(clients[0].room.code, "超员玩家")
		check(await until(func(): return errors.any(func(error): return error.client == 8 and error.code == "room_full")), "ninth_human_cannot_join_full_eight_seat_room")
		check(extra.owner_id == -1 and relay.sessions.size() == 8, "ninth_human_receives_no_identity_or_credentials")
		extra.disconnect_relay()
		extra.queue_free()
	if mode == "ffa":
		clients[0].configure_slot(last, "bot" if bots else "human", 0)
		check(await until(func(): return errors.any(func(error): return error.code == "ffa_independent")), prefix + "reject_joining_other_alliance")
		check(int(clients[0].room.slots[last].team_id) == last, prefix + "ffa_last_owner_independent")
	else:
		# A within-range but unbalanced roster must never start a match.
		clients[0].configure_slot(last, "bot" if bots else "human", 0)
		await until(func(): return int(clients[0].room.slots[last].team_id) == 0)
		for owner in range(1, count):
			if not bots: clients[owner].set_ready(true)
		await until(func(): return clients[0].room.slots.all(func(slot): return slot.ready))
		clients[0].start_match()
		check(await until(func(): return errors.any(func(error): return error.code == "team_capacity")), prefix + "team_size_enforced")
		check(starts.is_empty(), prefix + "invalid_roster_never_started")
		clients[0].configure_slot(last, "bot" if bots else "human", Protocol.default_alliance(mode, last))
		await until(func(): return int(clients[0].room.slots[last].team_id) == Protocol.default_alliance(mode, last))
	for owner in range(1, count):
		if not bots: clients[owner].set_ready(true)
	check(await until(func(): return clients[0].room.slots.all(func(slot): return slot.ready)), prefix + "all_ready")
	clients[0].start_match()
	check(await until(func(): return starts.size() == (1 if bots else count)), prefix + "all_peers_start")
	if clients[0]._match.is_empty():
		return
	var config: Dictionary = clients[0]._match.duplicate(true)
	check(config.map_id == Protocol.MODES[mode].map_id and config.players.size() == count, prefix + "mode_map_contract")
	for owner in range(count):
		check(int(config.players[owner].team_id) == Protocol.default_alliance(mode, owner), prefix + "alliance_%d" % owner)
		check(config.players[owner].controller == ("bot" if bots and owner > 0 else "human"), prefix + "controller_%d" % owner)
	if not bots:
		for owner in [last - 1, last]:
			check(clients[0].snapshot_to(owner, {"tick": 2, "recipient_secret": owner}) == OK, prefix + "late_recipient_send_%d" % owner)
		check(await until(func(): return snapshots.size() == 2), prefix + "late_recipients_receive")
		check(snapshots.all(func(record): return record.client in [last - 1, last] and record.payload.recipient_secret == record.client), prefix + "private_snapshot_routing")
		check(clients[0].snapshot_to(count, {}) == ERR_INVALID_PARAMETER, prefix + "outside_mode_recipient_rejected")
		clients[last].send_command({"kind": "move", "owner": 0, "units": [1]})
		check(await until(func(): return commands.size() == 1), prefix + "last_client_command_arrives")
		check(commands[0].client == 0 and commands[0].owner == last, prefix + "last_client_owner_bound_by_relay")
		clients[last]._send({"op": "command", "match": config.match_id, "sequence": 1, "payload": {"kind": "duplicate"}})
		await create_timer(0.05).timeout
		check(commands.size() == 1, prefix + "duplicate_last_owner_command_filtered")
		check(clients[last].snapshot_to(4, {}) == ERR_UNAUTHORIZED, prefix + "last_client_cannot_forge_snapshot")
		if mode == "3v3":
			clients[last]._send({"op": "finish", "match": config.match_id, "result": {"winner": 0}})
			check(await until(func(): return errors.any(func(error): return error.client == last and error.code == "host_only")), prefix + "guest_cannot_finish_room")
			clients[0].finish_match({"winner": 6})
			check(await until(func(): return errors.any(func(error): return error.code == "invalid_result")), prefix + "nonexistent_winner_rejected")
			check(relay.rooms.size() == 1 and clients[0].connection_state == "match", prefix + "invalid_result_keeps_match_running")
	clients[0].finish_match({"winner": int(Protocol.MODES[mode].teams) - 1})
	check(await until(func(): return relay.rooms.is_empty()), prefix + "match_releases_room")
	await until(func(): return clients.all(func(client): return client.connection_state in ["connected", "finished"]))
	for client: Node in clients:
		if client.connection_state == "finished": client.leave_room()
	check(relay.sessions.is_empty(), prefix + "match_releases_all_credentials")

func _sparse_room() -> void:
	starts.clear()
	errors.clear()
	commands.clear()
	snapshots.clear()
	clients[0].create_room("4v4", "房主")
	check(await until(func(): return clients[0].connection_state == "lobby"), "sparse_room_created")
	clients[0].start_match()
	check(await until(func(): return errors.any(func(error): return error.code == "opponents_required")), "one_faction_cannot_start")
	var feedback_before: int = errors.size()
	for retry in range(14):
		clients[0].start_match()
	check(await until(func(): return errors.size() >= feedback_before + 14), "repeated_room_feedback_is_delivered")
	check(clients[0].connection_state == "lobby" and clients[0].is_host, "ordinary_room_feedback_does_not_disconnect_host")
	for owner in range(1, 7):
		clients[0].configure_slot(owner, "bot", Protocol.default_alliance("4v4", owner))
	check(await until(func(): return clients[0].room.slots[6].kind == "bot"), "reserve_intermediate_slots")
	clients[7].join_room(clients[0].room.code, "末席玩家")
	check(await until(func(): return clients[7].owner_id == 7), "last_human_owner_stays_seven")
	for owner in [5, 6]:
		clients[0].configure_slot(owner, "open", 1)
	check(await until(func(): return clients[0].room.slots[5].kind == "open" and clients[0].room.slots[6].kind == "open"), "two_empty_seats_retained")
	clients[0].start_match()
	check(await until(func(): return errors.any(func(error): return error.code == "not_ready")), "only_actual_human_requires_ready")
	clients[7].set_ready(true)
	check(await until(func(): return Protocol.room_start_error(clients[0].room).is_empty()), "four_vs_two_valid_without_filling_open_seats")
	clients[0].start_match()
	check(await until(func(): return starts.size() == 2), "four_vs_two_starts_two_humans_four_bots")
	var config: Dictionary = clients[0]._match.duplicate(true)
	check(config.players.size() == 8 and config.players[7].owner_id == 7, "sparse_configuration_keeps_seat_indices")
	check(config.players[5].controller == "open" and config.players[6].controller == "open", "open_seats_are_not_humans_or_bots")
	check(clients[0].snapshot_to(5, {}) == ERR_INVALID_PARAMETER, "no_snapshot_for_empty_slot")
	clients[7].send_command({"kind": "move", "owner": 5, "units": [1]})
	check(await until(func(): return commands.size() == 1), "sparse_last_owner_command_arrives")
	check(commands[0].owner == 7, "cannot_impersonate_empty_owner")
	# Snapshots use an unreliable presentation channel. Exercise the recurring
	# publisher used by real matches, including its native per-recipient throttle.
	check(await until(func():
		if snapshots.is_empty(): clients[0].snapshot_to(7, {"tick": 2, "private_recipient": 7})
		return not snapshots.is_empty()), "sparse_last_owner_receives_private_snapshot")
	check(not snapshots.is_empty() and snapshots.all(func(item: Dictionary): return item.client == 7), "sparse_snapshot_not_broadcast")
	var token: String = clients[7]._token
	clients[7]._peer.peer_disconnect_now()
	clients[7]._close_transport()
	check(await until(func(): return relay.sessions[token].peer == null), "sparse_human_disconnect_detected")
	var boundary := Time.get_ticks_msec()
	relay.sessions[token].disconnected = boundary - Server.BOT_GRACE_MS
	relay._maintenance(boundary)
	check(relay.sessions[token].bot and relay.rooms[clients[0].room.code].slots[7].kind == "human", "disconnected_human_reserved_and_bot_taken_over")
	check(relay.rooms[clients[0].room.code].slots[5].kind == "open" and relay.sessions.size() == 2, "empty_seats_never_get_takeover_sessions")
	clients[7]._open()
	check(await until(func(): return clients[7].connection_state == "match" and not relay.sessions[token].bot), "sparse_last_human_rejoins")
	check(clients[7].owner_id == 7 and starts.size() == 2 and clients[7]._command_sequence == 1, "rejoin_preserves_identity_scene_and_command_sequence")
	clients[7]._send({"op": "command", "match": config.match_id, "sequence": 1, "payload": {"kind": "duplicate"}})
	await create_timer(0.05).timeout
	check(commands.size() == 1, "pre_disconnect_command_cannot_replay")
	clients[0].finish_match({"winner": 1})
	check(await until(func(): return relay.rooms.is_empty()), "sparse_match_releases_room")
	await until(func(): return clients[0].connection_state == "finished" and clients[7].connection_state == "finished")
	for client: Node in clients:
		if client.connection_state == "finished": client.leave_room()
	# FFA seats 1..6 can remain vacant while owners 0 and 7 fight independently.
	var ffa := config.duplicate(true)
	ffa.mode = "ffa"
	for owner in range(8):
		ffa.players[owner].team_id = owner
		ffa.players[owner].controller = "human" if owner in [0, 7] else "open"
	check(Protocol.match_config_error(ffa).is_empty(), "ffa_two_opponents_among_eight_slots_valid")
	ffa.players[7].owner_id = 1
	check(Protocol.match_config_error(ffa) == "invalid_roster", "compressed_or_duplicate_owner_ids_rejected")

func _finish() -> void:
	for client: Node in clients:
		client.disconnect_relay()
		client.queue_free()
	relay.stop()
	relay.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(certificate_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(key_path))
	print("NETWORK_MULTIPLAYER_RESULTS " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)
