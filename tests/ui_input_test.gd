extends Node
## Drives Godot's real input dispatch without moving the user's desktop pointer.

var game: Node3D
var failures: Array[String] = []
var checks: int = 0

func check(condition: bool, label: String) -> void:
	checks += 1
	print(("PASS: " if condition else "FAIL: ") + label)
	if not condition:
		failures.append(label)

func mouse(at: Vector2, pressed: bool, button: MouseButton = MOUSE_BUTTON_LEFT, shift: bool = false) -> void:
	var event := InputEventMouseButton.new()
	event.position = at
	event.global_position = at
	event.button_index = button
	event.pressed = pressed
	event.shift_pressed = shift
	get_viewport().push_input(event, true)
	await get_tree().process_frame

func click(at: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT, shift: bool = false) -> void:
	await mouse(at, true, button, shift)
	await mouse(at, false, button, shift)

func key(code: Key, ctrl: bool = false, shift: bool = false) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = true
	event.ctrl_pressed = ctrl
	event.shift_pressed = shift
	Input.parse_input_event(event)
	await get_tree().process_frame
	event.pressed = false
	Input.parse_input_event(event)
	await get_tree().process_frame

func run(controller: Node3D) -> void:
	game = controller
	game.tests_running = true
	game.camera_rig.edge_scroll = false
	game.get_node("EnemyTimer").stop()
	game.get_node("IncomeTimer").stop()
	for entity in get_tree().get_nodes_in_group("entities"):
		entity.set_physics_process(false)
	await get_tree().create_timer(0.4).timeout
	var gold_before: int = game.gold
	var count_before: int = game.player_count()
	var recruit: Button = game.hud.get_node("CommandBar/Recruitment/Recruit0")
	await click(recruit.get_global_rect().get_center())
	check(game.gold == gold_before - 45 and game.player_count() == count_before + 1, "Actual recruit button receives mouse click and produces one swordsman")
	check(game.selection.size() == 1 and game.headquarters in game.selection, "Clicking production UI does not clear HQ selection")
	var unit = game.get_node("Units/Blue0")
	var projected: Vector2 = game.camera.unproject_position(unit.global_position + Vector3.UP)
	await click(projected)
	check(game.selection.size() == 1 and game.selection[0] == unit, "World mouse click picks a real 3D unit")
	var left_top := Vector2(INF, INF)
	var right_bottom := Vector2(-INF, -INF)
	for index in range(6):
		var point: Vector2 = game.camera.unproject_position(game.get_node("Units/Blue" + str(index)).global_position + Vector3(0, 0.7, 0))
		left_top = left_top.min(point)
		right_bottom = right_bottom.max(point)
	await mouse(left_top - Vector2(16, 16), true)
	var motion := InputEventMouseMotion.new()
	motion.position = right_bottom + Vector2(16, 16)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	get_viewport().push_input(motion, true)
	await get_tree().process_frame
	await mouse(right_bottom + Vector2(16, 16), false)
	check(game.own_selected_units().size() == 6, "Real drag-selection captures six soldiers")
	await key(KEY_2, true)
	await key(KEY_B)
	await key(KEY_2)
	check(game.own_selected_units().size() == 6, "Ctrl+2 and 2 dispatch to control group assignment and recall")
	game.select_entities([game.get_node("Units/Blue6")])
	await key(KEY_2, false, true)
	check(game.control_groups[2].size() == 7 and game.selection.size() == 1, "Shift+2 appends selected units to the existing group without recalling it")
	await key(KEY_2, false, true)
	check(game.control_groups[2].size() == 7, "Appending a member twice cannot duplicate it")
	await key(KEY_2)
	check(game.selection.size() == 7, "Number key recalls the expanded group")
	game.select_entities([unit])
	await key(KEY_2, true)
	check(game.control_groups[2].size() == 1, "Ctrl+2 replaces the group instead of appending")
	var command_at: Vector2 = game.camera.unproject_position(Vector3(-4, 0, 24))
	await click(command_at, MOUSE_BUTTON_RIGHT)
	check(unit.order_name == "移动中", "Real right click issues a move order")
	await click(command_at + Vector2(50, 0), MOUSE_BUTTON_RIGHT, true)
	check(unit.waypoint_queue.size() == 1, "Shift right click queues the next route")
	await key(KEY_H)
	check(unit.order_name == "坚守阵地", "H key dispatches hold position")
	await key(KEY_A)
	check(game.attack_mode, "A key displays attack targeting mode")
	await click(command_at)
	check(not game.attack_mode and unit.order_name == "攻击前进", "Attack targeting consumes left click without changing selection")
	await key(KEY_F1)
	check(game.hud.help_visible(), "F1 opens the field manual")
	await key(KEY_ESCAPE)
	check(not game.hud.help_visible() and not get_tree().paused, "Escape closes manual without pausing battle")
	await key(KEY_ESCAPE)
	check(get_tree().paused, "Escape pauses battle")
	# This runner remains active while paused, like the native HUD.
	await key(KEY_ESCAPE)
	check(not get_tree().paused, "Escape resumes through the pause UI")
	await key(KEY_B)
	await key(KEY_F12)
	gold_before = game.gold
	await key(KEY_E)
	check(game.gold == gold_before - 60, "Recruit shortcut E works after selecting HQ")
	check(game.camera_rig.edge_direction(Vector2(0, 450), Vector2(1600, 900)) == Vector2.LEFT, "Left window edge scrolls left")
	check(game.camera_rig.edge_direction(Vector2(1599, 899), Vector2(1600, 900)) == Vector2(1, 1), "Bottom-right corner scrolls diagonally even over HUD")
	check(game.camera_rig.edge_direction(Vector2(1919, 0), Vector2(1920, 1080)) == Vector2(1, -1), "Resized/fullscreen top-right corner scrolls diagonally")
	check(game.camera_rig.edge_direction(Vector2(800, 450), Vector2(1600, 900)) == Vector2.ZERO, "Center of window never edge-scrolls")
	check(game.camera_rig.edge_direction(Vector2(-1, 20), Vector2(1600, 900)) == Vector2.ZERO, "Pointer outside window cannot scroll the battle")
	var report := {"checks": checks, "failures": failures, "passed": failures.is_empty()}
	var file := FileAccess.open("res://artifacts/ui-input-results.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("UI INPUT: %d checks, %d failures" % [checks, failures.size()])
	await game.prepare_shutdown()
	get_tree().quit(0 if failures.is_empty() else 1)
