extends SceneTree
## Native main-map wall contact regression: every face/corner, cavalry, demolition queue.
var game: Node3D
var failures: Array[String] = []
var check_count: int = 0
var done: bool = false

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, label: String) -> void:
	check_count += 1
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures.append(label)

func _run() -> void:
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	create_timer(75.0).timeout.connect(func(): failures.append("contact test deadline"); _finish())
	seed(17314)
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.get_node("EnemyTimer").stop()
	game.get_node("IncomeTimer").stop()
	# Let the main scene finish its initial native render before replacing fixtures.
	await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
	for unit: Node in get_nodes_in_group("units"):
		unit.queue_free()
	for building: Node in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
	await physics_frame
	await physics_frame
	await physics_frame
	var fort: Node3D = game.get_node("Buildings/WestBarracks")
	var offsets: Array[Vector3] = [
		Vector3(0, 0, 5.5), Vector3(0, 0, -5.5),
		Vector3(6, 0, 0), Vector3(-6, 0, 0),
		Vector3(6, 0, 5.5), Vector3(-6, 0, 5.5),
		Vector3(6, 0, -5.5), Vector3(-6, 0, -5.5)
	]
	for kind: String in ["swordsman", "knight"]:
		for direction: int in range(offsets.size()):
			var fighter: Node3D = game.spawn_unit(kind, 0, fort.global_position + offsets[direction])
			var before_hp: float = fort.hp
			fighter.issue_attack(fort)
			var deadline: int = Time.get_ticks_msec() + 4000
			while fort.hp == before_hp and Time.get_ticks_msec() < deadline and not done:
				await physics_frame
			if done:
				return
			_check(fort.hp < before_hp, "%s face/corner %d reaches the physical wall" % [kind, direction])
			_check(fighter._within_attack_range(fort), "%s face/corner %d retains real melee range" % [kind, direction])
			var local_pos: Vector3 = fort.to_local(fighter.global_position)
			_check(absf(local_pos.x) >= 3.0 or absf(local_pos.z) >= 2.5, "%s face/corner %d remains outside wall collision" % [kind, direction])
			print("CONTACT ", kind, " ", direction, " pos ", fighter.global_position, " hp ", fort.hp, " nav_finished ", fighter.navigation_agent.is_navigation_finished(), " goal ", fighter.navigation_agent.target_position)
			fighter.queue_free()
			await physics_frame
			await physics_frame
	var troops: Array[Node3D] = []
	for index: int in range(8):
		var fighter: Node3D = game.spawn_unit("knight", 0, fort.global_position + Vector3(-3.0 + float(index % 4) * 2.0, 0, 5.5 + float(index / 4) * 2.0))
		fighter.issue_attack(fort)
		fighter.queue_move(fort.global_position + Vector3(0, 0, -6))
		troops.append(fighter)
	var deadline: int = Time.get_ticks_msec() + 11000
	while fort.alive and Time.get_ticks_msec() < deadline and not done:
		await physics_frame
	_check(not fort.alive, "native melee demolishes the building")
	_check(game.get_node("ClearedNavigation/WestBarracks").enabled, "demolition reconnects native navigation")
	deadline = Time.get_ticks_msec() + 6000
	var crossed := false
	while not crossed and Time.get_ticks_msec() < deadline and not done:
		for fighter: Node3D in troops:
			crossed = crossed or fighter.global_position.z < fort.global_position.z - 3.0
		await physics_frame
	_check(crossed, "queued commands cross the former wall after target destruction")
	await _finish()

func _finish() -> void:
	if done:
		return
	done = true
	for entity: Node in get_nodes_in_group("entities"):
		entity.set_physics_process(false)
		if entity is BattleUnit:
			entity.navigation_agent.avoidance_enabled = false
			entity.get_node("AttackWindup").stop()
	for effect: Node in game.get_node("Effects").get_children():
		if effect is BattleProjectile:
			effect.set_physics_process(false)
	for player: Node in game.get_node("Audio").get_children():
		player.stop()
	await create_timer(3.2).timeout
	var report := FileAccess.open("res://artifacts/building_contact.json", FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks": check_count, "failures": failures}, "  "))
	report.close()
	print("BUILDING_CONTACT ", check_count, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
