extends SceneTree
## Real native bodies, fog and authoritative elimination across all six alliances.
var game: Node3D
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	Engine.max_fps = 60
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func _load_mode(mode: String, shuffled: bool = false) -> void:
	var session: Node = root.get_node("Session")
	session.start_offline(mode)
	if shuffled:
		for owner: int in range(6):
			session.config.players[owner].team_id = owner % 2
	await scene_changed
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

func _unit(kind: String, owner: int, at: Vector3) -> BattleUnit:
	var result: BattleUnit = game.spawn_unit(kind, owner, at)
	result.set_physics_process(false)
	result.navigation_agent.avoidance_enabled = false
	return result

func _discard(entity: Node3D) -> void:
	game.entities_by_id.erase(entity.entity_id)
	entity.queue_free()

func _run() -> void:
	await _load_mode("ffa")
	var fog: FogOfWar = game.get_node("FogOfWar")
	check(fog.alliance_count == 6 and fog.grid_size == Vector2i(80, 80), "six_independent_full_size_fog_masks")
	for owner: int in range(6):
		var home: Vector3 = game.get_spawn_marker(owner).global_position
		check(fog.position_visible(owner, home), "owner_%d_sees_own_start" % owner)
		for other: int in range(6):
			if other != owner:
				check(not fog.position_visible(other, home), "owner_%d_does_not_share_vision_with_%d" % [owner, other])
		var snapshot := fog.snapshot_for(owner)
		game.is_authority = false
		fog._received_revision = -1
		check(fog.apply_snapshot(snapshot), "owner_%d_fog_roundtrips_dynamic_alliance_array" % owner)
		var invalid := snapshot.duplicate(true)
		invalid.revision += 1
		invalid.revealed_building_alliances.pop_back()
		check(not fog.apply_snapshot(invalid), "owner_%d_rejects_wrong_reveal_array_length" % owner)
		game.is_authority = true
	for attacker: int in range(6):
		for defender: int in range(6):
			if attacker == defender:
				continue
			var source := _unit("archer", attacker, Vector3(-5, 0, 0))
			var target := _unit("swordsman", defender, Vector3.ZERO)
			var friendly := _unit("swordsman", attacker, Vector3(0, 0, 0.8))
			var tower: BattleBuilding = game.spawn_building("defense_tower", attacker, Vector3(-6, 0, -6))
			tower.set_physics_process(false)
			await physics_frame
			await physics_frame
			fog.tick(0.3)
			source._refresh_target()
			check(source.target == target, "native_acquisition_%d_attacks_%d_not_friendly" % [attacker, defender])
			tower._scan_time = 0
			tower._cooldown = 100
			tower._physics_process(0.1)
			check(tower._target == target, "native_tower_%d_targets_alliance_%d" % [attacker, defender])
			var stone: BattleProjectile = game.PROJECTILE_SCENE.instantiate()
			game.effect_container.add_child(stone)
			stone.initialize(source, target, DamageResolver.snapshot(BalanceCatalog.unit("catapult"), 0, attacker, attacker), "stone")
			stone.set_physics_process(false)
			stone._impact()
			check(is_equal_approx(target.hp, 21.0), "native_stone_%d_hits_alliance_%d" % [attacker, defender])
			check(friendly.hp == friendly.max_hp, "native_stone_%d_preserves_own_units_%d" % [attacker, defender])
			stone.queue_free()
			_discard(source)
			_discard(target)
			_discard(friendly)
			_discard(tower)
			await physics_frame
			await physics_frame
	game.tests_running = false
	for eliminated: int in range(5):
		for building: BattleBuilding in game.owned_entities(eliminated, "buildings"):
			building.receive_damage(building.hp)
		game.check_victory()
		check(game.get_player(eliminated).eliminated, "faction_%d_is_eliminated" % eliminated)
		check(game.finished == (eliminated == 4), "faction_%d_elimination_only_ends_when_one_remains" % eliminated)
		var before: int = game.get_player(eliminated).gold
		game._on_income()
		check(game.get_player(eliminated).gold == before, "eliminated_%d_receives_no_income" % eliminated)
		check(not game.command_bus.execute({"kind": "stop"}, eliminated).ok, "eliminated_%d_cannot_issue_commands" % eliminated)
	check(not game.get_player(5).eliminated, "sixth_faction_can_win_after_host_faction_dies")
	await game.prepare_shutdown()
	await _load_mode("3v3", true)
	for owner: int in range(6):
		var marker: Marker3D = game.get_spawn_marker(owner)
		var expected: int = owner / 2 + (0 if owner % 2 == 0 else 3)
		check(marker.name == "Player%d" % expected, "shuffled_owner_%d_starts_with_actual_teammates" % owner)
		var base: BattleBuilding = game.owned_entities(owner, "buildings").filter(func(b): return b.building_type == "headquarters")[0]
		check(base.global_position.is_equal_approx(marker.global_position), "shuffled_owner_%d_assets_follow_spawn_assignment" % owner)
		var ally: int = (owner + 2) % 6
		check(game.get_node("FogOfWar").position_visible(ally, base.global_position), "shuffled_owner_%d_shares_vision_with_actual_team" % owner)
		check(not game.get_node("FogOfWar").position_visible((owner + 1) % 6, base.global_position), "shuffled_owner_%d_hides_start_from_other_team" % owner)
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("MULTI_ALLIANCE_RESULTS " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)
