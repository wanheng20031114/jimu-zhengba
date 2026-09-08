extends SceneTree
## Main-scene economic controls through native viewport input; no desktop pointer.
var game: Node3D
var checks: int = 0
var failures: Array[String] = []
var ending: bool = false

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures.append(label)

func _sync() -> void:
	for frame: int in range(6):
		await physics_frame
		await process_frame

func _key(code: Key, shift: bool = false, ctrl: bool = false) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = true
	event.shift_pressed = shift
	event.ctrl_pressed = ctrl
	Input.parse_input_event(event)
	await process_frame
	event.pressed = false
	Input.parse_input_event(event)
	await process_frame

func _click(at: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT, shift: bool = false) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = at
		event.global_position = at
		event.button_index = button
		event.pressed = pressed
		event.shift_pressed = shift
		root.push_input(event, true)
		await process_frame

func _until(predicate: Callable, seconds: float = 5.0) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0 / Engine.time_scale) + 600
	while not predicate.call() and Time.get_ticks_msec() < deadline and not ending:
		await physics_frame
		await process_frame
	return bool(predicate.call())

func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout

func _freeze(unit: Node3D, value: bool = true) -> void:
	unit.set_physics_process(not value)
	unit.navigation_agent.avoidance_enabled = not value
	unit.get_node("AttackWindup").stop()

func _latest_farmer(previous: Array[Node]) -> Node3D:
	for unit: Node3D in get_nodes_in_group("friendly_units"):
		if unit not in previous and unit.unit_type == "farmer":
			return unit
	return null

func _focus(at: Vector3) -> void:
	game.camera_rig.focus_at(at, true)
	await process_frame

func _screen(entity: Node3D, height: float = 1.1) -> Vector2:
	return game.camera.unproject_position(entity.global_position + Vector3.UP * height)

func _sites() -> Array[Node]:
	return get_nodes_in_group("buildings").filter(func(building: Node): return building.building_type == "defense_tower")

func _find_site(near: Vector3, minimum_distance: float = 0.0) -> Vector3:
	var best: Vector3 = Vector3(0, -100, 0)
	var best_distance: float = INF
	for z: int in range(-24, 31, 2):
		for x: int in range(-28, 29, 2):
			var at := Vector3(x, 0, z)
			var distance: float = at.distance_squared_to(near)
			if distance < minimum_distance * minimum_distance or distance >= best_distance:
				continue
			if game.placement_error(at).is_empty():
				best = at
				best_distance = distance
	return best

func _run() -> void:
	create_timer(100.0, true, false, true).timeout.connect(func(): failures.append("economy input deadline"); _finish())
	Engine.time_scale = 3.0
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.camera_rig.edge_scroll = false
	game.get_node("EnemyTimer").stop()
	game.get_node("IncomeTimer").stop()
	for entity: Node3D in get_nodes_in_group("entities"):
		entity.set_physics_process(false)
		if entity.is_in_group("units"):
			_freeze(entity)
	await _sync()
	game.gold = 1000
	game.hud.refresh()
	var initial: int = game.player_count()
	var original: Array[Node] = get_nodes_in_group("friendly_units")
	await _key(KEY_U)
	var worker: Node3D = _latest_farmer(original)
	_check(worker != null and game.player_count() == initial + 1 and game.gold == 950, "native U recruits a farmer instantly for fifty gold")
	if worker == null:
		await _finish()
		return
	worker.stop()
	_freeze(worker)
	original = get_nodes_in_group("friendly_units")
	var recruit: Button = game.hud.get_node("CommandBar/Recruitment/Recruit5")
	await _click(recruit.get_global_rect().get_center())
	var second: Node3D = _latest_farmer(original)
	_check(second != null and game.player_count() == initial + 2 and game.gold == 900, "real farmer production button dispatches native GUI input")
	_check(game.selection.size() == 1 and game.selection[0] == game.headquarters, "production GUI preserves headquarters selection")
	if second == null:
		await _finish()
		return
	second.stop()
	_freeze(second)
	var mine: Node3D = get_nodes_in_group("resource_veins")[1]
	await _focus(mine.global_position)
	await _click(_screen(mine))
	_check(game.selection.size() == 1 and game.selection[0] == mine, "native world click selects the mineral deposit")
	_check(not game.hud.hp_bar.visible and not game.hud.hp_label.visible and game.hud.selected_role.text.contains("金矿"), "mineral details never read or display unit HP")
	var before_gold: int = game.gold
	await _key(KEY_U)
	_check(game.gold == before_gold and game.player_count() == initial + 2, "farmer shortcut requires headquarters selection")
	worker.position = mine.global_position + Vector3(0, 0, 5.2)
	await _sync()
	await _click(_screen(worker), MOUSE_BUTTON_LEFT, true)
	_check(game.selection.size() == 1 and game.selection[0] == worker, "Shift selection of a friendly farmer replaces a neutral mineral selection")
	game.select_entities([worker])
	await _click(_screen(mine), MOUSE_BUTTON_RIGHT)
	_check(worker.order == BattleUnit.Order.GATHER and worker.work_target == mine, "native right click on mineral starts the farmer's gathering order")
	_freeze(worker, false)
	_check(await _until(func(): return worker._working, 5.0), "farmer reaches an actual authored mineral using battlefield navigation")
	before_gold = game.gold
	_check(await _until(func(): return game.gold == before_gold + 3, 3.6), "completed gathering signal credits exactly three gold to the real game economy")
	await _key(KEY_S)
	_freeze(worker)
	await _construction_case(worker, second, mine)
	await _rally_and_selection_case(mine)
	await _recruit_obstruction_case()
	await _finish()

func _construction_case(worker: Node3D, second: Node3D, mine: Node3D) -> void:
	game.select_entities([worker])
	var before_gold: int = game.gold
	await _key(KEY_V)
	_check(game.build_mode and game.get_node("BuildingPreview").visible, "native V opens the tower placement preview")
	await _click(game.camera.unproject_position(mine.global_position))
	_check(game.gold == before_gold and _sites().is_empty() and game.build_mode, "invalid mineral-overlap placement keeps the preview and spends no gold")
	var first_position: Vector3 = _find_site(worker.global_position)
	_check(first_position.y == 0.0, "finds a genuinely legal authored-map tower footprint")
	if first_position.y != 0.0:
		return
	await _focus(first_position)
	await _click(game.camera.unproject_position(first_position), MOUSE_BUTTON_LEFT, true)
	var sites: Array[Node] = _sites()
	_check(sites.size() == 1 and game.gold == before_gold - 100, "native Shift click creates one foundation and reserves one hundred gold")
	if sites.size() != 1:
		return
	var first: Node3D = sites[0]
	_check(worker.order == BattleUnit.Order.BUILD and worker.work_target == first and game.build_mode, "first Shift placement assigns construction and keeps continuous placement active")
	await _sync()
	var second_position: Vector3 = _find_site(first_position, 8.0)
	_check(second_position.y == 0.0, "finds a second footprint outside the first tower clearance")
	if second_position.y != 0.0:
		return
	await _focus(second_position)
	await _click(game.camera.unproject_position(second_position), MOUSE_BUTTON_LEFT, true)
	sites = _sites()
	_check(sites.size() == 2 and game.gold == before_gold - 200, "second Shift placement creates and charges a distinct tower")
	if sites.size() != 2:
		return
	var queued: Node3D = sites[1]
	_check(worker.work_target == first and worker.waypoint_queue.size() == 1 and worker.waypoint_queue[0].entity == queued, "two Shift towers retain one active and one queued construction task")
	await _key(KEY_ESCAPE)
	_check(not game.build_mode and not paused and not game.get_node("BuildingPreview").visible, "Escape closes construction mode without pausing or deleting foundations")
	game.select_entities([queued])
	await _key(KEY_DELETE)
	_check(not queued.alive and game.gold == before_gold - 100, "native Delete cancels the untouched queued foundation and refunds one hundred gold")
	await _key(KEY_DELETE)
	_check(game.gold == before_gold - 100, "repeated Delete cannot refund a canceled foundation twice")
	game.select_entities([worker])
	_freeze(worker, false)
	_check(await _until(func(): return worker._working, 14.0), "builder reaches a real foundation around the newly carved navigation footprint")
	await _wait(3.0)
	await _key(KEY_S)
	_freeze(worker)
	var retained: float = first.construction_progress
	_check(retained > 0.1 and retained < 0.3, "native Stop pauses an actually progressing tower")
	second.position = first.global_position + Vector3(3.6, 0, 0)
	await _sync()
	game.select_entities([second])
	await _focus(first.global_position)
	await _click(_screen(first, 2.5), MOUSE_BUTTON_RIGHT)
	_check(second.order == BattleUnit.Order.BUILD and second.work_target == first, "native right click assigns another farmer to the existing paused site")
	_freeze(second, false)
	_check(await _until(func(): return first.construction_progress > retained, 5.0), "replacement farmer resumes accumulated construction rather than restarting it")
	_check(await _until(func(): return first.is_constructed, 20.0), "real input-assigned farmer completes the remaining twenty-second construction")
	_freeze(second)
	game.select_entities([first])
	var complete_gold: int = game.gold
	await _key(KEY_DELETE)
	_check(first.alive and first.is_constructed and game.gold == complete_gold, "Delete never demolishes or refunds a completed defensive tower")
	_check(game.hud.selected_stats.text.contains("无法进驻"), "completed tower details explicitly show the no-garrison rule")
	await _key(KEY_DELETE, false, true)
	_check(not first.alive and game.gold == complete_gold, "native Ctrl+Delete demolishes a completed player tower without any refund")
	await _key(KEY_DELETE, false, true)
	_check(not first.alive and game.gold == complete_gold, "repeated Ctrl+Delete cannot duplicate demolition or award gold")
	await _sync()
	_check(game.get_node("ConstructionNavigation").walkable_footprint(first.global_position), "demolition restores the tower footprint to native navigation")

func _rally_and_selection_case(mine: Node3D) -> void:
	await _key(KEY_B)
	await _focus(mine.global_position)
	await _click(_screen(mine), MOUSE_BUTTON_RIGHT)
	_check(game.rally_mine == mine and game.headquarters in game.selection, "headquarters right click stores a mineral rally target")
	var before_gold: int = game.gold
	var original: Array[Node] = get_nodes_in_group("friendly_units")
	await _key(KEY_U)
	var worker: Node3D = _latest_farmer(original)
	_check(worker != null and game.gold == before_gold - 50 and worker.work_target == mine and worker.order == BattleUnit.Order.GATHER, "newly recruited farmer automatically receives the headquarters mineral order")
	if worker != null:
		_freeze(worker)
	await _key(KEY_G)
	var military_count: int = get_nodes_in_group("friendly_units").filter(func(unit: Node): return unit.alive and unit.unit_type != "farmer").size()
	_check(game.selection.size() == military_count and game.own_selected_workers().is_empty(), "native G selects every military unit and leaves all farmers at work")
	await _key(KEY_PERIOD)
	var first_idle: Node3D = game.selection[0] if game.selection.size() == 1 else null
	_check(first_idle != null and first_idle.unit_type == "farmer" and first_idle.order == BattleUnit.Order.IDLE, "period key finds an actual idle farmer")
	_check(first_idle != null and game.camera_rig.destination.distance_to(first_idle.global_position) < 0.01, "idle-worker shortcut focuses the camera on its selected farmer")
	await _key(KEY_PERIOD)
	_check(game.selection.size() == 1 and game.selection[0] != first_idle and game.selection[0].unit_type == "farmer", "repeated idle-worker shortcut cycles through available farmers")

func _fixture_tower(at: Vector3) -> Node3D:
	# These authored scene instances deliberately occupy exits; placement itself
	# was tested above through native input, so fixtures need not spend test gold.
	var site: Node3D = game.BUILDING_SCENE.instantiate()
	site.building_type = "defense_tower"
	site.team = 0
	site.under_construction = true
	site.position = at
	game.get_node("Buildings").add_child(site)
	site.set_physics_process(false)
	return site

func _recruit_obstruction_case() -> void:
	await _key(KEY_B)
	game.rally_mine = null
	var primary_exit: Vector3 = game.find_recruit_position("farmer")
	_check(primary_exit.is_finite(), "headquarters has a verified clear initial recruitment exit")
	if not primary_exit.is_finite():
		return
	var blocker: Node3D = _fixture_tower(primary_exit)
	game.get_node("ConstructionNavigation").refresh()
	var before_gold: int = game.gold
	var original: Array[Node] = get_nodes_in_group("friendly_units")
	# Submit the recruitment key in the same frame as the new foundation.
	await _key(KEY_U)
	var worker: Node3D = _latest_farmer(original)
	_check(worker != null and game.gold == before_gold - 50, "same-frame tower obstruction redirects recruitment to another safe exit")
	if worker != null:
		_freeze(worker)
		await _sync()
		var clearance: float = worker.global_position.distance_to(blocker.get_attack_position(worker.global_position))
		_check(clearance > worker.radius + 0.09, "recruited farmer never overlaps the tower covering the former spawn point")
		var shape := SphereShape3D.new()
		shape.radius = worker.radius + 0.1
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = shape
		query.collision_mask = 6 | 128
		query.exclude = [worker.get_rid()]
		query.transform.origin = worker.global_position + Vector3.UP * maxf(shape.radius, 0.9)
		_check(game.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty(), "actual spawn collision volume clears nearby units, buildings and minerals")
		_check(game.get_node("ConstructionNavigation").contains_walkable_point(worker.global_position), "replacement spawn remains on the currently carved navigation grid")
	var fixtures: Array[Node3D] = [blocker]
	# Twelve full tower footprints surround the HQ in a continuous square ring.
	# This blocks its perimeter as a whole without copying the candidate algorithm.
	for side: float in [-8.5, 8.5]:
		for across: float in [-8.5, -2.833333, 2.833333, 8.5]:
			fixtures.append(_fixture_tower(game.headquarters.global_position + Vector3(side, 0, across)))
		for across: float in [-2.833333, 2.833333]:
			fixtures.append(_fixture_tower(game.headquarters.global_position + Vector3(across, 0, side)))
	game.get_node("ConstructionNavigation").refresh()
	await _sync()
	_check(not game.find_recruit_position("farmer").is_finite(), "completely surrounded headquarters exposes no valid recruitment position")
	before_gold = game.gold
	var before_count: int = game.player_count()
	await _key(KEY_U)
	_check(game.gold == before_gold and game.player_count() == before_count, "failed native recruitment with all exits blocked neither spends gold nor creates a unit")
	await _key(KEY_U)
	_check(game.gold == before_gold and game.player_count() == before_count, "repeated blocked recruitment remains free of charges and phantom units")
	game.select_entities([game.headquarters])
	before_gold = game.gold
	await _key(KEY_DELETE, false, true)
	_check(game.headquarters.alive and game.gold == before_gold, "tower demolition shortcut cannot destroy the headquarters")
	for fixture: Node3D in fixtures:
		fixture.queue_free()
	await _sync()
	game.get_node("ConstructionNavigation").refresh()
	await _sync()
	_check(game.find_recruit_position("farmer").is_finite(), "removing the obstruction restores usable recruitment exits")

func _finish() -> void:
	if ending:
		return
	ending = true
	var report := FileAccess.open("res://artifacts/economy_input_results.json", FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks": checks, "failures": failures}, "  "))
	report.close()
	print("ECONOMY_INPUT ", checks, " checks; ", failures.size(), " failures")
	await game.prepare_shutdown()
	quit(0 if failures.is_empty() else 1)
