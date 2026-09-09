extends SceneTree
## One authored example per owner; clone primitive states, not 432 scene graphs.

const Fixture = preload("res://tests/network_game_fixture.tscn")
const RelayScene = preload("res://scripts/network/relay_client.tscn")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(passed: bool, label: String) -> void:
	checks += 1
	if not passed:
		failures.append(label)

func _run() -> void:
	var game = Fixture.instantiate()
	game.players.clear()
	for owner in range(6):
		game.players.append(PlayerState.new(owner, owner))
	game.local_owner_id = 5
	root.add_child(game)
	var relay: RelayClient = RelayScene.instantiate()
	game.add_child(relay)
	var replication: MatchReplication = game.get_node("MatchReplication")
	replication.configure(game, relay)
	var states: Array = []
	for owner in range(6):
		var example: BattleUnit = game.spawn_unit("swordsman", owner, Vector3(owner * 10, 0, 0))
		var unit_state: Dictionary = replication._entity_state(example, 5)
		for index in range(72):
			var state: Dictionary = unit_state.duplicate(true)
			state.kind = "farmer" if index < 12 else "swordsman"
			state.id = 1000 + owner * 72 + index
			state.p = [owner * 10.0, 0.0, index * 0.5]
			states.append(state)
		for kind: String in ["headquarters", "defense_tower"]:
			var building: BattleBuilding = game.spawn_building(kind, owner, Vector3(owner * 10, 0, 10))
			var state: Dictionary = replication._entity_state(building, 5)
			state.id = 2000 + states.size()
			states.append(state)
	var snapshot: Dictionary = replication.build_snapshot(5)
	snapshot.entities = states
	var cells := PackedByteArray()
	cells.resize(9216)
	cells.fill(2)
	var memories: Array = []
	for index in range(512):
		memories.append({"id": 3000 + index, "kind": "defense_tower", "owner_id": index % 5, "alliance_id": index % 5,
			"position": [index * 0.125, 0.0, index * 0.25], "rotation": [0.0, 0.0, 0.0], "radius": 1.5,
			"construction_progress": 1.0, "last_seen_revision": 1})
	snapshot.fog = {"owner_id": 5, "alliance_id": 5, "map_size": [192.0, 192.0], "width": 96, "height": 96, "revision": 1,
		"cells": Marshalls.raw_to_base64(cells), "buildings": memories, "revealed_building_alliances": [1, 1, 1, 1, 1, 1]}
	check(states.size() == 444, "432_units_and_twelve_initial_buildings")
	check(replication._valid_snapshot(snapshot), "six_owner_snapshot_fields_match_actual_replication_schema")
	var started := Time.get_ticks_usec()
	var encoded := NetworkProtocol.encode_snapshot(snapshot, 5, 1, "1".repeat(32))
	var encode_usec := Time.get_ticks_usec() - started
	var decoded := NetworkProtocol.decode(encoded)
	check(not encoded.is_empty() and not decoded.is_empty(), "maximum_population_fog_and_memory_roundtrip")
	check(decoded.get("payload", {}).get("entities", []).size() == 444, "all_six_owner_entities_survive_codec")
	check(NetworkProtocol.decoded_size(encoded) < NetworkProtocol.MAX_PACKET_BYTES, "decompressed_payload_below_hard_limit")
	if not decoded.is_empty():
		check(replication._valid_snapshot(decoded.payload), "decoded_six_owner_schema_still_valid")
		check(decoded.payload.fog.buildings.size() == 512 and decoded.payload.fog.cells.length() == 12288, "bounded_full_fog_and_memory_retained")
		check(decoded.payload.players.all(func(player): return player.has("private") == (int(player.owner_id) == 5)), "only_owner_five_private_economy")
		var invalid: Dictionary = decoded.payload.duplicate(true)
		invalid.players[5].alliance_id = 4
		check(not replication._valid_snapshot(invalid), "replica_cannot_change_room_alliance")
		invalid = decoded.payload.duplicate(true)
		invalid.players[5].eliminated = 1
		check(not replication._valid_snapshot(invalid), "elimination_requires_boolean")
		invalid = decoded.payload.duplicate(true)
		invalid.players[5].owner_id = 6
		check(not replication._valid_snapshot(invalid), "owner_six_outside_dense_roster_rejected")
	print("NETWORK_SIX_CODEC_RESULTS " + JSON.stringify({"checks": checks, "failures": failures,
		"units": 432, "buildings": 12, "fog_cells": 9216, "memories": 512,
		"decoded_bytes": NetworkProtocol.decoded_size(encoded), "wire_bytes": encoded.size(), "encode_usec": encode_usec}))
	game.queue_free()
	current_scene = null
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)
