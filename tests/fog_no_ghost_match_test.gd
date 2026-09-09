extends SceneTree
## Real main scene, authored models and encoded authority snapshots; no live room.

var game: Node3D
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	Engine.max_fps = 60
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func _freeze_scene() -> void:
	game = current_scene
	game.tests_running = true
	game.set_physics_process(false)
	game.bots.clear()
	game.camera_rig.edge_scroll = false
	game.get_node("IncomeTimer").stop()
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	await physics_frame
	await physics_frame

func _snapshot(tick: int) -> Dictionary:
	game.simulation_tick = tick
	game.elapsed = tick / 30.0
	var fog: FogOfWar = game.get_node("FogOfWar")
	fog.tick(0.2)
	fog.apply_visibility(0)
	var packet: Dictionary = game.replication.build_snapshot(0)
	var encoded: PackedByteArray = NetworkProtocol.encode_snapshot(packet, 0, tick, "1".repeat(32))
	check(not encoded.is_empty(), "actual_match_snapshot_encodes_%d" % tick)
	return NetworkProtocol.decode(encoded).payload

func _ids(packet: Dictionary) -> Array:
	return packet.entities.map(func(state): return int(state.id))

func _case(mode: String) -> void:
	var session: Node = root.get_node("Session")
	session.start_offline(mode)
	await scene_changed
	await _freeze_scene()
	game.replication.configure(game, session.relay)
	var fog: FogOfWar = game.get_node("FogOfWar")
	var opponent: int = 2 if mode == "2v2v2" else 1
	var target_position := Vector3(4, 0, 0)
	var scout: BattleUnit = game.spawn_unit("knight", 0, Vector3(-5, 0, 0))
	scout.set_physics_process(false)
	scout.navigation_agent.avoidance_enabled = false
	var enemy: BattleUnit = game.spawn_unit("archer", opponent, target_position)
	enemy.set_physics_process(false)
	enemy.navigation_agent.avoidance_enabled = false
	var building: BattleBuilding = game.spawn_building("factory", opponent, Vector3(3, 0, -5))
	building.set_physics_process(false)
	building.production.set_physics_process(false)
	var enemy_id: int = enemy.entity_id
	var building_id: int = building.entity_id
	var visible_packet: Dictionary = _snapshot(2)
	check(enemy.visible and building.visible and _ids(visible_packet).has(enemy_id), mode + "_scout_observes_live_enemy")
	scout.global_position = game.get_spawn_marker(0).global_position
	var hidden_packet: Dictionary = _snapshot(4)
	check(not enemy.visible and not building.visible, mode + "_departure_hides_models_without_silhouettes")
	check(not _ids(hidden_packet).has(enemy_id) and not _ids(hidden_packet).has(building_id) and not hidden_packet.fog.has("buildings"), mode + "_hidden_entity_identity_and_pose_absent_from_wire")
	check(not fog.has_node("Memory") and fog.get_child_count() == 1, mode + "_native_fog_has_only_terrain_overlay")
	enemy.receive_damage(enemy.hp)
	building.receive_damage(building.hp)
	check(not game.entities_by_id.has(enemy_id) and not game.entities_by_id.has(building_id), mode + "_actual_death_releases_authority_registry")
	scout.global_position = Vector3(-5, 0, 0)
	var empty_packet: Dictionary = _snapshot(6)
	check(fog.position_visible(0, target_position) and not _ids(empty_packet).has(enemy_id) and not _ids(empty_packet).has(building_id), mode + "_rescouting_destroyed_site_reports_empty_ground")
	var match_config: Dictionary = session.config.duplicate(true)
	game.replication.reset()
	await game.prepare_shutdown()

	# Load the actual multiplayer client scene, but feed local encoded packets.
	# RelayClient has no connection and cannot create or occupy a public room.
	session.relay.owner_id = 0
	session.relay.is_host = false
	session.start_online(match_config)
	await scene_changed
	await _freeze_scene()
	fog = game.get_node("FogOfWar")
	game.replication.receive_snapshot(visible_packet)
	check(game.entities_by_id.has(enemy_id) and game.entities_by_id.has(building_id), mode + "_native_client_reconstructs_observed_entities")
	var replica: BattleUnit = game.entities_by_id[enemy_id]
	var structure: BattleBuilding = game.entities_by_id[building_id]
	game.select_entities([replica])
	game._last_click_entity = replica
	game.replication.receive_snapshot(hidden_packet)
	check(not replica.visible and not structure.visible and replica.collision_layer == 0 and structure.collision_layer == 0, mode + "_visibility_loss_hides_and_unpicks_before_render")
	check(game.selection.is_empty() and game._last_click_entity == null, mode + "_visibility_loss_clears_real_selection_and_click_reference")
	check(not game.entities_by_id.has(enemy_id) and not game.entities_by_id.has(building_id), mode + "_client_has_no_hidden_live_entity")
	game.replication.render(0.0)
	check(not game.entities_by_id.has(enemy_id) and not game.entities_by_id.has(building_id), mode + "_buffered_pose_does_not_resurrect_ghost")
	game.replication.receive_snapshot(empty_packet)
	game.replication._playback_time = float(empty_packet.time)
	game.replication.render(0.0)
	check(fog.position_visible(0, target_position) and fog.get_child_count() == 1, mode + "_client_rescouts_empty_ground_without_memory_model")
	check(not game.entities_by_id.has(enemy_id) and not game.entities_by_id.has(building_id), mode + "_destroyed_entities_stay_absent_after_rescout")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	session.online = false
	session.config.clear()
	session.relay.owner_id = -1

func _run() -> void:
	for mode: String in ["1v1", "2v2v2", "ffa"]:
		await _case(mode)
	print("FOG_NO_GHOST_MATCH_RESULTS " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)
