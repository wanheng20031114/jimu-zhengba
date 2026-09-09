extends SceneTree
## Six native DTLS peers; room rules, ownership binding and private routing.

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
	var certificate := crypto.generate_self_signed_certificate(key, "CN=ashen-crown-relay")
	certificate_path = "user://multiplayer-%d.crt" % Time.get_ticks_usec()
	key_path = certificate_path.trim_suffix(".crt") + ".key"
	check(key.save(key_path) == OK and certificate.save(certificate_path) == OK, "isolated_certificate_created")
	relay = Server.new()
	root.add_child(relay)
	check(relay.max_humans == 6 and Protocol.CHANNEL_COUNT == 8, "six_player_native_transport_limits")
	check(relay.start("127.0.0.1", 0, key_path, certificate_path) == OK, "dtls_server_started")
	for index in range(6):
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
		check(false, "six_authenticated_dtls_connections")
		_finish()
		return
	check(true, "six_authenticated_dtls_connections")
	for mode: String in ["3v3", "2v2v2", "ffa"]:
		await _room(mode, false)
		await _room(mode, true)
	_finish()

func _room(mode: String, bots: bool) -> void:
	var prefix := mode + ("_bots_" if bots else "_humans_")
	starts.clear()
	errors.clear()
	snapshots.clear()
	commands.clear()
	clients[0].create_room(mode, "房主")
	if not await until(func(): return clients[0].connection_state == "lobby"):
		check(false, prefix + "room_created")
		return
	check(clients[0].room.slots.size() == 6, prefix + "six_seats")
	check(not JSON.stringify(clients[0].room).contains("token"), prefix + "no_public_credentials")
	for owner in range(1, 6):
		if bots:
			clients[0].configure_slot(owner, "bot", Protocol.default_alliance(mode, owner))
			check(await until(func(): return clients[0].room.slots[owner].kind == "bot"), prefix + "bot_slot_%d" % owner)
		else:
			clients[owner].join_room(clients[0].room.code, "玩家%d" % owner)
			check(await until(func(): return clients[owner].owner_id == owner), prefix + "stable_owner_%d" % owner)
	if mode == "ffa":
		clients[0].configure_slot(5, "bot" if bots else "human", 0)
		check(await until(func(): return errors.any(func(error): return error.code == "ffa_independent")), prefix + "reject_joining_other_alliance")
		check(int(clients[0].room.slots[5].team_id) == 5, prefix + "ffa_owner_five_independent")
	else:
		# A within-range but unbalanced roster must never start a match.
		clients[0].configure_slot(5, "bot" if bots else "human", 0)
		await until(func(): return int(clients[0].room.slots[5].team_id) == 0)
		for owner in range(1, 6):
			if not bots: clients[owner].set_ready(true)
		await until(func(): return clients[0].room.slots.all(func(slot): return slot.ready))
		clients[0].start_match()
		check(await until(func(): return errors.any(func(error): return error.code == "unbalanced_teams")), prefix + "team_size_enforced")
		check(starts.is_empty(), prefix + "invalid_roster_never_started")
		clients[0].configure_slot(5, "bot" if bots else "human", Protocol.default_alliance(mode, 5))
		await until(func(): return int(clients[0].room.slots[5].team_id) == Protocol.default_alliance(mode, 5))
	for owner in range(1, 6):
		if not bots: clients[owner].set_ready(true)
	check(await until(func(): return clients[0].room.slots.all(func(slot): return slot.ready)), prefix + "all_ready")
	clients[0].start_match()
	check(await until(func(): return starts.size() == (1 if bots else 6)), prefix + "all_peers_start")
	if clients[0]._match.is_empty():
		return
	var config: Dictionary = clients[0]._match
	check(config.map_id == Protocol.MODES[mode].map_id and config.players.size() == 6, prefix + "mode_map_contract")
	for owner in range(6):
		check(int(config.players[owner].team_id) == Protocol.default_alliance(mode, owner), prefix + "alliance_%d" % owner)
		check(config.players[owner].controller == ("bot" if bots and owner > 0 else "human"), prefix + "controller_%d" % owner)
	if not bots:
		for owner in [4, 5]:
			check(clients[0].snapshot_to(owner, {"tick": 2, "recipient_secret": owner}) == OK, prefix + "late_recipient_send_%d" % owner)
		check(await until(func(): return snapshots.size() == 2), prefix + "late_recipients_receive")
		check(snapshots.all(func(record): return record.client in [4, 5] and record.payload.recipient_secret == record.client), prefix + "private_snapshot_routing")
		check(clients[0].snapshot_to(6, {}) == ERR_INVALID_PARAMETER, prefix + "seventh_recipient_rejected")
		clients[5].send_command({"kind": "move", "owner": 0, "units": [1]})
		check(await until(func(): return commands.size() == 1), prefix + "sixth_client_command_arrives")
		check(commands[0].client == 0 and commands[0].owner == 5, prefix + "sixth_client_owner_bound_by_relay")
		clients[5]._send({"op": "command", "match": config.match_id, "sequence": 1, "payload": {"kind": "duplicate"}})
		await create_timer(0.05).timeout
		check(commands.size() == 1, prefix + "duplicate_owner_five_command_filtered")
		check(clients[5].snapshot_to(4, {}) == ERR_UNAUTHORIZED, prefix + "sixth_client_cannot_forge_snapshot")
		if mode == "3v3":
			clients[5]._send({"op": "finish", "match": config.match_id, "result": {"winner": 0}})
			check(await until(func(): return errors.any(func(error): return error.client == 5 and error.code == "host_only")), prefix + "guest_cannot_finish_room")
			clients[0].finish_match({"winner": 6})
			check(await until(func(): return errors.any(func(error): return error.code == "invalid_result")), prefix + "nonexistent_winner_rejected")
			check(relay.rooms.size() == 1 and clients[0].connection_state == "match", prefix + "invalid_result_keeps_match_running")
	clients[0].finish_match({"winner": int(Protocol.MODES[mode].teams) - 1})
	check(await until(func(): return relay.rooms.is_empty()), prefix + "match_releases_room")
	await until(func(): return clients.all(func(client): return client.connection_state in ["connected", "finished"]))
	for client: Node in clients:
		if client.connection_state == "finished": client.leave_room()
	check(relay.sessions.is_empty(), prefix + "match_releases_all_credentials")

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
