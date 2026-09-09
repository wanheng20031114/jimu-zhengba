extends SceneTree
## Exercise native mouse/keyboard events through the actual battle viewport.

var game: Node3D
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("FAIL ", label)

func unit(kind: String, owner: int, at: Vector3) -> BattleUnit:
	var result: BattleUnit = game.spawn_unit(kind, owner, at)
	result.stop()
	result.set_physics_process(false)
	result.navigation_agent.avoidance_enabled = false
	return result

func point(entity: Node3D) -> Vector2:
	return game.camera.unproject_position(entity.global_position + Vector3.UP)

func mouse(at: Vector2, pressed: bool, ctrl: bool = false, shift: bool = false) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = at
	event.global_position = at
	event.pressed = pressed
	event.ctrl_pressed = ctrl
	event.shift_pressed = shift
	root.push_input(event, true)

func click(entity: Node3D, ctrl: bool = false, shift: bool = false, consecutive: bool = false) -> void:
	if not consecutive:
		game._last_click_time = -1.0
	mouse(point(entity), true, ctrl, shift)
	mouse(point(entity), false, ctrl, shift)
	await process_frame

func key(code: Key, ctrl: bool = false, shift: bool = false) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = code
		event.pressed = pressed
		event.ctrl_pressed = ctrl
		event.shift_pressed = shift
		root.push_input(event, true)
	await process_frame

func _run() -> void:
	create_timer(30.0, true, false, true).timeout.connect(func(): quit(3))
	root.get_node("Session").start_offline("2v2")
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	game.tests_running = true
	game.bots.clear()
	game.set_physics_process(false)
	game.get_node("IncomeTimer").stop()
	game.camera_rig.edge_scroll = false
	game.camera_rig.focus_at(Vector3.ZERO, true)
	for entity: BattleUnit in get_nodes_in_group("units"):
		entity.stop()
		entity.set_physics_process(false)
		entity.navigation_agent.avoidance_enabled = false
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	var saved: Dictionary = game.settings.snapshot()
	game.settings._apply_values(game.settings.defaults(), false)
	var first := unit("swordsman", 0, Vector3.ZERO)
	var second := unit("swordsman", 0, Vector3(4, 0, 0))
	var offscreen := unit("swordsman", 0, Vector3(55, 0, 40))
	var archer := unit("archer", 0, Vector3(-4, 0, 4))
	var ally := unit("swordsman", 1, Vector3(7, 0, 3))
	var enemy := unit("swordsman", 2, Vector3(0, 0, -7))
	game.get_node("FogOfWar")._recompute()
	await physics_frame
	await physics_frame
	check(game.entity_at(point(first)) == first, "real camera ray hits the clicked owned unit")
	check(game.camera.is_position_in_frustum(second.global_position) and not game.camera.is_position_in_frustum(offscreen.global_position), "fixture includes an on-screen peer and an off-screen peer")
	await click(first)
	check(game.selection == [first], "plain click still selects one unit")
	await click(first, false, false, true)
	var double_selection: Array = game.selection.duplicate()
	check(double_selection.size() == 2 and second in double_selection, "existing double-click selects the on-screen same-type pair")
	game.select_entities([archer])
	await click(first, true)
	check(game.selection == double_selection, "Ctrl click reuses the exact double-click selection range")
	check(offscreen not in game.selection, "Ctrl click does not select the off-screen owned peer")
	check(ally not in game.selection and enemy not in game.selection, "Ctrl type selection excludes ally and enemy assets")
	check(archer not in game.selection, "unshifted Ctrl click replaces previous other-type selection")
	game.select_entities([archer])
	await click(first, true, true)
	check(game.selection.size() == 3 and archer in game.selection and second in game.selection, "Ctrl Shift click appends the full type to existing selection")
	await click(first, true, true)
	check(game.selection.size() == 3 and first in game.selection, "repeated Ctrl Shift click does not toggle the type off")
	await click(archer, false, true)
	check(game.selection.size() == 2 and archer not in game.selection, "plain Shift click keeps its individual toggle behavior")
	await click(enemy, true)
	check(game.selection == [enemy] and game.own_selected_units().is_empty(), "Ctrl click can inspect an enemy but cannot control it")
	await click(ally, true)
	check(game.selection == [ally] and game.own_selected_units().is_empty(), "Ctrl click can inspect an ally but cannot control it")
	game.select_entities([first])
	await click(enemy, true, true)
	check(game.selection == [first], "Ctrl Shift cannot append an enemy to owned selection")
	game.select_entities([])
	var at: Vector2 = point(first)
	mouse(at - Vector2(12, 12), true, true)
	mouse(at + Vector2(12, 12), false, true)
	await process_frame
	check(game.selection == [first], "Ctrl drag still performs a rectangle rather than same-type selection")
	await key(KEY_3, true)
	check(game.control_groups.get(3, []) == [first], "Ctrl number still creates an ordinary control group")
	game.select_entities([second])
	await key(KEY_3, false, true)
	check(game.control_groups[3].size() == 2 and second in game.control_groups[3], "Shift number still appends to the existing group")
	game.select_entities([archer])
	await key(KEY_3)
	check(game.selection.size() == 2 and first in game.selection and second in game.selection, "plain number recalls the stored group")
	game.settings._apply_values(saved, false)
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("CTRL_TYPE_SELECTION_RESULTS " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)
