extends SceneTree
## Real match opening: authored sites, native geometry/navigation and live arrows.
var game: Node3D
var checks: int = 0
var failures: Array[String] = []
var towers: Array[BattleBuilding] = []
var bases: Array[BattleBuilding] = []
var mines: Array[ResourceVein] = []
var navigation_wait_ticks: int = 0

func _initialize() -> void:
	Engine.max_fps = 60
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error(label)

func _run() -> void:
	var mode: String = "2v2" if "--2v2" in OS.get_cmdline_user_args() else "1v1"
	root.get_node("Session").start_offline(mode)
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.set_physics_process(false)
	game.camera_rig.edge_scroll = false
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	check(game.players.size() == (4 if mode == "2v2" else 2), "all_mode_player_slots_created")
	check(game.bots.size() == game.players.size() - 1, "default_human_and_bot_players_share_opening_rules")
	_opening_state()
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	while game.get_node("ConstructionNavigation").is_rebuilding():
		await physics_frame
	for tick in range(4):
		await physics_frame
	# Worker completion/first map iteration can precede publication of the
	# replacement region. Wait for real production exits, with a fixed limit.
	for tick: int in range(300):
		if bases.all(func(base: BattleBuilding): return game.find_recruit_position("farmer", base).is_finite()):
			break
		navigation_wait_ticks += 1
		await physics_frame
	check(bases.all(func(base: BattleBuilding): return game.find_recruit_position("farmer", base).is_finite()), "native_navigation_publishes_all_headquarters_exits_within_ten_seconds")
	for owner: int in range(towers.size()):
		_geometry_and_paths(owner)
		await _auto_defense(owner)
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("STARTING_TOWER_RESULTS " + JSON.stringify({"mode": mode, "checks": checks, "failures": failures, "navigation_wait_ticks": navigation_wait_ticks}))
	quit(0 if failures.is_empty() else 1)

func _opening_state() -> void:
	for player: PlayerState in game.players:
		var owner: int = player.owner_id
		var owned: Array = game.owned_entities(owner, "buildings")
		var owner_towers: Array = owned.filter(func(b: BattleBuilding): return b.building_type == "defense_tower")
		var owner_bases: Array = owned.filter(func(b: BattleBuilding): return b.building_type == "headquarters")
		check(owned.size() == 2 and owner_towers.size() == 1 and owner_bases.size() == 1, "owner_%d_one_headquarters_and_one_free_tower" % owner)
		check(player.gold == 320 and player.farmers == 3 and player.military_supply == 0, "owner_%d_opening_economy_unchanged" % owner)
		if owner_towers.size() != 1 or owner_bases.size() != 1:
			continue
		var tower: BattleBuilding = owner_towers[0]
		var base: BattleBuilding = owner_bases[0]
		var mine: ResourceVein = base.production.rally_mine
		towers.append(tower)
		bases.append(base)
		mines.append(mine)
		check(tower.alive and tower.is_constructed and tower.construction_progress == 1.0, "owner_%d_tower_completed_on_first_frame" % owner)
		check(tower.hp == BalanceCatalog.building("defense_tower").hp and tower.hp == tower.max_hp, "owner_%d_tower_starts_at_full_current_hp" % owner)
		check(tower.owner_id == owner and tower.alliance_id == player.alliance_id, "owner_%d_tower_has_correct_ownership_and_alliance" % owner)
		var spawn: Marker3D = game.map_instance.get_node("SpawnPoints/Player%d" % owner)
		var authored: Vector3 = game.map_instance.to_global(spawn.get_meta("starting_tower_position"))
		check(tower.global_position.is_equal_approx(authored), "owner_%d_tower_uses_native_authored_map_position" % owner)
		var front: Vector3 = -base.global_position.normalized()
		var left := Vector3(front.z, 0, -front.x)
		check((mine.global_position - base.global_position).dot(left) > 0.0, "owner_%d_protected_mine_is_on_local_left" % owner)
		check(tower.global_position.distance_to(mine.global_position) <= 9.0, "owner_%d_tower_stands_beside_starting_mine" % owner)
		check(mine.occupied_slots() == 3 and base.rally_point == mine.global_position, "owner_%d_three_workers_and_rally_keep_starting_mine" % owner)
		var foreign_owner: int = (owner + 1) % game.players.size()
		var denied: Dictionary = game.command_bus.execute({"kind": "destroy", "targets": [tower.entity_id]}, foreign_owner)
		check(not denied.ok and tower.alive, "owner_%d_other_player_cannot_destroy_opening_tower" % owner)
	var half: int = towers.size() / 2
	for owner: int in range(half):
		check(towers[owner].global_position.is_equal_approx(-towers[owner + half].global_position), "opposing_tower_sites_remain_half_turn_symmetric_%d" % owner)

func _geometry_and_paths(owner: int) -> void:
	var tower: BattleBuilding = towers[owner]
	var base: BattleBuilding = bases[owner]
	var mine: ResourceVein = mines[owner]
	var space: PhysicsDirectSpaceState3D = game.get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	var tower_shape := BoxShape3D.new()
	tower_shape.size = tower.get_combat_definition().size - Vector3(0.02, 0.02, 0.02)
	query.shape = tower_shape
	query.transform.origin = tower.global_position + Vector3.UP * 3.0
	query.collision_mask = 1 | 2 | 4 | 128
	query.exclude = [tower.get_rid()]
	check(space.intersect_shape(query, 1).is_empty(), "owner_%d_tower_native_body_clears_rocks_trees_mines_buildings" % owner)
	var navigation: ConstructionNavigation = game.get_node("ConstructionNavigation")
	check(not navigation.contains_walkable_point(tower.global_position), "owner_%d_tower_is_carved_from_native_navigation" % owner)
	var exit: Vector3 = game.find_recruit_position("farmer", base)
	check(exit.is_finite(), "owner_%d_headquarters_keeps_a_free_training_exit" % owner)
	if not exit.is_finite():
		return
	var nav_map: RID = game.get_world_3d().navigation_map
	var worker_shape := CapsuleShape3D.new()
	worker_shape.radius = BalanceCatalog.unit("farmer").radius * 0.85
	worker_shape.height = 1.8
	query.shape = worker_shape
	query.exclude = []
	for slot: Marker3D in mine.get_node("GatherSlots").get_children():
		var at: Vector3 = slot.global_position
		query.transform.origin = at + Vector3.UP
		check(space.intersect_shape(query, 1).is_empty(), "owner_%d_%s_worker_body_has_physical_clearance" % [owner, slot.name])
		check(navigation.contains_walkable_point(at), "owner_%d_%s_remains_logically_walkable" % [owner, slot.name])
		var closest: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, at)
		check(closest.distance_to(at) < 0.21, "owner_%d_%s_remains_on_published_native_navigation" % [owner, slot.name])
		var path: PackedVector3Array = NavigationServer3D.map_get_path(nav_map, exit, at, true)
		check(path.size() >= 2 and path[-1].distance_to(at) < 0.21, "owner_%d_%s_has_a_native_path_from_headquarters_exit" % [owner, slot.name])
		check(tower.get_attack_position(at).distance_to(at) <= tower.get_combat_definition().range, "owner_%d_%s_is_covered_by_opening_tower_range" % [owner, slot.name])

func _auto_defense(owner: int) -> void:
	var tower: BattleBuilding = towers[owner]
	var enemy_owner: int = 0
	for player: PlayerState in game.players:
		if player.alliance_id != tower.alliance_id:
			enemy_owner = player.owner_id
			break
	var enemy: BattleUnit = game.spawn_unit("archer", enemy_owner, tower.global_position + Vector3(8, 0, 0))
	enemy.set_physics_process(false)
	enemy.navigation_agent.avoidance_enabled = false
	var ally_owner: int = owner
	for player: PlayerState in game.players:
		if player.owner_id != owner and player.alliance_id == tower.alliance_id:
			ally_owner = player.owner_id
			break
	var ally: BattleUnit = game.spawn_unit("archer", ally_owner, tower.global_position + Vector3(5, 0, 0))
	ally.set_physics_process(false)
	ally.navigation_agent.avoidance_enabled = false
	await physics_frame
	await physics_frame
	check(not tower._can_shoot_target(ally), "owner_%d_opening_tower_never_targets_own_or_teammate_unit" % owner)
	tower._scan_time = 0.0
	tower._cooldown = 0.0
	tower._physics_process(1.0 / 30.0)
	check(tower._target == enemy, "owner_%d_opening_tower_autonomously_acquires_enemy" % owner)
	for tick: int in range(90):
		if enemy.hp < enemy.max_hp:
			break
		await physics_frame
	check(enemy.hp == enemy.max_hp - 26.0 and ally.hp == ally.max_hp, "owner_%d_real_tower_arrow_hits_enemy_only" % owner)
	enemy.receive_damage(enemy.hp)
	ally.receive_damage(ally.hp)
	await physics_frame
