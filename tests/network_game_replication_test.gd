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
	func snapshot_json_to(owner: int, snapshot_json: String) -> Error:
		return snapshot_to(owner, JSON.parse_string(snapshot_json))
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
	own.order = BattleUnit.Order.ATTACK
	own.target = enemy
	own.model_pivot.rotation.y = deg_to_rad(175)
	own._model.strike()
	own._attack_animation.seek(0.1, true, true)
	ally._working = true
	ally.work_progress = 0.5
	ally._model.set_working(true, "gather")
	host.get_node("Mine").try_claim(ally)
	own_building.production.training.append({"kind": "farmer", "elapsed": 4.0, "cost": 50, "job_id": 1})
	own_building.production.rally_mine = host.get_node("Mine")
	ally_building.production.research_queue.append({"id": "attack_1", "elapsed": 0.0, "cost": 100, "job_id": 1})
	enemy_building.construction_progress = 0.45
	var snapshot := sender.build_snapshot(0)
	check(snapshot.entities.size() == 6, "allies_visible_enemies_only")
	check(not _ids(snapshot).has(hidden.entity_id), "hidden_enemy_id_and_position_not_sent")
	check(not _ids(snapshot).has(host.get_node("Mine").entity_id), "map_mines_not_duplicated")
	check(snapshot.mines.size() == 1 and snapshot.mines[0].workers == 1, "visible_mine_occupancy_sent")
	check(snapshot.players[0].private.gold == 700, "own_economy_sent")
	check(snapshot.players[0].private.workforce_level == 0, "own_unresearched_workforce_level_sent")
	check(snapshot.players[0].private.army_capacity_level == 0 and snapshot.players[0].private.mining_level == 0,
		"own_unresearched_army_and_mining_levels_sent")
	check(not snapshot.players[1].has("private") and not snapshot.players[2].has("private"), "ally_enemy_economy_private")
	check(not _state(snapshot, ally_building.entity_id).has("production"), "ally_research_private")
	check(not _state(snapshot, enemy_building.entity_id).has("rally"), "enemy_orders_private")
	check(not _state(snapshot, ally.entity_id).has("plan") and not _state(snapshot, enemy.entity_id).has("plan"), "allied_and_enemy_unit_plans_private")
	check(_state(snapshot, own.entity_id).plan == [{"kind": "attack", "at": [4.0, 0.0, 2.0]}, {"kind": "move", "at": [20.0, 0.0, 20.0]}], "own_visible_attack_and_following_move_plan")
	check(_state(snapshot, own_building.entity_id).production.training.size() == 1, "own_training_sent")
	check(not snapshot.fog.has("memories") and not snapshot.fog.has("buildings"), "fog_has_no_enemy_memory_payload")
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
	check(client.get_player(0).get_worker_limit() == 10, "initial_worker_limit_is_authoritative_ten")
	check(client.get_player(0).get_supply_limit() == 50 and client.get_player(0).mining_level == 0,
		"initial_army_limit_and_mining_level_are_authoritative")
	check(client.entities_by_id.size() == 7, "client_creates_six_replicas_preserves_mine")
	var remote: BattleUnit = client.entities_by_id[own.entity_id]
	check(remote.unit_type == "knight" and remote.owner_id == 0, "stable_identity_and_type")
	check(remote.get_meta("replica_queue_count") == 1 and remote.waypoint_queue.is_empty(), "own_queue_count_without_executable_orders")
	check(remote.get_meta("replica_order_plan") == _state(snapshot, own.entity_id).plan, "plan_is_display_metadata_not_executable_orders")
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
	client.get_player(0).workforce_level = 1
	client.get_player(0).army_capacity_level = 2
	client.get_player(0).mining_level = 3
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
	check(client.get_player(0).workforce_level == 0 and client.get_player(0).get_worker_limit() == 10,
		"local_workforce_forgery_overwritten_by_authority")
	check(client.get_player(0).army_capacity_level == 0 and client.get_player(0).get_supply_limit() == 50 and client.get_player(0).mining_level == 0,
		"local_army_and_mining_forgery_overwritten_by_authority")
	check(is_equal_approx(remote.global_position.x, 10), "second_frame_exact")
	receiver.render(3.0)
	check(is_equal_approx(remote.global_position.x, 10), "packet_stall_never_extrapolates")
	var invalid := second.duplicate(true)
	invalid.tick = 4
	invalid.entities[0].p = ["unsafe", 0, 0]
	receiver.receive_snapshot(invalid)
	check(receiver.last_received_tick == 2, "malformed_transform_rejected_atomically")
	for malformed_owner: Variant in [{}, []]:
		invalid = second.duplicate(true)
		invalid.tick = 4
		invalid.entities[0].owner = malformed_owner
		receiver.receive_snapshot(invalid)
		check(receiver.last_received_tick == 2 and remote.owner_id == 0, "malformed_existing_replica_owner_rejected_before_integer_conversion")
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
	for bad_level: Variant in [null, -1, 2, 0.5, "1", true, {}, []]:
		invalid = second.duplicate(true)
		invalid.tick = 4
		invalid.players[0].private.workforce_level = bad_level
		receiver.receive_snapshot(invalid)
		check(receiver.last_received_tick == 2 and client.get_player(0).get_worker_limit() == 10,
			"invalid_workforce_level_rejected_atomically")
	for track: String in ["army_capacity", "mining"]:
		for bad_level: Variant in [null, -1, BalanceCatalog.UPGRADE_TRACKS[track] + 1, 0.5, "1", true, {}, []]:
			invalid = second.duplicate(true)
			invalid.tick = 4
			invalid.players[0].private[track + "_level"] = bad_level
			receiver.receive_snapshot(invalid)
			check(receiver.last_received_tick == 2 and client.get_player(0).get_supply_limit() == 50 and client.get_player(0).mining_level == 0,
				"invalid_" + track + "_level_rejected_atomically")
	var all_research := second.duplicate(true)
	all_research.players[0].private.queued_research.clear()
	for upgrade_id: String in BalanceCatalog.UPGRADES:
		all_research.players[0].private.queued_research[upgrade_id] = 1
	all_research.players[0].private.active_research["workforce"] = 1
	all_research.players[0].private.active_research["army_capacity"] = 2
	all_research.players[0].private.active_research["mining"] = 3
	check(all_research.players[0].private.queued_research.size() == 14 and receiver._valid_snapshot(all_research),
		"fourteen_unique_player_research_reservations_across_academies_are_valid")
	all_research.players[0].private.active_research["unknown"] = 1
	check(not receiver._valid_snapshot(all_research), "unknown_active_research_track_rejected")
	for bad_plan: Variant in [null, "move", [{"kind": "attack", "at": [NAN, 0, 0]}], [{"kind": "move", "at": [5000, 0, 0]}], [{"kind": "unknown", "at": [1, 0, 1]}], [{"kind": "build", "at": [0, 0, 0], "entity": 5}], [{"kind": "move", "at": [0, 0]}]]:
		invalid = second.duplicate(true)
		invalid.tick = 4
		_state(invalid, own.entity_id)["plan"] = bad_plan
		receiver.receive_snapshot(invalid)
		check(receiver.last_received_tick == 2, "malformed_private_plan_rejected")
	invalid = second.duplicate(true)
	invalid.tick = 4
	_state(invalid, ally.entity_id)["plan"] = []
	receiver.receive_snapshot(invalid)
	check(receiver.last_received_tick == 2, "unexpected_ally_plan_rejected")
	invalid = second.duplicate(true)
	invalid.tick = 4
	_state(invalid, enemy_building.entity_id)["plan"] = []
	receiver.receive_snapshot(invalid)
	check(receiver.last_received_tick == 2, "unexpected_building_plan_rejected")
	var excessive: Array = []
	for index in 10:
		excessive.append({"kind": "move", "at": [index, 0, 0]})
	check(not UnitOrderPlan.valid(excessive), "plan_payload_strictly_bounded")
	host.visible_ids.clear()
	host.get_player(0).complete_upgrade(BalanceCatalog.upgrade("workforce_1"))
	host.get_player(0).complete_upgrade(BalanceCatalog.upgrade("army_capacity_2"))
	host.get_player(0).complete_upgrade(BalanceCatalog.upgrade("mining_3"))
	host.simulation_tick = 4
	host.elapsed = 4.0 / 30.0
	var third := sender.build_snapshot(0)
	check(_state(third, own.entity_id).plan[0] == {"kind": "unknown"}, "lost_enemy_plan_never_contains_live_location")
	var disappearing_unit: BattleUnit = client.entities_by_id[enemy.entity_id]
	var disappearing_building: BattleBuilding = client.entities_by_id[enemy_building.entity_id]
	disappearing_unit.set_selected(true)
	disappearing_building.set_selected(true)
	receiver.receive_snapshot(third)
	check(not client.entities_by_id.has(enemy.entity_id) and not client.entities_by_id.has(enemy_building.entity_id), "absence_removes_replica_on_receipt_before_interpolation")
	check(not disappearing_unit.visible and not disappearing_building.visible and not disappearing_unit.selected and not disappearing_building.selected, "same_frame_absence_hides_models_and_selection")
	check(disappearing_unit.collision_layer == 0 and disappearing_building.collision_layer == 0, "same_frame_absence_cannot_be_picked")
	check(receiver._frames.all(func(frame): return not frame.index.has(enemy.entity_id) and not frame.index.has(enemy_building.entity_id)), "older_interpolation_frames_cannot_resurrect_removed_entities")
	receiver.render(0.0)
	check(not client.entities_by_id.has(enemy.entity_id) and not client.entities_by_id.has(enemy_building.entity_id), "rendering_buffered_pose_never_restores_a_ghost")
	receiver._playback_time = host.elapsed
	receiver.render(0.0)
	check(client.get_player(0).workforce_level == 1 and client.get_player(0).get_worker_limit() == 12,
		"completed_workforce_upgrade_applies_from_owner_private_snapshot")
	check(client.get_player(0).army_capacity_level == 2 and client.get_player(0).get_supply_limit() == 100 and client.get_player(0).mining_level == 3,
		"completed_army_and_mining_upgrades_apply_from_owner_private_snapshot")
	check(client.get_player(1).get_worker_limit() == 10 and client.get_player(2).get_worker_limit() == 10,
		"worker_expansion_never_applies_to_allied_or_enemy_player")
	check(client.get_player(1).get_supply_limit() == 50 and client.get_player(2).get_supply_limit() == 50
		and client.get_player(1).mining_level == 0 and client.get_player(2).mining_level == 0,
		"army_and_mining_technology_never_leaks_to_allied_or_enemy_state")
	check(not client.entities_by_id.has(enemy.entity_id) and not client.entities_by_id.has(enemy_building.entity_id), "lost_visibility_removes_live_enemy_state")
	check(client.entities_by_id.has(ally.entity_id), "allies_remain_without_local_vision")
	check(client.deaths == 0 and client.effects == 0, "visibility_loss_never_calls_death_effects")
	check(not client.get_node("FogOfWar").last_applied.has("memories"), "live_entity_removal_leaves_no_memory")
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
	check(client.get_player(0).get_worker_limit() == 12, "reconnect_snapshot_retains_completed_workforce_upgrade")
	check(client.get_player(0).get_supply_limit() == 100 and client.get_player(0).mining_level == 3,
		"reconnect_snapshot_retains_both_expansion_and_mining_research")
	check(displayed.size() == 1, "reconnect_discards_expired_sounds_instead_of_replaying_a_burst")
	current_scene = host
	for index in range(276):
		host.spawn_unit("swordsman", index % 2, Vector3(index % 20, 0, index / 20))
	host.visible_ids.assign([enemy.entity_id, hidden.entity_id, enemy_building.entity_id])
	var large := sender.build_snapshot(0)
	var snapshot_epoch := "1".repeat(32)
	bytes = NetworkProtocol.encode_snapshot(large, 0, 1, snapshot_epoch)
	check(not bytes.is_empty(), "280_units_fit_primitive_wire_budget")
	var began: int = Time.get_ticks_usec()
	for iteration in range(30):
		NetworkProtocol.encode_snapshot(sender.build_snapshot(0), 0, 1, snapshot_epoch)
	var encoding_usec: float = (Time.get_ticks_usec() - began) / 30.0
	began = Time.get_ticks_usec()
	for iteration in range(30):
		sender.build_snapshot(0)
	var build_usec: float = (Time.get_ticks_usec() - began) / 30.0
	began = Time.get_ticks_usec()
	for iteration in range(30):
		NetworkProtocol.encode_snapshot(large, 0, 1, snapshot_epoch)
	var encode_usec: float = (Time.get_ticks_usec() - began) / 30.0
	began = Time.get_ticks_usec()
	for iteration in range(30):
		NetworkProtocol._primitive(large, 0, [NetworkProtocol.MAX_VALUES] as Array[int])
	var primitive_usec: float = (Time.get_ticks_usec() - began) / 30.0
	began = Time.get_ticks_usec()
	for iteration in range(30):
		JSON.stringify(large, "", false)
	var json_usec: float = (Time.get_ticks_usec() - began) / 30.0
	print("NETWORK_GAME_METRICS " + JSON.stringify({"encoder": "authority_snapshot", "entities": large.entities.size(), "decoded_bytes": NetworkProtocol.decoded_size(bytes), "wire_bytes": bytes.size(), "build_encode_mean_usec": encoding_usec, "build_mean_usec": build_usec, "encode_mean_usec": encode_usec, "untrusted_primitive_mean_usec": primitive_usec, "json_mean_usec": json_usec}))
	var moving_units: Array = host.entities_by_id.values().filter(func(entity): return entity is BattleUnit)
	var dynamic_wire_before := 0
	var dynamic_wire_after := 0
	var dynamic_decoded_before := 0
	var dynamic_decoded_after := 0
	var max_position_error := 0.0
	var max_yaw_error := 0.0
	var untouched_fields := true
	var unchanged_schema := true
	var unchanged_source := true
	for sample in range(30):
		for index in range(moving_units.size()):
			var unit: BattleUnit = moving_units[index]
			unit.global_position = Vector3((index % 20) * 2.0 - 20.0 + sin(index * 0.731 + sample * 0.07) * 0.17,
				0.0, floorf(index / 20.0) * 2.0 - 14.0 + cos(index * 0.479 + sample * 0.06) * 0.21)
			unit.model_pivot.rotation.y = wrapf(index * 0.371 + sample * 0.07, -PI, PI)
			unit._moving = true
		var source_position: Vector3 = own.global_position
		var source_yaw: float = own.model_pivot.rotation.y
		var quantized := sender.build_snapshot(0)
		var unquantized := quantized.duplicate(true)
		for index in range(quantized.entities.size()):
			var state: Dictionary = quantized.entities[index]
			var original: Node3D = host.entities_by_id[int(state.id)]
			unquantized.entities[index].p = Replication.vector_data(original.global_position)
			unquantized.entities[index].yaw = original.model_pivot.rotation.y
			for axis in range(3):
				max_position_error = maxf(max_position_error, absf(float(state.p[axis]) - float(original.global_position[axis])))
			max_yaw_error = maxf(max_yaw_error, absf(angle_difference(float(state.yaw), float(original.model_pivot.rotation.y))))
			var original_fields: Dictionary = unquantized.entities[index].duplicate(true)
			var retained_fields := state.duplicate(true)
			for key: String in ["p", "yaw"]:
				original_fields.erase(key)
				retained_fields.erase(key)
			untouched_fields = untouched_fields and original_fields == retained_fields
		unchanged_schema = unchanged_schema and receiver._valid_snapshot(quantized)
		unchanged_source = unchanged_source and own.global_position == source_position and own.model_pivot.rotation.y == source_yaw
		var before := NetworkProtocol.encode_snapshot(unquantized, 0, 1, snapshot_epoch)
		var after := NetworkProtocol.encode_snapshot(quantized, 0, 1, snapshot_epoch)
		dynamic_wire_before += before.size()
		dynamic_wire_after += after.size()
		dynamic_decoded_before += NetworkProtocol.decoded_size(before)
		dynamic_decoded_after += NetworkProtocol.decoded_size(after)
	check(max_position_error <= 0.005000001, "presentation_position_quantization_within_half_centimeter_per_axis")
	check(max_yaw_error <= 0.000500001, "presentation_yaw_quantization_within_half_milliradian")
	check(untouched_fields, "quantization_preserves_health_orders_animation_and_other_snapshot_fields")
	check(unchanged_source, "quantization_never_changes_authority_transforms")
	check(unchanged_schema, "quantized_dynamic_snapshots_retain_existing_visibility_and_schema_contract")
	check(dynamic_wire_after < dynamic_wire_before, "dynamic_280_unit_quantization_reduces_compressed_payload")
	print("NETWORK_GAME_QUANTIZATION_METRICS " + JSON.stringify({"samples": 30, "units": moving_units.size(),
		"decoded_before_mean_bytes": dynamic_decoded_before / 30.0, "decoded_after_mean_bytes": dynamic_decoded_after / 30.0,
		"wire_before_mean_bytes": dynamic_wire_before / 30.0, "wire_after_mean_bytes": dynamic_wire_after / 30.0,
		"wire_reduction_percent": (1.0 - float(dynamic_wire_after) / float(dynamic_wire_before)) * 100.0,
		"max_position_error_m": max_position_error, "max_yaw_error_rad": max_yaw_error,
		"scope": "30 synthetic moving transforms on 280 authored units; actual protocol encoder, not socket throughput"}))
	var recording := RecordingRelay.new()
	host.add_child(recording)
	recording.connection_state = "match"
	sender.configure(host, recording)
	host.is_authority = true
	for index in range(300):
		sender.queue_host_visual(1, {"kind": "effect", "effect": "muzzle", "at": [0, 0, 0]})
	check(sender._outbound_visual[1].size() == Replication.MAX_VISUAL_EVENTS, "outbound_visual_backlog_is_bounded")
	for simulation_frame in [8, 10, 12]:
		host.simulation_tick = simulation_frame
		sender._next_publish_usec = 0
		sender.publish_latest()
		sender.publish_latest()
	check(recording.captured[1] == [8, 10, 12] and recording.captured[2] == [8, 10, 12] and recording.captured[3] == [8, 10, 12], "three_clients_share_latest_publication_without_duplicate_state")
	check(not recording.captured.has(0), "host_does_not_replicate_to_itself")
	check(recording.visual_packets.size() == 3 and recording.visual_packets[0].event.events.size() == 96 and recording.visual_packets[2].event.events.size() == 64, "300_battle_effects_use_three_bounded_reliable_batches")
	check(recording.visual_packets.all(func(packet): return NetworkProtocol.decoded_size(NetworkProtocol.encode({"op": "event", "payload": packet.event})) < NetworkProtocol.MAX_EVENT_BYTES), "visual_batches_respect_transport_size_limit")
	recording.visual_packets.clear()
	for index in range(300):
		sender.queue_host_visual(1, {"kind": "sound", "sound": "footstep_dirt", "at": [0, 0, 0]})
	check(sender._outbound_visual[1].size() == 1, "same_cell_same_period_steps_coalesce")
	host.simulation_tick = 14
	sender.flush_visual()
	check(recording.visual_packets.size() == 1 and recording.visual_packets[0].event.events.size() == 1, "coalesced_steps_keep_one_spatial_sound")
	for index in range(80):
		sender.queue_host_visual(1, {"kind": "sound", "sound": "footstep_dirt", "at": [1000 + index * 4, 0, 0]})
	sender.queue_host_visual(1, {"kind": "projectile", "projectile": "arrow", "at": [0, 0, 0]})
	sender.queue_host_visual(1, {"kind": "effect", "effect": "explosion", "at": [0, 0, 0]})
	sender.flush_visual()
	check(recording.visual_packets.size() == 1, "explicit_flush_cannot_send_twice_same_tick")
	host.simulation_tick = 16
	sender.flush_visual()
	var motion_batch: Array = recording.visual_packets.back().event.events
	check(motion_batch.size() == 18 and motion_batch[0].kind == "projectile" and motion_batch[1].effect == "explosion", "battle_visuals_precede_at_most_sixteen_motion_sounds")
	check(sender._outbound_visual[1].is_empty(), "excess_decorative_steps_do_not_accumulate_reliable_backlog")
	sender.queue_host_visual(1, {"kind": "sound", "sound": "horse_hoof", "at": [0, 0, 0]})
	sender.queue_host_visual(1, {"kind": "effect", "effect": "explosion", "at": [0, 0, 0]})
	host.elapsed += 0.3
	host.simulation_tick = 18
	sender.flush_visual()
	check(recording.visual_packets.back().event.events.size() == 1 and recording.visual_packets.back().event.events[0].effect == "explosion", "stale_footsteps_expire_without_dropping_current_battle_visual")
	check(not sender._cosmetic_times.has(1), "expired_cosmetic_dedup_cache_is_removed")
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
