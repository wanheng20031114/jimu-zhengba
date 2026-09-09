extends Node
## Explicit packaged-game acceptance. Observes real Bot play without subsidies or combat edits.
const MAX_MATCH_SECONDS: float = 1200.0
const STEP: float = 1.0 / 30.0
var game: Node3D
var failures: Array[String] = []
var checks: int = 0
var observed: Dictionary = {}
var known_hp: Dictionary = {}
var harvested: Array[int] = [0, 0]
var produced: Array[Dictionary] = [{}, {}]
var completed: Array[Dictionary] = [{}, {}]
var damage_events: int = 0
var military_deaths: int = 0
var first_damage: float = -1.0
var started_at: int = 0
var step_valid: bool = true
@onready var session: Node = get_node("/root/Session")

func _ready() -> void:
	_run.call_deferred()

func check(value: bool, description: String) -> void:
	checks += 1
	if not value:
		failures.append(description)
		printerr("MATCH_SMOKE_FAIL ", description)

func _run() -> void:
	var arguments := OS.get_cmdline_user_args()
	if "--match-smoke" not in arguments:
		printerr("MATCH_SMOKE_FAIL explicit_probe_flag_required")
		get_tree().quit(2)
		return
	var speed: int = 10 if "--match-smoke-fast" in arguments else 1
	Engine.physics_ticks_per_second = 30 * speed
	Engine.time_scale = speed
	Engine.max_physics_steps_per_frame = 64 if speed > 1 else 8
	seed(947103)
	# start_offline changes the scene at the end of the frame. Configure its
	# saved roster before Game._ready constructs players and the standard Bots.
	session.start_offline("1v1")
	for slot: Dictionary in session.config.players:
		slot.controller = "bot"
	await get_tree().scene_changed
	game = get_tree().current_scene
	game.camera_rig.edge_scroll = false
	check(not game.tests_running and not game.online, "production_offline_victory_and_economy_enabled")
	check(game.players.size() == 2 and game.bots.size() == 2, "two_standard_bots_loaded_from_session")
	for player: PlayerState in game.players:
		check(player.gold == 320 and player.farmers == 3 and player.military_supply == 0, "owner_%d_approved_starting_economy" % player.owner_id)
	started_at = Time.get_ticks_msec()
	var next_observation: float = 0.0
	var next_progress: float = 0.0
	var previous_tick: int = game.simulation_tick
	var previous_elapsed: float = game.elapsed
	while not game.finished and game.elapsed < MAX_MATCH_SECONDS:
		await get_tree().physics_frame
		if game.simulation_tick > previous_tick:
			var elapsed_per_tick: float = (game.elapsed - previous_elapsed) / (game.simulation_tick - previous_tick)
			step_valid = step_valid and absf(elapsed_per_tick - STEP) < 0.000001
			previous_tick = game.simulation_tick
			previous_elapsed = game.elapsed
		if game.elapsed >= next_observation:
			_observe()
			next_observation += 1.0
		if game.elapsed >= next_progress:
			print("MATCH_SMOKE_PROGRESS ", JSON.stringify({"seconds": game.elapsed, "supply": [game.players[0].military_supply, game.players[1].military_supply], "damage_events": damage_events}))
			next_progress += 60.0
		if Time.get_ticks_msec() - started_at > (300000 if speed > 1 else 1500000):
			check(false, "wall_clock_guard")
			break
	_observe()
	var remaining: Array[int] = [0, 0]
	for building: BattleBuilding in get_tree().get_nodes_in_group("buildings"):
		if building.alive:
			remaining[building.alliance_id] += 1
	var winner: int = 0 if remaining[0] > 0 and remaining[1] == 0 else (1 if remaining[1] > 0 and remaining[0] == 0 else -1)
	check(game.finished and winner >= 0, "natural_victory_destroyed_all_opposing_military_buildings")
	check(step_valid and game.simulation_tick > 0, "every_observed_simulation_tick_preserved_one_thirtieth_second")
	check(damage_events > 0 and military_deaths > 0 and first_damage > 0, "real_armies_dealt_damage_and_suffered_casualties")
	for owner: int in range(2):
		check(harvested[owner] > 0, "owner_%d_real_mining_income" % owner)
		check(produced[owner].has("swordsman") and produced[owner].has("archer") and produced[owner].has("knight"), "owner_%d_paid_basic_army_production" % owner)
		check(completed[owner].has("barracks"), "owner_%d_real_barracks_construction_completed" % owner)
	var report := {"ok": failures.is_empty(), "checks": checks, "failures": failures, "build": NetworkProtocol.BUILD_ID,
		"mode": "1v1", "source_editor_feature": OS.has_feature("editor"), "rendering": DisplayServer.get_name(),
		"speed": speed, "step_seconds": STEP, "observed_step_valid": step_valid, "simulated_seconds": game.elapsed,
		"wall_seconds": (Time.get_ticks_msec() - started_at) / 1000.0, "finished": game.finished, "winner": winner,
		"remaining_buildings": remaining, "first_damage": first_damage, "damage_events": damage_events,
		"military_deaths": military_deaths, "harvested_gold": harvested, "produced": produced, "completed": completed}
	# Report success only after the production shutdown has stopped sounds and units.
	await game.prepare_shutdown()
	game.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 30
	print("MATCH_SMOKE_RESULT ", JSON.stringify(report))
	get_tree().quit(0 if failures.is_empty() else 1)

func _observe() -> void:
	for entity: Node3D in get_tree().get_nodes_in_group("entities"):
		var owner: int = entity.owner_id
		if not observed.has(entity.entity_id):
			observed[entity.entity_id] = false
			if entity is BattleUnit:
				produced[owner][entity.unit_type] = int(produced[owner].get(entity.unit_type, 0)) + 1
				entity.died.connect(_on_death)
				if entity.unit_type == "farmer":
					entity.gathered.connect(_on_gathered)
		if known_hp.has(entity.entity_id) and entity.hp < float(known_hp[entity.entity_id]) - 0.01:
			damage_events += 1
			if first_damage < 0:
				first_damage = game.elapsed
		known_hp[entity.entity_id] = entity.hp
		if entity is BattleBuilding and entity.is_constructed and not observed[entity.entity_id]:
			observed[entity.entity_id] = true
			completed[owner][entity.building_type] = int(completed[owner].get(entity.building_type, 0)) + 1

func _on_gathered(worker: BattleUnit, amount: int) -> void:
	harvested[worker.owner_id] += amount

func _on_death(entity: Node3D) -> void:
	if entity is BattleUnit and entity.unit_type != "farmer":
		military_deaths += 1
