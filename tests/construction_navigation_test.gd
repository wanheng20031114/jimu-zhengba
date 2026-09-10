extends SceneTree
## Real battlefield construction lifecycle, automatic tower fire, and map carving.

var game: Node3D
var navigation: ConstructionNavigation
var failures: Array[String] = []
var checks: int = 0
var ending: bool = false
var agent_path_changes: int = 0

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures.append(label)

func _run() -> void:
	create_timer(60.0).timeout.connect(func(): failures.append("construction test deadline"); _finish())
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.get_node("EnemyTimer").stop()
	game.get_node("IncomeTimer").stop()
	for unit: Node in get_nodes_in_group("units"):
		unit.queue_free()
	for building: Node in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
	await physics_frame
	await physics_frame
	navigation = game.get_node("ConstructionNavigation")
	navigation.refresh()
	await _sync()
	var at: Vector3 = _find_open_site()
	_check(at.y == 0.0, "finds a clear native battlefield placement")
	if at.y != 0.0:
		await _finish()
		return
	var start: Vector3 = at + Vector3(-7, 0.03, 0)
	var finish: Vector3 = at + Vector3(7, 0.03, 0)
	var original: PackedVector3Array = _path(start, finish)
	var marching: BattleUnit = _unit("knight", 0, start)
	marching.navigation_agent.path_changed.connect(func(): agent_path_changes += 1)
	marching.issue_move(finish)
	marching.navigation_agent.get_next_path_position()
	var changes_before: int = agent_path_changes
	var tower: BattleBuilding = _tower(at)
	navigation.refresh()
	_check(not navigation.contains_walkable_point(at), "same-frame placement cache prevents spawning inside a new site")
	_check(navigation.contains_walkable_point(at + Vector3(-3, 0, 0)), "walkable cache accepts the west boundary's surviving polygon")
	_check(navigation.contains_walkable_point(at + Vector3(0, 0, -3)), "walkable cache accepts the north boundary's surviving polygon")
	await _sync()
	var around: PackedVector3Array = _path(start, finish)
	_check(not navigation.is_placement_clear(at), "existing foundation rejects overlapping placement")
	_check(_length(around) > _length(original) + 0.5, "native path detours around an unfinished tower")
	_check(_avoids_footprint(around, at), "every detour segment stays outside the tower footprint")
	marching.navigation_agent.get_next_path_position()
	_check(agent_path_changes > changes_before, "existing NavigationAgent receives a path change after tower placement")
	_check(marching.order == BattleUnit.Order.MOVE and _length(marching.navigation_agent.get_current_navigation_path()) > _length(original) + 0.5, "existing move command automatically follows the rebuilt detour")
	var iterations: int = navigation.rebuild_count
	for repeat: int in range(12):
		navigation.refresh()
	_check(navigation.rebuild_count == iterations, "unchanged buildings never rebuild the navigation mesh")
	var farmer: BattleUnit = _unit("farmer", 0, at + Vector3(3.6, 0, 0))
	var second: BattleUnit = _unit("farmer", 0, at + Vector3(0, 0, 3.6))
	var enemy: BattleUnit = _unit("swordsman", 1, at + Vector3(8, 0, 0))
	_check(not tower.is_constructed and is_equal_approx(tower.hp, 80.0), "new site starts unfinished with foundation HP")
	_check(not tower.try_claim_builder(enemy), "enemy military cannot claim construction")
	_check(tower.try_claim_builder(farmer), "friendly farmer claims the worksite")
	_check(not tower.try_claim_builder(second), "second farmer cannot accelerate an occupied worksite")
	tower._target = enemy
	tower._scan_time = 10.0
	tower._cooldown = 0.0
	var shots: int = game.get_node("ProjectilePool").launch_count
	tower._physics_process(0.1)
	_check(game.get_node("ProjectilePool").launch_count == shots, "unfinished tower cannot fire")
	tower.contribute_work(farmer, 5.0)
	_check(is_equal_approx(tower.construction_progress, 0.25), "five work seconds create exactly one quarter of the tower")
	farmer.position = at + Vector3(8, 0, 0)
	tower.contribute_work(farmer, 5.0)
	_check(is_equal_approx(tower.construction_progress, 0.25), "distant farmer cannot progress construction")
	_check(tower.try_claim_builder(second), "another farmer can take over an abandoned worksite")
	tower.receive_damage(50.0, enemy)
	tower.contribute_work(second, 5.0)
	_check(is_equal_approx(tower.construction_progress, 0.5) and is_equal_approx(tower.hp, 390.0), "construction preserves damage while adding structural HP")
	tower.release_builder(second)
	tower.contribute_work(second, 10.0)
	_check(is_equal_approx(tower.construction_progress, 0.5), "released farmer cannot continue remote construction")
	_check(tower.try_claim_builder(second), "paused worksite can be reclaimed")
	tower.contribute_work(second, 10.0)
	_check(tower.is_constructed and is_equal_approx(tower.hp, 750.0), "twenty contributed seconds finish tower and retain damage")
	_check(not tower.construction_bar.visible and not tower.scaffolding.visible, "completed tower removes scaffold and progress bar")
	enemy.position = at + Vector3(14.0 + enemy.radius + 0.1, 0, 0)
	tower._target = enemy
	tower._scan_time = 10.0
	tower._cooldown = 0.0
	shots = game.get_node("ProjectilePool").launch_count
	tower._physics_process(0.01)
	_check(game.get_node("ProjectilePool").launch_count == shots, "cached target more than twelve metres outside the wall cannot receive a shot")
	enemy.position = at + Vector3(14.0 + enemy.radius - 0.1, 0, 0)
	tower._physics_process(0.01)
	_check(game.get_node("ProjectilePool").launch_count == shots + 1, "finished tower automatically fires at a nearby enemy")
	tower._target = farmer
	tower._cooldown = 0.0
	shots = game.get_node("ProjectilePool").launch_count
	tower._physics_process(0.01)
	_check(game.get_node("ProjectilePool").launch_count == shots, "tower rechecks faction before firing")
	var diagonal: Vector3 = Vector3(1, 0, 1).normalized()
	enemy.position = at + Vector3(2, 0, 2) + diagonal * (12.0 + enemy.radius - 0.1)
	_check(tower._can_shoot_target(enemy), "diagonal range consistently measures wall corner to target edge")
	await _sync()
	shots = game.get_node("ProjectilePool").launch_count
	tower._target = null
	tower._scan_time = 0.0
	tower._cooldown = 0.0
	tower._physics_process(0.01)
	_check(tower._target == enemy and game.get_node("ProjectilePool").launch_count == shots + 1, "native broadphase acquires and fires at enemies near the diagonal range limit")
	enemy.position += diagonal * 0.2
	_check(not tower._can_shoot_target(enemy), "diagonal target beyond the same edge range is rejected")
	_check(tower.cancel_construction() == 0 and tower.alive, "completed tower cannot be canceled for a refund")
	tower.receive_damage(5000.0, enemy)
	navigation.refresh()
	await _sync()
	_check(_length(_path(start, finish)) <= _length(original) + 0.05, "destroying the tower restores its former passage")
	marching.navigation_agent.get_next_path_position()
	_check(_length(marching.navigation_agent.get_current_navigation_path()) <= _length(original) + 0.05, "existing NavigationAgent also restores its original direct route")
	_check(navigation.is_placement_clear(at), "destroyed tower permits rebuilding on the cleared footprint")
	_check(navigation.contains_walkable_point(at), "same-frame placement cache restores cleared ground")
	var cancel_site: BattleBuilding = _tower(at)
	navigation.refresh()
	second.position = at + Vector3(0, 0, 3.6)
	cancel_site.try_claim_builder(second)
	cancel_site.contribute_work(second, 5.0)
	_check(cancel_site.cancel_construction() == 75, "quarter-built tower cancellation returns seventy-five gold")
	_check(cancel_site.cancel_construction() == 0, "repeat cancellation cannot refund twice")
	navigation.refresh()
	await _sync()
	_check(_length(_path(start, finish)) <= _length(original) + 0.05, "cancellation also restores native navigation")
	await _demolition_overlap()
	await _stale_work_queue(at, farmer)
	var completed: BattleBuilding = _tower(at)
	completed.under_construction = false
	completed.construction_progress = 1.0
	_check(completed.demolish() and not completed.alive, "friendly completed tower can be deliberately demolished")
	_check(not completed.demolish(), "repeat demolition cannot destroy the same tower twice")
	var retired: BattleBuilding = _tower(at)
	_check(not retired.demolish(), "unfinished site uses refundable cancellation instead of finished-tower demolition")
	_check(not game.headquarters.demolish(), "headquarters cannot be removed through tower demolition")
	var retired_ref: WeakRef = weakref(retired)
	retired.get_node("DebrisLifetime").wait_time = 0.05
	retired.cancel_construction()
	await create_timer(0.15).timeout
	_check(retired_ref.get_ref() == null, "dynamic tower debris retires its complete node hierarchy")
	await _finish()

func _stale_work_queue(at: Vector3, farmer: BattleUnit) -> void:
	var retired: BattleBuilding = _tower(at)
	var next_site: BattleBuilding = _tower(at + Vector3(10, 0, 0))
	farmer.issue_move(at + Vector3(-7, 0, -7))
	farmer.issue_build(retired, true)
	retired.cancel_construction()
	retired.queue_free()
	await process_frame
	await physics_frame
	_check(farmer.issue_build(next_site, true), "adding a work order after a freed queued site remains safe")
	farmer._complete_waypoint()
	_check(farmer.order == BattleUnit.Order.BUILD and farmer.work_target == next_site, "work queue skips a reclaimed site and preserves its next order")
	next_site.cancel_construction()
	next_site.queue_free()
	await process_frame
	await physics_frame
	farmer._work_velocity(0.1)
	_check(farmer.order == BattleUnit.Order.IDLE and farmer.work_target == null, "reclaiming the active work target ends its order without a stale reference")
	navigation.refresh()

func _tower(at: Vector3) -> BattleBuilding:
	var tower: BattleBuilding = load("res://scenes/building.tscn").instantiate()
	tower.building_type = "defense_tower"
	tower.team = 0
	tower.under_construction = true
	tower.position = at
	game.get_node("Buildings").add_child(tower)
	tower.set_physics_process(false)
	return tower

func _unit(kind: String, faction: int, at: Vector3) -> BattleUnit:
	var unit: BattleUnit = game.spawn_unit(kind, faction, at)
	unit.set_physics_process(false)
	unit.navigation_agent.avoidance_enabled = false
	unit.get_node("AttackWindup").stop()
	return unit

func _find_open_site() -> Vector3:
	for z: int in range(24, -26, -3):
		for x: int in range(-24, 25, 3):
			var at := Vector3(x, 0, z)
			if not navigation.is_placement_clear(at):
				continue
			var path: PackedVector3Array = _path(at + Vector3(-7, 0.03, 0), at + Vector3(7, 0.03, 0))
			if path.size() >= 2 and path[0].distance_to(at + Vector3(-7, 0.03, 0)) < 0.1 and path[-1].distance_to(at + Vector3(7, 0.03, 0)) < 0.1 and _length(path) < 14.05:
				return at
	return Vector3(0, -100, 0)

func _demolition_overlap() -> void:
	var keep: BattleBuilding = game.get_node("Buildings/EnemyKeep")
	var at: Vector3 = keep.global_position
	keep.receive_damage(5000.0)
	navigation.refresh()
	await _sync()
	var tower: BattleBuilding = _tower(at)
	navigation.refresh()
	await _sync()
	var patch: NavigationRegion3D = game.get_node("ClearedNavigation/EnemyKeep")
	var mesh: NavigationMesh = patch.navigation_mesh
	var vertices: PackedVector3Array = mesh.get_vertices()
	var clear: bool = true
	for index: int in mesh.get_polygon_count():
		var center: Vector3 = Vector3.ZERO
		var polygon: PackedInt32Array = mesh.get_polygon(index)
		for vertex: int in polygon:
			center += vertices[vertex]
		center /= float(polygon.size())
		clear = clear and (absf(center.x - at.x) >= 3.15 or absf(center.z - at.z) >= 3.15)
	_check(patch.enabled and clear, "tower on demolished building also carves that building's navigation patch")
	tower.cancel_construction()
	navigation.refresh()
	await _sync()
	_check(patch.navigation_mesh == load("res://assets/navigation/EnemyKeep_cleared.tres"), "removing final tower restores the immutable demolition mesh")

func _sync() -> void:
	# Loading a large battlefield may catch up several physics ticks inside one
	# process frame. Region uploads and the map iteration need both boundaries.
	for frame: int in range(8):
		await physics_frame
		await process_frame
	NavigationServer3D.map_force_update(game.get_world_3d().navigation_map)
	await physics_frame

func _path(start: Vector3, finish: Vector3) -> PackedVector3Array:
	return NavigationServer3D.map_get_path(game.get_world_3d().navigation_map, start, finish, true)

func _length(path: PackedVector3Array) -> float:
	var result: float = 0.0
	for index: int in range(1, path.size()):
		result += path[index - 1].distance_to(path[index])
	return result

func _avoids_footprint(path: PackedVector3Array, at: Vector3) -> bool:
	if path.size() < 2:
		return false
	for index: int in range(1, path.size()):
		var steps: int = ceili(path[index - 1].distance_to(path[index]) / 0.2)
		for step: int in range(steps + 1):
			var point: Vector3 = path[index - 1].lerp(path[index], float(step) / maxi(steps, 1))
			if absf(point.x - at.x) < 2.8 and absf(point.z - at.z) < 2.8:
				return false
	return true

func _finish() -> void:
	if ending:
		return
	ending = true
	var report := FileAccess.open("res://artifacts/construction_navigation.json", FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks": checks, "failures": failures, "rebuild_count": navigation.rebuild_count, "last_rebuild_usec": navigation.last_rebuild_usec}, "  "))
	report.close()
	print("CONSTRUCTION_NAVIGATION ", checks, " checks; ", failures.size(), " failures")
	await game.prepare_shutdown()
	quit(0 if failures.is_empty() else 1)
