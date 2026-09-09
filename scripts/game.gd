extends Node3D

const UNIT_SCENE: PackedScene = preload("res://scenes/unit.tscn")
const PROJECTILE_SCENE: PackedScene = preload("res://scenes/projectile.tscn")
const EFFECT_SCENE: PackedScene = preload("res://scenes/battle_effect.tscn")
const BUILDING_SCENE: PackedScene = preload("res://scenes/building.tscn")
const UNIT_TYPES := ["swordsman", "archer", "knight", "catapult", "cannon", "farmer"]
const UNIT_NAMES := {"swordsman": "剑士", "archer": "弓箭手", "knight": "骑士", "catapult": "投石车", "cannon": "加农炮", "farmer": "农民"}
const TOWER_COST := 100
const MAX_ARMY: int = 160
const EFFECT_SOUNDS: Dictionary = {"hit": &"sword_hit", "wood_hit": &"wood_hit", "stone_chip": &"stone_chip", "arrow_hit": &"arrow_hit", "muzzle": &"cannon_shot", "explosion": &"explosion", "stone_hit": &"stone_hit", "collapse": &"collapse"}

@onready var camera_rig = $CameraRig
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var hud = $HUD/Interface
@onready var overlay = $HUD/SelectionOverlay
@onready var headquarters = $Buildings/Headquarters
@onready var unit_container: Node3D = $Units
@onready var effect_container: Node3D = $Effects

var players: Array[PlayerState] = [PlayerState.new(0, 0), PlayerState.new(1, 1)]
var local_owner_id: int = 0
var is_authority: bool = true
var map_size := Vector2(84, 84)
var entities_by_id: Dictionary = {}
var _next_entity_id: int = 1
var gold: int:
	get: return get_player(local_owner_id).gold
	set(value): get_player(local_owner_id).gold = value
var elapsed: float = 0.0
var simulation_tick: int = 0
var kills: int = 0
var buildings_destroyed: int = 0
var selection: Array[Node3D] = []
var control_groups: Dictionary = {}
var rally_point := Vector3(-10, 0, 24)
var attack_mode: bool = false
var dragging: bool = false
var drag_start := Vector2.ZERO
var pointer_now := Vector2.ZERO
var shift_drag: bool = false
var _last_click_time: float = -1.0
var _last_click_entity: Node3D
var _last_group: int = -1
var _last_group_time: float = -1.0
var _spawn_index: int = 0
var _ui_accumulator: float = 0.0
var _enemy_wave: int = 0
var finished: bool = false
var game_started: bool = false
var photo_mode: bool = false
var last_notification: String = ""
var tests_running: bool = false
var _closing: bool = false
var build_mode: bool = false
var _preview_time: float = 0.0
var _placement_query: PhysicsShapeQueryParameters3D
var _tower_serial: int = 0
var rally_mine: Node3D
var _idle_worker_index: int = 0
var build_kind: String = "defense_tower"
var command_bus: MatchCommands
var _outgoing_sequences: Dictionary = {}

func _ready() -> void:
	get_tree().auto_accept_quit = false
	command_bus = MatchCommands.new(self)
	hud.bind_game(self)
	for entity: Node3D in get_tree().get_nodes_in_group("entities"):
		entity.sound_requested.connect($Audio.play_world)
		if entity.is_in_group("units"):
			entity.gathered.connect(_on_gathered)
	var footprint := BoxShape3D.new()
	footprint.size = Vector3(4.4, 5.0, 4.4)
	_placement_query = PhysicsShapeQueryParameters3D.new()
	_placement_query.shape = footprint
	_placement_query.collision_mask = 6 | 128
	$ConstructionNavigation.refresh()
	$IncomeTimer.timeout.connect(_on_income)
	$EnemyTimer.timeout.connect(_on_enemy_wave)
	$IncomeTimer.start()
	$EnemyTimer.start()
	select_entities([headquarters])
	hud.toast("集结军队，夺回沙石镇", 5.0)
	hud.refresh()
	game_started = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	# Authored defenders keep their native IDLE order and engage approaching enemies.
	if "--smoke-test" in OS.get_cmdline_user_args():
		tests_running = true
		camera_rig.edge_scroll = false
		var test_script = load("res://tests/integration_test.gd")
		var runner = test_script.new()
		add_child(runner)
		runner.run(self)
	if "--ui-smoke" in OS.get_cmdline_user_args():
		tests_running = true
		camera_rig.edge_scroll = false
		var test_script = load("res://tests/ui_input_test.gd")
		var runner = test_script.new()
		runner.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(runner)
		runner.run(self)
	if "--capture" in OS.get_cmdline_user_args():
		camera_rig.edge_scroll = false
		await get_tree().create_timer(3.0).timeout
		await RenderingServer.frame_post_draw
		var screenshot := get_viewport().get_texture().get_image()
		var capture_path := "res://artifacts/battlefield.png" if OS.has_feature("editor") else "user://battlefield.png"
		screenshot.save_png(capture_path)
		print("CAPTURE_SAVED")
		await prepare_shutdown()
		get_tree().quit()

func _physics_process(delta: float) -> void:
	# One authoritative clock for the battle. Input only changes order intent;
	# movement, attacks and economic work consume it on the next native fixed tick.
	# Camera, selection feedback and portraits remain on the presentation clock.
	if not finished and is_authority:
		command_bus.tick()
		simulation_tick += 1
		elapsed += delta

func _process(delta: float) -> void:
	$RallyMarker.visible = is_instance_valid(headquarters) and headquarters.alive and headquarters in selection
	_ui_accumulator += delta
	if _ui_accumulator > 0.12:
		_ui_accumulator = 0.0
		_prune_selection()
		hud.refresh()
	if dragging:
		overlay.box_end = get_viewport().get_mouse_position()
		overlay.box_visible = overlay.box_start.distance_to(overlay.box_end) > 6.0
	if build_mode:
		if own_selected_workers().is_empty():
			set_build_mode(false)
		else:
			var at := snap_build_position(camera_rig.world_at(get_viewport().get_mouse_position()))
			$BuildingPreview.position = at
			_preview_time -= delta
			if _preview_time <= 0.0:
				_preview_time = 0.1
				$BuildingPreview.set_valid(placement_error(at).is_empty())

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.is_action_pressed("debug_gold"):
			debug_add_gold()
			get_viewport().set_input_as_handled()
			return
		if event.physical_keycode == KEY_F1:
			hud.toggle_help()
			get_viewport().set_input_as_handled()
			return
		if event.physical_keycode == KEY_F10:
			photo_mode = not photo_mode
			hud.visible = not photo_mode
			get_viewport().set_input_as_handled()
			return
		if event.physical_keycode == KEY_F11:
			var mode: DisplayServer.WindowMode = DisplayServer.window_get_mode()
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if mode == DisplayServer.WINDOW_MODE_FULLSCREEN else DisplayServer.WINDOW_MODE_FULLSCREEN)
			get_viewport().set_input_as_handled()
			return
		if event.physical_keycode == KEY_ESCAPE:
			if build_mode:
				set_build_mode(false)
			elif attack_mode:
				set_attack_mode(false)
			elif hud.help_visible():
				hud.toggle_help()
			else:
				toggle_pause()
			get_viewport().set_input_as_handled()
			return
	if get_tree().paused or finished:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
		camera_rig.dragging = event.pressed
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and camera_rig.dragging:
		camera_rig.drag_by(event.relative)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed and dragging:
		dragging = false
		overlay.box_visible = false
		_finish_selection(event.position)
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if get_tree().paused or finished:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_rig.zoom_by(-3.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_rig.zoom_by(3.0)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if build_mode:
				place_tower(camera_rig.world_at(event.position), event.shift_pressed)
			elif attack_mode:
				var entity := entity_at(event.position)
				if is_instance_valid(entity) and entity.alliance_id != get_player(local_owner_id).alliance_id:
					command_attack(entity)
				else:
					command_move(camera_rig.world_at(event.position), true, event.shift_pressed)
				set_attack_mode(false)
			else:
				dragging = true
				drag_start = event.position
				shift_drag = event.shift_pressed
				overlay.box_start = drag_start
				overlay.box_end = drag_start
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if build_mode:
				set_build_mode(false)
				return
			set_attack_mode(false)
			var entity := entity_at(event.position)
			if is_instance_valid(entity) and entity.is_in_group("resource_veins"):
				command_gather(entity, event.shift_pressed)
			elif is_instance_valid(entity) and entity is BattleBuilding and entity.owner_id == local_owner_id and not entity.is_constructed:
				command_build(entity, event.shift_pressed)
			elif is_instance_valid(entity) and entity.alliance_id != get_player(local_owner_id).alliance_id:
				command_attack(entity)
			else:
				command_move(camera_rig.world_at(event.position), false, event.shift_pressed)
	if event is InputEventKey and event.pressed and not event.echo:
		var key: Key = event.physical_keycode
		if key >= KEY_1 and key <= KEY_9:
			use_control_group(key - KEY_0, event.ctrl_pressed, event.shift_pressed)
			return
		match key:
			KEY_A: set_attack_mode(true)
			KEY_S: stop_selected()
			KEY_H: hold_selected()
			KEY_B, KEY_HOME: select_headquarters()
			KEY_G: select_army()
			KEY_SPACE: focus_selection()
			KEY_Q: recruit("swordsman")
			KEY_E: recruit("archer")
			KEY_R: recruit("knight")
			KEY_T: recruit("catapult")
			KEY_Y: recruit("cannon")
			KEY_U: recruit("farmer")
			KEY_V: set_build_mode(not build_mode)
			KEY_DELETE:
				if event.ctrl_pressed:
					demolish_selected_towers()
				else:
					cancel_selected_construction()
			KEY_PERIOD: select_idle_worker()
			KEY_P: toggle_pause()
			KEY_M:
				toggle_sound()

func entity_at(screen: Vector2) -> Node3D:
	var from := camera.project_ray_origin(screen)
	var ray := PhysicsRayQueryParameters3D.create(from, from + camera.project_ray_normal(screen) * 200.0, 6 | 128)
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if not hit.is_empty() and (hit.collider.is_in_group("entities") or hit.collider.is_in_group("resource_veins")) and hit.collider.alive:
		return hit.collider
	var closest: Node3D = null
	var best_distance: float = 28.0
	for entity in get_tree().get_nodes_in_group("units"):
		if not entity.alive or camera.is_position_behind(entity.global_position):
			continue
		var position_2d := camera.unproject_position(entity.global_position + Vector3.UP)
		var distance := position_2d.distance_to(screen)
		if distance < best_distance:
			closest = entity
			best_distance = distance
	return closest

func _finish_selection(at: Vector2) -> void:
	if at.distance_to(drag_start) > 6.0:
		var box := Rect2(drag_start, at - drag_start).abs()
		var picked: Array[Node3D] = []
		for unit in get_tree().get_nodes_in_group("units"):
			if unit.owner_id == local_owner_id and unit.alive and not camera.is_position_behind(unit.global_position):
				if box.has_point(camera.unproject_position(unit.global_position + Vector3(0, 0.7, 0))):
					picked.append(unit)
		select_entities(picked, shift_drag)
	else:
		var entity := entity_at(at)
		if is_instance_valid(entity):
			var now := Time.get_ticks_msec() / 1000.0
			if entity == _last_click_entity and now - _last_click_time < 0.30 and entity.is_in_group("units") and entity.owner_id == local_owner_id:
				var same: Array[Node3D] = []
				for unit in get_tree().get_nodes_in_group("units"):
					if unit.alive and unit.owner_id == local_owner_id and unit.unit_type == entity.unit_type and camera.is_position_in_frustum(unit.global_position):
						same.append(unit)
				select_entities(same, shift_drag)
			else:
				select_entities([entity], shift_drag, shift_drag)
			_last_click_entity = entity
			_last_click_time = now
		elif not shift_drag:
			select_entities([])

func select_entities(entities: Array, additive: bool = false, toggle: bool = false) -> void:
	# Resource/building inspection never becomes part of a troop selection group.
	if additive and entities.any(func(entity): return is_instance_valid(entity) and entity.owner_id == local_owner_id and entity.is_in_group("units")):
		for entity: Node3D in selection.duplicate():
			if not entity.is_in_group("units"):
				entity.set_selected(false)
				selection.erase(entity)
	if not additive:
		for entity in selection:
			if is_instance_valid(entity):
				entity.set_selected(false)
		selection.clear()
	for entity in entities:
		if not is_instance_valid(entity) or not entity.alive:
			continue
		if additive and entity.owner_id != local_owner_id:
			continue
		if additive and not entity.is_in_group("units") and selection.any(func(item): return item.is_in_group("units")):
			continue
		if toggle and entity in selection:
			entity.set_selected(false)
			selection.erase(entity)
		elif entity not in selection:
			selection.append(entity)
			entity.set_selected(true)
	hud.refresh()
	if not entities.is_empty():
		$Audio.play_ui("select")

func _prune_selection() -> void:
	selection = selection.filter(func(entity): return is_instance_valid(entity) and entity.alive)

func own_selected_units() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for entity in selection:
		if is_instance_valid(entity) and entity.alive and entity.owner_id == local_owner_id and entity.is_in_group("units"):
			result.append(entity)
	return result

func own_selected_workers() -> Array[Node3D]:
	return own_selected_units().filter(func(unit: Node3D): return unit.unit_type == "farmer")

func _on_gathered(worker: Node3D, amount: int) -> void:
	if is_authority and not finished and not get_tree().paused and worker.alive:
		get_player(worker.owner_id).gold += amount

func command_gather(mine: Node3D, queued: bool = false) -> void:
	var building := selected_production()
	if building != null:
		submit_local({"kind": "rally", "target": building.entity_id, "at": vector_data(mine.global_position), "mine": mine.entity_id})
	else:
		submit_local({"kind": "gather", "units": selected_ids(), "target": mine.entity_id, "queued": queued})
	$Audio.play_ui(&"order")

func _choose_builder(at: Vector3, queued: bool) -> Node3D:
	var best: Node3D
	var score := INF
	for worker: Node3D in own_selected_workers():
		var candidate: float = worker.global_position.distance_squared_to(at)
		if queued:
			candidate += worker.waypoint_queue.size() * 10000.0
			if worker.order != BattleUnit.Order.IDLE:
				candidate += 10000.0
		if candidate < score:
			score = candidate
			best = worker
	return best

func command_build(site: Node3D, queued: bool = false) -> void:
	submit_local({"kind": "work", "units": selected_ids(), "target": site.entity_id, "at": vector_data(site.global_position), "queued": queued})
	$Audio.play_ui(&"order")

func set_build_mode(value: bool, kind: String = "defense_tower") -> void:
	build_kind = kind
	build_mode = value and not finished and not own_selected_workers().is_empty()
	if value and not build_mode:
		hud.toast("先选择农民，再选择建筑", 2.0)
	if build_mode:
		set_attack_mode(false)
		dragging = false
		overlay.box_visible = false
		_preview_time = 0.0
		var definition := BalanceCatalog.building(kind)
		$BuildingPreview.configure(kind, definition.size)
		hud.toast("%s · %d 金币 · 左键放置 · Shift 连续建造" % [definition.name, definition.cost], 6.0)
	$BuildingPreview.visible = build_mode
	hud.refresh()

func snap_build_position(at: Vector3) -> Vector3:
	return Vector3(roundf(at.x), 0.0, roundf(at.z))

func placement_error(at: Vector3, owner: int = -1, kind: String = "") -> String:
	if owner < 0:
		owner = local_owner_id
	if kind.is_empty():
		kind = build_kind
	var definition := BalanceCatalog.building(kind)
	if finished:
		return "当前无法建造"
	if get_player(owner).gold < definition.cost:
		return "金币不足 · 需要 %d 金币" % definition.cost
	var own := owned_entities(owner, "buildings")
	if kind == "headquarters" and own.any(func(b): return b.building_type == "headquarters"):
		return "每位玩家只能拥有一座大本营（含工地）"
	if kind in ["factory", "academy"] and not own.any(func(b): return b.building_type == "barracks" and b.is_constructed):
		return "需要一座已完工兵营"
	if absf(at.x) + definition.size.x * 0.5 > map_size.x * 0.5 - 2 or absf(at.z) + definition.size.z * 0.5 > map_size.y * 0.5 - 2:
		return "请在战场范围内建造"
	if not can_see_position(owner, at):
		return "请先侦察这片区域"
	if not $ConstructionNavigation.walkable_footprint(at, definition.size):
		return "这里空间不足 · 请避开矿脉与道路边缘"
	_placement_query.shape.size = definition.size + Vector3(0.4, 0, 0.4)
	_placement_query.transform.origin = at + Vector3(0, definition.size.y * 0.5, 0)
	if not get_world_3d().direct_space_state.intersect_shape(_placement_query, 1).is_empty():
		return "这里有单位或障碍物"
	return ""

func place_tower(point: Vector3, queued: bool = false) -> Node3D:
	var at := snap_build_position(point)
	var error := placement_error(at)
	if not error.is_empty():
		hud.toast(error, 2.0)
		return null
	submit_local({"kind": "build", "building_type": build_kind, "units": selected_ids(), "at": vector_data(at), "queued": queued})
	if not queued:
		set_build_mode(false)
	return null

func _on_construction_completed(site: Node3D) -> void:
	notify_owner(site.owner_id, "%s建成" % site.display_name)

func cancel_selected_construction() -> void:
	for entity: Node3D in selection.duplicate():
		if entity is BattleBuilding and entity.owner_id == local_owner_id:
			submit_local({"kind": "cancel_site", "target": entity.entity_id})

func demolish_selected_towers() -> void:
	for entity: Node3D in selection.duplicate():
		if entity is BattleBuilding and entity.owner_id == local_owner_id:
			submit_local({"kind": "demolish", "target": entity.entity_id})

func command_move(destination: Vector3, assault: bool = false, queued: bool = false) -> void:
	var building := selected_production()
	if building != null:
		submit_local({"kind": "rally", "target": building.entity_id, "at": vector_data(clamp_to_map(destination))})
		$RallyMarker.position = destination
	else:
		submit_local({"kind": "move", "units": selected_ids(), "at": vector_data(clamp_to_map(destination)), "attack_move": assault, "queued": queued})
	spawn_effect(destination, "attack" if assault else "move", Color("ee9e57") if assault else Color("91d0ee"))
	$Audio.play_ui(&"order")

func command_attack(target: Node3D) -> void:
	if not is_instance_valid(target) or not target.alive:
		return
	submit_local({"kind": "attack", "units": selected_ids(), "target": target.entity_id})
	spawn_effect(target.global_position, "attack", Color("ff7851"))
	$Audio.play_ui(&"order")

func stop_selected() -> void:
	submit_local({"kind": "stop", "units": selected_ids()})
	set_attack_mode(false)
	$Audio.play_ui(&"order")

func hold_selected() -> void:
	submit_local({"kind": "hold", "units": selected_ids()})
	set_attack_mode(false)
	$Audio.play_ui(&"order")

func set_attack_mode(value: bool) -> void:
	if value and build_mode:
		set_build_mode(false)
	attack_mode = value and not own_selected_units().is_empty()
	overlay.attack_cursor = attack_mode
	if attack_mode:
		$Audio.play_ui(&"select")
		hud.toast("选择攻击目标或前进位置 · 右键取消", 8.0)
	hud.refresh()

func select_headquarters() -> void:
	if is_instance_valid(headquarters) and headquarters.alive:
		select_entities([headquarters])
		camera_rig.focus_at(headquarters.global_position + Vector3(5, 0, -5))

func select_army() -> void:
	var army: Array[Node3D] = []
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.alive and unit.owner_id == local_owner_id and unit.unit_type != "farmer":
			army.append(unit)
	select_entities(army)

func select_idle_worker() -> void:
	var idle: Array[Node3D] = []
	for unit: Node3D in get_tree().get_nodes_in_group("friendly_units"):
		if unit.alive and unit.unit_type == "farmer" and unit.order == BattleUnit.Order.IDLE:
			idle.append(unit)
	if idle.is_empty():
		hud.toast("没有空闲农民", 1.8)
		return
	var worker: Node3D = idle[_idle_worker_index % idle.size()]
	_idle_worker_index += 1
	select_entities([worker])
	camera_rig.focus_at(worker.global_position)

func focus_selection() -> void:
	_prune_selection()
	if selection.is_empty():
		return
	var center := Vector3.ZERO
	for entity in selection:
		center += entity.global_position
	camera_rig.focus_at(center / selection.size())

func use_control_group(number: int, assign: bool = false, append: bool = false) -> void:
	if append:
		var selected := own_selected_units()
		if selected.is_empty():
			$Audio.play_ui(&"denied")
			hud.toast("先选择要加入编队的部队", 2.0)
			return
		var group: Array = control_groups.get(number, []).filter(func(entity): return is_instance_valid(entity) and entity.alive)
		for unit in selected:
			if unit not in group:
				group.append(unit)
		control_groups[number] = group
		$Audio.play_ui(&"order")
		hud.toast("已加入编队 %d · 共 %d 人" % [number, group.size()], 2.0)
	elif assign:
		var selected := own_selected_units()
		if selected.is_empty():
			$Audio.play_ui(&"denied")
			hud.toast("先选择部队，再按 Ctrl + 数字编队", 2.5)
			return
		control_groups[number] = selected.duplicate()
		$Audio.play_ui(&"order")
		hud.toast("编队 %d · %d 名士兵" % [number, selected.size()], 2.0)
	elif control_groups.has(number):
		var group: Array = control_groups[number].filter(func(entity): return is_instance_valid(entity) and entity.alive)
		control_groups[number] = group
		select_entities(group)
		var now := Time.get_ticks_msec() / 1000.0
		if _last_group == number and now - _last_group_time < 0.35:
			focus_selection()
		_last_group = number
		_last_group_time = now
	else:
		$Audio.play_ui(&"denied")
		hud.toast("Ctrl + %d 创建编队" % number, 2.0)
	hud.refresh()

func recruit(kind: String) -> bool:
	var building := selected_production()
	if building == null:
		hud.toast("选中对应生产建筑后招募", 2.0)
		return false
	var error: String = building.get_node("Production").recruit_error(kind)
	if not error.is_empty():
		hud.toast(error, 2.0)
		return false
	return submit_local({"kind": "recruit", "target": building.entity_id, "unit_type": kind}).ok

func find_recruit_position(kind: String, building: BattleBuilding = null) -> Vector3:
	if building == null:
		building = headquarters
	var query := PhysicsShapeQueryParameters3D.new()
	var shape := SphereShape3D.new()
	shape.radius = BalanceCatalog.unit(kind).radius + 0.1
	query.shape = shape
	query.collision_mask = 6 | 128
	var world := get_world_3d()
	if NavigationServer3D.map_get_iteration_id(world.navigation_map) == 0:
		return Vector3.INF
	var half: Vector3 = building.get_combat_definition().size * 0.5
	for ring in [1.4, 2.6, 4.0]:
		for index in range(32):
			var angle: float = float(index) * TAU / 32.0
			var at: Vector3 = building.global_position + Vector3(sin(angle) * (half.x + ring), 0, cos(angle) * (half.z + ring))
			if not $ConstructionNavigation.contains_walkable_point(at):
				continue
			var closest := NavigationServer3D.map_get_closest_point(world.navigation_map, at)
			if Vector2(closest.x-at.x, closest.z-at.z).length_squared() > 0.04:
				continue
			query.transform.origin = at + Vector3.UP * maxf(shape.radius, 0.9)
			if world.direct_space_state.intersect_shape(query, 1).is_empty():
				return at
	return Vector3.INF

func spawn_unit(kind: String, faction: int, at: Vector3) -> Node3D:
	var unit: Node3D = UNIT_SCENE.instantiate()
	unit.unit_type = kind
	unit.owner_id = faction
	unit.alliance_id = get_player(faction).alliance_id
	unit.position = at
	unit.sound_requested.connect($Audio.play_world)
	unit.gathered.connect(_on_gathered)
	unit_container.add_child(unit)
	return unit

func spawn_projectile(source: Node3D, target: Node3D, damage: DamagePayload, kind: String) -> void:
	if not is_instance_valid(source) or not is_instance_valid(target):
		return
	var projectile = PROJECTILE_SCENE.instantiate()
	effect_container.add_child(projectile)
	projectile.initialize(source, target, damage, kind)

func spawn_effect(at: Vector3, kind: String, color: Color = Color.WHITE) -> void:
	# Sound tails belong to the bounded mixer, independent of visual effect limits.
	if EFFECT_SOUNDS.has(kind):
		$Audio.play_world(EFFECT_SOUNDS[kind], at)
	if effect_container.get_child_count() > 240:
		return
	var effect = EFFECT_SCENE.instantiate()
	effect_container.add_child(effect)
	effect.global_position = at
	effect.initialize(kind, color)

func on_entity_died(entity: Node3D) -> void:
	selection.erase(entity)
	if entity is BattleUnit:
		var player := get_player(entity.owner_id)
		if entity.unit_type == "farmer":
			player.farmers -= 1
		else:
			player.military_supply -= BalanceCatalog.unit(entity.unit_type).supply
	if entity.is_in_group("buildings"):
		var authored_patch: NavigationRegion3D = get_node_or_null("ClearedNavigation/" + str(entity.name))
		if authored_patch != null:
			authored_patch.enabled = true
		$ConstructionNavigation.refresh()
	if entity.alliance_id != get_player(local_owner_id).alliance_id:
		if entity.is_in_group("units"):
			kills += 1
		elif entity.is_in_group("buildings"):
			buildings_destroyed += 1
			gold += 90
			$Audio.play_ui(&"coin")
			hud.toast("摧毁" + entity.display_name + " · 战利品 +90 金币", 3.0)
	if entity == headquarters:
		end_battle(false)
	elif buildings_destroyed >= 4 and not tests_running:
		end_battle(true)
	hud.refresh()

func _on_income() -> void:
	if not finished and is_authority:
		for player: PlayerState in players:
			player.gold += 1

func debug_add_gold() -> void:
	gold += 100
	$Audio.play_ui("coin")
	hud.toast("调试补给 +100 金币", 2.0)
	hud.refresh()

func _on_enemy_wave() -> void:
	if finished or tests_running:
		return
	var barracks: Array = get_tree().get_nodes_in_group("buildings").filter(func(b): return b.alive and b.team == 1 and b.building_type == "barracks")
	if barracks.is_empty():
		return
	_enemy_wave += 1
	for barrack in barracks:
		for index in range(3 + mini(_enemy_wave, 3)):
			var kind: String = "archer" if index % 3 == 0 else "swordsman"
			if _enemy_wave > 2 and index == 1:
				kind = "knight"
			var unit := spawn_unit(kind, 1, barrack.global_position + Vector3(index - 2, 0, 5.5))
			unit.issue_move(headquarters.global_position + Vector3(0, 0, -7), true)
	hud.toast("敌方援军正在集结 · 摧毁兵营以切断增援", 4.0)
	$EnemyTimer.wait_time = 65.0

func player_count() -> int:
	var count := 0
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.alive and unit.owner_id == local_owner_id:
			count += 1
	return count

func enemy_count() -> int:
	var count := 0
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.alive and unit.team == 1:
			count += 1
	return count

func toggle_pause() -> void:
	if finished:
		return
	get_tree().paused = not get_tree().paused
	$Audio.set_world_paused(get_tree().paused)
	$Audio.play_ui(&"select")
	hud.show_pause(get_tree().paused)

func toggle_sound() -> void:
	var is_muted: bool = $Audio.toggle_mute()
	hud.refresh_sound_settings()
	if not is_muted:
		$Audio.play_ui(&"select")
	hud.toast("声音已关闭" if is_muted else "声音已开启", 1.5)

func end_battle(victory: bool) -> void:
	if finished:
		return
	finished = true
	$EnemyTimer.stop()
	$IncomeTimer.stop()
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.alive:
			unit.hold()
			unit.get_node("AttackWindup").stop()
			unit.set_physics_process(false)
			unit.navigation_agent.avoidance_enabled = false
	for building in get_tree().get_nodes_in_group("buildings"):
		building.set_physics_process(false)
	for effect in effect_container.get_children():
		if effect is BattleProjectile:
			effect.queue_free()
	hud.show_result(victory, elapsed, kills)
	$Audio.play_ui(&"victory" if victory else &"defeat")

func restart() -> void:
	if _closing:
		return
	_closing = true
	get_tree().paused = false
	await prepare_shutdown()
	get_tree().reload_current_scene()

func prepare_shutdown() -> void:
	finished = true
	$IncomeTimer.stop()
	$EnemyTimer.stop()
	var retiring_playbacks: Array[WeakRef] = []
	for unit in get_tree().get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	for building in get_tree().get_nodes_in_group("buildings"):
		building.set_physics_process(false)
	for effect in effect_container.get_children():
		if effect is BattleProjectile:
			effect.set_physics_process(false)
	retiring_playbacks.append_array($Audio.stop_all())
	# stop() requests an audio-thread fade and deferred main-thread deletion.
	# A fixed delay can expire before that deletion, especially with the Dummy driver.
	while not retiring_playbacks.is_empty():
		await get_tree().process_frame
		retiring_playbacks = retiring_playbacks.filter(func(reference: WeakRef): return reference.get_ref() != null)
	await get_tree().process_frame

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not _closing:
		_closing = true
		get_tree().paused = false
		await prepare_shutdown()
		get_tree().quit()

func _on_minimap_clicked(at: Vector3, command: bool) -> void:
	if command:
		command_move(at, attack_mode, Input.is_key_pressed(KEY_SHIFT))
		set_attack_mode(false)
	else:
		camera_rig.focus_at(at)

func get_player(owner: int) -> PlayerState:
	return players[owner]

func register_entity(entity: Node3D) -> void:
	if entity.entity_id == 0:
		entity.entity_id = _next_entity_id
		_next_entity_id += 1
	entities_by_id[entity.entity_id] = entity
	if entity is BattleUnit and is_authority:
		var player := get_player(entity.owner_id)
		if entity.unit_type == "farmer":
			player.farmers += 1
		else:
			player.military_supply += BalanceCatalog.unit(entity.unit_type).supply

func are_hostile(a: Node3D, b: Node3D) -> bool:
	return a.alliance_id != b.alliance_id

func can_see_entity(_owner: int, _entity: Node3D) -> bool:
	return true

func can_see_position(_owner: int, _at: Vector3) -> bool:
	return true

func clamp_to_map(at: Vector3) -> Vector3:
	return Vector3(clampf(at.x, -map_size.x * 0.5 + 2, map_size.x * 0.5 - 2), 0,
		clampf(at.z, -map_size.y * 0.5 + 2, map_size.y * 0.5 - 2))

func next_command_sequence(owner: int) -> int:
	return command_bus.next_sequence(owner)

func submit_command(command: Dictionary, owner: int = -1) -> Dictionary:
	return command_bus.submit(command, local_owner_id if owner < 0 else owner)

func submit_local(command: Dictionary) -> Dictionary:
	command["seq"] = next_command_sequence(local_owner_id)
	return submit_command(command)

func selected_ids() -> Array:
	return own_selected_units().map(func(unit): return unit.entity_id)

func selected_production() -> BattleBuilding:
	if selection.size() == 1 and selection[0] is BattleBuilding and selection[0].owner_id == local_owner_id and selection[0].alive:
		return selection[0]
	return null

static func vector_data(at: Vector3) -> Array:
	return [at.x, at.y, at.z]

func owned_entities(owner: int, group: String) -> Array:
	return get_tree().get_nodes_in_group(group).filter(func(entity): return entity.alive and entity.owner_id == owner)

func choose_builder(units: Array, at: Vector3, queued: bool) -> BattleUnit:
	var best: BattleUnit
	var score := INF
	for worker: BattleUnit in units:
		if worker.unit_type != "farmer":
			continue
		var value := worker.global_position.distance_squared_to(at)
		if queued:
			value += worker.waypoint_queue.size() * 10000 + (0 if worker.order == BattleUnit.Order.IDLE else 10000)
		if value < score:
			score = value
			best = worker
	return best

func create_site(owner: int, kind: String, at: Vector3, workers: Array, queued: bool) -> Dictionary:
	at = snap_build_position(at)
	var error := placement_error(at, owner, kind)
	if not error.is_empty():
		return MatchCommands.failure(error)
	var worker := choose_builder(workers, at, queued)
	get_player(owner).gold -= BalanceCatalog.building(kind).cost
	var site := spawn_building(kind, owner, at, true)
	worker.issue_build(site, queued)
	$ConstructionNavigation.refresh()
	return {"ok": true, "entity_id": site.entity_id}

func spawn_building(kind: String, owner: int, at: Vector3, construction: bool = false) -> BattleBuilding:
	var site: BattleBuilding = BUILDING_SCENE.instantiate()
	site.building_type = kind
	site.owner_id = owner
	site.team = get_player(owner).alliance_id
	site.under_construction = construction
	site.position = at
	site.sound_requested.connect($Audio.play_world)
	site.construction_completed.connect(_on_construction_completed)
	$Buildings.add_child(site)
	if owner == local_owner_id and kind == "headquarters":
		headquarters = site
	return site

func move_formation(army: Array, at: Vector3, assault: bool, queued: bool) -> void:
	if army.is_empty():
		return
	var columns := ceili(sqrt(float(army.size())))
	var spacing := 1.7
	var center := Vector3.ZERO
	for unit: BattleUnit in army:
		spacing = maxf(spacing, unit.radius * 2.3)
		center += unit.global_position
	center /= army.size()
	var forward := (at - center).normalized()
	if forward.length_squared() < 0.01:
		forward = Vector3.FORWARD
	var right := Vector3(-forward.z, 0, forward.x)
	for index in range(army.size()):
		var target := clamp_to_map(at + right * (float(index % columns) - float(columns - 1) * 0.5) * spacing - forward * float(index / columns) * spacing)
		if queued:
			army[index].queue_move(target, assault)
		else:
			army[index].issue_move(target, assault)

func notify_owner(owner: int, message: String) -> void:
	if owner == local_owner_id:
		hud.toast(message, 2.5)

func nearest_mine(at: Vector3) -> ResourceVein:
	var nearest: ResourceVein
	var distance := INF
	for mine: ResourceVein in get_tree().get_nodes_in_group("resource_veins"):
		var value := at.distance_squared_to(mine.global_position)
		if value < distance:
			distance = value
			nearest = mine
	return nearest

func find_build_location(owner: int, kind: String, near: Vector3) -> Vector3:
	for radius in [9, 13, 17, 21, 25]:
		for slot in range(16):
			var angle := float(slot) * TAU / 16
			var at := snap_build_position(near + Vector3(sin(angle), 0, cos(angle)) * radius)
			if placement_error(at, owner, kind).is_empty():
				return at
	return Vector3.INF
