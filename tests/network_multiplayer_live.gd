extends "res://tests/network_game_live.gd"
## Inherits only transport/session setup and process-safe fixture coordination.
## Six/eight actual main scenes exercise their own authority, fog, commands and replicas.

var _received_wire: Dictionary = {}

func host_steps() -> void:
	if not await until(func(): return all_phase("world_ready"), 25.0):
		check(false, "all_remote_native_worlds_ready")
		return
	var actors: Dictionary = {}
	var starts: Dictionary = {}
	var destinations: Dictionary = {}
	var bases: Dictionary = {}
	for player: PlayerState in game.players:
		var home: BattleBuilding = game.owned_entities(player.owner_id, "buildings").filter(func(building): return building.building_type == "headquarters")[0]
		check(await until(func(): return game.find_recruit_position("swordsman", home).is_finite(), 10.0), "native_spawn_ready_%d" % player.owner_id)
		var at: Vector3 = game.find_recruit_position("swordsman", home)
		var unit: BattleUnit = game.spawn_unit("swordsman", player.owner_id, at)
		unit.hold()
		player.gold = 800 + 100 * player.owner_id
		actors[str(player.owner_id)] = unit.entity_id
		starts[str(player.owner_id)] = data(at)
		bases[str(player.owner_id)] = home.entity_id
		destinations[str(player.owner_id)] = data(NavigationServer3D.map_get_closest_point(game.get_world_3d().navigation_map, at.move_toward(Vector3.ZERO, 5.0)))
	_published = {"actors": actors, "starts": starts, "destinations": destinations, "bases": bases}
	publish("orders")
	check(await until(func(): return all_phase("orders"), 20.0), "all_guests_submit_authoritative_commands")
	check(await until(func():
		for guest in range(1, peer_count):
			var unit: BattleUnit = game.entities_by_id[int(actors[str(guest)])]
			if unit.global_position.distance_to(vec(starts[str(guest)])) <= 1.0:
				return false
		return true, 8.0), "all_remote_remote_moves_execute")
	for guest in range(1, peer_count):
		check(game.get_player(guest).gold < 2000, "guest_cannot_forge_gold_%d" % guest)
		check(int(_command_marks.get("multiplayer_owner_%d" % guest, 0)) == 1, "command_dedup_and_identity_%d" % guest)
	var host_unit: BattleUnit = game.entities_by_id[int(actors["0"])]
	check(host_unit.order == BattleUnit.Order.HOLD, "foreign_owner_cannot_command_host_unit")
	var host_base: BattleBuilding = game.entities_by_id[int(bases["0"])]
	check(host_base.production.training.is_empty(), "foreign_owner_cannot_spend_host_gold")
	publish("last_recipient_drop")
	check(await until(func(): return game.bots.has(peer_count - 1), 18.0), "last_human_disconnect_becomes_bot")
	publish("last_recipient_resume")
	check(await until(func(): return not game.bots.has(peer_count - 1) and all_phase("last_recipient_resume"), 18.0), "last_human_reconnect_recovers_same_owner")
	check(game.get_instance_id() == scene_identity and match_starts == 1, "host_keeps_same_multiplayer_scene")
	# In modes with more than two sides an eliminated side cannot end the match.
	if int(NetworkProtocol.MODES[test_mode].teams) > 2:
		var eliminated_alliance: int = game.get_player(4).alliance_id
		for building: Node3D in get_nodes_in_group("buildings"):
			if building.alive and building.alliance_id == eliminated_alliance:
				building.receive_damage(100000.0)
		game.tests_running = false
		game.check_victory()
		game.tests_running = true
		check(not game.finished and game.get_player(4).eliminated, "third_side_elimination_keeps_match_running")
		_published["eliminated_alliance"] = eliminated_alliance
		publish("elimination")
		check(await until(func(): return all_phase("elimination"), 12.0), "all_remote_clients_receive_public_elimination")
	publish("steady")
	check(await until(func(): return all_phase("steady"), 10.0), "all_remote_clients_keep_receiving_states")
	await seconds(maxf(2.0, _steady_seconds))
	game.end_battle(true, game.get_player(0).alliance_id)
	publish("finish")
	await seconds(0.8)

func client_steps() -> void:
	var previous := ""
	while Time.get_ticks_msec() - started_msec < 150000:
		var directive := read_record("phase.json")
		if directive.is_empty() or directive.stage == previous:
			status()
			await process_frame
			continue
		var stage: String = directive.stage
		previous = stage
		match stage:
			"orders":
				var own_id: int = int(directive.actors[str(owner)])
				check(await until(func(): return game.entities_by_id.has(own_id), 12.0), "own_multiplayer_unit_replicated")
				var snapshot_ids: Array = _received_wire.get("entities", []).map(func(entity): return int(entity.id))
				for other in range(peer_count):
					if game.get_player(other).alliance_id == game.get_player(owner).alliance_id:
						check(snapshot_ids.has(int(directive.bases[str(other)])), "same_alliance_base_shared_%d" % other)
					else:
						check(not snapshot_ids.has(int(directive.bases[str(other)])), "hidden_enemy_base_not_on_wire_%d" % other)
				game.get_player(owner).gold = 999999
				game.submit_local({"kind": "move", "units": [own_id], "at": directive.destinations[str(owner)], "owner": 0, "test_marker": "multiplayer_owner_%d" % owner})
				relay._send({"op": "command", "match": relay._match.match_id, "sequence": relay._command_sequence, "payload": {"kind": "stop", "units": [own_id], "test_marker": "multiplayer_owner_%d" % owner}})
				game.submit_local({"kind": "move", "units": [int(directive.actors["0"])], "at": [0, 0, 0], "owner": 0})
				game.submit_local({"kind": "recruit", "target": int(directive.bases["0"]), "unit_type": "farmer", "owner": 0, "gold": 999999})
				phase = stage
			"last_recipient_drop":
				if owner == peer_count - 1:
					drop_transport()
				phase = stage
			"last_recipient_resume":
				if owner == peer_count - 1:
					var before := snapshots
					resume_transport()
					check(await until(func(): return relay.connection_state == "match" and snapshots > before + 1, 18.0), "last_owner_authenticates_and_receives_new_state")
					check(relay.owner_id == peer_count - 1 and game.get_instance_id() == scene_identity and match_starts == 1, "last_owner_resume_keeps_identity_and_scene")
				phase = stage
			"elimination":
				check(await until(func(): return game.get_player(4).eliminated, 10.0), "elimination_public_state_replicates")
				check(not game.finished, "other_sides_continue_after_elimination")
				if game.get_player(owner).alliance_id == int(directive.eliminated_alliance):
					check(game.get_player(owner).eliminated, "elimination_applies_to_entire_alliance")
				phase = stage
			"steady":
				phase = stage
			"finish":
				check(await until(func(): return game.finished and relay.connection_state == "finished", 8.0), "match_result_arrives_after_multiple_sides")
				check(snapshot_rejections == 0 and _snapshot_tick_regressions == 0, "multiplayer_owner_snapshot_schema_and_sequence")
				check(snapshots >= 20, "continuous_multiplayer_owner_snapshots")
				check(_snapshot_gaps.size() >= 20, "continuous_snapshot_spacing_measured_without_deliberate_outage")
				check(game.get_player(owner).gold < 2000, "authoritative_gold_restored")
				check(game.bots.is_empty(), "clients_never_run_bot_logic")
				check(get_nodes_in_group("units").all(func(unit): return not unit.is_physics_processing() and not unit.navigation_agent.avoidance_enabled), "client_models_are_presentation_only")
				return
		status(true)
	check(false, "multiplayer_scenario_timeout")

func _snapshot(snapshot: Dictionary) -> void:
	snapshots += 1
	_received_wire = snapshot
	var now := Time.get_ticks_msec()
	if phase in ["orders", "steady"] and relay.connection_state == "match":
		if _last_snapshot_msec > 0:
			_snapshot_gaps.append(now - _last_snapshot_msec)
		_last_snapshot_msec = now
	else:
		_last_snapshot_msec = 0
	var tick: int = int(snapshot.get("tick", -1))
	if tick <= _last_snapshot_tick:
		_snapshot_tick_regressions += 1
	_last_snapshot_tick = tick
	for player: Dictionary in snapshot.get("players", []):
		if player.has("private") and int(player.owner_id) != relay.owner_id:
			check(false, "other_owner_economy_leaked")
	for entity: Dictionary in snapshot.get("entities", []):
		if int(entity.owner) != relay.owner_id and (entity.has("production") or entity.has("rally") or entity.has("plan")):
			check(false, "other_owner_orders_leaked")
