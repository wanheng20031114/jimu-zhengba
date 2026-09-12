extends "res://scripts/game.gd"
## Offline scenario authoring uses the real combat, orders, navigation and pools.
## It has its own lifecycle: no roster handshake, economy, fog or victory checks.
const UNIT_LIMIT := 500
var running: bool = false
var placing: bool = true
var paint_kind: String = "swordsman"
var paint_count: int = 1
var paint_rotation: float = 0.0
var map_mode: String = "1v1"
var sandbox_unit_count: int = 0
var _placement_shape := CylinderShape3D.new()
var _paint_query := PhysicsShapeQueryParameters3D.new()
var _ghost: UnitVisual
var _ghost_check: float = 0.0
var _busy: bool = true

func _ready() -> void:
	get_tree().auto_accept_quit = false
	assert(not Session.online, "Sandbox is offline only")
	players.clear()
	for owner: int in FactionPalette.SANDBOX_COLORS.size():
		var player := PlayerState.new(owner, owner)
		player.display_name = "%02d · %s" % [owner + 1, FactionPalette.SANDBOX_NAMES[owner]]
		player.controller = "human"
		player.gold = 0
		players.append(player)
	command_bus = MatchCommands.new(self)
	map_mode = Session.config.get("mode", "1v1")
	map_definition = load(NetworkProtocol.map_path(map_mode))
	map_size = map_definition.size
	map_instance = map_definition.scene.instantiate()
	$MapContainer.add_child(map_instance)
	$ConstructionNavigation.refresh()
	$StaticMotionGrid.configure(map_instance, $Buildings, Rect2(-map_size * 0.5, map_size))
	_placement_shape.height = 2.0
	_paint_query.shape = _placement_shape
	_paint_query.collision_mask = 2 | 4 | 128
	_paint_query.margin = 0.03
	hud.bind_game(self)
	settings.pause_requested.connect(handle_pause_action)
	camera_rig.focus_at(Vector3.ZERO, true)
	set_paint_kind("swordsman")
	set_running(false)
	game_started = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	_busy = false
	_match_ready = true
	hud.refresh()

func presentation_faction(owner: int, _alliance: int) -> int:
	return FactionPalette.SANDBOX_OFFSET + owner

func command_unit_limit(_owner: int) -> int:
	return UNIT_LIMIT

func spawn_unit(kind: String, faction: int, at: Vector3, id: int = 0) -> Node3D:
	var unit: BattleUnit = super.spawn_unit(kind, faction, at, id)
	# Paused troops remain obstacles and mouse-pick targets. Native REMOVE mode
	# would remove disabled bodies from the physics space and allow overlap.
	unit.disable_mode = CollisionObject3D.DISABLE_MODE_KEEP_ACTIVE
	return unit

func register_entity(entity: Node3D) -> void:
	super.register_entity(entity)
	if entity is BattleUnit:
		sandbox_unit_count += 1

func on_entity_died(entity: Node3D) -> void:
	if entity is BattleUnit:
		sandbox_unit_count -= 1
	super.on_entity_died(entity)

func can_see_entity(_owner: int, entity: Node3D) -> bool:
	return is_instance_valid(entity) and entity.alive

func can_see_position(_owner: int, _at: Vector3) -> bool:
	return true

func _physics_process(delta: float) -> void:
	if _busy or finished:
		return
	command_bus.tick()
	if running:
		simulation_tick += 1
		elapsed += delta

func _process(delta: float) -> void:
	_ui_accumulator += delta
	if _ui_accumulator >= 0.2:
		_ui_accumulator = 0.0
		_prune_selection()
		hud.refresh()
	if dragging:
		overlay.box_end = get_viewport().get_mouse_position()
		overlay.box_visible = overlay.box_start.distance_to(overlay.box_end) > 6.0
	var show_ghost: bool = placing and not _busy and not settings.is_open() and get_viewport().gui_get_hovered_control() == null
	$PlacementPreview.visible = show_ghost
	if show_ghost:
		var at: Vector3 = camera_rig.world_at(get_viewport().get_mouse_position())
		$PlacementPreview.position = at
		$PlacementPreview.rotation.y = paint_rotation
		_ghost_check -= delta
		if _ghost_check <= 0.0:
			_ghost_check = 0.10
			var valid: bool = placement_valid(at, paint_kind)
			_ghost.set_team(presentation_faction(local_owner_id, local_owner_id) if valid else FactionPalette.ENEMY)

func set_running(value: bool) -> void:
	running = value
	var mode: ProcessMode = Node.PROCESS_MODE_INHERIT if running else Node.PROCESS_MODE_DISABLED
	$Units.process_mode = mode
	$ProjectilePool.process_mode = mode
	$EffectPool.process_mode = mode
	# Keep physics-space queries and the camera alive while troops are paused.
	hud.refresh()

func handle_pause_action() -> void:
	if not _busy:
		set_running(not running)

func set_placing(value: bool) -> void:
	placing = value
	if value:
		set_attack_mode(false)
	dragging = false
	overlay.box_visible = false
	hud.refresh()

func set_paint_kind(kind: String) -> void:
	paint_kind = kind
	for model: UnitVisual in $PlacementPreview/Models.get_children():
		model.visible = model.kind == kind
		if model.visible:
			_ghost = model
			model.set_team(presentation_faction(local_owner_id, local_owner_id))
	set_placing(true)
	_ghost_check = 0.0

func set_faction(owner: int) -> void:
	select_entities([])
	set_attack_mode(false)
	dragging = false
	overlay.box_visible = false
	local_owner_id = owner
	control_groups.clear()
	_last_group = -1
	_ghost.set_team(presentation_faction(owner, owner))
	_ghost_check = 0.0
	hud.refresh()

func placement_valid(at: Vector3, kind: String) -> bool:
	if not at.is_finite() or at.distance_squared_to(clamp_to_map(at)) > 0.001:
		return false
	if not $ConstructionNavigation.contains_walkable_point(at):
		return false
	_placement_shape.radius = BalanceCatalog.unit(kind).radius + 0.06
	_paint_query.transform.origin = at + Vector3.UP
	return get_world_3d().direct_space_state.intersect_shape(_paint_query, 1).is_empty()

func place_units(at: Vector3) -> int:
	if _busy or finished:
		return 0
	var available: int = UNIT_LIMIT - sandbox_unit_count
	if available <= 0:
		hud.toast("沙盘最多同时放置 500 个单位", 3.0)
		return 0
	var amount: int = mini(paint_count, available)
	var columns: int = ceili(sqrt(float(amount)))
	var rows: int = ceili(float(amount) / columns)
	var spacing: float = maxf(1.65, BalanceCatalog.unit(paint_kind).radius * 2.5)
	var basis := Basis(Vector3.UP, paint_rotation)
	var placed: int = 0
	for index: int in amount:
		var offset := Vector3((index % columns - (columns - 1) * 0.5) * spacing, 0, (floori(float(index) / columns) - (rows - 1) * 0.5) * spacing)
		var point: Vector3 = at + basis * offset
		if not placement_valid(point, paint_kind):
			continue
		var unit: BattleUnit = spawn_unit(paint_kind, local_owner_id, point)
		unit.model_pivot.rotation.y = paint_rotation
		unit.reset_physics_interpolation()
		placed += 1
	hud.toast("已放置 %d 名%s · %s" % [placed, UNIT_NAMES[paint_kind], players[local_owner_id].display_name] if placed > 0 else "这里被占用，或无法通行", 2.5)
	hud.refresh()
	return placed

func remove_selected() -> void:
	for entity: Node3D in selection.duplicate():
		if not entity is BattleUnit:
			continue
		forget_entity_selection(entity)
		entities_by_id.erase(entity.entity_id)
		sandbox_unit_count -= 1
		var player: PlayerState = get_player(entity.owner_id)
		if entity.unit_type == "farmer":
			player.farmers -= 1
		else:
			player.military_supply -= entity.get_combat_definition().supply
		entity.stop()
		entity.navigation_agent.avoidance_enabled = false
		entity.set_physics_process(false)
		entity.queue_free()
	hud.refresh()

func clear_units() -> void:
	select_entities([])
	command_bus.pending.clear()
	control_groups.clear()
	_last_click_entity = null
	$ProjectilePool.reset_all()
	$EffectPool.reset_all()
	for unit: BattleUnit in $Units.get_children():
		entities_by_id.erase(unit.entity_id)
		unit.stop()
		unit.navigation_agent.avoidance_enabled = false
		unit.set_physics_process(false)
		unit.queue_free()
	sandbox_unit_count = 0
	for player: PlayerState in players:
		player.farmers = 0
		player.military_supply = 0
		player.kills = 0
	elapsed = 0.0
	hud.refresh()

func switch_map(mode: String) -> void:
	if _busy or mode == map_mode:
		return
	_busy = true
	hud.refresh()
	await prepare_shutdown()
	Session.start_sandbox(mode)

func return_to_menu() -> void:
	if _closing:
		return
	_closing = true
	_busy = true
	await prepare_shutdown()
	Session.back_to_lobby()

func _input(event: InputEvent) -> void:
	if settings.is_open() or _busy:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key: Key = settings.resolve_key(event)
		if key == KEY_F5:
			handle_pause_action()
			get_viewport().set_input_as_handled()
		elif key == KEY_ESCAPE:
			set_placing(false)
			set_attack_mode(false)
			get_viewport().set_input_as_handled()
		elif key == KEY_F11:
			settings.toggle_fullscreen()
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
		camera_rig.dragging = event.pressed
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and camera_rig.dragging:
		camera_rig.drag_by(event.relative)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed and dragging:
		dragging = false
		overlay.box_visible = false
		_finish_selection(event.position)
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if _busy or settings.is_open():
		return
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP: camera_rig.zoom_by(-3)
			MOUSE_BUTTON_WHEEL_DOWN: camera_rig.zoom_by(3)
			MOUSE_BUTTON_LEFT:
				if placing:
					place_units(camera_rig.world_at(event.position))
				elif attack_mode:
					var target := entity_at(event.position)
					if is_instance_valid(target) and target.alliance_id != local_owner_id:
						command_attack(target, event.shift_pressed)
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
			MOUSE_BUTTON_RIGHT:
				if placing:
					set_placing(false)
				else:
					var target := entity_at(event.position)
					if is_instance_valid(target) and target is ResourceVein:
						command_gather(target, event.shift_pressed)
					elif is_instance_valid(target) and target is BattleUnit and target.owner_id != local_owner_id:
						command_attack(target, event.shift_pressed)
					else:
						command_move(camera_rig.world_at(event.position), attack_mode, event.shift_pressed)
					set_attack_mode(false)
	if event is InputEventKey and event.pressed and not event.echo:
		var key: Key = settings.resolve_key(event)
		if key >= KEY_1 and key <= KEY_9:
			use_control_group(key - KEY_0, event.ctrl_pressed, event.shift_pressed)
			return
		match key:
			KEY_F2, KEY_G: select_army()
			KEY_SPACE: focus_selection()
			KEY_DELETE: remove_selected()
			KEY_A:
				set_placing(false)
				set_attack_mode(true)
			KEY_S: stop_selected()
			KEY_H: hold_selected(event.shift_pressed)
			KEY_R: rotate_placement()
			KEY_Q: set_paint_kind("swordsman")
			KEY_W: set_paint_kind("archer")
			KEY_E: set_paint_kind("knight")

func rotate_placement() -> void:
	paint_rotation = wrapf(paint_rotation + PI * 0.5, 0.0, TAU)
	hud.refresh()
