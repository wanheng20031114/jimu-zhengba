extends Node
## Explicit packaged-game acceptance. Observes real Bot play without subsidies or combat edits.
const MAX_MATCH_SECONDS: float = 1200.0
const STEP: float = 1.0 / 30.0
var game: Node3D
var failures: Array[String] = []
var checks: int = 0
var observed: Dictionary = {}
var known_hp: Dictionary = {}
var harvested: Array[int] = []
var produced: Array[Dictionary] = []
var completed: Array[Dictionary] = []
var damage_events: int = 0
var military_deaths: int = 0
var first_damage: float = -1.0
var started_at: int = 0
var step_valid: bool = true
var samples: Array[Dictionary] = []
var catalogue_probe: Dictionary = {}
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
	var diagnostic: bool = "--match-smoke-diagnose" in arguments
	var match_limit: float = 120.0 if diagnostic else MAX_MATCH_SECONDS
	Engine.physics_ticks_per_second = 30 * speed
	Engine.time_scale = speed
	Engine.max_physics_steps_per_frame = 64 if speed > 1 else 8
	seed(947103)
	# start_offline changes the scene at the end of the frame. Configure its
	# saved roster before Game._ready constructs players and the standard Bots.
	var mode := "1v1"
	for candidate: String in NetworkProtocol.MODES:
		if "--" + candidate in arguments:
			mode = candidate
	session.start_offline(mode)
	for slot: Dictionary in session.config.players:
		slot.controller = "bot"
		harvested.append(0)
		produced.append({})
		completed.append({})
	await get_tree().scene_changed
	game = get_tree().current_scene
	game.camera_rig.edge_scroll = false
	catalogue_probe = _inspect_catalogue()
	print("MATCH_SMOKE_CATALOGUE ", JSON.stringify(catalogue_probe))
	check(not game.tests_running and not game.online, "production_offline_victory_and_economy_enabled")
	check(game.players.size() == int(NetworkProtocol.MODES[mode].slots) and game.bots.size() == game.players.size(), "all_standard_bots_loaded_from_session")
	for player: PlayerState in game.players:
		check(player.gold == 320 and player.farmers == 3 and player.military_supply == 0, "owner_%d_approved_starting_economy" % player.owner_id)
		var towers: Array = game.owned_entities(player.owner_id, "buildings").filter(func(building): return building.building_type == "defense_tower")
		check(towers.size() == 1, "owner_%d_starts_with_exactly_one_free_tower" % player.owner_id)
		if towers.size() == 1:
			var marker: Marker3D = game.get_spawn_marker(player.owner_id)
			check(towers[0].is_constructed and towers[0].hp == 1000 and towers[0].max_hp == 1000
				and towers[0].global_position.is_equal_approx(game.map_instance.to_global(marker.get_meta("starting_tower_position"))),
				"owner_%d_starting_tower_is_complete_at_authored_mine_position" % player.owner_id)
	started_at = Time.get_ticks_msec()
	var next_observation: float = 0.0
	var next_progress: float = 0.0
	var previous_tick: int = game.simulation_tick
	var previous_elapsed: float = game.elapsed
	while not game.finished and game.elapsed < match_limit:
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
			var sample := _diagnostics()
			samples.append(sample)
			print("MATCH_SMOKE_PROGRESS ", JSON.stringify(sample))
			next_progress += 30.0 if next_progress < 60.0 else 60.0
		if Time.get_ticks_msec() - started_at > (300000 if speed > 1 else 1500000):
			check(false, "wall_clock_guard")
			break
	_observe()
	var remaining: Array[int] = []
	remaining.resize(int(NetworkProtocol.MODES[mode].teams))
	remaining.fill(0)
	for building: BattleBuilding in get_tree().get_nodes_in_group("buildings"):
		if building.alive:
			remaining[building.alliance_id] += 1
	var contenders: Array[int] = []
	for alliance: int in range(remaining.size()):
		if remaining[alliance] > 0:
			contenders.append(alliance)
	var winner: int = contenders[0] if contenders.size() == 1 else -1
	check(not diagnostic and game.finished and winner >= 0, "natural_victory_destroyed_all_opposing_military_buildings")
	check(step_valid and game.simulation_tick > 0, "every_observed_simulation_tick_preserved_one_thirtieth_second")
	check(damage_events > 0 and military_deaths > 0 and first_damage > 0, "real_armies_dealt_damage_and_suffered_casualties")
	for owner: int in range(game.players.size()):
		check(harvested[owner] > 0, "owner_%d_real_mining_income" % owner)
		check(produced[owner].has("swordsman") and produced[owner].has("archer") and produced[owner].has("knight"), "owner_%d_paid_basic_army_production" % owner)
		check(completed[owner].has("barracks"), "owner_%d_real_barracks_construction_completed" % owner)
	var report := {"ok": failures.is_empty(), "checks": checks, "failures": failures, "build": NetworkProtocol.BUILD_ID,
		"mode": mode, "source_editor_feature": OS.has_feature("editor"), "rendering": DisplayServer.get_name(),
		"speed": speed, "step_seconds": STEP, "observed_step_valid": step_valid, "simulated_seconds": game.elapsed,
		"wall_seconds": (Time.get_ticks_msec() - started_at) / 1000.0, "finished": game.finished, "winner": winner,
		"remaining_buildings": remaining, "first_damage": first_damage, "damage_events": damage_events,
		"military_deaths": military_deaths, "harvested_gold": harvested, "produced": produced, "completed": completed,
		"diagnostic_only": diagnostic, "samples": samples, "catalogue_probe": catalogue_probe, "final_state": _diagnostics()}
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

func _diagnostics() -> Dictionary:
	var map: RID = game.get_world_3d().navigation_map
	var map_iteration: int = NavigationServer3D.map_get_iteration_id(map)
	var navigation: ConstructionNavigation = game.get_node("ConstructionNavigation")
	var region: NavigationRegion3D = game.map_instance.get_node("NavigationRegion3D")
	var paths: PathBudget = game.get_node("PathBudget")
	var row := {"seconds": game.elapsed, "damage_events": damage_events, "players": [], "workers": [], "buildings": [],
		"mines": [], "last_notification": game.last_notification,
		"navigation": {"iteration": map_iteration, "active": NavigationServer3D.map_is_active(map),
			"region_enabled": region.enabled, "region_polygons": region.navigation_mesh.get_polygon_count(),
			"compact_polygons": navigation.compact_polygon_count, "rebuilds": navigation.rebuild_count,
			"worker_task": navigation.is_rebuilding(), "walkable_cells": navigation._walkable_cells.size(),
			"queries": paths.total_queries, "pending": paths.pending_count()}}
	for player: PlayerState in game.players:
		row.players.append({"owner": player.owner_id, "gold": player.gold, "workers": player.farmers,
			"reserved_workers": player.reserved_farmers, "supply": player.military_supply, "reserved_supply": player.reserved_military_supply,
			"harvested": harvested[player.owner_id], "eliminated": player.eliminated, "bot_state": "eliminated" if player.eliminated else str(game.bots[player.owner_id].army_state)})
	for unit: BattleUnit in get_tree().get_nodes_in_group("units"):
		if unit.unit_type != "farmer":
			continue
		row.workers.append({"id": unit.entity_id, "owner": unit.owner_id, "at": game.vector_data(unit.position),
			"destination": game.vector_data(unit.destination), "order": unit.order_name, "working": unit._working,
			"work_seconds": unit._work_seconds, "claimed_mine": unit._claimed_mine,
			"target": unit.work_target.entity_id if is_instance_valid(unit.work_target) else 0,
			"path_points": unit.navigation_agent.get_current_navigation_path().size(),
			"nearest_nav": game.vector_data(NavigationServer3D.map_get_closest_point(map, unit.position)) if map_iteration > 0 else null})
	for building: BattleBuilding in get_tree().get_nodes_in_group("buildings"):
		if not building.alive:
			continue
		row.buildings.append({"id": building.entity_id, "owner": building.owner_id, "kind": building.building_type,
			"at": game.vector_data(building.position), "built": building.is_constructed,
			"progress": building.construction_progress, "training": building.production.training.duplicate(true),
			"definition_path": building.get_combat_definition().resource_path,
			"produces": Array(building.get_combat_definition().produces),
			"can_list_farmer": "farmer" in building.get_combat_definition().produces,
			"recruit_farmer_error": building.production.recruit_error("farmer"),
			"recruit_swordsman_error": building.production.recruit_error("swordsman"),
			"farmer_exit_available": game.find_recruit_position("farmer", building).is_finite() if building.building_type == "headquarters" else false})
	for mine: ResourceVein in get_tree().get_nodes_in_group("resource_veins"):
		row.mines.append({"id": mine.entity_id, "at": game.vector_data(mine.position), "occupied": mine.occupied_slots()})
	return row

func _inspect_catalogue() -> Dictionary:
	var result: Dictionary = {}
	var economy_fields := {"passive_gold_per_second": 1, "mining_seconds": 3.0, "mining_gold": 4}
	var fresh_economy: EconomyDefinition = ResourceLoader.load("res://data/economy.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	result.economy = {"cached": {}, "fresh": {}, "resource_path": BalanceCatalog.ECONOMY.resource_path}
	for field: String in economy_fields:
		result.economy.cached[field] = BalanceCatalog.ECONOMY.get(field)
		result.economy.fresh[field] = fresh_economy.get(field)
		check(result.economy.cached[field] == economy_fields[field] and result.economy.fresh[field] == economy_fields[field], "catalogue_economy_" + field)
	result.training_seconds = {}
	var training := {"farmer": 10.0, "swordsman": 6.0, "archer": 8.0, "knight": 10.0, "catapult": 20.0, "cannon": 20.0}
	for kind: String in training:
		var fresh_unit: UnitDefinition = ResourceLoader.load("res://data/units/%s.tres" % kind, "", ResourceLoader.CACHE_MODE_IGNORE)
		var cached_seconds: float = BalanceCatalog.unit(kind).training_seconds
		result.training_seconds[kind] = {"cached": cached_seconds, "fresh": fresh_unit.training_seconds}
		check(cached_seconds == training[kind] and fresh_unit.training_seconds == training[kind], "catalogue_training_seconds_" + kind)
	for kind: String in ["headquarters", "barracks", "factory"]:
		var path: String = "res://data/buildings/%s.tres" % kind
		var cached: BuildingDefinition = BalanceCatalog.BUILDINGS[kind]
		var fresh: BuildingDefinition = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		result[kind] = {"cached_produces": Array(cached.produces), "fresh_produces": Array(fresh.produces),
			"cached_type": typeof(cached.produces), "fresh_type": typeof(fresh.produces),
			"cached_damage": cached.damage, "fresh_damage": fresh.damage,
			"same_instance": cached == fresh, "cached_path": cached.resource_path, "fresh_path": fresh.resource_path}
	return result
