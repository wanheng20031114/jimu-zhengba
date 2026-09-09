extends SceneTree
## Malformed requests cross the actual match command bus and authored production
## components. No transport is needed: JSON decoding is the input boundary here.

var checks: int = 0
var failures: Array[String] = []
var game: Node3D
var hq: BattleBuilding
var worker: BattleUnit
var ally: BattleUnit

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
	worker = game.owned_entities(0, "units")[0]
	ally = game.owned_entities(1, "units")[0]
	game.get_player(0).gold = 1000
	var recruit: Dictionary = JSON.parse_string(JSON.stringify({"kind": "recruit", "target": hq.entity_id, "unit_type": "farmer"}))
	check(recruit.target is float, "ordinary_json_integer_decodes_as_float")
	check(game.command_bus.execute(recruit, 0).ok, "integral_json_target_recruits")
	check(hq.production.training.size() == 1, "positive_control_has_real_refundable_training")
	check(game.command_bus.execute({"kind": "hold", "units": [float(worker.entity_id)]}, 0).ok, "integral_json_unit_id_accepted")
	var mine: ResourceVein = get_nodes_in_group("resource_veins")[0]
	check(game.command_bus.execute({"kind": "rally", "target": float(hq.entity_id), "mine": float(mine.entity_id), "at": [-10, 0, -10]}, 0).ok, "integral_json_mine_id_accepted")
	check(hq.production.rally_mine == mine, "positive_control_sets_actual_mine")
	var malformed: Array = [{}, [], "0", true, null, 0.5, -1, 2147483648, 1.0e30, INF, NAN]
	for value: Variant in malformed:
		bad({"kind": "cancel_training", "target": hq.entity_id, "index": value}, 0, "training_index_" + str(typeof(value)) + "_" + str(value))
		bad({"kind": "rally", "target": hq.entity_id, "mine": value, "at": [10, 0, 10]}, 0, "rally_mine_" + str(typeof(value)) + "_" + str(value))
		bad({"kind": "recruit", "target": value, "unit_type": "farmer"}, 0, "target_" + str(typeof(value)) + "_" + str(value))
		bad({"kind": "stop", "units": [value]}, 0, "unit_" + str(typeof(value)) + "_" + str(value))
		var before_pending: int = game.command_bus.pending.size()
		check(not game.command_bus.submit({"kind": "stop", "seq": value}, 0).ok and game.command_bus.pending.size() == before_pending, "invalid_sequence_rejected_without_queue_" + str(value))
	bad({"kind": "cancel_training", "target": hq.entity_id, "index": 1}, 0, "valid_integer_outside_training_queue")
	bad({"kind": "recruit", "target": float(hq.entity_id) + 0.5, "unit_type": "farmer"}, 0, "fractional_target_cannot_truncate_to_owned_hq")
	bad({"kind": "stop", "units": [float(worker.entity_id) + 0.5]}, 0, "fractional_unit_cannot_truncate_to_owned_worker")
	bad({"kind": "rally", "target": hq.entity_id, "mine": float(mine.entity_id) + 0.5, "at": [10, 0, 10]}, 0, "fractional_mine_cannot_truncate_or_mutate_rally")
	bad({"kind": "rally", "target": hq.entity_id, "mine": worker.entity_id, "at": [10, 0, 10]}, 0, "non_mine_entity_cannot_mutate_rally")
	bad({"kind": "rally", "target": hq.entity_id, "mine": 2147483647, "at": [10, 0, 10]}, 0, "unknown_mine_cannot_mutate_rally")
	bad({"kind": "stop", "units": [worker.entity_id, ally.entity_id]}, 0, "mixed_owner_unit_list_is_atomic")
	bad({"kind": "rally", "target": hq.entity_id, "at": [1.0e300, 0, 0]}, 0, "finite_double_overflow_cannot_create_infinite_world_position")
	for owner in [-1, 1, 2, 4, 2147483647]:
		bad(recruit, owner, "foreign_or_invalid_owner_recruit_" + str(owner))
		bad({"kind": "cancel_training", "target": hq.entity_id, "index": 0}, owner, "foreign_or_invalid_owner_refund_" + str(owner))
		bad({"kind": "rally", "target": hq.entity_id, "mine": 0, "at": [10, 0, 10]}, owner, "foreign_or_invalid_owner_rally_" + str(owner))
	for invalid_kind: Variant in [null, [], {}, true, 1, "cheat_gold"]:
		bad({"kind": invalid_kind}, 0, "invalid_direct_kind_" + str(invalid_kind))
	bad({}, 0, "missing_direct_kind")
	check(game.command_bus.execute({"kind": "cancel_training", "target": float(hq.entity_id), "index": 0.0}, 0).ok, "integral_json_training_index_refunds")
	check(hq.production.training.is_empty() and game.get_player(0).gold == 1000, "exact_single_refund_restores_gold")
	check(game.command_bus.submit({"kind": "stop", "seq": 1.0}, 0).ok, "integral_json_sequence_accepted")
	check(not game.command_bus.submit({"kind": "stop", "seq": 1.0}, 0).ok and game.command_bus.pending.size() == 1, "duplicate_sequence_does_not_append")
	game.command_bus.pending.clear()
	await _expanded_economy_commands()
	game.finished = true
	bad(recruit, 0, "finished_direct_execute_cannot_purchase")
	check(not game.command_bus.submit({"kind": "stop", "seq": 2}, 0).ok, "finished_submit_cannot_enqueue")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("NETWORK_COMMAND_VALIDATION_RESULTS " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)

func _expanded_economy_commands() -> void:
	var player: PlayerState = game.get_player(0)
	var academy: BattleBuilding = game.spawn_building("academy", 0, Vector3(0, 0, 20))
	var ally_academy: BattleBuilding = game.spawn_building("academy", 1, Vector3(10, 0, 20))
	academy.set_physics_process(false)
	academy.production.set_physics_process(false)
	ally_academy.set_physics_process(false)
	ally_academy.production.set_physics_process(false)
	for upgrade_id: String in ["army_capacity_1", "mining_1"]:
		bad({"kind": "research", "target": ally_academy.entity_id, "upgrade": upgrade_id,
			"owner": 1, "cost": 0}, 0, "ally_" + upgrade_id + "_cannot_be_purchased_by_foreign_owner")
	bad({"kind": "research", "target": academy.entity_id, "upgrade": "army_capacity_2"}, 0,
		"capacity_second_level_cannot_skip_prerequisite")
	bad({"kind": "research", "target": academy.entity_id, "upgrade": "mining_3"}, 0,
		"mining_third_level_cannot_skip_prerequisites")
	var before: int = player.gold
	var command := {"kind": "research", "target": academy.entity_id, "upgrade": "army_capacity_1",
		"seq": 2, "army_capacity_level": 2, "mining_level": 3, "supply_limit": 100000, "cost": 0}
	check(game.command_bus.submit(command, 0).ok and not game.command_bus.submit(command, 0).ok,
		"repeated_capacity_command_sequence_only_queues_one_purchase")
	game.command_bus.tick()
	check(player.gold == before - 500 and academy.production.research_queue.size() == 1
		and academy.production.research_queue[0].cost == 500, "forged_research_price_still_charges_authoritative_500_gold")
	check(player.get_supply_limit() == 50 and player.mining_level == 0,
		"command_payload_cannot_grant_capacity_or_mining_completion")
	check(academy.production.cancel_research().ok and player.gold == before,
		"capacity_cancellation_refunds_one_real_payment")
	check(game.command_bus.execute({"kind": "research", "target": academy.entity_id, "upgrade": "mining_1",
		"cost": 0, "mining_level": 3, "mining_rate": 1000.0}, 0).ok, "mining_purchase_uses_shared_command_authority")
	check(player.gold == before - 50 and player.mining_level == 0 and is_equal_approx(player.get_mining_rate_multiplier(), 1.0),
		"mining_purchase_charges_50_without_accepting_forged_efficiency")
	academy.production.cancel_research()
	player.complete_upgrade(BalanceCatalog.upgrade("workforce_1"))
	player.complete_upgrade(BalanceCatalog.upgrade("army_capacity_2"))
	var owned_ids: Array = game.owned_entities(0, "units").map(func(unit): return unit.entity_id)
	for index in range(112 - owned_ids.size()):
		var unit: BattleUnit = game.spawn_unit("farmer" if index < 9 else "swordsman", 0,
			game.clamp_to_map(Vector3(index % 15, 0, index / 15)))
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
		owned_ids.append(unit.entity_id)
	var full_army := {"kind": "hold", "units": owned_ids}
	var encoded := NetworkProtocol.encode({"op": "command", "payload": full_army})
	check(NetworkProtocol.decoded_size(encoded) < NetworkProtocol.MAX_COMMAND_BYTES, "112_unit_group_command_fits_existing_four_kib_limit")
	check(game.command_bus.execute(full_army, 0).ok, "expanded_100_military_and_twelve_workers_can_receive_one_group_order")
	check(owned_ids.all(func(id): return game.entities_by_id[id].order == BattleUnit.Order.HOLD),
		"expanded_group_order_reaches_every_owned_entity")
	var over_limit: Array = owned_ids.duplicate()
	over_limit.append(worker.entity_id)
	bad({"kind": "stop", "units": over_limit}, 0, "113_unit_payload_exceeds_authoritative_expanded_limit")
	var foreign_group: Array = owned_ids.duplicate()
	foreign_group[0] = ally.entity_id
	bad({"kind": "stop", "units": foreign_group}, 0, "expanded_group_cannot_include_allied_assets")

func state() -> String:
	var players: Array = []
	for player: PlayerState in game.players:
		players.append(player.private_state())
	return JSON.stringify({"players": players, "training": hq.production.snapshot(),
		"rally": [hq.rally_point.x, hq.rally_point.y, hq.rally_point.z],
		"mine": hq.production.rally_mine.entity_id if is_instance_valid(hq.production.rally_mine) else 0,
		"worker_order": worker.order, "ally_order": ally.order})

func bad(command: Dictionary, owner: int, label: String) -> void:
	var before := state()
	var result: Dictionary = game.command_bus.execute(command, owner)
	check(not result.ok, label + "_rejected")
	check(state() == before, label + "_state_unchanged")

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
