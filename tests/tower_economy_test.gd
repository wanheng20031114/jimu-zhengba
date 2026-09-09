extends SceneTree
## Real authority placement, permanent price history, refunds and private replication.

const PRICES := [150, 185, 225, 255, 280, 270, 270, 270]
var checks: int = 0
var failures: Array[String] = []
var game: Node3D
var worker: BattleUnit
var sites: Array[BattleBuilding] = []

func _initialize() -> void:
	Engine.max_fps = 60
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func _build(at: Vector3, owner: int = 0, builder: BattleUnit = null, queued: bool = true) -> Dictionary:
	if builder == null:
		builder = worker
	return {"kind": "build", "building_type": "defense_tower", "units": [builder.entity_id],
		"at": [at.x, at.y, at.z], "queued": queued, "seq": game.command_bus.next_sequence(owner)}

func _run() -> void:
	create_timer(45.0, true, false, true).timeout.connect(func(): quit(3))
	root.get_node("Session").start_offline("2v2")
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	game.tests_running = true
	game.bots.clear()
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
	worker = game.owned_entities(0, "units")[0]
	var player: PlayerState = game.get_player(0)
	var ally: PlayerState = game.get_player(1)
	player.gold = 20000
	ally.gold = 20000
	for state: PlayerState in game.players:
		check(state.paid_tower_count == 0 and state.get_building_cost(&"defense_tower") == 150, "each player's free starting tower leaves first paid quote at 150")
		var starting: Array = game.owned_entities(state.owner_id, "buildings").filter(func(building): return building.building_type == "defense_tower")
		check(starting.size() == 1 and starting[0].actual_paid_gold == 0 and starting[0].construction_refund() == 0, "free starting tower has no paid amount to refund")
	check(BalanceCatalog.building(&"defense_tower").cost_progression == PackedInt32Array([150, 185, 225, 255, 280, 270]), "six exact resource prices preserve intentional sixth-tower decrease")
	for index in range(PRICES.size()):
		var quote: int = player.get_building_cost(&"defense_tower")
		check(quote == PRICES[index], "next authoritative quote " + str(index + 1))
		var at: Vector3 = game.find_build_location(0, "defense_tower", game.headquarters.global_position)
		check(at.is_finite(), "legal native site for paid tower " + str(index + 1))
		if not at.is_finite():
			break
		var gold_before: int = player.gold
		var command: Dictionary = _build(at)
		command["cost"] = 1
		check(game.command_bus.submit(command, 0).ok, "submit valid build with untrusted cheap quote")
		check(not game.command_bus.submit(command, 0).ok, "duplicate sequence rejected before placement")
		game.command_bus.tick()
		var tower: BattleBuilding
		for entity: BattleBuilding in game.owned_entities(0, "buildings"):
			if entity.under_construction and entity not in sites:
				tower = entity
		check(tower != null and player.gold == gold_before - quote and player.paid_tower_count == index + 1, "one successful command charges and increments exactly once")
		if tower == null:
			break
		tower.set_physics_process(false)
		tower.production.set_physics_process(false)
		sites.append(tower)
		check(tower.actual_paid_gold == quote and tower.construction_refund() == quote, "untouched site stores its exact paid amount")
		check(ally.paid_tower_count == 0 and ally.get_building_cost(&"defense_tower") == 150, "another player's quote remains independent")
		var overlap: Dictionary = game.command_bus.execute(_build(at), 0)
		check(not overlap.ok and player.gold == gold_before - quote and player.paid_tower_count == index + 1, "overlapping rejected site never charges or advances history")
	check(sites.size() == PRICES.size(), "all eight ladder placements succeeded")
	if sites.size() == PRICES.size():
		_refunds_and_rejections(player)
		await _second_owner(ally)
		_network_privacy(player)
		_ui_quote(player)
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("TOWER_ECONOMY_RESULTS " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)

func _refunds_and_rejections(player: PlayerState) -> void:
	check(worker.waypoint_queue.size() == 7, "Shift construction preserves seven subsequent paid jobs")
	for index in range(sites.size()):
		var tower: BattleBuilding = sites[index]
		tower.construction_progress = 0.4
		var expected: int = floori(PRICES[index] * 0.6 + 0.00001)
		check(tower.construction_refund() == expected, "partial refund uses original paid price " + str(index + 1))
	var before: int = player.gold
	var result: Dictionary = game.command_bus.execute({"kind": "cancel_site", "target": sites[1].entity_id}, 0)
	check(result.ok and player.gold == before + 111 and player.paid_tower_count == 8, "cancelling second tower refunds 111 without rewinding history")
	check(not game.command_bus.execute({"kind": "cancel_site", "target": sites[1].entity_id}, 0).ok and player.gold == before + 111, "duplicate cancellation never refunds twice")
	before = player.gold
	result = game.command_bus.execute({"kind": "destroy", "targets": [sites[4].entity_id]}, 0)
	check(result.ok and player.gold == before + 168 and player.paid_tower_count == 8, "Delete unfinished fifth tower refunds its paid 280 at remaining sixty percent")
	before = player.gold
	sites[2].receive_damage(sites[2].max_hp)
	check(not sites[2].alive and player.gold == before and player.paid_tower_count == 8, "enemy destruction gives no refund and never reduces placement count")
	sites[3].under_construction = false
	sites[3].construction_progress = 1.0
	result = game.command_bus.execute({"kind": "destroy", "targets": [sites[3].entity_id]}, 0)
	check(result.ok and player.gold == before and player.paid_tower_count == 8, "finished tower demolition gives no refund or count reduction")
	var at: Vector3 = game.headquarters.global_position + Vector3(0, 0, 20)
	player.gold = 269
	check(game.placement_error(at, 0, "defense_tower").contains("270"), "preview insufficient-gold message uses the next real quote")
	check(not game.command_bus.execute(_build(at), 0).ok and player.gold == 269 and player.paid_tower_count == 8, "insufficient gold rejects without mutation")
	player.gold = before
	var foreign_worker: BattleUnit = game.owned_entities(1, "units")[0]
	check(not game.command_bus.execute(_build(at, 0, foreign_worker), 0).ok and player.paid_tower_count == 8, "owner cannot build using teammate's worker")
	worker.stop()
	worker.issue_move(worker.position + Vector3(1, 0, 0))
	for index in range(BattleUnit.MAX_QUEUED_ORDERS):
		worker.queue_move(worker.position + Vector3(2 + index % 2, 0, 0))
	check(not game.command_bus.execute(_build(at), 0).ok and player.paid_tower_count == 8 and player.gold == before, "full worker queue rejects construction without consuming quote")
	worker.stop()
	player.paid_tower_count = 1000000
	check(player.get_building_cost(&"defense_tower") == 270 and player.get_building_cost(&"barracks") == 150, "late-game lookup remains bounded and other buildings keep fixed costs")
	player.paid_tower_count = 8

func _second_owner(ally: PlayerState) -> void:
	await physics_frame
	var builder: BattleUnit = game.owned_entities(1, "units")[0]
	var at: Vector3 = game.find_build_location(1, "defense_tower", game.owned_entities(1, "buildings")[0].global_position)
	check(at.is_finite(), "teammate has independent legal placement")
	var before: int = ally.gold
	var result: Dictionary = game.command_bus.execute(_build(at, 1, builder, false), 1)
	check(result.ok and ally.gold == before - 150 and ally.paid_tower_count == 1, "teammate's first paid tower still costs 150 after eight local towers")
	# Both orders are submitted with the same visible quote. The second must
	# recheck the authority's new price, not a stale UI/Shift budget.
	var first: Vector3 = Vector3.INF
	var second: Vector3 = Vector3.INF
	var home: Vector3 = game.owned_entities(1, "buildings")[0].global_position
	for x in range(-18, 19, 2):
		for z in range(-18, 19, 2):
			var candidate: Vector3 = game.snap_build_position(home + Vector3(x, 0, z))
			if first.is_finite() and absf(first.x - candidate.x) < 4.0 and absf(first.z - candidate.z) < 4.0:
				continue
			if not game.placement_error(candidate, 1, "defense_tower").is_empty():
				continue
			if not first.is_finite():
				first = candidate
			else:
				second = candidate
				break
		if second.is_finite():
			break
	check(first.is_finite() and second.is_finite(), "two distinct simultaneously legal Shift placements")
	if first.is_finite() and second.is_finite():
		ally.gold = 409
		check(game.command_bus.submit(_build(first, 1, builder), 1).ok and game.command_bus.submit(_build(second, 1, builder), 1).ok, "both distinct orders enter the same authority tick")
		game.command_bus.tick()
		check(ally.paid_tower_count == 2 and ally.gold == 224 and ally.get_building_cost(&"defense_tower") == 225, "same-tick second Shift build rejects new 225 quote when only 224 remain")

func _network_privacy(player: PlayerState) -> void:
	var replication: Node = game.replication
	replication.configure(game, root.get_node("Session").relay)
	var packet: Dictionary = replication.build_snapshot(0)
	check(replication._valid_snapshot(packet), "actual authoritative snapshot includes valid price schema")
	check(packet.players[0].private.paid_tower_count == 8, "own cumulative count sent privately")
	for index in range(1, game.players.size()):
		check(not packet.players[index].has("private") and not packet.players[index].has("paid_tower_count"), "no allied or enemy tower purchase history is disclosed")
	var own_state: Dictionary = {}
	var allied_state: Dictionary = {}
	for entity: Dictionary in packet.entities:
		if entity.id == sites[0].entity_id:
			own_state = entity
		if int(entity.owner) != 0:
			check(not entity.has("actual_paid_gold"), "visible non-owned entity does not reveal actual paid amount")
			if entity.category == "building":
				allied_state = entity
	check(own_state.actual_paid_gold == 150, "owned unfinished tower's original paid amount transmitted")
	var wire: Dictionary = NetworkProtocol.decode(NetworkProtocol.encode({"op": "snapshot", "payload": packet})).payload
	check(replication._valid_snapshot(wire), "price data survives real JSON network encoding")
	player.paid_tower_count = 0
	replication._apply_players(wire.players)
	check(player.paid_tower_count == 8 and player.get_building_cost(&"defense_tower") == 270, "reconnect restores authoritative current quote")
	sites[0].actual_paid_gold = 1
	replication._apply_entity(sites[0], own_state)
	check(sites[0].actual_paid_gold == 150 and sites[0].construction_refund() == 90, "replica restores original paid amount for cancellation UI")
	for bad: Variant in [-1, 1.5, "8", 2147483648]:
		var invalid: Dictionary = wire.duplicate(true)
		invalid.players[0].private.paid_tower_count = bad
		check(not replication._valid_snapshot(invalid), "invalid private placement count rejected atomically: " + str(bad))
	var missing: Dictionary = wire.duplicate(true)
	missing.players[0].private.erase("paid_tower_count")
	check(not replication._valid_snapshot(missing), "missing price history rejected instead of assuming first-price")
	for bad: Variant in [-1, 1.5, "150", 1000001]:
		var invalid: Dictionary = wire.duplicate(true)
		for entity: Dictionary in invalid.entities:
			if entity.id == sites[0].entity_id:
				entity.actual_paid_gold = bad
		check(not replication._valid_snapshot(invalid), "invalid paid amount rejected: " + str(bad))
	var leaked: Dictionary = wire.duplicate(true)
	for entity: Dictionary in leaked.entities:
		if entity.id == allied_state.id:
			entity.actual_paid_gold = 185
	check(not replication._valid_snapshot(leaked), "non-owned building's injected private price rejected")

func _ui_quote(player: PlayerState) -> void:
	game.select_entities([worker])
	game.hud.refresh()
	var tower_actions: Array = game.hud._actions.filter(func(action): return action.kind == "build" and action.id == "defense_tower")
	check(tower_actions.size() == 1 and tower_actions[0].cost == player.get_building_cost(&"defense_tower") and tower_actions[0].hint.contains("9"), "worker button shows next price and paid ordinal")
	game.set_build_mode(true, "defense_tower")
	check(game.hud.get_node("%RecruitHint").text.contains("270"), "live build preview label follows authoritative next quote")
	game.set_build_mode(false)
	game.select_entities([sites[0]])
	game.hud.refresh()
	check(game.hud.selected_stats.text.contains("150") and game.hud.selected_stats.text.contains("90"), "owned construction UI displays real payment and current refund")
