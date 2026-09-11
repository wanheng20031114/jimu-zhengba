extends SceneTree
## Real-rendered current model poses, portraits, sandbox placement and batching.
const OUTPUT := "res://artifacts/model-previews/shield_guard/"
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func capture(name: String, viewport: Viewport) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	check(viewport.get_texture().get_image().save_png(OUTPUT + name + ".png") == OK, "rendered " + name)

func _run() -> void:
	create_timer(90.0, true, false, true).timeout.connect(func(): quit(3))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var codex: Control = load("res://scenes/unit_codex.tscn").instantiate()
	root.add_child(codex)
	codex.open_codex()
	codex.select_entry(0, "shield_guard")
	await create_timer(0.4).timeout
	codex.set_process(false)
	check(codex._entries.size() == BalanceCatalog.UNITS.size(), "codex includes the complete unit catalog")
	check(codex.get_node("%Stats").text.contains("145") and codex.get_node("%Stats").text.contains("3.5"), "codex displays revised health and standard-minus movement speed")
	var model: UnitVisual = codex._model
	model.locomotion.seek(0.0, true)
	model.attack.play("strike")
	model.attack.seek(0.0, true)
	model.attack.pause()
	await capture("codex", root)
	var triangles: int = 0
	for part: MeshInstance3D in model.get_node("Rig").find_children("*", "MeshInstance3D", true, false):
		triangles += part.mesh.get_faces().size() / 3
	check(triangles <= 6500, "shield model stays under 6500 triangles")
	for angle: int in [0, 45, 90, 180, 270]:
		codex._anchor.rotation.y = deg_to_rad(angle)
		codex._request_preview_redraw()
		await capture("angle-%03d" % angle, codex.get_node("CodexViewport"))
	codex._anchor.rotation.y = 0
	codex._select_preview_action(2)
	codex.set_process(false)
	for phase: float in [0.0, .10, .22, .30, .37, .52, .72, .96]:
		model.attack.seek(phase, true)
		var sword: Node3D = model.get_node("Rig/Action/Waist/ArmRight/Sword")
		check(sword.position.is_equal_approx(Vector3(.215,-.425,-.405)), "sword stays in the gauntlet at " + str(phase))
		if is_equal_approx(phase, .30):
			check((sword.global_basis * Vector3.UP).dot(Vector3.FORWARD) > .95, "short sword points forward at authoritative contact")
		codex._request_preview_redraw()
		await capture("strike-%02d" % int(roundf(phase * 100)), codex.get_node("CodexViewport"))
	model.attack.seek(.30, true)
	await capture("attack", root)
	codex._select_preview_action(1)
	codex.set_process(false)
	var previous_phase: float = 0.0
	for phase: float in [0.0,.18,.36,.54,.72]:
		# Advance the codex's real clock so the native idle-to-walk blend
		# progresses too; seeking alone leaves its blend weight at zero.
		var elapsed: float = phase - previous_phase
		var steps: int = ceili(elapsed * 120.0)
		for step: int in steps:
			codex._advance_preview(elapsed / steps)
		previous_phase = phase
		if is_equal_approx(phase,.18) or is_equal_approx(phase,.54):
			check(absf(model.get_node("Rig/Action/LegLeft").rotation.x) > .4, "real codex playback reaches the walking stride")
		codex._request_preview_redraw()
		await capture("walk-%02d" % int(roundf(phase * 100)), codex.get_node("CodexViewport"))
	codex._select_preview_action(0)
	codex.set_process(false)
	codex._anchor.rotation.y = 0
	codex._camera.position = Vector3(0,1.75,-6)
	codex._camera.look_at(Vector3(0,1.69,0),Vector3.UP)
	codex._camera.size = 1.0
	codex._request_preview_redraw()
	await capture("face",codex.get_node("CodexViewport"))
	codex.queue_free()
	await process_frame
	var portraits: Node = load("res://scenes/model_previews.tscn").instantiate()
	root.add_child(portraits)
	await create_timer(.4).timeout
	await RenderingServer.frame_post_draw
	var portrait: Image = portraits.portrait("shield_guard").get_image()
	var bounds := portrait.get_used_rect()
	check(bounds.size.x > 45 and bounds.size.y > 60, "portrait contains a readable model")
	check(bounds.position.x > 1 and bounds.position.y > 1 and bounds.end.x < 191 and bounds.end.y < 215, "portrait silhouette is not clipped")
	check(portrait.get_pixel(0,0).a < .01, "portrait has native transparency")
	portraits.queue_free()
	await process_frame
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	var game: Node3D = current_scene
	while not game._match_ready:
		await process_frame
	game.camera_rig.edge_scroll = false
	game.camera_rig.set_process(false)
	game.hud.get_node("Sidebar/Scroll/Content/Kinds/shield_guard").pressed.emit()
	check(game.paint_kind == "shield_guard" and game._ghost.kind == "shield_guard", "sandbox button selects the new model")
	game.paint_count = 1
	check(game.place_units(Vector3(0,0,0)) == 1, "sandbox placement uses real radius and collision rules")
	game.set_placing(false)
	var guard: BattleUnit = game.owned_entities(0,"units")[0]
	var sword: BattleUnit = game.spawn_unit("swordsman",0,Vector3(-2.5,0,0))
	var spear: BattleUnit = game.spawn_unit("spearman",0,Vector3(2.5,0,0))
	check(guard._model.batch_parts.size() == 7, "battle shield guard uses seven shared rigid parts")
	game.select_entities([guard])
	check(guard.selected and guard.radius == .52 and guard.speed == 3.5, "normal selection and revised movement stats")
	game.camera_rig.camera.size = 10
	game.camera_rig.camera.position = Vector3(2,7,-10)
	game.camera_rig.camera.look_at(Vector3(0,1,0),Vector3.UP)
	game.hud.hide()
	await create_timer(.35).timeout
	await capture("comparison",root)
	game.camera_rig.camera.size = 24
	await capture("battle-scale",root)
	game.camera_rig.camera.size = 10
	for unit: BattleUnit in [sword,spear]:
		unit.queue_free()
	guard.issue_move(Vector3(0,0,8))
	game.set_running(true)
	await create_timer(.8).timeout
	check(guard.position.z > 1 and guard._model.locomotion.current_animation == &"walk", "new unit walks through native navigation")
	game.set_running(false)
	var paused_at: Vector3 = guard.position
	await create_timer(.2).timeout
	check(guard.position.is_equal_approx(paused_at), "sandbox pause freezes the new unit")
	game.set_running(true)
	await create_timer(2.5).timeout
	check(guard.position.distance_to(Vector3(0,0,8)) < .8, "new unit resumes and reaches its destination")
	game.set_running(false)
	guard._model.die()
	check(not guard._model.attack.is_playing() and not guard._model.locomotion.is_playing(), "death stops both authored animation players")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open(OUTPUT + "visual-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"triangles":triangles,"portrait_bounds":str(bounds)},"\t"))
	print("SHIELD_VISUAL ",checks," checks; ",failures.size()," failures; ",triangles," triangles")
	quit(0 if failures.is_empty() else 1)
