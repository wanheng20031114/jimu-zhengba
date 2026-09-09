extends SceneTree
## Paid queue jobs keep their identity across cancellation, completion and network delay.

var checks: int = 0
var failures: Array[String] = []
var game: Node3D
var hq: BattleBuilding
var academy: BattleBuilding

func _initialize() -> void:
	Engine.max_fps = 60
	_run.call_deferred()

func _run() -> void:
	root.get_node("Session").start_offline("2v2")
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	game.tests_running = true
	game.set_physics_process(false)
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	hq = game.headquarters
	academy = game.spawn_building("academy", 0, Vector3(-12, 0, -24))
	academy.set_physics_process(false)
	academy.production.set_physics_process(false)
	var player: PlayerState = game.get_player(0)
	player.gold = 10000
	var production: BuildingProduction = hq.production
	var initial_gold := player.gold
	var jobs: Array[int] = []
	for index: int in range(4):
		check(production.recruit("farmer").ok, "paid_farmer_queued_%d" % index)
		jobs.append(int(production.training.back().job_id))
	check(jobs == [1, 2, 3, 4], "new_building_jobs_are_monotonic")
	production.training[0].elapsed = 4.0
	check(cancel_job(jobs[1]).ok, "middle_slot_cancelled")
	check(job_ids() == [jobs[0], jobs[2], jobs[3]], "middle_cancel_preserves_neighbor_identity_and_order")
	check(production.training[0].elapsed == 4.0, "middle_cancel_preserves_active_progress")
	check(player.gold == initial_gold - 150 and player.reserved_farmers == 3, "middle_cancel_refunds_one_and_releases_one_slot")
	unchanged({"kind": "cancel_training", "target": hq.entity_id, "job_id": jobs[1]}, 0, "duplicate_click_has_no_second_refund")
	check(cancel_job(jobs[0]).ok, "head_slot_cancelled")
	check(job_ids() == [jobs[2], jobs[3]] and production.training[0].elapsed == 0.0, "head_cancel_promotes_next_job_without_inherited_progress")
	check(cancel_job(jobs[3]).ok and job_ids() == [jobs[2]], "tail_slot_cancelled")
	check(production.recruit("farmer").ok, "replacement_job_queued")
	var replacement_id: int = production.training.back().job_id
	check(replacement_id > jobs.back(), "cancelled_ids_never_reused")
	var workers_before := player.farmers
	# Authored regions and the new academy publish their native navigation map
	# asynchronously. Completion needs a real clear exit, not an initial empty map.
	for attempt in range(90):
		if game.find_recruit_position("farmer", hq).is_finite():
			break
		await physics_frame
	check(game.find_recruit_position("farmer", hq).is_finite(), "native_exit_ready_before_completion")
	production._physics_process(10.1)
	check(player.farmers == workers_before + 1 and job_ids() == [replacement_id], "head_completes_and_next_job_shifts")
	unchanged({"kind": "cancel_training", "target": hq.entity_id, "job_id": jobs[2]}, 0, "late_completed_job_click_cannot_cancel_shifted_neighbor")
	unchanged({"kind": "cancel_training", "target": hq.entity_id, "job_id": replacement_id}, 1, "ally_cannot_cancel_own_job")
	unchanged({"kind": "cancel_training", "target": hq.entity_id, "job_id": replacement_id}, 2, "enemy_cannot_cancel_own_job")
	var malformed: Array = [{}, [], null, true, "1", 0, -1, 0.5, 2147483648, INF, NAN]
	for value: Variant in malformed:
		unchanged({"kind": "cancel_training", "target": hq.entity_id, "job_id": value}, 0, "malformed_job_id_" + str(value))
	var wire_command: Dictionary = JSON.parse_string(JSON.stringify({"kind": "cancel_training", "target": hq.entity_id, "job_id": replacement_id, "index": 999}))
	check(game.command_bus.execute(wire_command, 0).ok and production.training.is_empty(), "integral_wire_job_id_takes_precedence_over_moving_index")
	check(production.recruit("farmer").ok and int(production.training[0].job_id) > replacement_id, "empty_queue_does_not_reset_job_identity")
	check(game.command_bus.execute({"kind": "cancel_training", "target": hq.entity_id, "index": 0}, 0).ok, "existing_index_command_remains_supported")
	check(production.training.is_empty() and player.reserved_farmers == 0, "all_cancelled_jobs_release_reservations")
	check(player.gold == initial_gold - 50, "only_successfully_completed_farmer_remains_paid")

	var research: BuildingProduction = academy.production
	check(research.research("attack_1").ok, "attack_research_started")
	var before_cancel := player.gold
	check(cancel_research("attack_1").ok and player.gold == before_cancel + 100, "matching_research_cancel_refunds_full_cost")
	check(research.research("defense_1").ok, "replacement_research_started")
	unchanged({"kind": "cancel_research", "target": academy.entity_id, "upgrade": "attack_1"}, 0, "late_research_click_cannot_cancel_different_replacement")
	unchanged({"kind": "cancel_research", "target": academy.entity_id, "upgrade": "defense_1"}, 1, "ally_cannot_cancel_research")
	for value: Variant in [{}, [], null, true, 1, ""]:
		unchanged({"kind": "cancel_research", "target": academy.entity_id, "upgrade": value}, 0, "malformed_research_identity_" + str(value))
	check(cancel_research("defense_1").ok, "defense_research_cancelled")
	check(research.research("attack_1").ok, "attack_research_restarted")
	research._physics_process(20.0)
	check(player.attack_level == 1 and research.research_id.is_empty(), "attack_research_completed")
	check(research.research("attack_2").ok, "next_level_research_started")
	unchanged({"kind": "cancel_research", "target": academy.entity_id, "upgrade": "attack_1"}, 0, "completed_research_click_cannot_cancel_next_level")
	before_cancel = player.gold
	check(cancel_research("attack_2").ok and player.gold == before_cancel + 250, "current_next_level_refunds_correct_cost")
	unchanged({"kind": "cancel_research", "target": academy.entity_id, "upgrade": "attack_2"}, 0, "duplicate_research_cancel_does_not_refund_twice")
	check(research.research("defense_1").ok, "legacy_cancel_setup")
	check(game.command_bus.execute({"kind": "cancel_research", "target": academy.entity_id}, 0).ok, "existing_research_cancel_without_identity_remains_supported")

	check(production.recruit("farmer").ok and production.recruit("farmer").ok, "snapshot_has_two_real_paid_jobs")
	var replication: MatchReplication = game.get_node("MatchReplication")
	var snapshot := {"rally": [0, 0, 0], "rally_mine": 0, "production": production.snapshot()}
	check(replication._valid_production(snapshot), "new_job_identity_snapshot_valid")
	var decoded: Dictionary = JSON.parse_string(JSON.stringify(snapshot))
	check(replication._valid_production(decoded), "wire_float_job_ids_validate")
	check(decoded.production.training[0].job_id == production.training[0].job_id, "snapshot_transmits_paid_job_identity")
	var legacy := snapshot.duplicate(true)
	for item: Dictionary in legacy.production.training:
		item.erase("job_id")
	check(not replication._valid_production(legacy), "identityless_snapshot_rejected_by_current_protocol")
	var invalid := snapshot.duplicate(true)
	invalid.production.training[1].job_id = invalid.production.training[0].job_id
	check(not replication._valid_production(invalid), "duplicate_job_ids_rejected")
	for value: Variant in malformed:
		invalid = snapshot.duplicate(true)
		invalid.production.training[0].job_id = value
		check(not replication._valid_production(invalid), "malformed_snapshot_job_id_rejected_" + str(value))
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("PRODUCTION_QUEUE_IDENTITY_RESULTS " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)

func job_ids() -> Array[int]:
	var result: Array[int] = []
	for item: Dictionary in hq.production.training:
		result.append(int(item.job_id))
	return result

func cancel_job(job_id: int) -> Dictionary:
	return game.command_bus.execute({"kind": "cancel_training", "target": hq.entity_id, "job_id": job_id}, 0)

func cancel_research(upgrade: String) -> Dictionary:
	return game.command_bus.execute({"kind": "cancel_research", "target": academy.entity_id, "upgrade": upgrade}, 0)

func state() -> String:
	var players: Array = []
	for player: PlayerState in game.players:
		players.append(player.private_state())
	return JSON.stringify({"players": players, "training": hq.production.snapshot(), "research": academy.production.snapshot()})

func unchanged(command: Dictionary, owner: int, label: String) -> void:
	var before := state()
	check(not game.command_bus.execute(command, owner).ok, label + "_rejected")
	check(state() == before, label + "_state_unchanged")

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
