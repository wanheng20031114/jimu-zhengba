extends SceneTree
## Actual six-worker movement, stone collision and authored pickaxe facing.
var game: Node3D
var checks: int = 0
var failures: Array[String] = []
var harvested: Dictionary = {}
var harvest_ticks: Dictionary = {}

func _initialize() -> void:
	Engine.max_fps = 120
	if DisplayServer.get_name() != "headless":
		root.set_flag(Window.FLAG_NO_FOCUS, true)
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func _on_gathered(worker: BattleUnit, amount: int) -> void:
	harvested[worker.entity_id] = int(harvested.get(worker.entity_id, 0)) + amount
	if not harvest_ticks.has(worker.entity_id):
		harvest_ticks[worker.entity_id] = []
	harvest_ticks[worker.entity_id].append(Engine.get_physics_frames())

func _mine_case(mine: ResourceVein, label: String) -> void:
	var workers: Array[BattleUnit] = []
	harvested.clear()
	harvest_ticks.clear()
	for slot: Marker3D in mine.get_node("GatherSlots").get_children():
		var outward := (slot.global_position - mine.global_position).normalized()
		var worker: BattleUnit = game.spawn_unit("farmer", 0, mine.global_position + outward * 6.5)
		worker.gathered.connect(_on_gathered)
		worker.issue_gather(mine)
		workers.append(worker)
	check(mine.occupied_slots() == 6, label + "_all_six_slots_claimed")
	var deadline := Time.get_ticks_msec() + 18000
	while not workers.all(func(worker): return int(harvested.get(worker.entity_id, 0)) >= BalanceCatalog.ECONOMY.mining_gold * 2) and Time.get_ticks_msec() < deadline:
		await physics_frame
		await process_frame
	check(harvested.size() == 6, label + "_all_six_workers_reach_contact_and_complete_a_real_cycle")
	if "--capture-mining" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless":
		game.camera_rig.focus_at(mine.global_position, true)
		game.camera_rig.zoom_target = 16
		game.camera.size = 16
		game.hud.hide()
		game.get_node("FogOfWar")._recompute()
		game.get_node("FogOfWar").apply_visibility(0)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png("res://artifacts/mining-contact-0.8.1.png") == OK, "native_mining_contact_capture_saved")
	var query := PhysicsShapeQueryParameters3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = BalanceCatalog.unit("farmer").radius * 0.85
	capsule.height = 1.8
	query.shape = capsule
	query.collision_mask = 3
	var space := game.get_world_3d().direct_space_state
	for worker: BattleUnit in workers:
		var ticks: Array = harvest_ticks.get(worker.entity_id, [])
		check(ticks.size() >= 2 and (int(ticks[1]) - int(ticks[0])) == roundi(BalanceCatalog.ECONOMY.mining_seconds * Engine.physics_ticks_per_second),
			label + "_worker_%d_two_cycles_preserve_native_%d_tps_cadence" % [worker.entity_id, Engine.physics_ticks_per_second])
		var contact := mine.get_work_position(worker.global_position, worker)
		if worker.global_position.distance_to(contact) > ResourceVein.WORK_REACH + 0.025:
			print("MINING_APPROACH_DIAGNOSTIC ", JSON.stringify({"case": label, "id": worker.entity_id,
				"position": str(worker.global_position), "contact": str(contact), "distance": worker.global_position.distance_to(contact),
				"order": worker.order_name, "velocity": str(worker.velocity),
				"nav_finished": game.get_node("PathBudget").is_finished(worker), "nav_pending": game.get_node("PathBudget").has_pending(worker),
				"path": str(worker.navigation_agent.get_current_navigation_path())}))
		check(worker.global_position.distance_to(contact) <= ResourceVein.WORK_REACH + 0.025,
			label + "_worker_%d_reaches_authored_contact" % worker.entity_id)
		query.transform.origin = worker.global_position + Vector3.UP
		check(space.intersect_shape(query, 1).is_empty(), label + "_worker_%d_does_not_enter_stone_collision" % worker.entity_id)
		var inward := (mine.global_position - worker.global_position).normalized()
		check((-worker.model_pivot.global_basis.z).dot(inward) > 0.98, label + "_worker_%d_faces_pickaxe_toward_mine" % worker.entity_id)
		var ray := PhysicsRayQueryParameters3D.create(worker.global_position + Vector3.UP * 0.8, mine.global_position + Vector3.UP * 0.8, 128)
		var hit := space.intersect_ray(ray)
		check(not hit.is_empty() and worker.global_position.distance_to(Vector3(hit.position.x, worker.global_position.y, hit.position.z)) < 1.45,
			label + "_worker_%d_pickaxe_is_close_to_visible_rock_face" % worker.entity_id)
	for first: int in workers.size():
		for second: int in range(first + 1, workers.size()):
			check(workers[first].global_position.distance_to(workers[second].global_position) > 0.84, label + "_six_workers_keep_separate_body_space")
	for worker: BattleUnit in workers:
		worker.stop()
		worker.queue_free()
	await process_frame
	await physics_frame
	check(mine.occupied_slots() == 0, label + "_leaving_releases_all_six_slots")

func _run() -> void:
	for mode: String in ["1v1", "ffa"]:
		if "--ffa-only" in OS.get_cmdline_user_args() and mode != "ffa":
			continue
		Engine.physics_ticks_per_second = 30 if mode == "1v1" else 60
		root.get_node("Session").start_offline(mode)
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
		var navigation: ConstructionNavigation = game.get_node("ConstructionNavigation")
		while navigation.is_rebuilding():
			await physics_frame
		await physics_frame
		await physics_frame
		var mines: Array[Node] = game.map_instance.get_node("Resources").get_children()
		await _mine_case(mines[0], mode + "_first_rotation")
		if not "--capture-mining" in OS.get_cmdline_user_args():
			await _mine_case(mines[1 if mode == "ffa" else 3], mode + "_second_rotation")
		await game.prepare_shutdown()
		game.queue_free()
		await process_frame
		await process_frame
		if "--capture-mining" in OS.get_cmdline_user_args():
			break
	Engine.physics_ticks_per_second = 30
	print("MINING_CONTACT_RESULTS " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)
