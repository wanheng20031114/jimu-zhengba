extends SceneTree
## Real native ENet + DTLS clients. No game scene, display, or remote mutation.

const Server = preload("res://server/relay_server.gd")
const Client = preload("res://scripts/network/relay_client.gd")
const Protocol = preload("res://scripts/network/network_protocol.gd")
var relay: Node
var clients: Array = []
var checks: Array = []
var messages: Array = []
var events: Array = []
var snapshots: Array = []
var errors: Array = []
var starts: Array = []
var _deadline: int = 0
var _certificate_path: String = ""
var _key_path: String = ""

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_deadline = Time.get_ticks_msec() + 45000
	_check("roundtrip primitives", Protocol.decode(Protocol.encode({"value": [1, 2.5, true, null, "中文"]})).value == [1.0, 2.5, true, null, "中文"])
	_check("reject Object encoding", Protocol.encode({"bad": RefCounted.new()}).is_empty())
	_check("reject non-finite", Protocol.encode({"bad": NAN}).is_empty())
	_check("reject malformed JSON", Protocol.decode("{broken".to_utf8_buffer()).is_empty())
	var oversized := PackedByteArray()
	oversized.resize(Protocol.MAX_PACKET_BYTES + 1)
	_check("reject oversized packet", Protocol.decode(oversized).is_empty())
	var deep: Dictionary = {}
	for _i in range(20): deep = {"nested": deep}
	_check("reject excessive depth", Protocol.encode(deep).is_empty())
	var snapshot_epoch := "1".repeat(32)
	var trusted_payload := {"tick": 1, "time": 0.0, "entities": [{"id": 1, "p": [1.0, 0.0, 2.0], "hp": 100.0}]}
	var trusted_packet := Protocol.encode_snapshot(trusted_payload, 1, 2, snapshot_epoch)
	var ordinary_packet := Protocol.encode({"op": "snapshot", "match": snapshot_epoch, "to": 1, "sequence": 2, "payload": trusted_payload})
	_check("trusted snapshot bytes retain wire contract", trusted_packet == ordinary_packet)
	_check("trusted snapshot passes complete receiver validation", Protocol.decode(trusted_packet).payload.entities[0].hp == 100.0)
	_check("trusted snapshot rejects invalid envelope", Protocol.encode_snapshot(trusted_payload, Protocol.MAX_PLAYERS, 2, snapshot_epoch).is_empty() and Protocol.encode_snapshot(trusted_payload, 1, 0, snapshot_epoch).is_empty() and Protocol.encode_snapshot(trusted_payload, 1, 2, "").is_empty())
	_check("trusted snapshot retains uncompressed size cap", Protocol.encode_snapshot({"padding": "x".repeat(Protocol.MAX_PACKET_BYTES)}, 1, 2, snapshot_epoch).is_empty())
	_check("receiver depth remains untrusted after sender optimization", Protocol.decode(Protocol.encode_snapshot(deep, 1, 2, snapshot_epoch)).is_empty())
	var many: Array = []
	many.resize(Protocol.MAX_VALUES + 1)
	many.fill(0)
	_check("general encoder retains total value budget", Protocol.encode({"many": many}).is_empty())
	_check("receiver retains total value budget", Protocol.decode(Protocol.encode_snapshot({"many": many}, 1, 2, snapshot_epoch)).is_empty())
	_check("receiver retains string and key bounds", Protocol.decode(Protocol.encode_snapshot({"long": "x".repeat(32769)}, 1, 2, snapshot_epoch)).is_empty() and Protocol.decode(Protocol.encode_snapshot({"x".repeat(65): 1}, 1, 2, snapshot_epoch)).is_empty())
	_check("sequence integer validation", not Protocol.integer(1.5, 0, 10) and Protocol.integer(5.0, 0, 10))
	var compressed := Protocol.encode({"repeated": "abc".repeat(2000)})
	_check("native Zstd roundtrip bounded", compressed.size() < 100 and Protocol.decode(compressed).repeated.length() == 6000)
	compressed.encode_u32(4, 2147483647)
	_check("reject declared decompression bomb before allocation", Protocol.decode(compressed).is_empty())
	# A clean checkout can run this test without any production private key.
	var crypto := Crypto.new()
	var key := crypto.generate_rsa(2048)
	var certificate := crypto.generate_self_signed_certificate(key, "CN=ashen-crown-relay")
	_certificate_path = "user://network-test-%d.crt" % Time.get_ticks_usec()
	_key_path = _certificate_path.trim_suffix(".crt") + ".key"
	_check("isolated test certificate generated", key.save(_key_path) == OK and certificate.save(_certificate_path) == OK)
	relay = Server.new()
	root.add_child(relay)
	var bucket_session := {"snapshot_buckets": {}}
	var accepted_burst := 0
	for _index in range(100):
		accepted_burst += int(relay._snapshot_allowed(bucket_session, 1, 1000))
	_check("snapshot limiter caps instantaneous burst at three", accepted_burst == 3)
	_check("snapshot limiter has no credit before 50ms", not relay._snapshot_allowed(bucket_session, 1, 1049))
	_check("snapshot limiter refills at twenty per second", relay._snapshot_allowed(bucket_session, 1, 1050) and not relay._snapshot_allowed(bucket_session, 1, 1050))
	_check("snapshot recipient buckets remain independent", relay._snapshot_allowed(bucket_session, 2, 1050))
	var jitter_session := {"snapshot_buckets": {}}
	var clustered_ok := true
	for arrival in [1000, 1125, 1125, 1210, 1266, 1390, 1390, 1466, 1585, 1600]:
		clustered_ok = relay._snapshot_allowed(jitter_session, 1, arrival) and clustered_ok
	_check("valid fifteen-Hz arrival clusters survive jitter", clustered_ok)
	var event_state := {"event_buckets": {}}
	var visual_burst := 0
	for _index in range(160):
		visual_burst += int(relay._event_allowed(event_state, true, 1000))
	_check("reliable visual burst bounded at one hundred fifty", visual_burst == 150)
	_check("visual refill retains hundred per second boundary", not relay._event_allowed(event_state, true, 1009) and relay._event_allowed(event_state, true, 1010))
	var critical_burst := 0
	for _index in range(60):
		critical_burst += int(relay._event_allowed(event_state, false, 1017))
	_check("critical budget independent of exhausted footsteps", critical_burst == 45)
	_check("critical refill retains thirty per second boundary", not relay._event_allowed(event_state, false, 1050) and relay._event_allowed(event_state, false, 1051))
	var clustered_events := {"event_buckets": {}}
	var event_clusters_ok := true
	for arrival in [1000, 3000, 3333, 3666, 4000, 4333]:
		for _index in range(90 if arrival == 3000 else 15):
			event_clusters_ok = relay._event_allowed(clustered_events, true, arrival) and event_clusters_ok
	_check("two seconds reliable backlog plus forty-five Hz stream survives", event_clusters_ok)
	var result: Error = relay.start("127.0.0.1", 0, _key_path, _certificate_path)
	_check("DTLS server starts", result == OK)
	if result != OK:
		_finish()
		return
	var port: int = relay.connection.get_local_port()
	for index in range(4):
		var client := _client(index)
		_check("client %d native connection begins" % index, client.connect_relay("127.0.0.1", port) == OK)
	await _until(func(): return clients.all(func(c): return c.connection_state == "connected"))
	_check("four trusted DTLS handshakes", clients.all(func(c): return c.connection_state == "connected"))
	await _until(func(): return clients.all(func(c): return c._peer != null and c._peer.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_INTERVAL) == Server.THROTTLE_INTERVAL_MS))
	_check("native RTT window applies on all client peers after handshake", clients.all(func(c): return c._peer != null and c._peer.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_INTERVAL) == 500))
	_check("native congestion deceleration remains enabled", relay._connections.values().all(func(s): return s.peer.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_INTERVAL) == 500 and s.peer.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_DECELERATION) == 1 and s.peer.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_ACCELERATION) == 4))
	if clients[0].connection_state != "connected":
		_finish()
		return
	clients[0].create_room("2v2", "房主")
	await _until(func(): return not clients[0].room.is_empty())
	_check("host slot assigned", clients[0].owner_id == 0 and clients[0].is_host)
	var code: String = clients[0].room.code
	_check("room code cryptographic length", code.length() == 8)
	for index in range(1, 4):
		clients[index].join_room(code, "玩家%d" % index)
		await _until(func(): return clients[index].owner_id == index)
	_check("four independent owners", clients.map(func(c): return c.owner_id) == [0, 1, 2, 3])
	_check("no resume tokens leaked in public room", not JSON.stringify(clients[0].room).contains("token"))
	clients[1].configure_slot(2, "human", 1)
	await _until(func(): return errors.any(func(e): return e.code == "host_only"))
	_check("guest cannot reconfigure lobby", errors.any(func(e): return e.code == "host_only"))
	clients[0].start_match()
	await _until(func(): return errors.any(func(e): return e.code == "not_ready"))
	_check("readiness enforced", starts.is_empty())
	for index in range(1, 4): clients[index].set_ready(true)
	await _until(func(): return clients[0].room.slots.all(func(s): return s.ready))
	clients[0].start_match()
	await _until(func(): return starts.size() == 4)
	_check("same match starts on four clients", starts.size() == 4)
	_check("stable map and teams", starts[0].config.map_id == "teams" and starts[0].config.players.map(func(p): return int(p.team_id)) == [0, 0, 1, 1])
	# A monotonic receive-time advance reproduces ordered ENet backlog release,
	# without an actual packet-loss wait. Packets still cross full relay validation.
	var host_peer: ENetPacketPeer = relay.sessions[clients[0]._token].peer
	var host_state: Dictionary = relay._connections[host_peer.get_instance_id()]
	var strikes_before: int = host_state.strikes
	var receive_time := Time.get_ticks_msec()
	var visual_message := {"op": "event", "match": clients[0]._match.match_id, "to": 1,
		"payload": {"kind": "visual_batch", "events": [{"kind": "sound", "sound": "footstep_dirt", "time": 1.0, "at": [0, 0, 0]}]}}
	var visual_packet := Protocol.encode(visual_message)
	for _index in range(151):
		relay._receive(host_peer, visual_packet, Protocol.EVENT_CHANNEL, receive_time)
	_check("one hundred fifty-one visual burst only expires excess presentation", relay.dropped_visual_batches == 1 and int(host_state.strikes) == strikes_before)
	for step in range(1, 11):
		for _index in range(20):
			relay._receive(host_peer, visual_packet, Protocol.EVENT_CHANNEL, receive_time + step * 100)
	_check("sustained visual excess is bounded without host disconnect", relay.dropped_visual_batches > 100 and int(host_state.strikes) == strikes_before and relay.sessions[clients[0]._token].peer == host_peer)
	var pause_packet := Protocol.encode({"op": "event", "match": clients[0]._match.match_id, "to": -1, "payload": {"kind": "pause", "paused": false}})
	relay._receive(host_peer, pause_packet, Protocol.EVENT_CHANNEL, receive_time + 1000)
	await _until(func(): return events.filter(func(e): return e.data.kind == "pause").size() == 4)
	_check("critical pause reaches all clients after full visual burst", events.filter(func(e): return e.data.kind == "pause").size() == 4)
	var malformed_visual := Protocol.encode({"op": "event", "match": clients[0]._match.match_id, "to": 1, "payload": {"kind": "visual_batch", "events": {}}})
	relay._receive(host_peer, malformed_visual, Protocol.EVENT_CHANNEL, receive_time + 1000)
	_check("exhausted visual allowance still validates message structure", int(host_state.strikes) == strikes_before + 1)
	await create_timer(1.05).timeout
	clients[2].send_command({"kind": "move", "units": [12, 13], "position": [2.0, 0.0, 5.0], "owner": 0})
	await _until(func(): return messages.size() == 1)
	_check("relay binds sender owner", messages.size() == 1 and messages[0].owner == 2)
	_check("only host receives commands", messages[0].client == 0)
	clients[2]._send({"op": "command", "match": clients[2]._match.match_id, "owner": 0, "sequence": 1, "payload": {"kind": "forged_duplicate"}})
	await _frames(8)
	_check("duplicate command sequence filtered", messages.size() == 1)
	clients[2]._send({"op": "snapshot", "to": 1, "sequence": 1, "payload": {"forged": true}}, Protocol.SNAPSHOT_CHANNEL)
	await _frames(8)
	_check("guest cannot send authoritative snapshots", snapshots.is_empty())
	_check("guest cannot enter trusted authority encoder", clients[2].snapshot_to(1, trusted_payload) == ERR_UNAUTHORIZED)
	var units: Array = []
	for index in range(280): units.append({"id": index + 1, "p": [float(index), 0.0, 5.0], "hp": 100, "kind": "swordsman"})
	_check("large snapshot send accepted", clients[0].snapshot_to(1, {"tick": 600, "units": units}) == OK)
	await _until(func(): return not snapshots.is_empty())
	_check("fragmented snapshot received intact", snapshots.size() == 1 and snapshots[0].client == 1 and snapshots[0].data.units.size() == 280)
	_check("private snapshots not broadcast", snapshots.all(func(s): return s.client == 1))
	var oversized_command := {"kind": "move", "padding": "x".repeat(5000)}
	_check("compressed command cannot bypass content limit", clients[2].send_command(oversized_command) == ERR_OUT_OF_MEMORY)
	await create_timer(1.05).timeout
	var before_burst := messages.size()
	for sequence in range(100, 203):
		clients[2]._send({"op": "command", "match": clients[2]._match.match_id, "sequence": sequence, "payload": {"kind": "move"}})
	await _until(func(): return errors.any(func(e): return e.code == "command_rate"))
	_check("command rate limited to 100 per second", messages.size() - before_burst <= 100 and errors.any(func(e): return e.code == "command_rate"))
	clients[0].send_event(-1, {"kind": "public_test", "tick": 600})
	await _until(func(): return events.filter(func(e): return e.data.kind == "public_test").size() == 4)
	_check("reliable public event broadcast", events.filter(func(e): return e.data.kind == "public_test").size() == 4)
	# Exercise immediate disconnect and authenticated resume with the token retained.
	clients[3]._peer.peer_disconnect_now()
	clients[3]._close_transport()
	await _until(func(): return events.any(func(e): return e.data.kind == "player_disconnected"))
	_check("guest disconnect reported", events.any(func(e): return e.data.kind == "player_disconnected"))
	var token: String = clients[3]._token
	if relay.sessions.has(token):
		_check("production guest reconnect grace is 120 seconds", int(relay.sessions[token].expires) - int(relay.sessions[token].disconnected) == 120000)
		var boundary := Time.get_ticks_msec()
		relay.sessions[token].disconnected = boundary - 9999
		relay._maintenance(boundary)
		_check("no Bot before ten second boundary", not relay.sessions[token].bot)
		relay.sessions[token].disconnected = boundary - 10000
		relay._maintenance(boundary)
		_check("Bot exactly at ten second boundary", relay.sessions[token].bot)
	clients[3]._open()
	await _until(func(): return events.any(func(e): return e.data.kind == "player_reconnected"))
	_check("guest reconnect keeps owner", clients[3].owner_id == 3 and clients[3].connection_state == "match")
	_check("guest resume cancels Bot ownership", relay.sessions.has(token) and not relay.sessions[token].bot)
	var returned_starts := starts.size()
	clients[3].auto_reconnect = true
	clients[3]._peer.peer_disconnect_now()
	clients[3]._lost(Time.get_ticks_msec())
	await _until(func(): return clients[3].connection_state == "match")
	_check("automatic reconnect restores live client", clients[3].connection_state == "match" and starts.size() == returned_starts)
	clients[3].auto_reconnect = false
	clients[3]._peer.peer_disconnect_now()
	clients[3]._close_transport()
	await _until(func(): return relay.sessions[token].peer == null)
	var expiry := Time.get_ticks_msec()
	relay.sessions[token].expires = expiry + 1
	relay._maintenance(expiry)
	_check("guest seat retained before reconnect deadline", relay.sessions.has(token))
	relay._maintenance(expiry + 1)
	_check("guest reconnect deadline releases secret", not relay.sessions.has(token) and relay.rooms.values()[0].slots[3].kind == "bot")
	# Host transport loss pauses rather than promoting another authority.
	clients[0]._peer.peer_disconnect_now()
	clients[0]._close_transport()
	await _until(func(): return clients[1].connection_state == "host_paused")
	_check("host loss pauses clients", clients[1].connection_state == "host_paused")
	clients[0]._open()
	await _until(func(): return events.any(func(e): return e.data.kind == "host_resumed"))
	_check("host resumes with same authority", clients[0].owner_id == 0 and clients[0].is_host and clients[1].connection_state == "match")
	_check("resume does not restart game scene", starts.size() == 4)
	# Capacity and incompatible builds are tested with real extra sockets.
	var extra := _client(4)
	extra.connect_relay("127.0.0.1", port)
	await _until(func(): return extra.connection_state == "connected")
	extra.create_room("1v1", "另一个房主")
	await _until(func(): return errors.any(func(e): return e.code == "capacity"))
	_check("configured one-match capacity", relay.rooms.size() == 1 and errors.any(func(e): return e.code == "capacity"))
	var wrong := _client(5)
	wrong.build_id = "incompatible"
	wrong.connect_relay("127.0.0.1", port)
	await _until(func(): return errors.any(func(e): return e.code == "version_mismatch"))
	_check("incompatible build rejected", wrong.owner_id == -1 and wrong.connection_state == "error")
	var wrong_content := _client(6)
	wrong_content.content_hash = "wrong-content"
	wrong_content.connect_relay("127.0.0.1", port)
	await _until(func(): return wrong_content.connection_state == "error")
	_check("different content rejected before room entry", wrong_content.connection_state == "error" and wrong_content.owner_id == -1)
	var old_protocol := _client(8)
	old_protocol.protocol_version = Protocol.VERSION - 1
	old_protocol.connect_relay("127.0.0.1", port)
	await _until(func(): return old_protocol.connection_state == "error")
	_check("old wire protocol rejected during version handshake", old_protocol.connection_state == "error" and old_protocol.owner_id == -1)
	var old_match: String = clients[0]._match.match_id
	var stale_command_count := messages.size()
	clients[2]._send({"op": "command", "match": "wrong-match-epoch", "sequence": 999, "payload": {"kind": "stale"}})
	await _frames(8)
	_check("wrong match command never reaches authority", messages.size() == stale_command_count)
	clients[0].finish_match({"winner": 0})
	await _until(func(): return relay.rooms.is_empty())
	_check("finished room releases capacity", relay.rooms.is_empty())
	var errors_before_tail := errors.size()
	clients[0]._send({"op": "snapshot", "match": old_match, "to": 1, "sequence": 999, "payload": {"late": true}}, Protocol.SNAPSHOT_CHANNEL)
	clients[0]._send({"op": "event", "match": old_match, "to": -1, "payload": {"kind": "late"}}, Protocol.EVENT_CHANNEL)
	await _frames(8)
	_check("finished match tail packets are silently drained", errors.size() == errors_before_tail)
	clients[0].leave_room()
	clients[0].create_room("1v1", "房主")
	await _until(func(): return clients[0].connection_state == "lobby")
	_check("new room has an independent random match identity", clients[0].room.match_id.length() == 32 and clients[0].room.match_id != old_match)
	clients[0]._send({"op": "finish", "match": old_match, "result": {"winner": 1}})
	await _frames(8)
	_check("old finish cannot close the next room", relay.rooms.size() == 1)
	clients[0].configure_slot(1, "bot", 1)
	await _until(func(): return clients[0].room.slots[1].kind == "bot")
	clients[0].start_match()
	await _until(func(): return clients[0].connection_state == "match")
	_check("one human versus Bot starts", clients[0]._match.players[1].controller == "bot" and clients[0]._match.map_id == "duel")
	var before_stale_event := events.size()
	var before_stale_snapshot := snapshots.size()
	clients[0]._receive({"op": "event", "match": old_match, "payload": {"kind": "match_finished", "result": {}}})
	clients[0]._receive({"op": "snapshot", "match": old_match, "sequence": 99999, "payload": {"stale": true}})
	_check("client rejects prior match events and snapshots", events.size() == before_stale_event and snapshots.size() == before_stale_snapshot and clients[0].connection_state == "match")
	clients[0]._peer.peer_disconnect_now()
	clients[0]._close_transport()
	await _until(func(): return relay.rooms.values()[0].status == "paused")
	var host_token: String = clients[0]._token
	_check("production host reconnect grace is 30 seconds", int(relay.sessions[host_token].expires) - int(relay.sessions[host_token].disconnected) == 30000)
	var now := Time.get_ticks_msec()
	relay.sessions[host_token].expires = now + 1
	relay._maintenance(now)
	_check("host grace retains room before boundary", not relay.rooms.is_empty())
	relay._maintenance(now + 1)
	_check("host timeout frees all sessions atomically", relay.rooms.is_empty() and relay.sessions.is_empty())
	# An initial DTLS attempt can fail before a room token exists. Preserve the
	# user's pending room intent and retry within one bounded initial deadline.
	var initial := _client(7)
	initial.auto_reconnect = true
	initial.connect_relay("127.0.0.1", port)
	initial.create_room("1v1", "首次握手重试")
	var initial_deadline: int = initial._reconnect_deadline
	initial._lost(Time.get_ticks_msec())
	_check("initial handshake loss retries without a token", initial._token.is_empty() and initial._retry_at > 0 and initial.connection_state == "connecting")
	_check("initial retry preserves bounded deadline", initial._reconnect_deadline == initial_deadline and initial_deadline - Time.get_ticks_msec() <= 20000)
	initial._retry_at = Time.get_ticks_msec()
	initial._process(0.0)
	await _until(func(): return initial.connection_state == "lobby")
	_check("initial retry restores queued room intent", initial.connection_state == "lobby" and initial.is_host and not initial.room.is_empty())
	initial.leave_room()
	await _until(func(): return relay.rooms.is_empty())
	_finish()

func _client(index: int) -> Node:
	var client := Client.new()
	client.auto_reconnect = false
	client.certificate_path = _certificate_path
	root.add_child(client)
	client.command_received.connect(func(owner: int, payload: Dictionary): messages.append({"client": index, "owner": owner, "data": payload}))
	client.event_received.connect(func(payload: Dictionary): events.append({"client": index, "data": payload}))
	client.snapshot_received.connect(func(payload: Dictionary): snapshots.append({"client": index, "data": payload}))
	client.error_received.connect(func(code: String, message: String): errors.append({"client": index, "code": code, "message": message}))
	client.match_started.connect(func(config: Dictionary): starts.append({"client": index, "config": config}))
	clients.append(client)
	return client

func _until(condition: Callable) -> void:
	var until := mini(Time.get_ticks_msec() + 5000, _deadline)
	while not condition.call() and Time.get_ticks_msec() < until:
		await process_frame

func _frames(count: int) -> void:
	for _index in range(count): await process_frame

func _check(name: String, passed: bool) -> void:
	checks.append({"name": name, "passed": passed})
	print("NETWORK_CHECK %s %s" % ["PASS" if passed else "FAIL", name])

func _finish() -> void:
	for client: Node in clients:
		client.disconnect_relay()
		client.queue_free()
	if is_instance_valid(relay):
		relay.stop()
		relay.queue_free()
	if not _certificate_path.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_certificate_path))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_key_path))
	var failed := checks.filter(func(c): return not c.passed).size()
	print("NETWORK_RESULTS " + JSON.stringify({"checks": checks.size(), "failed": failed}))
	quit(0 if failed == 0 else 1)
