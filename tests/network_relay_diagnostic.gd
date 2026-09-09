extends "res://server/relay_main.gd"
## Test-only native transport sampling. No addresses, tokens, or credentials.
## Kept outside the exported game and production relay entry point.

var _native_sample_at: int = 0
var _native_samples: int = 0

func _process(_delta: float) -> bool:
	var now := Time.get_ticks_msec()
	if now < _native_sample_at or _native_samples >= 3000 or not is_instance_valid(relay) or not relay.running:
		return false
	_native_sample_at = now + 50
	_native_samples += 1
	var peers: Array = []
	for state: Dictionary in relay._connections.values():
		var peer: ENetPacketPeer = state.peer
		if not peer.is_active() or peer.get_state() != ENetPacketPeer.STATE_CONNECTED:
			continue
		var peer_owner: int = -1
		if relay.sessions.has(state.token):
			peer_owner = int(relay.sessions[state.token].owner)
		peers.append({
			"owner": peer_owner,
			"throttle": peer.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE),
			"limit": peer.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_LIMIT),
			"rtt": peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME),
			"variance": peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME_VARIANCE),
			"last_rtt": peer.get_statistic(ENetPacketPeer.PEER_LAST_ROUND_TRIP_TIME),
			"last_variance": peer.get_statistic(ENetPacketPeer.PEER_LAST_ROUND_TRIP_TIME_VARIANCE),
			"interval": peer.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_INTERVAL),
		})
	if not peers.is_empty():
		print("NETWORK_NATIVE_RELAY " + JSON.stringify({"msec": now, "peers": peers}))
	return false
