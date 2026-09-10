class_name JimuRelayServer
extends Node
## No world state, simulation, credentials, or client-selected identity in relay packets.

const Protocol = preload("res://scripts/network/network_protocol.gd")
const HOST_GRACE_MS: int = 30000
const BOT_GRACE_MS: int = 10000
const REJOIN_GRACE_MS: int = 120000
const IDLE_ROOM_MS: int = 900000
const MAX_ROOMS: int = 16
const CONNECTION_RESERVE: int = 16
const DIAGNOSTIC_EVENTS_PER_SECOND: int = 64
const DIAGNOSTIC_URGENT_PER_SECOND: int = 32
const MAX_UI_NOTICE_CHARS: int = 512
const DIAGNOSTIC_OPERATIONS: Array[String] = ["hello", "ping", "create", "join", "slot", "ready", "start", "command", "snapshot", "event", "finish", "leave"]
const VISUAL_EVENT_RATE: float = 20.0
const VISUAL_EVENT_BURST: float = 60.0
const CRITICAL_EVENT_RATE: float = 30.0
const CRITICAL_EVENT_BURST: float = 90.0
const RECEIVE_BURST_SECONDS: float = 3.0
const CLIENT_PACKET_RATE: float = 200.0
const HOST_BASE_PACKET_RATE: float = 170.0 # Control 120 + broadcast visual 20 + critical 30.
const HOST_RECIPIENT_PACKET_RATE: float = 70.0 # Snapshot 20 + visual 20 + critical 30.
const CLIENT_WIRE_RATE: float = 2097152.0
const CLIENT_DECODED_RATE: float = 4194304.0
const HOST_WIRE_RATE: float = 12582912.0
const HOST_DECODED_RATE: float = 100663296.0
const THROTTLE_INTERVAL_MS: int = 500
const THROTTLE_ACCELERATION: int = 4
const THROTTLE_DECELERATION: int = 1
# Expected room decisions are recoverable feedback, not hostile packets. Native
# rate limits still bound repeated requests; malformed/forged messages accrue strikes.
const ROOM_FEEDBACK_CODES: Array[String] = ["not_ready", "opponents_required", "team_capacity", "human_host_required", "ffa_independent", "occupied_slot", "room_full", "room_missing", "match_started", "capacity", "already_joined", "resume_pending"]

var max_rooms: int = 8
var max_humans: int = Protocol.MAX_PLAYERS
var peer_capacity: int = 0
var content_hash: String = Protocol.content_hash()
var running: bool = false
var rejected_packets: int = 0
var relayed_commands: int = 0
var relayed_snapshots: int = 0
var dropped_visual_batches: int = 0
var dropped_notices: int = 0
var dropped_notice_rate: int = 0
var dropped_snapshots: int = 0
var relayed_visual_batches: int = 0
var relayed_critical_events: int = 0
var connection: ENetConnection
var rooms: Dictionary = {}
var sessions: Dictionary = {}
var _connections: Dictionary = {}
var _crypto := Crypto.new()
var _maintenance_at: int = 0
var _room_serial: int = 0
var diagnostic_emitted: int = 0
var diagnostic_suppressed: int = 0
var _diagnostic_window: int = 0
var _diagnostic_events: int = 0
var _diagnostic_urgent: int = 0
var _diagnostic_summary_at: int = 0
var _diagnostic_reported_suppressed: int = 0
var _diagnostic_reported_notices: int = 0
var _traffic_packets := PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
var _traffic_wire_bytes := PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
var _traffic_decoded_bytes := PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
var _traffic_reported: Dictionary = {}
var _traffic_summary_at: int = 0

func start(bind_address: String, port: int, key_path: String, cert_path: String) -> Error:
	var key := CryptoKey.new()
	var certificate := X509Certificate.new()
	if key.load(key_path) != OK or certificate.load(cert_path) != OK:
		return ERR_CANT_OPEN
	max_rooms = clampi(max_rooms, 1, MAX_ROOMS)
	max_humans = clampi(max_humans, 1, Protocol.MAX_PLAYERS)
	# Room-local owner IDs stay 0..7. Extra peers are for handshakes/reconnects
	# and connected lobby clients; they do not increase any room's human limit.
	peer_capacity = max_rooms * max_humans + CONNECTION_RESERVE
	connection = ENetConnection.new()
	var result := connection.create_host_bound(bind_address, port, peer_capacity, Protocol.CHANNEL_COUNT)
	if result == OK:
		result = connection.dtls_server_setup(TLSOptions.server(key, certificate))
	if result != OK:
		stop()
		return result
	running = true
	_diagnostic("started", {"protocol": Protocol.VERSION, "room_limit": max_rooms, "humans_per_room": max_humans, "human_seats": max_rooms * max_humans, "peer_capacity": peer_capacity})
	return OK

func stop() -> void:
	if running: _diagnostic("stopped")
	running = false
	_connections.clear()
	sessions.clear()
	rooms.clear()
	if connection != null:
		connection.destroy()
		connection = null

func _process(_delta: float) -> void:
	if not running:
		return
	var now := Time.get_ticks_msec()
	for _index in range(512):
		var event: Array = connection.service(0)
		# Decode/validation can span a meaningful portion of a second. Do not
		# charge the whole serviced batch to the clock captured before its first packet.
		now = Time.get_ticks_msec()
		match int(event[0]):
			ENetConnection.EVENT_NONE:
				break
			ENetConnection.EVENT_CONNECT:
				var peer: ENetPacketPeer = event[1]
				peer.set_timeout(8, 2000, 5000)
				peer.ping_interval(500)
				# The native default keeps a five-second idle RTT baseline. A full
				# roster reveal/first move can then suppress every snapshot for over
				# a second. Refresh the baseline while retaining congestion response.
				# Configure only after CONNECT; ENet reliably applies it to both ends.
				peer.throttle_configure(THROTTLE_INTERVAL_MS, THROTTLE_ACCELERATION, THROTTLE_DECELERATION)
				_connections[peer.get_instance_id()] = {"peer": peer, "token": "", "hello": false, "match_ended": false, "at": now, "window": now, "bytes": 0, "packets": 0, "commands": 0, "events": 0, "event_buckets": {}, "receive_bucket": {}, "control": 0, "strikes": 0, "last_op": "unparsed", "last_channel": -1, "packet_bytes": 0, "decoded_bytes": 0, "budget_kind": ""}
				_peer_diagnostic("connected", peer)
			ENetConnection.EVENT_RECEIVE:
				var peer: ENetPacketPeer = event[1]
				_receive(peer, peer.get_packet(), int(event[3]), now)
			ENetConnection.EVENT_DISCONNECT:
				_drop_connection(event[1], now)
			ENetConnection.EVENT_ERROR:
				push_error("RELAY_TRANSPORT_ERROR")
				stop()
				return
	now = Time.get_ticks_msec()
	if now >= _maintenance_at:
		_maintenance_at = now + 100
		_maintenance(now)
	connection.flush()

func _receive(peer: ENetPacketPeer, packet: PackedByteArray, channel: int, now: int) -> void:
	var id := peer.get_instance_id()
	if not _connections.has(id):
		return
	var state: Dictionary = _connections[id]
	state.last_op = "unparsed"
	state.last_channel = channel
	state.packet_bytes = packet.size()
	state.decoded_bytes = Protocol.decoded_size(packet)
	state.budget_kind = ""
	if channel < Protocol.CONTROL_CHANNEL or channel >= Protocol.CHANNEL_COUNT:
		_reject(peer, "invalid_channel", "消息通道不正确")
		return
	_traffic_packets[channel] += 1
	_traffic_wire_bytes[channel] += packet.size()
	_traffic_decoded_bytes[channel] += maxi(0, int(state.decoded_bytes))
	if now - int(state.window) >= 1000:
		state.window = now
		state.bytes = 0
		state.packets = 0
		state.commands = 0
		state.events = 0
		state.control = 0
	state.bytes += packet.size()
	state.packets += 1
	# Charge every packet before decompression, including rejected messages.
	# Only a server-bound host identity receives the room's recipient-scaled budget.
	if not _receive_allowed(state, packet.size(), maxi(0, int(state.decoded_bytes)), now):
		_reject(peer, "rate_limit", "发送频率超过上限", true)
		return
	# Reject large low-privilege packets before bounded decompression/JSON parsing.
	var decoded_bytes: int = Protocol.decoded_size(packet)
	if (channel == Protocol.CONTROL_CHANNEL and decoded_bytes > Protocol.MAX_COMMAND_BYTES) or (channel == Protocol.EVENT_CHANNEL and decoded_bytes > Protocol.MAX_EVENT_BYTES):
		_reject(peer, "payload_size", "消息内容超过通道大小上限")
		return
	if channel >= Protocol.SNAPSHOT_CHANNEL and (not sessions.has(state.token) or int(sessions[state.token].owner) != 0):
		if state.match_ended and state.token.is_empty():
			return
		_reject(peer, "host_only", "仅房主可以发送权威状态")
		return
	var message := Protocol.decode(packet)
	if message.is_empty() or not message.get("op") is String:
		_reject(peer, "invalid_packet", "无效的网络消息")
		return
	var op: String = message.op
	state.last_op = op if op in DIAGNOSTIC_OPERATIONS else "unknown"
	if not state.hello:
		if op != "hello" or channel != Protocol.CONTROL_CHANNEL:
			_reject(peer, "handshake_required", "请先完成版本握手", true)
			return
		_hello(peer, message, now)
		return
	if op == "snapshot":
		if not Protocol.integer(message.get("to"), 0, Protocol.MAX_PLAYERS - 1) or channel != Protocol.SNAPSHOT_CHANNEL + int(message.to):
			_reject(peer, "invalid_channel", "快照通道不正确")
			return
	elif op == "event":
		state.events += 1
		if channel != Protocol.EVENT_CHANNEL:
			_reject(peer, "invalid_channel", "事件通道不正确")
			return
	else:
		state.control += 1
		if channel != Protocol.CONTROL_CHANNEL or Protocol.decoded_size(packet) > Protocol.MAX_COMMAND_BYTES or state.control > 120:
			_reject(peer, "control_limit", "指令超过限制")
			return
	state.at = now
	if op == "ping":
		_send(peer, {"op": "pong"})
		return
	if op == "create":
		_create(peer, message, now)
		return
	if op == "join":
		_join(peer, message, now)
		return
	var token: String = state.token
	if not sessions.has(token):
		if state.match_ended and op in ["command", "snapshot", "event", "finish"]:
			return
		_reject(peer, "room_required", "请先进入房间")
		return
	var session: Dictionary = sessions[token]
	if not rooms.has(session.code):
		_reject(peer, "room_closed", "房间已关闭", true)
		return
	var room: Dictionary = rooms[session.code]
	# Reliable control and unreliable snapshots can arrive across a match
	# transition in different orders. A fresh room never accepts the old epoch.
	if op in ["command", "snapshot", "event", "finish"] and message.get("match") != room.match_id:
		return
	room.touched = now
	match op:
		"slot": _configure_slot(peer, session, room, message)
		"ready":
			if room.status == "lobby" and message.get("ready") is bool:
				session.ready = message.ready
				_broadcast_room(room)
		"start": _start_match(peer, session, room)
		"command": _command(peer, session, room, message)
		"snapshot", "event": _host_packet(peer, session, room, message, packet, now)
		"finish":
			if int(session.owner) != 0:
				_reject(peer, "host_only", "仅房主可以发布对局结果")
			elif room.status in ["match", "paused"]:
				if not message.get("result") is Dictionary or not _valid_winner(room, message.result.get("winner")):
					_reject(peer, "invalid_result", "无效的胜方阵营")
				else:
					_end_room(room, {"kind": "match_finished", "result": message.result})
		"leave": _leave(peer, session, room, now)
		_: _reject(peer, "unknown_operation", "未知网络操作")

func _valid_winner(room: Dictionary, winner: Variant) -> bool:
	if not Protocol.integer(winner, -1, int(Protocol.MODES[room.mode].teams) - 1):
		return false
	return int(winner) == -1 or room.slots.any(func(slot: Dictionary): return slot.kind != "open" and int(slot.team_id) == int(winner))

func _receive_allowed(state: Dictionary, wire_bytes: int, decoded_bytes: int, now: int) -> bool:
	var session: Dictionary = sessions.get(state.token, {})
	var room: Dictionary = rooms.get(session.get("code", ""), {})
	var host: bool = state.hello and session.get("owner", -1) == 0 and session.get("peer") == state.peer and room.get("status") in ["match", "paused"]
	# Updated on room membership changes, not by scanning recipients per packet.
	var recipients: int = int(room.get("remote_humans", 0)) if host else 0
	var profile: int = recipients + 1 if host else 0
	var packet_rate: float = HOST_BASE_PACKET_RATE + HOST_RECIPIENT_PACKET_RATE * recipients if host else CLIENT_PACKET_RATE
	var wire_rate: float = HOST_WIRE_RATE if host else CLIENT_WIRE_RATE
	var decoded_rate: float = HOST_DECODED_RATE if host else CLIENT_DECODED_RATE
	var bucket: Dictionary = state.receive_bucket
	if bucket.is_empty():
		bucket = {"profile": profile, "at": now, "packets": packet_rate * RECEIVE_BURST_SECONDS, "wire": wire_rate * RECEIVE_BURST_SECONDS, "decoded": decoded_rate * RECEIVE_BURST_SECONDS}
		state.receive_bucket = bucket
	# Lobby/match or membership transitions change the ceiling, not accrued
	# credit. Repeated room creation must not mint a fresh burst on each change.
	bucket.profile = profile
	var elapsed: float = maxi(0, now - int(bucket.at)) / 1000.0
	bucket.at = now
	bucket.packets = minf(packet_rate * RECEIVE_BURST_SECONDS, float(bucket.packets) + elapsed * packet_rate) - 1.0
	bucket.wire = minf(wire_rate * RECEIVE_BURST_SECONDS, float(bucket.wire) + elapsed * wire_rate) - wire_bytes
	bucket.decoded = minf(decoded_rate * RECEIVE_BURST_SECONDS, float(bucket.decoded) + elapsed * decoded_rate) - decoded_bytes
	state.packet_rate = packet_rate
	state.packet_burst = packet_rate * RECEIVE_BURST_SECONDS
	state.budget_kind = "packets" if bucket.packets < 0.0 else ("wire_bytes" if bucket.wire < 0.0 else ("decoded_bytes" if bucket.decoded < 0.0 else ""))
	return state.budget_kind.is_empty()

func _hello(peer: ENetPacketPeer, message: Dictionary, now: int) -> void:
	if message.get("version") != Protocol.VERSION or message.get("build") != Protocol.BUILD_ID or message.get("content") != content_hash:
		_reject(peer, "version_mismatch", "游戏版本不一致，请更新后重试", true)
		return
	var state: Dictionary = _connections[peer.get_instance_id()]
	state.hello = true
	var resume: Variant = message.get("resume", "")
	if not resume is String or resume.length() > 128:
		_reject(peer, "invalid_resume", "无效的重连凭据", true)
		return
	if resume.is_empty():
		_send(peer, {"op": "hello", "version": Protocol.VERSION, "build": Protocol.BUILD_ID})
		_peer_diagnostic("handshake_accepted", peer)
		return
	if not sessions.has(resume):
		_reject(peer, "resume_expired", "席位已失效，请重新创建房间", true)
		return
	var session: Dictionary = sessions[resume]
	if session.peer != null:
		_reject(peer, "resume_pending", "正在确认旧连接已断开，请稍候")
		return
	if now > int(session.expires) or not rooms.has(session.code):
		_reject(peer, "resume_unavailable", "该席位无法重连", true)
		return
	var room: Dictionary = rooms[session.code]
	session.peer = peer
	session.disconnected = 0
	session.expires = 0
	session.bot = false
	state.token = resume
	_peer_diagnostic("resumed", peer)
	_joined(peer, session, resume)
	_broadcast_room(room)
	if room.status in ["match", "paused"]:
		_send(peer, {"op": "start", "config": _match_config(room)})
		if int(session.owner) == 0:
			room.status = "match"
			_broadcast_event(room, {"kind": "host_resumed", "owner": 0})
		else:
			_broadcast_event(room, {"kind": "player_reconnected", "owner": int(session.owner)})
			if room.status == "paused":
				_send(peer, {"op": "event", "match": room.match_id, "payload": {"kind": "host_paused", "owner": 0}}, Protocol.EVENT_CHANNEL)

func _create(peer: ENetPacketPeer, message: Dictionary, now: int) -> void:
	if not _connections[peer.get_instance_id()].token.is_empty():
		_reject(peer, "already_joined", "已在房间中")
		return
	if rooms.size() >= max_rooms:
		_reject(peer, "capacity", "中继当前对局已满，请稍后重试")
		return
	if message.get("mode") not in Protocol.MODES:
		_reject(peer, "mode", "无效的对局模式")
		return
	var count: int = Protocol.MODES[message.mode].slots
	var slots: Array = []
	for owner in range(count):
		slots.append({"owner_id": owner, "team_id": Protocol.default_alliance(message.mode, owner), "kind": "open", "token": "", "bot_difficulty": "normal"})
	var code := _code()
	_room_serial += 1
	var room := {"code": code, "diagnostic_id": _room_serial, "match_id": _crypto.generate_random_bytes(16).hex_encode(), "mode": message.mode, "slots": slots, "status": "lobby", "touched": now, "seed": _crypto.generate_random_bytes(4).decode_u32(0) & 0x7fffffff}
	rooms[code] = room
	_diagnostic("room_created", {"room": _room_serial, "mode": message.mode})
	_assign(peer, room, 0, Protocol.nickname(message.get("name")))
	_broadcast_room(room)

func _join(peer: ENetPacketPeer, message: Dictionary, _now: int) -> void:
	if not _connections[peer.get_instance_id()].token.is_empty():
		_reject(peer, "already_joined", "已在房间中")
		return
	var code: Variant = message.get("code")
	if not code is String or not rooms.has(code):
		_reject(peer, "room_missing", "未找到邀请码对应的房间")
		return
	var room: Dictionary = rooms[code]
	if room.status != "lobby":
		_reject(peer, "match_started", "对局已经开始")
		return
	var humans := 0
	var available := -1
	for slot: Dictionary in room.slots:
		if slot.kind == "human": humans += 1
		elif slot.kind == "open" and available < 0: available = int(slot.owner_id)
	if available < 0 or humans >= max_humans:
		_reject(peer, "room_full", "房间没有空余席位")
		return
	_assign(peer, room, available, Protocol.nickname(message.get("name")))
	_broadcast_room(room)

func _assign(peer: ENetPacketPeer, room: Dictionary, owner: int, name: String) -> void:
	var token := _crypto.generate_random_bytes(32).hex_encode()
	var session := {"owner": owner, "name": name, "code": room.code, "peer": peer, "ready": owner == 0, "disconnected": 0, "expires": 0, "bot": false, "command_sequence": 0, "snapshot_buckets": {}}
	sessions[token] = session
	_connections[peer.get_instance_id()].token = token
	_connections[peer.get_instance_id()].match_ended = false
	room.slots[owner].kind = "human"
	room.slots[owner].bot_difficulty = "normal"
	room.slots[owner].token = token
	_peer_diagnostic("joined", peer)
	_joined(peer, session, token)

func _joined(peer: ENetPacketPeer, session: Dictionary, token: String) -> void:
	_send(peer, {"op": "joined", "token": token, "owner": session.owner, "host": int(session.owner) == 0, "command_sequence": session.command_sequence})

func _configure_slot(peer: ENetPacketPeer, session: Dictionary, room: Dictionary, message: Dictionary) -> void:
	if int(session.owner) != 0 or room.status != "lobby":
		_reject(peer, "host_only", "仅房主可以设置房间")
		return
	if not Protocol.integer(message.get("owner"), 0, room.slots.size() - 1) or not Protocol.integer(message.get("team"), 0, int(Protocol.MODES[room.mode].teams) - 1) or message.get("kind") not in ["open", "bot", "human"]:
		_reject(peer, "invalid_slot", "无效的席位设置")
		return
	var difficulty: Variant = message.get("bot_difficulty", "normal")
	if difficulty not in Protocol.BOT_DIFFICULTIES or (message.kind != "bot" and difficulty != "normal"):
		_reject(peer, "invalid_difficulty", "仅电脑席位可以设置有效的电脑难度")
		return
	if room.mode == "ffa" and int(message.team) != int(message.owner):
		_reject(peer, "ffa_independent", "乱斗中每名玩家独立作战，不能加入其他队伍")
		return
	var slot: Dictionary = room.slots[int(message.owner)]
	if (slot.kind == "human") != (message.kind == "human"):
		_reject(peer, "occupied_slot", "不能替换已加入的玩家或创建虚假玩家")
		return
	slot.kind = message.kind
	slot.team_id = int(message.team)
	slot.bot_difficulty = difficulty
	for token: String in sessions:
		if sessions[token].code == room.code and int(sessions[token].owner) != 0:
			sessions[token].ready = false
	_broadcast_room(room)

func _start_match(peer: ENetPacketPeer, session: Dictionary, room: Dictionary) -> void:
	if int(session.owner) != 0 or room.status != "lobby":
		_reject(peer, "host_only", "仅房主可以开始对局")
		return
	var roster_error := Protocol.room_start_error(_room_view(room))
	if not roster_error.is_empty():
		var explanation: String = {"team_capacity": "队伍人数超过该模式上限", "opponents_required": "至少需要两个实际参战阵营", "human_host_required": "需要一名真人房主", "not_ready": "还有玩家未准备或连接中断"}.get(roster_error, "席位配置无效")
		_reject(peer, roster_error, explanation)
		return
	room.status = "match"
	_diagnostic("match_started", {"room": room.diagnostic_id, "mode": room.mode})
	_broadcast_room(room)
	_broadcast(room, {"op": "start", "config": _match_config(room)})

func _command(peer: ENetPacketPeer, session: Dictionary, room: Dictionary, message: Dictionary) -> void:
	if room.status != "match" or not message.get("payload") is Dictionary or not Protocol.integer(message.get("sequence"), 1, 2147483647):
		_reject(peer, "invalid_command", "当前不能发送该指令")
		return
	if int(message.sequence) <= int(session.command_sequence):
		return
	var state: Dictionary = _connections[peer.get_instance_id()]
	state.commands += 1
	if state.commands > 100:
		_reject(peer, "command_rate", "指令发送过快")
		return
	session.command_sequence = int(message.sequence)
	var host: Dictionary = sessions[room.slots[0].token]
	if host.peer != null:
		# The origin is bound here, never copied from a client supplied owner field.
		_send(host.peer, {"op": "command", "match": room.match_id, "owner": int(session.owner), "payload": message.payload})
		relayed_commands += 1

func _host_packet(peer: ENetPacketPeer, session: Dictionary, room: Dictionary, message: Dictionary, packet: PackedByteArray, now: int) -> void:
	if int(session.owner) != 0 or not message.get("payload") is Dictionary or not Protocol.integer(message.get("to"), -1, room.slots.size() - 1):
		_reject(peer, "host_only", "仅房主可以发送权威状态")
		return
	# A legitimate in-flight state packet can cross the pause transition. It
	# cannot advance the frozen match, and is not an ownership violation.
	if room.status != "match":
		return
	var recipient := int(message.to)
	if recipient >= 0 and room.slots[recipient].kind != "human":
		# UI notices have no receiver for a Bot. Older released hosts also emit
		# these on Bot construction/training completion. Authenticated, bounded
		# notices are undeliverable, not a host ownership violation. This narrow
		# case follows all transport/epoch/host checks and never forwards data;
		# snapshots, other events, open slots, and malformed notices still reject.
		if message.op == "event" and room.slots[recipient].kind == "bot" and _undeliverable_notice(message.payload):
			dropped_notices += 1
			return
		_reject(peer, "inactive_recipient", "仅能向已加入的真人发送状态")
		return
	if message.op == "snapshot":
		if recipient < 0 or not Protocol.integer(message.get("sequence"), 0, 2147483647):
			_reject(peer, "invalid_snapshot", "快照需要明确接收者和序号")
			return
		if not _snapshot_allowed(session, recipient, now):
			dropped_snapshots += 1
			return
		# The original bounded JSON frame has already passed sender, recipient,
		# channel, epoch, sequence and primitive validation. Receivers ignore the
		# routing-only `to` field. Keep its bytes instead of stringify+Zstd again.
		if _send_encoded_owner(room, recipient, packet, Protocol.SNAPSHOT_CHANNEL):
			relayed_snapshots += 1
	else:
		# Relay lifecycle messages are reserved; a host cannot fake another connection.
		if message.payload.get("kind", "") in ["host_paused", "host_resumed", "match_aborted", "player_disconnected", "player_reconnected", "bot_takeover"]:
			_reject(peer, "reserved_event", "该事件由中继管理")
			return
		var visual: bool = message.payload.get("kind") == "visual_batch"
		# Check the recipient's presentation allowance before walking up to 96
		# items. Bounded JSON decoding remains necessary to identify a compressed
		# event, and the predecode byte/packet buckets bound that work separately.
		var state: Dictionary = _connections[peer.get_instance_id()]
		if not _event_allowed(state, visual, recipient, now):
			if visual:
				dropped_visual_batches += 1
			elif _undeliverable_notice(message.payload):
				# Many legitimate completions can share a tick. A UI notice is
				# expendable; it must never turn batch production into a host kick.
				dropped_notice_rate += 1
			else:
				_reject(peer, "event_limit", "关键事件发送过快")
			return
		if visual and not _visual_batch_structure(message.payload):
			_reject(peer, "invalid_visual_batch", "无效的表现批次")
			return
		if recipient == -1:
			for slot: Dictionary in room.slots:
				_send_encoded_owner(room, int(slot.owner_id), packet, Protocol.EVENT_CHANNEL)
		else:
			_send_encoded_owner(room, recipient, packet, Protocol.EVENT_CHANNEL)
		if visual: relayed_visual_batches += 1
		else: relayed_critical_events += 1

static func _undeliverable_notice(payload: Dictionary) -> bool:
	return payload.size() == 2 and payload.get("kind") == "notice" and payload.get("text") is String and not payload.text.is_empty() and payload.text.length() <= MAX_UI_NOTICE_CHARS

static func _visual_batch_structure(payload: Dictionary) -> bool:
	var items: Variant = payload.get("events")
	if not items is Array or items.is_empty() or items.size() > 96:
		return false
	for item: Variant in items:
		if not item is Dictionary or not item.get("kind") is String:
			return false
		var stamp: Variant = item.get("time")
		if not (stamp is int or stamp is float) or not is_finite(stamp) or stamp < 0 or stamp > 10000000:
			return false
	return true

func _snapshot_allowed(session: Dictionary, recipient: int, now: int) -> bool:
	# A 15 Hz stream can arrive in small clusters after jitter. A strict minimum
	# arrival interval throws away healthy updates; this bounded bucket accepts
	# the cluster while retaining a 20 Hz sustained rate and only three credits.
	var bucket: Dictionary = session.snapshot_buckets.get(recipient, {"at": now, "credits": 3.0})
	bucket.credits = minf(3.0, float(bucket.credits) + maxi(0, now - int(bucket.at)) * 0.02)
	bucket.at = now
	session.snapshot_buckets[recipient] = bucket
	if float(bucket.credits) < 1.0:
		return false
	bucket.credits -= 1.0
	return true

func _event_allowed(state: Dictionary, visual: bool, recipient: int, now: int) -> bool:
	# Ordered reliable delivery can release >1s of accumulated visual batches
	# together after a lost fragment. Retain a bounded burst, and reserve an
	# independent budget for pause/notices so footsteps cannot consume it.
	# A full room legitimately has seven independent 15 Hz visual streams.
	# Broadcasting uses its own bounded stream; it never consumes private slots.
	var key: int = (recipient + 1) * 2 + (0 if visual else 1)
	var capacity: float = VISUAL_EVENT_BURST if visual else CRITICAL_EVENT_BURST
	var rate: float = VISUAL_EVENT_RATE if visual else CRITICAL_EVENT_RATE
	var bucket: Dictionary = state.event_buckets.get(key, {"at": now, "credits": capacity})
	bucket.credits = minf(capacity, float(bucket.credits) + maxi(0, now - int(bucket.at)) * rate / 1000.0)
	bucket.at = now
	state.event_buckets[key] = bucket
	if float(bucket.credits) < 1.0:
		return false
	bucket.credits -= 1.0
	return true

func _drop_connection(peer: ENetPacketPeer, now: int, reason: String = "transport_disconnect") -> void:
	var id := peer.get_instance_id()
	if not _connections.has(id): return
	_peer_diagnostic("disconnected", peer, {"reason": reason})
	var token: String = _connections[id].token
	_connections.erase(id)
	if not sessions.has(token): return
	var session: Dictionary = sessions[token]
	session.peer = null
	session.disconnected = now
	session.expires = now + (HOST_GRACE_MS if int(session.owner) == 0 else REJOIN_GRACE_MS)
	if not rooms.has(session.code): return
	var room: Dictionary = rooms[session.code]
	if room.status in ["match", "paused"]:
		if int(session.owner) == 0:
			room.status = "paused"
			_broadcast_event(room, {"kind": "host_paused", "owner": 0, "grace_seconds": 30})
		else:
			_broadcast_event(room, {"kind": "player_disconnected", "owner": int(session.owner), "bot_in_seconds": 10, "reconnect_seconds": 120})
	_broadcast_room(room)

func _maintenance(now: int) -> void:
	for id: int in _connections.keys():
		var state: Dictionary = _connections[id]
		if now - int(state.at) > (8000 if state.hello else 5000):
			var peer: ENetPacketPeer = state.peer
			_drop_connection(peer, now, "application_timeout" if state.hello else "handshake_timeout")
			peer.peer_disconnect()
	for token: String in sessions.keys():
		# Expiring a host removes the whole room, including later entries in this copy.
		if not sessions.has(token): continue
		var session: Dictionary = sessions[token]
		if session.peer != null or not rooms.has(session.code): continue
		var room: Dictionary = rooms[session.code]
		if int(session.owner) == 0 and now >= int(session.expires):
			_end_room(room, {"kind": "match_aborted", "reason": "host_timeout", "message": "房主断线超过30秒，对局已中止"})
			continue
		if int(session.owner) != 0 and room.status in ["match", "paused"] and not session.bot and now - int(session.disconnected) >= BOT_GRACE_MS:
			session.bot = true
			_broadcast_event(room, {"kind": "bot_takeover", "owner": int(session.owner)})
			_broadcast_room(room)
		if int(session.owner) != 0 and now >= int(session.expires):
			var slot: Dictionary = room.slots[int(session.owner)]
			slot.kind = "open" if room.status == "lobby" else "bot"
			slot.token = ""
			sessions.erase(token)
			_broadcast_room(room)
	for code: String in rooms.keys():
		var room: Dictionary = rooms[code]
		if room.status == "lobby" and now - int(room.touched) > IDLE_ROOM_MS:
			_end_room(room, {"kind": "match_aborted", "reason": "room_idle", "message": "房间长时间未开始，已关闭"})
	if now >= _diagnostic_summary_at:
		_diagnostic_summary_at = now + 5000
		if dropped_notices != _diagnostic_reported_notices:
			_diagnostic("notices_undeliverable", {"count": dropped_notices - _diagnostic_reported_notices, "total": dropped_notices})
			_diagnostic_reported_notices = dropped_notices
		if diagnostic_suppressed != _diagnostic_reported_suppressed:
			_diagnostic("logs_suppressed", {"count": diagnostic_suppressed - _diagnostic_reported_suppressed, "total": diagnostic_suppressed}, true)
			_diagnostic_reported_suppressed = diagnostic_suppressed
		_report_traffic(now)

func _leave(peer: ENetPacketPeer, session: Dictionary, room: Dictionary, now: int) -> void:
	_peer_diagnostic("left", peer)
	if int(session.owner) == 0:
		_end_room(room, {"kind": "match_aborted", "reason": "host_left", "message": "房主已离开"})
	else:
		var token: String = _connections[peer.get_instance_id()].token
		_connections[peer.get_instance_id()].token = ""
		room.slots[int(session.owner)].token = ""
		room.slots[int(session.owner)].kind = "open" if room.status == "lobby" else "bot"
		sessions.erase(token)
		if room.status in ["match", "paused"]:
			_broadcast_event(room, {"kind": "bot_takeover", "owner": int(session.owner)})
		room.touched = now
		_broadcast_room(room)

func _end_room(room: Dictionary, payload: Dictionary) -> void:
	_diagnostic("room_ended", {"room": room.get("diagnostic_id", 0), "kind": payload.get("kind", ""), "reason": payload.get("reason", "")})
	_broadcast_event(room, payload)
	for token: String in sessions.keys():
		if sessions[token].code != room.code: continue
		var peer: ENetPacketPeer = sessions[token].peer
		if peer != null and _connections.has(peer.get_instance_id()):
			_connections[peer.get_instance_id()].token = ""
			_connections[peer.get_instance_id()].match_ended = true
		sessions.erase(token)
	rooms.erase(room.code)

func _match_config(room: Dictionary) -> Dictionary:
	var players: Array = []
	for slot: Dictionary in room.slots:
		var session: Dictionary = sessions.get(slot.token, {})
		players.append({"owner_id": int(slot.owner_id), "team_id": int(slot.team_id), "controller": "bot" if session.get("bot", false) else slot.kind, "name": session.get("name", "空位" if slot.kind == "open" else "电脑 %d" % (int(slot.owner_id) + 1)), "bot_difficulty": slot.bot_difficulty})
	return {"mode": room.mode, "match_id": room.match_id, "map_id": Protocol.MODES[room.mode].map_id, "seed": int(room.seed), "host_owner": 0, "players": players}

func _room_view(room: Dictionary) -> Dictionary:
	var view := {"code": room.code, "match_id": room.match_id, "mode": room.mode, "status": room.status, "host_owner": 0, "slots": []}
	for slot: Dictionary in room.slots:
		var session: Dictionary = sessions.get(slot.token, {})
		view.slots.append({"owner_id": int(slot.owner_id), "team_id": int(slot.team_id), "kind": slot.kind, "name": session.get("name", "电脑 %d" % (int(slot.owner_id) + 1) if slot.kind == "bot" else "空位"), "ready": session.get("ready", slot.kind == "bot"), "connected": session.get("peer") != null, "bot_takeover": session.get("bot", false), "bot_difficulty": slot.bot_difficulty})
	return view

func _broadcast_room(room: Dictionary) -> void:
	# Membership changes are infrequent; the receive hot path reads this count.
	var remote_humans: int = 0
	for slot: Dictionary in room.slots:
		if int(slot.owner_id) != 0 and slot.kind == "human": remote_humans += 1
	room.remote_humans = remote_humans
	_broadcast(room, {"op": "room", "room": _room_view(room)})

func _broadcast_event(room: Dictionary, payload: Dictionary) -> void:
	_broadcast(room, {"op": "event", "match": room.match_id, "payload": payload}, Protocol.EVENT_CHANNEL)

func _broadcast(room: Dictionary, message: Dictionary, channel: int = Protocol.CONTROL_CHANNEL) -> void:
	for slot: Dictionary in room.slots:
		_send_owner(room, int(slot.owner_id), message, channel)

func _send_owner(room: Dictionary, owner: int, message: Dictionary, channel: int) -> void:
	var token: String = room.slots[owner].token
	if sessions.has(token) and sessions[token].peer != null:
		_send(sessions[token].peer, message, channel)

func _send_encoded_owner(room: Dictionary, owner: int, packet: PackedByteArray, channel: int) -> bool:
	var token: String = room.slots[owner].token
	if not sessions.has(token) or sessions[token].peer == null:
		return false
	var peer: ENetPacketPeer = sessions[token].peer
	if not peer.is_active() or peer.get_state() != ENetPacketPeer.STATE_CONNECTED:
		return false
	return peer.send(channel, packet, ENetPacketPeer.FLAG_UNRELIABLE_FRAGMENT if channel == Protocol.SNAPSHOT_CHANNEL else ENetPacketPeer.FLAG_RELIABLE) == OK

func _send(peer: ENetPacketPeer, message: Dictionary, channel: int = Protocol.CONTROL_CHANNEL) -> void:
	if not peer.is_active() or peer.get_state() != ENetPacketPeer.STATE_CONNECTED: return
	var packet := Protocol.encode(message)
	if not packet.is_empty():
		peer.send(channel, packet, ENetPacketPeer.FLAG_UNRELIABLE_FRAGMENT if channel == Protocol.SNAPSHOT_CHANNEL else ENetPacketPeer.FLAG_RELIABLE)

func _reject(peer: ENetPacketPeer, code: String, message: String, fatal: bool = false) -> void:
	rejected_packets += 1
	var id := peer.get_instance_id()
	if _connections.has(id) and code not in ROOM_FEEDBACK_CODES:
		_connections[id].strikes += 1
		fatal = fatal or int(_connections[id].strikes) >= 12
	_peer_diagnostic("rejected", peer, {"code": code.left(48), "fatal": fatal}, fatal)
	_send(peer, {"op": "error", "code": code, "message": message, "fatal": fatal})
	if fatal:
		_drop_connection(peer, Time.get_ticks_msec(), "rejected")
		peer.peer_disconnect_later()

func _peer_diagnostic(event: String, peer: ENetPacketPeer, details: Dictionary = {}, urgent: bool = false) -> void:
	var id: int = peer.get_instance_id()
	var state: Dictionary = _connections.get(id, {})
	var session: Dictionary = sessions.get(state.get("token", ""), {})
	var room: Dictionary = rooms.get(session.get("code", ""), {})
	# Never emit credentials, addresses, invite codes, nicknames, or payloads.
	# Operation labels are reduced to a fixed whitelist at the receive boundary.
	var fields := {"peer": id, "owner": int(session.get("owner", -1)), "room": int(room.get("diagnostic_id", 0)), "op": state.get("last_op", "unparsed"), "channel": int(state.get("last_channel", -1)), "packet_bytes": int(state.get("packet_bytes", 0)), "decoded_bytes": int(state.get("decoded_bytes", 0)), "window_bytes": int(state.get("bytes", 0)), "window_packets": int(state.get("packets", 0)), "strikes": int(state.get("strikes", 0))}
	fields.merge({"budget_kind": state.get("budget_kind", ""), "packet_rate": state.get("packet_rate", 0), "packet_burst": state.get("packet_burst", 0)})
	fields.merge(details)
	_diagnostic(event, fields, urgent)

func _report_traffic(now: int) -> void:
	var totals := {"snapshots": relayed_snapshots, "visual_batches": relayed_visual_batches, "critical_events": relayed_critical_events, "commands": relayed_commands, "snapshot_drops": dropped_snapshots, "visual_drops": dropped_visual_batches, "notice_rate_drops": dropped_notice_rate, "rejected": rejected_packets}
	var fields := {"interval_ms": maxi(1, now - _traffic_summary_at), "channel_packets": Array(_traffic_packets), "channel_wire_bytes": Array(_traffic_wire_bytes), "channel_decoded_bytes": Array(_traffic_decoded_bytes)}
	for key: String in totals:
		fields[key] = int(totals[key]) - int(_traffic_reported.get(key, 0))
	if _traffic_packets != PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0]):
		_diagnostic("traffic", fields)
	_traffic_reported = totals
	_traffic_summary_at = now
	_traffic_packets.fill(0)
	_traffic_wire_bytes.fill(0)
	_traffic_decoded_bytes.fill(0)

func _diagnostic(event: String, fields: Dictionary = {}, urgent: bool = false) -> void:
	var now: int = Time.get_ticks_msec()
	if now - _diagnostic_window >= 1000:
		_diagnostic_window = now
		_diagnostic_events = 0
		_diagnostic_urgent = 0
	if (urgent and _diagnostic_urgent >= DIAGNOSTIC_URGENT_PER_SECOND) or (not urgent and _diagnostic_events >= DIAGNOSTIC_EVENTS_PER_SECOND):
		diagnostic_suppressed += 1
		return
	if urgent: _diagnostic_urgent += 1
	else: _diagnostic_events += 1
	var record := {"event": event, "milliseconds": now, "rooms": rooms.size(), "sessions": sessions.size(), "connections": _connections.size()}
	record.merge(fields)
	diagnostic_emitted += 1
	print("JIMU_RELAY_DIAGNOSTIC ", JSON.stringify(record))

func _code() -> String:
	const ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	while true:
		var result := ""
		for value: int in _crypto.generate_random_bytes(8):
			result += ALPHABET[value % ALPHABET.length()]
		if not rooms.has(result): return result
	return ""

func _exit_tree() -> void:
	stop()
