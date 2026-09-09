extends SceneTree
## Actual unit/building models validate vision, frozen memory and network roundtrips.
const UNIT: PackedScene = preload("res://scenes/unit.tscn")
const BUILDING: PackedScene = preload("res://scenes/building.tscn")
const MINE: PackedScene = preload("res://scenes/resource_vein.tscn")
const FOG: PackedScene = preload("res://scenes/fog_of_war.tscn")
const PROJECTILE: PackedScene = preload("res://scenes/projectile.tscn")
var host: Node3D
var fog: Node3D
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func _unit(kind: String, owner: int, at: Vector3) -> Node3D:
	var unit: Node3D = UNIT.instantiate()
	unit.unit_type = kind
	unit.owner_id = owner
	unit.alliance_id = host.get_player(owner).alliance_id
	unit.position = at
	host.get_node("Units").add_child(unit)
	unit.set_physics_process(false)
	unit.navigation_agent.avoidance_enabled = false
	return unit

func _building(kind: String, owner: int, at: Vector3, progress: float = 1.0) -> Node3D:
	var building: Node3D = BUILDING.instantiate()
	building.building_type = kind
	building.owner_id = owner
	building.under_construction = progress < 1.0
	building.position = at
	host.get_node("Buildings").add_child(building)
	building.set_physics_process(false)
	building.construction_progress = progress
	building._update_construction_visuals()
	return building

func _run() -> void:
	change_scene_to_file("res://tests/fog_test_host.tscn")
	await scene_changed
	host = current_scene
	fog = host.fog
	var own_hq: Node3D = _building("headquarters", 0, Vector3(-40, 0, -20))
	var scout: Node3D = _unit("archer", 2, Vector3(-5, 0, 20))
	var enemy_hq: Node3D = _building("headquarters", 1, Vector3(44, 0, 24))
	var enemy: Node3D = _unit("knight", 1, Vector3(40, 0, 18))
	var mine: ResourceVein = MINE.instantiate()
	mine.position = Vector3(0, 0, 18)
	host.get_node("Resources").add_child(mine)
	fog.configure(host, Vector2(128, 112))
	fog.apply_visibility(0)
	_check_circle_cells()
	_check(fog.grid_size == Vector2i(64, 56), "128x112 map uses 3584 two-meter cells per alliance")
	_check(fog.position_visible(0, own_hq.position) and fog.position_visible(2, own_hq.position), "allied owners share headquarters vision")
	_check(fog.position_visible(0, scout.position) and fog.position_visible(2, scout.position), "allied scout grants shared vision")
	_check(not fog.position_visible(1, scout.position) and fog.position_visible(1, enemy_hq.position), "opposing alliance has an independent mask")
	_check(not enemy.visible and not enemy_hq.visible, "unexplored live enemy army and headquarters are hidden")
	_check(mine.visible and fog.explored(0, mine.position), "visible neutral mine is explored")
	_check(fog.cell_state(0, Vector3(70, 0, 0)) == 0 and fog.cell_state(0, Vector3(-70, 0, 0)) == 0, "positions outside map boundaries remain unknown")
	var old: Vector3 = scout.position
	scout.position = Vector3(-35, 0, 24)
	fog.tick(0.2)
	fog.apply_visibility(0)
	_check(fog.cell_state(0, old) == 1 and not fog.position_visible(0, old), "departed scout leaves remembered terrain without current vision")
	_check(mine.visible and not fog.entity_visible(0, mine), "known mine model persists without claiming current visibility")
	await _building_memory_case(scout)
	await _snapshot_case()
	_projectile_visibility_case(scout, enemy)
	fog.reveal_alliance_buildings(1)
	fog.apply_visibility(0)
	_check(fog.entity_visible(0, enemy_hq) and enemy_hq.visible, "permanent building reveal includes headquarters")
	_check(not fog.entity_visible(0, enemy) and not fog.position_visible(0, enemy.position), "building reveal never reveals nearby troops or their terrain cells")
	var rebuilt_hq: Node3D = _building("headquarters", 1, Vector3(42, 0, -26), 0.1)
	fog.apply_entity_visibility(0, rebuilt_hq)
	_check(rebuilt_hq.visible and fog.entity_visible(0, rebuilt_hq), "new headquarters site inherits permanent alliance building reveal immediately")
	var revealed_site: Node3D = _building("academy", 1, Vector3(54, 0, 45), 0.2)
	var revealed_id: int = revealed_site.entity_id
	fog.tick(0.2)
	_check(fog.last_seen_buildings(0).has(revealed_id), "permanent reveal records newly built sites outside unit vision")
	revealed_site.queue_free()
	await process_frame
	await process_frame
	fog.tick(0.2)
	_check(not fog.last_seen_buildings(0).has(revealed_id), "destroyed permanently exposed buildings do not leave false minimap memories")
	var rev: int = fog.revision
	for tick: int in range(5): fog.tick(1.0 / 30.0)
	_check(fog.revision == rev, "fog does not refresh above five Hz")
	fog.tick(1.0 / 30.0)
	_check(fog.revision == rev + 1, "six 30-TPS ticks trigger one fog refresh")
	if "--capture" in OS.get_cmdline_user_args():
		fog.apply_visibility(0)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		var capture: Image = root.get_texture().get_image()
		capture.save_png("res://artifacts/fog_visual.png")
		print("FOG_CAPTURE artifacts/fog_visual.png")
	var report := {"checks": checks, "failures": failures}
	var file := FileAccess.open("res://artifacts/fog_state_results.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("FOG_STATE ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _building_memory_case(scout: Node3D) -> void:
	var factory: Node3D = _building("factory", 1, Vector3(32, 0, 20), 0.35)
	factory.hp = 600
	scout.position = Vector3(20, 0, 20)
	fog.tick(0.2)
	fog.apply_visibility(0)
	_check(factory.visible and fog.entity_visible(0, factory), "approaching scout discovers an enemy factory site")
	var id: int = factory.entity_id
	var first: Dictionary = fog.last_seen_buildings(0)[id]
	_check(first.construction_progress == 0.35 and not first.has("hp") and not first.has("max_hp"), "observation stores construction pose without health data")
	_check(fog.last_seen_buildings(2)[id] == first, "allied owners share the same building observation")
	factory.set_selected(true)
	scout.position = Vector3(-35, 0, 24)
	fog.tick(0.2)
	fog.apply_visibility(0)
	_check(not factory.visible and not factory.selected and not factory.health_bar.is_visible_in_tree(), "hidden building also hides its health bar and selection")
	_check(fog._memory_nodes.has(id), "out-of-vision building has a separate remembered model")
	var memory: Node3D = fog._memory_nodes[id]
	var scale_before: Vector3 = memory.scale
	factory.construction_progress = 0.9
	factory.hp = 1700
	factory._update_construction_visuals()
	fog.tick(0.2)
	fog.apply_visibility(0)
	_check(fog.last_seen_buildings(0)[id] == first and memory.scale == scale_before, "hidden construction and health changes never update remembered model")
	_check(memory.get_script() == null and memory.process_mode == Node.PROCESS_MODE_DISABLED, "remembered model is script-free and process-disabled")
	var collision_count: int = 0
	var simulation_count: int = 0
	for node: Node in memory.find_children("*", "Node", true, false):
		if node is CollisionObject3D or node is CollisionShape3D: collision_count += 1
		if node is AnimationPlayer or node is AudioStreamPlayer3D or node is GPUParticles3D or node is CPUParticles3D: simulation_count += 1
	_check(collision_count == 0 and simulation_count == 0, "remembered models contain no collision, animation, sound or particles")
	_check(memory.find_children("*", "MeshInstance3D", true, false).all(func(mesh: MeshInstance3D) -> bool: return mesh.material_override == fog.memory_material), "frozen memory uses a time-independent shared material")
	var saved: Dictionary = fog.last_seen_buildings(0)
	saved[id]["construction_progress"] = 0.99
	_check(fog.last_seen_buildings(0)[id].construction_progress == 0.35, "external minimap snapshots cannot mutate internal fog memory")
	scout.position = Vector3(20, 0, 20)
	fog.tick(0.2)
	fog.apply_visibility(0)
	_check(factory.visible and not fog._memory_nodes.has(id) and fog.last_seen_buildings(0)[id].construction_progress == 0.9, "rescouting replaces memory with the current live model")
	scout.position = Vector3(-35, 0, 24)
	fog.tick(0.2)
	fog.apply_visibility(0)
	factory.queue_free()
	await process_frame
	await process_frame
	fog.tick(0.2)
	fog.apply_visibility(0)
	_check(fog.last_seen_buildings(0).has(id), "unobserved destruction does not erase remembered buildings")
	scout.position = Vector3(20, 0, 20)
	fog.tick(0.2)
	fog.apply_visibility(0)
	_check(not fog.last_seen_buildings(0).has(id) and not fog._memory_nodes.has(id), "seeing the empty site removes obsolete building memory")
	scout.position = Vector3(-35, 0, 24)
	fog.tick(0.2)

func _snapshot_case() -> void:
	# Capture a hidden building so network restoration exercises static memory creation.
	var enemy_academy: Node3D = _building("academy", 1, Vector3(3, 0, -25), 0.45)
	var scout: Node3D = _unit("archer", 0, Vector3(0, 0, -25))
	fog.tick(0.2)
	scout.position = Vector3(-40, 0, -25)
	fog.tick(0.2)
	var packet: Dictionary = fog.snapshot_for(0)
	_check(packet.cells is String and packet.cells.length() == 4780, "3584 cell states serialize into one bounded base64 value")
	var serialized: String = JSON.stringify(packet)
	var decoded: Dictionary = JSON.parse_string(serialized)
	_check(not serialized.contains("\"hp\"") and not serialized.contains("\"max_hp\""), "wire fog packet contains no building health")
	if "--capture" in OS.get_cmdline_user_args():
		fog.apply_visibility(0)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://artifacts/fog_memory_visual.png")
		print("FOG_MEMORY_CAPTURE artifacts/fog_memory_visual.png")
	host.is_authority = false
	var client: Node3D = FOG.instantiate()
	host.add_child(client)
	client.configure(host, Vector2(128, 112))
	_check(client.apply_snapshot(decoded), "client accepts a primitive JSON fog snapshot")
	client.apply_visibility(0)
	_check(client._memory_nodes.has(enemy_academy.entity_id), "client snapshot restores a frozen remembered academy without hidden live state")
	for x: int in range(-62, 63, 8):
		for z: int in range(-54, 55, 8):
			var at := Vector3(x, 0, z)
			_check(client.cell_state(0, at) == fog.cell_state(0, at), "client fog cell agrees at %d,%d" % [x, z])
	var current_revision: int = client.revision
	client.tick(60.0)
	_check(client.revision == current_revision, "client never recalculates fog from replicated world entities")
	_check(not client.apply_snapshot(decoded), "duplicate or older snapshots cannot roll fog backward")
	var malformed: Dictionary = decoded.duplicate(true)
	malformed.revision += 1
	malformed.cells = "AAAA"
	_check(not client.apply_snapshot(malformed), "incorrect base64 grid length is rejected")
	malformed.cells = "?".repeat(4780)
	_check(not client.apply_snapshot(malformed), "invalid base64 alphabet is rejected without invoking the decoder")
	malformed = decoded.duplicate(true)
	malformed.revision += 1
	malformed.width = 65
	_check(not client.apply_snapshot(malformed), "mismatched map grid dimensions are rejected")
	_check(not client.apply_snapshot({}), "missing fog fields are rejected without script errors")
	malformed = decoded.duplicate(true)
	malformed.revision += 1
	malformed.buildings = ["invalid"]
	_check(not client.apply_snapshot(malformed), "non-dictionary building memories are rejected")
	malformed.buildings = [{}]
	_check(not client.apply_snapshot(malformed), "missing building-memory fields are rejected")
	malformed = decoded.duplicate(true)
	malformed.revision += 1
	malformed.owner_id = 999
	_check(not client.apply_snapshot(malformed), "unrecognized recipient owners are rejected before lookup")
	malformed = decoded.duplicate(true)
	malformed.revision += 1
	malformed.buildings[0].position = [0, 0, 100000]
	_check(not client.apply_snapshot(malformed), "out-of-map building memories are rejected")
	malformed = decoded.duplicate(true)
	malformed.revision += 1
	malformed.buildings[0].hp = 777
	_check(client.apply_snapshot(malformed) and not client.last_seen_buildings(0).values()[0].has("hp"), "unrecognized live-health fields never enter client memories")
	client.queue_free()
	await process_frame
	await process_frame
	host.is_authority = true

func _projectile_visibility_case(source: Node3D, target: Node3D) -> void:
	var projectile: BattleProjectile = PROJECTILE.instantiate()
	host.get_node("Effects").add_child(projectile)
	projectile.set_physics_process(false)
	var payload: DamagePayload = DamageResolver.snapshot(source.get_combat_definition(), 0, source.owner_id, source.alliance_id)
	projectile.initialize(source, target, payload, "arrow")
	_check(projectile.visible, "projectile launches visibly inside allied vision")
	projectile._physics_process(projectile._duration * 0.65)
	_check(not projectile.visible and projectile._active, "projectile disappears into fog without stopping its authoritative flight")
	var hp_before: float = target.hp
	projectile._physics_process(projectile._duration)
	_check(not projectile.visible and target.hp == hp_before - 8, "hidden homing arrow still resolves its original 8 cavalry damage once")
	projectile.queue_free()

func _check_circle_cells() -> void:
	for alliance: int in range(2):
		var matches: bool = true
		for z: int in range(56):
			for x: int in range(64):
				var center := Vector3((x + 0.5) * 2 - 64, 0, (z + 0.5) * 2 - 56)
				var visible: bool = false
				for entity: Node3D in get_nodes_in_group("entities"):
					if entity.alliance_id != alliance: continue
					var definition: CombatDefinition = entity.get_combat_definition()
					var radius: float = maxf(definition.range + entity.radius, 12.0) if entity.is_in_group("buildings") else (definition as UnitDefinition).sight
					var offset: Vector3 = entity.global_position - center
					offset.y = 0
					visible = visible or offset.length_squared() <= radius * radius
				if (fog._state(alliance, center) == 2) != visible: matches = false
		_check(matches, "optimized circle row spans exactly match cell-center sight circles for alliance %d" % alliance)
