class_name NetworkProtocol
extends RefCounted
## Explicit JSON primitives only: never decode network bytes into Godot objects.

const VERSION: int = 4
const BUILD_ID: String = "0.7.4"
const TLS_NAME: String = "ashen-crown-relay"
const PORT: int = 24571
const CONTROL_CHANNEL: int = 0
const EVENT_CHANNEL: int = 1
const SNAPSHOT_CHANNEL: int = 2
# Host -> relay uses channels 2 + recipient. Separate sequence windows prevent
# one recipient's newer packet from discarding another recipient's reordered one.
# Relay -> each client uses channel 2 because that connection has one recipient.
const CHANNEL_COUNT: int = 6
const MAX_COMMAND_BYTES: int = 4096
const MAX_EVENT_BYTES: int = 32768
const MAX_PACKET_BYTES: int = 131072
const SNAPSHOT_HZ: int = 15
const MAX_DEPTH: int = 12
const MAX_VALUES: int = 20000
const MAGIC: int = 0x314e4341 # ACN1, little endian.
const HEADER_BYTES: int = 9

static func content_hash() -> String:
	const MANIFEST := "res://data/content_manifest.json"
	# The protocol-only isolated test project has no content catalogue.
	return FileAccess.get_sha256(MANIFEST) if FileAccess.file_exists(MANIFEST) else BUILD_ID.sha256_text()

static func encode(message: Dictionary) -> PackedByteArray:
	var budget: Array[int] = [MAX_VALUES]
	if not _primitive(message, 0, budget):
		return PackedByteArray()
	return _encode_json(message)

static func encode_snapshot(snapshot: Dictionary, recipient: int, sequence: int, match_id: String) -> PackedByteArray:
	# TRUST BOUNDARY: only the authority's MatchReplication schema builder may
	# supply this payload through RelayClient.snapshot_to. It constructs primitive
	# fields from typed game state, never copies a received command dictionary.
	# Do not use this path for commands, events, decoded packets or relay forwarding.
	# All receivers still apply decode()'s full untrusted-value budget and schema.
	if recipient < 0 or recipient > 3 or sequence < 1 or sequence > 2147483647 or match_id.length() != 32:
		return PackedByteArray()
	return _encode_json({"op": "snapshot", "match": match_id, "to": recipient, "sequence": sequence, "payload": snapshot})

static func _encode_json(message: Dictionary) -> PackedByteArray:
	# Native JSON serializes the fixed schema; the size cap is always enforced,
	# including on trusted authority snapshots, before ENet can fragment a packet.
	var raw := JSON.stringify(message, "", false).to_utf8_buffer()
	if raw.size() + HEADER_BYTES > MAX_PACKET_BYTES:
		return PackedByteArray()
	var body := raw
	var compressed := false
	if raw.size() > 512:
		var candidate := raw.compress(FileAccess.COMPRESSION_ZSTD)
		if candidate.size() < raw.size():
			body = candidate
			compressed = true
	var packet := PackedByteArray()
	packet.resize(HEADER_BYTES)
	packet.encode_u32(0, MAGIC)
	packet.encode_u32(4, raw.size())
	packet[8] = 1 if compressed else 0
	packet.append_array(body)
	return packet

static func decode(packet: PackedByteArray) -> Dictionary:
	if packet.size() <= HEADER_BYTES or packet.size() > MAX_PACKET_BYTES or packet.decode_u32(0) != MAGIC:
		return {}
	var size: int = decoded_size(packet)
	if size < 2 or size + HEADER_BYTES > MAX_PACKET_BYTES or packet[8] > 1:
		return {}
	var raw := packet.slice(HEADER_BYTES)
	if packet[8] == 1:
		raw = raw.decompress(size, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != size:
		return {}
	var parser := JSON.new()
	if parser.parse(raw.get_string_from_utf8()) != OK or not parser.data is Dictionary:
		return {}
	var budget: Array[int] = [MAX_VALUES]
	return parser.data if _primitive(parser.data, 0, budget) else {}

static func decoded_size(packet: PackedByteArray) -> int:
	return packet.decode_u32(4) if packet.size() >= HEADER_BYTES else 0

static func _primitive(value: Variant, depth: int, budget: Array[int]) -> bool:
	budget[0] -= 1
	if budget[0] < 0 or depth > MAX_DEPTH:
		return false
	var children: Array
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			return true
		TYPE_FLOAT:
			return is_finite(value)
		TYPE_STRING:
			return value.length() <= 32768
		TYPE_ARRAY:
			children = value
		TYPE_DICTIONARY:
			for key: Variant in value:
				if not key is String or key.length() > 64:
					return false
			children = value.values()
		_:
			return false
	# Most snapshot fields are scalars. Validate them in this loop rather than
	# making thousands of GDScript calls per recipient; recurse only containers.
	budget[0] -= children.size()
	if budget[0] < 0 or (depth == MAX_DEPTH and not children.is_empty()):
		return false
	for child: Variant in children:
		match typeof(child):
			TYPE_NIL, TYPE_BOOL, TYPE_INT:
				pass
			TYPE_FLOAT:
				if not is_finite(child):
					return false
			TYPE_STRING:
				if child.length() > 32768:
					return false
			TYPE_ARRAY, TYPE_DICTIONARY:
				budget[0] += 1 # The recursive entry counts this container itself.
				if not _primitive(child, depth + 1, budget):
					return false
			_:
				return false
	return true

static func integer(value: Variant, minimum: int, maximum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value)) and value >= minimum and value <= maximum

static func nickname(value: Variant) -> String:
	if not value is String:
		return "指挥官"
	var cleaned: String = value.strip_edges().replace("\n", "").replace("\r", "").replace("\t", "")
	return cleaned.left(20) if not cleaned.is_empty() else "指挥官"
