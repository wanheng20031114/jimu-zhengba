extends SceneTree
## Actual academy queues, owner state, training reservations and worker payouts.

var game: Node3D
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	Engine.max_fps = 60
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func _building(kind: String, owner: int = 0) -> BattleBuilding:
	var near: Vector3 = game.owned_entities(owner, "buildings")[0].position
	var at: Vector3 = game.find_build_location(owner, kind, near)
	check(at.is_finite(), "legal " + kind + " footprint for owner " + str(owner))
	var building: BattleBuilding = game.spawn_building(kind, owner, at)
	building.set_physics_process(false)
	building.production.set_physics_process(false)
	return building

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
	var player: PlayerState = game.get_player(0)
	var ally: PlayerState = game.get_player(1)
	player.gold = 10000
	var barracks := _building("barracks")
	var factory := _building("factory")
	var academy := _building("academy")
	var other := _building("academy")
	var research: BuildingProduction = academy.production
	var parallel: BuildingProduction = other.production
	var unit_queue: BuildingProduction = barracks.production
	check(player.get_supply_limit() == 50 and player.get_mining_rate_multiplier() == 1.0, "baseline is fifty military population and unmodified mining")
	check(BalanceCatalog.UPGRADE_TRACKS[&"army_capacity"] == 2 and BalanceCatalog.UPGRADE_TRACKS[&"mining"] == 3, "independent two-level and three-level technology tracks")
	for level in range(1, 3):
		var expansion := BalanceCatalog.upgrade("army_capacity_%d" % level)
		check(expansion.cost == 500 and expansion.research_seconds == 30.0 and expansion.total_bonus == level * 25, "army capacity resource defines paid cumulative level " + str(level))
	for level in range(1, 4):
		var mining := BalanceCatalog.upgrade("mining_%d" % level)
		check(mining.cost == [50, 150, 300][level - 1] and mining.research_seconds == [15.0, 25.0, 35.0][level - 1] and mining.total_bonus == level * 10, "mining resource defines paid cumulative percentage " + str(level))
	player.military_supply = 50
	var gold_before := player.gold
	check(not unit_queue.recruit("swordsman").ok and player.gold == gold_before, "default cap blocks production without charging")
	check(not research.research("army_capacity_2").ok and not research.research("mining_2").ok, "new tracks cannot skip prerequisites")
	check(research.research("army_capacity_1").ok and parallel.research("army_capacity_2").ok, "second expansion can wait in another academy")
	check(not parallel.research("army_capacity_1").ok and player.planned_upgrade_level(&"army_capacity") == 2, "cross-academy expansion reservation is exclusive")
	parallel._physics_process(30.0)
	check(player.get_supply_limit() == 50 and parallel.research_elapsed == 0.0, "future expansion neither progresses nor grants population before prerequisite")
	gold_before = player.gold
	check(research.cancel_research().ok and player.gold == gold_before + 1000 and parallel.research_queue.is_empty(), "cancelling expansion I refunds both dependent levels exactly once")
	check(not research.cancel_research().ok and player.gold == gold_before + 1000, "duplicate expansion cancellation cannot refund again")
	check(research.research("army_capacity_1").ok and parallel.research("army_capacity_2").ok, "cancelled expansion chain can be queued again")
	research._physics_process(29.99)
	check(player.get_supply_limit() == 50 and not unit_queue.recruit("archer").ok, "expansion I waits the entire thirty seconds")
	research._physics_process(0.01)
	check(player.get_supply_limit() == 75 and ally.get_supply_limit() == 50, "expansion I grants twenty-five population to its owner only")
	check(unit_queue.recruit("knight").ok and player.reserved_military_supply == 1, "new population becomes available to one-supply knight training")
	unit_queue.cancel_training(0)
	player.military_supply = 74
	gold_before = player.gold
	check(not factory.production.recruit("cannon").ok and player.gold == gold_before, "three-supply cannon cannot oversubscribe the expanded cap or charge for rejection")
	check(unit_queue.recruit("knight").ok and player.used_military_supply() == 75 and player.reserved_military_supply == 1, "one-supply knight reserves the expanded cap's final slot")
	gold_before = player.gold
	check(not unit_queue.recruit("archer").ok and player.gold == gold_before and unit_queue.recruit_error("archer").contains("75"), "expanded cap rejection displays seventy-five and does not charge")
	unit_queue.cancel_training(0)
	parallel._physics_process(30.0)
	check(player.get_supply_limit() == 100 and player.army_capacity_level == 2, "expansion II reaches one hundred instead of adding previous totals again")
	gold_before = player.gold
	check(not research.research("army_capacity_2").ok and player.gold == gold_before, "completed expansion cannot be purchased twice")
	player.military_supply = 99
	gold_before = player.gold
	check(not factory.production.recruit("cannon").ok and player.gold == gold_before, "three-supply cannon is still weighted at the full expansion limit")
	check(unit_queue.recruit("knight").ok and player.used_military_supply() == 100, "one-supply knight reserves the fully expanded final slot")
	check(not unit_queue.recruit("knight").ok, "one hundred is the final military ceiling")
	unit_queue.cancel_training(0)
	player.military_supply = 0
	var worker: BattleUnit = game.owned_entities(0, "units").filter(func(unit): return unit.unit_type == "farmer")[0]
	var mine: ResourceVein = game.nearest_mine(worker.position)
	worker.issue_gather(mine)
	worker.global_position = worker.destination
	worker._work_velocity(1.5)
	check(is_equal_approx(worker.work_progress, 0.5), "unupgraded worker reaches half progress after one and a half seconds")
	check(research.research("mining_1").ok and parallel.research("mining_2").ok and parallel.research("mining_3").ok, "all three mining levels support ordered cross-academy queues")
	check(not parallel.research("mining_1").ok and player.get_mining_rate_multiplier() == 1.0, "reserved mining is exclusive and gives no early efficiency")
	research._physics_process(15.0)
	check(is_equal_approx(player.get_mining_rate_multiplier(), 1.1) and is_equal_approx(worker.work_progress, 0.5) and is_equal_approx(worker._work_seconds, 1.5), "mid-cycle research preserves completed work and upgrades only subsequent work")
	gold_before = player.gold
	worker._work_velocity(1.5 / 1.1 - 1.0 / 30.0)
	check(player.gold == gold_before, "faster worker still requires all remaining work before payout")
	worker._work_velocity(1.0 / 30.0)
	check(player.gold == gold_before + 4, "first accelerated completion pays exactly four gold")
	parallel._physics_process(25.0)
	check(player.mining_level == 2 and is_equal_approx(player.get_mining_rate_multiplier(), 1.2), "mining II is total twenty percent instead of compounded twenty-one")
	gold_before = player.gold
	check(parallel.cancel_research().ok and player.gold == gold_before + 300 and player.mining_level == 2, "cancelling mining III refunds three hundred and preserves completed lower level")
	check(parallel.research("mining_3").ok, "cancelled final mining level may be researched again")
	parallel._physics_process(34.99)
	check(player.mining_level == 2, "mining III waits the full thirty-five seconds")
	parallel._physics_process(0.01)
	check(player.mining_level == 3 and is_equal_approx(player.get_mining_rate_multiplier(), 1.3), "mining III is total thirty percent")
	for level in range(4):
		player.mining_level = level
		worker.stop()
		worker.issue_gather(mine)
		worker.global_position = worker.destination
		gold_before = player.gold
		for tick in range(900):
			worker._work_velocity(1.0 / 30.0)
		check(player.gold - gold_before == 40 + level * 4, "thirty seconds of actual work pays exact noncompounded income at mining level " + str(level))
	player.mining_level = 3
	check(ally.mining_level == 0 and ally.get_mining_rate_multiplier() == 1.0, "allied miners do not inherit another owner's efficiency")
	var private_data := player.private_state()
	check(private_data.army_capacity_level == 2 and private_data.mining_level == 3, "new technology state is exported to the owning client")
	check(not player.public_state().has("army_capacity_level") and not player.public_state().has("mining_level"), "new technology levels are not public enemy information")
	academy.receive_damage(academy.max_hp)
	other.receive_damage(other.max_hp)
	check(player.get_supply_limit() == 100 and is_equal_approx(player.get_mining_rate_multiplier(), 1.3), "finished upgrades survive all academies being destroyed")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("ECONOMY_UPGRADES_RESULTS " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)
