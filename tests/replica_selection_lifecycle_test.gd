extends SceneTree
## The real Game/HUD and native replica retirement, before deferred free and
## before the 120 ms selection refresh. The live-network suite covers delivery.
var game: Node3D
var checks: int = 0
var failures: Array[String] = []
var completed_cases: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		printerr("REPLICA_SELECTION_FAIL ", label)

func _run() -> void:
	create_timer(25.0, true, false, true).timeout.connect(func(): quit(3))
	AudioServer.set_bus_mute(0, true)
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	for scenario: String in ["single_knight", "mixed_knight", "hidden_enemy", "construction"]:
		await _case(scenario)
	_check(completed_cases == ["single_knight", "mixed_knight", "hidden_enemy", "construction"], "all lifecycle cases complete despite any script errors")
	var report := {"checks": checks, "failures": failures, "cases": completed_cases,
		"audio": AudioServer.get_driver_name(), "display": DisplayServer.get_name()}
	var file := FileAccess.open("res://artifacts/replica_selection_lifecycle_results.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("REPLICA_SELECTION_RESULT ", JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)

func _case(scenario: String) -> void:
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.bots.clear()
	game.camera_rig.edge_scroll = false
	game.camera_rig.focus_at(Vector3.ZERO, true)
	await create_timer(0.15).timeout
	var survivor: BattleUnit = game.spawn_unit("swordsman", 0, Vector3(2, 0, 0))
	survivor.set_physics_process(false)
	survivor.navigation_agent.avoidance_enabled = false
	var retiring: Node3D
	if scenario == "construction":
		retiring = game.spawn_building("barracks", 0, Vector3.ZERO, true)
	else:
		retiring = game.spawn_unit("knight", 1 if scenario == "hidden_enemy" else 0, Vector3.ZERO)
		retiring.set_physics_process(false)
		retiring.navigation_agent.avoidance_enabled = false
	game.get_node("FogOfWar").tick(FogOfWar.UPDATE_SECONDS)
	game.online = true
	game.is_authority = false
	game.replication.configure(game, root.get_node("Session").relay)
	game.replication._replicas[retiring.entity_id] = retiring
	game.select_entities([retiring, survivor] if scenario == "mixed_knight" else [retiring])
	if scenario != "hidden_enemy":
		game.use_control_group(1, true)
		game.control_groups[2] = [retiring]
	game._last_click_entity = retiring
	game._last_click_time = Time.get_ticks_msec() / 1000.0
	game.dragging = true
	game.drag_start = Vector2(400, 220)
	game.shift_drag = true
	game.ctrl_drag = true
	game._ui_accumulator = 0.0
	var before_gold: int = game.gold
	var before_supply: int = game.get_player(0).military_supply
	var before_kills: int = game.kills
	var before_buildings: int = game.buildings_destroyed
	var before_effects: int = game.get_node("EffectPool").active_count()
	var before_sounds: int = game.get_node("Audio")._playbacks.size()
	var retired_id: int = retiring.entity_id
	game.replication._remove_replica(retired_id)
	_check(is_instance_valid(retiring) and retiring.is_queued_for_deletion(), scenario + " observes retirement before deferred node deletion")
	_check(retiring not in game.selection, scenario + " synchronously removes selection without waiting for refresh")
	_check(game.control_groups.values().all(func(group): return retiring not in group), scenario + " removes the cached entity from every control group")
	_check(game._last_click_entity == null and game._last_click_time < 0, scenario + " invalidates same-type click history")
	_check(game.gold == before_gold and game.get_player(0).military_supply == before_supply and game.kills == before_kills and game.buildings_destroyed == before_buildings,
		scenario + " retires presentation without guessing authority economy or death scores")
	_check(game.get_node("EffectPool").active_count() == before_effects and game.get_node("Audio")._playbacks.size() == before_sounds,
		scenario + " disappearance produces no fabricated death effects or sounds")
	if scenario == "construction":
		_check(game.selected_production() == null and game.hud._actions[0].kind == "cancel_site", "stale cancel-site button outlives the removed selected site")
		_check(int(game.hud._actions[0].target) == retired_id, "cancel-site action retains the displayed stable entity ID")
		# Exactly the native Button signal binding; selected_production is null.
		game.hud.get_node("%Recruit0").pressed.emit()
		_check(game.gold == before_gold and game.selection.is_empty(), "late cancel-site click handles missing selection without mutation")
	game.hud.refresh()
	_check(game.hud.selected_name.text == (survivor.display_name if scenario == "mixed_knight" else "等待指令"), scenario + " HUD reads only surviving selection before free")
	await process_frame
	await process_frame
	_check(not is_instance_valid(retiring), scenario + " actually releases the retired native object")
	game.hud.refresh()
	game.get_node("ContextCursor").context_kind(null, Vector3.ZERO)
	game.get_node("OrderPlanOverlay").refresh()
	game.select_entities([survivor], true)
	_check(game.selection == [survivor], scenario + " Shift/Ctrl append remains usable after free")
	game.use_control_group(1)
	game.select_entities([survivor])
	var right := InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = true
	right.position = Vector2(500, 220)
	game._unhandled_input(right)
	game.drag_start = Vector2(200, 160)
	game.shift_drag = true
	game.ctrl_drag = true
	game._finish_selection(Vector2(700, 320))
	game.focus_selection()
	_check(game.selection.all(func(entity): return is_instance_valid(entity) and entity.alive), scenario + " right click, drag completion and focus preserve live selection")
	_check(game.gold == before_gold and game.kills == before_kills, scenario + " client input cannot invent refunds or kills")
	await game.prepare_shutdown()
	completed_cases.append(scenario)
