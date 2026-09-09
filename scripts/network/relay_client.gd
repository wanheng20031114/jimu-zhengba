class_name RelayClient
extends Node
## The transport is independent of gameplay. Only the host simulates the match.

signal room_changed(room: Dictionary)
signal match_started(config: Dictionary)
signal command_received(owner: int, command: Dictionary)
signal snapshot_received(snapshot: Dictionary)
signal event_received(event: Dictionary)
signal connection_state_changed(state: String)
signal error_received(code: String, message: String)

const Protocol = preload("res://scripts/network/network_protocol.gd")
const CERTIFICATE_PATH: String = "res://scripts/network/relay_trust.crt"
const INITIAL_CONNECT_MS: int = 20000

var owner_id: int = -1
var is_host: bool = false
var room: Dictionary = {}
var connection_state: String = "disconnected"
var address: String = ""
var port: int = Protocol.PORT
var protocol_version: int = Protocol.VERSION
var build_id: String = Protocol.BUILD_ID
var content_hash: String = Protocol.content_hash()
var certificate_path: String = CERTIFICATE_PATH
var auto_reconnect: bool = true
var _connection: ENetConnection
var _peer: ENetPacketPeer
var _token: String = ""
var _intent: Dictionary = {}
var _match: Dictionary = {}
var _heartbeat_at: int = 0
var _last_received: int = 0
var _connecting_at: int = 0
var _retry_at: int = 0
var _reconnect_deadline: int = 0
var _command_sequence: int = 0
var _last_snapshot_sequence: int = -1
var _snapshot_sequences: Dictionary = {}
var _snapshot_sent_at: Dictionary = {}

func _ready() -> void:
	# Connections and grace periods continue while a gameplay SceneTree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS

func connect_relay(endpoint: String, endpoint_port: int = Protocol.PORT) -> Error:
	disconnect_relay()
	address = endpoint.strip_edges()
	port = endpoint_port
	if address.is_empty() or port < 1 or port > 65535:
		return ERR_INVALID_PARAMETER
	_reconnect_deadline = Time.get_ticks_msec() + INITIAL_CONNECT_MS
	return _open()

func _open() -> Error:
	_close_transport()
	var certificate := X509Certificate.new()
	var error := certificate.load(certificate_path)
	if error != OK:
		_fail("certificate", "无法读取受信中继证书")
		return error
	_connection = ENetConnection.new()
	error = _connection.create_host(1, Protocol.CHANNEL_COUNT)
	if error == OK:
		error = _connection.dtls_client_setup(Protocol.TLS_NAME, TLSOptions.client(certificate, Protocol.TLS_NAME))
	if error != OK:
		_close_transport()
		_fail("transport", "无法创建加密联网连接")
		return error
	_peer = _connection.connect_to_host(address, port, Protocol.CHANNEL_COUNT)
	if _peer == null:
		_close_transport()
		_fail("transport", "中继连接初始化失败")
		return ERR_CANT_CONNECT
	_peer.set_timeout(8, 2000, 5000)
	_peer.ping_interval(500)
	_connecting_at = Time.get_ticks_msec()
	_last_received = _connecting_at
	_set_state("reconnecting" if not _token.is_empty() else "connecting")
	return OK

func create_room(mode: String, nickname: String = "指挥官") -> void:
	_intent = {"op": "create", "mode": mode, "name": Protocol.nickname(nickname)}
	_flush_intent()

func join_room(code: String, nickname: String = "指挥官") -> void:
	_intent = {"op": "join", "code": code.strip_edges().to_upper(), "name": Protocol.nickname(nickname)}
	_flush_intent()

func configure_slot(owner: int, kind: String, team: int) -> void:
	_send({"op": "slot", "owner": owner, "kind": kind, "team": team})

func set_ready(value: bool) -> void:
	_send({"op": "ready", "ready": value})

func start_match() -> void:
	_send({"op": "start"})

func send_command(command: Dictionary) -> Error:
	if _match.is_empty() or connection_state != "match":
		return ERR_UNAVAILABLE
	_command_sequence += 1
	var message := {"op": "command", "match": _match.match_id, "sequence": _command_sequence, "payload": command}
	var packet := Protocol.encode(message)
	if packet.is_empty():
		return ERR_INVALID_DATA
	if Protocol.decoded_size(packet) > Protocol.MAX_COMMAND_BYTES:
		return ERR_OUT_OF_MEMORY
	return _send_packet(packet, Protocol.CONTROL_CHANNEL)

func snapshot_to(owner: int, snapshot: Dictionary) -> Error:
	if not is_host or _match.is_empty() or connection_state != "match":
		return ERR_UNAUTHORIZED
	if owner < 0 or owner > 3:
		return ERR_INVALID_PARAMETER
	var now := Time.get_ticks_msec()
	# Each recipient is independently capped; the simulation should call at 15 Hz.
	if now - int(_snapshot_sent_at.get(owner, -1000)) < 50:
		return ERR_BUSY
	var sequence: int = int(_snapshot_sequences.get(owner, 0)) + 1
	var result := _send({"op": "snapshot", "match": _match.match_id, "to": owner, "sequence": sequence, "payload": snapshot}, Protocol.SNAPSHOT_CHANNEL + owner)
	if result == OK:
		_snapshot_sequences[owner] = sequence
		_snapshot_sent_at[owner] = now
	return result

func send_event(owner: int, event: Dictionary) -> Error:
	if not is_host or _match.is_empty():
		return ERR_UNAUTHORIZED
	var message := {"op": "event", "match": _match.match_id, "to": owner, "payload": event}
	var packet := Protocol.encode(message)
	if packet.is_empty():
		return ERR_INVALID_DATA
	if Protocol.decoded_size(packet) > Protocol.MAX_EVENT_BYTES:
		return ERR_OUT_OF_MEMORY
	return _send_packet(packet, Protocol.EVENT_CHANNEL)

func finish_match(result: Dictionary) -> void:
	if is_host and not _match.is_empty():
		_send({"op": "finish", "match": _match.match_id, "result": result})

func leave_room() -> void:
	if connection_state != "finished":
		_send({"op": "leave"})
	_clear_membership()
	_set_state("connected" if _peer != null else "disconnected")

func disconnect_relay() -> void:
	if _peer != null and _peer.is_active():
		_peer.peer_disconnect_now()
	_close_transport()
	_clear_membership()
	_intent.clear()
	_retry_at = 0
	_reconnect_deadline = 0
	_set_state("disconnected")

func _clear_membership() -> void:
	_token = ""
	owner_id = -1
	is_host = false
	room.clear()
	_match.clear()
	_command_sequence = 0
	_last_snapshot_sequence = -1
	_snapshot_sequences.clear()
	_snapshot_sent_at.clear()

func _close_transport() -> void:
	_peer = null
	if _connection != null:
		_connection.destroy()
		_connection = null

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _connection != null:
		for _index in range(256):
			var event: Array = _connection.service(0)
			var type: int = event[0]
			if type == ENetConnection.EVENT_NONE:
				break
			if type == ENetConnection.EVENT_CONNECT:
				_send({"op": "hello", "version": protocol_version, "build": build_id, "content": content_hash, "resume": _token})
			elif type == ENetConnection.EVENT_RECEIVE:
				_last_received = now
				var message := Protocol.decode(event[1].get_packet())
				if message.is_empty():
					_fail("protocol", "中继返回了无效消息")
					break
				_receive(message)
				if _connection == null:
					break
			elif type in [ENetConnection.EVENT_DISCONNECT, ENetConnection.EVENT_ERROR]:
				_lost(now)
				break
		if _connection != null:
			if now - _last_received > 8000:
				_lost(now)
			elif now >= _heartbeat_at and _peer != null and _peer.get_state() == ENetPacketPeer.STATE_CONNECTED:
				_send({"op": "ping"})
				_heartbeat_at = now + 1000
			if _connection != null:
				_connection.flush()
	if _connection == null and _retry_at > 0 and now >= _retry_at:
		if now < _reconnect_deadline:
			_retry_at = 0
			_open()
		else:
			_retry_at = 0
			if _token.is_empty():
				_fail("connect_timeout", "未能连接中继，请检查网络后重试")
			else:
				_fail("reconnect_expired", "重连时间已结束")

func _receive(message: Dictionary) -> void:
	if message.get("op") in ["command", "snapshot", "event"]:
		var expected_match: String = _match.get("match_id", room.get("match_id", ""))
		if expected_match.is_empty() or message.get("match") != expected_match:
			return
	match message.get("op", ""):
		"hello":
			_reconnect_deadline = 0
			_set_state("connected")
			_flush_intent()
		"joined":
			_token = message.token
			owner_id = int(message.owner)
			is_host = bool(message.host)
			_command_sequence = int(message.get("command_sequence", 0))
			_reconnect_deadline = 0
			_set_state("lobby")
		"room":
			room = message.room
			room_changed.emit(room)
		"start":
			var resuming := not _match.is_empty()
			_match = message.config
			_last_snapshot_sequence = -1
			_set_state("match")
			if resuming:
				event_received.emit({"kind": "connection_restored", "owner": owner_id})
			else:
				match_started.emit(_match)
		"command":
			command_received.emit(int(message.owner), message.payload)
		"snapshot":
			var sequence := int(message.sequence)
			if sequence > _last_snapshot_sequence:
				_last_snapshot_sequence = sequence
				snapshot_received.emit(message.payload)
		"event":
			var payload: Dictionary = message.payload
			if payload.get("kind") == "host_paused":
				_set_state("host_paused")
			elif payload.get("kind") == "host_resumed":
				_set_state("match")
			elif payload.get("kind") in ["match_aborted", "match_finished"]:
				_set_state("finished")
			event_received.emit(payload)
		"error":
			error_received.emit(message.get("code", "unknown"), message.get("message", "连接失败"))
			if message.get("code") == "resume_pending" and not _token.is_empty():
				_lost(Time.get_ticks_msec())
				return
			if bool(message.get("fatal", false)):
				_close_transport()
				_clear_membership()
				_retry_at = 0
				_set_state("error")

func _flush_intent() -> void:
	if connection_state == "connected" and not _intent.is_empty():
		_send(_intent)
		_intent.clear()

func _send(message: Dictionary, channel: int = Protocol.CONTROL_CHANNEL) -> Error:
	if _peer == null or not _peer.is_active() or _peer.get_state() != ENetPacketPeer.STATE_CONNECTED:
		return ERR_UNAVAILABLE
	var packet := Protocol.encode(message)
	if packet.is_empty():
		return ERR_INVALID_DATA
	return _send_packet(packet, channel)

func _send_packet(packet: PackedByteArray, channel: int) -> Error:
	if _peer == null or not _peer.is_active() or _peer.get_state() != ENetPacketPeer.STATE_CONNECTED:
		return ERR_UNAVAILABLE
	return _peer.send(channel, packet, ENetPacketPeer.FLAG_UNRELIABLE_FRAGMENT if channel >= Protocol.SNAPSHOT_CHANNEL else ENetPacketPeer.FLAG_RELIABLE)

func _lost(now: int) -> void:
	_close_transport()
	if auto_reconnect and (not _token.is_empty() or _reconnect_deadline > 0):
		if _reconnect_deadline == 0:
			_reconnect_deadline = now + (30000 if is_host else 120000)
		_retry_at = now + 1000
		_set_state("connecting" if _token.is_empty() else "reconnecting")
	else:
		_set_state("disconnected")

func _fail(code: String, message: String) -> void:
	_close_transport()
	_retry_at = 0
	error_received.emit(code, message)
	_set_state("error")

func _set_state(state: String) -> void:
	if connection_state != state:
		connection_state = state
		connection_state_changed.emit(state)

func _exit_tree() -> void:
	_close_transport()
