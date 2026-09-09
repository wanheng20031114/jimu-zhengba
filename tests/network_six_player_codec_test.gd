extends SceneTree
## Authored templates plus primitive clones exercise full six-player capacity
## without allocating hundreds of model scene graphs in a codec regression.

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
		game.players[owner].army_capacity_level = 2
		game.players[owner].workforce_level = 1
		game.players[owner].mining_level = 3
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
		for index in range(112):
			var state: Dictionary = unit_state.duplicate(true)
			state.kind = "farmer" if index < 12 else "swordsman"
			state.id = 1000 + owner * 112 + index
			state.p = [owner * 10.0, 0.0, index * 0.5]
			if owner == 5:
				state.plan = []
				state.queued_count = BattleUnit.MAX_QUEUED_ORDERS
				for step in range(UnitOrderPlan.MAX_ENTRIES):
					state.plan.append({"kind": "move", "at": [index + step * 0.25, 0.0, owner * 10.0]})
			states.append(state)
		for building_index in range(20):
			var kind: String = ["headquarters", "barracks", "academy", "factory", "defense_tower"][building_index % 5]
			var building: BattleBuilding = game.spawn_building(kind, owner, Vector3(owner * 10, 0, 10))
			var state: Dictionary = replication._entity_state(building, 5)
			state.id = 2000 + states.size()
			if owner == 5 and kind in ["barracks", "factory", "headquarters"]:
				var training_kind := "swordsman" if kind == "barracks" else ("catapult" if kind == "factory" else "farmer")
				for job in range(BuildingProduction.TRAINING_LIMIT):
					state.production.training.append({"kind": training_kind, "elapsed": 0.0,
						"cost": BalanceCatalog.unit(training_kind).cost, "job_id": job + 1})
			if owner == 5 and kind == "academy":
				var ids: Array = BalanceCatalog.UPGRADES.keys().slice(0, BuildingProduction.RESEARCH_LIMIT)
				for job in range(ids.size()):
					state.production.research_queue.append({"id": ids[job], "elapsed": 0.0,
						"cost": BalanceCatalog.upgrade(ids[job]).cost, "job_id": job + 1})
				state.production.research_id = ids[0]
			states.append(state)
	var snapshot: Dictionary = replication.build_snapshot(5)
	snapshot.entities = states
	var cells := PackedByteArray()
	cells.resize(9216)
	cells.fill(2)
	snapshot.fog = {"owner_id": 5, "alliance_id": 5, "map_size": [192.0, 192.0], "width": 96, "height": 96, "revision": 1,
		"cells": Marshalls.raw_to_base64(cells), "revealed_building_alliances": [1, 1, 1, 1, 1, 1]}
	check(states.size() == 792, "672_units_and_120_production_and_defense_buildings")
	check(states.filter(func(state): return state.has("plan")).size() == 112, "all_112_owner_units_have_full_nine_entry_plans_only")
	check(replication._valid_snapshot(snapshot), "six_owner_snapshot_fields_match_actual_replication_schema")
	var primitive_budget: Array[int] = [NetworkProtocol.MAX_VALUES]
	check(NetworkProtocol._primitive(snapshot, 0, primitive_budget), "maximum_armies_plans_and_queues_fit_primitive_budget")
	var primitive_values: int = NetworkProtocol.MAX_VALUES - primitive_budget[0]
	var started := Time.get_ticks_usec()
	var encoded := NetworkProtocol.encode_snapshot(snapshot, 5, 1, "1".repeat(32))
	var encode_usec := Time.get_ticks_usec() - started
	var decoded := NetworkProtocol.decode(encoded)
	check(not encoded.is_empty() and not decoded.is_empty(), "maximum_population_fog_roundtrip")
	check(decoded.get("payload", {}).get("entities", []).size() == 792, "all_six_owner_entities_survive_codec")
	check(NetworkProtocol.decoded_size(encoded) < NetworkProtocol.MAX_PACKET_BYTES, "decompressed_payload_below_hard_limit")
	if not decoded.is_empty():
		check(replication._valid_snapshot(decoded.payload), "decoded_six_owner_schema_still_valid")
		check(not decoded.payload.fog.has("buildings") and decoded.payload.fog.cells.length() == 12288, "bounded_full_fog_without_enemy_memories")
		check(decoded.payload.players.all(func(player): return player.has("private") == (int(player.owner_id) == 5)), "only_owner_five_private_economy")
		check(decoded.payload.players[5].private.army_capacity_level == 2 and decoded.payload.players[5].private.mining_level == 3,
			"expanded_army_and_mining_levels_roundtrip_in_owner_private_state")
		check(decoded.payload.entities.all(func(state): return int(state.owner) == 5 or (not state.has("plan") and not state.has("production"))),
			"other_players_plans_and_production_stay_private_at_full_capacity")
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
		"units": 672, "buildings": 120, "own_plans": 112, "plan_entries": UnitOrderPlan.MAX_ENTRIES, "fog_cells": 9216, "memories": 0,
		"primitive_values": primitive_values, "decoded_bytes": NetworkProtocol.decoded_size(encoded), "wire_bytes": encoded.size(), "encode_usec": encode_usec}))
	game.queue_free()
	current_scene = null
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)
