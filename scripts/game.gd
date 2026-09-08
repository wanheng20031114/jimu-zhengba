extends Node3D

const UNIT_SCENE: PackedScene = preload("res://scenes/unit.tscn")
const PROJECTILE_SCENE: PackedScene = preload("res://scenes/projectile.tscn")
const EFFECT_SCENE: PackedScene = preload("res://scenes/battle_effect.tscn")
const UNIT_TYPES := ["swordsman", "archer", "knight", "catapult", "cannon"]
const UNIT_COSTS := {"swordsman": 45, "archer": 60, "knight": 100, "catapult": 140, "cannon": 180}
const UNIT_NAMES := {"swordsman": "剑士", "archer": "弓箭手", "knight": "骑士", "catapult": "投石车", "cannon": "加农炮"}
const MAX_ARMY: int = 160
const EFFECT_SOUNDS: Dictionary = {"hit": &"sword_hit", "wood_hit": &"wood_hit", "stone_chip": &"stone_chip", "arrow_hit": &"arrow_hit", "muzzle": &"cannon_shot", "explosion": &"explosion", "stone_hit": &"stone_hit", "collapse": &"collapse"}

@onready var camera_rig = $CameraRig
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var hud = $HUD/Interface
@onready var overlay = $HUD/SelectionOverlay
@onready var headquarters = $Buildings/Headquarters
@onready var unit_container: Node3D = $Units
@onready var effect_container: Node3D = $Effects

var gold: int = 320
var elapsed: float = 0.0
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

func _ready() -> void:
	get_tree().auto_accept_quit = false
	hud.bind_game(self)
	for entity: Node3D in get_tree().get_nodes_in_group("entities"):
		entity.sound_requested.connect($Audio.play_world)
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
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.team == 1:
			unit.hold()
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

func _process(delta: float) -> void:
	if not finished:
		elapsed += delta
	$RallyMarker.visible = headquarters.alive and headquarters in selection
	_ui_accumulator += delta
	if _ui_accumulator > 0.12:
		_ui_accumulator = 0.0
		_prune_selection()
		hud.refresh()
	if dragging:
		overlay.box_end = get_viewport().get_mouse_position()
		overlay.box_visible = overlay.box_start.distance_to(overlay.box_end) > 6.0

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
			if attack_mode:
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
			if attack_mode:
				var entity := entity_at(event.position)
				if is_instance_valid(entity) and entity.team == 1:
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
			set_attack_mode(false)
			var entity := entity_at(event.position)
			if is_instance_valid(entity) and entity.team == 1:
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
			KEY_P: toggle_pause()
			KEY_M:
				toggle_sound()

func entity_at(screen: Vector2) -> Node3D:
	var from := camera.project_ray_origin(screen)
	var ray := PhysicsRayQueryParameters3D.create(from, from + camera.project_ray_normal(screen) * 200.0, 6)
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if not hit.is_empty() and hit.collider.is_in_group("entities") and hit.collider.alive:
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
			if unit.team == 0 and unit.alive and not camera.is_position_behind(unit.global_position):
				if box.has_point(camera.unproject_position(unit.global_position + Vector3(0, 0.7, 0))):
					picked.append(unit)
		select_entities(picked, shift_drag)
	else:
		var entity := entity_at(at)
		if is_instance_valid(entity):
			var now := Time.get_ticks_msec() / 1000.0
			if entity == _last_click_entity and now - _last_click_time < 0.30 and entity.is_in_group("units") and entity.team == 0:
				var same: Array[Node3D] = []
				for unit in get_tree().get_nodes_in_group("units"):
					if unit.alive and unit.team == 0 and unit.unit_type == entity.unit_type and camera.is_position_in_frustum(unit.global_position):
						same.append(unit)
				select_entities(same, shift_drag)
			else:
				select_entities([entity], shift_drag, shift_drag)
			_last_click_entity = entity
			_last_click_time = now
		elif not shift_drag:
			select_entities([])

func select_entities(entities: Array, additive: bool = false, toggle: bool = false) -> void:
	if not additive:
		for entity in selection:
			if is_instance_valid(entity):
				entity.set_selected(false)
		selection.clear()
	for entity in entities:
		if not is_instance_valid(entity) or not entity.alive:
			continue
		if additive and entity.team != 0:
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
		if is_instance_valid(entity) and entity.alive and entity.team == 0 and entity.is_in_group("units"):
			result.append(entity)
	return result

func command_move(destination: Vector3, assault: bool = false, queued: bool = false) -> void:
	var army := own_selected_units()
	if army.is_empty():
		if headquarters in selection and headquarters.alive:
			rally_point = destination
			$RallyMarker.global_position = destination
			spawn_effect(destination, "move", Color("e6bd69"))
			$Audio.play_ui(&"order")
			hud.toast("集结点已设置", 2.0)
		return
	var columns := int(ceil(sqrt(float(army.size()))))
	var spacing: float = 1.65
	for unit in army:
		spacing = maxf(spacing, unit.radius * 2.5)
	var center := Vector3.ZERO
	for unit in army:
		center += unit.global_position
	center /= army.size()
	var forward := (destination - center).normalized()
	if forward.length_squared() < 0.01:
		forward = Vector3.FORWARD
	var right := Vector3(-forward.z, 0, forward.x)
	for index in range(army.size()):
		var row := index / columns
		var column := index % columns
		var offset := right * (float(column) - float(columns - 1) * 0.5) * spacing - forward * float(row) * spacing
		var target := destination + offset
		target.x = clampf(target.x, -39, 39)
		target.z = clampf(target.z, -39, 39)
		if queued:
			army[index].queue_move(target, assault)
		else:
			army[index].issue_move(target, assault)
	spawn_effect(destination, "attack" if assault else "move", Color("ee9e57") if assault else Color("91d0ee"))
	$Audio.play_ui("order")
	hud.toast(("攻击前进" if assault else "行军") + (" · 路径已追加" if queued else ""), 1.5)

func command_attack(target: Node3D) -> void:
	if not is_instance_valid(target) or not target.alive:
		return
	for unit in own_selected_units():
		unit.issue_attack(target)
	spawn_effect(target.global_position, "attack", Color("ff7851"))
	$Audio.play_ui("order")
	hud.toast("集中攻击 · " + target.display_name, 1.8)

func stop_selected() -> void:
	for unit in own_selected_units():
		unit.stop()
	set_attack_mode(false)
	$Audio.play_ui(&"order")
	hud.toast("部队停止", 1.5)

func hold_selected() -> void:
	for unit in own_selected_units():
		unit.hold()
	set_attack_mode(false)
	$Audio.play_ui(&"order")
	hud.toast("坚守阵地", 1.5)

func set_attack_mode(value: bool) -> void:
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
		if unit.alive and unit.team == 0:
			army.append(unit)
	select_entities(army)

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
	if finished or get_tree().paused:
		return false
	if not headquarters.alive or headquarters not in selection:
		$Audio.play_ui(&"denied")
		hud.toast("选择大本营后招募部队 · 快捷键 B", 2.5)
		return false
	if gold < UNIT_COSTS[kind]:
		$Audio.play_ui(&"denied")
		hud.toast("金币不足 · 需要 %d 金币" % UNIT_COSTS[kind], 2.0)
		return false
	if player_count() >= MAX_ARMY:
		$Audio.play_ui(&"denied")
		hud.toast("军队已达 %d 人上限" % MAX_ARMY, 2.5)
		return false
	gold -= UNIT_COSTS[kind]
	var at: Vector3 = headquarters.global_position + Vector3(float(_spawn_index % 5 - 2) * 1.25, 0, 6.0 + float(_spawn_index % 2) * 1.3)
	_spawn_index += 1
	var unit := spawn_unit(kind, 0, at)
	var target := rally_point + Vector3(randf_range(-2, 2), 0, randf_range(-2, 2))
	unit.issue_move(target)
	spawn_effect(at, "spawn", Color("84bfd9"))
	$Audio.play_ui(&"recruit")
	hud.toast(UNIT_NAMES[kind] + "已加入军队", 1.8)
	hud.refresh()
	return true

func spawn_unit(kind: String, faction: int, at: Vector3) -> Node3D:
	var unit: Node3D = UNIT_SCENE.instantiate()
	unit.unit_type = kind
	unit.team = faction
	unit.position = at
	unit.sound_requested.connect($Audio.play_world)
	unit_container.add_child(unit)
	return unit

func spawn_projectile(source: Node3D, target: Node3D, damage: float, kind: String) -> void:
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
	if entity.is_in_group("buildings"):
		get_node("ClearedNavigation/" + str(entity.name)).enabled = true
	if entity.team == 1:
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
	if not finished:
		gold += 1

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
		if unit.alive and unit.team == 0:
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
		unit.set_physics_process(false)
		unit.get_node("AttackWindup").stop()
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
