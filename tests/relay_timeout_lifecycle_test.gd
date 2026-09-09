extends SceneTree
## Native DTLS stays alive while application pings stop. Uses an isolated relay.

const Server = preload("res://server/relay_server.gd")
const Protocol = preload("res://scripts/network/network_protocol.gd")
var relay: Node
var clients: Array[Dictionary] = []
var checks: int = 0
var failures: Array[String] = []
var deadline: int = 0
var cycles: int = 0
var certificate: X509Certificate
var relay_port: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	deadline = Time.get_ticks_msec() + 60000
	certificate = X509Certificate.new()
	_check(certificate.load("res://test-trust.crt") == OK, "read isolated trust certificate")
	relay = Server.new()
	root.add_child(relay)
	_check(relay.start("127.0.0.1", 0, "res://test-private.key", "res://test-trust.crt") == OK, "isolated native DTLS relay starts")
	if not relay.running:
		_finish()
		return
	relay_port = relay.connection.get_local_port()
	for _index in 2:
		var client := {"connection": null, "peer": null, "token": "", "owner": -1,
			"state": "", "room": {}, "match_id": "", "heartbeat": true, "heartbeat_at": 0,
			"native_connected": false, "events": []}
		clients.append(client)
		_open(client)
	await _until(func(): return clients.all(func(c): return c.state == "hello"))
	_send(clients[0], {"op": "create", "mode": "1v1", "name": "timeout host"})
	await _until(func(): return not clients[0].room.is_empty())
	if clients[0].room.is_empty():
		_finish()
		return
	_send(clients[1], {"op": "join", "code": clients[0].room.code, "name": "timeout guest"})
	await _until(func(): return clients[1].owner == 1)
	_send(clients[1], {"op": "ready", "ready": true})
	await _until(func(): return clients[0].room.slots.all(func(s): return s.ready))
	_send(clients[0], {"op": "start"})
	await _until(func(): return clients.all(func(c): return c.state == "match"))
	_check(clients.all(func(c): return c.state == "match"), "two raw native clients entered a real match")
	if clients[1].token.is_empty():
		_finish()
		return
	var token: String = clients[1].token
	var code: String = clients[0].room.code
	var match_id: String = clients[1].match_id
	clients[1].heartbeat = false
	var silence_start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - silence_start < 7000:
		await process_frame
	_check(clients[1].native_connected and clients[1].peer.get_state() == ENetPacketPeer.STATE_CONNECTED,
		"native ENet remains connected after seven seconds without application pings")
	_check(relay.sessions[token].peer != null, "application timeout has not fired before eight seconds")
	print("RELAY_TIMEOUT_PHASE natural_application_timeout_pending")
	await _until(func(): return relay.sessions[token].peer == null)
	await _until(func(): return not clients[1].native_connected)
	_check(relay.running, "relay survives natural application timeout and subsequent native service")
	_check(relay.sessions.has(token) and relay.rooms[code].slots[1].token == token,
		"guest timeout preserves authenticated seat")
	_check(int(relay.sessions[token].expires) - int(relay.sessions[token].disconnected) == 120000,
		"guest retains full reconnect grace")
	_check(relay.rooms[code].status == "match", "guest timeout does not pause host")
	await _resume_guest(token, match_id)
	# Repeat the same production maintenance path with only the receive timestamp
	# aged. Each iteration has a new real DTLS connection and no mocked ENet peer.
	for index in 32:
		clients[1].heartbeat = false
		var peer: ENetPacketPeer = relay.sessions[token].peer
		relay._connections[peer.get_instance_id()].at = Time.get_ticks_msec() - 8001
		relay._maintenance(Time.get_ticks_msec())
		await _until(func(): return not clients[1].native_connected)
		_check(relay.running and relay.sessions[token].peer == null,
			"relay remains live after timeout cycle %d" % index)
		if index == 0:
			relay.sessions[token].disconnected = Time.get_ticks_msec() - 10000
			relay._maintenance(Time.get_ticks_msec())
			_check(relay.sessions[token].bot, "guest is transferred to Bot after ten seconds")
		await _resume_guest(token, match_id)
		cycles += 1
	# Host expiry uses the existing production semantics too: pause, then abort.
	clients[0].heartbeat = false
	var host_token: String = clients[0].token
	var host_peer: ENetPacketPeer = relay.sessions[host_token].peer
	relay._connections[host_peer.get_instance_id()].at = Time.get_ticks_msec() - 8001
	relay._maintenance(Time.get_ticks_msec())
	await _until(func(): return not clients[0].native_connected)
	_check(relay.running and relay.rooms[code].status == "paused", "host application timeout pauses the room without crashing")
	_check(int(relay.sessions[host_token].expires) - int(relay.sessions[host_token].disconnected) == 30000,
		"host retains thirty second grace")
	relay.sessions[host_token].expires = Time.get_ticks_msec() - 1
	relay._maintenance(Time.get_ticks_msec())
	_check(relay.rooms.is_empty() and relay.sessions.is_empty(), "host expiry removes complete room and tokens")
	await process_frame
	_finish()

func _resume_guest(token: String, match_id: String) -> void:
	clients[1].heartbeat = true
	_open(clients[1])
	await _until(func(): return clients[1].state == "match")
	_check(clients[1].owner == 1 and clients[1].token == token and clients[1].match_id == match_id,
		"resume preserves owner token and running match")
	_check(relay.sessions[token].peer != null and not relay.sessions[token].bot,
		"resume restores human control without duplicate session")

func _open(client: Dictionary) -> void:
	_close(client)
	client.state = "connecting"
	client.connection = ENetConnection.new()
	_check(client.connection.create_host(1, Protocol.CHANNEL_COUNT) == OK, "native client host created")
	_check(client.connection.dtls_client_setup(Protocol.TLS_NAME, TLSOptions.client(certificate, Protocol.TLS_NAME)) == OK,
		"native verified client DTLS configured")
	client.peer = client.connection.connect_to_host("127.0.0.1", relay_port, Protocol.CHANNEL_COUNT)
	client.peer.ping_interval(200)
	client.peer.set_timeout(8, 2000, 5000)
	client.heartbeat_at = 0

func _process(_delta: float) -> bool:
	for client: Dictionary in clients:
		_poll(client)
	return false

func _poll(client: Dictionary) -> void:
	if client.connection == null:
		return
	for _index in 128:
		var event: Array = client.connection.service(0)
		match int(event[0]):
			ENetConnection.EVENT_NONE:
				break
			ENetConnection.EVENT_CONNECT:
				client.native_connected = true
				_send(client, {"op": "hello", "version": Protocol.VERSION, "build": Protocol.BUILD_ID,
					"content": Protocol.content_hash(), "resume": client.token})
			ENetConnection.EVENT_RECEIVE:
				var message: Dictionary = Protocol.decode(event[1].get_packet())
				match message.get("op"):
					"hello": client.state = "hello"
					"joined":
						client.token = message.token
						client.owner = int(message.owner)
						client.state = "lobby"
					"room": client.room = message.room
					"start":
						client.match_id = message.config.match_id
						client.state = "match"
					"event": client.events.append(message.payload.kind)
					"error": _check(false, "relay rejected message: " + String(message.code))
			ENetConnection.EVENT_DISCONNECT, ENetConnection.EVENT_ERROR:
				_close(client)
				client.state = "disconnected"
				return
	var now := Time.get_ticks_msec()
	if client.native_connected and client.heartbeat and now >= int(client.heartbeat_at):
		_send(client, {"op": "ping"})
		client.heartbeat_at = now + 500
	client.connection.flush()

func _send(client: Dictionary, message: Dictionary) -> void:
	if client.peer != null and client.peer.get_state() == ENetPacketPeer.STATE_CONNECTED:
		client.peer.send(Protocol.CONTROL_CHANNEL, Protocol.encode(message), ENetPacketPeer.FLAG_RELIABLE)

func _close(client: Dictionary) -> void:
	client.native_connected = false
	client.peer = null
	if client.connection != null:
		client.connection.destroy()
		client.connection = null

func _until(condition: Callable) -> void:
	var local_deadline := mini(deadline, Time.get_ticks_msec() + 12000)
	while not condition.call() and Time.get_ticks_msec() < local_deadline:
		await process_frame
	_check(bool(condition.call()), "bounded native lifecycle condition")

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error(label)

func _finish() -> void:
	for client: Dictionary in clients:
		_close(client)
	clients.clear()
	if relay != null:
		relay.stop()
		relay.queue_free()
	await process_frame
	print("RELAY_TIMEOUT_RESULTS " + JSON.stringify({"checks": checks, "failures": failures, "cycles": cycles,
		"engine": Engine.get_version_info().string, "natural_silence_seconds": 8, "accelerated_cycles": 32}))
	quit(0 if failures.is_empty() else 1)
