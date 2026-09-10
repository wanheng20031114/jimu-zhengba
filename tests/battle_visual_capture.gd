extends SceneTree
## GPU capture of the real campaign, using its initial army and normal orders.
## Launch with --position -20000,-20000 --audio-driver Dummy --script THIS_FILE.

const OUTPUT := "res://artifacts/battle_visual"
var game: Node3D
var started_usec: int
var shots: Array[Dictionary] = []
var attack_types: Dictionary = {}
var projectile_types: Dictionary = {}
var checks: Dictionary = {}
var finishing: bool = false

func _initialize() -> void:
	# The process is launched hidden and offscreen; this native flag also prevents
	# the review window from taking keyboard focus from the user's editor/game.
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	DisplayServer.window_set_position(Vector2i(-20000, -20000))
	started_usec = Time.get_ticks_usec()
	_run.call_deferred()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT)
	create_timer(65.0, true, false, true).timeout.connect(_watchdog)
	seed(28471)
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.camera_rig.edge_scroll = false
	await physics_frame
	await physics_frame
	await physics_frame
	checks["no_focus_window"] = DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS)
	checks["uses_initial_army"] = game.player_count() == 16
	game.select_army()
	game.use_control_group(1, true)
	game.command_move(Vector3(1, 0, -4), true)
	_focus(Vector3(0, 0, -2), 23.0)
	var began_melee: bool = false
	var deadline: float = _elapsed() + 16.0
	while _elapsed() < deadline:
		_observe()
		if not began_melee and _melee_attacking() >= 2:
			began_melee = true
			await _snapshot("01_melee_hud")
			await _advance(0.35)
			await _snapshot("02_melee_detail", true)
			await _advance(0.9)
			await _snapshot("03_mixed_army_hud")
			break
		await create_timer(0.04).timeout
	checks["real_melee_animation"] = began_melee
	await _advance(3.0)
	var barracks: BattleBuilding = game.get_node("Buildings/WestBarracks")
	game.select_army()
	game.command_attack(barracks)
	# Frame the full firing line: artillery stays behind the archers and must
	# remain above the command bar while the barracks fills the upper third.
	_focus(Vector3(-5, 0, -1), 27.0)
	var siege_shot: bool = false
	var collapse_shot: bool = false
	deadline = _elapsed() + 32.0
	while _elapsed() < deadline:
		_observe()
		if not siege_shot and barracks.hp < barracks.max_hp and _siege_projectiles() > 0:
			siege_shot = true
			await _snapshot("04_siege_hud")
			await _advance(0.15)
			await _snapshot("05_siege_detail", true)
		if not barracks.alive:
			collapse_shot = true
			await _advance(0.24)
			await _snapshot("06_building_collapse_hud")
			await _advance(0.35)
			await _snapshot("07_collapse_detail", true)
			await _advance(1.2)
			await _snapshot("08_cleared_rubble_hud")
			break
		await create_timer(0.025).timeout
	checks["real_siege_projectile"] = siege_shot
	checks["real_building_destruction"] = collapse_shot
	checks["observed_five_attack_animations"] = attack_types.size() == 5
	checks["observed_three_projectile_types"] = projectile_types.size() == 3
	await _finish()

func _focus(at: Vector3, size: float) -> void:
	game.camera_rig.focus_at(at, true)
	game.camera_rig.zoom_target = size
	game.camera.size = size

func _advance(seconds: float) -> void:
	var until := _elapsed() + seconds
	while _elapsed() < until:
		_observe()
		await create_timer(0.025).timeout

func _observe() -> void:
	for unit: BattleUnit in get_nodes_in_group("units"):
		if unit.alive and unit._attack_animation.is_playing():
			attack_types[unit.unit_type] = true
	for effect: ProjectileFlight in game.get_node("ProjectilePool").active_flights:
		if effect._active:
			projectile_types[effect._kind] = true

func _melee_attacking() -> int:
	var count: int = 0
	for unit: BattleUnit in get_nodes_in_group("friendly_units"):
		if unit.alive and unit.unit_type in ["swordsman", "knight"] and unit._attack_animation.is_playing():
			count += 1
	return count

func _siege_projectiles() -> int:
	var count: int = 0
	for effect: ProjectileFlight in game.get_node("ProjectilePool").active_flights:
		if effect._active and effect._kind in ["stone", "cannon"]:
			count += 1
	return count

func _snapshot(label: String, clean: bool = false) -> void:
	game.hud.visible = not clean
	await RenderingServer.frame_post_draw
	var path := OUTPUT + "/" + label + ".png"
	root.get_texture().get_image().save_png(path)
	var visible_bars: int = 0
	for unit: BattleUnit in get_nodes_in_group("units"):
		if unit.alive and unit.health_bar.visible and game.camera.is_position_in_frustum(unit.global_position):
			visible_bars += 1
	shots.append({"file": path, "elapsed_s": snappedf(_elapsed(), 0.01), "hud": not clean, "friendly": game.player_count(), "enemy": game.enemy_count(), "kills": game.kills, "destroyed": game.buildings_destroyed, "visible_health_bars": visible_bars, "projectiles": _siege_projectiles()})
	print("BATTLE_VISUAL_CAPTURE ", JSON.stringify(shots.back()))
	game.hud.visible = true

func _elapsed() -> float:
	return float(Time.get_ticks_usec() - started_usec) / 1000000.0

func _watchdog() -> void:
	if not finishing:
		checks["watchdog"] = false
		_finish()

func _finish() -> void:
	if finishing:
		return
	finishing = true
	var success: bool = not checks.values().has(false)
	var report := {"passed": success, "checks": checks, "attack_types": attack_types.keys(), "projectile_types": projectile_types.keys(), "shots": shots}
	var file := FileAccess.open(OUTPUT + "/report.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("BATTLE_VISUAL_RESULT ", JSON.stringify(report))
	await game.prepare_shutdown()
	quit(0 if success else 1)
