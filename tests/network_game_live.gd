extends SceneTree
## One process / one actual main scene. Four peers coordinate only their test phases
## through ignored local files; commands and world state always cross native ENet.

var session: Node
var relay: RelayClient
var game: Node3D
var directory: String
var peer_index: int = 0
var owner: int = -1
var checks: int = 0
var failures: Array[String] = []
var errors: Array[String] = []
var events: Dictionary = {}
var snapshots: int = 0
var match_starts: int = 0
var snapshot_rejections: int = 0
var phase: String = "connect"
var scene_identity: int = 0
var started_msec: int = 0
var _published: Dictionary = {}
var _last_status_msec: int = 0
var _finishing: bool = false
var _snapshot_gaps: Array[int] = []
var _last_snapshot_msec: int = 0
var _last_snapshot_tick: int = -1
var _snapshot_tick_regressions: int = 0
var _transport_states: Array[String] = []
var _command_marks: Dictionary = {}
var _observed_stages: Array[String] = []
var _file_publish_retries: int = 0
var _steady_seconds: float = 0.0
var _load_units: int = 0
var _load_seconds: float = 20.0
var _load_gaps: Array[int] = []
var _load_counts: Array[int] = []
var _load_last_msec: int = 0
var _load_first_snapshot_msec: int = -1
var _load_last_count: int = 0
var _load_started_msec: int = 0
var _load_long_gaps: Array[Dictionary] = []
var _load_process_gaps: Array[Dictionary] = []
var _load_last_process_msec: int = 0
var _load_ready_msec: int = 0
var _load_setup_msec: int = 0
var _native_samples: Array[Dictionary] = []
var _native_sample_at: int = 0
var _load_report: Dictionary = {}
var _load_routes: Dictionary = {}
var _saw_private_queue_plan := false
var _saw_private_research_queue := false
var _saw_reserved_population := false

func _initialize() -> void:
	Engine.max_fps = 60
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--live-dir="):
			directory = argument.trim_prefix("--live-dir=")
		elif argument.begins_with("--peer-index="):
			peer_index = int(argument.trim_prefix("--peer-index="))
		elif argument.begins_with("--load-units="):
			_load_units = int(argument.trim_prefix("--load-units="))
		elif argument.begins_with("--load-seconds="):
			_load_seconds = float(argument.trim_prefix("--load-seconds="))
	started_msec = Time.get_ticks_msec()
	_run.call_deferred()

func _run() -> void:
	if directory.is_empty():
		quit(2)
		return
	session = root.get_node("Session")
	relay = session.relay
	relay.match_started.connect(_match_started)
	relay.snapshot_received.connect(_snapshot)
	relay.event_received.connect(_event)
	relay.error_received.connect(_error)
	relay.connection_state_changed.connect(func(state: String): _transport_states.append(state))
	relay.command_received.connect(func(_owner: int, command: Dictionary):
		if command.has("test_marker"):
			_command_marks[command.test_marker] = int(_command_marks.get(command.test_marker, 0)) + 1)
	var endpoint := read_record("endpoint-%d.json" % peer_index)
	if endpoint.is_empty():
		endpoint = read_record("endpoint.json")
	_steady_seconds = float(endpoint.get("steady_seconds", 0))
	if endpoint.has("certificate"):
		relay.certificate_path = endpoint.certificate
	check(relay.connect_relay(endpoint.address, int(endpoint.port)) == OK, "native_dtls_connect_requested")
	if not await until(func(): return relay.connection_state == "connected", 24.0):
		check(false, "encrypted_connection_ready")
		await finish()
		return
	if peer_index == 0:
		relay.create_room("2v2", "测试房主")
		if not await until(func(): return not relay.room.is_empty(), 10.0):
			check(false, "create_room")
			await finish()
			return
		write_record("lobby.json", {"code": relay.room.code})
		if not await until(_room_ready, 35.0):
			check(false, "four_humans_ready")
			await finish()
			return
		relay.start_match()
	else:
		if not await until(func(): return not read_record("lobby.json").is_empty(), 24.0):
			check(false, "read_invitation")
			await finish()
			return
		relay.join_room(read_record("lobby.json").code, "测试指挥官 %d" % peer_index)
		if not await until(func(): return relay.connection_state == "lobby", 15.0):
			check(false, "join_room")
			await finish()
			return
		relay.set_ready(true)
	if not await until(func(): return current_scene != null and current_scene.scene_file_path == "res://scenes/main.tscn" and current_scene._match_ready, 35.0):
		check(false, "actual_main_scene_ready")
		await finish()
		return
	game = current_scene
	owner = relay.owner_id
	scene_identity = game.get_instance_id()
	game.tests_running = true
	game.camera_rig.edge_scroll = false
	game.get_node("MatchReplication").snapshot_rejected.connect(func(_reason): snapshot_rejections += 1)
	check(game.local_owner_id == owner and game.is_authority == (owner == 0), "session_bound_identity_and_authority")
	check(game.players.size() == 4 and game.match_config.mode == "2v2", "actual_four_player_map")
	if owner != 0:
		check(await until(func(): return snapshots >= 2 and game.owned_entities(owner, "buildings").size() >= 1, 15.0), "first_authoritative_world_arrives")
	phase = "world_ready"
	status(true)
	if owner == 0:
		await host_steps()
	else:
		await client_steps()
	await finish()

func _room_ready() -> bool:
	if relay.room.is_empty() or relay.room.slots.size() != 4:
		return false
	for slot: Dictionary in relay.room.slots:
		if slot.kind != "human" or not slot.connected or (int(slot.owner_id) != 0 and not slot.ready):
			return false
	return true

func _match_started(config: Dictionary) -> void:
	match_starts += 1
	session.start_online(config)

func host_steps() -> void:
	if not await until(func(): return all_phase("world_ready"), 20.0):
		check(false, "all_four_worlds_ready")
		return
	await physics_frame
	await physics_frame
	var actors: Dictionary = {}
	var bases: Dictionary = {}
	var starts: Dictionary = {}
	var destinations: Dictionary = {}
	var barracks: Dictionary = {}
	var academies: Dictionary = {}
	for player: PlayerState in game.players:
		player.gold = 900 + player.owner_id * 10
		var base: BattleBuilding = game.owned_entities(player.owner_id, "buildings")[0]
		var at: Vector3 = game.find_recruit_position("swordsman", base)
		check(at.is_finite(), "legal_test_spawn_%d" % player.owner_id)
		var unit: BattleUnit = game.spawn_unit("swordsman", player.owner_id, at)
		unit.hold()
		actors[str(player.owner_id)] = unit.entity_id
		bases[str(player.owner_id)] = base.entity_id
		starts[str(player.owner_id)] = data(at)
		var destination: Vector3 = NavigationServer3D.map_get_closest_point(game.get_world_3d().navigation_map, at.move_toward(Vector3.ZERO, 4.0))
		destinations[str(player.owner_id)] = data(destination)
		if player.owner_id != 0:
			# Scenario setup supplies completed buildings. Every queued job below
			# still pays the real price and waits the unmodified simulation time.
			for kind: String in ["barracks", "academy"]:
				var location: Vector3 = game.find_build_location(player.owner_id, kind, base.global_position)
				check(location.is_finite(), "legal_test_" + kind + "_" + str(player.owner_id))
				if not location.is_finite():
					return
				var production: BattleBuilding = game.spawn_building(kind, player.owner_id, location)
				(barracks if kind == "barracks" else academies)[str(player.owner_id)] = production.entity_id
				game.get_node("ConstructionNavigation").refresh()
				await physics_frame
				await physics_frame
	game.get_player(0).gold = 9001
	_published = {"actors": actors, "bases": bases, "starts": starts, "destinations": destinations, "barracks": barracks, "academies": academies}
	publish("orders")
	check(await until(func(): return all_phase("orders"), 15.0), "three_clients_submit_real_game_orders")
	await seconds(2.0)
	for target_owner in range(1, 4):
		var unit: BattleUnit = game.entities_by_id[int(actors[str(target_owner)])]
		check(unit.global_position.distance_to(vec(starts[str(target_owner)])) > 0.7, "remote_move_executed_owner_%d" % target_owner)
	var host_unit: BattleUnit = game.entities_by_id[int(actors["0"])]
	check(host_unit.global_position.distance_to(vec(starts["0"])) < 0.1, "foreign_owner_move_rejected")
	check(host_unit.order == BattleUnit.Order.HOLD, "ally_attack_and_owner_spoof_rejected")
	check(int(_command_marks.get("one_move_owner_1", 0)) == 1, "duplicate_transport_sequence_never_reaches_game")
	check(game.get_player(2).gold < 2000, "client_gold_fields_cannot_change_authority")
	var own_base: BattleBuilding = game.entities_by_id[int(bases["2"])]
	check(own_base.production.training.size() == 1 or game.get_player(2).farmers == 4, "client_training_crossed_command_validator")
	publish("queues")
	check(await until(func(): return all_phase("queues"), 12.0), "clients_observe_paid_training_and_research_queues")
	for target_owner in range(1, 4):
		var building: BattleBuilding = game.entities_by_id[int(barracks[str(target_owner)])]
		var academy: BattleBuilding = game.entities_by_id[int(academies[str(target_owner)])]
		check(building.production.training.size() == 2 and game.get_player(target_owner).reserved_military_supply == 2, "host_reserves_two_training_population_" + str(target_owner))
		check(academy.production.research_queue.size() == 2, "host_research_queue_from_remote_commands_" + str(target_owner))
		check(game.get_player(target_owner).military_supply == 1, "military_training_is_not_instant_" + str(target_owner))
	check(await until(func(): return [1, 2, 3].all(func(id): return game.get_player(id).military_supply == 3 and game.get_player(id).reserved_military_supply == 0), 16.0), "two_sequential_six_second_training_jobs_really_complete")
	if _steady_seconds > 0:
		publish("steady")
		check(await until(func(): return all_phase("steady"), 10.0), "all_clients_enter_continuous_network_observation")
		await seconds(_steady_seconds)
	publish("guest_drop")
	check(await until(func(): return game.bots.has(3), 18.0), "ordinary_disconnect_becomes_bot_after_grace")
	check(not game.bots.has(1) and not game.bots.has(2), "other_humans_keep_control")
	publish("guest_resume")
	check(await until(func(): return not game.bots.has(3) and events.get("player_reconnected", 0) > 0, 18.0), "authenticated_guest_resume_removes_bot")
	check(await until(func(): return all_phase("guest_resume"), 12.0), "guest_receives_fresh_world_without_scene_reload")
	publish("host_drop")
	drop_transport()
	var tick_at_drop: int = game.simulation_tick
	check(await until(func(): return all_event("host_paused"), 12.0), "host_disconnect_pauses_all_remote_worlds")
	check(game.simulation_tick <= tick_at_drop + 1, "authority_clock_stops_while_disconnected")
	resume_transport()
	check(await until(func(): return relay.connection_state == "match" and not paused, 18.0), "host_authenticated_resume_unpauses")
	publish("host_resume")
	check(await until(func(): return all_phase("host_resume"), 12.0), "all_clients_resume_same_scene")
	check(game.get_instance_id() == scene_identity and match_starts == 1, "host_reconnect_does_not_restart_match")
	# Move two opponents into the authored central lane. The client must issue
	# attack through its own game coordinator; the host alone applies damage.
	var attacker: BattleUnit = game.entities_by_id[int(actors["1"])]
	var victim: BattleUnit = game.entities_by_id[int(actors["2"])]
	attacker.stop()
	victim.stop()
	attacker.set_physics_process(false)
	attacker.global_position = Vector3(-2.5, 0, 0)
	victim.global_position = Vector3(0, 0, 0)
	attacker.reset_physics_interpolation()
	victim.reset_physics_interpolation()
	attacker.hold()
	victim.hold()
	# The victim is a stationary test target, retaining native collision and HP.
	victim.set_physics_process(false)
	victim.navigation_agent.avoidance_enabled = false
	game.get_node("FogOfWar").tick(0.2)
	var initial_hp: float = victim.hp
	publish("attack")
	check(await until(func(): return all_phase("attack"), 12.0), "newly_visible_enemy_replicates_before_attack")
	check(await until(func(): return attacker.order == BattleUnit.Order.ATTACK and attacker.target == victim, 5.0), "explicit_remote_attack_reaches_host_order")
	attacker.set_physics_process(true)
	check(await until(func(): return not victim.alive or victim.hp < initial_hp, 6.0), "remote_attack_applies_authoritative_damage")
	# Research deliberately spans the real guest/host disconnect exercises.
	# There is no timer mutation or simulation acceleration in this suite.
	check(await until(func(): return [1, 2, 3].all(func(id): return game.get_player(id).attack_level == 1 and game.get_player(id).defense_level == 1), 48.0), "research_queue_completes_in_order_across_reconnections")
	publish("queues_done")
	check(await until(func(): return all_phase("queues_done"), 12.0), "all_clients_receive_finished_research_and_population")
	await seconds(0.6)
	for client_owner in range(1, 4):
		var report := owner_status(client_owner)
		check(int(report.get("snapshots", 0)) > 20, "continuous_world_snapshots_owner_%d" % client_owner)
	if _load_units > 0:
		await host_network_load()
	check(failures.is_empty(), "host_scenario_complete")
	check(_transport_states.count("reconnecting") == 1, "host_has_only_planned_transport_interruption")
	game.end_battle(true)
	publish("finish")
	await seconds(0.5)

func client_steps() -> void:
	var previous: String = ""
	while Time.get_ticks_msec() - started_msec < 135000 + int((_load_seconds + 45.0) * 1000) * int(_load_units > 0):
		var process_now: int = Time.get_ticks_msec()
		if phase == "network_load" and _load_last_process_msec > 0 and process_now - _load_last_process_msec > 100:
			_load_process_gaps.append({"at_ms": process_now - _load_started_msec, "gap_ms": process_now - _load_last_process_msec})
		_load_last_process_msec = process_now
		var directive := read_record("phase.json")
		if directive.is_empty():
			status()
			await process_frame
			continue
		var stage: String = directive.stage
		if stage == "finish":
			check(await until(func(): return game.finished and relay.connection_state == "finished", 8.0), "canonical_match_result_reaches_actual_client_game")
			check(snapshot_rejections == 0, "all_received_game_snapshots_pass_schema")
			check(_snapshot_tick_regressions == 0, "reordered_snapshots_never_reverse_authority_tick")
			check(_snapshot_gaps.size() >= 20, "snapshot_gap_measurement_has_continuous_samples")
			check(match_starts == 1 and game.get_instance_id() == scene_identity, "client_scene_survives_reconnections")
			check(game.get_player(owner).gold < 2000, "own_gold_returns_to_authoritative_value")
			check(game.bots.is_empty(), "client_never_instantiates_authoritative_bot_ai")
			check(get_nodes_in_group("units").all(func(unit): return not unit.is_physics_processing() and not unit.navigation_agent.avoidance_enabled), "actual_client_units_never_run_physics_or_rvo")
			check(_transport_states.count("reconnecting") == (1 if owner == 3 else 0), "client_has_only_planned_transport_interruption")
			check(_saw_private_queue_plan, "own_shift_plan_crossed_real_transport")
			check(_saw_private_research_queue and _saw_reserved_population, "private_research_and_population_crossed_real_transport")
			return
		if stage == previous:
			status()
			await process_frame
			continue
		previous = stage
		_observed_stages.append(stage)
		_published = directive
		match stage:
			"network_load_setup":
				phase = stage
				_load_setup_msec = Time.get_ticks_msec()
				check(await until(func(): return _load_last_count == _load_units and get_nodes_in_group("units").size() == _load_units, 25.0), "load_complete_roster_arrives_before_measurement")
				_load_ready_msec = Time.get_ticks_msec()
				phase = "network_load_ready"
			"network_load":
				_load_gaps.clear()
				_load_counts.clear()
				_load_long_gaps.clear()
				_load_process_gaps.clear()
				_load_last_msec = 0
				_load_first_snapshot_msec = -1
				_load_started_msec = Time.get_ticks_msec()
				_load_last_process_msec = _load_started_msec
				phase = stage
			"network_load_end":
				_load_report = {"units": _load_units, "snapshots": _load_counts.size(), "unit_counts": number_statistics(_load_counts),
					"gap_ms": number_statistics(_load_gaps), "seconds": (Time.get_ticks_msec() - _load_started_msec) / 1000.0,
					"long_snapshot_gaps": _load_long_gaps, "long_process_frame_gaps": _load_process_gaps,
					"roster_load_ms": _load_ready_msec - _load_setup_msec, "ready_before_window_ms": _load_started_msec - _load_ready_msec,
					"native_transport_samples": _native_samples,
					"first_snapshot_latency_ms": _load_first_snapshot_msec - _load_started_msec if _load_first_snapshot_msec >= 0 else -1,
					"last_snapshot_age_ms": Time.get_ticks_msec() - _load_last_msec,
					"byte_source": "runner joins this peer's relay_to_client UDP payload counters from the isolated network_load window"}
				check(not _load_counts.is_empty() and _load_counts.all(func(count): return count == _load_units), "every_load_snapshot_contains_all_280_units")
				check(_load_counts.size() >= int(_load_seconds * 5.0), "load_receives_at_least_five_complete_snapshots_per_second")
				check(not _load_gaps.is_empty() and _load_gaps.max() <= 1000, "load_has_no_complete_snapshot_outage_over_one_second")
				check(_load_first_snapshot_msec >= 0 and _load_first_snapshot_msec - _load_started_msec <= 1000 and Time.get_ticks_msec() - _load_last_msec <= 1000, "load_window_first_and_last_snapshot_are_within_one_second")
				check(get_nodes_in_group("units").size() == _load_units, "all_280_native_client_replicas_remain_present")
				phase = stage
			"steady":
				phase = stage
			"orders":
				var id := int(directive.actors[str(owner)])
				check(await until(func(): return game.entities_by_id.has(id), 10.0), "own_military_replica_arrives")
				game.submit_local({"kind": "move", "units": [id], "at": directive.destinations[str(owner)], "owner": (owner + 1) % 4, "test_marker": "one_move_owner_%d" % owner})
				game.submit_local({"kind": "move", "units": [id], "at": data(vec(directive.destinations[str(owner)]).move_toward(Vector3.ZERO, 5.0)), "queued": true})
				if owner == 1:
					# Conflicting own-unit order with the same transport sequence. The
					# relay must drop it before the host Game sees the payload.
					relay._send({"op": "command", "match": relay._match.match_id, "sequence": relay._command_sequence, "payload": {"kind": "move", "units": [id], "at": directive.starts[str(owner)], "seq": game.next_command_sequence(owner), "test_marker": "one_move_owner_1"}})
					check(not game.entities_by_id.has(int(directive.actors["2"])), "hidden_enemy_has_no_live_client_node")
					game.submit_local({"kind": "move", "units": [int(directive.actors["0"])], "at": [0, 0, 0]})
					game.submit_local({"kind": "attack", "units": [id], "target": int(directive.actors["0"])})
					game.submit_local({"kind": "attack", "units": [id], "target": int(directive.actors["2"])})
					check(game.get_player(0).gold != 9001, "ally_private_gold_not_replicated")
				if owner == 2:
					game.get_player(owner).gold = 999999
					game.submit_local({"kind": "recruit", "target": int(directive.bases[str(owner)]), "unit_type": "farmer", "gold": 999999, "owner": 0})
					relay._send({"op": "event", "match": relay._match.match_id, "to": 0, "payload": {"kind": "grant_gold", "amount": 999999}}, NetworkProtocol.EVENT_CHANNEL)
					check(await until(func(): return "host_only" in errors, 5.0), "guest_cannot_forge_authoritative_event")
				phase = stage
			"queues":
				var barracks_id: int = int(directive.barracks[str(owner)])
				var academy_id: int = int(directive.academies[str(owner)])
				check(await until(func(): return game.entities_by_id.has(barracks_id) and game.entities_by_id.has(academy_id), 10.0), "own_production_buildings_arrive")
				for index in 2:
					game.submit_local({"kind": "recruit", "target": barracks_id, "unit_type": "swordsman"})
				for upgrade: String in ["attack_1", "defense_1"]:
					game.submit_local({"kind": "research", "target": academy_id, "upgrade": upgrade})
				check(await until(func(): return game.entities_by_id[barracks_id].production.training.size() == 2 and game.entities_by_id[academy_id].production.research_queue.size() == 2 and game.get_player(owner).reserved_military_supply == 2, 5.0), "owner_receives_two_training_and_two_research_jobs")
				check(game.get_player(owner).military_supply == 1, "client_sees_reservation_before_spawn")
				phase = stage
			"queues_done":
				check(await until(func(): return game.get_player(owner).attack_level == 1 and game.get_player(owner).defense_level == 1 and game.get_player(owner).reserved_military_supply == 0 and game.entities_by_id[int(directive.academies[str(owner)])].production.research_queue.is_empty(), 10.0), "completed_research_and_reservations_replicate")
				phase = stage
			"guest_drop":
				if owner == 3:
					drop_transport()
				phase = stage
			"guest_resume":
				if owner == 3:
					var before: int = snapshots
					resume_transport()
					check(await until(func(): return relay.connection_state == "match" and snapshots > before + 1, 15.0), "guest_rejoined_receives_current_snapshot")
					check(game.get_instance_id() == scene_identity, "guest_keeps_same_main_scene")
				phase = stage
			"host_drop":
				phase = stage
			"host_resume":
				check(await until(func(): return relay.connection_state == "match" and not paused, 12.0), "host_resume_resumes_remote_simulation_view")
				phase = stage
			"attack":
				var enemy_id: int = int(directive.actors["2" if owner == 1 else "1"])
				check(await until(func(): return game.entities_by_id.has(enemy_id), 10.0), "shared_vision_reveals_central_enemy")
				if owner == 1:
					game.submit_local({"kind": "attack", "units": [int(directive.actors["1"])], "target": int(directive.actors["2"])})
				phase = stage
		status(true)
	check(false, "scenario_deadline")

func drop_transport() -> void:
	if relay._peer != null:
		relay._peer.peer_disconnect_now()
	relay._close_transport()
	relay._retry_at = 0
	relay._set_state("reconnecting")

func resume_transport() -> void:
	relay._reconnect_deadline = Time.get_ticks_msec() + (30000 if owner == 0 else 120000)
	relay._retry_at = Time.get_ticks_msec() + 1

func _snapshot(snapshot: Dictionary) -> void:
	snapshots += 1
	var now := Time.get_ticks_msec()
	if phase.begins_with("network_load"):
		_load_last_count = 0
		for entity: Dictionary in snapshot.get("entities", []):
			if entity.get("category") == "unit":
				_load_last_count += 1
		if phase == "network_load":
			if _load_first_snapshot_msec < 0:
				_load_first_snapshot_msec = now
			_load_counts.append(_load_last_count)
			if _load_last_msec > 0:
				_load_gaps.append(now - _load_last_msec)
				if now - _load_last_msec > 200:
					_load_long_gaps.append({"at_ms": now - _load_started_msec, "gap_ms": now - _load_last_msec,
						"tick": int(snapshot.tick), "previous_tick": _last_snapshot_tick})
			_load_last_msec = now
	if int(snapshot.tick) < _last_snapshot_tick:
		_snapshot_tick_regressions += 1
	_last_snapshot_tick = int(snapshot.tick)
	# Deliberate outage phases are not network jitter. Reset their baseline so
	# the 10-second Bot-grace exercise cannot pollute normal snapshot percentiles.
	if phase in ["orders", "steady", "attack"] and relay.connection_state == "match":
		if _last_snapshot_msec > 0:
			_snapshot_gaps.append(now - _last_snapshot_msec)
		_last_snapshot_msec = now
	else:
		_last_snapshot_msec = 0
	for player: Dictionary in snapshot.get("players", []):
		if player.has("private") and int(player.owner_id) != relay.owner_id:
			check(false, "snapshot_leaked_other_player_economy")
		if int(player.owner_id) == relay.owner_id and int(player.get("private", {}).get("reserved_supply", 0)) == 2:
			_saw_reserved_population = true
	for entity: Dictionary in snapshot.get("entities", []):
		if int(entity.owner) != relay.owner_id and (entity.has("production") or entity.has("rally") or entity.has("queued_count") or entity.has("plan")):
			check(false, "snapshot_leaked_other_player_orders")
		if int(entity.owner) == relay.owner_id:
			if entity.has("plan") and int(entity.get("queued_count", 0)) > 0 and entity.plan.size() >= 2:
				_saw_private_queue_plan = true
			if entity.has("production") and entity.production.research_queue.size() == 2:
				_saw_private_research_queue = true
	if phase in ["orders", "steady"] and relay.owner_id == 1:
		var enemy_id := int(_published.get("actors", {}).get("2", -1))
		for entity: Dictionary in snapshot.get("entities", []):
			if int(entity.id) == enemy_id:
				check(false, "snapshot_leaked_hidden_enemy_pose")

func _event(event: Dictionary) -> void:
	var kind: String = event.get("kind", "")
	events[kind] = int(events.get(kind, 0)) + 1
	if kind == "grant_gold":
		check(false, "forged_authoritative_event_delivered")

func _error(code: String, _message: String) -> void:
	errors.append(code)
	if code != "resume_pending" and not (code == "host_only" and relay.owner_id == 2):
		check(false, "unexpected_transport_error_" + code)

func publish(stage: String) -> void:
	phase = stage
	_published.stage = stage
	write_record("phase.json", _published)
	status(true)

func all_phase(stage: String) -> bool:
	for index in range(1, 4):
		var record := read_record("peer-%d.json" % index)
		if record.get("phase") != stage:
			return false
	return true

func all_event(kind: String) -> bool:
	for index in range(1, 4):
		var record := read_record("peer-%d.json" % index)
		if int(record.get("events", {}).get(kind, 0)) == 0:
			return false
	return true

func owner_status(target_owner: int) -> Dictionary:
	for index in range(4):
		var record := read_record("peer-%d.json" % index)
		if int(record.get("owner", -1)) == target_owner:
			return record
	return {}

func status(force: bool = false) -> void:
	var now := Time.get_ticks_msec()
	if _load_units > 0 and phase.begins_with("network_load") and now >= _native_sample_at and relay._peer != null and relay._peer.is_active():
		_native_sample_at = now + 50
		_native_samples.append({"at_ms": now - _load_started_msec if _load_started_msec > 0 else -1, "phase": phase,
			"throttle": relay._peer.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE),
			"limit": relay._peer.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_LIMIT),
			"rtt": relay._peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME),
			"variance": relay._peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME_VARIANCE),
			"last_rtt": relay._peer.get_statistic(ENetPacketPeer.PEER_LAST_ROUND_TRIP_TIME),
			"last_variance": relay._peer.get_statistic(ENetPacketPeer.PEER_LAST_ROUND_TRIP_TIME_VARIANCE)})
	if not force and now - _last_status_msec < 250:
		return
	_last_status_msec = now
	write_record("peer-%d.json" % peer_index, {"owner": owner, "phase": phase, "snapshots": snapshots,
		"events": events, "checks": checks, "failures": failures, "load_count": _load_last_count,
		"last_tick": game.simulation_tick if is_instance_valid(game) else -1})

func until(predicate: Callable, duration: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(duration * 1000)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		status()
		await process_frame
	return bool(predicate.call())

func seconds(duration: float) -> void:
	var deadline := Time.get_ticks_msec() + int(duration * 1000)
	while Time.get_ticks_msec() < deadline:
		status()
		await process_frame

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition and label not in failures:
		failures.append(label)

func read_record(name: String) -> Dictionary:
	var path := directory.path_join(name)
	if not FileAccess.file_exists(path):
		return {}
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK or not parser.data is Dictionary:
		return {}
	return parser.data

func write_record(name: String, record: Dictionary) -> void:
	var path := directory.path_join(name)
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	file.store_string(JSON.stringify(record))
	file.close()
	# Windows can briefly refuse replacement while another test peer reads the
	# previous status. An ignored rename error would silently skip a whole phase.
	for attempt in range(8):
		if DirAccess.rename_absolute(path + ".tmp", path) == OK:
			return
		_file_publish_retries += 1
		OS.delay_msec(1)
	check(false, "coordinator_publish_failed_" + name)

func finish() -> void:
	if _finishing:
		return
	_finishing = true
	if owner == 0 and phase != "finish":
		publish("finish")
		if is_instance_valid(game):
			game.end_battle(false)
		else:
			relay.finish_match({"winner": 1, "time": 0})
		await seconds(0.3)
	paused = false
	if is_instance_valid(game):
		await game.prepare_shutdown()
	relay.disconnect_relay()
	var result := {"owner": owner, "checks": checks, "failures": failures, "snapshots": snapshots,
		"snapshot_rejections": snapshot_rejections, "match_starts": match_starts, "events": events,
		"error_codes": errors, "transport_states": _transport_states,
		"observed_stages": _observed_stages, "coordinator_publish_retries": _file_publish_retries,
		"snapshot_gap_ms": gap_statistics(), "snapshot_tick_regressions": _snapshot_tick_regressions,
		"network_load": _load_report, "peer_index": peer_index,
		"elapsed_seconds": (Time.get_ticks_msec() - started_msec) / 1000.0}
	write_record("result-%d.json" % peer_index, result)
	print("NETWORK_GAME_LIVE_PEER " + JSON.stringify(result))
	quit(0 if failures.is_empty() else 1)

func gap_statistics() -> Dictionary:
	if _snapshot_gaps.is_empty():
		return {"samples": 0}
	var sorted := _snapshot_gaps.duplicate()
	sorted.sort()
	var total: int = 0
	for gap: int in sorted:
		total += gap
	return {"samples": sorted.size(), "mean": float(total) / sorted.size(),
		"p50": sorted[int((sorted.size() - 1) * 0.5)],
		"p95": sorted[int((sorted.size() - 1) * 0.95)], "max": sorted.back()}

static func data(at: Vector3) -> Array:
	return [at.x, at.y, at.z]

static func vec(at: Array) -> Vector3:
	return Vector3(float(at[0]), float(at[1]), float(at[2]))

static func number_statistics(values: Array) -> Dictionary:
	if values.is_empty():
		return {"samples": 0}
	var ordered := values.duplicate()
	ordered.sort()
	var total: float = 0.0
	for value in ordered:
		total += float(value)
	return {"samples": ordered.size(), "min": ordered.front(), "mean": total / ordered.size(),
		"p50": ordered[int((ordered.size() - 1) * 0.5)], "p95": ordered[int((ordered.size() - 1) * 0.95)],
		"p99": ordered[int((ordered.size() - 1) * 0.99)], "max": ordered.back()}

func host_network_load() -> void:
	check(_load_units == 280, "load_fixture_is_four_real_sixty_supply_ten_farmer_rosters")
	if _load_units != 280:
		return
	publish("network_load_setup")
	game.select_entities([])
	game.control_groups.clear()
	game.bots.clear()
	game.get_node("IncomeTimer").stop()
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		while not building.production.training.is_empty():
			building.production.cancel_training(0)
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		# Fixture replacement bypasses death; preserve the registry invariant
		# normally maintained by Game.on_entity_died before freeing old actors.
		game.entities_by_id.erase(unit.entity_id)
		unit.queue_free()
	await physics_frame
	await process_frame
	for player: PlayerState in game.players:
		player.farmers = 0
		player.reserved_farmers = 0
		player.military_supply = 0
	# This isolated fixture deliberately models worst-case visibility. Keep the
	# configured fog serializer intact while postponing only future recomputes.
	var fog: FogOfWar = game.get_node("FogOfWar")
	fog._tick_time = -_load_seconds - 90.0
	for alliance: int in range(2):
		var cells: PackedByteArray = fog._cells[alliance]
		cells.fill(2)
		fog._cells[alliance] = cells
	fog.revision += 1
	fog.apply_visibility(0)
	var taken: Dictionary = {}
	for player: PlayerState in game.players:
		var points := _load_spawn_points(player.owner_id, taken)
		check(points.size() == 70, "seventy_nonoverlapping_walkable_spawns_owner_%d" % player.owner_id)
		if points.size() != 70:
			return
		for index: int in range(70):
			var unit: BattleUnit = game.spawn_unit("farmer" if index < 10 else "swordsman", player.owner_id, points[index])
			_load_routes[unit.entity_id] = [points[index], points[(index + 35) % 70]]
			unit.issue_move(points[(index + 35) % 70])
		check(player.farmers == 10 and player.military_supply == 60, "load_keeps_real_owner_population_limits_%d" % player.owner_id)
	await seconds(2.0)
	check(await until(func(): return all_phase("network_load_ready"), 25.0), "three_clients_have_complete_load_roster")
	var probe: Node = preload("res://tests/skirmish_profile_probe.tscn").instantiate()
	game.add_child(probe)
	probe.begin_sample()
	var tick_start: int = game.simulation_tick
	var began: int = Time.get_ticks_usec()
	_load_started_msec = Time.get_ticks_msec()
	var first_positions: Dictionary = {}
	var moved_ids: Dictionary = {}
	var moving_samples: Array[int] = []
	for unit: BattleUnit in get_nodes_in_group("units"):
		first_positions[unit.entity_id] = unit.position
	publish("network_load")
	var reissue_at: int = 0
	var motion_check_at: int = 0
	var turn: int = 0
	while Time.get_ticks_usec() - began < int(_load_seconds * 1000000):
		if Time.get_ticks_msec() >= motion_check_at:
			motion_check_at = Time.get_ticks_msec() + 1000
			var active: int = 0
			for unit: BattleUnit in get_nodes_in_group("units"):
				if unit.position.distance_to(first_positions[unit.entity_id]) > 0.5:
					moved_ids[unit.entity_id] = true
				if unit.velocity.length_squared() > 0.04:
					active += 1
			moving_samples.append(active)
		if Time.get_ticks_msec() >= reissue_at:
			reissue_at = Time.get_ticks_msec() + 2500
			turn += 1
			for unit: BattleUnit in get_nodes_in_group("units"):
				unit.issue_move(_load_routes[unit.entity_id][turn % 2])
		status()
		await process_frame
	var elapsed: float = (Time.get_ticks_usec() - began) / 1000000.0
	var ticks: int = game.simulation_tick - tick_start
	var physics_ms: Array = probe.end_sample()
	var units: Array[Node] = get_nodes_in_group("units")
	var moving: int = moved_ids.size()
	check(units.size() == _load_units and units.all(func(unit): return unit.alive and unit.is_physics_processing() and unit.navigation_agent.avoidance_enabled), "load_all_280_units_keep_native_physics_and_rvo")
	check(moving >= 210, "at_least_three_quarters_of_roster_actually_displaced_during_march")
	_load_report = {"units": units.size(), "expected_units": _load_units, "seconds": elapsed, "ticks": ticks,
		"tps": ticks / elapsed, "physics_logic_ms": number_statistics(physics_ms), "physics_logic_samples_ms": physics_ms,
		"moved_units": moving, "moving_units_samples": moving_samples, "full_visibility": true,
		"native_transport_samples": _native_samples,
		"scope": "four owners each 10 farmers + 60 swordsmen, all visible, native CharacterBody/RVO/NavigationAgent enabled; SceneTree priority markers bracket callbacks, not the whole native physics server step"}
	publish("network_load_end")
	check(await until(func(): return all_phase("network_load_end"), 12.0), "three_clients_finish_independent_load_measurements")
	check(await until(func(): return read_record("udp-window-ended.json").get("complete", false), 3.0), "runner_acknowledges_isolated_udp_measurement_window")
	probe.queue_free()

func _load_spawn_points(target_owner: int, taken: Dictionary) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var bases: Array[Vector3] = []
	for index: int in range(4):
		bases.append(game.map_instance.get_node("SpawnPoints/Player%d" % index).position)
	var home: Vector3 = bases[target_owner]
	var candidates: Array[Vector3] = []
	var navigation: ConstructionNavigation = game.get_node("ConstructionNavigation")
	for x: int in range(-24, 25, 2):
		for z: int in range(-24, 25, 2):
			var at := home + Vector3(x, 0, z)
			if taken.has(at) or not navigation.contains_walkable_point(at):
				continue
			var nearest: bool = true
			for index: int in range(4):
				if index != target_owner and at.distance_squared_to(bases[index]) < at.distance_squared_to(home) + 4.0:
					nearest = false
			if nearest:
				candidates.append(at)
	candidates.sort_custom(func(a: Vector3, b: Vector3): return a.distance_squared_to(home) < b.distance_squared_to(home))
	var query := PhysicsShapeQueryParameters3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.72
	query.shape = shape
	query.collision_mask = 1 | 2 | 4 | 128
	var world: World3D = game.get_world_3d()
	for at: Vector3 in candidates:
		var closest: Vector3 = NavigationServer3D.map_get_closest_point(world.navigation_map, at)
		if closest.distance_squared_to(at) > 0.01:
			continue
		query.transform.origin = at + Vector3.UP * 0.9
		if not world.direct_space_state.intersect_shape(query, 1).is_empty():
			continue
		taken[at] = true
		result.append(at)
		if result.size() == 70:
			break
	return result
