extends Node
## Exercises the actual main scene, native input events and recruitment economy.

var failures: Array[String] = []
var checks: int = 0
var game: Node3D

func check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("PASS: " + message)
	else:
		failures.append(message)
		push_error("FAIL: " + message)

func run(controller: Node3D) -> void:
	game = controller
	game.tests_running = true
	game.get_node("EnemyTimer").stop()
	for entity in get_tree().get_nodes_in_group("entities"):
		entity.set_physics_process(false)
	await get_tree().physics_frame
	check(game.player_count() == 16, "Authored starting force contains five military classes and two farmers")
	check(game.enemy_count() == 27, "Authored enemy deployment is complete")
	check(game.get_node("Buildings").get_child_count() == 5, "HQ and four hostile military buildings exist")
	check(game.headquarters in game.selection, "HQ selected at game start")
	var baseline: int = game.gold
	await get_tree().create_timer(1.1).timeout
	check(game.gold == baseline + 1, "Economy accrues exactly one gold per second")
	game.get_node("IncomeTimer").stop()
	var cheat := InputEventKey.new()
	cheat.physical_keycode = KEY_F12
	cheat.pressed = true
	Input.parse_input_event(cheat)
	await get_tree().process_frame
	check(game.gold == baseline + 101, "Mapped F12 input awards exactly 100 gold")
	cheat.pressed = false
	Input.parse_input_event(cheat)
	game.gold = 1000
	var before: int = game.player_count()
	var expected: int = 1000
	for kind in game.UNIT_TYPES:
		var recruited: bool = game.recruit(kind)
		expected -= game.UNIT_COSTS[kind]
		check(recruited and game.gold == expected, "Immediate recruitment charges correct cost: " + kind)
	check(game.player_count() == before + 6, "Six recruits exist immediately without a queue timer")
	game.gold = 0
	before = game.player_count()
	check(not game.recruit("swordsman") and game.player_count() == before, "Unaffordable recruitment cannot create a free unit")
	game.select_army()
	var military_count: int = get_tree().get_nodes_in_group("friendly_units").filter(func(unit): return unit.alive and unit.unit_type != "farmer").size()
	check(game.own_selected_units().size() == military_count, "Select army excludes workers, enemies and buildings")
	game.use_control_group(3, true)
	var assigned: int = game.selection.size()
	game.select_entities([])
	game.use_control_group(3)
	check(game.selection.size() == assigned, "Control group recalls the saved army")
	var first = game.selection[0]
	var second = game.selection[1]
	game.select_entities([first])
	game.select_entities([second], true)
	check(game.selection.size() == 2, "Shift selection appends a unit")
	game.select_entities([first], true, true)
	check(game.selection.size() == 1 and game.selection[0] == second, "Shift click toggles selected units")
	game.gold = 500
	check(not game.recruit("knight") and game.gold == 500, "Recruitment requires selecting the headquarters")
	game.select_entities([game.headquarters])
	var rally := Vector3(-8, 0, 24)
	game.command_move(rally)
	check(game.rally_point.is_equal_approx(rally), "Right-click ground updates HQ rally point")
	var test_unit = game.spawn_unit("swordsman", 0, Vector3(-8, 0, 26))
	test_unit.set_physics_process(true)
	game.select_entities([test_unit])
	game.command_move(Vector3(-3, 0, 26))
	await get_tree().create_timer(2.5).timeout
	check(test_unit.global_position.x > -5.0, "Formation move traverses the authored navigation map")
	game.hold_selected()
	check(test_unit.order_name == "坚守阵地", "Hold position command reaches combat entity")
	game.stop_selected()
	check(test_unit.order_name == "待命", "Stop command cancels movement")
	game.set_attack_mode(true)
	check(game.attack_mode and game.overlay.attack_cursor, "Attack move mode exposes target cursor")
	game.set_attack_mode(false)
	var dead_enemy = get_tree().get_nodes_in_group("enemy_units")[0]
	var kill_count: int = game.kills
	dead_enemy.receive_damage(10000, test_unit)
	check(game.kills == kill_count + 1, "Death callback increments enemy defeat count")
	game.use_control_group(5, true)
	test_unit.receive_damage(10000)
	game.use_control_group(5)
	check(game.selection.is_empty(), "Dead members are removed from recalled control groups")
	var reward_before: int = game.gold
	var enemy_building = game.get_node("Buildings/NorthBarracks")
	enemy_building.receive_damage(10000)
	check(game.buildings_destroyed == 1 and game.gold == reward_before + 90, "Destruction grants bounty and updates military objective")
	check(not enemy_building.alive and enemy_building.get_node("Rubble").visible, "Destroyed building keeps visible rubble")
	game.hud.toggle_help()
	check(game.hud.help_visible(), "Field manual opens")
	game.hud.toggle_help()
	game.toggle_pause()
	check(get_tree().paused, "Pause stops the scene tree")
	game.toggle_pause()
	check(not get_tree().paused, "Pause resumes through controller")
	game.tests_running = false
	for entity in get_tree().get_nodes_in_group("buildings").duplicate():
		if entity.team == 1:
			entity.receive_damage(10000)
	check(game.finished and game.buildings_destroyed == 4, "Destroying every enemy military building completes victory")
	var report := {"checks": checks, "failures": failures, "passed": failures.is_empty()}
	var report_file := FileAccess.open("res://artifacts/integration-results.json", FileAccess.WRITE)
	report_file.store_string(JSON.stringify(report, "  "))
	report_file.close()
	print("INTEGRATION: %d checks, %d failures" % [checks, failures.size()])
	await game.prepare_shutdown()
	get_tree().quit(0 if failures.is_empty() else 1)
