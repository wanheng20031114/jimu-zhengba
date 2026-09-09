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

func _initialize() -> void:
	Engine.max_fps = 60
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--live-dir="):
			directory = argument.trim_prefix("--live-dir=")
		elif argument.begins_with("--peer-index="):
			peer_index = int(argument.trim_prefix("--peer-index="))
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
	game.get_player(0).gold = 9001
	_published = {"actors": actors, "bases": bases, "starts": starts, "destinations": destinations}
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
	await seconds(0.6)
	for client_owner in range(1, 4):
		var report := owner_status(client_owner)
		check(int(report.get("snapshots", 0)) > 20, "continuous_world_snapshots_owner_%d" % client_owner)
	check(failures.is_empty(), "host_scenario_complete")
	check(_transport_states.count("reconnecting") == 1, "host_has_only_planned_transport_interruption")
	game.end_battle(true)
	publish("finish")
	await seconds(0.5)

func client_steps() -> void:
	var previous: String = ""
	while Time.get_ticks_msec() - started_msec < 135000:
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
			return
		if stage == previous:
			status()
			await process_frame
			continue
		previous = stage
		_observed_stages.append(stage)
		_published = directive
		match stage:
			"steady":
				phase = stage
			"orders":
				var id := int(directive.actors[str(owner)])
				check(await until(func(): return game.entities_by_id.has(id), 10.0), "own_military_replica_arrives")
				game.submit_local({"kind": "move", "units": [id], "at": directive.destinations[str(owner)], "owner": (owner + 1) % 4, "test_marker": "one_move_owner_%d" % owner})
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
	for entity: Dictionary in snapshot.get("entities", []):
		if int(entity.owner) != relay.owner_id and (entity.has("production") or entity.has("rally") or entity.has("queued_count")):
			check(false, "snapshot_leaked_other_player_orders")
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
	if not force and now - _last_status_msec < 250:
		return
	_last_status_msec = now
	write_record("peer-%d.json" % peer_index, {"owner": owner, "phase": phase, "snapshots": snapshots,
		"events": events, "checks": checks, "failures": failures, "last_tick": game.simulation_tick if is_instance_valid(game) else -1})

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
