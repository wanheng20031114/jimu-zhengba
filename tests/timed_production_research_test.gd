extends SceneTree
## Real production components, native blocked exits, cross-academy reservations.

const EXIT_BLOCKER = preload("res://tests/production_exit_blocker.tscn")
var game: Node3D
var player: PlayerState
var checks := 0
var failures: Array[String] = []
var barracks: BattleBuilding
var factory: BattleBuilding
var academy: BattleBuilding
var academy2: BattleBuilding

func _initialize() -> void:
	Engine.max_fps = 60
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func _freeze_units() -> void:
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false

func _building(kind: String) -> BattleBuilding:
	var at: Vector3 = game.find_build_location(0, kind, game.headquarters.position)
	check(at.is_finite(), kind + " native legal location")
	var building: BattleBuilding = game.spawn_building(kind, 0, at)
	building.set_physics_process(false)
	building.production.set_physics_process(false)
	return building

func _ready_exit(building: BattleBuilding, kind: String) -> void:
	for attempt in range(120):
		if game.find_recruit_position(kind, building).is_finite():
			return
		await physics_frame
	check(false, "native exit became available " + kind)

func _run() -> void:
	create_timer(45.0, true, false, true).timeout.connect(func(): quit(3))
	root.get_node("Session").start_offline("1v1")
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	game.tests_running = true
	game.bots.clear()
	game.set_physics_process(false)
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	_freeze_units()
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	player = game.get_player(0)
	player.gold = 100000
	barracks = _building("barracks")
	factory = _building("factory")
	academy = _building("academy")
	academy2 = _building("academy")
	var durations := {"swordsman": 6.0, "archer": 8.0, "knight": 10.0, "catapult": 20.0, "cannon": 20.0, "farmer": 10.0}
	for kind: String in durations:
		var producer: BattleBuilding = game.headquarters if kind == "farmer" else (factory if kind in ["catapult", "cannon"] else barracks)
		await _ready_exit(producer, kind)
		var production: BuildingProduction = producer.production
		var definition := BalanceCatalog.unit(kind)
		var living_before: int = game.owned_entities(0, "units").size()
		var gold_before := player.gold
		check(definition.training_seconds == durations[kind], kind + " approved training duration")
		check(production.recruit(kind).ok and player.gold == gold_before - definition.cost, kind + " paid queue admission")
		check(game.owned_entities(0, "units").size() == living_before, kind + " no instantaneous spawning")
		var reserved: int = player.reserved_farmers if kind == "farmer" else player.reserved_military_supply
		check(reserved == (1 if kind == "farmer" else definition.supply), kind + " correct population reserved")
		production._physics_process(durations[kind] - 0.1)
		check(game.owned_entities(0, "units").size() == living_before, kind + " waits full duration")
		var blocker: StaticBody3D = EXIT_BLOCKER.instantiate()
		blocker.position = producer.position
		game.add_child(blocker)
		await physics_frame
		await physics_frame
		check(not game.find_recruit_position(kind, producer).is_finite(), kind + " native physics blocks every exit")
		production._physics_process(0.2)
		production._physics_process(0.3)
		check(production.training.size() == 1 and production.training[0].elapsed == durations[kind], kind + " completed blocked job remains queued")
		check((player.reserved_farmers if kind == "farmer" else player.reserved_military_supply) == reserved, kind + " blocked job keeps reservation")
		check(player.gold == gold_before - definition.cost, kind + " blocked retries never charge twice")
		blocker.queue_free()
		await process_frame
		await physics_frame
		await _ready_exit(producer, kind)
		production._physics_process(0.3)
		check(production.training.is_empty() and game.owned_entities(0, "units").size() == living_before + 1, kind + " clear exit spawns exactly once")
		check(player.reserved_farmers == 0 and player.reserved_military_supply == 0, kind + " spawn transfers reservation to living population")
		_freeze_units()

	for index in range(10):
		check(barracks.production.recruit("swordsman").ok, "ten slot training capacity " + str(index))
	var gold_before := player.gold
	check(not barracks.production.recruit("archer").ok and player.gold == gold_before, "eleventh training job rejected without payment")
	var middle_id: int = barracks.production.training[4].job_id
	barracks.production.training[0].elapsed = 2.0
	check(barracks.production.cancel_training_job(middle_id).ok and player.reserved_military_supply == 9, "middle military job refunds and releases only its supply")
	check(player.gold == gold_before + 45 and barracks.production.training[0].elapsed == 2.0, "cancelling waiting job preserves active progress")
	check(not barracks.production.cancel_training_job(middle_id).ok and player.gold == gold_before + 45, "repeated cancellation never double refunds")
	gold_before = player.gold
	barracks.production.destroyed()
	check(player.reserved_military_supply == 0 and barracks.production.training.is_empty() and player.gold == gold_before, "destroyed training loses paid jobs and releases supply")
	var living_supply := player.military_supply
	player.military_supply = 49
	gold_before = player.gold
	check(not factory.production.recruit("cannon").ok and player.gold == gold_before, "three supply cannon rejected without payment with one free slot")
	check(barracks.production.recruit("knight").ok and player.used_military_supply() == 50 and player.reserved_military_supply == 1, "one supply knight can reserve the final slot")
	check(not factory.production.recruit("cannon").ok and not barracks.production.recruit("archer").ok, "other buildings cannot oversubscribe reserved population")
	barracks.production.cancel_training(0)
	player.military_supply = living_supply

	var research: BuildingProduction = academy.production
	var other: BuildingProduction = academy2.production
	check(not research.research("attack_2").ok, "unplanned prerequisite cannot be skipped")
	for id: String in ["attack_1", "defense_1", "attack_2", "defense_2", "attack_3", "defense_3"]:
		check(research.research(id).ok, "interleaved research queue " + id)
	check(research.research_queue.size() == 6 and player.queued_research.size() == 6, "all six technologies reserved")
	check(not other.research("attack_1").ok and not other.research("defense_3").ok, "cross academy duplicate projects refused")
	research._physics_process(3.0)
	gold_before = player.gold
	check(research.cancel_research_by_id("attack_2").ok, "waiting technology individually cancellable")
	check(player.gold == gold_before + 750, "cancelling attack II also refunds dependent attack III")
	check(research.research_elapsed == 3.0 and research.research_queue.size() == 4 and player.planned_upgrade_level(&"defense") == 3, "unrelated track and current progress preserved")
	check(not research.cancel_research_by_id("attack_3").ok, "dependent project cannot refund twice")
	while not research.research_queue.is_empty():
		research.cancel_research()
	check(player.queued_research.is_empty() and player.active_research.is_empty(), "all technology reservations released")

	check(research.research("attack_1").ok and other.research("attack_2").ok and other.research("attack_3").ok, "future same track can be queued in another academy")
	other._physics_process(35.0)
	check(other.research_elapsed == 0.0 and player.attack_level == 0 and other.research_waiting_for_prerequisite(), "other academy waits for actual prerequisite completion")
	research._physics_process(20.0)
	check(player.attack_level == 1 and not other.research_waiting_for_prerequisite(), "completed prerequisite releases dependent academy")
	other._physics_process(35.0)
	check(player.attack_level == 2 and other.research_id == "attack_3" and other.research_elapsed == 0.0, "completion promotes next queued level without inherited elapsed time")
	other._physics_process(50.0)
	check(player.attack_level == 3 and player.get_attack_bonus() == 4 and player.queued_research.is_empty(), "queued technologies apply total plus four")
	check(research.research("defense_1").ok and other.research("defense_2").ok and other.research("defense_3").ok, "academy destruction dependency setup")
	gold_before = player.gold
	research.destroyed()
	check(player.gold == gold_before + 900, "destroyed own project loses cost while other academy dependencies refund")
	check(other.research_queue.is_empty() and player.active_research.is_empty(), "destroyed prerequisite cannot leave immortal waiting research")
	check(player.attack_level == 3 and player.defense_level == 0, "destruction preserves completed technologies")
	check(other.research("defense_1").ok, "destroyed project can be ordered again")
	var id_before: int = other.research_queue[0].job_id
	other.cancel_research_job(id_before)
	other.research("defense_1")
	check(other.research_queue[0].job_id > id_before and not other.cancel_research_job(id_before).ok, "late click cannot cancel restarted same-name research")
	var replication: MatchReplication = game.get_node("MatchReplication")
	var snapshot := {"rally": [0, 0, 0], "rally_mine": 0, "production": other.snapshot()}
	check(replication._valid_production(JSON.parse_string(JSON.stringify(snapshot))), "research queue passes exact wire validation")
	var malformed := snapshot.duplicate(true)
	malformed.production.research_queue[0].job_id = {}
	check(not replication._valid_production(malformed), "malformed research identity rejected before conversion")
	malformed = snapshot.duplicate(true)
	malformed.production.research_queue.append(malformed.production.research_queue[0].duplicate())
	check(not replication._valid_production(malformed), "duplicate research identities rejected")
	malformed = snapshot.duplicate(true)
	malformed.production.research_id = "attack_1"
	check(not replication._valid_production(malformed), "inconsistent queue head rejected")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("TIMED_PRODUCTION_RESEARCH_RESULTS " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)
