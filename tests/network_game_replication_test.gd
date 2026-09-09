extends SceneTree

const FIXTURE = preload("res://tests/network_game_fixture.tscn")
const RELAY_SCENE = preload("res://scripts/network/relay_client.tscn")
const Replication = preload("res://scripts/network/match_replication.gd")
var checks: int = 0
var failures: Array[String] = []

class RecordingRelay extends RelayClient:
	var captured: Dictionary = {}
	var visual_packets: Array[Dictionary] = []
	func snapshot_to(owner: int, snapshot: Dictionary) -> Error:
		if not captured.has(owner):
			captured[owner] = []
		captured[owner].append(int(snapshot.tick))
		return OK
	func send_event(owner: int, event: Dictionary) -> Error:
		visual_packets.append({"owner": owner, "event": event})
		return OK

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)

func _run() -> void:
	var host = FIXTURE.instantiate()
	root.add_child(host)
	var host_relay: RelayClient = RELAY_SCENE.instantiate()
	host.add_child(host_relay)
	var sender: Replication = host.get_node("MatchReplication")
	sender.configure(host, host_relay)
	var own: BattleUnit = host.spawn_unit("knight", 0, Vector3.ZERO)
	var ally: BattleUnit = host.spawn_unit("farmer", 1, Vector3(2, 0, 1))
	var enemy: BattleUnit = host.spawn_unit("archer", 2, Vector3(4, 0, 2))
	var hidden: BattleUnit = host.spawn_unit("cannon", 3, Vector3(60, 0, 60))
	var own_building: BattleBuilding = host.spawn_building("headquarters", 0, Vector3(0, 0, 10))
	var ally_building: BattleBuilding = host.spawn_building("academy", 1, Vector3(10, 0, 10))
	var enemy_building: BattleBuilding = host.spawn_building("defense_tower", 2, Vector3(12, 0, 10), true)
	host.visible_ids.assign([enemy.entity_id, enemy_building.entity_id])
	own.hp = 111
	own._moving = true
	own.waypoint_queue.append({"kind": "move", "position": Vector3(20, 0, 20), "attack_move": false})
	own.model_pivot.rotation.y = deg_to_rad(175)
	own._model.strike()
	own._attack_animation.seek(0.1, true, true)
	ally._working = true
	ally.work_progress = 0.5
	ally._model.set_working(true, "gather")
	host.get_node("Mine").try_claim(ally)
	own_building.production.training.append({"kind": "farmer", "elapsed": 4.0, "cost": 50})
	own_building.production.rally_mine = host.get_node("Mine")
	ally_building.production.research_id = "attack_1"
	enemy_building.construction_progress = 0.45
	var snapshot := sender.build_snapshot(0)
	check(snapshot.entities.size() == 6, "allies_visible_enemies_only")
	check(not _ids(snapshot).has(hidden.entity_id), "hidden_enemy_id_and_position_not_sent")
	check(not _ids(snapshot).has(host.get_node("Mine").entity_id), "map_mines_not_duplicated")
	check(snapshot.mines.size() == 1 and snapshot.mines[0].workers == 1, "visible_mine_occupancy_sent")
	check(snapshot.players[0].private.gold == 700, "own_economy_sent")
	check(not snapshot.players[1].has("private") and not snapshot.players[2].has("private"), "ally_enemy_economy_private")
	check(not _state(snapshot, ally_building.entity_id).has("production"), "ally_research_private")
	check(not _state(snapshot, enemy_building.entity_id).has("rally"), "enemy_orders_private")
	check(_state(snapshot, own_building.entity_id).production.training.size() == 1, "own_training_sent")
	check(snapshot.fog.memories.size() == 1, "fog_memory_uses_last_seen_payload")
	var bytes := NetworkProtocol.encode({"op": "snapshot", "payload": snapshot})
	check(not bytes.is_empty(), "actual_scene_state_is_safe_primitive")
	snapshot = NetworkProtocol.decode(bytes).payload
	var client = FIXTURE.instantiate()
	root.add_child(client)
	var client_relay: RelayClient = RELAY_SCENE.instantiate()
	client.add_child(client_relay)
	var receiver: Replication = client.get_node("MatchReplication")
	receiver.configure(client, client_relay)
	var displayed: Array[Dictionary] = []
	receiver.visual_event_due.connect(func(event: Dictionary): displayed.append(event))
	receiver.receive_snapshot(snapshot)
	client_relay.event_received.emit({"kind": "visual_batch", "events": [{"kind": "sound", "sound": "sword_swing", "time": 0.02}]})
	check(displayed.is_empty(), "reliable_sound_waits_for_presentation_clock")
	check(receiver.last_received_tick == 0, "wire_snapshot_valid")
	check(client.entities_by_id.size() == 7, "client_creates_six_replicas_preserves_mine")
	var remote: BattleUnit = client.entities_by_id[own.entity_id]
	check(remote.unit_type == "knight" and remote.owner_id == 0, "stable_identity_and_type")
	check(remote.get_meta("replica_queue_count") == 1 and remote.waypoint_queue.is_empty(), "own_queue_count_without_executable_orders")
	check(is_equal_approx(remote.hp, 111.0), "health_applied")
	check(not remote.is_physics_processing() and not remote.navigation_agent.avoidance_enabled, "no_client_simulation_or_rvo")
	check(remote.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF, "no_double_interpolation")
	check(remote.attack_windup.is_stopped(), "client_damage_timer_stopped")
	check(remote._attack_animation.callback_mode_process == AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL, "attack_is_presentation_only")
	var remote_building: BattleBuilding = client.entities_by_id[own_building.entity_id]
	check(not remote_building.production.is_physics_processing(), "client_production_stopped")
	check(remote_building.production.training[0].elapsed == 4.0, "own_training_ui_copied")
	check(remote_building.production.rally_mine == client.get_node("Mine"), "stable_mine_rally_reference")
	check(client.get_node("Mine").occupied_slots() == 1, "mine_occupancy_ui_copied")
	check(client.get_node("FogOfWar").last_applied.owner == 0, "recipient_fog_applied")
	client.get_player(0).gold = 1
	own.global_position.x = 10
	own.model_pivot.rotation.y = deg_to_rad(-175)
	own._attack_animation.seek(0.166, true, true)
	host.simulation_tick = 2
	host.elapsed = 2.0 / 30.0
	var second := sender.build_snapshot(0)
	receiver.receive_snapshot(second)
	receiver._playback_time = 1.0 / 30.0
	receiver.render(0.0)
	check(displayed.size() == 1 and displayed[0].kind == "sound", "visual_event_follows_interpolated_attack_clock")
	check(is_equal_approx(remote.global_position.x, 5.0), "snapshot_position_interpolates_halfway")
	check(absf(absf(remote.model_pivot.rotation.y) - PI) < 0.001, "yaw_takes_short_arc")
	check(absf(remote._attack_animation.current_animation_position - 0.133) < 0.001, "authored_attack_phase_interpolates")
	check(client.get_player(0).gold == 1, "economy_uses_same_delayed_frame")
	receiver._playback_time = 2.0 / 30.0
	receiver.render(0.0)
	check(client.get_player(0).gold == 700, "economy_advances_with_authoritative_frame")
	check(is_equal_approx(remote.global_position.x, 10), "second_frame_exact")
	receiver.render(3.0)
	check(is_equal_approx(remote.global_position.x, 10), "packet_stall_never_extrapolates")
	var invalid := second.duplicate(true)
	invalid.tick = 4
	invalid.entities[0].p = ["unsafe", 0, 0]
	receiver.receive_snapshot(invalid)
	check(receiver.last_received_tick == 2, "malformed_transform_rejected_atomically")
	invalid = second.duplicate(true)
	invalid.tick = 4
	invalid.entities[0].id = client.get_node("Mine").entity_id
	receiver.receive_snapshot(invalid)
	check(receiver.last_received_tick == 2, "replica_cannot_overwrite_map_identity")
	invalid = second.duplicate(true)
	invalid.tick = 4
	invalid.players[1]["private"] = invalid.players[0].private
	receiver.receive_snapshot(invalid)
	check(receiver.last_received_tick == 2, "unexpected_other_player_private_state_rejected")
	host.visible_ids.clear()
	host.simulation_tick = 4
	host.elapsed = 4.0 / 30.0
	var third := sender.build_snapshot(0)
	receiver.receive_snapshot(third)
	receiver._playback_time = host.elapsed
	receiver.render(0.0)
	check(not client.entities_by_id.has(enemy.entity_id) and not client.entities_by_id.has(enemy_building.entity_id), "lost_visibility_removes_live_enemy_state")
	check(client.entities_by_id.has(ally.entity_id), "allies_remain_without_local_vision")
	check(client.deaths == 0 and client.effects == 0, "visibility_loss_never_calls_death_effects")
	check(client.get_node("FogOfWar").last_applied.memories.size() == 1, "memory_survives_live_entity_removal")
	await process_frame
	host.visible_ids.assign([enemy.entity_id])
	host.simulation_tick = 6
	host.elapsed = 6.0 / 30.0
	enemy.hp = 20
	receiver.receive_snapshot(sender.build_snapshot(0))
	receiver._playback_time = host.elapsed
	receiver.render(0.0)
	check(client.entities_by_id[enemy.entity_id].hp == 20, "reentry_reconstructs_current_visible_state")
	check(client.get_player(0).farmers == 0, "replica_creation_does_not_invent_economy")
	var identity_before_resume: int = remote.get_instance_id()
	client_relay.event_received.emit({"kind": "visual_batch", "events": [{"kind": "sound", "sound": "footstep_dirt", "time": 0.5}]})
	host.simulation_tick = 456
	host.elapsed = 15.2
	own.global_position.x = 20
	receiver.receive_snapshot(sender.build_snapshot(0))
	receiver.render(0.0)
	check(absf(client.elapsed - 15.08) < 0.001 and remote.global_position.x == 20, "long_outage_resumes_current_timeline")
	check(remote.get_instance_id() == identity_before_resume, "recovery_preserves_existing_entity_instances")
	check(displayed.size() == 1, "reconnect_discards_expired_sounds_instead_of_replaying_a_burst")
	current_scene = host
	for index in range(276):
		host.spawn_unit("swordsman", index % 2, Vector3(index % 20, 0, index / 20))
	host.visible_ids.assign([enemy.entity_id, hidden.entity_id, enemy_building.entity_id])
	var large := sender.build_snapshot(0)
	bytes = NetworkProtocol.encode({"op": "snapshot", "payload": large})
	check(not bytes.is_empty(), "280_units_fit_primitive_wire_budget")
	var began: int = Time.get_ticks_usec()
	for iteration in range(30):
		NetworkProtocol.encode({"op": "snapshot", "payload": sender.build_snapshot(0)})
	var encoding_usec: float = (Time.get_ticks_usec() - began) / 30.0
	began = Time.get_ticks_usec()
	for iteration in range(30):
		sender.build_snapshot(0)
	var build_usec: float = (Time.get_ticks_usec() - began) / 30.0
	began = Time.get_ticks_usec()
	for iteration in range(30):
		NetworkProtocol.encode({"op": "snapshot", "payload": large})
	var encode_usec: float = (Time.get_ticks_usec() - began) / 30.0
	began = Time.get_ticks_usec()
	for iteration in range(30):
		NetworkProtocol._primitive(large, 0, [NetworkProtocol.MAX_VALUES] as Array[int])
	var primitive_usec: float = (Time.get_ticks_usec() - began) / 30.0
	began = Time.get_ticks_usec()
	for iteration in range(30):
		JSON.stringify(large, "", false)
	var json_usec: float = (Time.get_ticks_usec() - began) / 30.0
	print("NETWORK_GAME_METRICS " + JSON.stringify({"entities": large.entities.size(), "decoded_bytes": NetworkProtocol.decoded_size(bytes), "wire_bytes": bytes.size(), "build_encode_mean_usec": encoding_usec, "build_mean_usec": build_usec, "encode_mean_usec": encode_usec, "primitive_mean_usec": primitive_usec, "json_mean_usec": json_usec}))
	var recording := RecordingRelay.new()
	host.add_child(recording)
	recording.connection_state = "match"
	sender.configure(host, recording)
	host.is_authority = true
	for index in range(300):
		sender.queue_host_visual(1, {"kind": "sound", "sound": "footstep_dirt", "at": [0, 0, 0]})
	check(sender._outbound_visual[1].size() == Replication.MAX_VISUAL_EVENTS, "outbound_visual_backlog_is_bounded")
	for simulation_frame in range(7, 13):
		host.simulation_tick = simulation_frame
		sender.tick(1.0 / 30.0)
		sender.tick(1.0 / 30.0)
	check(recording.captured[1] == [8, 10, 12] and recording.captured[2] == [7, 9, 11] and recording.captured[3] == [8, 10, 12], "three_clients_each_15hz_without_three_snapshots_in_one_tick")
	check(not recording.captured.has(0), "host_does_not_replicate_to_itself")
	check(recording.visual_packets.size() == 3 and recording.visual_packets[0].event.events.size() == 96 and recording.visual_packets[2].event.events.size() == 64, "300_sounds_use_three_bounded_reliable_batches")
	check(recording.visual_packets.all(func(packet): return NetworkProtocol.decoded_size(NetworkProtocol.encode({"op": "event", "payload": packet.event})) < NetworkProtocol.MAX_EVENT_BYTES), "visual_batches_respect_transport_size_limit")
	client.queue_free()
	host.queue_free()
	current_scene = null
	await process_frame
	await process_frame
	print("NETWORK_GAME_RESULTS " + JSON.stringify({"passed": checks - failures.size(), "total": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)

func _ids(snapshot: Dictionary) -> Array:
	return snapshot.entities.map(func(state): return int(state.id))

func _state(snapshot: Dictionary, id: int) -> Dictionary:
	for state: Dictionary in snapshot.entities:
		if int(state.id) == id:
			return state
	return {}
