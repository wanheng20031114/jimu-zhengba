extends Node3D

const UNIT_SCENE: PackedScene = preload("res://scenes/unit.tscn")
const PROJECTILE_SCENE: PackedScene = preload("res://scenes/projectile.tscn")
const EFFECT_SCENE: PackedScene = preload("res://scenes/battle_effect.tscn")
const BUILDING_SCENE: PackedScene = preload("res://scenes/building.tscn")
const UNIT_TYPES := ["swordsman", "archer", "knight", "catapult", "cannon", "farmer"]
const UNIT_NAMES := {"swordsman": "剑士", "archer": "弓箭手", "knight": "骑士", "catapult": "投石车", "cannon": "加农炮", "farmer": "农民"}
const MAX_ARMY: int = 160
const EFFECT_SOUNDS: Dictionary = {"hit": &"sword_hit", "wood_hit": &"wood_hit", "stone_chip": &"stone_chip", "arrow_hit": &"arrow_hit", "muzzle": &"cannon_shot", "explosion": &"explosion", "stone_hit": &"stone_hit", "collapse": &"collapse"}

@onready var camera_rig = $CameraRig
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var hud = $HUD/Interface
@onready var overlay = $HUD/SelectionOverlay
var headquarters: BattleBuilding
@onready var unit_container: Node3D = $Units
@onready var effect_container: Node3D = $Effects
@onready var settings: GameSettings = get_node("/root/Session/Settings")

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
var _production_group_kind: String = ""
var rally_point := Vector3(-10, 0, 24)
var attack_mode: bool = false
var dragging: bool = false
var drag_start := Vector2.ZERO
var pointer_now := Vector2.ZERO
var shift_drag: bool = false
var ctrl_drag: bool = false
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
var map_instance: Node3D
var map_definition: MapDefinition
var match_config: Dictionary = {}
var _spawn_indices: Dictionary = {}
var bots: Dictionary = {}
var _fog_ready: bool = false
var _match_ready: bool = false
var _victory_timer: float = 0.0
var _revealed_alliances: Array[int] = []
var online: bool = false
var _local_menu: bool = false
var _network_paused: bool = false
var _notice_after: Dictionary = {}
@onready var replication: MatchReplication = $MatchReplication

func _ready() -> void:
	get_tree().auto_accept_quit = false
	command_bus = MatchCommands.new(self)
	hud.bind_game(self)
	_setup_match()
	var footprint := BoxShape3D.new()
	footprint.size = Vector3(4.4, 5.0, 4.4)
	_placement_query = PhysicsShapeQueryParameters3D.new()
	_placement_query.shape = footprint
	_placement_query.collision_mask = 6 | 128
	$ConstructionNavigation.refresh()
	$IncomeTimer.timeout.connect(_on_income)
	
	$IncomeTimer.start()

	select_entities([headquarters])
	hud.toast("建立兵营，集结军队 · 摧毁敌队全部军事建筑", 5.0)
	hud.refresh()
	game_started = not online
	$FogOfWar.configure(self, map_size)
	_fog_ready = true
	$FogOfWar.apply_visibility(local_owner_id)
	_match_ready = true
	settings.pause_requested.connect(handle_pause_action)
	if online:
		replication.configure(self, Session.relay)
		replication.visual_event_due.connect(_play_network_visual)
		Session.relay.command_received.connect(_on_network_command)
		Session.relay.event_received.connect(_on_network_event)
		Session.relay.connection_state_changed.connect(_on_connection_state)
		replication.snapshot_applied.connect(_on_snapshot_applied)
		hud.get_node("%RestartButton").text = "返回大厅"
		hud.get_node("%ResultRestart").text = "返回大厅"
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
		$FogOfWar.tick(delta)
		command_bus.tick()
		for bot: SkirmishBot in bots.values():
			bot.tick(delta)
		_victory_timer += delta
		if _victory_timer >= 0.5:
			_victory_timer = 0
			check_victory()
		simulation_tick += 1
		elapsed += delta
		if online:
			replication.tick(delta)

func _process(delta: float) -> void:
	if online and not is_authority:
		replication.render(delta)
	if _fog_ready:
		$FogOfWar.apply_visibility(local_owner_id)
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
	if settings.is_open():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key: Key = settings.resolve_key(event)
		if key == KEY_F5 and not finished:
			handle_pause_action()
			get_viewport().set_input_as_handled()
			return
		if event.is_action_pressed("debug_gold"):
			debug_add_gold()
			get_viewport().set_input_as_handled()
			return
		if key == KEY_F1:
			hud.toggle_help()
			get_viewport().set_input_as_handled()
			return
		if key == KEY_F10:
			photo_mode = not photo_mode
			hud.visible = not photo_mode
			get_viewport().set_input_as_handled()
			return
		if key == KEY_F11:
			settings.toggle_fullscreen()
			get_viewport().set_input_as_handled()
			return
		if key == KEY_ESCAPE:
			if build_mode:
				set_build_mode(false)
			elif attack_mode:
				set_attack_mode(false)
			elif hud.help_visible():
				hud.toggle_help()
			elif not get_tree().paused and not _local_menu and not finished:
				cancel_selected_queue()
			get_viewport().set_input_as_handled()
			return
	if get_tree().paused or finished or _local_menu:
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
	if get_tree().paused or finished or _local_menu or settings.is_open():
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
					command_attack(entity, event.shift_pressed)
				else:
					command_move(camera_rig.world_at(event.position), true, event.shift_pressed)
				set_attack_mode(false)
			else:
				dragging = true
				drag_start = event.position
				shift_drag = event.shift_pressed
				ctrl_drag = event.ctrl_pressed
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
				command_attack(entity, event.shift_pressed)
			else:
				command_move(camera_rig.world_at(event.position), false, event.shift_pressed)
	if event is InputEventKey and event.pressed and not event.echo:
		var key: Key = settings.resolve_key(event)
		if key >= KEY_1 and key <= KEY_9:
			use_control_group(key - KEY_0, event.ctrl_pressed, event.shift_pressed)
			return
		match key:
			KEY_A: set_attack_mode(true)
			KEY_S: stop_selected()
			KEY_H: hold_selected(event.shift_pressed)
			KEY_B, KEY_HOME: select_headquarters()
			KEY_G, KEY_F2: select_army()
			KEY_SPACE: focus_selection()
			KEY_TAB: cycle_production_group()
			KEY_Q: hud.trigger_action_slot(0)
			KEY_W: hud.trigger_action_slot(1)
			KEY_E: hud.trigger_action_slot(2)
			KEY_R: hud.trigger_action_slot(3)
			KEY_T: hud.trigger_action_slot(4)
			KEY_Y: hud.trigger_action_slot(5)
			KEY_V: set_build_mode(not build_mode)
			KEY_DELETE: destroy_selected()
			KEY_PERIOD: select_idle_worker()
			KEY_M:
				toggle_sound()

func entity_at(screen: Vector2) -> Node3D:
	var from := camera.project_ray_origin(screen)
	var ray := PhysicsRayQueryParameters3D.create(from, from + camera.project_ray_normal(screen) * 200.0, 6 | 128)
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if not hit.is_empty() and (hit.collider.is_in_group("entities") or hit.collider.is_in_group("resource_veins")) and hit.collider.alive and can_see_entity(local_owner_id, hit.collider):
		return hit.collider
	var closest: Node3D = null
	var best_distance: float = 28.0
	for entity in get_tree().get_nodes_in_group("units"):
		if not entity.alive or not can_see_entity(local_owner_id, entity) or camera.is_position_behind(entity.global_position):
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
		# As in common RTS selection, mobile units take precedence; an empty
		# troop rectangle can still collect several owned production buildings.
		if picked.is_empty():
			for building: BattleBuilding in owned_entities(local_owner_id, "buildings"):
				if not camera.is_position_behind(building.global_position) and box.has_point(camera.unproject_position(building.global_position + Vector3.UP)):
					picked.append(building)
		select_entities(picked, shift_drag)
	else:
		var entity := entity_at(at)
		if is_instance_valid(entity):
			var now := Time.get_ticks_msec() / 1000.0
			var double_click: bool = entity == _last_click_entity and now - _last_click_time < 0.30
			var select_type: bool = double_click or (ctrl_drag and entity is BattleUnit)
			if select_type and (entity is BattleUnit or entity is BattleBuilding) and entity.owner_id == local_owner_id:
				var same: Array[Node3D] = []
				var group: String = "units" if entity is BattleUnit else "buildings"
				for item: Node3D in owned_entities(local_owner_id, group):
					var same_type: bool = item.unit_type == entity.unit_type if entity is BattleUnit else item.building_type == entity.building_type
					if same_type and camera.is_position_in_frustum(item.global_position):
						same.append(item)
				select_entities(same, shift_drag)
			else:
				select_entities([entity], shift_drag, shift_drag)
			_last_click_entity = entity
			_last_click_time = now
		elif not shift_drag:
			select_entities([])

func select_entities(entities: Array, additive: bool = false, toggle: bool = false) -> void:
	if additive and entities.any(func(entity): return is_instance_valid(entity) and entity.owner_id == local_owner_id and (entity is BattleUnit or entity is BattleBuilding)):
		for entity: Node3D in selection.duplicate():
			if entity.owner_id != local_owner_id or not (entity is BattleUnit or entity is BattleBuilding):
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
	selection = selection.filter(func(entity): return is_instance_valid(entity) and entity.alive and can_see_entity(local_owner_id, entity))

func forget_entity_selection(entity: Node3D) -> void:
	# Authoritative death and client snapshot retirement share this local-only
	# cleanup. Clear references before queue_free; HUD/input run more frequently
	# than the periodic selection refresh and must never see a freed replica.
	selection.erase(entity)
	for group: Array in control_groups.values():
		group.erase(entity)
	if _last_click_entity == entity:
		_last_click_entity = null
		_last_click_time = -1.0

func own_selected_units() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for entity in selection:
		if is_instance_valid(entity) and entity.alive and entity.owner_id == local_owner_id and entity.is_in_group("units"):
			result.append(entity)
	return result

func own_selected_assets() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for entity: Node3D in selection:
		if is_instance_valid(entity) and entity.alive and entity.owner_id == local_owner_id and (entity is BattleUnit or entity is BattleBuilding):
			result.append(entity)
	return result

func own_selected_buildings() -> Array[BattleBuilding]:
	var result: Array[BattleBuilding] = []
	for entity: Node3D in own_selected_assets():
		if entity is BattleBuilding:
			result.append(entity)
	return result

func selected_building_ids() -> Array:
	return own_selected_buildings().map(func(building): return building.entity_id)

func own_selected_workers() -> Array[Node3D]:
	return own_selected_units().filter(func(unit: Node3D): return unit.unit_type == "farmer")

func _on_gathered(worker: Node3D, amount: int) -> void:
	if is_authority and not finished and not get_tree().paused and worker.alive:
		get_player(worker.owner_id).gold += amount

func command_gather(mine: Node3D, queued: bool = false) -> void:
	if not own_selected_buildings().is_empty():
		submit_local({"kind": "rally", "buildings": selected_building_ids(), "at": vector_data(mine.global_position), "mine": mine.entity_id})
	if not own_selected_workers().is_empty():
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
	# Newly placed sites must reserve their true footprint immediately, including
	# several build commands within one authority tick before physics publishes.
	for building: BattleBuilding in get_tree().get_nodes_in_group("buildings"):
		if not building.alive:
			continue
		var combined_half: Vector3 = (definition.size + building.get_combat_definition().size) * 0.5
		var offset: Vector3 = building.global_position - at
		if absf(offset.x) < combined_half.x - 0.005 and absf(offset.z) < combined_half.z - 0.005:
			return "这里已有建筑或工地"
	# Building placement uses the actual collision footprint. Navigation padding
	# belongs to unit movement and must not be applied twice between buildings.
	_placement_query.shape.size = definition.size - Vector3(0.01, 0, 0.01)
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

func destroy_selected() -> void:
	var assets := own_selected_assets()
	if assets.is_empty():
		return
	submit_local({"kind": "destroy", "targets": assets.map(func(entity): return entity.entity_id)})
	set_build_mode(false)
	set_attack_mode(false)

func command_move(destination: Vector3, assault: bool = false, queued: bool = false) -> void:
	if not own_selected_buildings().is_empty():
		submit_local({"kind": "rally", "buildings": selected_building_ids(), "at": vector_data(clamp_to_map(destination))})
	if not own_selected_units().is_empty():
		submit_local({"kind": "move", "units": selected_ids(), "at": vector_data(clamp_to_map(destination)), "attack_move": assault, "queued": queued})
	spawn_effect(destination, "attack" if assault else "move", Color("ee9e57") if assault else Color("91d0ee"))
	$Audio.play_ui(&"order")

func command_attack(target: Node3D, queued: bool = false) -> void:
	if not is_instance_valid(target) or not target.alive:
		return
	if not own_selected_units().is_empty():
		submit_local({"kind": "attack", "units": selected_ids(), "target": target.entity_id, "queued": queued})
	elif not own_selected_buildings().is_empty():
		submit_local({"kind": "rally", "buildings": selected_building_ids(), "at": vector_data(target.global_position)})
	spawn_effect(target.global_position, "attack", Color("ff7851"))
	$Audio.play_ui(&"order")

func stop_selected() -> void:
	submit_local({"kind": "stop", "units": selected_ids()})
	set_attack_mode(false)
	$Audio.play_ui(&"order")

func hold_selected(queued: bool = false) -> void:
	submit_local({"kind": "hold", "units": selected_ids(), "queued": queued})
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
	for unit: Node3D in owned_entities(local_owner_id, "units"):
		if unit.unit_type == "farmer" and unit.order == BattleUnit.Order.IDLE:
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
		var selected := own_selected_assets()
		if selected.is_empty():
			$Audio.play_ui(&"denied")
			hud.toast("先选择要加入编队的部队或建筑", 2.0)
			return
		var group: Array = control_groups.get(number, []).filter(func(entity): return is_instance_valid(entity) and entity.alive and entity.owner_id == local_owner_id)
		for unit in selected:
			if unit not in group:
				group.append(unit)
		control_groups[number] = group
		$Audio.play_ui(&"order")
		hud.toast("已加入编队 %d · 共 %d 个单位／建筑" % [number, group.size()], 2.0)
	elif assign:
		var selected := own_selected_assets()
		if selected.is_empty():
			$Audio.play_ui(&"denied")
			hud.toast("先选择部队或建筑，再按 Ctrl + 数字编队", 2.5)
			return
		control_groups[number] = selected.duplicate()
		$Audio.play_ui(&"order")
		hud.toast("编队 %d · %d 个单位／建筑" % [number, selected.size()], 2.0)
	elif control_groups.has(number):
		var group: Array = control_groups[number].filter(func(entity): return is_instance_valid(entity) and entity.alive and entity.owner_id == local_owner_id)
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
	var buildings := own_selected_buildings()
	if buildings.is_empty():
		hud.toast("选中对应生产建筑后招募", 2.0)
		return false
	return submit_local({"kind": "recruit", "buildings": selected_building_ids(), "unit_type": kind}).ok

func research_selected(upgrade: String) -> bool:
	if own_selected_buildings().is_empty():
		return false
	return submit_local({"kind": "research", "buildings": selected_building_ids(), "upgrade": upgrade}).ok

func find_recruit_position(kind: String, building: BattleBuilding = null) -> Vector3:
	if building == null:
		building = headquarters
	var query := PhysicsShapeQueryParameters3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = BalanceCatalog.unit(kind).radius * 0.85 + 0.05
	shape.height = maxf(shape.radius * 2.0, 1.8)
	query.shape = shape
	query.collision_mask = 6 | 128
	var world := get_world_3d()
	if NavigationServer3D.map_get_iteration_id(world.navigation_map) == 0:
		return Vector3.INF
	var half: Vector3 = building.get_combat_definition().size * 0.5
	var rally_direction: Vector3 = building.rally_point - building.global_position
	if rally_direction.length_squared() < 0.0001:
		rally_direction = Vector3.FORWARD
	var preferred_angle: float = atan2(rally_direction.x, rally_direction.z)
	var clearance: float = maxf(BalanceCatalog.unit(kind).radius + 0.1, ConstructionNavigation.NAV_PADDING + 0.05)
	for index in range(32):
		# Search the rally ray first, then alternate the nearest directions
		# around the complete perimeter, including the opposite building side.
		var step: int = (index + 1) / 2
		var angle: float = preferred_angle + float(step if index % 2 == 1 else -step) * TAU / 32.0
		var direction := Vector3(sin(angle), 0, cos(angle))
		for extra_distance: float in [0.0, 0.75, 1.5, 2.5]:
			var padded_half := half + Vector3.ONE * (clearance + extra_distance)
			var distance_x: float = padded_half.x / absf(direction.x) if absf(direction.x) > 0.00001 else INF
			var distance_z: float = padded_half.z / absf(direction.z) if absf(direction.z) > 0.00001 else INF
			var at: Vector3 = building.global_position + direction * minf(distance_x, distance_z)
			if at.distance_squared_to(clamp_to_map(at)) > 0.0001:
				continue
			if not $ConstructionNavigation.contains_walkable_point(at):
				continue
			var closest := NavigationServer3D.map_get_closest_point(world.navigation_map, at)
			if Vector2(closest.x-at.x, closest.z-at.z).length_squared() > 0.04:
				continue
			query.transform.origin = at + Vector3.UP * shape.height * 0.5
			if world.direct_space_state.intersect_shape(query, 1).is_empty():
				return at
	return Vector3.INF

func spawn_unit(kind: String, faction: int, at: Vector3, id: int = 0) -> Node3D:
	var unit: Node3D = UNIT_SCENE.instantiate()
	unit.unit_type = kind
	unit.entity_id = id
	unit.owner_id = faction
	unit.alliance_id = get_player(faction).alliance_id
	unit.position = at
	unit.sound_requested.connect(play_world_sound)
	unit.gathered.connect(_on_gathered)
	unit_container.add_child(unit)
	return unit

func spawn_projectile(source: Node3D, target: Node3D, damage: DamagePayload, kind: String) -> void:
	if not is_instance_valid(source) or not is_instance_valid(target):
		return
	var projectile = PROJECTILE_SCENE.instantiate()
	effect_container.add_child(projectile)
	projectile.initialize(source, target, damage, kind)
	if online and is_authority:
		for player: PlayerState in players:
			if player.owner_id != local_owner_id and player.controller == "human" and can_see_position(player.owner_id, projectile._start) and can_see_position(player.owner_id, projectile._end):
				replication.queue_host_visual(player.owner_id, {"kind": "projectile", "projectile": kind, "from": vector_data(projectile._start), "at": vector_data(projectile._end), "duration": projectile._duration, "arc": projectile._arc_height, "target": target.entity_id})

func spawn_effect(at: Vector3, kind: String, color: Color = Color.WHITE) -> void:
	if kind not in ["move", "attack"]:
		queue_visible_visual(at, {"kind": "effect", "effect": kind, "at": vector_data(at), "color": [color.r, color.g, color.b]})
	if not can_see_position(local_owner_id, at):
		return
	# Sound tails belong to the bounded mixer, independent of visual effect limits.
	if EFFECT_SOUNDS.has(kind):
		$Audio.play_world(EFFECT_SOUNDS[kind], at)
	$EffectPool.play(at, kind, color)

func on_entity_died(entity: Node3D) -> void:
	forget_entity_selection(entity)
	if not is_authority:
		return
	if entity is BattleUnit:
		var player := get_player(entity.owner_id)
		if entity.unit_type == "farmer":
			player.farmers -= 1
		else:
			player.military_supply -= BalanceCatalog.unit(entity.unit_type).supply
		if entity.alliance_id != get_player(local_owner_id).alliance_id:
			kills += 1
	else:
		$ConstructionNavigation.refresh()
		if entity.alliance_id != get_player(local_owner_id).alliance_id:
			buildings_destroyed += 1
	entities_by_id.erase(entity.entity_id)
	hud.refresh()

func _on_income() -> void:
	if not finished and is_authority:
		for player: PlayerState in players:
			if player.is_participating() and not player.eliminated:
				player.gold += BalanceCatalog.ECONOMY.passive_gold_per_second

func debug_add_gold() -> void:
	if online or get_player(local_owner_id).eliminated:
		return
	gold += 100
	$Audio.play_ui("coin")
	hud.toast("调试补给 +100 金币", 2.0)
	hud.refresh()

func _on_enemy_wave() -> void:
	pass

func player_count() -> int:
	var count := 0
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.alive and unit.owner_id == local_owner_id:
			count += 1
	return count

func enemy_count() -> int:
	var count := 0
	for unit: BattleUnit in get_tree().get_nodes_in_group("units"):
		if unit.alive and unit.alliance_id != get_player(local_owner_id).alliance_id and can_see_entity(local_owner_id, unit):
			count += 1
	return count

func cancel_selected_queue() -> void:
	var active := selected_production()
	if active == null:
		return
	var ids: Array = []
	for building: BattleBuilding in own_selected_buildings():
		if building.building_type == active.building_type and building.is_constructed:
			ids.append(building.entity_id)
	if not ids.is_empty():
		submit_local({"kind": "cancel_queue", "buildings": ids})

func handle_pause_action() -> void:
	if finished:
		return
	if settings.is_open():
		settings.close_menu()
	dragging = false
	camera_rig.dragging = false
	overlay.box_visible = false
	if online:
		request_match_pause()
		if is_authority:
			_local_menu = get_tree().paused
			hud.show_pause(_local_menu)
	else:
		toggle_pause()

func toggle_pause() -> void:
	if finished:
		return
	if online:
		_local_menu = not _local_menu
		hud.show_pause(_local_menu)
	else:
		get_tree().paused = not get_tree().paused
		$Audio.set_world_paused(get_tree().paused)
		hud.show_pause(get_tree().paused)
	$Audio.play_ui(&"select")

func open_settings() -> void:
	dragging = false
	camera_rig.dragging = false
	overlay.box_visible = false
	settings.open_menu()

func return_to_menu() -> void:
	if _closing:
		return
	_closing = true
	get_tree().paused = false
	await prepare_shutdown()
	Session.back_to_lobby()

func quit_game() -> void:
	if _closing:
		return
	_closing = true
	get_tree().paused = false
	await prepare_shutdown()
	Session.relay.disconnect_relay()
	get_tree().quit()

func toggle_sound() -> void:
	var is_muted: bool = $Audio.toggle_mute()
	hud.refresh_sound_settings()
	if not is_muted:
		$Audio.play_ui(&"select")
	hud.toast("声音已关闭" if is_muted else "声音已开启", 1.5)

func end_battle(victory: bool, winner: int = -2) -> void:
	if winner == -2 and victory:
		winner = get_player(local_owner_id).alliance_id
	if online and is_authority and not finished and winner >= -1:
		replication.flush_visual()
		Session.relay.finish_match({"winner": winner, "time": elapsed})
	if finished:
		return
	Session.record_diagnostic("match_finished", {"victory": victory, "online": online, "tick": simulation_tick})
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
	if winner == -1:
		hud.get_node("%ResultHeading").text = "平局"
		hud.get_node("%ResultBody").text = "所有阵营的军事建筑均已被摧毁。"
	$Audio.play_ui(&"victory" if victory else &"defeat")

func restart() -> void:
	if _closing:
		return
	_closing = true
	get_tree().paused = false
	await prepare_shutdown()
	if online:
		Session.back_to_lobby()
	else:
		get_tree().reload_current_scene()

func prepare_shutdown() -> void:
	Session.record_diagnostic("shutdown_begin", {"online": online, "tick": simulation_tick})
	finished = true
	$EffectPool.reset_all()
	if online:
		replication.reset()
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
	Session.record_diagnostic("shutdown_complete")

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
	if _fog_ready:
		$FogOfWar.apply_entity_visibility(local_owner_id, entity)
	if entity is BattleUnit and is_authority:
		var player := get_player(entity.owner_id)
		if entity.unit_type == "farmer":
			player.farmers += 1
		else:
			player.military_supply += BalanceCatalog.unit(entity.unit_type).supply

func are_hostile(a: Node3D, b: Node3D) -> bool:
	return a.alliance_id != b.alliance_id

func can_see_entity(owner: int, entity: Node3D) -> bool:
	return $FogOfWar.entity_visible(owner, entity) if _fog_ready else entity.alliance_id == get_player(owner).alliance_id

func can_see_position(owner: int, at: Vector3) -> bool:
	return $FogOfWar.position_visible(owner, at) if _fog_ready else true

func clamp_to_map(at: Vector3) -> Vector3:
	return Vector3(clampf(at.x, -map_size.x * 0.5 + 2, map_size.x * 0.5 - 2), 0,
		clampf(at.z, -map_size.y * 0.5 + 2, map_size.y * 0.5 - 2))

func next_command_sequence(owner: int) -> int:
	return command_bus.next_sequence(owner)

func submit_command(command: Dictionary, owner: int = -1) -> Dictionary:
	return command_bus.submit(command, local_owner_id if owner < 0 else owner)

func submit_local(command: Dictionary) -> Dictionary:
	command["seq"] = next_command_sequence(local_owner_id)
	if online and not is_authority:
		var error: Error = Session.relay.send_command(command)
		return {"ok": error == OK, "error": "网络连接暂不可用" if error != OK else ""}
	return submit_command(command)

func selected_ids() -> Array:
	return own_selected_units().map(func(unit): return unit.entity_id)

func selected_production() -> BattleBuilding:
	var buildings := own_selected_buildings()
	for building: BattleBuilding in buildings:
		if building.building_type == _production_group_kind:
			return building
	return buildings[0] if not buildings.is_empty() else null

func cycle_production_group() -> void:
	var buildings := own_selected_buildings()
	if buildings.is_empty():
		return
	var kinds: Array[String] = []
	for building: BattleBuilding in buildings:
		if building.building_type not in kinds:
			kinds.append(building.building_type)
	var current: String = selected_production().building_type
	_production_group_kind = kinds[(kinds.find(current) + 1) % kinds.size()]
	hud.refresh()
	hud.toast("%s · Tab 切换建筑类别" % selected_production().display_name, 2.0)

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

func spawn_building(kind: String, owner: int, at: Vector3, construction: bool = false, id: int = 0) -> BattleBuilding:
	var site: BattleBuilding = BUILDING_SCENE.instantiate()
	site.building_type = kind
	site.entity_id = id
	site.owner_id = owner
	site.team = get_player(owner).alliance_id
	site.under_construction = construction
	site.position = at
	site.sound_requested.connect(play_world_sound)
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
	elif online and is_authority:
		var now := Time.get_ticks_msec()
		if now >= int(_notice_after.get(owner, 0)):
			_notice_after[owner] = now + 200
			Session.relay.send_event(owner, {"kind": "notice", "text": message})

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

func _setup_match() -> void:
	online = Session.online
	if not Session.config.is_empty():
		match_config = Session.config.duplicate(true)
	if online:
		is_authority = Session.relay.is_host
		local_owner_id = Session.relay.owner_id
	var mode := "1v1"
	for candidate: String in NetworkProtocol.MODES:
		if "--" + candidate in OS.get_cmdline_user_args():
			mode = candidate
	if match_config.is_empty():
		match_config = Session.offline_config(mode)
	assert(NetworkProtocol.match_config_error(match_config, online).is_empty(), "Invalid match roster")
	players.clear()
	for slot: Dictionary in match_config.players:
		var player := PlayerState.new(int(slot.owner_id), int(slot.team_id))
		player.controller = slot.controller
		player.display_name = slot.name
		if not player.is_participating():
			player.gold = 0
		players.append(player)
	# Physical starts follow alliances even when the host rearranges room teams.
	# Owner IDs remain stable for commands, economy and network recipients.
	var spawn_order := players.filter(func(player: PlayerState): return player.is_participating())
	spawn_order.sort_custom(func(a: PlayerState, b: PlayerState): return a.alliance_id < b.alliance_id if a.alliance_id != b.alliance_id else a.owner_id < b.owner_id)
	var alliance_slots: Dictionary = {}
	_spawn_indices.clear()
	for player: PlayerState in spawn_order:
		var offset := int(alliance_slots.get(player.alliance_id, 0))
		_spawn_indices[player.owner_id] = player.alliance_id * int(NetworkProtocol.MODES[match_config.mode].team_size) + offset
		alliance_slots[player.alliance_id] = offset + 1
	map_definition = load(NetworkProtocol.map_path(match_config.mode))
	map_size = map_definition.size
	map_instance = map_definition.scene.instantiate()
	$MapContainer.add_child(map_instance)
	if not is_authority:
		camera_rig.focus_at(get_spawn_marker(local_owner_id).global_position, true)
		return
	for player: PlayerState in players:
		if not player.is_participating():
			continue
		var spawn: Marker3D = get_spawn_marker(player.owner_id)
		var at: Vector3 = spawn.global_position
		var base := spawn_building("headquarters", player.owner_id, at)
		# Maps author a clear tower site beside each player's left starting mine.
		# Only the authority creates opening assets; clients receive normal replicas.
		spawn_building("defense_tower", player.owner_id, map_instance.to_global(spawn.get_meta("starting_tower_position")))
		var mine := nearest_mine(at)
		base.production.rally_mine = mine
		base.rally_point = mine.global_position
		for index in range(3):
			var direction: Vector3 = (mine.global_position - at).normalized()
			var worker: BattleUnit = spawn_unit("farmer", player.owner_id, at + direction * 7 + Vector3(direction.z, 0, -direction.x) * (index - 1) * 1.7)
			worker.issue_gather(mine)
		if player.controller == "bot":
			bots[player.owner_id] = SkirmishBot.new(self, player.owner_id)
	camera_rig.focus_at(headquarters.position.move_toward(Vector3.ZERO, 5), true)

func get_spawn_marker(owner: int) -> Marker3D:
	return map_instance.get_node("SpawnPoints/Player%d" % int(_spawn_indices[owner]))

func check_victory() -> void:
	if finished or not _match_ready or not is_authority or tests_running:
		return
	var counts: Dictionary = {}
	var cores: Dictionary = {}
	for player: PlayerState in players:
		if not player.is_participating():
			continue
		counts[player.alliance_id] = 0
		cores[player.alliance_id] = 0
	for building: BattleBuilding in get_tree().get_nodes_in_group("buildings"):
		if not building.alive:
			continue
		counts[building.alliance_id] += 1
		if building.is_constructed and building.building_type in ["headquarters", "barracks", "factory"]:
			cores[building.alliance_id] += 1
	var remaining: Array[int] = []
	var newly_eliminated: Array[int] = []
	for alliance: int in counts:
		if cores[alliance] == 0 and alliance not in _revealed_alliances:
			_revealed_alliances.append(alliance)
			$FogOfWar.reveal_alliance_buildings(alliance)
		if counts[alliance] > 0:
			remaining.append(alliance)
		else:
			for player: PlayerState in players:
				if player.is_participating() and player.alliance_id == alliance and not player.eliminated:
					player.eliminated = true
					bots.erase(player.owner_id)
					if alliance not in newly_eliminated:
						newly_eliminated.append(alliance)
	if remaining.size() <= 1:
		var winner: int = remaining[0] if not remaining.is_empty() else -1
		end_battle(winner == get_player(local_owner_id).alliance_id, winner)
		return
	# An eliminated faction cannot rebuild after losing every military building.
	# Other factions continue; losing the host's faction does not stop simulation.
	for alliance: int in newly_eliminated:
		for unit: BattleUnit in get_tree().get_nodes_in_group("units"):
			if unit.alive and unit.alliance_id == alliance:
				unit.receive_damage(unit.hp)
		for player: PlayerState in players:
			if player.is_participating() and player.alliance_id == alliance:
				var message := "你的阵营已出局 · 比赛继续，可返回大厅"
				if online and player.owner_id == local_owner_id:
					message = "你的阵营已出局 · 请保持房间开启，其他玩家继续对战"
				notify_owner(player.owner_id, message)

func play_world_sound(kind: StringName, at: Vector3) -> void:
	queue_visible_visual(at, {"kind": "sound", "sound": String(kind), "at": vector_data(at)})
	if can_see_position(local_owner_id, at):
		$Audio.play_world(kind, at)


func _on_network_command(owner: int, command: Dictionary) -> void:
	if is_authority:
		submit_command(command, owner)

func _on_snapshot_applied(_tick: int) -> void:
	if selection.is_empty() and is_instance_valid(headquarters) and not game_started:
		select_entities([headquarters])
	game_started = true
	hud.refresh()

func _on_network_event(event: Dictionary) -> void:
	match str(event.get("kind", "")):
		"notice": hud.toast(str(event.get("text", "")), 2.5)
		"bot_takeover":
			var owner: int = int(event.owner)
			if is_authority and owner >= 0 and owner < players.size() and get_player(owner).is_participating() and not get_player(owner).eliminated:
				get_player(owner).controller = "bot"
				bots[owner] = SkirmishBot.new(self, owner)
		"player_reconnected":
			var owner: int = int(event.owner)
			if is_authority and owner >= 0 and owner < players.size() and get_player(owner).is_participating():
				get_player(owner).controller = "human"
				bots.erase(owner)
		"host_paused":
			set_match_paused(true)
			hud.toast("房主连接中断 · 等待恢复（最多 30 秒）", 30)
		"host_resumed", "connection_restored":
			set_match_paused(false)
			hud.toast("连接已恢复", 3)
		"pause": set_match_paused(event.get("paused", false) == true)
		"match_finished":
			var result: Dictionary = event.result
			elapsed = float(result.get("time", elapsed))
			end_battle(int(result.get("winner", -1)) == get_player(local_owner_id).alliance_id, int(result.get("winner", -1)))
		"match_aborted":
			set_match_paused(false)
			end_battle(false)
			hud.get_node("%ResultHeading").text = "对局已中断"
			hud.get_node("%ResultBody").text = "房主未能在 30 秒内恢复连接，本场比赛结束。"

func _on_connection_state(state: String) -> void:
	if not online or finished:
		return
	if state in ["reconnecting", "disconnected"]:
		if is_authority:
			set_match_paused(true)
		hud.toast("连接中断 · 正在尝试恢复", 10)
	elif state == "match" and _network_paused:
		set_match_paused(false)
	elif state == "error":
		set_match_paused(false)
		end_battle(false)
		hud.get_node("%ResultHeading").text = "对局连接已中断"
		hud.get_node("%ResultBody").text = "未能在重连时限内恢复连接，请返回大厅重新加入对局。"

func request_match_pause() -> void:
	if not is_authority:
		toggle_pause()
		return
	var value := not get_tree().paused
	Session.relay.send_event(-1, {"kind": "pause", "paused": value})
	set_match_paused(value)

func set_match_paused(value: bool) -> void:
	_network_paused = value
	get_tree().paused = value
	$Audio.set_world_paused(value)

func queue_visible_visual(at: Vector3, event: Dictionary) -> void:
	if not online or not is_authority or not _match_ready:
		return
	for player: PlayerState in players:
		if player.owner_id != local_owner_id and player.controller == "human" and can_see_position(player.owner_id, at):
			replication.queue_host_visual(player.owner_id, event)

func _play_network_visual(event: Dictionary) -> void:
	var data: Array = event.at
	var at := Vector3(float(data[0]), float(data[1]), float(data[2]))
	if not can_see_position(local_owner_id, at):
		return
	match str(event.kind):
		"effect":
			var color: Array = event.color
			spawn_effect(at, str(event.effect), Color(float(color[0]), float(color[1]), float(color[2])))
		"sound": $Audio.play_world(StringName(event.sound), at)
		"projectile":
			var origin: Array = event.from
			var projectile: BattleProjectile = PROJECTILE_SCENE.instantiate()
			effect_container.add_child(projectile)
			projectile.initialize_visual(Vector3(float(origin[0]), float(origin[1]), float(origin[2])), at, str(event.projectile), float(event.duration), float(event.arc), entities_by_id.get(int(event.target)))
