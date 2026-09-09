extends SceneTree
## Exercise real authored entities, authority validation, queue completion and selection.
var checks: int = 0
var failures: Array[String] = []
var game: Node3D
var soldier: BattleUnit
var enemy: BattleUnit
var worker: BattleUnit
var barracks: BattleBuilding
var second_barracks: BattleBuilding
var academy: BattleBuilding

func _initialize() -> void:
	Engine.max_fps = 60
	_run.call_deferred()

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
		push_error(label)

func command(value: Dictionary) -> Dictionary:
	return game.command_bus.execute(value, 0)

func unit(kind: String, owner: int, at: Vector3) -> BattleUnit:
	var result: BattleUnit = game.spawn_unit(kind, owner, at)
	result.set_physics_process(false)
	result.navigation_agent.avoidance_enabled = false
	return result

func building(kind: String, owner: int, at: Vector3, site: bool = false) -> BattleBuilding:
	var result: BattleBuilding = game.spawn_building(kind, owner, at, site)
	result.set_physics_process(false)
	result.production.set_physics_process(false)
	return result

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
	for entity: BattleUnit in get_nodes_in_group("units"):
		entity.stop()
		entity.set_physics_process(false)
		entity.navigation_agent.avoidance_enabled = false
	for entity: BattleBuilding in get_nodes_in_group("buildings"):
		entity.set_physics_process(false)
		entity.production.set_physics_process(false)
	game.get_player(0).gold = 20000
	soldier = unit("swordsman", 0, Vector3(-5, 0, 0))
	enemy = unit("knight", 2, Vector3(-5, 0, 1.5))
	worker = game.owned_entities(0, "units")[0]
	barracks = building("barracks", 0, Vector3(-14, 0, -14))
	second_barracks = building("barracks", 0, Vector3(-24, 0, -14))
	academy = building("academy", 0, Vector3(-14, 0, -24))
	game.get_node("FogOfWar")._recompute()
	await _orders()
	_groups_and_production()
	_destroy()
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("RTS_COMMAND_QUEUE_RESULTS " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)

func _orders() -> void:
	check(command({"kind": "move", "units": [soldier.entity_id], "at": [-4, 0, 0]}).ok, "normal_move_accepted")
	check(command({"kind": "attack", "units": [soldier.entity_id], "target": enemy.entity_id, "queued": true}).ok, "shift_attack_accepted")
	check(soldier.order == BattleUnit.Order.MOVE and soldier.waypoint_queue.size() == 1, "shift_attack_preserves_active_move")
	for index in range(20):
		command({"kind": "attack", "units": [soldier.entity_id], "target": enemy.entity_id, "queued": true})
	check(soldier.waypoint_queue.size() == 1, "repeated_tail_attack_deduplicated")
	command({"kind": "move", "units": [soldier.entity_id], "at": [0, 0, 0], "attack_move": true, "queued": true})
	soldier._complete_waypoint()
	check(soldier.order == BattleUnit.Order.ATTACK and soldier.target == enemy and soldier.waypoint_queue.size() == 1, "arrival_promotes_attack_without_erasing_later_orders")
	soldier._start_attack()
	var before_hp: float = enemy.hp
	var before_cooldown: float = soldier._attack_cooldown
	for index in range(14):
		command({"kind": "attack", "units": [soldier.entity_id], "target": enemy.entity_id})
		await physics_frame
	check(enemy.hp < before_hp, "rapid_focus_commands_preserve_real_timer_hit")
	check(soldier._attack_cooldown == before_cooldown, "rapid_focus_does_not_reset_cooldown")
	check(soldier.waypoint_queue.is_empty(), "unshifted_focus_replaces_future_queue")
	command({"kind": "move", "units": [soldier.entity_id], "at": [2, 0, 0], "attack_move": true, "queued": true})
	enemy.receive_damage(enemy.hp)
	soldier._physics_process(1.0 / 30.0)
	check(soldier.order == BattleUnit.Order.ATTACK_MOVE, "target_death_resumes_next_attack_move")
	var doomed := unit("archer", 2, Vector3(-4, 0, 1.5))
	game.get_node("FogOfWar")._recompute()
	soldier.issue_move(Vector3(-2, 0, 0))
	soldier.issue_attack(doomed, true)
	soldier.queue_move(Vector3(3, 0, 0))
	doomed.receive_damage(doomed.hp)
	soldier._complete_waypoint()
	check(soldier.order == BattleUnit.Order.MOVE and soldier.destination == Vector3(3, 0, 0), "dead_future_target_skipped_without_stalling")
	var hidden := unit("archer", 2, Vector3(-3, 0, 1.5))
	game.get_node("FogOfWar")._recompute()
	soldier.issue_attack(hidden, true)
	soldier.queue_move(Vector3(4, 0, 0))
	hidden.global_position = Vector3(55, 0, -48)
	game.get_node("FogOfWar")._recompute()
	soldier._complete_waypoint()
	check(soldier.order == BattleUnit.Order.MOVE and soldier.destination == Vector3(4, 0, 0), "hidden_future_enemy_does_not_leak_or_block_queue")
	command({"kind": "hold", "units": [soldier.entity_id], "queued": true})
	check(soldier.order == BattleUnit.Order.MOVE and soldier.waypoint_queue.back().kind == "hold", "shift_hold_waits_for_move")
	soldier._complete_waypoint()
	check(soldier.order == BattleUnit.Order.HOLD and soldier.waypoint_queue.is_empty(), "queued_hold_enters_indefinite_stationary_stance")
	soldier.queue_move(Vector3.ZERO)
	check(soldier.order == BattleUnit.Order.MOVE, "shift_order_from_hold_starts_immediately")
	soldier.queue_move(Vector3(2, 0, 1))
	command({"kind": "stop", "units": [soldier.entity_id], "queued": true})
	check(soldier.order == BattleUnit.Order.IDLE and soldier.waypoint_queue.is_empty(), "stop_always_clears_queue_even_with_shift")
	var mine: ResourceVein = get_nodes_in_group("resource_veins")[0]
	var occupied: int = mine.occupied_slots()
	worker.issue_move(worker.global_position + Vector3.RIGHT)
	worker.issue_gather(mine, true)
	check(mine.occupied_slots() == occupied and not worker._claimed_mine, "future_gather_does_not_reserve_mine")
	worker._complete_waypoint()
	check(worker.order == BattleUnit.Order.GATHER and mine.occupied_slots() == occupied + 1, "active_gather_claims_slot")
	worker.global_position = worker.destination
	worker.queue_move(worker.destination + Vector3(3, 0, 0))
	var gold: int = game.get_player(0).gold
	worker._work_velocity(3.0)
	check(game.get_player(0).gold == gold + 3 and worker.order == BattleUnit.Order.MOVE, "mining_finishes_one_paid_cycle_then_queued_move")
	check(mine.occupied_slots() == occupied and not worker._claimed_mine, "queued_move_releases_mine_immediately")
	var site := building("defense_tower", 0, Vector3(-10, 0, 10), true)
	worker.issue_build(site, true)
	worker.queue_move(Vector3(-8, 0, 10))
	check(worker.order == BattleUnit.Order.MOVE, "future_build_does_not_interrupt_move")
	worker._complete_waypoint()
	check(worker.order == BattleUnit.Order.BUILD and worker.work_target == site, "move_promotes_build_job")
	command({"kind": "destroy", "targets": [site.entity_id]})
	worker._work_velocity(0.1)
	check(worker.order == BattleUnit.Order.MOVE and worker.destination == Vector3(-8, 0, 10), "cancelled_site_advances_worker_queue")
	worker.issue_gather(mine)
	command({"kind": "hold", "units": [worker.entity_id]})
	check(worker.order == BattleUnit.Order.HOLD and mine.occupied_slots() == occupied, "hold_cancels_work_and_releases_slot")
	soldier.issue_move(Vector3.ZERO)
	for index in range(BattleUnit.MAX_QUEUED_ORDERS):
		soldier.queue_move(Vector3(float(index % 20), 0, index / 20.0))
	check(soldier.waypoint_queue.size() == 64, "queue_accepts_bounded_sixty_four_orders")
	check(not command({"kind": "move", "units": [soldier.entity_id], "at": [1, 0, 1], "queued": true}).ok, "authority_rejects_queue_overflow")
	check(soldier.waypoint_queue.size() == 64, "overflow_does_not_replace_queue")
	soldier.stop()
	worker.stop()

func _groups_and_production() -> void:
	game.select_entities([barracks, second_barracks])
	game.use_control_group(3, true)
	check(game.control_groups[3].size() == 2, "ctrl_number_stores_buildings")
	game.select_entities([academy])
	game.use_control_group(3, false, true)
	game.use_control_group(3, false, true)
	check(game.control_groups[3].size() == 3, "shift_number_appends_building_without_duplicates")
	game.use_control_group(3)
	check(game.selection.size() == 3 and game.selection.has(academy), "number_recalls_building_group")
	check(game.selected_production() == barracks, "first_building_type_is_active")
	game.cycle_production_group()
	check(game.selected_production() == academy, "tab_selects_academy_subgroup")
	game.cycle_production_group()
	check(game.selected_production() == barracks, "tab_cycles_back_to_barracks")
	game.select_entities([soldier], true)
	check(game.selection.size() == 4 and game.own_selected_units().size() == 1, "shift_selection_can_mix_own_units_and_buildings")
	var allied: BattleBuilding = game.owned_entities(1, "buildings")[0]
	game.select_entities([allied], true)
	check(not game.selection.has(allied), "additive_selection_cannot_add_allied_assets")
	var gold: int = game.get_player(0).gold
	for index in range(4):
		check(game.recruit("swordsman"), "group_recruit_submitted_%d" % index)
	game.command_bus.tick()
	check(barracks.production.training.size() == 2 and second_barracks.production.training.size() == 2, "same_tick_group_purchases_spread_across_buildings")
	check(game.get_player(0).gold == gold - 4 * 45, "one_group_keypress_buys_one_unit")
	check(command({"kind": "rally", "buildings": [barracks.entity_id, second_barracks.entity_id], "at": [6, 0, 7]}).ok, "authority_accepts_group_rally")
	check(barracks.rally_point == Vector3(6, 0, 7) and second_barracks.rally_point == barracks.rally_point, "all_selected_buildings_receive_rally")
	var before_rally: Vector3 = barracks.rally_point
	check(not command({"kind": "rally", "buildings": [barracks.entity_id, allied.entity_id], "at": [7, 0, 8]}).ok, "mixed_owner_group_rally_rejected")
	check(barracks.rally_point == before_rally, "group_rally_validates_all_before_mutation")
	var before_training: int = barracks.production.training.size()
	gold = game.get_player(0).gold
	check(not command({"kind": "recruit", "buildings": [barracks.entity_id, allied.entity_id], "unit_type": "swordsman"}).ok, "mixed_owner_group_purchase_rejected")
	check(barracks.production.training.size() == before_training and game.get_player(0).gold == gold, "invalid_group_purchase_has_no_side_effect")
	for malformed: Variant in ["1", {}, true, -1, 0.5, 2147483648]:
		check(not command({"kind": "recruit", "buildings": [malformed], "unit_type": "swordsman"}).ok, "malformed_group_id_" + str(malformed))
	check(game.research_selected("attack_1"), "mixed_group_research_submits")
	game.command_bus.tick()
	check(academy.production.research_id == "attack_1", "research_routes_to_eligible_academy")
	check(command({"kind": "research", "buildings": [academy.entity_id], "upgrade": "attack_2"}).ok, "second_technology_can_queue")
	var tail_id: int = academy.production.research_queue.back().job_id
	check(command({"kind": "cancel_research", "target": academy.entity_id, "job_id": tail_id}).ok, "stable_identity_cancels_waiting_technology")
	check(academy.production.research_queue.size() == 1 and academy.production.research_id == "attack_1", "tail_cancel_preserves_active_research")
	check(not command({"kind": "cancel_research", "target": academy.entity_id, "job_id": tail_id}).ok, "duplicate_technology_cancel_cannot_refund_twice")
	check(command({"kind": "cancel_research", "target": academy.entity_id, "upgrade": "attack_1"}).ok, "legacy_upgrade_identity_cancels_matching_job")
	for malformed: Variant in ["1", {}, [], true, 0, 0.5, 2147483648]:
		check(not command({"kind": "cancel_research", "target": academy.entity_id, "job_id": malformed}).ok, "malformed_research_job_" + str(malformed))

func _destroy() -> void:
	var ally: BattleUnit = game.owned_entities(1, "units")[0]
	var gold: int = game.get_player(0).gold
	check(not command({"kind": "destroy", "targets": [soldier.entity_id, ally.entity_id]}).ok, "delete_mixed_ownership_is_atomic")
	check(soldier.alive and ally.alive, "rejected_delete_preserves_all_entities")
	var mine: ResourceVein = get_nodes_in_group("resource_veins")[0]
	check(not command({"kind": "destroy", "targets": [mine.entity_id]}).ok and mine.alive, "resources_cannot_be_deleted")
	for malformed: Variant in ["1", {}, [], true, 0, 0.5, 2147483648]:
		check(not command({"kind": "destroy", "targets": [malformed]}).ok, "malformed_delete_target_" + str(malformed))
	var military: int = game.get_player(0).military_supply
	game.select_entities([soldier, barracks])
	game.destroy_selected()
	game.command_bus.tick()
	check(not soldier.alive and not barracks.alive, "delete_selection_destroys_unit_and_finished_barracks")
	check(game.get_player(0).military_supply == military - 1, "delete_unit_releases_population")
	check(game.get_player(0).gold == gold, "completed_assets_and_destroyed_training_do_not_refund")
	check(game.selection.is_empty(), "destroyed_entities_leave_selection")
	game.use_control_group(3)
	check(not game.control_groups[3].has(barracks) and game.control_groups[3].has(second_barracks), "recall_prunes_destroyed_buildings")
	worker.issue_gather(mine)
	var slots: int = mine.occupied_slots()
	check(command({"kind": "destroy", "targets": [worker.entity_id, worker.entity_id]}).ok, "duplicate_delete_ids_processed_once")
	check(not worker.alive and mine.occupied_slots() == slots - 1, "worker_delete_releases_mine_slot")
	var site := building("defense_tower", 0, Vector3(-10, 0, 12), true)
	site.construction_progress = 0.4
	gold = game.get_player(0).gold
	check(command({"kind": "destroy", "targets": [site.entity_id]}).ok, "delete_cancels_construction_site")
	check(not site.alive and game.get_player(0).gold == gold + 60, "site_delete_keeps_existing_proportional_refund")
