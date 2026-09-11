extends SceneTree
## Native codex poses, sandbox buttons, batch visibility and AI composition.
var checks: int = 0
var failures: Array[String] = []
var output_dir := "res://report/spearman-20260911/"

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func _capture(name: String, viewport: Viewport) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	check(viewport.get_texture().get_image().save_png(output_dir.path_join(name + ".png")) == OK, "saved rendered " + name)

func _run() -> void:
	create_timer(60.0, true, false, true).timeout.connect(func(): quit(3))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		output_dir = args[0]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))
	var codex: Control = load("res://scenes/unit_codex.tscn").instantiate()
	root.add_child(codex)
	codex.open_codex()
	codex.select_entry(0, "spearman")
	await create_timer(0.5).timeout
	codex.set_process(false)
	check(codex.selected_id == "spearman" and codex._entries.size() == 7, "codex lists and selects all seven units")
	await _capture("spearman-idle", root)
	for angle: float in [PI * 0.5, PI]:
		codex._anchor.rotation.y = angle
		codex._request_preview_redraw()
		await _capture("spearman-idle-" + str(roundi(rad_to_deg(angle))), root)
	codex._anchor.rotation.y = 0.0
	codex._select_preview_action(2)
	var model: UnitVisual = codex._model
	model.locomotion.stop()
	model.attack.play("strike")
	for at: float in [0.0, 0.08, 0.16, 0.22, 0.29, 0.43, 0.65, 0.88]:
		model.attack.seek(at, true)
		var arm: Node3D = model.get_node("Rig/Action/Waist/ArmRight")
		var spear: Node3D = arm.get_node("Spear")
		check(spear.position.is_equal_approx(Vector3(0.25, -0.445, -0.45)), "spear stays in gauntlet at " + str(at))
		if is_equal_approx(at, 0.22):
			check((spear.global_basis * Vector3.UP).dot(Vector3.FORWARD) > 0.98, "spear points straight forward at damage release")
			for angle: float in [0.0, PI * 0.5, PI, PI * 1.5]:
				codex._anchor.rotation.y = angle
				var tip: Vector2 = codex._camera.unproject_position(spear.global_transform * Vector3(0, 1.87, 0))
				check(Rect2(Vector2(6, 6), Vector2(888, 888)).has_point(tip), "thrust tip stays inside native viewport at angle " + str(angle))
			codex._anchor.rotation.y = 0.0
		if at in [0.16, 0.22, 0.43]:
			codex._request_preview_redraw()
			await _capture("spearman-strike-" + str(int(at * 100)), root)
	model.attack.seek(0.22, true)
	codex._anchor.rotation.y = PI * 0.5
	codex._request_preview_redraw()
	await _capture("spearman-strike-side", root)
	codex.queue_free()
	await process_frame
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	var game: Node3D = current_scene
	while not game._match_ready:
		await process_frame
	game.camera_rig.edge_scroll = false
	var button: Button = game.hud.get_node("Sidebar/Scroll/Content/Kinds/spearman")
	button.pressed.emit()
	check(game.paint_kind == "spearman" and game._ghost.kind == "spearman", "sandbox spear button selects the authored placement model")
	game.paint_count = 3
	var placed: int = game.place_units(Vector3(0, 0, 3))
	check(placed == 3, "sandbox places three spearmen through normal placement validation")
	var troops: Array = game.owned_entities(0, "units")
	check(troops.size() == 3 and troops.all(func(unit): return unit.unit_type == "spearman"), "sandbox registers spearmen in player and world state")
	for unit: BattleUnit in troops:
		check(unit._model.batch_parts.size() == 7, "battle spear model uses seven shared rigid parts")
	game.set_faction(15)
	game.paint_count = 1
	check(game.place_units(Vector3(0, 0, -3)) == 1, "sixteenth faction can place the new unit")
	game.set_placing(false)
	await create_timer(0.4).timeout
	await _capture("spearman-sandbox", root)
	var bot := SkirmishBot.new(game, 0)
	bot._memory = {1: {"building": false, "kind": "spearman", "seen_at": 0.0}, 2: {"building": false, "kind": "knight", "seen_at": 0.0}, 3: {"building": false, "kind": "knight", "seen_at": 0.0}}
	check(bot._composition().spearman == 1.0, "AI remembers visible spearmen without unknown-kind errors")
	var counts := {"swordsman": 0, "spearman": 0, "archer": 0, "knight": 0, "catapult": 0, "cannon": 0}
	check(bot._choose_recruit(counts) == "spearman", "AI chooses spearmen in response to cavalry-heavy forces")
	game.clear_units()
	check(game.sandbox_unit_count == 0, "sandbox releases all spear units")
	await physics_frame
	var mover: BattleUnit = game.spawn_unit("spearman", 0, Vector3(0, 0, 3))
	game.set_faction(0)
	game.select_entities([mover])
	check(mover.selected, "new unit participates in ordinary selection")
	check(mover.get_combat_definition().speed == BalanceCatalog.unit(&"swordsman").speed, "spearman uses standard infantry movement speed")
	mover.issue_move(Vector3(0, 0, 10))
	game.set_running(true)
	await create_timer(0.8).timeout
	check(mover.position.distance_to(Vector3(0, 0, 3)) > 1.0 and mover._model.locomotion.current_animation == &"walk", "native navigation advances spearman with walk animation")
	game.set_running(false)
	var paused_at: Vector3 = mover.position
	await create_timer(0.25).timeout
	check(mover.position.is_equal_approx(paused_at), "sandbox pause freezes moving spearman")
	game.set_running(true)
	await create_timer(3.0).timeout
	check(mover.position.distance_to(Vector3(0, 0, 10)) < 0.8, "spearman resumes and arrives at its order destination")
	game.set_running(false)
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open(output_dir.path_join("integration.json"), FileAccess.WRITE).store_string(JSON.stringify({"checks": checks, "failures": failures}, "\t") + "\n")
	print("SPEARMAN_INTEGRATION %d checks; %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
